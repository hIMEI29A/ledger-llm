# Spec Delta

## Purpose

Loads and validates runtime configuration, exposes operational endpoints for health, readiness, and version reporting, and manages draining and graceful shutdown so deploys and configuration changes do not drop or corrupt in-flight work.

## ADDED Requirements

### Requirement: Configuration loading and validation
The service SHALL load configuration from a file with environment-variable overrides and SHALL validate it at startup. Invalid configuration MUST fail startup with an actionable error naming the offending field.

#### Scenario: Invalid configuration
- **WHEN** the service starts with an invalid or incomplete configuration
- **THEN** it exits non-zero and reports the offending configuration path without starting listeners

#### Scenario: Environment override
- **WHEN** an environment variable overrides a file value
- **THEN** the effective configuration uses the environment value and startup validation applies to it

### Requirement: Secret redaction
Configuration dumps, logs, and admin responses MUST NOT reveal provider API keys, tenant credentials, or other secret values.

#### Scenario: Config inspection
- **WHEN** an operator requests the effective configuration through the admin API or logs
- **THEN** secret values are replaced with a redaction marker

### Requirement: Safe configuration reload
The service SHALL support reload of a documented safe subset of configuration without restart. A reload SHALL apply atomically via a new snapshot; in-flight requests SHALL continue on their original snapshot, and an invalid reload SHALL be rejected while the previous configuration remains active.

#### Scenario: Valid reload
- **WHEN** a valid configuration change is submitted for the safe subset
- **THEN** new requests use the new snapshot while in-flight requests complete under the previous one

#### Scenario: Invalid reload
- **WHEN** a reload contains an invalid value
- **THEN** the reload is rejected, an error is reported, and the previous configuration stays active

### Requirement: Operational endpoints
The service SHALL expose `GET /admin/health`, `GET /admin/ready`, `GET /admin/version`, and `GET /admin/config` returning liveness, readiness, build metadata, and redacted effective configuration respectively.

#### Scenario: Readiness during startup
- **WHEN** the service is still initializing backends
- **THEN** `GET /admin/ready` reports not ready and `GET /admin/health` reports live

#### Scenario: Version reporting
- **WHEN** an operator requests `GET /admin/version`
- **THEN** the response includes version, commit, build time, and Go runtime version

### Requirement: Drain mode
The service SHALL support entering drain mode through `POST /admin/drain`. In drain mode the instance SHALL report not ready, reject new inference requests with a retry hint, and continue processing admitted work.

#### Scenario: Drain requested
- **WHEN** `POST /admin/drain` is called
- **THEN** readiness flips to not ready, new inference requests receive HTTP 503 with a retry hint, and admitted requests continue to completion

### Requirement: Graceful shutdown
On SIGTERM or SIGINT, the service SHALL stop admission, drain in-flight requests for up to the configured grace period, then cancel remaining work and exit. Exit status SHALL distinguish a clean drain from a forced one.

#### Scenario: Clean shutdown
- **WHEN** the service receives SIGTERM and all in-flight requests finish within the grace period
- **THEN** it exits with status 0

#### Scenario: Grace period exceeded
- **WHEN** the grace period expires with requests still in flight
- **THEN** the service cancels remaining work and exits with a non-zero status

### Requirement: Self-observability
The service SHALL expose process-level telemetry covering uptime, goroutine count, open connections, queue depths, and in-flight batches for each tier.

#### Scenario: Queue depth visible
- **WHEN** an operator inspects process telemetry during load
- **THEN** per-tier pending and in-flight batch counts are visible
