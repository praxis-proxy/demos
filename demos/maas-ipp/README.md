# MaaS IPP lab (Forge)

Single-cluster Kind environment that reproduces the **stock MaaS** Kind datapath:

```text
Client → Istio Gateway → IPP-pre → Kuadrant Auth → IPP-post → HTTPRoute → LLM sim
```

Forge owns cluster lifecycle and infra stacks. `maas-controller` **owns EnvoyFilter / IPP deployment** — this demo never authors Praxis or IPP filter YAML.

This profile is for MaaS + Praxis integration work. It is **not** the Grid multi-cluster GLB demo, and it intentionally diverges from issue #2’s “CRDs-only / skip Authorino” simulation table.

## What this demo proves

MaaS (Models-as-a-Service on OpenShift AI) already ships a payload-processing
step — **IPP** — as an Envoy `ExternalProcessor` in front of every model call,
split into an **IPP-pre** hop (before Kuadrant auth: extract model identity,
resolve the MaaS auth identity, apply bounded request mutations) and an
**IPP-post** hop (after auth: protect the provider boundary, select the
provider, translate protocol, inject provider credentials). Today that
processor is a stock ODH container (`odh-ai-gateway-payload-processing`).

This demo swaps that one container for **Praxis**, with nothing else in the
stock MaaS datapath changed — same Gateway, same Kuadrant `AuthPolicy`, same
CRDs, same HTTPRoute. `MAAS_IPP_PROFILE` is the switch:

| `MAAS_IPP_PROFILE` | IPP-pre/IPP-post implementation | Platform manifests overlay |
|---|---|---|
| `llm-d` (stock) | `odh-ai-gateway-payload-processing` (`$IPP_IMAGE`) | `overlays/xks` |
| `praxis` (this lab's default) | Praxis (`$PRAXIS_EXTPROC_IMAGE`), implementing the same Pre-Auth/Post-Auth contract | `overlays/xks-praxis` |

That table is the actual point of the demo: it's evidence Praxis can sit in
MaaS's existing `ExternalProcessor` slot and preserve IPP's pre/post-auth
behavior, not a new, separate datapath that MaaS would have to adopt
wholesale. From a roadmap perspective, that's the difference between "replace
your gateway" and "replace one container" — the latter is a far smaller ask
of a platform team already running MaaS in production.

The `## Call models` walkthrough below exercises both hops end-to-end
(model-identity extraction pre-auth, provider selection and credential
injection post-auth) against two backend shapes MaaS supports: an in-cluster
`LLMInferenceService` sim and an `ExternalModel`.

## Pins

Version and namespace pins live in `forge.yaml` cluster `properties`. Stacks
template them into URL steps and `exec.env`; `scripts/lib.sh` defaults are only
fallbacks for running scripts outside Forge.


| Component     | Property / env                         |
| ------------- | -------------------------------------- |
| MetalLB       | `metallbVersion` (+ `metallbSha256`)   |
| Gateway API   | `gatewayApiVersion` (+ sha256)         |
| GIE CRDs      | `gieVersion` → `GIE_VERSION`           |
| Istio         | `istioVersion` → `ISTIO_VERSION`       |
| cert-manager  | `certManagerVersion` (+ sha256)        |
| Kuadrant Helm | `kuadrantVersion` → `KUADRANT_VERSION` |
| Namespaces    | `maasNamespace`, `gatewayNamespace`    |




## Prerequisites

- Docker, `kind`, `kubectl`, `kustomize` (≥5.7), `helm`, `jq`, `curl` (or `wget`), `openssl`, `python3`
- `istioctl` is **not** required on PATH — `scripts/install-istio.sh` fetches
  `cluster.properties.istioVersion` (via `ISTIO_VERSION`) into `.cache/`
- Optional for arm64 LLMIS build: `gh`, `docker buildx`
- A local checkout of [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service):

```bash
export MAAS_ROOT=/path/to/models-as-a-service
```

- A `praxis-forge` binary on PATH. Build it from a checkout of the
  [grid repo](https://github.com/praxxis-ai/grid):

```bash
# from the grid repo
cargo build -p praxis-forge --release
# then copy/symlink target/release/praxis-forge onto PATH
```



## Bring up

From the directory containing this demo:

```bash
export MAAS_ROOT=/path/to/models-as-a-service

# Create Kind cluster
praxis-forge up --config forge.yaml

# Apply stacks (metallb → … → maas-fixtures). Required after `up`.
praxis-forge apply local --config forge.yaml
```

Cluster context: `kind-maas-ipp-local`.

Re-apply a single stack if needed:

```bash
praxis-forge apply local --stack maas-platform --config forge.yaml
praxis-forge apply local --stack maas-fixtures --config forge.yaml
```

Optional overrides (consumed by `scripts/install-maas-platform.sh`):

```bash
export MAAS_CONTROLLER_IMAGE=quay.io/you/maas-controller:dev
export MAAS_API_IMAGE=quay.io/you/maas-api:dev
export IPP_IMAGE=quay.io/opendatahub/odh-ai-gateway-payload-processing:odh-stable
# Default for this lab is praxis (requires MAAS_ROOT with MAAS_IPP_PROFILE support).
export MAAS_IPP_PROFILE=praxis
export PRAXIS_EXTPROC_IMAGE=praxis-extproc:dev
# Stock llm-d IPP instead:
# export MAAS_IPP_PROFILE=llm-d
```



## API key

```bash
API_KEY=$(kubectl --context kind-maas-ipp-local -n maas-system exec deploy/maas-api -- \
  curl -sk https://localhost:8443/v1/api-keys \
  -H "X-MaaS-Username: demo-user" \
  -H 'X-MaaS-Group: ["system:authenticated"]' \
  -H "Content-Type: application/json" \
  -d '{"name":"demo"}' | jq -r '.key')
echo "$API_KEY"
```



## Call models

> Every request below crosses the full stock datapath — `Client → Istio
> Gateway → IPP-pre → Kuadrant Auth → IPP-post → HTTPRoute → LLM sim` — with
> Praxis standing in for IPP-pre/IPP-post per `MAAS_IPP_PROFILE=praxis`. What
> to watch: the request succeeds identically to how it would against the
> stock `llm-d` IPP profile — that equivalence, not the model's answer, is
> the thing this demo is proving.

Gateway LB (MetalLB on the Kind docker network — reachable from the Kind host):

```bash
GW=$(kubectl --context kind-maas-ipp-local -n istio-system \
  get svc maas-default-gateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

**Internal llm-d sim** (`LLMInferenceService` `sim-internal`):

> Praxis's IPP-pre hop reads the `/llm-internal/sim-internal/...` path and
> `model` field to resolve which MaaS-registered model this call targets
> *before* Kuadrant decides whether the bearer token is allowed to call it.
> Post-auth, IPP-post resolves `sim-internal` to its backing
> `LLMInferenceService` and forwards — the same provider-selection step the
> stock IPP container performs, just implemented by Praxis's filter chain
> instead.

```bash
curl -sk "https://${GW}/llm-internal/sim-internal/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
```

**External model** (`ExternalModel` `llm-katan-openai` — remote simulator must be reachable):

> Same pre/post-auth contract, but IPP-post now resolves to an `ExternalModel`
> instead of an in-cluster `LLMInferenceService` — the provider-boundary and
> credential-injection step that matters most for customers routing to
> models MaaS itself doesn't host.

```bash
curl -sk "https://${GW}/llm/llm-katan-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"llm-katan-openai","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
```

Port-forward instead of LB:

```bash
kubectl --context kind-maas-ipp-local -n istio-system \
  port-forward svc/maas-default-gateway-istio 19090:80
# then http://localhost:19090/... with the same paths
```



## Validate

```bash
./scripts/validate.sh kind-maas-ipp-local
```

Expect:

- unauthenticated `/v1/models` → **401**
- API key + internal llm-d sim chat completion → **200** with a choices body



## Tear down

```bash
praxis-forge down --config forge.yaml
```



## Rebuild with local maas-controller changes

EnvoyFilter YAML stays in the controller. After editing under `$MAAS_ROOT/maas-controller`:

```bash
export MAAS_ROOT=/path/to/models-as-a-service
# rebuild.sh retags quay.io/opendatahub/maas-controller:* → localhost/…
# so imagePullPolicy=Always cannot re-pull over the kind-loaded image.
./scripts/rebuild.sh kind-maas-ipp-local maas-controller
```

Builds from `MAAS_ROOT`, `kind load`s, sets the Deployment image, patches
`imagePullPolicy` to `IfNotPresent`, and rolls out.

Also: `./scripts/rebuild.sh kind-maas-ipp-local maas-api`

Load `praxis-extproc:dev` separately if `MAAS_IPP_PROFILE=praxis`:

```bash
kind load docker-image praxis-extproc:dev --name maas-ipp-local
```

Forge must **not** apply a competing Praxis EnvoyFilter; the controller reconcile owns IPP.

## Stacks


| Stack           | Role                                                            |
| --------------- | --------------------------------------------------------------- |
| `metallb`       | LB + Kind docker-network pool                                   |
| `gateway-api`   | GW API 1.5.1 + GIE CRDs                                         |
| `istio`         | 1.30.3 minimal + GIE pilot flags                                |
| `cert-manager`  | cert-manager + maas-api CA chain                                |
| `kuadrant`      | Helm Kuadrant + Authorino trust                                 |
| `maas-platform` | Postgres, CRDs, KServe/llmisvc, Gateway, stock controller → IPP |
| `maas-fixtures` | ExternalModel + LLMInferenceService sim + subscription          |


GIE is enabled so an InferencePool backend can be attached later without reinstalling Istio. v1 validate uses the stock MaaS HTTPRoute → LLMInferenceService path.
