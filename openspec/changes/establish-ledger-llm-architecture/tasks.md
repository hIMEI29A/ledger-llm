# Tasks

## 1. Milestone 0 — Repository and contracts

- [ ] 1.1 Initialize the Go module at the repository's canonical path and add `go.mod`/`go.sum`; verify `go build ./...` succeeds on a clean checkout.
- [ ] 1.2 Create the package layout from design D1 (`cmd/ledger-llm`, `api/proto`, `api/gen`, `pkg/adapter`, `internal/*`) with minimal `doc.go` files; verify `go list ./...` returns every package and no import cycles exist.
- [ ] 1.3 Add a `Makefile` with `build`, `test`, `test-race`, `lint`, `bench`, and `generate` targets; verify each target runs locally.
- [ ] 1.4 Add CI (GitHub Actions) running `go vet`, `go test -race ./...`, and `golangci-lint`; verify the workflow passes on the initial commit.
- [ ] 1.5 Define `api/proto/ledger/v1/inference.proto` per design D8 and generate Go/gRPC stubs; verify `make generate` is reproducible and `go build ./...` passes with generated code.
- [ ] 1.6 Define `api/openapi.yaml` for the HTTP surface in design D8; verify an OpenAPI linter accepts it and every documented route has a handler stub.
- [ ] 1.7 Implement the config schema, defaults, environment overrides, and validation with a `--check` flag; verify unit tests cover invalid fields, missing sections, and env precedence.
- [ ] 1.8 Document the pipeline stage ownership and lock-free invariants from design D2 in `docs/architecture.md`; verify the document names every channel boundary and its single-owner rule.
- [ ] 1.9 Add structured logging with request/trace correlation and no secret values; verify a redaction test fails if a configured key appears in logs.

## 2. Milestone 0 — Pipeline skeleton

- [ ] 2.1 Implement the request model and `sync.Pool` reuse; verify a benchmark reports zero steady-state allocations per request after warm-up.
- [ ] 2.2 Implement bounded ingress admission with an atomic in-flight counter and `429` rejection; verify a saturation test observes the retry hint and no unbounded queue growth.
- [ ] 2.3 Implement classifier workers with a stub classifier that always returns `mid`; verify a fan-out test processes all requests and workers exit on shutdown.
- [ ] 2.4 Implement scheduler shards keyed by `hash(tenant, tier)` with a stub batch builder; verify a test shows one tenant always maps to one shard and shards run without shared mutable state.
- [ ] 2.5 Implement the dispatcher with a buffered-channel semaphore and a fake adapter; verify the concurrency-limit test never exceeds the configured maximum.
- [ ] 2.6 Implement the reconciler using a capacity-1 `done` channel per request; verify race tests show exactly one terminal delivery per request and no cross-delivery.
- [ ] 2.7 Wire the end-to-end skeleton from ingress to response with fake adapters; verify a `-race` stress test completes every request exactly once and loses none.
- [ ] 2.8 Add per-stage panic recovery that returns the mapped error and keeps the process alive; verify an injected panic test does not crash the server.
- [ ] 2.9 Implement graceful shutdown and drain ordering from design D10; verify an integration test sends SIGTERM and observes exit code 0 for a clean drain and 1 for a forced one.

## 3. Milestone 1 — Ingress, auth, classifier, single backend

- [ ] 3.1 Implement `POST /v1/inference` and `POST /v1/inference/stream`; verify handler tests cover success, SSE termination, `400`, `413`, `401`, `429`, and expired deadlines.
- [ ] 3.2 Implement gRPC `Complete` and `Stream`; verify an equivalence test sends the same payload over HTTP and gRPC and gets the same tier and normalized response fields.
- [ ] 3.3 Implement static API-key authentication with hashed secrets, constant-time comparison, and tenant resolution; verify tests reject missing, malformed, and unknown keys.
- [ ] 3.4 Propagate deadlines and client cancellation through every stage; verify a disconnect test removes the request from its queue and batch and cancels the backend call.
- [ ] 3.5 Implement classifier v1 with the feature set, integer scoring, thresholds, confidence, and version reporting from design D6; verify table-driven tests and a determinism property test.
- [ ] 3.6 Add the classifier benchmark and latency gate; verify the benchmark reports p99 ≤ 1 ms for 8 KiB payloads and the gate fails the build above the ceiling.
- [ ] 3.7 Implement the degraded-fallback path for classifier errors and timeouts; verify a fault-injection test routes to `mid`, sets the degraded flag, and increments the counter.
- [ ] 3.8 Implement the OpenAI-compatible adapter with retries, `Retry-After`, error mapping, and usage extraction; verify `httptest` contract tests cover `429`, `5xx`, context-length errors, and missing usage.
- [ ] 3.9 Implement streaming pass-through and upstream cancellation in the adapter; verify a test cancels the client mid-stream and observes the upstream request context cancelled.

## 4. Milestone 2 — Multi-tier batch routing

- [ ] 4.1 Implement batch builders with `(tier, tenant, deadline_bucket, mode)` keys and the size/byte/wait limits from design D3; verify fake-clock tests cover each flush trigger.
- [ ] 4.2 Implement deadline-aware flush and split; verify tests assert the earliest deadline is met and ineligible requests receive `deadline_exceeded` without a backend call.
- [ ] 4.3 Implement per-tenant weighted round-robin within a shard; verify a starvation test keeps a quiet tenant's requests within the maximum wait under a noisy neighbor.
- [ ] 4.4 Implement failover and one-step escalation with deadline and tenant-cap checks; verify tests cover `local → mid`, `mid → high`, and no-escalation cases.
- [ ] 4.5 Implement the local (Ollama/llama.cpp) and Anthropic adapters; verify the shared adapter contract suite passes for all three implementations.
- [ ] 4.6 Implement per-tier backpressure and adaptive `max_wait`; verify a load test shows bounded queues, `429` responses at the watermark, and no goroutine growth.
- [ ] 4.7 Implement provider rate-limit handling and circuit breakers; verify a chaos test opens the circuit after the threshold, stops dispatch, and recovers after a successful probe.
- [ ] 4.8 Run an end-to-end multi-tier test with three fake backends; verify tier selection, per-tenant isolation, and batch-key separation are all asserted.

## 5. Milestone 3 — Metrics, usage, admin, OSS release

- [ ] 5.1 Implement Prometheus collectors and `GET /metrics` per design D9; verify a scrape test exposes the required metrics and a cardinality test rejects free-form labels.
- [ ] 5.2 Implement per-request and per-batch usage records, the versioned price table, and estimation flags; verify unit tests cover exact usage, estimated usage, unknown models, and cost arithmetic.
- [ ] 5.3 Implement JSONL and webhook usage sinks with a bounded buffer and drop-oldest policy; verify a slow-sink test never blocks requests and increments the drop counter.
- [ ] 5.4 Implement `GET /admin/health`, `/admin/ready`, `/admin/version`, `/admin/config`, `POST /admin/drain`, and `POST /admin/reload`; verify endpoint tests including redacted config output.
- [ ] 5.5 Implement atomic config snapshot reload for the safe subset; verify a `-race` test reloads under load, in-flight requests keep their snapshot, and invalid reloads keep the old one.
- [ ] 5.6 Write the README, configuration reference, API reference, adapter guide, and deployment guide; verify every documented command and route works against a local stub backend.
- [ ] 5.7 Add a load/soak harness; verify it reports throughput, p50/p99 latency, batch-size distribution, and cost per 1K requests for a repeatable scenario.
- [ ] 5.8 Add release automation (goreleaser, container image, SBOM, signed artifacts); verify a dry-run release produces the expected binaries and image.
- [ ] 5.9 Run a security pass (`gosec`, dependency scan, secret-redaction tests); verify no high-severity findings remain and redaction tests pass.
- [ ] 5.10 Freeze the `v1beta1` HTTP/proto surface and publish a changelog; verify the changelog lists every route, field, and error code with compatibility notes.

## 6. Milestone 4 — Commercial handoff (outside this repository)

- Freeze the usage-event JSON schema v1 with the commercial team and publish it from the OSS repository.
- Provide a reference consumer that reads the JSONL/webhook feed and prints per-tenant aggregates; keep it outside the OSS module.
- Track billing dashboard, chargeback allocation, budgets, SSO/RBAC, and invoice export as a separate commercial change, not in this repository.

## Roadmap follow-up

- Async provider batch APIs (OpenAI Batch, Anthropic Message Batches) are a separate change after Milestone 3, as decided during design review.
- Each later milestone may be split into its own OpenSpec change if implementation spans more than one release.

## Workflow follow-up

- Review the generated specs and design with the maintainers before applying tasks.
- Sync the capability specs into `openspec/specs/` and archive this change after Milestone 3 is implemented and verified.
