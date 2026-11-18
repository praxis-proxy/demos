#!/usr/bin/env python3
"""Prettify the gateway's access_log (NDJSON file sink) into the 'gateway activity'
pane of the recording.

The gateway's access_log filter is configured with `sink: {type: file, path: ...}`,
which appends one NDJSON record per request and flushes live (a dedicated writer
thread), so tailing that file shows requests as they happen. Each line becomes:

    POST /v1/chat/completions   200  ↗ model
    POST /v1/chat/completions   429  ✗ no dispatch

A request that reached the backend has a non-empty `upstream` (↗ model); a denial
has `upstream="-"` (✗ no dispatch). Status is colored.

Usage: _activity.py [path-to-access.ndjson]   (default record/access.ndjson)
"""
import json
import os
import sys
import time

G = "\033[1;32m"; R = "\033[1;31m"; Y = "\033[1;33m"; D = "\033[2m"; NC = "\033[0m"

path = sys.argv[1] if len(sys.argv) > 1 else "record/access.ndjson"

print(f"{D}gateway activity{NC}\n", flush=True)

while not os.path.exists(path):
    time.sleep(0.2)

with open(path) as f:
    f.seek(0, os.SEEK_END)
    while True:
        line = f.readline()
        if not line:
            time.sleep(0.15)
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        method = rec.get("method", "?")
        p = rec.get("path", "?")
        status = str(rec.get("status", "?"))
        upstream = rec.get("upstream", "-")
        hit = f"{G}↗ model{NC}" if upstream not in ("-", "") else f"{R}✗ no dispatch{NC}"
        color = {"200": G, "429": R, "401": Y}.get(status, R)
        print(f"  {method:4} {p:22} {color}{status}{NC}  {hit}", flush=True)
