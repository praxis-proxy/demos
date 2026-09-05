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
note "Expected: 200 OK"
note "Expected upstream: x-auth-user-id / x-auth-username / x-auth-roles / x-auth-context"
note "Expected upstream: NO x-user-token — the contract strips it"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

call_get_compensation "$BOB" "$CLIENT" true

step "The same call, with Bob spoofing an asserted header"
note "Sending: x-auth-user-id: root"
note "Expected upstream: x-auth-user-id is still Bob's real subject id, not 'root'"

SPOOF_HEADER="x-auth-user-id: root" call_get_compensation "$BOB" "$CLIENT" true

step "Read the upstream's view"
note "docker compose logs --tail 40 hr-mcp | grep x-auth"
