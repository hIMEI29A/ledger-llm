# Spec Delta

## Purpose

Groups classified requests into cost-efficient batches keyed by tier, tenant, and deadline, dispatches them to backends, and reconciles every batch into independent per-request results while preserving deadline, isolation, and fairness guarantees.

## ADDED Requirements

### Requirement: Batch formation
The scheduler SHALL accumulate pending requests into batches keyed by tier, tenant, and deadline bucket, bounded by a maximum batch size, a maximum batch byte size, and a maximum formation wait.

#### Scenario: Requests batched together
- **WHEN** several requests share the same tier, tenant, and deadline bucket and fit within batch limits
- **THEN** they are dispatched in a single backend batch

#### Scenario: Formation limits reached
- **WHEN** a batch reaches maximum size or bytes before the maximum wait elapses
- **THEN** the batch is dispatched immediately

#### Scenario: Maximum wait elapses
- **WHEN** the maximum formation wait elapses before a batch is full
- **THEN** the partial batch is dispatched rather than waiting for more requests

### Requirement: Tenant and tier isolation
A single backend call MUST NOT contain requests from different tenants or different tiers.

#### Scenario: Mixed tenants pending
- **WHEN** requests from two tenants are pending for the same tier
- **THEN** they are dispatched as at least two separate backend calls

#### Scenario: Mixed tiers pending
- **WHEN** requests classified into different tiers are pending
- **THEN** each tier's requests are dispatched only to that tier's backend

### Requirement: Deadline-aware dispatch
The scheduler SHALL flush or split a batch early when the earliest request deadline would otherwise be missed. Requests that cannot complete within their remaining deadline SHALL receive a deadline error instead of being sent.

#### Scenario: Earliest deadline approaches
- **WHEN** the earliest request in a pending batch has insufficient remaining time for the estimated backend call
- **THEN** the batch is dispatched immediately or split so that eligible requests still meet their deadlines

#### Scenario: Request cannot meet deadline
- **WHEN** a request's remaining deadline is shorter than the minimum estimated backend call time
- **THEN** the request fails with error code `deadline_exceeded` without a backend call

### Requirement: Per-request reconciliation
Each request in a dispatched batch SHALL receive exactly its own result or error, correlated by request identifier, with no cross-delivery between requests.

#### Scenario: Batch completes with mixed outcomes
- **WHEN** a backend batch returns results for several requests and an error for one of them
- **THEN** each successful request receives its own output and the failing request receives its mapped error

#### Scenario: Duplicate completion prevented
- **WHEN** a request has already received a terminal result
- **THEN** no later event for the same request is delivered to the client

### Requirement: Cancellation handling
Cancelled requests SHALL be removed from pending batches without affecting their batch companions. A batch with no remaining requests MUST NOT be dispatched.

#### Scenario: One request cancelled
- **WHEN** a client cancels while its request waits in a batch
- **THEN** that request is removed and the remaining requests continue normally

#### Scenario: All requests cancelled
- **WHEN** every request in a pending batch is cancelled
- **THEN** the batch is dropped without a backend call

### Requirement: Bounded queues and backpressure
The scheduler SHALL bound pending and in-flight batches per tier, and MUST NOT create unbounded queues or goroutines. When a bound is reached, ingress SHALL reject new work with a retry hint.

#### Scenario: Tier saturated
- **WHEN** the in-flight batch limit for a tier is reached
- **THEN** further requests for that tier are rejected with error code `rate_limited` and a retry hint

### Requirement: Fair scheduling across tenants
Under sustained overload from one tenant, the scheduler SHALL continue dispatching other tenants' requests within the maximum wait, and MUST NOT allow one tenant to starve another.

#### Scenario: Single noisy tenant
- **WHEN** one tenant continuously submits more work than its share while another tenant submits occasional requests
- **THEN** the occasional tenant's requests are dispatched within the maximum wait

### Requirement: Fallback and escalation
When a backend call fails, times out, or is rate-limited, the scheduler SHALL retry within the remaining deadline and MAY escalate the request one tier higher when policy and deadline allow. Every escalation SHALL be recorded.

#### Scenario: Mid-tier failure escalates
- **WHEN** a mid-tier backend call fails or times out and the remaining deadline permits another attempt
- **THEN** the request is retried on the high tier and the escalation is recorded

#### Scenario: No budget to escalate
- **WHEN** retry or escalation cannot complete within the remaining deadline
- **THEN** the request returns the mapped backend error without further attempts
