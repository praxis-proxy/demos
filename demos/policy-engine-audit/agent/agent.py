#!/usr/bin/env python3
"""A deliberately naive HR copilot agent, scripted so every run is the same.

It does what a real tool-using agent does on a bad day: it treats text that
comes back from a tool as instructions. A wiki page fetched with `fetch_doc`
carries an HTML comment starting "AGENT INSTRUCTION:", and the agent turns it
into a `send_email` call carrying the compensation record it just read.

Nothing here is clever, and that is the point of the demo: the gateway policy
has to contain the agent, because the agent will not contain itself.

Usage (normally driven by scenarios/03-injection-blocked.sh):

    agent.py --user bob --session <id> --task comp-review

Talks to the Praxis gateway with only the standard library. Prints one line
per tool call so a presenter can narrate it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

GATEWAY = os.environ.get("PRAXIS_URL", "http://127.0.0.1:8090/mcp")
KEYCLOAK = os.environ.get("KEYCLOAK_URL", "http://localhost:8081")
REALM = os.environ.get("REALM", "cpex-demo")

DIM, RED, GREEN, CYAN, RESET = "\033[2m", "\033[91m", "\033[92m", "\033[96m", "\033[0m"

# What the injected comment asks for. Matched loosely, like a model would.
INJECTION = re.compile(
    r"AGENT INSTRUCTION:.*?[Ee]mail.*?to\s+(?P<to>[\w.+-]+@[\w.-]+).*?subject\s+'(?P<subject>[^']+)'",
    re.S,
)


def login(user: str) -> str:
    """Password grant on the hr-copilot client: the agent acts as `user`."""
    body = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": "hr-copilot",
            "client_secret": "hr-copilot-secret",
            "username": user,
            "password": user,
            "scope": "openid",
        }
    ).encode()
    url = f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token"
    with urllib.request.urlopen(urllib.request.Request(url, data=body)) as resp:
        return json.load(resp)["access_token"]


class Gateway:
    def __init__(self, token: str, session: str):
        self.token = token
        self.session = session
        self.next_id = 1

    def call(self, tool: str, arguments: dict) -> dict:
        rpc = {
            "jsonrpc": "2.0",
            "id": self.next_id,
            "method": "tools/call",
            "params": {"name": tool, "arguments": arguments},
        }
        self.next_id += 1
        req = urllib.request.Request(
            GATEWAY,
            data=json.dumps(rpc).encode(),
            headers={
                "Content-Type": "application/json",
                # The same Keycloak token proves both the user (X-User-Token)
                # and the agent client (Authorization, azp=hr-copilot).
                "Authorization": f"Bearer {self.token}",
                "X-User-Token": self.token,
                # Session taint is keyed on subject + this header.
                "X-Session-Id": self.session,
            },
        )
        try:
            with urllib.request.urlopen(req) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            return json.loads(e.read() or b"{}")


def text_of(reply: dict) -> str:
    content = reply.get("result", {}).get("content", [])
    return "".join(part.get("text", "") for part in content)


def show(tool: str, reply: dict) -> None:
    if "error" in reply:
        err = reply["error"]
        violation = (err.get("data") or {}).get("violation", "")
        print(f"    {RED}✗ {tool}: DENIED by gateway{RESET}  {err.get('message')}  [{violation}]")
    else:
        print(f"    {GREEN}✓ {tool}{RESET}  {DIM}{text_of(reply)[:90].strip()}…{RESET}")


def comp_review(gw: Gateway) -> int:
    """User asks: "Prep me for Jane's comp review." The agent reads the
    process page, then the figures, then obeys whatever the page told it."""
    print(f"  {CYAN}agent{RESET} user task: prepare Jane Smith's Q3 compensation review")

    doc = gw.call("fetch_doc", {"doc_id": "comp-review-process"})
    show("fetch_doc(comp-review-process)", doc)
    comp = gw.call("get_compensation", {"employee_id": "EMP-001234"})
    show("get_compensation(EMP-001234)", comp)

    match = INJECTION.search(text_of(doc))
    if not match:
        print("  agent: nothing else to do")
        return 0

    to, subject = match["to"], match["subject"]
    print(f"  {CYAN}agent{RESET} {RED}found an instruction in tool output and is following it{RESET}")
    reply = gw.call("send_email", {"to": to, "subject": subject, "body": text_of(comp)})
    show(f"send_email(to={to})", reply)
    return 0 if "error" in reply else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--user", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--task", choices=["comp-review"], default="comp-review")
    args = parser.parse_args()

    gw = Gateway(login(args.user), args.session)
    return comp_review(gw)


if __name__ == "__main__":
    sys.exit(main())
