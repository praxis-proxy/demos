#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
"""
Record the interactive CPEX HR assistant (chat.py) as a demo GIF/MP4.

This is the "assistant cut": a real, LLM-driven session in front of the
Praxis-CPEX gateway, driven through a two-pane tmux layout and captured with
asciinema. The TOP pane spotlights the exact cpex.yaml policy that governs each
step; the BOTTOM pane is chat.py talking to the gateway. The two are interleaved
so a viewer sees the rule and then the agent obeying it.

It exercises the main features end to end:
  allow + RFC 8693 delegation, session taint, APL deny, Cedar allow/deny,
  on-the-wire SSN redaction, and the human-in-the-loop CIBA approval flow.

Usage:
  # Full recording (needs the stack up + a capable tool-calling model):
  DEMO_MODEL=watsonx/meta-llama/llama-3-3-70b-instruct \
      python demo/record_chat_demo.py --record

  python demo/record_chat_demo.py --check       # preflight only, no recording
  python demo/record_chat_demo.py --gif-only     # re-convert an existing .cast
  python demo/record_chat_demo.py --verify        # check markers in the .cast
  python demo/record_chat_demo.py --no-cleanup    # keep the tmux session (debug)

  # Internal subcommands the TOP pane runs (not called by hand):
  python demo/record_chat_demo.py spotlight <act-key>
  python demo/record_chat_demo.py approve [--approver alice]

Prerequisites:
  - The full cpex stack up (../restart.sh with the feat/hil_apl gateway, plus a
    REBUILD_IMAGES=1 run if hr-mcp predates adjust_compensation), so
    :8090 gateway, :8081 Keycloak (cpex-demo realm), :5001 auth-channel, and the
    hr-mcp backend are all live.
  - A model that reliably tool-calls (70B-class / gpt-4o / claude); the local
    ollama default forgets tools mid-flow. Set DEMO_MODEL.
  - tmux + asciinema on PATH (agg + ffmpeg for GIF/MP4 conversion).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

# --------------------------------------------------------------------------
# Paths and configuration
# --------------------------------------------------------------------------

SELF = Path(__file__).resolve()
AGENT_DIR = SELF.parent.parent          # .../agent
DEMO_ROOT = AGENT_DIR.parent            # .../cpex
CHAT_PY = AGENT_DIR / "chat.py"
OUT_DIR = SELF.parent                   # .../agent/demo
CAST_FILE = OUT_DIR / "chat-demo.cast"
GIF_FILE = OUT_DIR / "chat-demo.gif"
MP4_FILE = OUT_DIR / "chat-demo.mp4"

SESSION = "cpex-chat-demo"
COLS, ROWS = 160, 48
CHAT_ROWS = 30                          # bottom pane height; top gets the rest

GATEWAY = os.environ.get("GATEWAY_URL", "http://localhost:8090/mcp")
KEYCLOAK = os.environ.get("KEYCLOAK_HOST", "http://localhost:8081")
AUTH_CHANNEL = os.environ.get("AUTH_CHANNEL", "http://localhost:5001")
DEMO_MODEL = os.environ.get("DEMO_MODEL", "ollama/qwen3:8b")
BANNER_MARKER = "CPEX-Praxis HR Demo"

# Timing (seconds). Independent knobs: reading time vs. response waits.
READ_POLICY = 6.0        # let viewers read the spotlighted policy
READ_RESPONSE = 5.0      # let viewers read the agent's answer
AFTER_SEND_MIN = 2.0     # min settle before we start watching for the prompt
RESPONSE_TIMEOUT = 100   # LLM completion + gateway round-trip
HIL_WAIT = 60            # wait for the out-of-band approval to surface in chat

# --------------------------------------------------------------------------
# ANSI helpers (spotlight rendering)
# --------------------------------------------------------------------------

RESET = "\033[0m"
GRAY = "\033[90m"
CYAN = "\033[1;96m"
YELLOW = "\033[1;93m"
GREEN = "\033[1;92m"


def _c(text: str, color: str) -> str:
    return f"{color}{text}{RESET}"


# --------------------------------------------------------------------------
# The acts: persona, prompt, the policy to spotlight, and expected markers
# --------------------------------------------------------------------------
#
# Each act names a policy snippet (verbatim from cpex.yaml) plus a one-line
# caption explaining the decision, and the natural-language prompt typed into
# the chat. `switch` swaps the human persona mid-conversation.

SPOTLIGHTS: dict[str, dict[str, str]] = {
    "allow": {
        "title": "get_compensation — allow + RFC 8693 delegation",
        "yaml": (
            "routes:\n"
            "  - tool: get_compensation\n"
            "    pre_invocation:\n"
            '      - "require(role.hr)"\n'
            '      - "delegate(workday-oauth, audience: workday-api,\n'
            '                  permissions: [read_compensation])"\n'
            '      - "taint(secret, session)"\n'
            "    result:\n"
            '      ssn: "str | redact(!perm.view_ssn)"'
        ),
        "caption": "Bob is HR with view_ssn: allowed. His token is exchanged for a "
        "workday-api token (RFC 8693); the backend never sees his IdP JWT.",
    },
    "taint": {
        "title": "send_email — session taint blocks exfiltration",
        "yaml": (
            "  - tool: get_compensation\n"
            "    pre_invocation:\n"
            '      - "taint(secret, session)"      # <- ran a moment ago\n'
            "\n"
            "  - tool: send_email\n"
            "    pre_invocation:\n"
            '      - "security.labels contains \\"secret\\":\n'
            "             deny('external email blocked', 'session_tainted_secret')\""
        ),
        "caption": "This session already read secret comp data, so it carries the "
        "'secret' label. Emailing out is blocked even with a clean body.",
    },
    "deny": {
        "title": "get_compensation — APL deny (wrong role)",
        "yaml": (
            "  - tool: get_compensation\n"
            "    pre_invocation:\n"
            '      - "require(role.hr)"            # <- gate #1'
        ),
        "caption": "Alice is engineering, not HR. require(role.hr) denies at the "
        "cheapest layer: no PDP, no token exchange, no backend call.",
    },
    "cel_allow": {
        "title": "search_repos — CEL PERMITS internal repos",
        "yaml": (
            "  - tool: search_repos\n"
            "    pre_invocation:\n"
            '      - "require(team.engineering | team.security)"\n'
            "      - cel:\n"
            "          expr: |\n"
            "            (has(role.engineer) && role.engineer &&\n"
            '             args.visibility == "internal")\n'
            "            || (has(role.security) && role.security)"
        ),
        "caption": "engineer + args.visibility == \"internal\" makes the CEL predicate "
        "true. A github-api token is minted for the forwarded call.",
    },
    "cel_deny": {
        "title": "search_repos — CEL DENIES external repos",
        "yaml": (
            "  # global.pdp: { kind: cel }.  The route's cel: step:\n"
            "  (has(role.engineer) && role.engineer &&\n"
            '   args.visibility == "internal")\n'
            "  || (has(role.security) && role.security)\n"
            "  # on_deny -> deny('…', 'cel.policy_denied')"
        ),
        "caption": "visibility == \"external\" makes the predicate false, so it denies "
        "(cel.policy_denied). The rule is inline on the route, no external store.",
    },
    "redact": {
        "title": "get_compensation — on-the-wire SSN redaction",
        "yaml": (
            "  - tool: get_compensation\n"
            "    result:\n"
            '      ssn: "str | redact(!perm.view_ssn)"'
        ),
        "caption": "Eve is HR but lacks view_ssn. The gateway rewrites the response "
        "body: the agent only ever sees ssn = [REDACTED].",
    },
    "hil": {
        "title": "adjust_compensation — human-in-the-loop approval",
        "yaml": (
            "  - tool: adjust_compensation\n"
            "    pre_invocation:\n"
            '      - "require(role.hr)"\n'
            '      - when: "args.amount > 10000"\n'
            "        do:\n"
            '          - "require_approval(manager-approver, from: claim.manager,\n'
            '                 channel: \\"ciba\\", scope: \\"args.amount <= 25000\\")"'
        ),
        "caption": "Over $10k suspends the call for Bob's manager (Alice) to approve "
        "out-of-band via OIDC CIBA. The gateway returns -32120, never blocks.",
    },
}

# persona key -> display name chat.py prints as the prompt
PERSONA_NAME = {
    "alice": "Alice Chen",
    "bob": "Bob Martinez",
    "charlie": "Charlie Wu",
    "eve": "Eve Patel",
}

# The demo flow. kind: "prompt" | "switch". HIL is handled specially.
ACTS = [
    {"kind": "prompt", "persona": "bob", "spotlight": "allow",
     "prompt": "Look up the compensation for EMP-001234, and include the SSN."},
    {"kind": "prompt", "persona": "bob", "spotlight": "taint",
     "prompt": "Now email that compensation summary to partner@example.com."},
    {"kind": "switch", "persona": "alice"},
    {"kind": "prompt", "persona": "alice", "spotlight": "deny",
     "prompt": "Look up the compensation for EMP-001234."},
    {"kind": "prompt", "persona": "alice", "spotlight": "cel_allow",
     "prompt": "Search the internal repos for web-app."},
    {"kind": "prompt", "persona": "alice", "spotlight": "cel_deny",
     "prompt": "Now search the external repos for partner-sdk."},
    {"kind": "switch", "persona": "eve"},
    {"kind": "prompt", "persona": "eve", "spotlight": "redact",
     "prompt": "Look up the compensation for EMP-001234, include the SSN."},
    {"kind": "switch", "persona": "bob"},
    {"kind": "hil", "persona": "bob", "spotlight": "hil",
     "prompt": "Give EMP-001234 a $25,000 raise — her Q3 review was strong.",
     "confirm": "Yes, apply it."},
]

# Markers that must appear in the recording for it to count as a valid demo.
VERIFY_MARKERS = [
    (BANNER_MARKER, "intro banner"),
    ("[REDACTED]", "Eve: SSN redacted on the wire"),
    ("pending", "HIL: approval requested"),
    ("approved", "HIL: manager approved"),
    ("applied", "HIL: change applied after approval"),
]


# --------------------------------------------------------------------------
# spotlight / approve subcommands (run inside the TOP pane)
# --------------------------------------------------------------------------

def render_spotlight(key: str) -> None:
    """Print a titled, colorized policy snippet + caption. The TOP pane runs
    `record_chat_demo.py spotlight <key>` so the rule is on screen while the
    agent acts on it below."""
    s = SPOTLIGHTS[key]
    width = 78
    bar = "─" * width
    print()
    print(_c("  ┌" + bar + "┐", GRAY))
    print("  " + _c("│", GRAY) + " " + _c("POLICY  ", CYAN) + _c(s["title"], YELLOW))
    print(_c("  ├" + bar + "┤", GRAY))
    for line in s["yaml"].splitlines():
        print("  " + _c("│", GRAY) + "   " + _c(line, GREEN))
    print(_c("  └" + bar + "┘", GRAY))
    # Caption wrapped to the box width.
    words, line = s["caption"].split(), ""
    for w in words:
        if len(line) + len(w) + 1 > width - 2:
            print("  " + _c("» " + line, GRAY))
            line = w
        else:
            line = f"{line} {w}".strip()
    if line:
        print("  " + _c("» " + line, GRAY))
    sys.stdout.flush()


def _http_json(url: str, method: str = "GET", timeout: float = 5.0):
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (localhost dev)
        body = resp.read().decode()
        try:
            return resp.status, json.loads(body)
        except json.JSONDecodeError:
            return resp.status, body


def do_approve(approver: str = "alice") -> int:
    """Drive the auth-channel approval UI programmatically — the 'manager taps
    Approve on their phone' moment, shown in the TOP pane. Uses the dev-only
    /pending endpoint to find the request id, then POSTs /approve."""
    print()
    print("  " + _c(f"📱  {approver}'s phone — incoming approval request", CYAN))
    arid = None
    for _ in range(20):
        try:
            _, pend = _http_json(f"{AUTH_CHANNEL}/pending?login_hint={approver}")
        except Exception:  # noqa: BLE001
            pend = []
        if isinstance(pend, list) and pend:
            arid = pend[0].get("auth_req_id")
            break
        time.sleep(1)
    if not arid:
        print("  " + _c(f"✗ no pending request for {approver} at {AUTH_CHANNEL}", YELLOW))
        return 1
    try:
        _http_json(f"{AUTH_CHANNEL}/approve/{arid}", method="POST")
    except Exception as e:  # noqa: BLE001
        print("  " + _c(f"✗ approve failed: {e}", YELLOW))
        return 1
    print("  " + _c(f"✓  {approver} tapped Approve  (req {arid[:8]}…)", GREEN))
    print("  " + _c("   Keycloak releases the token on the gateway's next CIBA poll.", GRAY))
    sys.stdout.flush()
    return 0


# --------------------------------------------------------------------------
# tmux plumbing
# --------------------------------------------------------------------------

def tmux(*args: str, check: bool = True, capture: bool = False):
    return subprocess.run(["tmux", *args], check=check,
                          capture_output=capture, text=True)


def pane_ids() -> tuple[str, str]:
    """Return (top_pane_id, bottom_pane_id) by vertical position — robust to
    any tmux base-index configuration."""
    out = tmux("list-panes", "-t", SESSION, "-F", "#{pane_top} #{pane_id}",
               capture=True).stdout.strip().splitlines()
    ordered = sorted(out, key=lambda l: int(l.split()[0]))
    return ordered[0].split()[1], ordered[-1].split()[1]


def send_line(pane: str, text: str) -> None:
    tmux("send-keys", "-t", pane, "-l", text)
    tmux("send-keys", "-t", pane, "Enter")


def capture(pane: str) -> str:
    return tmux("capture-pane", "-t", pane, "-p", capture=True).stdout


def wait_for_prompt(pane: str, persona: str, timeout: float = RESPONSE_TIMEOUT) -> bool:
    """Wait until the chat pane is back at the persona's input prompt (e.g.
    'Bob Martinez:'), stable for two consecutive reads. This is the reliable
    'agent finished this turn' signal — chat.py does not stream tokens, so a
    naive stability check would false-trigger while the LLM is thinking."""
    name = PERSONA_NAME[persona]
    time.sleep(AFTER_SEND_MIN)
    deadline = time.time() + timeout
    stable = 0
    while time.time() < deadline:
        lines = [l for l in capture(pane).splitlines() if l.strip()]
        last = lines[-1].strip() if lines else ""
        # The bare prompt is just "<Name>:" (no user text after it).
        if last.endswith(f"{name}:"):
            stable += 1
            if stable >= 2:
                return True
        else:
            stable = 0
        time.sleep(0.6)
    return False


def wait_for_text(pane: str, needle: str, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in capture(pane):
            return True
        time.sleep(0.6)
    return False


# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

def _reachable(url: str) -> bool:
    try:
        urllib.request.urlopen(url, timeout=4)  # noqa: S310
        return True
    except urllib.error.HTTPError:
        return True  # any HTTP response means it's up
    except Exception:  # noqa: BLE001
        return False


def preflight() -> bool:
    ok = True

    def check(label: str, good: bool, hint: str = "") -> None:
        nonlocal ok
        mark = "✓" if good else "✗"
        print(f"  {mark} {label}" + ("" if good else f"   {hint}"))
        ok = ok and good

    for tool in ("tmux", "asciinema"):
        check(f"{tool} on PATH", subprocess.run(["which", tool],
              capture_output=True).returncode == 0, f"install {tool}")
    for tool in ("agg", "ffmpeg"):
        present = subprocess.run(["which", tool], capture_output=True).returncode == 0
        print(f"  {'✓' if present else '·'} {tool} on PATH"
              + ("" if present else "   (optional — needed for GIF/MP4 convert)"))
    check(f"gateway {GATEWAY}", _reachable(GATEWAY.rsplit('/', 1)[0]))
    check(f"Keycloak cpex-demo realm",
          _reachable(f"{KEYCLOAK}/realms/cpex-demo/.well-known/openid-configuration"))
    check(f"auth-channel {AUTH_CHANNEL}", _reachable(f"{AUTH_CHANNEL}/health"),
          "start it: docker compose up -d auth-channel")

    # hr-mcp must advertise adjust_compensation (rebuild if it's a stale image).
    adj = False
    try:
        mint = DEMO_ROOT / "mint-token.sh"
        bob = subprocess.run(["bash", str(mint), "bob"], capture_output=True,
                             text=True, cwd=DEMO_ROOT).stdout.strip()
        cli = subprocess.run(["bash", str(mint), "hr-copilot"], capture_output=True,
                             text=True, cwd=DEMO_ROOT).stdout.strip()
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
        req = urllib.request.Request(GATEWAY, data=body, method="POST", headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {cli}", "X-User-Token": bob})
        with urllib.request.urlopen(req, timeout=6) as r:  # noqa: S310
            adj = "adjust_compensation" in r.read().decode()
    except Exception:  # noqa: BLE001
        adj = False
    check("hr-mcp advertises adjust_compensation", adj,
          "stale image — run: docker compose build hr-mcp && docker compose up -d hr-mcp")

    weak = DEMO_MODEL.startswith("ollama/")
    print(f"  {'·' if weak else '✓'} model: {DEMO_MODEL}"
          + ("   (local models often drop tool calls — set DEMO_MODEL to a 70B/gpt-4o/claude)"
             if weak else ""))
    return ok


# --------------------------------------------------------------------------
# Record
# --------------------------------------------------------------------------

def _cleanup_session() -> None:
    subprocess.run(["tmux", "kill-session", "-t", SESSION], capture_output=True)


def record(no_cleanup: bool = False) -> int:
    if not preflight():
        print("\nPreflight failed — fix the above and retry.")
        return 1
    print()

    _cleanup_session()
    tmux("new-session", "-d", "-s", SESSION, "-x", str(COLS), "-y", str(ROWS))
    # Bottom pane (chat) gets CHAT_ROWS; the top pane (policy) gets the rest.
    tmux("split-window", "-v", "-t", SESSION, "-l", str(CHAT_ROWS))
    top, bottom = pane_ids()

    # Position + quiet both panes BEFORE recording, so none of this setup (nor
    # any absolute home path) is captured. Policy pane: blank prompt, no input
    # echo → only the spotlight boxes show. Chat pane: cd'd into AGENT_DIR with a
    # short prompt (echo kept on so typed prompts stay visible), so the launch
    # line is short and free of a /Users home path.
    send_line(top, "stty -echo; PS1=''; clear")
    send_line(bottom, f"cd {AGENT_DIR}; PS1='$ '; clear")
    time.sleep(0.8)
    # Relative interpreter so the recording shows `.venv/bin/python`, not an
    # absolute home path (falls back to absolute if it's outside AGENT_DIR).
    _rel = os.path.relpath(sys.executable, AGENT_DIR)
    py = _rel if not _rel.startswith("..") else sys.executable

    # asciinema records the tmux window headlessly (no controlling tty needed)
    # at a fixed size, so this runs the same from an automation context or a
    # real terminal. asciicast-v2 keeps agg + the trim logic happy.
    rec = subprocess.Popen(["asciinema", "rec", str(CAST_FILE), "--overwrite",
                            "--headless", "--window-size", f"{COLS}x{ROWS}",
                            "--output-format", "asciicast-v2",
                            "--idle-time-limit", "5",
                            "--command", f"tmux attach -t {SESSION}"])
    time.sleep(2.0)

    try:
        # Intro spotlight in the top pane.
        send_line(top, f"clear; {sys.executable} {SELF} spotlight allow")
        # Launch the assistant in the bottom pane (already in AGENT_DIR).
        send_line(bottom, f"DEMO_MODEL={DEMO_MODEL} {py} chat.py "
                          f"--persona bob --gateway {GATEWAY}")
        if not wait_for_text(bottom, BANNER_MARKER, timeout=40):
            print("chat.py banner never appeared — see the pane / logs.")
            return 1
        wait_for_prompt(bottom, "bob", timeout=40)
        time.sleep(2.0)

        current = "bob"
        for act in ACTS:
            if act["kind"] == "switch":
                current = act["persona"]
                send_line(bottom, f"switch {current}")
                wait_for_prompt(bottom, current, timeout=30)
                time.sleep(1.5)
                continue

            # Spotlight the governing policy, give viewers time to read it.
            send_line(top, f"clear; {sys.executable} {SELF} spotlight {act['spotlight']}")
            time.sleep(READ_POLICY)

            # Type the prompt into the chat and wait for the turn to finish.
            send_line(bottom, act["prompt"])

            if act["kind"] == "hil":
                _run_hil(top, bottom, act, current)
            else:
                wait_for_prompt(bottom, current)
                time.sleep(READ_RESPONSE)

        send_line(bottom, "quit")
        time.sleep(2.0)
    finally:
        time.sleep(1.0)
        rec.terminate()
        try:
            rec.wait(timeout=10)
        except subprocess.TimeoutExpired:
            rec.kill()
        if not no_cleanup:
            _cleanup_session()

    trim_cast_to_banner(CAST_FILE, BANNER_MARKER)
    convert()
    good = verify()
    print("\n✓ recording complete" if good else "\n⚠ recording done but markers missing")
    print(f"  cast: {CAST_FILE}")
    if GIF_FILE.exists():
        print(f"  gif:  {GIF_FILE}")
    if MP4_FILE.exists():
        print(f"  mp4:  {MP4_FILE}")
    return 0 if good else 2


def _run_hil(top: str, bottom: str, act: dict, persona: str) -> None:
    """The interactive HIL beat: request -> pending -> out-of-band approve ->
    the agent surfaces the approval on its own -> confirm -> applied."""
    # 1. Wait for the gateway to suspend the call (chat prints '⏳ pending').
    if not wait_for_text(bottom, "pending", timeout=RESPONSE_TIMEOUT):
        return
    wait_for_prompt(bottom, persona, timeout=30)
    time.sleep(READ_RESPONSE)

    # 2. The manager approves out-of-band (shown in the top pane).
    send_line(top, f"{sys.executable} {SELF} approve --approver alice")
    time.sleep(2.0)

    # 3. chat.py's background poller notices and the agent speaks up on its own
    #    (no user input needed) asking whether to apply. Wait for that.
    wait_for_text(bottom, "approved", timeout=HIL_WAIT)
    wait_for_prompt(bottom, persona, timeout=RESPONSE_TIMEOUT)
    time.sleep(READ_RESPONSE)

    # 4. Confirm — the agent re-sends the approved call and it applies.
    send_line(bottom, act["confirm"])
    wait_for_text(bottom, "applied", timeout=RESPONSE_TIMEOUT)
    wait_for_prompt(bottom, persona, timeout=30)
    time.sleep(READ_RESPONSE)


# --------------------------------------------------------------------------
# Cast trim + convert + verify
# --------------------------------------------------------------------------

def trim_cast_to_banner(cast_file: Path, marker: str) -> None:
    """Drop shell-init events so the banner is the first visible frame."""
    if not cast_file.exists():
        return
    lines = cast_file.read_text().splitlines()
    if len(lines) < 2:
        return
    header, events = lines[0], lines[1:]
    banner_idx = next((i for i, l in enumerate(events) if marker in l), None)
    if banner_idx is None:
        print(f"[trim] marker {marker!r} not found — skipping trim")
        return
    clear_idx = banner_idx
    for i in range(banner_idx - 1, -1, -1):
        if "\\u001b[H\\u001b[2J" in events[i] or "\\u001b[2J" in events[i]:
            clear_idx = i
            break
    kept = events[clear_idx:]
    first_ts = json.loads(kept[0])[0]
    rebased = []
    for line in kept:
        evt = json.loads(line)
        evt[0] = round(evt[0] - first_ts, 6)
        rebased.append(json.dumps(evt))
    cast_file.write_text(header + "\n" + "\n".join(rebased) + "\n")
    print(f"[trim] removed {len(events) - len(kept)} pre-banner events")


def convert() -> None:
    agg = subprocess.run(["which", "agg"], capture_output=True).returncode == 0
    if not agg:
        print("[convert] agg not found — cast recorded, GIF skipped "
              "(brew install agg / cargo install agg)")
        return
    subprocess.run(["agg", str(CAST_FILE), str(GIF_FILE),
                    "--theme", "dracula", "--font-size", "16",
                    "--renderer", "fontdue", "--speed", "0.75",
                    "--idle-time-limit", "10"], check=False)
    if subprocess.run(["which", "ffmpeg"], capture_output=True).returncode != 0:
        print("[convert] ffmpeg not found — MP4 skipped (GIF only)")
        return
    scale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    strategies = [
        ["-c:v", "libx265", "-preset", "slow", "-crf", "28", "-tune", "animation",
         "-pix_fmt", "yuv420p", "-tag:v", "hvc1"],
        ["-c:v", "libx264", "-preset", "slow", "-crf", "24", "-tune", "animation",
         "-pix_fmt", "yuv420p"],
        ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"],
        ["-pix_fmt", "yuv420p"],
    ]
    for strat in strategies:
        rc = subprocess.run(["ffmpeg", "-y", "-i", str(GIF_FILE), "-movflags",
                            "faststart", "-vf", scale, *strat, str(MP4_FILE)],
                            capture_output=True).returncode
        if rc == 0:
            return
    print("[convert] all ffmpeg strategies failed — GIF only")


def verify() -> bool:
    if not CAST_FILE.exists():
        print("[verify] no cast file")
        return False
    content = CAST_FILE.read_text()
    all_ok = True
    print("\n[verify] markers in the recording:")
    for marker, label in VERIFY_MARKERS:
        present = marker in content
        all_ok = all_ok and present
        print(f"  {'✓' if present else '✗'} {label}  ({marker!r})")
    return all_ok


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd")
    sp = sub.add_parser("spotlight", help="(internal) render a policy snippet")
    sp.add_argument("key", choices=list(SPOTLIGHTS))
    ap = sub.add_parser("approve", help="(internal) approve via the auth-channel")
    ap.add_argument("--approver", default="alice")

    p.add_argument("--record", action="store_true", help="record the demo")
    p.add_argument("--check", action="store_true", help="preflight only")
    p.add_argument("--gif-only", action="store_true", help="re-convert existing cast")
    p.add_argument("--verify", action="store_true", help="check markers in the cast")
    p.add_argument("--no-cleanup", action="store_true", help="keep the tmux session")
    args = p.parse_args()

    if args.cmd == "spotlight":
        render_spotlight(args.key)
        return 0
    if args.cmd == "approve":
        return do_approve(args.approver)
    if args.check:
        return 0 if preflight() else 1
    if args.gif_only:
        convert()
        return 0
    if args.verify:
        return 0 if verify() else 1
    if args.record:
        return record(no_cleanup=args.no_cleanup)
    p.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
