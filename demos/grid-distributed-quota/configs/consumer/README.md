# Consumer Gateway

`praxis-valkey-a.yaml` and `praxis-valkey-b.yaml` are independently addressable
west consumers backed by the same Valkey namespace and quota rules. Basic Auth
runs at the identity gateway; these private consumers authenticate that hop and
validate its projected quota group before admission. Their filter order is
intentional:

```text
peer trust -> trusted quota group -> model extraction -> token reservation
           -> Grid routing -> provider request -> token counting -> settlement
```

Response hooks execute in reverse order, so `token_count` publishes actual
usage before `token_rate_limit` reconciles the reservation. This topology has
no in-memory fallback consumer: both deployed consumers must use shared Valkey
state.
