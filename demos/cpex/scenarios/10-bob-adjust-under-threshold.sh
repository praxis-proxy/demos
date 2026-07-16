#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
#
# Human-in-the-loop threshold — the pass-through half.
# adjust_compensation is a sensitive mutating action. The route applies
# require_approval ONLY when args.amount > $10,000; a smaller change goes
# straight through with no manager sign-off. This scenario exercises that
# under-threshold path — fully non-interactive, like scenarios 01-09.
#
#   Bob (HR) → adjust_compensation(EMP-001234, +$5,000)
#     → 200 OK, status "applied"  (require(role.hr) ✓, under $10k → no approval)
#
# The over-threshold path (approval required) is scenario 11.
# Both cpex.yaml and cpex-cel.yaml behave identically here — the route
# has no PDP step.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Bob (HR) → adjust_compensation (+\$5,000, under the \$10k threshold)"
note "Expected: HTTP 200 + status \"applied\" — require(role.hr) ✓"
note "Under \$10k, so the when: args.amount > 10000 guard does NOT fire — no approval"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

call_adjust_compensation "$BOB" "$CLIENT" 5000
show_last_audit adjust_compensation
