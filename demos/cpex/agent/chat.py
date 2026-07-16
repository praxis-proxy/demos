#!/usr/bin/env python3
"""Interactive LLM agent in front of the Praxis-CPEX gateway.

The LLM thinks it's calling `get_compensation` / `send_email` /
`display_compensation` / `get_directory` tools directly. In reality:

    user prompt
        ▼
    LLM (litellm-routed: ollama/llama3, gpt-4o-mini, claude-3-7, …)
        ▼ tool_call(...)
    THIS agent
        ▼ POST /mcp with X-User-Token + Authorization
    Praxis-CPEX gateway
        ▼ identity (jwt-user + jwt-client from Keycloak JWKS)
        ▼ APL: require(role.hr), redact(args.ssn) when !perm.view_ssn
        ▼ delegate(workday-oauth) — RFC 8693 → Keycloak
        ▼ forward to upstream (workday-api token, ssn maybe redacted)
    Mock HR MCP server
        ◄ tool result
    LLM
        ◄ "Here's the data: …"

The interesting demo moments:

  * Alice (engineer) asks for compensation → gateway returns an MCP
    JSON-RPC error envelope (HTTP 200, code -32001, data.violation =
    `routes.tool:get_compensation.apl.policy[0]`). The LLM sees a
    tool error and apologizes politely without leaking the violation.
  * Bob (HR + view_ssn) asks for SSN → gateway allows + delegates
    → backend sees minted workday-api token + intact SSN
  * Eve (HR, no view_ssn) asks for SSN → gateway allows + delegates
    → backend sees minted token + ssn=`[REDACTED]` (the LLM presents
    "[REDACTED]" as if it were the value, which is exactly the
    transparent enforcement story)

Usage:

    pip install -r requirements.txt

    # No API keys required — default points at a local Ollama with
    # llama3. Install Ollama (https://ollama.com) and `ollama pull
    # llama3` first.
    python chat.py --persona bob

    # Or use any LiteLLM-supported provider via env:
    export OPENAI_API_KEY=...
    python chat.py --persona bob --model gpt-4o-mini

    export ANTHROPIC_API_KEY=...
    python chat.py --persona bob --model anthropic/claude-3-7-sonnet-20250219

    # IBM watsonx.ai with Meta's Llama (tool-use needs 70B+):
    export WATSONX_APIKEY=...
    export WATSONX_URL=https://us-south.ml.cloud.ibm.com
    export WATSONX_PROJECT_ID=...
    python chat.py --persona bob \\
        --model watsonx/meta-llama/llama-3-3-70b-instruct

Switch personas mid-session with `switch <name>` — handy for showing
deny → allow → redact in one continuous demo. Type `quit` to exit.
"""

import argparse
import json
import os
import select
import sys
import threading
import uuid
from typing import Any

import httpx
import litellm
from rich.console import Console
from rich.panel import Panel

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

DEFAULT_MODEL = "ollama/qwen3:8b"  # local, no API key required
DEFAULT_GATEWAY = "http://localhost:8090/mcp"
DEFAULT_KEYCLOAK = "http://localhost:8081"
KEYCLOAK_REALM = "cpex-demo"
KEYCLOAK_CLIENT_ID = "hr-copilot"
KEYCLOAK_CLIENT_SECRET = "hr-copilot-secret"

# Human-in-the-loop: the gateway suspends an approval-gated tool call with
# JSON-RPC -32120 ("not complete — retry with this id") instead of denying.
# The agent echoes the id back in this header to resume; while it waits it
# stays free to do other work and cuts in when the approver acts.
ELICITATION_PENDING_CODE = -32120
# Peek mode: the agent re-checks an approval WITHOUT committing the action.
# When it has resolved approved, the gateway answers -32121 ("approved —
# confirm to apply") instead of running the tool. The agent then asks the
# requester and re-sends WITHOUT the peek header to actually apply it.
ELICITATION_APPROVED_CODE = -32121
ELICITATION_ID_HEADER = "X-Policy-Elicitation-Id"
ELICITATION_PEEK_HEADER = "X-Policy-Elicitation-Peek"
# Just above Keycloak's CIBA poll interval (cibaInterval=5s). Polling faster
# earns a `slow_down` (treated as still-pending), so 6s keeps detection
# smooth without tripping it.
APPROVAL_POLL_SECONDS = 6

PERSONAS: dict[str, dict[str, str]] = {
    "alice": {
        "name": "Alice Chen",
        "title": "Software Engineer",
        "color": "cyan",
        "description": "Engineer — no role.hr → policy denies HR tools.",
        "password": "alice",
    },
    "bob": {
        "name": "Bob Martinez",
        "title": "HR Manager",
        "color": "green",
        "description": "HR + view_ssn → policy allows + SSN passes through.",
        "password": "bob",
    },
    "charlie": {
        "name": "Charlie Wu",
        "title": "Auditor",
        "color": "yellow",
        "description": "Auditor (no role.hr) — same as Alice for HR tools.",
        "password": "charlie",
    },
    "eve": {
        "name": "Eve Patel",
        "title": "HR Coordinator",
        "color": "magenta",
        "description": "HR but NO view_ssn → policy allows; SSN gets redacted.",
        "password": "eve",
    },
}

SYSTEM_PROMPT = (
    "You are an HR assistant for an HR copilot app. Help the user look up "
    "employee compensation, view directories, send emails, and similar "
    "tasks. Use the provided tools when needed. "
    "\n\n"
    "Only request data the user actually asked for: in particular, set "
    "get_compensation's `include_ssn` to true ONLY when the user explicitly "
    "asks to include/show the SSN. If the user just asks to look up "
    "compensation without mentioning the SSN, leave `include_ssn` false. "
    "\n\n"
    "CRITICAL — relay tool data verbatim: when you present a field, copy its "
    "value EXACTLY as it appears in the tool result. Never invent, mask, "
    "redact, or replace a value yourself. Only write `[REDACTED]` for a field "
    "if the tool result's value for that field is literally the string "
    "`[REDACTED]`; when the tool returns a real value (for example an actual "
    "social-security number), show that exact value unchanged. The gateway — "
    "not you — decides what to hide; your job is to relay precisely what it "
    "returned. "
    "\n\n"
    "How to interpret tool results: "
    "\n"
    "  * Normal result: present the data, copying each value verbatim per the "
    "rule above. A field whose value is `[REDACTED]` is the gateway's "
    "transparent enforcement marker (the field exists but is hidden for this "
    "caller) — show it as-is; do NOT apologize or refuse. "
    "\n"
    "  * If the tool returns an `error` envelope (a JSON-RPC error "
    "with a `code` and `message`), the gateway denied the call. "
    "Acknowledge politely without revealing the internal violation "
    "code — the user may not have permission for that operation. "
    "\n"
    "  * If the tool returns an `auth_error`, the request failed at "
    "the transport layer. Ask the user to re-authenticate. "
    "\n"
    "  * If the tool returns `status: pending_approval`, the action was NOT "
    "denied — it needs a person's out-of-band sign-off, which has been "
    "requested. Tell the user it's pending that person's approval and offer "
    "to help with something else meanwhile; do NOT call the tool again yet. "
    "You'll get a system update when they respond. If it was APPROVED, tell "
    "the user and ask whether to apply it now — and ONLY when the user "
    "confirms, call the tool again to finalize it (that actually applies it). "
    "If it was DECLINED or EXPIRED, let the user know it was not applied."
)

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_compensation",
            "description": (
                "Get compensation data for an employee. Returns salary, "
                "bonus, department, and optionally SSN."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "employee_id": {
                        "type": "string",
                        "description": "Employee identifier (e.g., EMP-001234)",
                    },
                    "include_ssn": {
                        "type": "boolean",
                        "description": "Whether to include SSN in the response",
                        "default": False,
                    },
                    "ssn": {
                        "type": "string",
                        "description": (
                            "An echo-back of the employee's SSN if the caller "
                            "claims to already know it — this is exactly the "
                            "kind of field the gateway redacts when the "
                            "caller lacks the necessary permission."
                        ),
                    },
                },
                "required": ["employee_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "display_compensation",
            "description": (
                "Display a compensation summary for the employee (band only, "
                "no salary)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "employee_id": {"type": "string"},
                },
                "required": ["employee_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_directory",
            "description": "Get the employee directory listing.",
            "parameters": {
                "type": "object",
                "properties": {
                    "department": {
                        "type": "string",
                        "description": "Optional department filter",
                        "default": "",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "send_email",
            "description": "Send an email (simulated).",
            "parameters": {
                "type": "object",
                "properties": {
                    "to": {"type": "string"},
                    "subject": {"type": "string"},
                    "body": {"type": "string"},
                },
                "required": ["to", "subject", "body"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_repos",
            "description": (
                "Search the internal GitHub Enterprise for repositories. "
                "Filter by name substring and/or visibility. Visibility is "
                "one of `internal`, `public`, `external`."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "repo_name": {
                        "type": "string",
                        "description": "Substring to filter repo names (e.g. 'web-app').",
                        "default": "",
                    },
                    "visibility": {
                        "type": "string",
                        "description": (
                            "Repo visibility — `internal` (default), `public`, or `external`. "
                            "External repos are typically off-limits for engineering."
                        ),
                        "enum": ["internal", "public", "external"],
                    },
                },
                "required": ["visibility"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "adjust_compensation",
            "description": (
                "Adjust an employee's salary by a dollar amount (a raise). "
                "Adjustments over $10,000 require the requester's manager to "
                "approve out-of-band before they apply — the gateway handles "
                "that; you just make the call and relay the outcome."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "employee_id": {
                        "type": "string",
                        "description": "Employee identifier (e.g., EMP-001234)",
                    },
                    "amount": {
                        "type": "integer",
                        "description": "Dollar amount to add to the salary (e.g. 25000).",
                    },
                },
                "required": ["employee_id", "amount"],
            },
        },
    },
]

# ---------------------------------------------------------------------------
# Keycloak token minting
# ---------------------------------------------------------------------------


def keycloak_token(persona: str, keycloak_host: str) -> str:
    """Mint a user JWT via Keycloak password grant. Persona name is
    both the username and password in the demo realm."""
    info = PERSONAS[persona]
    token_endpoint = f"{keycloak_host}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token"
    resp = httpx.post(
        token_endpoint,
        data={
            "grant_type": "password",
            "client_id": KEYCLOAK_CLIENT_ID,
            "client_secret": KEYCLOAK_CLIENT_SECRET,
            "username": persona,
            "password": info["password"],
            "scope": "openid",
        },
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def keycloak_client_token(keycloak_host: str) -> str:
    """Mint the hr-copilot client's own service-account token (the
    `Authorization` header on every gateway call)."""
    token_endpoint = f"{keycloak_host}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token"
    resp = httpx.post(
        token_endpoint,
        data={
            "grant_type": "client_credentials",
            "client_id": KEYCLOAK_CLIENT_ID,
            "client_secret": KEYCLOAK_CLIENT_SECRET,
            "scope": "openid",
        },
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


# ---------------------------------------------------------------------------
# Gateway client
# ---------------------------------------------------------------------------


class GatewayClient:
    """Calls tools through the Praxis-CPEX gateway. The agent sends
    the client token in `Authorization` (which our jwt-client
    resolver reads) and the user token in `X-User-Token` (which the
    jwt-user resolver reads)."""

    def __init__(self, gateway_url: str, client_token: str, user_token: str):
        self.gateway_url = gateway_url
        self.client_token = client_token
        self.user_token = user_token
        self._request_id = 0
        # One session id per chat process. The gateway maps X-Session-Id to
        # agent.session_id, and cpex keys session taint by H(subject:session_id)
        # — so a `secret` label written by get_compensation persists across the
        # turns of this conversation and later blocks send_email in it. A chat
        # is a logical session; this makes that boundary explicit.
        self.session_id = f"chat-{uuid.uuid4().hex}"

    def set_user_token(self, token: str) -> None:
        self.user_token = token

    def set_client_token(self, token: str) -> None:
        self.client_token = token

    def call_tool(
        self,
        tool_name: str,
        arguments: dict[str, Any],
        elicitation_id: str | None = None,
        peek: bool = False,
    ) -> tuple[int, dict[str, Any]]:
        self._request_id += 1
        payload = {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": arguments},
            "id": self._request_id,
        }
        headers = {
            "Authorization": f"Bearer {self.client_token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-User-Token": self.user_token,
            "X-Session-Id": self.session_id,
        }
        # Resume a suspended approval: echo the id so the gateway *checks*
        # the existing elicitation instead of dispatching a fresh one. With
        # `peek`, the gateway only reports status (-32121 if approved) and
        # does NOT run the tool — used to detect approval before committing.
        if elicitation_id:
            headers[ELICITATION_ID_HEADER] = elicitation_id
        if peek:
            headers[ELICITATION_PEEK_HEADER] = "true"
        resp = httpx.post(self.gateway_url, json=payload, headers=headers, timeout=30)
        # Distinguish gateway-policy denies (4xx with body text) from
        # downstream tool errors (200 with JSON-RPC error).
        try:
            data = resp.json()
        except Exception:
            data = {"text": resp.text}
        return resp.status_code, data


def _error_code(data: dict[str, Any]) -> int | None:
    """JSON-RPC error code from a gateway response, if any."""
    if isinstance(data, dict) and isinstance(data.get("error"), dict):
        return data["error"].get("code")
    return None


def classify_elicitation_outcome(status: int, data: dict[str, Any]) -> str | None:
    """Classify a resolved (non-pending) approval re-check.

    Returns `approved` (the tool ran), `expired` (the approver didn't act in
    time), or `declined` (the approver said no / another policy rejected the
    resumed call). Returns **None** for a transient or auth failure (a 401
    from an expired token, a 5xx) — that is NOT a verdict, so the poller
    keeps waiting instead of crying "declined."
    """
    if status >= 400:
        return None  # transport/auth error — not an approval decision
    if not (isinstance(data, dict) and "error" in data):
        return "approved"  # HTTP 200 + result → the tool executed
    # The gateway distinguishes the lifecycle states in the error message:
    # "elicitation expired before a response" vs "denied by approver".
    msg = (data["error"].get("message") or "").lower()
    if "expired" in msg:
        return "expired"
    return "declined"


class PendingApprovals:
    """Tracks tool calls the gateway suspended on out-of-band approval and
    re-checks them in the background — so the agent keeps working while it
    waits, and cuts back in once the approver acts. No blocking, no manual
    polling.

    Confirm-then-apply flow: a daemon thread *peeks* at each pending approval
    every few seconds (re-issuing the call with the id + peek header, which
    resolves status WITHOUT running the tool). States:

      * ``pending`` — gateway still answers -32120 (awaiting the approver).
      * ``ready``   — gateway answered -32121 (approved!). A ``ready`` event
                      is queued so the agent can ask the requester to
                      confirm. The action is NOT applied yet.
      * resolved    — declined / expired: a ``resolved`` event is queued.

    The actual apply happens only when the requester confirms: the chat loop
    looks up :meth:`ready_id_for` and re-sends WITHOUT the peek header.
    """

    def __init__(self, gateway: "GatewayClient", console: Console):
        self._gateway = gateway
        self._console = console
        self._lock = threading.Lock()
        self._pending: dict[str, dict[str, Any]] = {}
        self._events: list[dict[str, Any]] = []
        self._stop = threading.Event()
        threading.Thread(target=self._loop, daemon=True).start()

    def register(self, elicitation_id: str, tool: str, args: dict[str, Any], approver: str) -> None:
        if not elicitation_id:
            return
        with self._lock:
            self._pending[elicitation_id] = {
                "tool": tool, "args": args, "approver": approver, "state": "pending",
            }

    def ready_for(self, tool: str) -> dict[str, Any] | None:
        """An approved-and-awaiting-confirm request for this tool, or None:
        ``{"id", "args", "approver"}``. The chat loop uses it to apply on
        confirmation, re-sending the *original* approved args (not whatever
        the LLM re-emits) so the action matches what was signed off."""
        with self._lock:
            for eid, info in self._pending.items():
                if info["state"] == "ready" and info["tool"] == tool:
                    return {"id": eid, "args": info["args"], "approver": info["approver"]}
        return None

    def mark_applied(self, elicitation_id: str) -> None:
        with self._lock:
            self._pending.pop(elicitation_id, None)

    def drain_events(self) -> list[dict[str, Any]]:
        with self._lock:
            out, self._events = self._events, []
            return out

    def has_pending(self) -> bool:
        with self._lock:
            return bool(self._pending)

    def has_events(self) -> bool:
        with self._lock:
            return bool(self._events)

    def clear(self) -> None:
        with self._lock:
            self._pending.clear()
            self._events.clear()

    def _loop(self) -> None:
        while not self._stop.wait(APPROVAL_POLL_SECONDS):
            with self._lock:
                items = [(eid, info) for eid, info in self._pending.items()
                         if info["state"] == "pending"]
            for eid, info in items:
                try:
                    status, data = self._gateway.call_tool(
                        info["tool"], info["args"], elicitation_id=eid, peek=True)
                except Exception:
                    continue  # transient (network) — try again next tick
                code = _error_code(data)
                if code == ELICITATION_PENDING_CODE:
                    continue  # still awaiting the approver
                if code == ELICITATION_APPROVED_CODE:
                    # Approved — but do NOT apply. Flip to `ready` and let the
                    # agent ask the requester to confirm.
                    with self._lock:
                        if eid in self._pending:
                            self._pending[eid]["state"] = "ready"
                    self._events.append({"kind": "ready", "tool": info["tool"],
                                         "approver": info["approver"]})
                    self._console.print(
                        f"\n🔔 {info['approver']} [green]approved[/green] the "
                        f"[bold]{info['tool']}[/bold] request — confirm to apply."
                    )
                    continue
                # Declined / expired (or, defensively, an applied result).
                outcome = classify_elicitation_outcome(status, data)
                if outcome is None:
                    continue  # transient/auth error — not a verdict, keep waiting
                with self._lock:
                    self._pending.pop(eid, None)
                    self._events.append({"kind": "resolved", "tool": info["tool"],
                                         "approver": info["approver"], "outcome": outcome,
                                         "text": format_tool_response(status, data)})
                verb = {"declined": "[red]declined[/red]",
                        "expired": "[yellow]didn't respond in time to[/yellow]",
                        "approved": "[green]approved[/green]"}.get(outcome, "closed")
                self._console.print(
                    f"\n🔔 {info['approver']} {verb} the pending "
                    f"[bold]{info['tool']}[/bold] request."
                )


# ---------------------------------------------------------------------------
# Chat loop
# ---------------------------------------------------------------------------


def format_tool_response(status: int, data: dict[str, Any]) -> str:
    """Convert the gateway's response into something compact the LLM
    can read. Pull text content out of MCP `result.content[].text`.

    Three shapes the gateway can return (per MCP spec):

      * HTTP 200 + `{"result": ...}`  — happy path
      * HTTP 200 + `{"error": {"code": -32001, "message": ..., "data": {...}}}`
                                      — application-level deny (policy, PDP,
                                        PII, delegation). The LLM should treat
                                        this as a tool-refusal.
      * HTTP 401 + plain-text body    — transport-level auth failure (JWT
                                        missing / invalid / wrong audience).
                                        Includes `WWW-Authenticate: Bearer`.
    """
    if status == 401:
        # Auth-level failure — transport problem, not a policy decision.
        # Surface enough for the LLM to back off without retrying.
        body = data.get("text") if isinstance(data, dict) else str(data)
        return json.dumps({"gateway_status": 401, "auth_error": body})
    if status >= 400:
        # Other HTTP errors (e.g. 502 from a Pingora upstream failure).
        # Praxis-cpex puts the violation code in X-Cpex-Violation but
        # we don't surface headers up here. Fall back to body.
        return json.dumps({"gateway_status": status, "error": data})
    if "error" in data:
        # MCP JSON-RPC error envelope — gateway-side deny (policy, PDP, PII,
        # delegation). Pass the message and any violation hint through to the
        # LLM so it can give the user a sensible refusal.
        err = data["error"]
        return json.dumps({
            "error": err.get("message", "tool error"),
            "violation": (err.get("data") or {}).get("violation"),
        })
    result = data.get("result", {})
    content = result.get("content", [])
    text_parts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
    combined = "".join(text_parts)
    return combined or json.dumps(result)


def prompt_or_event(console: Console, prompt_markup: str, pending: PendingApprovals) -> tuple[str, str]:
    """Show the prompt and wait for a typed line — but return as soon as a
    background approval event lands, so the agent can speak proactively
    instead of waiting for the user to press Enter.

    Returns ``("line", text)`` for a typed line, or ``("event", "")`` when an
    approval event is queued. Degrades to a blocking prompt (the old
    behaviour) wherever ``select`` on stdin isn't usable (non-tty, Windows).
    """
    console.print(prompt_markup, end="")
    sys.stdout.flush()
    try:
        if not sys.stdin.isatty():
            raise OSError("stdin is not a tty")
        while True:
            ready, _, _ = select.select([sys.stdin], [], [], 0.5)
            if ready:
                line = sys.stdin.readline()
                if line == "":
                    raise EOFError
                return ("line", line.rstrip("\n"))
            if pending.has_events():
                console.print()  # close the prompt line before the agent speaks
                return ("event", "")
    except (OSError, ValueError):
        # select-on-stdin unusable — fall back to a blocking read. The user
        # then presses Enter to let the agent pick up any pending updates.
        return ("line", console.input(""))


def inject_approval_events(events: list[dict[str, Any]], messages: list[dict[str, Any]]) -> None:
    """Fold background approval activity into the conversation as context so
    the agent addresses it. `ready` = approved-but-not-applied (ask the user
    to confirm); `resolved` = declined/expired (it was not applied).

    Injected with role `user`, not `system`: this is an out-of-band update the
    agent must respond to on the next (often proactive) turn, and providers like
    Anthropic require the conversation to end with a user message — a trailing
    `system` message makes the completion call fail."""
    for ev in events:
        if ev["kind"] == "ready":
            note = (
                f"[Update: {ev['approver']} APPROVED the pending '{ev['tool']}' request — but it "
                f"has NOT been applied yet. Tell the user {ev['approver']} signed off and ask "
                f"whether to apply it now. When the user confirms, call {ev['tool']} again to "
                f"finalize it (that actually applies it).]"
            )
        elif ev.get("outcome") == "expired":
            note = (
                f"[Update: the '{ev['tool']}' request EXPIRED — {ev['approver']} didn't respond in "
                f"time, so it was NOT applied. Let the user know and offer to resend it.]"
            )
        else:
            note = (
                f"[Update: {ev['approver']} DECLINED the '{ev['tool']}' request, so it was NOT "
                f"applied. Let the user know.]"
            )
        messages.append({"role": "user", "content": note})


def agent_announce(messages: list[dict[str, Any]], model: str, console: Console) -> None:
    """A proactive (no-user-input) turn: the agent speaks after an approval
    event landed while the user was idle. Text only — the actual apply waits
    for the user's confirmation on their next turn."""
    try:
        resp = litellm.completion(model=model, messages=messages)
        text = resp.choices[0].message.content or ""
    except Exception as e:  # noqa: BLE001 — surface, don't crash the loop
        text = f"(LLM error: {e})"
    messages.append({"role": "assistant", "content": text})
    console.print(f"\n[bold]assistant:[/bold] {text}\n")


def run_chat(
    persona: str,
    model: str,
    gateway_url: str,
    keycloak_host: str,
) -> None:
    console = Console()
    info = PERSONAS[persona]

    try:
        user_tok = keycloak_token(persona, keycloak_host)
        client_tok = keycloak_client_token(keycloak_host)
    except httpx.HTTPError as e:
        console.print(f"[red]Failed to mint tokens from {keycloak_host}: {e}[/red]")
        console.print(
            "[dim]Is Keycloak running? `docker compose up -d` from the demo "
            "directory should have brought it up on :8081.[/dim]"
        )
        return

    gateway = GatewayClient(gateway_url, client_tok, user_tok)
    pending = PendingApprovals(gateway, console)

    console.print()
    console.print(
        Panel(
            f"[bold]{info['name']}[/bold] — {info['title']}\n"
            f"[dim]{info['description']}[/dim]\n\n"
            f"[dim]Model:    {model}[/dim]\n"
            f"[dim]Gateway:  {gateway_url}[/dim]\n"
            f"[dim]Keycloak: {keycloak_host}[/dim]",
            title="[bold]CPEX-Praxis HR Demo[/bold]",
            border_style=info["color"],
        )
    )
    console.print(
        "[dim]commands: `quit` to exit; "
        "`switch <alice|bob|charlie|eve>` to swap personas; "
        "`relogin` to mint fresh tokens for the current persona[/dim]\n"
    )

    messages: list[dict[str, Any]] = [{"role": "system", "content": SYSTEM_PROMPT}]

    while True:
        prompt_markup = f"[bold {info['color']}]{info['name']}:[/] "
        try:
            kind, user_input = prompt_or_event(console, prompt_markup, pending)
        except (EOFError, KeyboardInterrupt):
            console.print("\n[dim]bye[/dim]")
            return

        # An approval landed while the user was idle: the agent speaks up on
        # its own (announce + ask to confirm) instead of waiting for Enter.
        if kind == "event":
            inject_approval_events(pending.drain_events(), messages)
            agent_announce(messages, model, console)
            continue

        user_input = user_input.strip()

        if user_input.lower() == "quit":
            console.print("[dim]bye[/dim]")
            return
        if user_input.lower() in ("relogin", "reauth"):
            # Re-mint both tokens for the current persona. The client
            # token (Authorization header) is otherwise minted once at
            # startup; after accessTokenLifespan it expires and every
            # request fails with auth.token_expired. This is the
            # demo-day escape hatch when a pause runs long.
            try:
                gateway.set_client_token(keycloak_client_token(keycloak_host))
                gateway.set_user_token(keycloak_token(persona, keycloak_host))
            except httpx.HTTPError as e:
                console.print(f"[red]re-auth failed: {e}[/red]")
                continue
            console.print()
            console.print(
                Panel(
                    f"Fresh tokens for [bold]{info['name']}[/bold] + the hr-copilot client.",
                    title="[bold]re-authenticated[/bold]",
                    border_style="green",
                )
            )
            continue

        if user_input.lower().startswith("switch "):
            new = user_input.split(" ", 1)[1].strip().lower()
            if new not in PERSONAS:
                console.print(f"[red]unknown persona '{new}'. valid: {', '.join(PERSONAS)}[/red]")
                continue
            try:
                gateway.set_client_token(keycloak_client_token(keycloak_host))
                gateway.set_user_token(keycloak_token(new, keycloak_host))
            except httpx.HTTPError as e:
                console.print(f"[red]failed to mint token for {new}: {e}[/red]")
                continue
            persona = new
            info = PERSONAS[persona]
            pending.clear()  # approvals belong to the previous persona
            messages = [{"role": "system", "content": SYSTEM_PROMPT}]
            console.print()
            console.print(
                Panel(
                    f"[bold]{info['name']}[/bold] — {info['title']}\n"
                    f"[dim]{info['description']}[/dim]",
                    title="[bold]switched[/bold]",
                    border_style=info["color"],
                )
            )
            continue

        # Fold in any approval activity that landed alongside this input
        # (the proactive path above usually handles it first, but a fresh
        # event can arrive between the announce and the user's reply).
        events = pending.drain_events()
        inject_approval_events(events, messages)

        if not user_input:
            # Bare Enter: nothing to say unless approval activity just landed.
            if not events:
                continue
            user_input = "(no new message — please share any updates.)"

        messages.append({"role": "user", "content": user_input})

        try:
            response = litellm.completion(model=model, messages=messages, tools=TOOLS, tool_choice="auto")
        except Exception as e:
            console.print(f"[red]LLM error: {e}[/red]")
            messages.pop()
            continue

        assistant = response.choices[0].message
        if not assistant.tool_calls:
            text = assistant.content or "(no response)"
            console.print(f"[bold]assistant:[/bold] {text}\n")
            messages.append({"role": "assistant", "content": text})
            continue

        # Tool-call path. Replay through the gateway, hand the
        # results back to the LLM for a final summarization.
        messages.append(assistant.model_dump())
        for tc in assistant.tool_calls:
            fn = tc.function
            try:
                args = json.loads(fn.arguments) if isinstance(fn.arguments, str) else fn.arguments
            except json.JSONDecodeError:
                args = {}
            console.print(
                f"  [dim]→ {fn.name}({json.dumps(args, separators=(',', ':'))})[/dim]"
            )
            ready = pending.ready_for(fn.name)
            if ready:
                # The requester is confirming a previously-approved action.
                # Apply it now: re-send with the elicitation id (no peek) and
                # the ORIGINAL approved args, so the gateway runs the tool.
                status, data = gateway.call_tool(fn.name, ready["args"], elicitation_id=ready["id"])
                pending.mark_applied(ready["id"])
                tool_text = format_tool_response(status, data)
                console.print(f"  [dim]← [green]✓ applied[/green] {tool_text}[/dim]")
            else:
                status, data = gateway.call_tool(fn.name, args)
                if _error_code(data) == ELICITATION_PENDING_CODE:
                    # Suspended on out-of-band approval — NOT a deny. Hand it to
                    # the background poller (which peeks until approved) and tell
                    # the LLM to acknowledge the wait and move on.
                    ed = (data["error"].get("data") or {})
                    approver = ed.get("approver", "the approver")
                    pending.register(ed.get("elicitation_id", ""), fn.name, args, approver)
                    tool_text = json.dumps({
                        "status": "pending_approval",
                        "approver": approver,
                        "instruction": (
                            f"This action requires {approver}'s out-of-band approval, which has now "
                            f"been requested. Tell the user it's pending {approver}'s sign-off and "
                            f"offer to help with something else meanwhile. Do NOT retry it — you'll "
                            f"be notified automatically when {approver} responds, and the user will "
                            f"be asked to confirm before it's applied."
                        ),
                    })
                    console.print(f"  [dim]← [yellow]⏳ pending {approver}'s approval[/yellow][/dim]")
                else:
                    tool_text = format_tool_response(status, data)
                    if status >= 400:
                        console.print(f"  [dim]← [red]{status}[/red]: {tool_text}[/dim]")
                    else:
                        # Show the full tool result. Earlier versions truncated
                        # at 200 chars to keep the terminal scannable, but the
                        # demo punchline is fields like `ssn=[REDACTED]` — we
                        # need them visible on the wire so the audience can see
                        # the gateway enforcement, not just trust the LLM saw it.
                        console.print(f"  [dim]← {tool_text}[/dim]")
            messages.append({"role": "tool", "tool_call_id": tc.id, "content": tool_text})

        try:
            final = litellm.completion(model=model, messages=messages)
            text = final.choices[0].message.content or ""
        except Exception as e:
            text = f"(LLM error summarizing tool results: {e})"
        messages.append({"role": "assistant", "content": text})
        console.print(f"[bold]assistant:[/bold] {text}\n")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(description="LLM agent in front of Praxis-CPEX")
    p.add_argument(
        "--persona",
        default="alice",
        choices=list(PERSONAS),
        help="Starting persona (switch in-session with `switch <name>`)",
    )
    p.add_argument(
        "--model",
        default=os.environ.get("DEMO_MODEL", DEFAULT_MODEL),
        help=f"litellm-routed model (default: {DEFAULT_MODEL})",
    )
    p.add_argument(
        "--gateway",
        default=os.environ.get("GATEWAY_URL", DEFAULT_GATEWAY),
        help=f"Praxis-CPEX endpoint (default: {DEFAULT_GATEWAY})",
    )
    p.add_argument(
        "--keycloak",
        default=os.environ.get("KEYCLOAK_HOST", DEFAULT_KEYCLOAK),
        help=f"Keycloak host (default: {DEFAULT_KEYCLOAK})",
    )
    args = p.parse_args()
    run_chat(args.persona, args.model, args.gateway, args.keycloak)
    return 0


if __name__ == "__main__":
    sys.exit(main())
