# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Where the demo's agent processes run. Each agent runs as its own user, and
# the SPIRE agent attests a process by its uid, so the users here stand in for
# separate deployments. The spire-agent binary is only used as a Workload API
# client (`spire-agent api fetch jwt`).

FROM ghcr.io/spiffe/spire-agent:1.9.6 AS spire

FROM alpine:3.20
COPY --from=spire /opt/spire/bin/spire-agent /usr/local/bin/spire-agent
# 1001: hr-copilot (registered). 1004: a process nobody registered.
RUN adduser -D -u 1001 hr-copilot \
 && adduser -D -u 1004 unregistered
CMD ["sleep", "infinity"]
