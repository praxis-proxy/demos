#!/usr/bin/env python3
"""Interactive agent REPL for the rate-limit demo (the live recording's bottom pane).

An agent that calls a shared model through the Praxis gateway. The gateway caps
each agent's requests per verified identity; this REPL lets you drive the calls and
watch the limiter admit (200) or throttle (429 / 401).

Commands:
  <text>          send a chat completion (the model) as the current agent
  /embed <text>   call the embeddings route (its own, lower budget)
  /models         list models (an unmetered route)
  /as <who>       act as: agent-blue | agent-green | nosub | none  (none = no token)
  /help           show commands
  /quit           exit

The agent presents its identity as a bearer token (its JWT). The gateway keys the
rate limit on the verified subject — not on anything typed here.

Env:
  GATEWAY_URL   default http://127.0.0.1:8095
  MODEL         chat model Ollama serves       (default llama3.2)
  MODEL_EMBED   embeddings model               (default = MODEL)
  TOKENS_DIR    default jwt/tokens
"""
import os
import sys

import httpx

GATEWAY = os.environ.get("GATEWAY_URL", "http://127.0.0.1:8095").rstrip("/")
MODEL = os.environ.get("MODEL", "llama3.2")
MODEL_EMBED = os.environ.get("MODEL_EMBED", MODEL)
TOKENS_DIR = os.environ.get("TOKENS_DIR", "jwt/tokens")

B = "\033[1;34m"; G = "\033[1;32m"; R = "\033[1;31m"; Y = "\033[1;33m"; D = "\033[2m"; NC = "\033[0m"

IDENTITIES = {
    "agent-blue": "agent-blue.jwt",
    "agent-green": "agent-green.jwt",
    "nosub": "nosub.jwt",
    "none": None,
}


def load_token(name):
    fn = IDENTITIES.get(name)
    if fn is None:
        return None
    with open(os.path.join(TOKENS_DIR, fn)) as fh:
        return fh.read().strip()


class Repl:
    def __init__(self):
        self.identity = "agent-blue"
        self.token = load_token(self.identity)
        self.http = httpx.Client(base_url=GATEWAY, timeout=60)

    def _headers(self):
        h = {"Content-Type": "application/json"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    def _status(self, code, ok_msg=""):
        if code == 200:
            print(f"  {G}200{NC} {ok_msg}", flush=True)
        elif code == 429:
            print(f"  {R}429{NC} rate limit exceeded — this agent has spent its budget", flush=True)
        elif code == 401:
            print(f"  {Y}401{NC} unauthorized — no verified agent identity", flush=True)
        else:
            print(f"  {R}{code}{NC} {ok_msg}", flush=True)

    def _post(self, path, body):
        try:
            return self.http.post(path, headers=self._headers(), json=body)
        except Exception as e:  # upstream/transport errors
            print(f"  {R}error{NC} {e}", flush=True)
            return None

    def chat(self, text):
        r = self._post("/v1/chat/completions", {
            "model": MODEL,
            "messages": [
                {"role": "system", "content": "Reply in 3 words."},
                {"role": "user", "content": text},
            ],
        })
        if r is None:
            return
        if r.status_code == 200:
            try:
                msg = r.json()["choices"][0]["message"]["content"].strip().replace("\n", " ")
            except Exception:
                msg = ""
            self._status(200, msg[:70])
        else:
            self._status(r.status_code)

    def embed(self, text):
        r = self._post("/v1/embeddings", {"model": MODEL_EMBED, "input": text})
        if r is None:
            return
        if r.status_code == 200:
            try:
                n = len(r.json()["data"][0]["embedding"])
            except Exception:
                n = "?"
            self._status(200, f"embedded ({n} dims)")
        else:
            self._status(r.status_code)

    def models(self):
        try:
            r = self.http.get("/v1/models", headers=self._headers())
        except Exception as e:
            print(f"  {R}error{NC} {e}", flush=True)
            return
        if r.status_code == 200:
            try:
                names = ", ".join(m["id"] for m in r.json()["data"])
            except Exception:
                names = ""
            self._status(200, f"models: {names}"[:70])
        else:
            self._status(r.status_code)

    def set_identity(self, who):
        if who not in IDENTITIES:
            print(f"  {R}unknown identity{NC} '{who}' (agent-blue|agent-green|nosub|none)", flush=True)
            return
        self.identity = who
        self.token = load_token(who)
        print(f"  {D}now acting as {'no token' if who == 'none' else who}{NC}", flush=True)

    def prompt(self):
        return f"{B}{self.identity}{NC} ❯ "


def main():
    repl = Repl()
    echo = not sys.stdin.isatty()  # when driven via a pipe (tests), echo input so it shows
    print(f"{B}agent{NC} calling the model through Praxis {D}(rate-limited per agent; model: {MODEL}){NC}")
    print(f"{D}commands: <text> | /embed <text> | /models | /as <who> | /help | /quit{NC}\n")
    while True:
        sys.stdout.write(repl.prompt())
        sys.stdout.flush()
        line = sys.stdin.readline()
        if not line:
            break
        line = line.rstrip("\n")
        if echo:
            print(line, flush=True)
        s = line.strip()
        if not s:
            continue
        if s in ("/quit", "/exit"):
            break
        elif s == "/help":
            print(f"  {D}<text> chat | /embed <text> | /models | /as <who> | /quit{NC}", flush=True)
        elif s.startswith("/as "):
            repl.set_identity(s[4:].strip())
        elif s == "/models":
            repl.models()
        elif s.startswith("/embed "):
            repl.embed(s[7:].strip())
        elif s.startswith("/"):
            print(f"  {R}unknown command{NC} {s}", flush=True)
        else:
            repl.chat(s)
    print(f"\n{D}bye{NC}", flush=True)


if __name__ == "__main__":
    main()
