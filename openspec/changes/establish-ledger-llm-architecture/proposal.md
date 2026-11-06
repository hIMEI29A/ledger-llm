# Proposal

## Why

LLM workloads are increasingly dominated by high-volume batch jobs (document enrichment, evaluation sweeps, bulk generation), where per-request routing wastes both money and throughput: each call pays classification latency, cannot share transport or provider quota, and cannot exploit prompt/size locality. Existing routers optimize the single interactive request and leave batch scheduling, tenant-aware fairness, and cost attribution to ad-hoc glue code.

`ledger-llm` closes that gap with a Go proxy whose default execution model is batched end to end: requests are admitted, classified, grouped, dispatched, and reconciled in batches while still serving interactive traffic through the same pipeline. This change establishes the architecture baseline — behavior contracts and the implementation roadmap — before any production code is written.

## What Changes

- Introduce the OpenSpec capability baseline for the OSS core: ingress, complexity classifier, batch scheduler, backend adapters, usage metrics, and service operations.
- Define the stage-by-stage processing pipeline with explicit `chan` boundaries and a stated lock-free invariant per stage; mutex-guarded hot paths are prohibited.
- Specify a pure-Go complexity classifier with a sub-millisecond to ~1 ms budget and a tier decision contract (local / mid-tier / high-end) including confidence and fallback semantics.
- Specify batch formation and dispatch keys (tier, tenant, deadline bucket), backpressure, deadline-aware degradation, and reconciliation of per-request results out of batched backend calls.
- Define a uniform backend-adapter contract covering streaming, retries, provider rate limits, and a shared error taxonomy.
- Define the usage-metrics model (latency per tier, classifier cost, batch size, token and cost attribution) and its export surfaces, leaving the commercial FinOps engine as a consumer.
- Record the OSS/commercial boundary: router and metrics tracker are OSS; billing dashboard and cross-department cost allocation are gated and out of scope for this change.
- **BREAKING**: none — the repository is greenfield and has no existing behavior to preserve.

## Capabilities

### New Capabilities

- `request-ingress`: HTTP and gRPC admission, request normalization, tenant identity, deadlines, cancellation, and admission-level backpressure.
- `complexity-classifier`: pure-Go classification of a normalized request into a tier decision, its inputs/outputs, confidence, versioning, and the ~1 ms performance budget.
- `batch-scheduling`: batch keys, batch lifecycle, dispatch, deadline handling, fallback/escalation, and per-request reconciliation with lock-free inter-stage channels.
- `backend-adapters`: uniform adapter contract for local, mid-tier, and high-end backends, including streaming, retries, rate-limit handling, and error mapping.
- `usage-metrics`: per-request and per-batch measurement, aggregation, export, and the cost-attribution feed consumed by the commercial layer.
- `service-operations`: configuration loading/validation, admin endpoints, health/readiness, draining, and graceful shutdown.

### Modified Capabilities

- None — no existing specifications exist in this repository.

## Impact

- **Code**: greenfield. This change creates planning artifacts only; the Go module layout, package boundaries, and test strategy are defined in `design.md` and implemented under `tasks.md` in later milestones.
- **APIs**: new public HTTP routes and gRPC services for inference ingress, plus operational/admin endpoints and a metrics endpoint.
- **Dependencies**: Go standard library first; expected external packages are limited to gRPC/protobuf, an HTTP router, Prometheus/OpenTelemetry export, and provider SDKs behind adapters.
- **Systems**: operator-supplied backend endpoints (local inference server, mid-tier and high-end provider APIs), tenant identity source, and a metrics backend. The commercial billing/FinOps service consumes the usage feed but is not implemented here.
- **Compatibility**: no migration concerns; artifact and API stability commitments begin at the first tagged release.
