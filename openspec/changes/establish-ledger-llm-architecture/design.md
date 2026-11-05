# Design

## Context

Greenfield Go repository with no application code, no module file, and no deployment tooling. The only existing assets are the MIT license and the planner brief in `docs/prompt.md`. See `proposal.md` for motivation and `specs/*/spec.md` for the behavior contracts this design must satisfy.

Assumptions used throughout:

- Go 1.23+ with modules enabled; standard library first, minimal third-party dependencies.
- The reference machine for latency claims is a 4 vCPU Linux/amd64 or arm64 instance with 8 GiB RAM, running a release build.
- Local backends expose an OpenAI-compatible or Ollama-style HTTP API; mid-tier and high-end backends expose provider HTTP APIs.
- No database is available to the OSS core. All hot-path state is in memory; durability is optional and limited to the usage feed.
- A single process serves many tenants; horizontal scale-out is stateless per instance.

## Goals / Non-Goals

**Goals:**

- Fix the package layering and ownership boundaries so the pipeline can be implemented and reviewed incrementally.
- Define the channel topology and the lock-free invariant that each stage must uphold.
- Define the batching, routing, fallback, and backpressure policies precisely enough to implement and test.
- Define the public HTTP and gRPC surfaces, the metrics model, and the usage feed consumed by the commercial layer.
- Separate the MIT-licensed OSS core from the gated FinOps product through explicit extension points.

**Non-Goals:**

- Production code, generated protobufs, CI pipelines, or container images (this change is planning only).
- A trained ML classifier; v1 is a hand-tuned linear model.
- A billing dashboard, chargeback engine, budget alerts, SSO/RBAC, or invoice export.
- Provider asynchronous batch APIs (file-based batch endpoints). These are deferred to a separate change after Milestone 3.
- Multi-region coordination, persistent request queues, or exactly-once usage delivery.

## Decisions

### D1. Single binary, `cmd/` + `internal/` + public extension package

```
cmd/ledger-llm/            main: flags, wiring, lifecycle
api/proto/ledger/v1/       .proto sources; generated code under api/gen/
pkg/adapter/               public adapter contract for third-party backends
internal/config/           schema, defaults, validation, reload snapshots
internal/ingress/httpapi/  HTTP handlers, SSE writer, error mapping
internal/ingress/grpcapi/  gRPC service implementations
internal/pipeline/         stage wiring, backpressure counters, shutdown
internal/classifier/       feature extraction, scoring, versioning
internal/scheduler/        shard ownership, batch builders, dispatch, reconciliation
internal/adapters/         openai, anthropic, local implementations + registry
internal/metrics/          Prometheus/OTel collectors, bounded buffers
internal/usage/            usage records, price table, feed sinks
internal/admin/            health, readiness, config, drain, reload
```

`pkg/adapter` is intentionally public so operators can ship custom backends without forking the router. Everything under `internal/` is free to change. Alternative considered: a flat package layout. Rejected because the pipeline, scheduler shards, and adapters have distinct ownership rules that are easier to enforce when they cannot reach into each other.

### D2. Pipeline topology and channel boundaries

```
                    ┌──────────────┐
HTTP / gRPC ───────▶│ ingress      │  normalize, authenticate, admit
                    └──────┬───────┘
                           │ ingressCh  (bounded chan *Request)
                           ▼
                    ┌──────────────┐
                    │ classifier   │  N workers, pure function over snapshot
                    └──────┬───────┘
                           │ classifiedCh (bounded chan *Classified)
                           ▼
                    ┌──────────────┐
                    │ scheduler    │  S shards keyed by hash(tenant, tier)
                    │  shard 0..S-1│  each owns its batch builders
                    └──────┬───────┘
                           │ dispatchCh (bounded chan *Batch, per backend)
                           ▼
                    ┌──────────────┐
                    │ dispatcher   │  per-backend semaphore, circuit breaker
                    └──────┬───────┘
                           │ resultCh (bounded chan *BatchResult)
                           ▼
                    ┌──────────────┐
                    │ reconciler   │  fan results back to per-request channels
                    └──────┬───────┘
                           │ request.done (chan Outcome, capacity 1)
                           ▼
                     response writer / SSE
```

Side channels: `metricsCh` and `usageCh` are bounded, non-blocking, and drop-oldest. They never participate in request completion.

Ownership and lock-free invariants per stage:

| Stage | Owns | Invariant |
|---|---|---|
| Ingress | Request struct from `sync.Pool` | A request has exactly one owner at a time; ownership transfers only through a channel send. Admission uses an atomic in-flight counter, not a mutex. |
| Classifier | Nothing; reads `atomic.Pointer[ClassifierConfig]` | Stateless workers; the config snapshot is immutable and swapped atomically on reload. |
| Scheduler shard | Batch builders for its shard | Single-goroutine ownership of all maps and timers. No other goroutine mutates a builder. Shard assignment by consistent hash of `(tenant, tier)` keeps a tenant's requests on one shard, which also gives fairness and isolation for free. |
| Dispatcher | One goroutine per backend | Concurrency limit is a buffered `chan struct{}` semaphore. Circuit-breaker state is an `atomic.Uint32` moved with CAS; only the winner probes. |
| Reconciler | Per-request `done` channel | Each request's `done` channel has capacity 1 and exactly one terminal send; no shared result map and no mutex. |
| Metrics / usage | Bounded ring buffer | Counters are `atomic`; enqueue is non-blocking and drops oldest with a dropped-events counter. |

Allowed `sync` usage is limited to `sync.Pool` for request/byte buffers, `sync.Once` for process-wide initialization, `sync.WaitGroup` for shutdown, and `sync/atomic` for counters, snapshots, and circuit state. Mutexes are not permitted in `ingress`, `classifier`, `scheduler`, `dispatcher`, or `reconciler` hot paths. An occasional mutex in admin/config reload code is acceptable because it is off the request path.

### D3. Batching policy

A batch key is `(tier, tenant_id, deadline_bucket, mode)`. `deadline_bucket` is the request deadline quantized to 25 ms; requests with materially different remaining time are not grouped. `mode` is `interactive` or `batch`, selected per request (header or body) and defaulted per tenant.

Defaults, all configurable:

| Parameter | interactive | batch |
|---|---|---|
| `max_wait` | 10 ms | 100 ms |
| `max_requests` | 16 | 64 |
| `max_bytes` | 128 KiB | 512 KiB |
| `min_requests_before_flush` | 1 | 1 |

Flush triggers, whichever fires first: batch full, byte budget reached, `max_wait` elapsed, earliest deadline pressure, tenant policy allows only smaller batches, or shutdown/drain.

Deadline pressure: before dispatch, the builder compares the earliest remaining deadline with the backend's exponentially weighted call estimate plus a safety margin. If the estimate does not fit, it dispatches the eligible subset immediately and fails the ineligible requests with `deadline_exceeded` (per `batch-scheduling`).

Streaming requests are dispatched as single-request batches. Provider streaming is chunk-oriented and gives no cross-request batching benefit; grouping them would only add head-of-line blocking.

Adaptive behavior is deliberately small: `max_wait` shrinks toward its floor when the tier queue exceeds its high watermark, and returns to the configured value when the queue drains. This keeps tail latency bounded without a control loop that is hard to reason about.

### D4. Scheduling shards and fairness

`S = 2 × GOMAXPROCS` shards. Each shard is a goroutine with its own `map[batchKey]*builder`, timers, and dispatch output. Sharding by `hash(tenant, tier)` guarantees that all requests for a tenant land on one shard, so per-tenant fairness needs no cross-shard coordination.

Within a shard, each tenant gets a weighted round-robin slot. A tenant exceeding its configured share is deferred to the next round, which bounds starvation while allowing bursts. Because batches are tenant-scoped, noisy-neighbor effects are limited to queueing delay, not shared backend calls.

Alternative considered: a single central scheduler. Rejected because it becomes a mutex or single-goroutine bottleneck at the target throughput.

### D5. Routing policy

- Classification produces a score in `[0, 1]`, a tier, and a confidence. Thresholds `mid_at` and `high_at` map score to tier; the confidence threshold defaults to `0.60`.
- Confidence below threshold marks the request uncertain and lifts it to at least `mid` (per `complexity-classifier`).
- Explicit `tier` in the request bypasses classification and counts as an override.
- Tenant policy may restrict allowed tiers, cap the maximum tier, set per-tenant rate and burst limits, and choose the default mode. A request that violates its tenant's tier cap is clamped, not rejected.
- Escalation on failure is at most one tier upward, at most once per request, only when the remaining deadline covers the estimated call and the tenant permits the higher tier. Every escalation sets the `escalated` flag and increments a counter.
- Backend unavailability fails over in the direction `local → mid → high`; `high` has no fallback and returns `upstream_unavailable`.
- Backpressure is per tier: queue depth above the high watermark causes new admissions for that tier to receive `429` with `Retry-After` derived from the current drain rate.

### D6. Classifier

V1 is a deterministic linear scorer over features extracted from the first 8 KiB of the payload plus request metadata, bounded work per request:

- estimated token count from a rune-class heuristic (no tokenizer dependency),
- prompt length and message count,
- code-fence, math, and reasoning-marker counts,
- requested `max_output_tokens`,
- tenant and mode hints.

Scores use integer weights so results are stable across architectures. Confidence is the normalized distance from the nearest threshold, clipped to `[0, 1]`. Weights are compiled into the binary as `classifier.v1`; thresholds and the confidence floor live in config and can be reloaded atomically.

The feature schema is versioned separately (`features.v1`) so a future learned model can replace the scorer behind the same `Classify(request) Decision` seam without changing callers or metrics.

### D7. Backend adapters

Public contract in `pkg/adapter`:

```go
type Adapter interface {
    ID() string
    Tier() Tier
    Capabilities() Capabilities

    // Complete dispatches one logical batch. Implementations may use a provider
    // batch endpoint or bounded concurrent calls; outcomes are correlated by
    // request id and returned in input order.
    Complete(ctx context.Context, batch []Request) ([]Outcome, error)

    // Stream forwards chunks for a single request and returns terminal usage.
    Stream(ctx context.Context, req Request, sink ChunkSink) (Outcome, error)

    Health(ctx context.Context) error
}
```

Important distinction: a **scheduling batch** is the tenant/tier group the router forms. A **transport batch** is a provider capability. OpenAI-compatible and Anthropic chat APIs have no synchronous multi-prompt batch, so their adapters implement a scheduling batch as bounded concurrent HTTP calls sharing a connection pool. Local llama.cpp/Ollama adapters may use native multi-prompt batching when available. This keeps the scheduler policy uniform without pretending providers offer something they do not. `Capabilities.Batch` reports the strongest available transport mode.

Connection handling: one `http.Client` per backend with HTTP/2, a buffered-channel semaphore for `max_concurrency`, retry with exponential backoff and jitter, `Retry-After` honoring, and an idempotency key forwarded when the client supplied one. Circuit breaker: closed → open after N consecutive failures → half-open with a single CAS-elected probe.

### D8. Public interfaces

HTTP:

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/inference` | JSON completion |
| POST | `/v1/inference/stream` | SSE streaming |
| GET | `/metrics` | Prometheus exposition |
| GET | `/admin/health` | liveness |
| GET | `/admin/ready` | readiness |
| GET | `/admin/version` | build metadata |
| GET | `/admin/config` | redacted effective config |
| POST | `/admin/drain` | enter drain mode |
| POST | `/admin/reload` | reload safe config subset |

Request body (shared by both inference routes):

```json
{
  "mode": "interactive | batch",
  "tier": "auto | local | mid | high",
  "messages": [{"role": "user", "content": "..."}],
  "max_output_tokens": 512,
  "temperature": 0.2,
  "idempotency_key": "optional",
  "metadata": {"trace_id": "..."}
}
```

Tenant identity comes from the credential, never from the body. Success response:

```json
{
  "request_id": "r_...",
  "tier": "mid",
  "model": "gpt-4o-mini",
  "output": "...",
  "usage": {"input_tokens": 123, "output_tokens": 45, "estimated": false},
  "cost": {"amount": 0.0012, "currency": "USD", "price_version": "2026-01"},
  "flags": {"degraded": false, "overridden": false, "escalated": false}
}
```

Error envelope: `{"error": {"code": "...", "message": "...", "request_id": "...", "retry_after_ms": 0}}`.

gRPC sketch (full proto in `tasks.md` Milestone 0):

```proto
package ledger.v1;

service InferenceService {
  rpc Complete(CompletionRequest) returns (CompletionResponse);
  rpc Stream(CompletionRequest) returns (stream CompletionChunk);
}

message CompletionRequest {
  string request_id = 1;
  string mode = 2;
  string tier = 3;
  repeated Message messages = 4;
  int32 max_output_tokens = 5;
  float temperature = 6;
  string idempotency_key = 7;
  map<string, string> metadata = 8;
}

message CompletionChunk {
  string request_id = 1;
  string delta = 2;
  Usage usage = 3;
  bool done = 4;
  Error error = 5;
}
```

Routing metadata is returned on both transports: `X-Ledger-Request-Id`, `X-Ledger-Tier`, `X-Ledger-Classifier-Version`, `X-Ledger-Degraded` over HTTP, and equivalent response fields over gRPC.

### D9. Observability and usage model

Per request: `request_id`, `tenant`, `tier`, `model`, `batch_id`, `mode`, queue wait, classification duration, upstream duration, total duration, input/output tokens (exact or estimated), cost and price version, status, and flags (overridden, uncertain, degraded, escalated).

Per batch: tier, backend, request count, bytes, formation wait, upstream duration, outcome (success/partial/failure).

Core metrics: `ledger_request_duration_seconds{tier,status}`, `ledger_queue_wait_seconds{tier,mode}`, `ledger_classifier_duration_seconds`, `ledger_classifier_decisions_total{tier}`, `ledger_batch_requests`, `ledger_batch_duration_seconds{tier}`, `ledger_queue_depth{tier}`, `ledger_usage_tokens_total{tier,kind}`, `ledger_usage_cost_usd_total`, `ledger_usage_dropped_total`, `ledger_backend_health{tier,backend}`.

Cardinality rules: tenant labels are opt-in; model label is limited to configured models; no request ids or free-form values in labels. Trace ids go to logs/spans, not labels.

Usage feed: append-only JSON events with `request_id`, `tenant`, `tier`, `model`, token counts, `estimated`, `price_version`, `cost`, `currency`, `completed_at`, and optional `batch_id`. OSS sinks are file (JSONL, rotated) and HTTP webhook (batched, deduplicable by `request_id`). Delivery is at-least-once while an event sits in the bounded buffer and best-effort across process restarts; a durable disk spool is out of scope for v1. The commercial FinOps service is a consumer of this feed and is not part of this repository.

Costs come from a versioned YAML price table keyed by model and token type, with currency. Unknown models produce `cost_known: false`, never a silent zero.

### D10. Configuration and lifecycle

One YAML file plus `LEDGER_*` environment overrides. Sections: `server`, `ingress`, `classifier`, `scheduler`, `tenants`, `backends`, `metrics`, `usage`, `prices`. `--check` validates and exits.

Hot-reloadable subset: classifier thresholds and confidence floor, batch waits and size limits, tenant policies, price table, metrics sampling. Listeners, backends, and secrets require a restart. Reload builds a complete new snapshot, validates it, then swaps an `atomic.Pointer`; failure keeps the old snapshot.

Tenant authentication in OSS v1 uses static API keys declared in config as a key id, a hashed secret, and a tenant record. The ingress compares a presented key against the in-memory hash set and resolves the tenant; no external identity provider is required. Delegation to an upstream gateway is a documented future option, not a v1 feature.

Shutdown order: flip readiness, stop admission, drain scheduler shards, flush bounded metrics/usage buffers with a short deadline, close listeners, exit. Exit code 0 for a clean drain, 1 for a forced one.

### D11. OSS / commercial boundary

MIT-licensed OSS core (this repository): ingress, classifier, scheduler, adapters, metrics, usage records, price table evaluation, admin API, config, and the `pkg/adapter` extension contract.

Gated commercial layer (separate repository and license): billing dashboard, tenant/department hierarchy, chargeback allocation rules, budgets and alerts, invoice/export, SSO/RBAC, long-term usage warehouse, and audit reporting.

The boundary is enforced by interfaces, not by build tags: the OSS core knows only `usage.Sink` (file/webhook) and standard Prometheus/OTLP. The commercial service consumes the usage feed through a documented JSON schema, so a fork can replace the sink without touching router internals.

### D12. Testing strategy

- Classifier: table-driven cases, determinism and monotonicity property tests, fuzz over arbitrary UTF-8, and a benchmark that gates p99 at 1 ms on the reference machine.
- Scheduler: fake clock and fake adapter tests for batch formation, deadline flush, tenant isolation, cancellation, fairness, and backpressure.
- Pipeline: `go test -race` plus a stress test that drives ingress through fake backends and asserts no request is lost or double-completed.
- Adapters: `httptest` contract tests for retries, `Retry-After`, error mapping, streaming cancellation, and usage extraction.
- End-to-end: binary against a stub local backend, asserting HTTP and gRPC equivalence, drain behavior, and graceful shutdown.
- Load: a harness that reports throughput, p50/p99 latency, batch size distribution, and cost per 1K requests.

## Risks / Trade-offs

- **Batching adds queueing latency** → bounded `max_wait`, deadline-aware flush, per-request `mode`, and adaptive shrink under queue pressure. Interactive defaults stay at 10 ms.
- **Classifier accuracy may not justify routing** → confidence floor lifts uncertain requests, overrides are always honored, escalation exists, and Milestone 3 adds shadow-mode accuracy tracking before thresholds are tuned.
- **Tail latency from head-of-line blocking** → tenant-scoped batches, deadline buckets, single-request dispatch for streaming, and per-tier queues.
- **Provider rate limits and outages** → token-bucket admission, `Retry-After` honoring, circuit breakers, and one-step failover.
- **"Batch" is not a provider primitive** → adapters model logical batches; the provider capability matrix makes the limitation explicit instead of hiding it.
- **Lock-free code is harder to get right** → single-owner shard design, one-sender result channels, documented invariants, and mandatory race/stress tests. No lock-free data structures are hand-rolled; the design uses ownership, not CAS loops, except for the circuit breaker.
- **In-memory usage loss on crash** → OSS feed is best-effort with bounded buffers; durable delivery is a commercial concern. This is an accepted trade-off for the OSS core.
- **Price table drift** → versioned table, `cost_known` flag, and an unpriced-model counter so operators see gaps instead of silent zeros.
- **Memory pressure from large prompts** → payload byte budget per batch, `sync.Pool` reuse, and admission limits. Prompts are never retained after completion.

## Migration Plan

The repository has no code, so there is no data or API migration.

1. Milestone 0 lands the module, config loader, proto/HTTP skeleton, and a pass-through pipeline with fake adapters. No routing behavior is exposed yet.
2. Milestone 1 adds authentication, normalization, and the classifier behind an internal flag; default remains a single configured backend.
3. Milestone 2 enables multi-tier batching and is gated by a config flag (`scheduler.enabled`) so operators can revert to pass-through by configuration.
4. Milestone 3 makes metrics and the usage feed the default and declares the HTTP/proto surface `v1beta1`.
5. Rollback at any point is a binary rollback plus a previous config snapshot; the service is stateless, and the usage feed is append-only.

## Open Questions

- Exact reference hardware and target RPS for the 1 ms classifier gate; the benchmark in Milestone 0 will pin these numbers.
- Which labeled dataset or sampling process is used to calibrate classifier thresholds before Milestone 3, and who reviews the accuracy-versus-savings trade-off.
- Who owns and publishes the default price table, and which currency is canonical for cost attribution.
- Whether upstream-gateway identity delegation is required by early adopters; v1 ships static API keys, and delegation can be added without changing the request contract.
