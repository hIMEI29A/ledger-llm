# Spec Delta

## Purpose

Measures each request and batch across the pipeline, exposes latency, tier, classifier, and cost signals to operators, and publishes a privacy-preserving usage feed that the commercial FinOps layer can consume for chargeback.

## ADDED Requirements

### Requirement: Per-request usage record
The metrics subsystem SHALL record one usage record per terminal request containing request identifier, tenant identifier, tier, model, batch identifier, queue wait, classification duration, upstream duration, total duration, input and output tokens, estimated cost, price-table version, status, and degradation flags.

#### Scenario: Successful request recorded
- **WHEN** a request completes successfully
- **THEN** one usage record is emitted with all required fields populated

#### Scenario: Failed request recorded
- **WHEN** a request terminates with an error
- **THEN** a usage record is emitted with the mapped error status and zero or estimated token counts as applicable

### Requirement: Batch-level telemetry
The metrics subsystem SHALL record one record per dispatched batch containing tier, backend identity, batch size, batch bytes, formation wait, upstream duration, and outcome (success, partial, failure).

#### Scenario: Partial batch failure
- **WHEN** a batch returns a mix of successful and failed requests
- **THEN** the batch record is marked partial and its size is recorded alongside per-request outcomes

### Requirement: Classifier telemetry
The metrics subsystem SHALL expose classification latency, decision counts per tier, confidence distribution, override counts, and degraded-fallback counts.

#### Scenario: Decision counters
- **WHEN** requests are classified
- **THEN** tier decision counters and the latency histogram advance for each request, including overridden and fallback decisions

### Requirement: Metrics export
The service SHALL expose Prometheus-format metrics at `GET /metrics` and SHALL support an OpenTelemetry export path. Label cardinality MUST remain bounded, and tenant identifiers MUST be exported only when explicitly enabled.

#### Scenario: Prometheus scrape
- **WHEN** a metrics scraper requests `GET /metrics`
- **THEN** the response contains the pipeline, classifier, batch, and cost counters and histograms in Prometheus text format

#### Scenario: Tenant label disabled
- **WHEN** tenant labelling is disabled in configuration
- **THEN** exported metrics contain no tenant identifier label

### Requirement: Cost attribution feed
The service SHALL publish append-only usage events for the commercial layer, delivered best-effort with retries while buffered in memory and deduplicable by request identifier, containing tenant, tier, model, token counts, price-table version, cost, currency, and completion timestamp.

#### Scenario: Event published
- **WHEN** a request completes
- **THEN** a usage event is available to a subscribed consumer with an idempotency key equal to the request identifier

#### Scenario: Consumer retries
- **WHEN** a consumer receives the same event twice
- **THEN** the event can be deduplicated by request identifier without double counting

### Requirement: Cost estimation and price table
Cost SHALL be computed from a versioned price table keyed by model and token type. When token usage is missing, counts SHALL be estimated and marked; when a model has no price entry, cost SHALL be recorded as unknown rather than zero-without-flag.

#### Scenario: Missing usage
- **WHEN** a backend omits token usage
- **THEN** the usage record marks token counts and cost as estimated

#### Scenario: Unknown model price
- **WHEN** a completed request uses a model absent from the active price table
- **THEN** the usage record marks cost as unknown and increments an unpriced-model counter

### Requirement: Privacy of telemetry
Metrics and usage events MUST NOT contain prompt text, completion text, or raw request payloads. Only identifiers, sizes, counts, timings, and derived costs may be exported.

#### Scenario: No payload leakage
- **WHEN** any metric or usage event is exported
- **THEN** it contains no prompt or completion content

### Requirement: Non-blocking, bounded export
Metric and usage emission SHALL NOT block request completion. Buffers SHALL be bounded; when an exporter is unavailable, the oldest events SHALL be dropped and a drop counter incremented.

#### Scenario: Exporter unavailable
- **WHEN** the metrics or usage exporter is unreachable
- **THEN** requests continue to complete, the bounded buffer drops the oldest events, and the drop counter increases
