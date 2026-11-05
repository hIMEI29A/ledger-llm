# Spec Delta

## Purpose

Defines a uniform behavioral contract for every local, mid-tier, and high-end backend so the scheduler can dispatch batches, stream results, handle rate limits and provider errors consistently, and collect usage without provider-specific branching in the hot path.

## ADDED Requirements

### Requirement: Uniform backend contract
Every configured backend SHALL declare its tier, identity, supported capabilities (batch, streaming, token usage reporting), and SHALL accept a batch of requests with individual deadlines and return per-request outcomes.

#### Scenario: Batch dispatched to a capable backend
- **WHEN** a batch is dispatched to a backend that supports batching
- **THEN** the adapter returns one outcome per request in the batch, correlated by request identifier

#### Scenario: Unsupported capability
- **WHEN** a request requires streaming but the selected backend does not support it
- **THEN** the adapter reports error code `unsupported` instead of silently degrading

### Requirement: Connection reuse and concurrency limits
Adapters SHALL reuse connections to their backend and SHALL enforce a configured maximum concurrency per backend. Excess work MUST wait or be rejected rather than opening unbounded connections.

#### Scenario: Concurrency limit reached
- **WHEN** the configured maximum concurrency for a backend is reached
- **THEN** additional batches wait for a free slot or are rejected with `rate_limited`

### Requirement: Retry policy
Adapters SHALL retry transport failures, HTTP 5xx responses, and rate-limit responses up to the configured attempt count with exponential backoff and jitter, but only while the remaining deadline permits. Requests without an idempotency key MUST NOT be retried after the request has been sent.

#### Scenario: Transient upstream error
- **WHEN** a backend returns HTTP 503 and the deadline permits another attempt
- **THEN** the adapter retries with backoff and returns the eventual outcome

#### Scenario: Non-idempotent request fails after send
- **WHEN** a request without an idempotency key fails after being sent
- **THEN** the adapter returns the mapped error without retrying

### Requirement: Rate-limit handling
On a provider rate-limit response, adapters SHALL honor the provider's retry hint when present, SHALL NOT hot-loop, and SHALL keep waiting work within bounded queues.

#### Scenario: Provider returns 429 with Retry-After
- **WHEN** a backend responds with HTTP 429 and a `Retry-After` value
- **THEN** the adapter waits at least that long before retrying or reports `rate_limited` if the deadline cannot accommodate the wait

### Requirement: Stable error taxonomy
Adapters SHALL map all backend failures to the stable codes `invalid_request`, `unauthorized`, `rate_limited`, `deadline_exceeded`, `context_length_exceeded`, `upstream_unavailable`, `unsupported`, or `upstream_error`. Provider-specific error text MUST NOT be exposed to clients.

#### Scenario: Context length exceeded
- **WHEN** a provider rejects a request because the prompt exceeds the model context window
- **THEN** the client receives `context_length_exceeded` with no provider-specific payload

#### Scenario: Provider outage
- **WHEN** a backend is unreachable or returns repeated 5xx responses beyond the retry budget
- **THEN** the client receives `upstream_unavailable`

### Requirement: Streaming pass-through
For streaming requests, adapters SHALL forward chunks to the client in backend order with timely flushing, and SHALL terminate the upstream call when the client cancels.

#### Scenario: Client cancels a stream
- **WHEN** a client disconnects during a streamed response
- **THEN** the adapter cancels the upstream request and stops forwarding chunks

### Requirement: Usage extraction
Adapters SHALL report the model identifier and input/output token usage for each completed request when the backend provides them. Missing usage SHALL be marked as estimated.

#### Scenario: Provider reports usage
- **WHEN** a backend response includes token usage
- **THEN** the adapter returns the reported model identifier and exact token counts

#### Scenario: Provider omits usage
- **WHEN** a backend response does not include token usage
- **THEN** the adapter returns estimated counts flagged as estimated

### Requirement: Backend health and circuit breaking
Adapters SHALL track consecutive failures per backend. After the configured failure threshold, the backend SHALL be marked unhealthy, dispatch SHALL stop, and recovery SHALL require a successful probe.

#### Scenario: Backend marked unhealthy
- **WHEN** a backend accumulates the configured number of consecutive failures
- **THEN** the scheduler stops dispatching to it and requests are failed over according to scheduling policy

#### Scenario: Backend recovers
- **WHEN** a health probe against a previously unhealthy backend succeeds
- **THEN** the backend is marked healthy and may receive batches again
