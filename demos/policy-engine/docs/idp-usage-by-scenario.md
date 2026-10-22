# Keycloak and IBM Verify across the scenarios

Which IdP each scenario touches, and *where* in the request path it touches it.

The IdP is one axis of the demo matrix; the PDP (Cedar / CEL / Rego) is the other.
`USE_VERIFY=true` picks the IdP the scenario scripts mint from, and
`GATEWAY_CONFIG=praxis-verify-*.yaml` picks the IdP the gateway validates and
exchanges against. Both halves must agree or every scenario fails at
`identity.resolve` with `auth.untrusted_issuer`.

## How the IdP is reached

```mermaid
flowchart TB
    SW{"USE_VERIFY ?"}
    SW -->|"false (default)"| MK["<b>mint-token.sh</b><br/>password + client_credentials<br/>localhost:8081/realms/policy-demo"]
    SW -->|"true"| MV["<b>mint-verify-token.sh</b><br/>password + client_credentials<br/>tenant /oauth2/token"]

    MK --> ID
    MV --> ID

    subgraph GW["Praxis gateway :8090"]
        direction TB
        ID["① identity.resolve<br/>jwt-user · jwt-client<br/>trusted_issuers + JWKS"]
        APL["② APL gate<br/>require(role / team / perm)"]
        PDP["③ PDP step<br/>Cedar | CEL | Rego"]
        DEL["④ token.delegate<br/>RFC 8693 exchange"]
        ELI["⑤ elicit<br/>manager-approver (CIBA)"]
        PLUG["⑥ plugins<br/>pii-scan · taint<br/>audit-log · assertions"]
        ID --> APL --> PDP --> DEL --> ELI --> PLUG
    end

    PLUG --> UP["hr-mcp upstream :9100"]

    ID -. "JWKS fetch" .-> IDP
    DEL -. "exchange client<br/>praxis-gateway / praxis-sts-1" .-> IDP
    ELI -. "backchannel + poll" .-> IDP

    IDP{{"Selected IdP<br/>Keycloak :8081<br/>or IBM Verify tenant"}}

    classDef kc fill:#1f4e79,stroke:#0d2b45,color:#fff
    classDef iv fill:#7a2f8f,stroke:#45194f,color:#fff
    classDef idp fill:#4a4a4a,stroke:#222,color:#fff
    class MK kc
    class MV iv
    class IDP idp
```

## Per-scenario IdP reach

Every scenario mints a token from the selected IdP and has it validated at
step ① above. What differs is how much further down the chain the IdP is used —
a scenario denied at the APL gate or the PDP never reaches a token exchange.

```mermaid
flowchart TB
    subgraph A["Both IdPs · denied at the gateway"]
        direction TB
        S02["02 · alice deny<br/>get_compensation<br/>require(role.hr) fails"]
        S05["05 · alice external<br/>search_repos<br/>PDP denies"]
        S06["06 · bob APL deny<br/>search_repos<br/>team gate fails"]
        S07["07 · bob PII deny<br/>send_email<br/>pii-scan denies"]
        S08["08 · session taint<br/>send_email<br/>session_tainted_secret"]
        S02 ~~~ S05 ~~~ S06 ~~~ S07 ~~~ S08
    end

    subgraph B["Both IdPs · reaches token exchange"]
        direction TB
        S01["01 · bob allow<br/>get_compensation<br/>→ workday-api"]
        S03["03 · eve redact<br/>get_compensation<br/>→ workday-api + redact"]
        S04["04 · alice internal<br/>search_repos<br/>→ github-api"]
        S09["09 · taint isolation<br/>send_email + get_compensation<br/>→ workday-api"]
        S12["12 · assertions<br/>get_compensation<br/>→ workday-api + headers"]
        S01 ~~~ S03 ~~~ S04 ~~~ S09 ~~~ S12
    end

    subgraph C["Both IdPs · no exchange on route"]
        direction TB
        S10["10 · adjust under threshold<br/>adjust_compensation $5k<br/>no approval step reached"]
    end

    subgraph D["Keycloak only"]
        direction TB
        S11["11 · manager approval<br/>adjust_compensation $25k<br/>CIBA + auth-channel :5001"]
        S13["13 · workload identity<br/>get_headcount<br/>SPIFFE JWT-SVID + SPIRE"]
        S11 ~~~ S13
    end

    subgraph E["IBM Verify only"]
        direction TB
        S14["14 · agent identity<br/>search_repos_agent<br/>Agent Registry status"]
    end

    NA["IdP used to mint and validate only.<br/>No exchange · upstream never called."]
    NB["Keycloak/Verify: audience-scoped token."]
    NC["Route has no delegate step,<br/>so both IdPs behave identically."]
    ND["Verify works via<br/>policy-verify-opa-ciba.yaml.tmpl.<br/>Requires valid e-mail address for eve to approve CIBA"]
    NE["Keycloak's SPIFFE-native client auth<br/>(providerId: spiffe) has no Verify<br/>counterpart. Needs WITH_SPIRE=1."]
    NF["Verify's Agent Registry has no Keycloak<br/>counterpart. The gateway reads<br/>/v1.0/Agents and denies unless ACTIVE."]

    S08 --> NA
    S12 --> NB
    S10 --> NC
    S11 --> ND
    S13 --> NE
    S14 --> NF

    classDef both fill:#1f4e79,stroke:#0d2b45,color:#fff
    classDef kconly fill:#7a2f8f,stroke:#45194f,color:#fff
    classDef iv fill:#1f6f4a,stroke:#0d3b27,color:#fff
    classDef note fill:#f5f5f5,stroke:#999,color:#222
    class S01,S02,S03,S04,S05,S06,S07,S08,S09,S10,S12 both
    class S11,S13 kconly
    class S14 iv
    class NA,NB,NC,ND,NE,NF note
```

## Verify configuration differences

- **Claim shape.** Verify emits `roles` / `teams` / `permissions` as scalars at
  N=1, so the Verify configs use `claim_mapper: ibmverify` instead of
  `standard`. Without it, `subject.roles` silently empties and every
  single-valued persona presents as a policy deny.
- **Dual-trust workaround.** The Verify configs currently trust the Keycloak
  issuer alongside Verify (commit `c596244`), because the chat agent and the
  auth-channel still mint from Keycloak on some paths. A 200 therefore does not
  prove Verify validated the token — confirm the issuer in the audit record.
- **Separate clients.** Verify refuses to let a client exchange tokens it
  issued itself (`CSIAQ5207E`), so minting uses `HR_COPILOT_CLIENT_ID` and
  exchange uses `VERIFY_GATEWAY_CLIENT_ID` — the same split as Keycloak's
  `hr-copilot` mints / `praxis-gateway` exchanges.

## Agent identity: why 13 and 14 do not port

Scenario 13 requires Keycloak SPIFFE client authentication. Scenario 14 requires
Verify Agent Registry.

| | 13 — SPIFFE workload identity | 14 — Verify agent identity |
|---|---|---|
| Credential | SPIFFE JWT-SVID, `X-Workload-Token` | OIDC JWT from `client_credentials`, `X-Agent-Token` |
| Issued because | SPIRE attested the process | the agent's OAuth client authenticated |
| IdP mechanism | Keycloak `providerId: spiffe` + `client_assertion_type: …jwt-spiffe` | Agent Registry record (`/v1.0/Agents`) linked to the client |
| Answers | "is this really the agent?" | "is this agent approved to act?" |
| Revocation | remove the registration entry; existing SVIDs live out their TTL | flip status to `SUSPENDED`; the gateway refuses within its cache TTL |
| Enforced by | Keycloak, at client authentication | **the gateway** — Verify does not gate issuance on status |
| On the other IdP | no Verify counterpart | no Keycloak counterpart |

Verify can issue tokens to suspended agents, so `run(agent-status)` reads the
registry and enforces status on the tool route. Cached status remains valid
until its TTL expires.
