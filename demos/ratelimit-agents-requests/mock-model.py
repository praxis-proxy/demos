#!/usr/bin/env python3
"""Minimal mock model backend for the rate-limit demo.

Stands in for a shared LLM inference service so the demo (and its recording) are
deterministic and need no API key or GPU. It answers the OpenAI-shaped endpoints
an agent calls:

    POST /v1/chat/completions   -> a prepared reply chosen from the prompt
    POST /v1/embeddings         -> a canned embedding vector
    GET  /v1/models             -> a static model list

Chat replies are mapped from the user's message so the output reads naturally and
reproducibly (e.g. a prompt about CSV export -> "Here is the CSV export ..."), with
a generic fallback for anything unmatched.

Anything that reaches this backend was already ADMITTED by the gateway's rate
limiter, so the backend also proves dispatch: it records a receipt per served
inference and exposes control endpoints the verification reads.

    GET  /__count   -> 200 {"served": N}      (does NOT count itself)
    POST /__reset   -> 200 {"served": 0}      (zero the counter)

Configuration (env):
    MODEL_BIND   bind address (default 0.0.0.0, for the container)
    MODEL_PORT   listen port  (default 9100)
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

BIND = os.environ.get("MODEL_BIND", "0.0.0.0")
PORT = int(os.environ.get("MODEL_PORT", "9100"))

_served = 0

# Prepared chat replies: first keyword found in the user's message wins.
RESPONSES = [
    ("log in", "Login problem: recommend a password reset."),
    ("password", "Login problem: recommend a password reset."),
    ("invoice", "Billing error: the invoice tax rate is wrong."),
    ("tax", "Billing error: the invoice tax rate is wrong."),
    ("dark mode", "Logged a feature request: dark mode."),
    ("csv", "Here is the CSV export of your data."),
    ("export", "Here is the CSV export of your data."),
    ("2fa", "Security: resetting two-factor authentication."),
    ("upload", "Upload fails: likely the 2 GB file-size limit."),
    ("crash", "Crash on upload: file-size limit suspected."),
]
DEFAULT_REPLY = "Ticket triaged."

_EMBED = {
    "object": "list",
    "model": "mock-embed",
    "data": [{"object": "embedding", "index": 0, "embedding": [0.0, 0.1, 0.2]}],
    "usage": {"prompt_tokens": 8, "total_tokens": 8},
}
_MODELS = {
    "object": "list",
    "data": [
        {"id": "mock-model", "object": "model"},
        {"id": "mock-embed", "object": "model"},
    ],
}


def pick_reply(body):
    try:
        user = ""
        for m in body.get("messages", []):
            if m.get("role") == "user":
                user = m.get("content", "")
        low = user.lower()
        for key, resp in RESPONSES:
            if key in low:
                return resp
    except Exception:
        pass
    return DEFAULT_REPLY


class Model(BaseHTTPRequestHandler):
    def _read_json(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(n) if n > 0 else b""
            return json.loads(raw or b"{}")
        except Exception:
            return {}

    def _json(self, status, payload):
        body = (json.dumps(payload) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve(self, kind, payload):
        global _served
        _served += 1
        print(f"INFERENCE served: {kind}  (total={_served})", flush=True)
        self._json(200, payload)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/__count":
            self._json(200, {"served": _served})
        elif path == "/v1/models":
            self._serve("models", _MODELS)
        else:
            self.send_error(404, "not found")

    def do_POST(self):
        global _served
        path = self.path.split("?", 1)[0]
        if path == "/__reset":
            _served = 0
            self._json(200, {"served": _served})
        elif path == "/v1/chat/completions":
            reply = pick_reply(self._read_json())
            self._serve("chat.completion", {
                "id": "chatcmpl-mock",
                "object": "chat.completion",
                "model": "mock-model",
                "choices": [
                    {"index": 0, "message": {"role": "assistant", "content": reply}, "finish_reason": "stop"}
                ],
                "usage": {"prompt_tokens": 8, "completion_tokens": 6, "total_tokens": 14},
            })
        elif path == "/v1/embeddings":
            self._read_json()  # drain the request body
            self._serve("embedding", _EMBED)
        else:
            self.send_error(404, "not found")

    def log_message(self, *_args):  # inferences are logged explicitly above
        pass


if __name__ == "__main__":
    HTTPServer((BIND, PORT), Model).serve_forever()
