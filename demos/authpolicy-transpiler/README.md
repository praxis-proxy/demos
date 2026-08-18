# AuthPolicy transpiler

A standalone CLI that converts a Kuadrant [`AuthPolicy`](https://docs.kuadrant.io/latest/kuadrant-operator/doc/overviews/auth/) into Praxis policy configuration: a `policy`-filter block plus a policy document. It is best-effort and prints a coverage report saying exactly what was translated, approximated, or skipped.

Use it to see how an existing Kuadrant `AuthPolicy` would look under Praxis + the Praxis Policy Engine, without hand-rewriting anything.

## What it shows

- Kuadrant `AuthPolicy` (`kuadrant.io/v1`, Authorino `v1beta3`) parsed and mapped to the engine's canonical policy form.
- JWT authentication becomes an engine `identity/jwt` plugin; CEL authorization (`patternMatching` predicates, `when`, `patterns`, and the deprecated `selector`/`operator`/`value` form) becomes `cel: { expr }` PDP steps under the `global` policy's `authorization.pre_invocation` block, gated by a native `require(authenticated)` presence check.
- A coverage report that classifies every construct, so gaps are visible rather than silently dropped.
- Fail-closed behaviour: if a policy declares authorization but nothing translates, the output is a `require(false)` deny-all and the CLI exits non-zero.

The following demo shows transpiles the sample policies and reads the coverage report:

[![AuthPolicy transpiler CLI demo](https://asciinema.org/a/Swtb1ZPhv5WCdQoV.svg)](https://asciinema.org/a/Swtb1ZPhv5WCdQoV)

## Quick start

```console
# Print the policy doc + Praxis filter block + coverage report to stdout
cargo run -- examples/jwt-rbac.yaml

# Or write the three artifacts to a directory
cargo run -- examples/jwt-rbac.yaml --out-dir ./out
```

The emitted policy uses the canonical block form:

```yaml
plugins:
  - name: keycloak-jwt
    kind: identity/jwt
    hooks: [identity.resolve]
    on_error: fail
    config: { ... }
global:
  authentication:
    - keycloak-jwt
  authorization:
    pre_invocation:
      - "require(authenticated)"          # native presence gate
      - cel: { expr: "<remapped CEL>" }   # one per Kuadrant rule
```

Kuadrant `patternMatching`/`when` predicates are CEL, so each translated rule is emitted as a `cel: { expr }` PDP step — dispatched to the engine's bundled `cel` resolver, which evaluates full CEL (`startsWith`, `&&`/`||`, literal `in`). The APL-native `require(...)` form is used only for the `require(authenticated)` presence gate and the `require(false)` fail-closed sentinel, because `require(...)` parses APL's own predicate DSL, not CEL.

The coverage report summarises the mapping:

```text
AuthPolicy → Praxis coverage report
===================================
translated: 4   approximated: 4   skipped: 1

[INFO ] translated    authentication/keycloak-jwt
          JWT → identity/jwt ...
[WARN ] approximated  authentication (claims)
          a rule references a nested identity claim (Keycloak realm_access.roles) ...
[WARN ] skipped       authorization/via-opa
          authorization method `opa` is not supported ...
```

Per input policy, `--out-dir` writes `<name>-policy-doc.yaml`, `<name>-policy-filter.yaml`, and `<name>-coverage.txt`. Multiple input files and multi-document (`---`) YAML are supported. The process exits non-zero if any policy fails closed.

Try the other samples to see the range: `examples/apikey-opa.yaml` (unsupported methods, fails closed) and `examples/gateway-defaults.yaml` (`defaults` block, metadata/callbacks reported as gaps).

## End-to-end on Praxis + the Policy Engine

`examples/jwt-cel-http.yaml` is the "happy path": it translates cleanly (no approximations) and its output runs, unedited, as a generic-HTTP (L7) authorization policy on Praxis with the Praxis Policy Engine. The `e2e/` directory is a **self-contained** runner — it brings up its own Keycloak, transpiles the example, builds Praxis, and proves the CEL decisions with real persona tokens:

```console
cd e2e
./run-demo.sh
```

The run transpiles the AuthPolicy, deploys the emitted policy on Praxis, and proves the CEL decisions with alice/bob tokens — showing both the original AuthPolicy and the deployed policy along the way:

[![AuthPolicy transpiler end-to-end demo](https://asciinema.org/a/BeWTbAEyGrzEQvAN.svg)](https://asciinema.org/a/BeWTbAEyGrzEQvAN)

That single command:

1. Starts **Keycloak** (`e2e/docker-compose.yml`, realm `e2e/keycloak/realm-export.json`) and waits for OIDC discovery.
2. Transpiles `examples/jwt-cel-http.yaml` into `e2e/out/` (policy doc + Praxis filter block).
3. Injects a localhost-dev `insecure_http` shim into the emitted JWKS `decoding_key` (never needed with an https IdP).
4. Builds **Praxis** with `--features policy-engine` (`e2e/build-praxis.sh`) — from the sibling `../../../../praxis` checkout if there is one, otherwise a clone at the **pinned commit** in `DEFAULT_GIT_REF`, so a run is reproducible rather than tracking a moving branch. Override with `PRAXIS_BIN` / `PRAXIS_DIR` / `PRAXIS_GIT_URL` / `PRAXIS_GIT_REF` (`PRAXIS_GIT_REF=main` tracks the branch).
5. Starts a tiny echo backend (`:9200`) and the gateway (`:8095`, `e2e/praxis.yaml`: `policy` → `router` → `load_balancer`).
6. Mints `alice`/`bob` tokens (`e2e/mint-token.sh`) and exercises the CEL policy.

The AuthPolicy expresses two CEL rules over the HTTP request line and top-level identity claims — Kuadrant array-membership maps to the engine's boolean identity namespaces (`role.*` / `perm.*`), which the `standard` claim mapper populates:

- **reads** (`GET`) require the `tool_execute` permission — `'tool_execute' in auth.identity.permissions` → `has(perm.tool_execute) && perm.tool_execute`
- **writes** (`POST`/`DELETE`) require the `hr` role — `'hr' in auth.identity.roles` → `has(role.hr) && role.hr`

| Request | Persona | Result | Why |
|---|---|---|---|
| `GET /api/...`  | alice (engineer) | **200** | has `tool_execute` |
| `GET /api/...`  | bob (hr)         | **200** | has `tool_execute` |
| `POST /api/...` | alice (engineer) | **403** | CEL deny — not `hr` |
| `POST /api/...` | bob (hr)         | **200** | CEL allow — `hr` |
| `GET /api/...`  | (no token)       | **401** | identity gate |

Requirements: `docker` (compose), `cargo`, `python3`, `curl`, `jq`. Keycloak binds host port `8081` and imports the `policy-demo` realm — the same as the sibling `policy-engine` demo, so run only one at a time. First run is slow (Praxis release build); later runs reuse the cached binary.

## Scope and limitations

The transpiler covers the subset that maps cleanly to CEL. Everything else is reported, not dropped.

- **Authentication:** JWT only (JWKS, issuer, audiences). `apiKey`, `x509`/mTLS, `anonymous`, `oauth2Introspection`, and `kubernetesTokenReview` are reported as gaps. Multi-rule priority/fallback is reported, not preserved.
- **Authorization:** CEL only. `opa` (Rego), `spicedb`, and `kubernetesSubjectAccessReview` are reported as gaps.
- **Policy composition:** a single policy's rules. The `defaults`/`overrides` hierarchy and Gateway-to-route merge strategies (GEP-2649) are collapsed to a single flat policy and reported.
- **Response:** custom `denyWith` (status/body/headers) is **not** yet carried into the emitted policy — it is reported as `approximated`, and a denial uses the engine's default (401 identity / 403 authorization). Success-response injection is best-effort and reported.
- **Metadata and callbacks:** reported as gaps.
- **Binding and lifecycle (out of scope):** no Gateway API translation (`targetRef` to listeners/routes), no CRD ingestion or operator, no reverse translation, no multi-version schema support.
- **Signing algorithms:** not expressible in a Kuadrant JWT block, so the emitted trusted issuer defaults to `RS256` (the OIDC default). Widen it in the emitted policy if the IdP signs with ES256/etc.
- **CEL namespaces:** predicates are lexically remapped from Kuadrant's vocabulary to the engine's. The HTTP request line maps directly (`request.*` → `http.*`). Identity RBAC uses the membership idiom: `'<v>' in auth.identity.roles` / `.permissions` / `.groups`|`.teams` → the engine's boolean namespaces `has(role.<v>) && role.<v>` / `perm.<v>` / `team.<v>`, which is what the `standard` claim mapper populates. Other identity references fall back to `auth.identity.* → claim.*` and are a runtime gap wherever `claim.*` is unpopulated (e.g. nested `realm_access.roles`, scalar claims). A reference that does not remap at all (e.g. `auth.metadata.*`) is reported as a gap and dropped rather than emitted as wrong-namespace CEL.

The emitted documents are checked by the golden corpus under `tests/` and the structural invariant assertions in `src/main.rs`. This demo depends only on `serde`, `serde_yaml`, and `clap`; it does not parse its output through the engine's crate.

## Files

| Path | Purpose |
|------|---------|
| `src/main.rs` | CLI entry: parse args, transpile each input, emit artifacts, exit non-zero on fail-closed. |
| `src/authpolicy/model.rs` | Serde model for the supported `AuthPolicy` subset (best-effort parse). |
| `src/authpolicy/cel.rs` | Kuadrant to Praxis Policy Engine CEL namespace remap (`auth.identity.*` to `claim.*`, `request.*` to `http.*`). |
| `src/authpolicy/translate.rs` | Core translation to the canonical engine blocks; fail-closed logic. |
| `src/authpolicy/emit.rs` | Serializable shapes for the policy doc + Praxis filter block. |
| `src/authpolicy/report.rs` | Coverage report (translated / approximated / skipped). |
| `examples/*.yaml` | Sample `AuthPolicy` inputs. |
| `tests/fixtures/authpolicy/` | Golden corpus (`*.yaml` inputs + `*.golden` expected output). |
