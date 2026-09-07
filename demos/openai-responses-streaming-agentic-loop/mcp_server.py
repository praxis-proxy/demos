#!/usr/bin/env python3
"""Minimal MCP server (streamable HTTP) with a get_weather tool."""

import json
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = 9100


class MCPHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        req = json.loads(body)
        method = req.get("method")
        rid = req.get("id")

        if method == "initialize":
            self.json_rpc(rid, {
                "protocolVersion": "2025-03-26",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "weather-mock", "version": "0.1.0"},
            })
        elif method == "notifications/initialized":
            self.send_response(202)
            self.end_headers()
        elif method == "tools/list":
            self.json_rpc(rid, {
                "tools": [{
                    "name": "get_weather",
                    "description": "Get current weather for a city",
                    "inputSchema": {
                        "type": "object",
                        "properties": {"location": {"type": "string"}},
                        "required": ["location"],
                        "additionalProperties": False,
                    },
                }]
            })
        elif method == "tools/call":
            loc = req.get("params", {}).get("arguments", {}).get("location", "unknown")
            self.json_rpc(rid, {
                "content": [{"type": "text", "text": f"72°F and sunny in {loc}"}]
            })
        elif method == "ping":
            self.json_rpc(rid, {})
        else:
            self.json_rpc(rid, None, error={
                "code": -32601, "message": f"unknown method: {method}"
            })

    def json_rpc(self, rid, result, error=None):
        resp = {"jsonrpc": "2.0", "id": rid}
        if error:
            resp["error"] = error
        else:
            resp["result"] = result
        payload = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print(f"[MCP] {args[0]} {args[1]} {args[2]}")


if __name__ == "__main__":
    print(f"MCP mock server on http://127.0.0.1:{PORT}/mcp")
    HTTPServer(("127.0.0.1", PORT), MCPHandler).serve_forever()
