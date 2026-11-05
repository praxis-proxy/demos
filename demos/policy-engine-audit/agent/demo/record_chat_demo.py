#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
"""
Record the live praxis-audit chat demo (chat.py) as an asciinema cast / GIF / MP4.

Adapted from the praxis-proxy/demos policy-engine recorder. A real,
LLM-driven session runs in front of the Praxis gateway inside a three-pane
tmux layout, captured headlessly with asciinema:

  ┌──────────────────────────────────┬──────────────────────────────┐
  │ POLICY   the rule that governs   │ RECORDS  tools/watch-records │
  │          the next step           │          one signed OCSF     │
  │          (and the ledger receipt │          record per ruling,  │
  │          at the close)           │          as it lands         │
  ├──────────────────────────────────┴──────────────────────────────┤
  │ chat.py: the HR copilot talking to the gateway                   │
  └──────────────────────────────────────────────────────────────────┘

`--layout side` instead puts the chat on the right and stacks the policy
and records panes on the left, the arrangement used when presenting live:

  ┌──────────────────────────────┬──────────────────────────────────┐
  │ POLICY                       │                                  │
  ├──────────────────────────────┤ chat.py                          │
  │ RECORDS                      │                                  │
  └──────────────────────────────┴──────────────────────────────────┘

The four beats from CHAT.md, then the proof:
  1. Bob (HR) looks up compensation: allowed, token exchanged, four records.
  2. Alice (engineering) tries the same: denied before the HR system sees it.
  3. Bob emails the record outside: refused, the session is tainted `secret`.
  4. Eve (HR, no view_ssn) asks for the SSN: redacted in flight.
  5. The records are shipped to the ARE ledger and the receipt for the
     blocked email is verified on screen.

Usage (from the agent/ directory, with the stack up via ../run-demo.sh):
  python demo/record_chat_demo.py --check        # preflight only
  DEMO_MODEL=gpt-4o python demo/record_chat_demo.py --record
  DEMO_MODEL=gpt-4o python demo/record_chat_demo.py --record --layout side
  python demo/record_chat_demo.py --gif-only     # re-convert an existing .cast
  python demo/record_chat_demo.py --verify       # check the markers in the .cast
  python demo/record_chat_demo.py --no-cleanup   # keep the tmux session (debug)

  Internal subcommands the top panes run (not called by hand):
  python demo/record_chat_demo.py spotlight <key>
  python demo/record_chat_demo.py records [--width <cols>]
  python demo/record_chat_demo.py proof --since <n>   # the chat pane runs this at the close

Prerequisites:
  - ./run-demo.sh has run, so the gateway (:8090), Keycloak (cpex-demo realm,
    :8081), the HR MCP server (:9100), Valkey and the ARE ledger (:18080 /
    :19292) are up and out/gateway.stderr exists.
  - A model that tool-calls reliably (gpt-4o, a Claude model, a 70B-class
    model) in DEMO_MODEL, with its provider key exported.
  - tmux and asciinema on PATH; agg and ffmpeg for the GIF / MP4.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# --------------------------------------------------------------------------
# Paths and configuration
# --------------------------------------------------------------------------

SELF = Path(__file__).resolve()
AGENT_DIR = SELF.parent.parent            # .../agent
DEMO_DIR = AGENT_DIR.parent               # .../praxis-audit (or policy-engine-audit)
CHAT_PY = AGENT_DIR / "chat.py"
OUT_DIR = SELF.parent                     # .../agent/demo
CAST_FILE = OUT_DIR / "chat-demo.cast"
GIF_FILE = OUT_DIR / "chat-demo.gif"
MP4_FILE = OUT_DIR / "chat-demo.mp4"

# The ledger checkout: the demos port keeps it in .ledger/, the ledger repo
# has it two levels up.
LEDGER_REPO = DEMO_DIR / ".ledger" if (DEMO_DIR / ".ledger").is_dir() else DEMO_DIR.parent.parent
GATEWAY_STDERR = DEMO_DIR / "out" / "gateway.stderr"
BATCH_FILE = DEMO_DIR / "out" / "record-batch.ndjson"

SESSION = "praxis-audit-chat-demo"
COLS, ROWS = 160, 48
# stacked: chat across the bottom, policy top-left, records top-right.
CHAT_ROWS = 28                            # bottom pane height; the top row gets the rest
RECORDS_COLS = 90                         # top-right pane width; the policy pane gets the rest
# side: chat down the right, policy above records on the left.
SIDE_CHAT_COLS = 88                       # right pane width; the left column gets the rest
SIDE_RECORDS_ROWS = 27                    # bottom-left pane height; the policy pane gets the rest
LAYOUTS = ("stacked", "side")

GATEWAY = os.environ.get("PRAXIS_URL", "http://localhost:8090/mcp")
KEYCLOAK = os.environ.get("KEYCLOAK_URL", "http://localhost:8081")
REALM = os.environ.get("KEYCLOAK_REALM", "cpex-demo")
HR_MCP = os.environ.get("HR_MCP_URL", "http://127.0.0.1:9100")
LEDGER_HEALTH = os.environ.get("LEDGER_HEALTH", "http://localhost:18080")
LEDGER_GRPC = os.environ.get("LEDGER_GRPC", "localhost:19292")
DEMO_MODEL = os.environ.get("DEMO_MODEL", "ollama/qwen3:8b")
BANNER_MARKER = "Praxis Policy Engine HR Demo"

# Timing (seconds).
READ_POLICY = 6.0        # let viewers read the spotlighted policy
READ_RESPONSE = 6.0      # let viewers read the agent's answer and the records
AFTER_SEND_MIN = 2.0     # settle before watching for the prompt
RESPONSE_TIMEOUT = 100   # LLM completion + gateway round-trip
BANNER_TIMEOUT = 90      # litellm import + Keycloak token mint before chat.py's banner
PROOF_TIMEOUT = 60       # adapter + ledger verification at the close

# --------------------------------------------------------------------------
# ANSI helpers (spotlight rendering)
# --------------------------------------------------------------------------

RESET = "\033[0m"
GRAY = "\033[90m"
CYAN = "\033[1;96m"
YELLOW = "\033[1;93m"
GREEN = "\033[1;92m"
RED = "\033[1;91m"
BOX_WIDTH = 64


def _c(text: str, color: str) -> str:
    return f"{color}{text}{RESET}"


# --------------------------------------------------------------------------
# The acts: persona, prompt, the policy to spotlight, and expected markers
# --------------------------------------------------------------------------
#
# Each spotlight is a snippet of config/policy.yaml (verbatim) plus a caption.
# The captions name what the RECORDS pane shows, since that pane is the point
# of this demo: every ruling becomes a signed, chained OCSF record.

SPOTLIGHTS: dict[str, dict[str, str]] = {
    "allow": {
        "title": "get_compensation: allow, with evidence",
        "yaml": (
            "routes:\n"
            "  - tool: get_compensation\n"
            "    authorization:\n"
            "      pre_invocation:\n"
            '        - "require(role.hr)"\n'
            '        - "delegate(workday-oauth, target: workday-api,\n'
            '                    audience: workday-api,\n'
            '                    permissions: [read_compensation])"\n'
            '        - "taint(secret, session)"\n'
            "\n"
            "plugins:\n"
            "  - name: ocsf-audit    # the sink: records EVERY verdict\n"
            "    kind: audit/ocsf\n"
            "    config: { chain: true, signing: dsse }"
        ),
        "caption": "Bob is HR: allowed. His token is exchanged for a workday-api token "
        "(RFC 8693) and the session is tainted 'secret'. One call, four signed "
        "records on the right: identity, token exchange, authorize, response.",
    },
    "deny": {
        "title": "get_compensation: denied before the HR system sees it",
        "yaml": (
            "  - tool: get_compensation\n"
            "    authorization:\n"
            "      pre_invocation:\n"
            '        - "require(role.hr)"            # <- gate #1'
        ),
        "caption": "Alice is engineering, not HR. require(role.hr) denies at the "
        "cheapest layer: no token exchange, no backend call. The deny is itself "
        "a signed record (red, on the right), with the rule that fired.",
    },
    "taint": {
        "title": "send_email: exfiltration blocked by session taint",
        "yaml": (
            "  - tool: get_compensation\n"
            "    authorization:\n"
            "      pre_invocation:\n"
            '        - "taint(secret, session)"   # <- ran a moment ago\n'
            "\n"
            "  - tool: send_email\n"
            "    authorization:\n"
            "      pre_invocation:\n"
            '        - "require(perm.email_send)"\n'
            "        - \"security.labels contains \\\"secret\\\":\n"
            "             deny('external email blocked: this session\n"
            "                   accessed secret data',\n"
            "                   'session_tainted_secret')\""
        ),
        "caption": "This session already read secret compensation data, so it carries "
        "the 'secret' label. Emailing anything out is refused even with a clean "
        "body, and the refusal is on record before the HR outbox is touched.",
    },
    "redact": {
        "title": "get_compensation: SSN redacted in flight",
        "yaml": (
            "  - tool: get_compensation\n"
            "    result:\n"
            '      ssn: "str | redact(!perm.view_ssn)"\n'
            "\n"
            "engine_settings:\n"
            "  capture_content_provenance: true  # entry + emission digests"
        ),
        "caption": "Eve is HR but lacks view_ssn. The gateway rewrites the response: "
        "the agent only ever sees ssn = [REDACTED]. The record shows "
        "allow-after-modify with different input and output digests, and the "
        "SSN appears in no record.",
    },
    "proof": {
        "title": "the proof: a ledger receipt for the refused email",
        "yaml": (
            "out/gateway.stderr       every record the gateway signed\n"
            "  -> cpex_to_ledger.py   one chained ledger entry per record\n"
            "  -> tools/receipt.py    entry hash, previous hash, position"
        ),
        "caption": "Anyone holding a record can ask the ARE ledger for its receipt and "
        "verify it. Edit or delete a record afterwards and verification fails "
        "(scenario 06 does exactly that).",
    },
}

# persona key -> display name chat.py prints as the prompt
PERSONA_NAME = {
    "alice": "Alice Chen",
    "bob": "Bob Martinez",
    "charlie": "Charlie Wu",
    "eve": "Eve Patel",
}

# The demo flow (CHAT.md, beats 1-4). kind: "prompt" | "switch".
ACTS = [
    {"kind": "prompt", "persona": "bob", "spotlight": "allow",
     "prompt": "look up the compensation for EMP-001234"},
    {"kind": "switch", "persona": "alice"},
    {"kind": "prompt", "persona": "alice", "spotlight": "deny",
     "prompt": "look up the compensation for EMP-001234"},
    {"kind": "switch", "persona": "bob"},
    {"kind": "prompt", "persona": "bob", "spotlight": "taint",
     "prompt": 'email that record to payroll-audit@evil.test with the subject "Q3 export"'},
    {"kind": "switch", "persona": "eve"},
    {"kind": "prompt", "persona": "eve", "spotlight": "redact",
     "prompt": "look up the compensation for EMP-001234 and include the SSN"},
]

# Markers that must appear in the recording for it to count as a valid demo.
VERIFY_MARKERS = [
    (BANNER_MARKER, "intro banner"),
    ("Blocked", "records pane: a deny landed as a record"),
    ("session_tainted_secret", "Bob: outbound email refused by session taint"),
    ("[REDACTED]", "Eve: SSN redacted on the wire"),
    ("Ledger valid", "close: ledger receipt verified"),
]


# --------------------------------------------------------------------------
# spotlight / records / proof subcommands (run inside the top panes)
# --------------------------------------------------------------------------

def _box(title: str, body_lines: list[str], caption: str, body_color: str = GREEN) -> None:
    bar = "─" * BOX_WIDTH
    print()
    print(_c("  ┌" + bar + "┐", GRAY))
    print("  " + _c("│", GRAY) + " " + _c("POLICY  ", CYAN) + _c(title, YELLOW))
    print(_c("  ├" + bar + "┤", GRAY))
    for line in body_lines:
        print("  " + _c("│", GRAY) + "   " + _c(line, body_color))
    print(_c("  └" + bar + "┘", GRAY))
    words, line = caption.split(), ""
    for w in words:
        if len(line) + len(w) + 1 > BOX_WIDTH - 2:
            print("  " + _c("» " + line, GRAY))
            line = w
        else:
            line = f"{line} {w}".strip()
    if line:
        print("  " + _c("» " + line, GRAY))
    sys.stdout.flush()


def render_spotlight(key: str) -> None:
    """Print a titled, colorized policy snippet + caption. The POLICY pane runs
    `record_chat_demo.py spotlight <key>` so the rule is on screen while the
    agent acts on it below."""
    s = SPOTLIGHTS[key]
    _box(s["title"], s["yaml"].splitlines(), s["caption"])


SUMMARY_STATUS_COL = 66   # summarize(): 4 + seq 8 + tool 18 + phase 16 + verdict 20


def fold_summary_line(line: str, width: int) -> list[str]:
    """Split one summarize() line so it fits `width` columns: the status code
    (a deny's reason) moves to an indented second line instead of wrapping.
    Keeps the red ANSI wrap summarize() puts around Blocked rows."""
    prefix, suffix = "", ""
    if line.startswith("\x1b[91m") and line.endswith("\x1b[0m"):
        prefix, suffix = "\x1b[91m", "\x1b[0m"
        line = line[len(prefix):-len(suffix)]
    if len(line) <= width or len(line) <= SUMMARY_STATUS_COL:
        return [prefix + line + suffix]
    head, status = line[:SUMMARY_STATUS_COL].rstrip(), line[SUMMARY_STATUS_COL:].strip()
    return [prefix + head + suffix, prefix + " " * 12 + status + suffix]


def run_records(width: int = 0) -> int:
    """Follow the gateway's OCSF records as they land, one summary line per
    ruling, reusing summarize() from scenarios/_lib.sh (the same shape the
    scenarios and tools/watch-records.sh print). Prints its own header so the
    recording carries no absolute path. With --width, lines that would wrap
    are folded instead."""
    print()
    print("  " + _c("RECORDS  ", CYAN) + _c("one signed, chained OCSF record per ruling", YELLOW))
    print("  " + _c("seq      tool              phase           verdict", GRAY))
    sys.stdout.flush()
    # jq fully buffers when its stdout is a pipe (it is one here), so wrap it.
    script = (
        'cd "$1" && source scenarios/_lib.sh && '
        'jq() { command jq --unbuffered "$@"; } && '
        'tail -n 0 -F "$GATEWAY_STDERR" | grep --line-buffered "^{" | summarize'
    )
    proc = subprocess.Popen(["bash", "-c", script, "_", str(DEMO_DIR)],
                            stdout=subprocess.PIPE, text=True, bufsize=1)
    assert proc.stdout is not None
    try:
        for raw in iter(proc.stdout.readline, ""):
            line = raw.rstrip("\n")
            for out in (fold_summary_line(line, width) if width else [line]):
                print(out, flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
    return proc.wait()


def _records_since(mark: int) -> list[dict]:
    if not GATEWAY_STDERR.exists():
        return []
    lines = [l for l in GATEWAY_STDERR.read_text().splitlines() if l.startswith("{")]
    out = []
    for line in lines[mark:]:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def _records_mark() -> int:
    if not GATEWAY_STDERR.exists():
        return 0
    return sum(1 for l in GATEWAY_STDERR.read_text().splitlines() if l.startswith("{"))


def run_proof(since: int) -> int:
    """The close, run in the chat pane after `quit`: ship the records this chat
    produced to the ARE ledger through the CPEX adapter, then verify the
    receipt for the blocked email."""
    records = _records_since(since)
    if not records:
        print("  " + _c("✗ no records written since the recording started", RED))
        return 1
    BATCH_FILE.parent.mkdir(parents=True, exist_ok=True)
    BATCH_FILE.write_text("".join(json.dumps(r) + "\n" for r in records))
    env = dict(os.environ)
    env["PYTHONPATH"] = str(LEDGER_REPO / "sdks" / "python") + (
        ":" + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    adapter = subprocess.run(
        [sys.executable, str(LEDGER_REPO / "adapters" / "cpex" / "cpex_to_ledger.py"),
         "--endpoint", LEDGER_GRPC, "--file", str(BATCH_FILE)],
        capture_output=True, text=True, env=env, check=False)
    if adapter.returncode != 0:
        print("  " + _c("✗ adapter failed:", RED))
        print(adapter.stdout[-1500:], adapter.stderr[-1500:])
        return 1

    blocked = [r for r in records if r.get("disposition") == "Blocked"]
    target = next((r for r in reversed(blocked)
                   if (r.get("tool") or {}).get("name") == "send_email"), None)
    target = target or (blocked[-1] if blocked else records[-1])
    uid = target["metadata"]["uid"]
    print()
    print("  " + _c(f"✓ {len(records)} records from this chat shipped to the ARE ledger, "
                    "one chained entry each", GREEN))
    print("  " + _c(f"receipt for the refused send_email (metadata.uid {uid}):", GRAY))
    print()
    sys.stdout.flush()
    receipt = subprocess.run(
        [sys.executable, str(DEMO_DIR / "tools" / "receipt.py"),
         "--uid", uid, "--endpoint", LEDGER_GRPC], env=env, check=False)
    sys.stdout.flush()
    return receipt.returncode


# --------------------------------------------------------------------------
# tmux plumbing
# --------------------------------------------------------------------------

def tmux(*args: str, check: bool = True, capture: bool = False):
    return subprocess.run(["tmux", *args], check=check, capture_output=capture, text=True)


def pane_ids(layout: str = "stacked") -> tuple[str, str, str]:
    """Return (policy, records, chat) pane ids by position, robust to any tmux
    base-index configuration. stacked: chat is the lowest pane, policy the
    top-left, records the top-right. side: chat is the rightmost pane, policy
    the upper-left, records the lower-left."""
    out = tmux("list-panes", "-t", SESSION, "-F", "#{pane_top} #{pane_left} #{pane_id}",
               capture=True).stdout.strip().splitlines()
    panes = [(int(t), int(l), pid) for t, l, pid in (line.split() for line in out)]
    if layout == "side":
        chat = max(panes, key=lambda p: p[1])
        column = sorted((p for p in panes if p is not chat), key=lambda p: p[0])
    else:
        chat = max(panes, key=lambda p: p[0])
        column = sorted((p for p in panes if p is not chat), key=lambda p: p[1])
    return column[0][2], column[-1][2], chat[2]


def build_layout(layout: str) -> tuple[str, str, str, int]:
    """Create the tmux session and panes. Returns the (policy, records, chat)
    pane ids and the records pane's width."""
    tmux("new-session", "-d", "-s", SESSION, "-x", str(COLS), "-y", str(ROWS))
    if layout == "side":
        tmux("split-window", "-h", "-t", SESSION, "-l", str(SIDE_CHAT_COLS))     # right: chat
        policy, _, _ = pane_ids(layout)
        tmux("split-window", "-v", "-t", policy, "-l", str(SIDE_RECORDS_ROWS))  # lower-left: records
        records_width = COLS - SIDE_CHAT_COLS - 1
    else:
        tmux("split-window", "-v", "-t", SESSION, "-l", str(CHAT_ROWS))         # bottom: chat
        policy, _, _ = pane_ids(layout)
        tmux("split-window", "-h", "-t", policy, "-l", str(RECORDS_COLS))       # top-right: records
        records_width = RECORDS_COLS
    policy, records, chat = pane_ids(layout)
    return policy, records, chat, records_width


def send_line(pane: str, text: str) -> None:
    tmux("send-keys", "-t", pane, "-l", text)
    tmux("send-keys", "-t", pane, "Enter")


def capture(pane: str) -> str:
    return tmux("capture-pane", "-t", pane, "-p", capture=True).stdout


def wait_for_prompt(pane: str, persona: str, timeout: float = RESPONSE_TIMEOUT) -> bool:
    """Wait until the chat pane is back at the persona's input prompt (e.g.
    'Bob Martinez:'), stable for two consecutive reads. chat.py does not stream
    tokens, so this is the reliable 'turn finished' signal."""
    name = PERSONA_NAME[persona]
    time.sleep(AFTER_SEND_MIN)
    deadline = time.time() + timeout
    stable = 0
    while time.time() < deadline:
        lines = [l for l in capture(pane).splitlines() if l.strip()]
        last = lines[-1].strip() if lines else ""
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
        urllib.request.urlopen(url, timeout=4)  # noqa: S310 (localhost dev)
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
        check(f"{tool} on PATH", shutil.which(tool) is not None, f"brew install {tool}")
    for tool in ("agg", "ffmpeg"):
        present = shutil.which(tool) is not None
        print(f"  {'✓' if present else '·'} {tool} on PATH"
              + ("" if present else f"   (optional, needed for GIF/MP4: brew install {tool})"))
    check(f"gateway {GATEWAY}", _reachable(GATEWAY.rsplit("/", 1)[0]),
          "run ../run-demo.sh first (or ../tools/gateway.sh start)")
    check(f"Keycloak {REALM} realm",
          _reachable(f"{KEYCLOAK}/realms/{REALM}/.well-known/openid-configuration"))
    check(f"HR MCP server {HR_MCP}", _reachable(f"{HR_MCP}/healthz"))
    check(f"ARE ledger {LEDGER_HEALTH}", _reachable(f"{LEDGER_HEALTH}/readyz"))
    check("gateway records file out/gateway.stderr", GATEWAY_STDERR.exists(),
          "the records pane follows it; start the gateway")
    check("ledger checkout (adapters/cpex, sdks/python)",
          (LEDGER_REPO / "adapters" / "cpex" / "cpex_to_ledger.py").exists()
          and (LEDGER_REPO / "sdks" / "python").is_dir(),
          "run tools/fetch-ledger.sh" if (DEMO_DIR / "tools" / "fetch-ledger.sh").exists()
          else f"expected at {LEDGER_REPO}")
    try:
        import grpc  # noqa: F401
        import litellm  # noqa: F401
        import rich  # noqa: F401
        deps = True
    except ImportError:
        deps = False
    check("python deps (litellm, rich, grpcio) in this interpreter", deps,
          "activate the chat venv; pip install -r requirements.txt and the adapter's")

    weak = DEMO_MODEL.startswith("ollama/")
    print(f"  {'·' if weak else '✓'} model: {DEMO_MODEL}"
          + ("   (local models often drop tool calls; set DEMO_MODEL=gpt-4o or a Claude model)"
             if weak else ""))
    return ok


# --------------------------------------------------------------------------
# Record
# --------------------------------------------------------------------------

def _cleanup_session() -> None:
    subprocess.run(["tmux", "kill-session", "-t", SESSION], capture_output=True)


def _python_for_pane() -> str:
    """How the chat pane launches chat.py. `python` when it resolves to this
    interpreter (an activated venv), so no home path lands in the recording."""
    for name in ("python", "python3"):
        found = shutil.which(name)
        if found and Path(found).resolve() == Path(sys.executable).resolve():
            return name
    rel = os.path.relpath(sys.executable, AGENT_DIR)
    return rel if not rel.startswith("..") else sys.executable


def record(no_cleanup: bool = False, layout: str = "stacked") -> int:
    if not preflight():
        print("\nPreflight failed: fix the above and retry.")
        return 1
    print()

    _cleanup_session()
    policy, records, chat, records_width = build_layout(layout)

    # Position and quiet the panes BEFORE recording so none of this setup (nor
    # any absolute home path) is captured. The two top panes get a blank
    # prompt with no input echo, so only their output shows. The chat pane
    # keeps echo on with a short prompt so the typed prompts stay visible.
    # The pane shells are fresh login shells, and macOS's path_helper (or a
    # .zshrc) can reorder PATH so the venv no longer comes first; put this
    # interpreter's bin directory back in front so `python` is the venv's.
    # sys.prefix is the venv itself (not resolved: the venv's python is a
    # symlink to the base interpreter, whose bin has none of the deps).
    venv_bin = Path(sys.prefix) / "bin" if (Path(sys.prefix) / "bin").is_dir() \
        else Path(sys.executable).parent
    send_line(policy, "stty -echo; PS1=''; clear")
    send_line(records, "stty -echo; PS1=''; clear")
    send_line(chat, f"cd {AGENT_DIR}; export PATH=\"{venv_bin}:$PATH\"; PS1='$ '; clear")
    time.sleep(1.5)
    py = _python_for_pane()
    mark = _records_mark()

    # asciinema records the tmux window headlessly at a fixed size, so this
    # runs the same from an automation context or a real terminal.
    rec = subprocess.Popen(["asciinema", "rec", str(CAST_FILE), "--overwrite",
                            "--headless", "--window-size", f"{COLS}x{ROWS}",
                            "--output-format", "asciicast-v2",
                            "--idle-time-limit", "5",
                            "--command", f"tmux attach -t {SESSION}"])
    time.sleep(2.0)

    try:
        send_line(records, f"clear; {sys.executable} {SELF} records --width {records_width - 1}")
        send_line(policy, f"clear; {sys.executable} {SELF} spotlight allow")
        send_line(chat, f"DEMO_MODEL={DEMO_MODEL} {py} chat.py --persona bob")
        if not wait_for_text(chat, BANNER_MARKER, timeout=BANNER_TIMEOUT):
            print(f"chat.py banner never appeared within {BANNER_TIMEOUT}s. The chat pane shows:")
            print("-" * 72)
            print("\n".join(l for l in capture(chat).splitlines() if l.strip()) or "(nothing)")
            print("-" * 72)
            return 1
        wait_for_prompt(chat, "bob", timeout=40)
        time.sleep(2.0)

        current = "bob"
        for act in ACTS:
            if act["kind"] == "switch":
                current = act["persona"]
                send_line(chat, f"switch {current}")
                wait_for_prompt(chat, current, timeout=30)
                time.sleep(1.5)
                continue

            # Spotlight the governing policy, give viewers time to read it.
            send_line(policy, f"clear; {sys.executable} {SELF} spotlight {act['spotlight']}")
            time.sleep(READ_POLICY)

            # Type the prompt into the chat and wait for the turn to finish.
            send_line(chat, act["prompt"])
            wait_for_prompt(chat, current)
            time.sleep(READ_RESPONSE)

        # The close: quit the chat, then in the same (full-width) pane ship the
        # chat's records and verify one receipt on screen.
        send_line(policy, f"clear; {sys.executable} {SELF} spotlight proof")
        time.sleep(READ_POLICY / 2)
        send_line(chat, "quit")
        time.sleep(2.0)
        send_line(chat, f"clear; {py} demo/record_chat_demo.py proof --since {mark}")
        wait_for_text(chat, "Ledger valid", timeout=PROOF_TIMEOUT)
        time.sleep(READ_RESPONSE * 2)
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
        print(f"[trim] marker {marker!r} not found, skipping trim")
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
    if shutil.which("agg") is None:
        print("[convert] agg not found: cast recorded, GIF skipped (brew install agg)")
        return
    subprocess.run(["agg", str(CAST_FILE), str(GIF_FILE),
                    "--theme", "dracula", "--font-size", "16",
                    "--renderer", "fontdue", "--speed", "0.75",
                    "--idle-time-limit", "10"], check=False)
    if shutil.which("ffmpeg") is None:
        print("[convert] ffmpeg not found: MP4 skipped (GIF only)")
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
    print("[convert] all ffmpeg strategies failed: GIF only")


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
    rp = sub.add_parser("records", help="(internal) follow the gateway's records")
    rp.add_argument("--width", type=int, default=0, help="fold lines wider than this")
    pr = sub.add_parser("proof", help="(internal) ship records and verify a receipt")
    pr.add_argument("--since", type=int, default=0,
                    help="record count when the recording started")

    p.add_argument("--record", action="store_true", help="record the demo")
    p.add_argument("--check", action="store_true", help="preflight only")
    p.add_argument("--gif-only", action="store_true", help="re-convert existing cast")
    p.add_argument("--verify", action="store_true", help="check markers in the cast")
    p.add_argument("--no-cleanup", action="store_true", help="keep the tmux session")
    p.add_argument("--layout", choices=LAYOUTS, default="stacked",
                   help="stacked: chat below policy and records (default); "
                        "side: chat on the right, policy above records on the left")
    args = p.parse_args()

    if args.cmd == "spotlight":
        render_spotlight(args.key)
        return 0
    if args.cmd == "records":
        return run_records(args.width)
    if args.cmd == "proof":
        return run_proof(args.since)
    if args.check:
        return 0 if preflight() else 1
    if args.gif_only:
        convert()
        return 0
    if args.verify:
        return 0 if verify() else 1
    if args.record:
        return record(no_cleanup=args.no_cleanup, layout=args.layout)
    p.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
