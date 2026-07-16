#!/usr/bin/env python3
"""
Demo harness for the AuthPolicy transpiler (CLI pathway).

  Record:   python demo/record_demo.py --record     # .cast -> GIF (+ MP4)
  Run acts: python demo/record_demo.py --run-acts    # the command asciinema records
  GIF only: python demo/record_demo.py --gif-only    # reconvert an existing cast
  Verify:   python demo/record_demo.py --verify      # check the last cast

The harness IS the recorded process: it types each `$` prompt and runs the real
release binary with capture_output=False so asciinema captures all stdout.
Optional tools (asciinema/agg/ffmpeg) are looked up at runtime, not required.
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
BIN = REPO_ROOT / "target" / "release" / "authpolicy-transpiler"
DEMO_DIR = REPO_ROOT / "demo"
CAST_FILE = DEMO_DIR / "demo.cast"
GIF_FILE = DEMO_DIR / "demo.gif"
MP4_FILE = DEMO_DIR / "demo.mp4"
OUT_DIR = REPO_ROOT / "out"

BANNER_MARKER = "authpolicy-transpiler"

# Put the release binary on PATH so acts can show the clean `authpolicy-transpiler`
# command instead of a `./target/release/...` path.
DEMO_ENV = {**os.environ, "PATH": f"{BIN.parent}:{os.environ.get('PATH', '')}"}

_TIMED = False  # True only inside --run-acts (recording mode)


# -----------------------------------------------------------------------------
# Terminal helpers
# -----------------------------------------------------------------------------
def pause(seconds: float) -> None:
    """Reading time. Sleeps only while recording; a no-op otherwise."""
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


def _run(cmd: str) -> None:
    """Show a typed `$` prompt, then run the command with output to the terminal."""
    _type("\n\033[1;32m$\033[0m ", delay=0)
    _type(cmd + "\n", delay=0.03)
    pause(0.3)
    subprocess.run(cmd, cwd=REPO_ROOT, env=DEMO_ENV, shell=True,
                   capture_output=False, text=True)


def section(title: str) -> None:
    """Visual divider between acts. Newlines here are spacing, not timing."""
    bar_len = max(72, len(title) + 6)
    bar = "─" * bar_len
    sys.stdout.write(f"\n\n\n\033[90m{bar}\033[0m\n")
    sys.stdout.write(f"\033[1;96m  {title}\033[0m\n")
    sys.stdout.write(f"\033[90m{bar}\033[0m\n")
    sys.stdout.flush()


def banner() -> None:
    W = 72

    def row(text: str = "", style: str = "") -> str:
        content = (" " + text).ljust(W)  # W visible chars; no ANSI inside ljust math
        return f"\033[90m  ║\033[0m{style}{content}\033[0m\033[90m║\033[0m"

    lines = [
        f"\033[90m  ╔{'═' * W}╗\033[0m",
        row("authpolicy-transpiler", "\033[1;96m"),
        row("Kuadrant AuthPolicy  →  Praxis + CPEX policy config", "\033[0;96m"),
        row(),
        row("Best-effort translation with a coverage report — every", "\033[90m"),
        row("construct is translated, approximated, or reported as a gap.", "\033[90m"),
        row(),
        row("This demo shows:", "\033[97m"),
        row("  1. A Kuadrant AuthPolicy (JWT auth + CEL RBAC)", "\033[90m"),
        row("  2. A clean translation to CPEX + a Praxis filter block", "\033[90m"),
        row("  3. A coverage report that makes every gap visible", "\033[90m"),
        row("  4. Fail-closed safety: untranslatable authz denies all", "\033[90m"),
        row("  5. Writing the emitted artifacts to a directory", "\033[90m"),
        f"\033[90m  ╚{'═' * W}╝\033[0m",
    ]
    print("\n" + "\n".join(lines) + "\n")


# -----------------------------------------------------------------------------
# Acts
# -----------------------------------------------------------------------------
def run_demo_acts() -> None:
    banner()
    pause(10.0)

    section("1. What it does")
    _run(f"{BIN.name} --help")
    pause(7.0)

    section("2. The input: a Kuadrant AuthPolicy (JWT + CEL RBAC)")
    _run("cat examples/jwt-cel-http.yaml")
    pause(11.0)

    section("3. Transpile it — clean translation to CPEX + Praxis filter")
    _run(f"{BIN.name} examples/jwt-cel-http.yaml")
    pause(12.0)

    section("4. Best-effort, honest: the coverage report flags every gap")
    _run(f"{BIN.name} examples/gateway-defaults.yaml")
    pause(11.0)

    section("5. Fail-closed: untranslatable authz becomes deny-all + exit 1")
    _run(f"{BIN.name} examples/apikey-opa.yaml; echo \"exit code: $?\"")
    pause(11.0)

    section("6. Write the emitted artifacts to a directory")
    _run(f"{BIN.name} examples/jwt-cel-http.yaml --out-dir ./out && ls -1 out/")
    pause(8.0)

    sys.stdout.write(
        "\n\n\033[1;32m  ══════════════════════════════════════════════════════════\033[0m\n"
        "\033[1;32m  ✓  Demo complete — authpolicy-transpiler\033[0m\n"
        "\033[0;32m     Kuadrant AuthPolicy → Praxis + CPEX, best-effort + reported\033[0m\n"
        "\033[1;32m  ══════════════════════════════════════════════════════════\033[0m\n"
        "\n"
        "     Run it:  cargo run -- examples/jwt-cel-http.yaml\n"
        "     End-to-end on Praxis + CPEX:  cd e2e && ./run-demo.sh\n"
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
    """Drop shell-init events so the banner is the first visible frame."""
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
        print("[demo] Install: brew install agg  or  cargo install agg")
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
            print(f"[demo] MP4 → {MP4_FILE}  ({strat[strat.index('-c:v') + 1] if '-c:v' in strat else 'default'})")
            return
    print("[demo] MP4 conversion failed (GIF still available)")


def record() -> None:
    asciinema = _resolve("asciinema")
    if not asciinema:
        sys.exit("[demo] asciinema not found — install: brew install asciinema")
    if not BIN.exists():
        print("[demo] release binary missing — building…")
        subprocess.run(["cargo", "build", "--release"], cwd=REPO_ROOT, check=True)
    DEMO_DIR.mkdir(exist_ok=True)
    if CAST_FILE.exists():
        CAST_FILE.unlink()
    subprocess.run([
        asciinema, "rec", str(CAST_FILE),
        "--command", f"{sys.executable} {__file__} --run-acts",
        "--window-size", "160x48",
        "--capture-env", "TERM,COLORTERM",
        "--headless",
    ], cwd=REPO_ROOT, check=True)
    trim_cast_to_banner(CAST_FILE, BANNER_MARKER)
    convert(CAST_FILE)
    shutil.rmtree(OUT_DIR, ignore_errors=True)


def verify() -> bool:
    if not CAST_FILE.exists():
        print("[verify] no cast file")
        return False
    content = CAST_FILE.read_text()
    checks = [
        ("Kuadrant AuthPolicy", "banner present"),
        ("identity/jwt", "act 3: CPEX identity/jwt plugin emitted"),
        ("require(authenticated)", "act 3: native presence gate"),
        ("translated: 4", "act 3: clean coverage report"),
        ("defaults/overrides", "act 4: gap reported"),
        ("require(false)", "act 5: fail-closed deny-all"),
        ("exit code: 1", "act 5: non-zero exit"),
        ("cpex-policy.yaml", "act 6: artifacts written"),
    ]
    ok = True
    for fragment, label in checks:
        present = fragment in content
        print(f"  [{'ok ' if present else 'MISS'}] {label}")
        ok = ok and present
    return ok


# -----------------------------------------------------------------------------
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AuthPolicy transpiler demo recorder")
    parser.add_argument("--record", action="store_true", help="Record cast → GIF/MP4")
    parser.add_argument("--run-acts", action="store_true", help="Run acts (recorded)")
    parser.add_argument("--gif-only", action="store_true", help="Reconvert existing cast")
    parser.add_argument("--verify", action="store_true", help="Verify the last cast")
    args = parser.parse_args()

    if args.run_acts:
        _TIMED = True
        os.chdir(REPO_ROOT)
        run_demo_acts()
    elif args.gif_only:
        convert(CAST_FILE)
    elif args.verify:
        sys.exit(0 if verify() else 1)
    elif args.record:
        record()
    else:
        parser.print_help()
