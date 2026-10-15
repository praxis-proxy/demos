# Creating a free trial of IBM Verify tenant
Visit URL: https://www.ibm.com/products/verify?lnk=L0G in a browser and click on the blue, "Start a free trial" push-button.
Login using your IBMiD and provide your desired hostname (in this demo, "praxis-1.verify.ibm.com" is the tenant). 
Once the tenant has been provisioned, login to the instance and access the admin ui. e.g. [https://praxis-1.verify.ibm.com/ui/admin](https://praxis-1.verify.ibm.com/ui/admin)
## Create an API client for tenant provisioning
- Expand the "Security" section in the left-hand navigation pane and click on "API access".
- Click the blue, "Add API client +" push-button.
  - Click the "Permission name" checkbox to assign all entitilements to the API client.
  - On the "API credentials" page, take the defaults and click the "Next" push-button
  - On the "Custom scopes" page, click the "Next" push-button
  - On the "IP filter" page, click the "Next" push-button
  - On the "Additional properties" page, click the "Next" push-button
  - On the "Confirm Configuration" page, enter the name, "VERIFY_ADMIN_CLIENT_ID" and press the blue, "Create API client" push-button
- Copy the file .env.verify.example to .env.verify
- Copy the client ID (generated on save of the API client in the previous step) as VERIFY_ADMIN_CLIENT_ID= value in .env.verify
- Copy the client secret as VERIFY_ADMIN_CLIENT_SECRET= value in .env.verify
- Create the post_deploy_variables.json file:
```bash
echo '{ "variables": {"IBM_VERIFY_TOKEN_ENDPOINT": "https://<your_company_name>.verify.ibm.com/oauth2/token"}}' > post_deploy_variables.json
```
# Verify tenant provisioning

Provisions the demo into an IBM Verify tenant — the four personas and the OAuth
clients that turn their attributes into token claims — using
`keycloak/realm-export.json` as the source of truth.

| File | Purpose |
|---|---|
| `users.csv` | The user source — personas, roles, and the four policy attributes |
| `import-verify-users.sh` | Reads the CSV, defines the custom attributes, creates the users |
| `clients.csv` | The client source — the realm export's four clients, mapped onto Verify |
| `import-verify-clients.sh` | Creates the applications, their grants, and their claim mappers |

Together these automate requirement **R6** ("documented tenant setup") from
`docs/brainstorms/2026-08-31-ibm-verify-idp-requirements.md`. Decision **D5**
kept tenant setup manual; the users, their custom attributes, and the clients'
claim mappers are the parts where doing it by hand reliably costs the most time,
and where a mistake surfaces as a policy deny rather than an error.

## Quick start

```bash
# 1. Inspect what would be sent. Needs no credentials.
./verify/import-verify-users.sh   --dry-run
./verify/import-verify-clients.sh --dry-run

# 2. Add an admin API client to .env.verify (see .env.verify.example)
#    Entitlements: manageUsers + manageAttributes + manageAppAccessAdmin

# 3. See what the tenant actually reports before writing to it
./verify/import-verify-clients.sh --discover

# 4. Provision — users FIRST, and not only for the claim mappers: the clients
#    script grants each persona sign-on access by SCIM id, so the users must
#    exist before the clients are created.
./verify/import-verify-users.sh
./verify/import-verify-clients.sh

# 5. Confirm the claims actually land in a token
./mint-verify-token.sh alice | cut -d. -f2 | base64 -d 2>/dev/null | jq .
./verify-ibm-verify-token-exchange.sh
```

Re-running either script is safe: existing users and clients are reported and
left unchanged rather than overwritten. Use `--delete` then re-run to replace
them.

## Application entitlement

Creating a client is not enough to let it mint. Application access is a separate
resource, and without it every password grant fails:

```
CSIAQ0279E Only entitled users can single sign-on to the application.
```

`import-verify-clients.sh` grants it automatically for `role=mint` clients via
`POST /v1.0/owner/applications/{id}/entitlements`, so there is **no manual
console step**. Two models:

| Flag | Effect |
|---|---|
| *(default)* | Explicit per-user grants for the personas in `users.csv` — only they may sign on |
| `--all-users` | `birthRightAccess: true` — every user in the tenant, the console's "Automatic access for all users and groups" |
| `--no-entitle` | Skip it; the script then reports which clients still need access |

Explicit is the default because it matches how this tenant's `praxis-identity-1`
is already configured, and because the demo's argument rests on four personas
whose differences matter — a client any tenant user can mint from weakens the
eve-vs-bob contrast. Use `--all-users` on a throwaway tenant.

`--discover` prints the current state per application, so you can see who is
entitled before changing anything.

Note this is **invisible in the application object**: `birthRightAccess` reads
back as `null` on `GET /v1.0/applications/{id}` — write-only there, the same trap
as `idTokenSigningAlg` — and the grants live under `/v1.0/owner/...`. Reading an
application back and diffing it against a working one will not reveal it. `GET`
on the owner path does.

## What the scripts do not do

**They do not edit `policy-verify-opa.yaml` directly** — they do not need to.
That file is now *generated* from `policy-verify-opa.yaml.tmpl` by
`render-verify-config.sh`, which substitutes the tenant URL and the exchange
`client_id` from the environment, defaulting to `post_deploy_variables.json`.
`restart.sh` renders it automatically on any `*verify*` config, so the ids that
`import-verify-clients.sh` writes back are picked up with no manual edit.

```bash
./render-verify-config.sh           # render (no-op when up to date)
./render-verify-config.sh --check   # non-zero if stale, for CI
VERIFY_TENANT_URL=https://other.verify.ibm.com ./render-verify-config.sh
```

Why a template rather than an env var in the YAML: Praxis has no env-var
indirection for `client_id`. Only the *secret* does (`client_secret_source:
{kind: env_var}`); `client_id` is a plain `String` read straight into the
outbound Basic auth header, so a literal `${VAR}` there would be sent to Verify
verbatim and fail as `invalid_client` at the token endpoint — well away from the
cause. Substitution therefore has to happen before the gateway reads the file.

The client **secret** is deliberately *not* templated. It stays a runtime lookup
by the gateway, so a live credential never lands in a rendered file on disk.

## Two things worth knowing before editing

**The trailing `""` pad is gone — the `ibmverify` claim-mapper preset replaced
it.** Verify serialises a single-valued custom attribute as a JSON scalar, and
Praxis's standard claim mapper read `roles`/`teams`/`permissions` via
`Value::as_array`, which returns `None` for a string — so a one-role persona got
an empty `subject.roles`, silently, and `require(role.hr)` then failed as a
*policy deny* rather than a config fault. Both importers worked around it by
appending a `""`, at the cost of `""` becoming a real set member in audit records
and `X-Policy-*` output.

The preset wraps a scalar into a one-element vec on the engine side, so nothing
has to force array shape any more. It is selected by `claim_mapper: ibmverify` on
the `jwt-user` and `jwt-agent` plugins in `policy-verify-opa.yaml.tmpl`.

Claims are now unpadded end to end:

```
stored on the user   roles: ["engineer"]
minted in the token  roles: ["engineer"]
```

Two things to know when re-provisioning. The pad was injected by each client's
CELx claim mapper, not by the user record — so a tenant whose clients were
created by an older copy of `import-verify-clients.sh` keeps minting
`["engineer", ""]` regardless of what `import-verify-users.sh` stores, because
the mapper rebuilds the array from `getCustomValues()`. **Re-run both importers,
not just the users one.** And a gateway *without* the preset needs the padding
back; see git history for the mappers that append it.

**Passwords come from the CSV, not from a rule.** They currently follow
`<username>Lab3151`, matching `post_deploy_variables.json` so
`mint-verify-token.sh` works against a freshly provisioned tenant. The importer
reads the column rather than computing the pattern, because the tenant's actual
passwords are the source of truth — a provisioner that hands you a
non-patterned password would otherwise produce a tenant nobody can log into,
and the failure would surface as a 400 from the ROPC grant, well away from the
cause.

Columns are read **by header name**, so the CSV can be reordered or extended
without touching the script. Multi-valued cells are pipe-separated.

## Attribute slots

Custom attributes must exist in the tenant schema before a user payload may
carry one; an undefined attribute fails the create with a validation error. The
importer claims four of the predefined `customAttribute1..150` slots:

| Attribute | Slot | Read by |
|---|---|---|
| `roles` | `customAttribute1` | `require(role.hr)` — the APL policy gate |
| `permissions` | `customAttribute2` | `perm.view_ssn` redaction, tool gates |
| `teams` | `customAttribute3` | policy context |
| `gh_permissions` | `customAttribute4` | scenario 4's exchange (passthrough claim) |

These numbers are arbitrary but must stay stable — changing one after users
exist orphans the stored values. Note the slots the importer *claims* are not
the slots the owner's tenant actually uses (it was built by hand first):

| Attribute | Importer | This tenant |
|---|---|---|
| `roles` | `customAttribute1` | `customAttribute2` |
| `permissions` | `customAttribute2` | `customAttribute4` |
| `teams` | `customAttribute3` | `customAttribute3` |
| `gh_permissions` | `customAttribute4` | `customAttribute1` |

This is harmless — the attributes already exist, so the importer skips them, and
claim mapping resolves by `scimName` rather than by slot. It only matters if you
provision a *fresh* tenant and then expect the slot numbers to match this one.
The "this tenant" column above is the hand-built `praxis-1`; a tenant the
importer provisions from scratch (e.g. `praxis-2`) gets the importer's slots.

**`gh_permissions` has `scimName` `ghpermissions`** — no underscore. This is not
a quirk of one hand-built tenant: Verify's `scimName`/`attributeName` validator
accepts **letters only**, and rejects anything else with

```
400  CSIAI0096E  The value gh_permissions is not valid for attribute [scimName].
```

Note that is a 400 *without* the word "exists", so it is not the idempotent
already-defined case. `import-verify-users.sh` therefore carries the scimName as
the third field of each `ATTRS` entry (`displayName:slot:scimName`) and uses it
for both the attribute definition and the `customAttributes` entries in each
user's SCIM payload — the display name keeps the underscore, the wire never sees
it. Adding a new attribute whose name is not purely alphabetic means giving it a
letters-only scimName there.

The CELx mappers call `user.getCustomValues("<scimName>")`, so a mapper written
against the display name yields nothing and scenario 4 loses its permissions
claim silently. `import-verify-clients.sh` resolves each scimName from the
tenant rather than assuming; `--discover` prints the mapping.

Two other tenant constraints the importer encodes, both discovered the same way:

- **`emailVerified` is not accepted** in the IBM user extension —
  `CSIAI0111E The supplied JSON contained an invalid attribute: emailVerified`.
  It is also unnecessary; `notifyType: NONE` is what suppresses the
  account-created mail to the non-resolving `@corp.com` addresses.
- A user create returning **201 does not prove the attributes stored**. Read the
  user back and check `customAttributes` before trusting a fresh tenant.

The realm export's `groups` attribute is deliberately not carried over: it
duplicates `teams` for all four personas and no Verify-path policy reads it.
Add a `groups` column and an `ATTRS` entry if that changes.

## Clients — what the realm export maps onto

The realm export has four clients. Only two are real OAuth clients on Verify:

| Keycloak | Verify | Role |
|---|---|---|
| `hr-copilot` | `praxis-identity-1` | Mints user + client tokens (ROPC + `client_credentials`) |
| `praxis-gateway` | `praxis-sts-1` | Performs the RFC 8693 exchange |
| `github-api` | *(audience string)* | Registered for parity only — see below |
| `workday-api` | *(audience string)* | Registered for parity only — see below |

The two must stay distinct: Verify refuses to let a client exchange its own
tokens (`CSIAQ5207E`), the same split the realm export already has.

`github-api` and `workday-api` are **not clients** on Verify — they are audience
strings in the exchange client's `audiences` list. `clients.csv` registers them
anyway so the console shows the same four names a viewer sees in Keycloak. and it
does reproduce Keycloak's per-audience `gh-permissions-as-scope` mapper, which is
what makes scenario 4's assertion load-bearing there. Nothing in the demo authenticates as either one.
They cannot be pure placeholders either — Verify rejects an application with every grant type
disabled (`CSIAQ0032`) — so each carries `clientCredentials` and nothing else.
Delete those two rows if you would rather the console show only what
participates; the demo behaves identically.

### Field-level facts, none of them fully documented

Each was confirmed by creating and deleting a throwaway application on the live
tenant. They are the reason this script exists rather than a `curl` snippet.

| Thing | Value | Note |
|---|---|---|
| `templateId` | `998` | **Not** `"0001"`, which circulates in examples. No documented enum; `--discover` reads it off the tenant. |
| JWT tokens | `providers.oidc.token.accessTokenType: "jwt"` | Not `accessTokenFormat`. |
| JWT signing | `providers.oidc.properties.idTokenSigningAlg` | **Required** when `accessTokenType` is `jwt`, despite the name. Omit it and every create fails `CSIAQ0257`. The GET response omits it, so it cannot be discovered by reading an app back. |
| Grant types | `"true"` / `"false"` | Quoted strings, not JSON booleans. |
| Claim mappers | `{ targetName, function: { custom: <CELx> } }` | The API reference describes `JWTAttributeMapBean` as `sourceId` + `targetName`; the working shape is a CELx function calling `user.getCustomValues("<scimName>")`. |
| `sso` | `{ userOptions: "oidc" }` | Required even for a pure OIDC app; satisfies it without inventing a `domainName`. |
| Credentials | Not in the `201` response | It returns only `_links.self.href`; `GET` that to read the generated `clientId` / `clientSecret`. |
| Admin entitlement | `manageAppAccessAdmin` | "Manage application lifecycle". Not `manageApplications`. |
| Sign-on access | `POST /v1.0/owner/applications/{id}/entitlements` | Separate resource, not an application field. `birthRightAccess` for all users, or `additions[]` with a SCIM `subjectId` per user (`grantType: "BRT"`). Needs `manageAppAccessAdmin` or `manageAppAccessOwner`. |
