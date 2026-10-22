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

Run the user importer before the client importer so application entitlements
can reference existing SCIM user ids.

## Quick start

```bash
# 1. Inspect what would be sent. Needs no credentials.
./verify/import-verify-users.sh   --dry-run
./verify/import-verify-clients.sh --dry-run

# 2. Add an admin API client to .env.verify (see .env.verify.example)
#    Entitlements: manageUsers + manageAttributes + manageAppAccessAdmin

# 3. See what the tenant actually reports before writing to it
./verify/import-verify-clients.sh --discover

# 4. Provision users before clients; application entitlements need their SCIM ids.
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

Explicit grants limit access to the demo personas. `--all-users` grants
application access to every tenant user.

`--discover` prints the current state per application, so you can see who is
entitled before changing anything.

Read entitlement state from the owner endpoint. The application object does
not return it in `birthRightAccess`.

## Policy rendering

`render-verify-config.sh` generates `policy-verify-{opa,cel,cedar}.yaml` from
the matching templates. `restart.sh` renders the selected variant using tenant
and exchange-client ids from the environment or `post_deploy_variables.json`.
Edit the templates; generated files are overwritten.

```bash
./render-verify-config.sh           # render (no-op when up to date)
./render-verify-config.sh --check   # non-zero if stale, for CI
VERIFY_TENANT_URL=https://other.verify.ibm.com ./render-verify-config.sh
```

Praxis reads `client_id` as a literal string, so the renderer substitutes it
before startup. Client secrets remain runtime environment lookups and are not
written into generated policies.

## Claims and CSV format

Use `claim_mapper: ibmverify` on `jwt-user` and `jwt-client` to handle Verify's
scalar role and permission claims. Do not add empty-string padding to user
attributes or CELx claim mappers. Older tenant clients may still have padded
mappers; inspect them when re-provisioning. The `jwt-agent` resolver uses
`standard` because client-credentials tokens carry no user roles or teams.

Passwords are read from the CSV. The demo values match
`post_deploy_variables.json`; keep these consistent for `mint-verify-token.sh`.
Columns are read by header name. Multi-valued cells use `|` separators.
`manager` holds one userName, resolved to a SCIM relationship after user creation.

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

Keep attribute slots stable after users exist; changing slots orphans stored
values. Existing tenants may use different slots. Claim mapping resolves by
`scimName`, so the slot numbers do not need to match this table.

**`gh_permissions` has `scimName` `ghpermissions`** — no underscore. This is not
a quirk of one hand-built tenant: Verify's `scimName`/`attributeName` validator
accepts **letters only**, and rejects anything else with

```
400  CSIAI0096E  The value gh_permissions is not valid for attribute [scimName].
```

Define each `ATTRS` entry as `displayName:slot:scimName`, with a letters-only
SCIM name. The client importer resolves these names from the tenant for
`user.getCustomValues()`; `--discover` prints the mapping.

Other constraints:

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

`github-api` and `workday-api` serve as audience names. Their CSV rows create
applications for parity with Keycloak, but no demo request authenticates as
either one. They enable `clientCredentials` because Verify rejects applications
with no enabled grant (`CSIAQ0032`).

### Client fields

| Field | Required value or behavior |
|---|---|
| `templateId` | Defaults to `998`; use `--discover` to check the tenant. |
| `providers.oidc.token.accessTokenType` | `jwt` |
| `providers.oidc.properties.idTokenSigningAlg` | Required for JWT access tokens (`CSIAQ0257`); omitted on GET. |
| Grant flags | Strings `"true"` / `"false"` |
| Claim mappers | `{targetName, function: {custom: <CELx>}}` |
| `sso` | `{userOptions: "oidc"}` |
| Credentials | Read generated `clientId` / `clientSecret` through `_links.self.href`. |
| Provisioning entitlement | `manageAppAccessAdmin` |
| Application access | `POST /v1.0/owner/applications/{id}/entitlements`; explicit SCIM user grants or `birthRightAccess`. |

Token-exchange clients also need `subjectTokenTypes` and `requestedTokenTypes`
under `additionalConfig`. DPCM request mapping uses `{name, custom}` entries in
`tokenRequestMap`; its purpose must already be active. The importer creates a
draft purpose and publishes it with a versioned PATCH before creating clients.

## Agent identity (scenario 14)

`import-verify-clients.sh` provisions the agent from the `role=agent` row in
`clients.csv`. That row creates:

1. an application-level OIDC client (`client_credentials`, JWT access token,
   audiences `praxis-gateway` + `github-api`), and
2. an **Agent Registry** record (`POST /v1.0/Agents`) with the client
   associated to it, which is what carries the governance state.

Ids are written back to `post_deploy_variables.json` as `AGENT_CLIENT_ID`,
`AGENT_CLIENT_SECRET` and `VERIFY_AGENT_ID`.

Agent Registry constraints:

- **Create always lands in `UNDER_REVIEW`.** `POST /v1.0/Agents` ignores the
  `status` field — sending `"ACTIVE"` still stores `UNDER_REVIEW`. The importer
  therefore POSTs and then promotes with a PUT, reporting
  `UNDER_REVIEW promoted to ACTIVE`. The gateway denies agents left under review.
- **`oauthClients` is write-only.** It is required on write
  (`CSINH2100E` without `issuer`) but always reads back as `null`, even
  immediately after a 201 that accepted it. Do not verify the association by
  reading it; check the write's status code.
- **PUT is a full replace.** A PUT carrying only `status` clears
  `description`, `tags` and the client association. `set-agent-status.sh`
  reconstructs the whole record on every write for exactly this reason, and
  re-supplies the association from config since it cannot be read back.

### The two agent-status credentials

The importer creates separate reader and operator credentials and saves them
in `.env.verify`:

| Client | Entitlement | Used by |
|---|---|---|
| `praxis-agent-status-reader` | `readAgents` | the **gateway**, per request (agent-status plugin) |
| `praxis-agent-status-operator` | `manageAgentStatus` | `set-agent-status.sh`, and a human admin |

The reference tenant permits these operations:

| | reader | operator |
|---|---|---|
| `GET /v1.0/Agents/{id}` | 200 | 200 |
| `PUT` status change | **403** | 200 |
| `PUT` renaming the agent | 403 | **403** (`CSINH2507E`) |
| `POST /v2.0/Users` | 403 | 403 |
| `GET /v1.0/applications` | 403 | 403 |
| `POST /v1.0/apiclients` | 403 | 403 |

The reader credential lets the gateway enforce status without being able to
change it. The operator can change status only; other fields must match the
existing record.

The admin pair stays **provisioning-only** — nothing on the demo path reads it.
The importer asserts each client's read-back entitlement list is exactly the
one expected and warns if the tenant returned anything broader. If your admin
client cannot create API clients (403 on `POST /v1.0/apiclients`), create the
two by hand with those single entitlements and set the four variables yourself.

### Flipping status by hand

```bash
./verify/set-agent-status.sh              # report
./verify/set-agent-status.sh SUSPENDED    # revoke
./verify/set-agent-status.sh ACTIVE       # restore
```

Statuses are `ACTIVE`, `SUSPENDED`, `UNDER_REVIEW`, `DEFAULT`. Only `ACTIVE`
passes the gateway's check.

Note that suspending does **not** stop the agent from getting a token — Verify
records status without enforcing it at the token endpoint. The gateway is what
refuses the call. See "Agent governance" in the top-level README.

### The exchange client needs birthright entitlement

Application entitlement is checked against the exchange **subject**. For
scenarios 01-13 that subject is a persona (bob, alice, eve), and the importer
grants access per user by SCIM id. The agent has no SCIM id — it is an OAuth
client, not a directory user — so no per-user grant can cover it.

So when a `role=agent` row is present, the importer entitles the **exchange**
client (`praxis-gateway`) by birthright instead. Without it, scenario 14 fails
at its delegate step with:

```text
CSIAQ0279E Only entitled users can single sign-on to the application.
```

The user-based exchange flows can still pass because they have explicit grants.

This change applies only to the exchange client when an agent exists.
The minting client keeps its explicit persona grants. Re-running the importer
repairs the entitlement on an existing client, so a tenant provisioned before
the agent existed does not need `--delete`.

### If the tenant has no Agent Registry

It is an Early Access capability. When `/v1.0/Agents` answers 403 or 404 the
importer warns, finishes the OAuth clients normally, and leaves
`VERIFY_AGENT_ID` unset — which makes scenario 14 skip (exit 77) rather than
fail.
