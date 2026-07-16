#!/usr/bin/env python3
"""Minimal HTTP echo backend for the AuthPolicy L7 demo.

Returns 200 + a small JSON blob for ANY method and path. Praxis's `policy`
filter is what decides allow/deny — anything that reaches this backend was
already authorized, so the backend just confirms the request got through.

Listens on 127.0.0.1:9200 (matches praxis.yaml's cluster endpoint).
"""

from http.server import BaseHTTPRequestHandler, HTTPServer

ADDR = ("127.0.0.1", 9200)


class Echo(BaseHTTPRequestHandler):
    def _respond(self):
        body = b'{"backend":"echo","result":"reached upstream"}\n'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = lambda self: self._respond()

    def log_message(self, *_args):  # keep the demo output clean
        pass


if __name__ == "__main__":
    HTTPServer(ADDR, Echo).serve_forever()
