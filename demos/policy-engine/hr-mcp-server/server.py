"""HR Demo MCP Server — HTTP/JSON-RPC variant.

A small FastAPI app that speaks MCP-shaped JSON-RPC over HTTP so
Praxis can route to it. Adapted from `apl-plugins/demo/hr_demo_server.py`
(which speaks stdio); the tool fixtures + logic are the same.

The headline log line is intentional: every inbound request prints
the Authorization header (so audiences can see the IdP-minted token,
NOT the user's original IdP JWT) and the parsed tool arguments
(so they can see args.ssn redacted to `[REDACTED]` when policy
fires).

Run locally:
    pip install -r requirements.txt
    uvicorn server:app --host 0.0.0.0 --port 9100

Endpoint:
    POST /mcp   — JSON-RPC 2.0 requests

Methods:
    tools/list, tools/call      — tool discovery and invocation
    prompts/list, prompts/get   — prompt template discovery and retrieval
    resources/list, resources/read — resource discovery and content fetch

Tools:
    get_compensation, send_email, display_compensation, get_directory

Prompts:
    summarize-report, onboarding-checklist

Resources:
    hr://employees/compensation, hr://employees/directory
"""

import json
import logging
import sys
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(message)s",
    handlers=[logging.StreamHandler(sys.stderr)],
)
logger = logging.getLogger("hr-mcp-server")

app = FastAPI(title="HR Demo MCP Server")

# ---------------------------------------------------------------------------
# Mock data (copied from sibling-repos/apl-plugins/demo/hr_demo_server.py)
# ---------------------------------------------------------------------------

EMPLOYEES: dict[str, dict[str, Any]] = {
    "EMP-001234": {
        "employee_id": "EMP-001234",
        "name": "Jane Smith",
        "salary": 125000,
        "bonus": 15000,
        "ssn": "123-45-6789",
        "department": "Engineering",
        "internal_notes": "Performance review pending, do not disclose",
        "email": "jane.smith@corp.com",
        "title": "Senior Software Engineer",
    },
    "EMP-005678": {
        "employee_id": "EMP-005678",
        "name": "Bob Johnson",
        "salary": 145000,
        "bonus": 25000,
        "ssn": "234-56-7890",
        "department": "Marketing",
        "internal_notes": "Promotion candidate Q2",
        "email": "bob.johnson@corp.com",
        "title": "Marketing Manager",
    },
    "EMP-009012": {
        "employee_id": "EMP-009012",
        "name": "Alice Chen",
        "salary": 145000,
        "bonus": 20000,
        "ssn": "456-78-9012",
        "department": "Engineering",
        "internal_notes": "Team lead, retention risk",
        "email": "alice.chen@corp.com",
        "title": "Principal Engineer",
    },
}

SENT_EMAILS: list[dict[str, Any]] = []

# Fake repo fixtures — names + visibility match what Cedar policy
# expects in `args.repo_name` / `args.visibility`.
REPOS: list[dict[str, Any]] = [
    {"name": "internal/web-app",       "visibility": "internal", "stars": 24, "language": "TypeScript"},
    {"name": "internal/api-gateway",   "visibility": "internal", "stars": 18, "language": "Rust"},
    {"name": "internal/data-pipeline", "visibility": "internal", "stars": 11, "language": "Python"},
    {"name": "public/showcase-site",   "visibility": "public",   "stars": 2840, "language": "Astro"},
    {"name": "external/partner-sdk",   "visibility": "external", "stars": 47, "language": "Go"},
]

# ---------------------------------------------------------------------------
# Tool implementations (logic copied from the stdio server)
# ---------------------------------------------------------------------------


def tool_get_compensation(args: dict[str, Any]) -> dict[str, Any]:
    employee_id = args.get("employee_id", "")
    include_ssn = args.get("include_ssn", False)
    employee = EMPLOYEES.get(employee_id)
    if not employee:
        return {"error": f"Employee {employee_id} not found"}
    result = {
        "employee_id": employee["employee_id"],
        "name": employee["name"],
        "salary": employee["salary"],
        "bonus": employee["bonus"],
        "department": employee["department"],
        "title": employee["title"],
        "internal_notes": employee["internal_notes"],
    }
    if include_ssn:
        # NB: this is the field gateway redaction should have stripped
        # before we ever see it. If the upstream actually sees a real
        # SSN here, the redact policy didn't fire.
        result["ssn"] = employee["ssn"]
    return result


def tool_send_email(args: dict[str, Any]) -> dict[str, Any]:
    email = {"to": args.get("to", ""), "subject": args.get("subject", ""), "body": args.get("body", "")}
    SENT_EMAILS.append(email)
    return {
        "status": "sent",
        "message_id": f"msg-{len(SENT_EMAILS):04d}",
        "to": email["to"],
        "subject": email["subject"],
    }


def tool_display_compensation(args: dict[str, Any]) -> dict[str, Any]:
    employee_id = args.get("employee_id", "")
    employee = EMPLOYEES.get(employee_id)
    if not employee:
        return {"error": f"Employee {employee_id} not found"}
    return {
        "employee_id": employee["employee_id"],
        "name": employee["name"],
        "department": employee["department"],
        "title": employee["title"],
        "salary_band": (
            "senior" if employee["salary"] >= 120000 else
            "mid" if employee["salary"] >= 80000 else
            "junior"
        ),
        "has_bonus": employee["bonus"] > 0,
    }


def tool_get_directory(args: dict[str, Any]) -> list[dict[str, Any]]:
    department = args.get("department", "")
    entries = []
    for emp in EMPLOYEES.values():
        if department and emp["department"].lower() != department.lower():
            continue
        entries.append({
            "name": emp["name"],
            "department": emp["department"],
            "title": emp["title"],
            "email": emp["email"],
        })
    return entries


def tool_search_repos(args: dict[str, Any]) -> dict[str, Any]:
    # Simulated GitHub Enterprise search. The interesting demo
    # property: this returns the repo IF the gateway allowed the
    # call through. The Cedar policy + post-delegate check
    # determines whether the request reaches this code at all.
    repo_name = args.get("repo_name", "")
    visibility = args.get("visibility", "")
    matches = []
    for r in REPOS:
        if repo_name and repo_name.lower() not in r["name"].lower():
            continue
        if visibility and r["visibility"].lower() != visibility.lower():
            continue
        matches.append(r)
    return {"matches": matches, "query": {"repo_name": repo_name, "visibility": visibility}}


def tool_adjust_compensation(args: dict[str, Any]) -> dict[str, Any]:
    # Mutating, sensitive action. The interesting demo property: large
    # adjustments require a manager's out-of-band approval, enforced by
    # the gateway's `require_approval(...)` policy BEFORE this code runs.
    # By the time we get here, the approval (if required) already landed —
    # the tool just applies the change.
    employee_id = args.get("employee_id", "")
    amount = int(args.get("amount", 0))
    employee = EMPLOYEES.get(employee_id)
    if not employee:
        return {"error": f"Employee {employee_id} not found"}
    employee["salary"] += amount
    return {
        "status": "applied",
        "employee_id": employee["employee_id"],
        "name": employee["name"],
        "adjustment": amount,
        "new_salary": employee["salary"],
    }


TOOLS = {
    "get_compensation": tool_get_compensation,
    "send_email": tool_send_email,
    "display_compensation": tool_display_compensation,
    "get_directory": tool_get_directory,
    "search_repos": tool_search_repos,
    "adjust_compensation": tool_adjust_compensation,
}

# ---------------------------------------------------------------------------
# Prompt definitions and implementations
# ---------------------------------------------------------------------------

PROMPT_DEFINITIONS: list[dict[str, Any]] = [
    {
        "name": "summarize-report",
        "description": "Generate a prompt for summarizing an employee's compensation report.",
        "arguments": [
            {"name": "employee_id", "description": "Employee identifier (e.g. EMP-001234)", "required": True},
            {"name": "include_ssn", "description": "Whether to include SSN in the report", "required": False},
        ],
    },
    {
        "name": "onboarding-checklist",
        "description": "Generate an onboarding checklist prompt for a department.",
        "arguments": [
            {"name": "department", "description": "Department name (e.g. Engineering)", "required": True},
        ],
    },
]


def prompt_summarize_report(args: dict[str, Any]) -> dict[str, Any]:
    employee_id = args.get("employee_id", "")
    include_ssn = args.get("include_ssn", False)
    employee = EMPLOYEES.get(employee_id)
    if not employee:
        return {"error": f"Employee {employee_id} not found"}
    data = {
        "employee_id": employee["employee_id"],
        "name": employee["name"],
        "salary": employee["salary"],
        "bonus": employee["bonus"],
        "department": employee["department"],
        "title": employee["title"],
    }
    if include_ssn:
        data["ssn"] = employee["ssn"]
    return {
        "messages": [
            {
                "role": "user",
                "content": {"type": "text", "text": (
                    f"Summarize the following compensation report for {employee['name']}:\n\n"
                    f"{json.dumps(data, indent=2)}"
                )},
            },
        ],
    }


def prompt_onboarding_checklist(args: dict[str, Any]) -> dict[str, Any]:
    department = args.get("department", "")
    members = [
        emp for emp in EMPLOYEES.values()
        if emp["department"].lower() == department.lower()
    ]
    member_names = ", ".join(m["name"] for m in members) if members else "no current members"
    return {
        "messages": [
            {
                "role": "user",
                "content": {"type": "text", "text": (
                    f"Create an onboarding checklist for a new hire joining the {department} department. "
                    f"Current team members: {member_names}."
                )},
            },
        ],
    }


PROMPTS = {
    "summarize-report": prompt_summarize_report,
    "onboarding-checklist": prompt_onboarding_checklist,
}

# ---------------------------------------------------------------------------
# Resource definitions and implementations
# ---------------------------------------------------------------------------

RESOURCE_DEFINITIONS: list[dict[str, Any]] = [
    {
        "uri": "hr://employees/compensation",
        "name": "Employee Compensation Data",
        "description": "Salary, bonus, SSN, and department data for all employees.",
        "mimeType": "application/json",
    },
    {
        "uri": "hr://employees/directory",
        "name": "Employee Directory",
        "description": "Name, department, title, and email for all employees.",
        "mimeType": "application/json",
    },
]


def resource_compensation() -> dict[str, Any]:
    records = []
    for emp in EMPLOYEES.values():
        records.append({
            "employee_id": emp["employee_id"],
            "name": emp["name"],
            "salary": emp["salary"],
            "bonus": emp["bonus"],
            "ssn": emp["ssn"],
            "department": emp["department"],
            "title": emp["title"],
        })
    return {"employees": records}


def resource_directory() -> dict[str, Any]:
    entries = []
    for emp in EMPLOYEES.values():
        entries.append({
            "name": emp["name"],
            "department": emp["department"],
            "title": emp["title"],
            "email": emp["email"],
        })
    return {"employees": entries}


RESOURCES = {
    "hr://employees/compensation": resource_compensation,
    "hr://employees/directory": resource_directory,
}

# ---------------------------------------------------------------------------
# JSON-RPC endpoint
# ---------------------------------------------------------------------------


def _redact_token(value: str) -> str:
    """Trim long bearer tokens in logs so audiences can see the prefix
    without 800 chars of base64 noise."""
    if value.startswith("Bearer ") and len(value) > 50:
        return f"{value[:40]}…[{len(value)-40} chars elided]"
    return value


@app.post("/mcp")
async def mcp_endpoint(request: Request) -> JSONResponse:
    body_bytes = await request.body()

    # Demo headline: print what reached us. This is what the audience
    # watches to see the gateway's effects.
    logger.info("=" * 64)
    logger.info("INBOUND REQUEST  (this is what reached the MCP server)")
    interesting_headers = [
        "authorization", "x-user-token", "x-policy-violation",
        "x-praxis-mcp-method", "x-praxis-mcp-name",
        # Asserted by the gateway's `global.assertions.request:` block. These
        # are the engine telling us what it decided. Unsigned: we believe them
        # because we believe nothing between the gateway and here can set them.
        # `x-user-token` above is stripped by the same block, so it should be
        # absent, and a client that sends `x-auth-user-id` itself should see it
        # replaced rather than forwarded. Scenario 12 checks both.
        "x-auth-user-id", "x-auth-username", "x-auth-roles", "x-auth-context",
    ]
    for name in interesting_headers:
        v = request.headers.get(name)
        if v is not None:
            logger.info("  %-25s = %s", name, _redact_token(v))
    try:
        rpc = json.loads(body_bytes)
        logger.info("  body.method               = %s", rpc.get("method"))
        params = rpc.get("params", {})
        logger.info("  body.params.name          = %s", params.get("name"))
        logger.info("  body.params.uri           = %s", params.get("uri"))
        logger.info("  body.params.arguments     = %s", json.dumps(params.get("arguments", {})))
    except Exception as e:
        logger.warning("body is not JSON-RPC: %s", e)
        return JSONResponse(
            {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": None},
            status_code=400,
        )

    method = rpc.get("method", "")
    rpc_id = rpc.get("id")

    # ----- tools/list -----
    if method == "tools/list":
        tool_defs = [
            {"name": name, "description": f"HR tool: {name}", "inputSchema": {"type": "object"}}
            for name in TOOLS
        ]
        return JSONResponse(
            {"jsonrpc": "2.0", "result": {"tools": tool_defs}, "id": rpc_id},
        )

    # ----- tools/call -----
    if method == "tools/call":
        tool_name = params.get("name", "")
        args = params.get("arguments", {}) or {}
        impl = TOOLS.get(tool_name)
        if impl is None:
            return JSONResponse(
                {
                    "jsonrpc": "2.0",
                    "error": {"code": -32601, "message": f"Unknown tool: {tool_name}"},
                    "id": rpc_id,
                },
                status_code=404,
            )
        try:
            out = impl(args)
        except Exception as e:
            logger.exception("tool '%s' failed", tool_name)
            return JSONResponse(
                {
                    "jsonrpc": "2.0",
                    "error": {"code": -32000, "message": str(e)},
                    "id": rpc_id,
                },
                status_code=500,
            )
        logger.info("OUTBOUND RESPONSE")
        logger.info("  tool                      = %s", tool_name)
        logger.info("  payload                   = %s", json.dumps(out)[:200])
        return JSONResponse(
            {
                "jsonrpc": "2.0",
                "result": {
                    "content": [{"type": "text", "text": json.dumps(out, indent=2)}]
                },
                "id": rpc_id,
            },
        )

    # ----- prompts/list -----
    if method == "prompts/list":
        return JSONResponse(
            {"jsonrpc": "2.0", "result": {"prompts": PROMPT_DEFINITIONS}, "id": rpc_id},
        )

    # ----- prompts/get -----
    if method == "prompts/get":
        prompt_name = params.get("name", "")
        args = params.get("arguments", {}) or {}
        impl = PROMPTS.get(prompt_name)
        if impl is None:
            return JSONResponse(
                {
                    "jsonrpc": "2.0",
                    "error": {"code": -32601, "message": f"Unknown prompt: {prompt_name}"},
                    "id": rpc_id,
                },
                status_code=404,
            )
        try:
            out = impl(args)
        except Exception as e:
            logger.exception("prompt '%s' failed", prompt_name)
            return JSONResponse(
                {
                    "jsonrpc": "2.0",
                    "error": {"code": -32000, "message": str(e)},
                    "id": rpc_id,
                },
                status_code=500,
            )
        logger.info("OUTBOUND RESPONSE")
        logger.info("  prompt                    = %s", prompt_name)
        logger.info("  payload                   = %s", json.dumps(out)[:200])
        return JSONResponse(
            {"jsonrpc": "2.0", "result": out, "id": rpc_id},
        )

    # ----- resources/list -----
    if method == "resources/list":
        return JSONResponse(
            {"jsonrpc": "2.0", "result": {"resources": RESOURCE_DEFINITIONS}, "id": rpc_id},
        )

    # ----- resources/read -----
    if method == "resources/read":
        uri = params.get("uri", "")
        impl = RESOURCES.get(uri)
        if impl is None:
            return JSONResponse(
                {
                    "jsonrpc": "2.0",
                    "error": {"code": -32002, "message": f"Unknown resource: {uri}"},
                    "id": rpc_id,
                },
                status_code=404,
            )
        try:
            out = impl()
        except Exception as e:
            logger.exception("resource '%s' failed", uri)
            return JSONResponse(
                {
                    "jsonrpc": "2.0",
                    "error": {"code": -32000, "message": str(e)},
                    "id": rpc_id,
                },
                status_code=500,
            )
        content_text = json.dumps(out, indent=2)
        logger.info("OUTBOUND RESPONSE")
        logger.info("  resource                  = %s", uri)
        logger.info("  payload                   = %s", content_text[:200])
        return JSONResponse(
            {
                "jsonrpc": "2.0",
                "result": {
                    "contents": [{"uri": uri, "mimeType": "application/json", "text": content_text}]
                },
                "id": rpc_id,
            },
        )

    # ----- unknown method -----
    return JSONResponse(
        {
            "jsonrpc": "2.0",
            "error": {"code": -32601, "message": f"Unsupported method: {method}"},
            "id": rpc_id,
        },
        status_code=404,
    )


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}
