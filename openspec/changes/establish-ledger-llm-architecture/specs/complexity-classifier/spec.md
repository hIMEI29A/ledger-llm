# Spec Delta

## Purpose

Assigns every admitted request to exactly one of three routing tiers using a pure-Go, in-process classifier, returning a confidence value and version within a sub-millisecond budget so routing never becomes the dominant cost.

## ADDED Requirements

### Requirement: Three-tier decision
The classifier SHALL return exactly one tier from `local`, `mid`, or `high`, together with a confidence in the range 0.0 to 1.0 and a classifier version.

#### Scenario: High-complexity request
- **WHEN** a request contains a long, multi-step reasoning or code-generation prompt
- **THEN** the classifier selects the `high` tier with a confidence above the configured threshold

#### Scenario: Trivial request
- **WHEN** a request contains a short, single-sentence factual prompt
- **THEN** the classifier selects the `local` tier

#### Scenario: Confidence range
- **WHEN** the classifier produces any decision
- **THEN** the returned confidence is between 0.0 and 1.0 inclusive

### Requirement: Classification latency budget
Classification SHALL complete within a p99 of 1 ms and a hard ceiling of 5 ms for payloads up to 8 KiB on the documented reference hardware. The classifier MUST perform no network or disk I/O.

#### Scenario: Latency under load
- **WHEN** the classifier is exercised at the target request rate with 8 KiB payloads
- **THEN** the measured p99 classification latency does not exceed 1 ms

#### Scenario: No external calls
- **WHEN** a request is classified
- **THEN** no outbound network request, model inference call, or file read occurs during classification

### Requirement: Deterministic decisions
For the same normalized request, classifier version, and configuration snapshot, the classifier SHALL produce the same tier and confidence.

#### Scenario: Repeated classification
- **WHEN** the same request is classified repeatedly under an unchanged configuration
- **THEN** every call returns the same tier and the same confidence

### Requirement: Explicit tier override
A request MAY carry an explicit tier hint. When present, the system SHALL route to that tier without classification and SHALL mark the decision as overridden.

#### Scenario: Client requests high tier
- **WHEN** a client sends `tier=high` explicitly
- **THEN** the request is routed to the `high` tier, classification is skipped, and the decision is reported as overridden

### Requirement: Uncertain decisions escalate
When the classifier confidence falls below the configured threshold, the request SHALL be marked uncertain and routed no lower than the `mid` tier.

#### Scenario: Low-confidence local decision
- **WHEN** the classifier returns `local` with confidence below the threshold
- **THEN** the request is routed to `mid` and the low-confidence outcome is recorded

### Requirement: Degraded fallback
If classification fails, panics, or exceeds the hard latency ceiling, the request SHALL still be served at the `mid` tier with a degraded flag rather than failing.

#### Scenario: Classifier panic
- **WHEN** the classifier returns an error or exceeds 5 ms
- **THEN** the request is routed to `mid`, the degraded flag is set in response metadata, and a fallback counter is incremented

### Requirement: Version reporting and privacy
The classifier version and feature-schema version SHALL be exposed in response metadata and metrics. Request payloads and extracted features MUST NOT be persisted beyond the request lifetime.

#### Scenario: Version exposed
- **WHEN** a request completes
- **THEN** the response metadata reports the active classifier version and feature-schema version

#### Scenario: No payload retention
- **WHEN** classification completes
- **THEN** no payload text or per-request feature vector is stored outside the request's memory
