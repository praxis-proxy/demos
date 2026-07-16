#!/usr/bin/env python3
"""
End-to-end demo harness for the AuthPolicy transpiler (CLI pathway).

  Record:   python demo/record_e2e_demo.py --record     # .cast -> GIF (+ MP4)
  Run acts: python demo/record_e2e_demo.py --run-acts    # the recorded command
  GIF only: python demo/record_e2e_demo.py --gif-only
  Verify:   python demo/record_e2e_demo.py --verify

Unlike record_demo.py (which shows the transpiler CLI), this drives the real
`e2e/run-demo.sh`: it transpiles jwt-cel-http.yaml, runs the emitted CPEX policy
on a live Praxis gateway against a local Keycloak, and proves the CEL decisions
with alice/bob persona tokens. Requires docker + a Praxis checkout/binary.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
E2E_DIR = REPO_ROOT / "e2e"
RUN_DEMO = E2E_DIR / "run-demo.sh"
DEMO_DIR = REPO_ROOT / "demo"
CAST_FILE = DEMO_DIR / "e2e.cast"
GIF_FILE = DEMO_DIR / "e2e.gif"
MP4_FILE = DEMO_DIR / "e2e.mp4"

# Prebuilt Praxis binary → build-praxis.sh path 1 ("prebuilt wins"), so the
# recording skips cargo entirely and shows a clean absolute path.
_PRAXIS_CANDIDATE = (REPO_ROOT / ".." / ".." / ".." / "praxis"
                     / "target" / "release" / "praxis").resolve()

BANNER_MARKER = "end-to-end on Praxis"

INPUT_YAML = "examples/jwt-cel-http.yaml"
OUTPUT_YAML = "e2e/out/jwt-cel-http-cpex-policy.yaml"

_TIMED = False


def _demo_env() -> dict:
    env = {**os.environ}
    if _PRAXIS_CANDIDATE.exists():
        env["PRAXIS_BIN"] = str(_PRAXIS_CANDIDATE)
    return env


# -----------------------------------------------------------------------------
# Terminal helpers
# -----------------------------------------------------------------------------
def pause(seconds: float) -> None:
    if _TIMED:
        time.sleep(seconds)


def _type(text: str, delay: float = 0.04) -> None:
    if _TIMED:
        for ch in text:
            sys.stdout.write(ch)
            sys.stdout.flush()
            time.sleep(delay)
    else:
        sys.stdout.write(text)
        sys.stdout.flush()


def section(title: str) -> None:
    bar_len = max(76, len(title) + 6)
    bar = "─" * bar_len
    sys.stdout.write(f"\n\n\033[90m{bar}\033[0m\n")
    sys.stdout.write(f"\033[1;96m  {title}\033[0m\n")
    sys.stdout.write(f"\033[90m{bar}\033[0m\n")
    sys.stdout.flush()


def _run(cmd: str) -> None:
    """Show a typed `$` prompt, then run the command from the repo root."""
    _type("\n\033[1;32m$\033[0m ", delay=0)
    _type(cmd + "\n", delay=0.035)
    pause(0.4)
    subprocess.run(cmd, cwd=REPO_ROOT, env=_demo_env(), shell=True,
                   capture_output=False, text=True)


def banner() -> None:
    W = 76

    def row(text: str = "", style: str = "") -> str:
        content = (" " + text).ljust(W)
        return f"\033[90m  ║\033[0m{style}{content}\033[0m\033[90m║\033[0m"

    lines = [
        f"\033[90m  ╔{'═' * W}╗\033[0m",
        row("authpolicy-transpiler  ·  end-to-end on Praxis + CPEX", "\033[1;96m"),
        row(),
        row("Proves the transpiled policy actually enforces: one command", "\033[90m"),
        row("transpiles jwt-cel-http.yaml, runs the emitted CPEX policy on a", "\033[90m"),
        row("real Praxis gateway against a local Keycloak, and checks the CEL", "\033[90m"),
        row("decisions with alice/bob persona tokens.", "\033[90m"),
        row(),
        row("`./run-demo.sh` does, in one shot:", "\033[97m"),
        row("  1. Start Keycloak (docker) + wait for OIDC discovery", "\033[90m"),
        row("  2. Transpile the AuthPolicy → CPEX policy + Praxis filter", "\033[90m"),
        row("  3. Inject a localhost-dev JWKS shim (never in prod)", "\033[90m"),
        row("  4. Resolve the Praxis binary (cpex-policy-engine)", "\033[90m"),
        row("  5. Start the echo backend + the gateway", "\033[90m"),
        row("  6. Mint alice/bob tokens + exercise the CEL policy", "\033[90m"),
        f"\033[90m  ╚{'═' * W}╝\033[0m",
    ]
    print("\n" + "\n".join(lines) + "\n")


def results_matrix() -> None:
    """Interpreted decision matrix (matches what run-demo.sh just verified)."""
    C = "\033[1;96m"
    G = "\033[1;32m"
    R = "\033[1;31m"
    D = "\033[90m"
    X = "\033[0m"
    rows = [
        ("GET  /api/widgets", "alice (engineer)", G, "200", "has tool_execute permission"),
        ("GET  /api/widgets", "bob (hr)        ", G, "200", "has tool_execute permission"),
        ("POST /api/widgets", "alice (engineer)", R, "403", "CEL deny — not in the hr role"),
        ("POST /api/widgets", "bob (hr)        ", G, "200", "CEL allow — in the hr role"),
        ("GET  /api/widgets", "(no token)      ", R, "401", "identity gate — unauthenticated"),
    ]
    sys.stdout.write(f"\n{C}  Transpiled CEL policy, enforced live on Praxis:{X}\n\n")
    sys.stdout.write(f"{D}  Request             Persona            Result   Why{X}\n")
    sys.stdout.write(f"{D}  ─────────────────── ────────────────── ──────── ─────────────────────────────{X}\n")
    for req, persona, color, code, why in rows:
        sys.stdout.write(
            f"  {req}   {persona}   {color}{code}{X}      {D}{why}{X}\n"
        )
    sys.stdout.flush()


# -----------------------------------------------------------------------------
# Acts
# -----------------------------------------------------------------------------
def run_demo_acts() -> None:
    banner()
    pause(12.0)

    section("1. The input: the original Kuadrant AuthPolicy")
    _type("\033[90m  Two CEL rules — GET needs the tool_execute permission, "
          "POST needs the hr role.\033[0m\n")
    _run(f"cat {INPUT_YAML}")
    pause(13.0)

    section("2. Run it: transpile → deploy on Praxis → prove the decisions")
    _run("./e2e/run-demo.sh")
    pause(8.0)

    section("3. The deployed output: the CPEX policy Praxis actually loaded")
    _type("\033[90m  identity/jwt plugin + require(authenticated) gate + one "
          "cel: step per rule.\033[0m\n"
          "\033[90m  (insecure_http on the JWKS URL is the localhost-dev shim "
          "the runner injected.)\033[0m\n")
    _run(f"cat {OUTPUT_YAML}")
    pause(14.0)

    section("4. What those five checks proved")
    results_matrix()
    pause(13.0)

    sys.stdout.write(
        "\n\n\033[1;32m  ══════════════════════════════════════════════════════════════\033[0m\n"
        "\033[1;32m  ✓  End-to-end verified — the transpiled policy enforces on Praxis\033[0m\n"
        "\033[1;32m  ══════════════════════════════════════════════════════════════\033[0m\n"
        "\n"
        "     Reproduce:  cd e2e && ./run-demo.sh\n"
        "     Transpiler only:  cargo run -- examples/jwt-cel-http.yaml\n"
        "\n"
    )
    pause(6.0)


# -----------------------------------------------------------------------------
# Recording pipeline
# -----------------------------------------------------------------------------
def _resolve(*names: str) -> str | None:
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    return None


def trim_cast_to_banner(cast_file: Path, banner_marker: str) -> None:
    lines = cast_file.read_text().splitlines()
    if len(lines) < 2:
        return
    header, events = lines[0], lines[1:]
    banner_idx = next((i for i, l in enumerate(events) if banner_marker in l), None)
    if banner_idx is None:
        print(f"[trim] marker {banner_marker!r} not found — skipping trim")
        return
    clear_idx = banner_idx
    for i in range(banner_idx - 1, -1, -1):
        if "\\u001b[H\\u001b[2J" in events[i] or "\\u001b[2J" in events[i]:
            clear_idx = i
            break
    kept = events[clear_idx:]
    if not kept:
        return
    first_ts = json.loads(kept[0])[0]
    rebased = []
    for line in kept:
        evt = json.loads(line)
        evt[0] = round(evt[0] - first_ts, 6)
        rebased.append(json.dumps(evt))
    cast_file.write_text(header + "\n" + "\n".join(rebased) + "\n")
    print(f"[trim] Removed {len(events) - len(kept)} events before banner "
          f"(kept {len(kept)})")


def convert(cast_file: Path) -> None:
    agg = _resolve("agg")
    if not agg:
        print("[demo] agg not found — cast recorded but GIF skipped")
        return
    subprocess.run([
        agg, str(cast_file), str(GIF_FILE),
        "--theme", "dracula",
        "--font-size", "16",
        "--renderer", "fontdue",
        "--speed", "0.75",
        "--idle-time-limit", "10",
        "--last-frame-duration", "5",
    ], check=True)
    print(f"[demo] GIF → {GIF_FILE}")

    ffmpeg = _resolve("ffmpeg")
    if not ffmpeg:
        print("[demo] ffmpeg not found — MP4 skipped (GIF only)")
        return
    scale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    strategies = [
        [ffmpeg, "-y", "-i", str(GIF_FILE), "-movflags", "faststart", "-vf", scale,
         "-c:v", "libx265", "-preset", "slow", "-crf", "28", "-tune", "animation",
         "-pix_fmt", "yuv420p", "-tag:v", "hvc1", str(MP4_FILE)],
        [ffmpeg, "-y", "-i", str(GIF_FILE), "-movflags", "faststart", "-vf", scale,
         "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-tune", "animation",
         "-pix_fmt", "yuv420p", str(MP4_FILE)],
        [ffmpeg, "-y", "-i", str(GIF_FILE), "-movflags", "faststart", "-vf", scale,
         "-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p",
         "-color_range", "tv", str(MP4_FILE)],
        [ffmpeg, "-y", "-i", str(GIF_FILE), "-vf", scale, "-pix_fmt", "yuv420p",
         str(MP4_FILE)],
    ]
    for strat in strategies:
        if subprocess.run(strat, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0:
            print(f"[demo] MP4 → {MP4_FILE}")
            return
    print("[demo] MP4 conversion failed (GIF still available)")


def record() -> None:
    asciinema = _resolve("asciinema")
    if not asciinema:
        sys.exit("[demo] asciinema not found — install: brew install asciinema")
    if not RUN_DEMO.exists():
        sys.exit(f"[demo] {RUN_DEMO} not found")
    DEMO_DIR.mkdir(exist_ok=True)
    if CAST_FILE.exists():
        CAST_FILE.unlink()
    subprocess.run([
        asciinema, "rec", str(CAST_FILE),
        "--command", f"{sys.executable} {__file__} --run-acts",
        "--window-size", "160x44",
        "--capture-env", "TERM,COLORTERM",
        "--headless",
    ], cwd=REPO_ROOT, check=True)
    trim_cast_to_banner(CAST_FILE, BANNER_MARKER)
    convert(CAST_FILE)


def verify() -> bool:
    if not CAST_FILE.exists():
        print("[verify] no cast file")
        return False
    content = CAST_FILE.read_text()
    checks = [
        ("end-to-end on Praxis", "banner present"),
        ("kind: AuthPolicy", "act 1: original AuthPolicy shown"),
        ("Keycloak realm", "act 2: Keycloak up"),
        ("gateway listening", "act 2: gateway started"),
        ("minted alice", "act 2: tokens minted"),
        ("All CEL policy checks passed", "act 2: all 5 checks passed"),
        ("kind: identity/jwt", "act 3: deployed CPEX policy shown"),
        ("insecure_http: true", "act 3: JWKS shim visible in output"),
        ("CEL deny", "act 4: results matrix rendered"),
    ]
    ok = True
    for fragment, label in checks:
        present = fragment in content
        print(f"  [{'ok ' if present else 'MISS'}] {label}")
        ok = ok and present
    return ok


# -----------------------------------------------------------------------------
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AuthPolicy transpiler e2e demo recorder")
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--run-acts", action="store_true")
    parser.add_argument("--gif-only", action="store_true")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    if args.run_acts:
        _TIMED = True
        run_demo_acts()
    elif args.gif_only:
        convert(CAST_FILE)
    elif args.verify:
        sys.exit(0 if verify() else 1)
    elif args.record:
        record()
    else:
        parser.print_help()
