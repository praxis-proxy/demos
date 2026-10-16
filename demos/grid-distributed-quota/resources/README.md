# Kubernetes Resources

This directory owns Kubernetes resources that are not emitted directly by the
two Helm charts. Reusable workload and policy resources live under `common/`;
peer-specific trust resources live under `trust/`. Grid sites, networks, and
providers are emitted by the `grid-site` chart rather than duplicated here.

Resources must preserve separate consumer and provider identities and prevent
consumer workloads from reaching private inference endpoints directly. Secret
manifests and credential values must never be committed.
