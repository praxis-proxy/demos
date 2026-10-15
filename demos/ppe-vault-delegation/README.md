# PPE Vault Community GitHub delegation demo

This demo puts Praxis AI and the Praxis Policy Engine (PPE) between an
agent-compatible MCP caller and GitHub. PPE validates a user's JWT, authorizes
the tool call, logs in to a local Vault Community server with that same JWT,
and retrieves the GitHub credential enrolled for that user. The credential is
attached only to a local MCP bridge, which calls GitHub `GET /user` and returns
selected identity fields—not the token—to the caller.

It demonstrates credential custody and per-user isolation with software anyone
can run locally. It is intentionally a development recipe, not a production
Vault deployment.

## Security model

- Vault policy confines the JWT alias `alice` to
  `secret/data/agents/alice/*`; changing the requested path cannot cross that
  boundary.
- The GitHub token is read from `gh auth token`, stdin, or a silent prompt. It
  is piped directly into Vault and never written to disk or accepted as a CLI
  argument.
- Praxis attaches the token only after policy allows the request. The
  `github_denied` scenario proves an early deny makes no Vault or GitHub call.
- The bridge never logs or serializes `Authorization` and returns only GitHub
  `login`, numeric `id`, and `html_url`.

Use a fine-grained GitHub personal access token with **no repository access and
no additional permissions**. GitHub's `GET /user` endpoint does not require a
fine-grained permission; the token only needs to identify its owner. A classic
personal access token with no scopes also works, but a fine-grained token is
preferred. The endpoint accepts `Authorization: Bearer <token>`.

> Vault runs here in insecure, in-memory developer mode with a known root token
> and loopback HTTP. The RSA signing key is generated locally under `.state/`.
> Never copy these settings into a production deployment.

## Prerequisites

- Docker with Compose v2
- Rust 1.96 (`rustup toolchain install 1.96.0`) and Cargo
- `curl`, `git`, `jq`, `openssl`, and Python 3
- Optional: GitHub CLI (`gh`) already authenticated
- Loopback ports `8090`, `8200`, and `9100` available

## Run it

```console
./up.sh
./scripts/enroll.sh alice --from-gh
./scripts/run-demo.sh
./down.sh
```

Without GitHub CLI, use the silent prompt:

```console
./scripts/enroll.sh alice
```

Or pipe from a secret-aware command:

```console
secret-command | ./scripts/enroll.sh alice --stdin
```

The scenario runner proves three outcomes:

1. Alice is enrolled, so `github_whoami` returns her GitHub login.
2. Bob is authenticated but unenrolled, so PPE denies with
   `delegation.vault_secret_not_found` and the bridge is not called.
3. `github_denied` is rejected before `delegate(...)`; Vault audit-request and
   bridge-call counters do not change.

It also reads Alice's credential back through the local demo root token solely
as a test oracle. The value stays in shell memory and is used to assert that it
is absent from every response, service log, generated state file, and tracked
demo file. It is never printed or placed in a process argument.

## Cleanup

Run `./down.sh` to stop the gateway and containers, remove the Compose volumes,
and delete `.state/`, including generated keys, JWTs, policy, logs, and the
recorded expected login. This does not revoke the GitHub token itself; revoke
the token in GitHub when the demo is finished.

## What `up.sh` configures

1. A pinned `hashicorp/vault:2.1.1` Community server in dev mode.
2. An ephemeral RS256 key and one-hour Alice/Bob JWTs with issuer
   `https://ppe-vault-demo.local`, audience `vault-demo`, and `sub` equal to the
   user name.
3. Vault JWT auth against that public key, plus a five-minute login role.
4. A Vault ACL using the JWT mount accessor:

   ```hcl
   path "secret/data/agents/{{identity.entity.aliases.<accessor>.name}}/*" {
     capabilities = ["read"]
   }
   ```

5. A thin Praxis AI gateway with the `mcp` and `policy` filters.
6. A local MCP bridge that forwards the delegated credential to GitHub.

The enrollment logical path is `secret/agents/<sub>/github`; because `secret/`
is KV v2, the corresponding ACL path contains the additional `data/` segment.

## Production adaptation

- Replace Vault dev mode with persistent storage, TLS, normal unseal and root
  token handling, audit retention, backup, and HA appropriate to your threat
  model.
- Replace static PEM validation with your IdP's OIDC discovery or JWKS endpoint.
- Bind the Vault role to the exact issuer, audience, and claims PPE accepts.
- Keep `sub` stable and issuer-controlled; do not key secret paths by email,
  display name, request labels, or session IDs.
- Remove `insecure_http: true` and loopback/private-endpoint development opts.
- Add a real enrollment workflow with authentication, authorization, rotation,
  deletion, and an auditable ownership model.

GitHub OAuth device flow is a useful follow-up, but it requires an owned OAuth
app with device flow enabled and an explicit client-id/rotation lifecycle. This
baseline deliberately accepts an already-issued, least-privilege token.
