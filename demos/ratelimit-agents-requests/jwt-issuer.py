#!/usr/bin/env python3
"""Minimal static JWKS issuer for the rate-limit demo.

Stands in for an OIDC IdP: it serves ONLY the public JWKS so the gateway's
policy filter can verify the persona tokens' RS256 signatures. It deliberately
serves nothing else — in particular it never exposes the RSA private key, which
a blanket `python3 -m http.server` over the jwt/ directory would.

    GET /jwks.json   -> 200 application/json
    anything else    -> 404

Configuration (env):
    ISSUER_BIND   bind address      (default 0.0.0.0, for the container)
    ISSUER_PORT   listen port       (default 8888)
    JWKS_FILE     path to jwks.json (default <this dir>/jwt/jwks.json)

Run jwt/generate.sh first so jwks.json exists. In docker-compose this script is
mounted into a python image and JWKS_FILE points at the mounted jwks.json.
"""

import os
from http.server import BaseHTTPRequestHandler, HTTPServer

BIND = os.environ.get("ISSUER_BIND", "0.0.0.0")
PORT = int(os.environ.get("ISSUER_PORT", "8888"))
_DEFAULT_JWKS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jwt", "jwks.json")
JWKS_FILE = os.environ.get("JWKS_FILE", _DEFAULT_JWKS)


class Issuer(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] != "/jwks.json":
            self.send_error(404, "not found")
            return
        try:
            with open(JWKS_FILE, "rb") as fh:
                body = fh.read()
        except FileNotFoundError:
            self.send_error(503, "jwks.json missing; run jwt/generate.sh first")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):  # keep the demo output clean
        pass


if __name__ == "__main__":
    HTTPServer((BIND, PORT), Issuer).serve_forever()
