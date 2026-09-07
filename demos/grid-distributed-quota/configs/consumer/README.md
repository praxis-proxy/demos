# Consumer Gateway

`praxis-valkey-a.yaml` and `praxis-valkey-b.yaml` are independently addressable
consumer replicas. Each exposes one listener, authenticates
`application-a`, `application-b`, and `application-c`, and applies the same
subject-keyed Valkey rule. Their filter order is intentional:

```text
Basic Auth -> model extraction -> token reservation -> Grid routing
           -> provider request -> token counting -> settlement
```

Praxis publishes only a successfully verified subject in typed request
metadata. The quota filter hashes that subject into its backend key. Response
hooks run in reverse order, so `token_count` publishes actual usage before
`token_rate_limit` settles the reservation. Both consumers use shared Valkey
state; there is no in-memory fallback or trusted client identity header.
