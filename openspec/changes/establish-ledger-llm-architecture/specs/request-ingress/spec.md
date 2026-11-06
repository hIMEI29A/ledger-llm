# Spec Delta

## Purpose

Accepts client inference traffic over HTTP and gRPC, normalizes it into a single logical request, and enforces tenant identity, deadlines, payload limits, and admission-level backpressure before any classification or backend work begins.

## ADDED Requirements

### Requirement: HTTP inference endpoints
The service SHALL expose `POST /v1/inference` for JSON completions and `POST /v1/inference/stream` for server-sent events. Both endpoints SHALL accept the same logical request body.

#### Scenario: Non-streaming completion
- **WHEN** a client sends a valid request to `POST /v1/inference`
- **THEN** the service responds with HTTP 200 and a JSON body containing `request_id`, `tier`, `model`, `output`, and `usage`

#### Scenario: Streaming completion
- **WHEN** a client sends a valid request to `POST /v1/inference/stream`
- **THEN** the service responds with HTTP 200, `Content-Type: text/event-stream`, incremental chunk events, and a terminal `[DONE]` event

#### Scenario: Malformed request body
- **WHEN** a client sends a body that is invalid JSON or omits required message content
- **THEN** the service responds with HTTP 400 and error code `invalid_request` without enqueueing the request

### Requirement: gRPC inference service
The service SHALL expose a `ledger.v1.InferenceService` with `Complete` and `Stream` RPCs that accept the same logical request fields as the HTTP endpoints.

#### Scenario: gRPC complete call
- **WHEN** a client calls `Complete` with a valid request
- **THEN** the service returns a response containing `request_id`, `tier`, `model`, `output`, and `usage`

#### Scenario: gRPC stream call
- **WHEN** a client calls `Stream` with a valid request
- **THEN** the service emits ordered stream chunks followed by a terminal status message

### Requirement: Protocol-equivalent normalization
The service SHALL normalize HTTP and gRPC input into one logical request carrying `request_id`, `tenant_id`, payload, token estimate, deadline, stream flag, optional idempotency key, and optional tier hint.

#### Scenario: Equivalent requests route identically
- **WHEN** semantically equivalent requests arrive over HTTP and gRPC
- **THEN** both receive the same tier decision and the same normalized request fields

### Requirement: Tenant authentication and isolation
The service SHALL require a valid tenant credential on every inference request and SHALL bind each request to exactly one tenant. Missing or invalid credentials MUST be rejected before admission.

#### Scenario: Missing credential
- **WHEN** a request arrives without a tenant credential
- **THEN** the service responds with HTTP 401 or gRPC `Unauthenticated` and does not enqueue the request

#### Scenario: Tenant identity propagated
- **WHEN** an authenticated request is accepted
- **THEN** the response metadata includes the resolved tenant identifier

### Requirement: Deadline propagation and cancellation
The service SHALL honor the client-supplied deadline. Work MUST NOT start when the remaining deadline is insufficient to attempt a backend call, and client disconnection SHALL cancel upstream work.

#### Scenario: Deadline already exceeded
- **WHEN** a request arrives with a deadline that has already expired
- **THEN** the service responds with error code `deadline_exceeded` without invoking a backend

#### Scenario: Client disconnects mid-flight
- **WHEN** a client closes the connection while its request is queued or in flight
- **THEN** the service cancels the request, releases its queue slot, and removes it from any pending batch

### Requirement: Admission control and backpressure
The service SHALL bound the number of queued requests and MUST NOT buffer requests without limit. When the bound is reached, new requests SHALL be rejected with a retry hint.

#### Scenario: Queue saturation
- **WHEN** the admission queue is full
- **THEN** the service responds with HTTP 429 or gRPC `ResourceExhausted`, error code `rate_limited`, and a `Retry-After` hint

### Requirement: Payload size limits
The service SHALL reject payloads that exceed the configured maximum request size before classification and before enqueueing.

#### Scenario: Oversized payload
- **WHEN** a request body exceeds the configured maximum size
- **THEN** the service responds with HTTP 413 and error code `invalid_request`

### Requirement: Response routing metadata
Every accepted request SHALL return routing metadata identifying the handling decision so clients and operators can correlate requests.

#### Scenario: Routing headers present
- **WHEN** a request completes successfully
- **THEN** the response includes the request identifier, selected tier, classifier version, and a degraded flag
