#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
"""Assert that a token from stdin is absent from generated and tracked files."""

from __future__ import annotations

import pathlib
import subprocess
import sys


demo_dir = pathlib.Path(sys.argv[1]).resolve()
token = sys.stdin.buffer.read()
if not token:
    raise SystemExit("empty GitHub token supplied to leak scanner")

repo_root = pathlib.Path(
    subprocess.run(
        ["git", "-C", demo_dir, "rev-parse", "--show-toplevel"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
)
tracked = subprocess.run(
    ["git", "-C", repo_root, "ls-files", "-z"],
    check=True,
    stdout=subprocess.PIPE,
).stdout.split(b"\0")

files = [path for path in (demo_dir / ".state").iterdir() if path.is_file()]
files.extend(repo_root / pathlib.Path(path.decode()) for path in tracked if path)

for path in files:
    if path.is_file() and token in path.read_bytes():
        raise SystemExit(f"GitHub token leaked into {path}")
