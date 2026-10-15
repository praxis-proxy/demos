# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
"""Minimal MCP bridge that keeps the delegated GitHub token out of payloads."""

from __future__ import annotations

import json
import os
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


GITHUB_API_BASE = os.environ.get("GITHUB_API_BASE", "https://api.github.com").rstrip("/")
_stats_lock = threading.Lock()
_github_calls = 0


def _increment_github_calls() -> None:
    global _github_calls
    with _stats_lock:
        _github_calls += 1


def _github_call_count() -> int:
    with _stats_lock:
        return _github_calls


class Handler(BaseHTTPRequestHandler):
    server_version = "praxis-vault-demo"

    def log_message(self, _format: str, *_args: object) -> None:
        # Never let the default server logger grow into header logging.
        return

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        if self.path == "/healthz":
            self._send_json(200, {"status": "ok"})
            return
        if self.path == "/stats":
            self._send_json(200, {"github_calls": _github_call_count()})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        if self.path not in ("/", "/mcp"):
            self._send_json(404, {"error": "not found"})
            return

        try:
            size = int(self.headers.get("content-length", "0"))
            message = json.loads(self.rfile.read(size))
        except (ValueError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid JSON"})
            return

        if not isinstance(message, dict):
            self._send_json(400, {"error": "invalid request"})
            return

        params = message.get("params")
        if not isinstance(params, dict):
            self._send_json(400, {"error": "invalid request"})
            return

        request_id = message.get("id")
        if message.get("method") != "tools/call" or params.get("name") != "github_whoami":
            self._send_json(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32601, "message": "unknown tool"},
                },
            )
            return

        authorization = self.headers.get("authorization", "")
        if not authorization.startswith("Bearer ") or len(authorization) <= len("Bearer "):
            self._send_json(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32000, "message": "delegated credential missing"},
                },
            )
            return

        request = urllib.request.Request(
            f"{GITHUB_API_BASE}/user",
            headers={
                "accept": "application/vnd.github+json",
                "authorization": authorization,
                "user-agent": "praxis-vault-community-demo",
                "x-github-api-version": "2022-11-28",
            },
        )
        _increment_github_calls()
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                github_user = json.load(response)
        except urllib.error.HTTPError as error:
            self._send_json(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32002,
                        "message": f"GitHub returned HTTP {error.code}",
                    },
                },
            )
            return
        except urllib.error.URLError:
            self._send_json(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32003, "message": "GitHub is unreachable"},
                },
            )
            return

        safe_user = {
            "login": github_user.get("login"),
            "id": github_user.get("id"),
            "html_url": github_user.get("html_url"),
        }
        self._send_json(
            200,
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(safe_user, separators=(",", ":")),
                        }
                    ],
                    "isError": False,
                },
            },
        )


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
