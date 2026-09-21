#!/usr/bin/env bash
# What the gateway tells the upstream, and what it refuses to pass on.
#
# Everything the other scenarios show is a decision. This one is the only
# channel that carries the decision onward: `global.assertions.request:` renders
# engine-derived identity into request headers hr-mcp can read.
#
# Two halves:
#
#   1. Bob calls the tool normally. The upstream log shows four asserted
#      headers, and no `x-user-token`: the contract strips it, and `delegate`
#      already replaced `authorization` with the minted workday-api token, so
#      the upstream holds no credential Bob issued.
#
#   2. Bob calls again, this time spoofing `x-auth-user-id: root` himself. The
#      upstream still sees Bob's real subject id. An entry removes its target
#      before injecting, so a client cannot launder a value into a header the
#      upstream trusts. That removal is unconditional: it happens even when the
#      source resolves to nothing, precisely so absence cannot leave a client
#      value standing under a trusted name.
#
# The headers are UNSIGNED. hr-mcp believes them because it believes nothing
# between the gateway and itself can set them. If that is not true of your
# network, this feature is not what makes it true.
#
# Watch the effect with:
#   docker compose logs -f hr-mcp

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Bob (HR) → get_compensation, with assertions on the upstream request"
note "global.assertions.request renders identity into headers the tool can read"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)
BOB_SUB="$(token_sub "$BOB")"
note "Bob's real subject id: $BOB_SUB"

reset_upstream
call_get_compensation "$BOB" "$CLIENT" true

expect_status 200
expect_upstream_calls 1
# The engine originates each of these. The upstream believes them because it
# believes the network path, so what matters is that they are the engine's
# values.
expect_upstream_header x-auth-user-id "$BOB_SUB"
expect_upstream_header x-auth-username bob
expect_upstream_header x-auth-roles hr
# And the raw caller token is withheld: `delegate(...)` already replaced
# `authorization`, so forwarding this too would hand the tool a second,
# more powerful credential.
expect_upstream_no_header x-user-token

step "The same call, with Bob spoofing an asserted header"
note "Sending: x-auth-user-id: root"
note "An assertion entry removes its target before injecting, so the client's"
note "value cannot survive into the upstream request."

reset_upstream
SPOOF_HEADER="x-auth-user-id: root" call_get_compensation "$BOB" "$CLIENT" true

expect_status 200
expect_upstream_calls 1
# The header Bob set himself must not be what the tool reads.
expect_upstream_header x-auth-user-id "$BOB_SUB"
finish
