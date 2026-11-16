#!/usr/bin/env python3
"""Three-pane demo harness for the rate-limit recording.

Layout (tmux): top-left SPOTLIGHT (policy snippet, driving line highlighted),
top-right GATEWAY ACTIVITY (prettified access_log), bottom AGENT REPL. It drives
the interactive agent through the six locked acts, keeping the spotlight in step.
Deterministic (mock model with prepared replies).

Spotlight is rendered by re-invoking this script as a subcommand inside the top
pane (`record_demo.py spotlight <i>`), the same pattern the policy-engine demo
uses — a static, colorized, boxed snippet per act.

Modes:
  (default)    preview: play the acts and attach so you can watch live
  --selftest   headless: play the acts, dump each pane, exit (no attach)
  --record     record the attached session to record/demo.cast via asciinema

Run from the demo root or this directory. Prereqs: docker, cargo, tmux, python
httpx (record/.venv), asciinema for --record. The deterministic proof of the
policy outcomes remains ../run-demo.sh.
"""
import os
import re
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)  # demo root
os.chdir(ROOT)

SES = "ratelimit-demo"
GATEWAY_LOG = "record/gateway-record.log"
ACCESS = "record/access.ndjson"  # access_log file sink; the activity pane tails this
PY = "record/.venv/bin/python" if os.path.exists("record/.venv/bin/python") else "python3"
ASCIINEMA = "record/.venv/bin/asciinema" if os.path.exists("record/.venv/bin/asciinema") else "asciinema"
SELF = "record/record_demo.py"
READ = 10.0  # seconds to let the viewer read each spotlight before the agent acts

# ANSI (boxed spotlight, policy-engine style + our highlight)
RESET = "\033[0m"; GRAY = "\033[90m"; CYAN = "\033[1;96m"
YELLOW = "\033[1;93m"; GREEN = "\033[1;92m"; BOLD = "\033[1m"


def _c(text, color):
    return f"{color}{text}{RESET}"


# --- the six locked acts -----------------------------------------------------
LIMITER = """  - name: requests
    kind: ratelimit/limitador
    hooks: [ratelimit.post_identity]
    config:
      namespace: chat
      bindings: { subject_id: subject.id }
      limits:
        - max: 3
          seconds: 60
          variables: [subject_id]"""

ACTS = [
    dict(title="1 · Accounting",
         caption="agent-blue calls the model to triage support tickets.\n"
                 "the limiter counts each admitted call; the budget is 3 per 60s.",
         snippet=LIMITER, highlight=["max: 3", "seconds: 60"],
         inputs=["ticket: can't log in", "ticket: wrong invoice tax", "ticket: dark mode please"]),
    dict(title="2 · Admission gate",
         caption="once the budget is spent, every further call is denied at admission.\n"
                 "the model never runs for a denied call -- no wasted work downstream.",
         snippet=LIMITER, highlight=["max: 3"],
         inputs=["ticket: app crash on upload", "ticket: refund request"]),
    dict(title="3 · Identity-based keying",
         caption="the counter is keyed on the verified subject.id, not the connection.\n"
                 "agent-green is a different agent, so it gets its own fresh budget.",
         snippet="""    config:
      bindings: { subject_id: subject.id }
      limits:
        - max: 3
          variables: [subject_id]""",
         highlight=["subject_id: subject.id", "variables: [subject_id]"],
         inputs=["/as agent-green", "ticket: export as CSV", "ticket: reset 2FA"]),
    dict(title="4 · Selection",
         caption="there is no global limiter; limiting is opt-in, per route.\n"
                 "/v1/models lists none, so agent-blue is served even while throttled on chat.",
         snippet="""global:
  authentication: [jwt-agent]
  # no rate_limits here  ->  no global limit
routes:
  - http: /v1/chat/completions
    rate_limits: { steps: [{ name: requests }] }
  # /v1/models: not listed  ->  never rate limited""",
         highlight=["# no rate_limits here", "# /v1/models: not listed"],
         inputs=["/as agent-blue", "/models"]),
    dict(title="5 · Route-specific limit",
         caption="the same limiter is attached to /v1/embeddings with an override:\n"
                 "a lower budget (1 per 60s) and a separate counter, independent of chat.",
         snippet="""routes:
  - http: /v1/embeddings
    rate_limits:
      steps:
        - name: requests
          config:
            namespace: embeddings
            limits: [{ max: 1, seconds: 60, variables: [subject_id] }]""",
         highlight=["namespace: embeddings", "max: 1"],
         inputs=["/embed quarterly report", "/embed follow-up"]),
    dict(title="6 · Trust basis",
         caption="the limit depends on a verified identity, not caller-supplied input.\n"
                 "no token, or a token with no subject, is denied before any counter changes.",
         snippet="""plugins:
  - name: jwt-agent
    kind: identity/jwt
    on_error: fail
  - name: requests
    kind: ratelimit/limitador
    capabilities: [read_subject]""",
         highlight=["on_error: fail", "capabilities: [read_subject]"],
         inputs=["/as none", "ticket: hello", "/as nosub", "ticket: hello"]),
]


def render_spotlight(act):
    """Print a titled, colorized, boxed policy snippet + caption (run in the top pane)."""
    # Adapt the box to the pane width so it fits whatever size the recording runs at.
    cols = shutil.get_terminal_size((80, 24)).columns
    width = max(46, min(cols - 6, 92))
    bar = "─" * width
    print()
    print("  " + _c("┌" + bar + "┐", GRAY))
    print("  " + _c("│", GRAY) + " " + _c("POLICY  ", CYAN) + _c(f"Act {act['title']}", YELLOW))
    print("  " + _c("├" + bar + "┤", GRAY))
    for line in act["snippet"].splitlines():
        if any(h in line for h in act["highlight"]):
            body = _c(line + "  ◀", YELLOW + BOLD)
        else:
            body = _c(line, GREEN)
        print("  " + _c("│", GRAY) + "  " + body)
    print("  " + _c("└" + bar + "┘", GRAY))
    # Caption may be multiple lines (split on "\n"); each is word-wrapped.
    for para in act["caption"].split("\n"):
        words, ln = para.split(), ""
        for w in words:
            if len(ln) + len(w) + 1 > width - 2:
                print("  " + _c("» " + ln, GRAY)); ln = w
            else:
                ln = f"{ln} {w}".strip()
        if ln:
            print("  " + _c("» " + ln, GRAY))
    sys.stdout.flush()


# --- tmux helpers ------------------------------------------------------------
def tmux(*args, check=True):
    return subprocess.run(["tmux", *args], check=check, capture_output=True, text=True)


def capture(pane):
    return tmux("capture-pane", "-p", "-t", pane, check=False).stdout


def send(pane, text):
    tmux("send-keys", "-t", pane, "-l", text)
    tmux("send-keys", "-t", pane, "Enter")


def wait_prompt(pane, identity, timeout=20):
    stable = 0
    for _ in range(int(timeout / 0.25)):
        lines = [ln for ln in capture(pane).splitlines() if ln.strip()]
        last = lines[-1].rstrip() if lines else ""
        if last.endswith("❯") and last.startswith(identity):
            stable += 1
            if stable >= 2:
                return True
        else:
            stable = 0
        time.sleep(0.25)
    return False


# --- stack ------------------------------------------------------------------
_gw = None


def setup_stack():
    global _gw
    # Clear any stale gateway on :8095 so our access_log-enabled one actually binds
    # (a leftover would serve requests and silently mask a bind failure).
    subprocess.run(["bash", "-c", "fuser -k 8095/tcp 2>/dev/null; sleep 1"], check=False)
    subprocess.run(["./jwt/generate.sh"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["docker", "compose", "up", "-d", "--wait"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    binp = subprocess.run(["./build-praxis.sh"], check=True, capture_output=True, text=True).stdout.strip()
    open(ACCESS, "w").close()  # fresh access-log sink for this run
    env = {**os.environ, "RUST_LOG": os.environ.get("RUST_LOG", "info")}
    _gw = subprocess.Popen([binp, "-c", "record/praxis-record.yaml"],
                           stdout=open(GATEWAY_LOG, "w"), stderr=subprocess.STDOUT, env=env)
    for _ in range(30):
        if subprocess.run(["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8095"],
                          check=False, capture_output=True).returncode == 0:
            return
        time.sleep(1)
    raise SystemExit("gateway did not start (see %s)" % GATEWAY_LOG)


def teardown():
    tmux("kill-session", "-t", SES, check=False)
    if _gw:
        _gw.terminate()
    subprocess.run(["docker", "compose", "down"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# --- panes ------------------------------------------------------------------
def build_panes():
    tmux("kill-session", "-t", SES, check=False)
    spot = tmux("new-session", "-d", "-s", SES, "-x", "188", "-y", "50",
                "-P", "-F", "#{pane_id}").stdout.strip()
    tmux("set-option", "-t", SES, "status", "off")
    # REPL + activity are launched as pane commands (no shell echo / prompt).
    repl_cmd = ("GATEWAY_URL=http://127.0.0.1:8095 TOKENS_DIR=jwt/tokens "
                "MODEL=mock-model %s record/agent-repl.py" % PY)
    repl = tmux("split-window", "-v", "-t", spot, "-l", "58%",
                "-P", "-F", "#{pane_id}", repl_cmd).stdout.strip()
    act = tmux("split-window", "-h", "-t", spot, "-P", "-F", "#{pane_id}",
               "%s -u record/_activity.py %s" % (PY, ACCESS)).stdout.strip()
    # Spotlight pane stays a shell we send `spotlight` subcommands to; silence its
    # prompt so only the boxed snippet shows.
    send(spot, "PROMPT_COMMAND=''; PS1=''; clear")
    return spot, act, repl


def drive(spot, repl, pause=5.0, settle=0.4, read=READ, end_session=False):
    identity = "agent-blue"
    wait_prompt(repl, identity, timeout=25)
    time.sleep(1.5)  # settle / let a viewer attach
    for i, act in enumerate(ACTS):
        send(spot, "clear; %s %s spotlight %d" % (PY, SELF, i))
        time.sleep(read)
        for line in act["inputs"]:
            send(repl, line)
            if line.startswith("/as "):
                identity = line.split(None, 1)[1].strip()
            time.sleep(settle)
            wait_prompt(repl, identity)
            time.sleep(settle)
        time.sleep(pause)
    time.sleep(1.5)
    if end_session:
        time.sleep(2.5)  # hold the final frame, then end so asciinema rec stops
        tmux("kill-session", "-t", SES, check=False)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--preview"
    setup_stack()
    try:
        spot, act, repl = build_panes()
        if mode == "--selftest":
            drive(spot, repl, pause=0.4, settle=0.25, read=0.8)
            for name, p in [("SPOTLIGHT", spot), ("ACTIVITY", act), ("REPL", repl)]:
                print(f"\n===== {name} =====")
                print(capture(p))
        elif mode == "--record":
            t = threading.Thread(target=drive, args=(spot, repl),
                                 kwargs={"end_session": True}, daemon=True)
            t.start()
            subprocess.run([ASCIINEMA, "rec", "-q", "--overwrite",
                            "--title", "Rate-limit an agent's requests",
                            "-c", f"tmux attach -t {SES}", "record/demo.cast"], check=False)
            t.join(timeout=10)
        else:  # preview
            t = threading.Thread(target=drive, args=(spot, repl), daemon=True)
            t.start()
            subprocess.run(["tmux", "attach", "-t", SES], check=False)
            t.join(timeout=5)
    finally:
        teardown()


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "spotlight":
        render_spotlight(ACTS[int(sys.argv[2])])
        sys.exit(0)
    main()
