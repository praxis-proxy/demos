#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
"""Resolve the login for a GitHub token supplied only on standard input."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


api_base = os.environ.get("GITHUB_API_BASE", "https://api.github.com").rstrip("/")
token = sys.stdin.read().strip()
if not token:
    raise SystemExit("empty GitHub token")

request = urllib.request.Request(
    f"{api_base}/user",
    headers={
        "accept": "application/vnd.github+json",
        "authorization": f"Bearer {token}",
        "user-agent": "praxis-vault-community-demo-enrollment",
        "x-github-api-version": "2022-11-28",
    },
)

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        login = json.load(response).get("login")
except (urllib.error.HTTPError, urllib.error.URLError) as error:
    raise SystemExit(f"GitHub identity lookup failed: {error}") from None

if not isinstance(login, str) or not login:
    raise SystemExit("GitHub identity response did not contain a login")

print(login)
