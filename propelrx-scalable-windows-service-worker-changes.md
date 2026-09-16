# PropelRx Scalable Windows Service Worker Changes

## Purpose

This proposal describes the worker-level changes required to make PropelRx background Windows services independently scalable, configurable, reliable, and observable.

The primary goal is to improve the execution framework around existing workloads—such as claims, batch, print, pharmacy synchronization, and similar background processing—without redesigning their business logic.

## Current Worker Model

The current model typically starts a Windows service with a fixed, hardcoded number of worker threads. Those workers read work from a queue or queue table and process it.

This approach limits the ability to:

- Adjust processing capacity for different workloads or stores.
- Safely increase parallel processing.
- Recover consistently from transient failures or service restarts.
- Protect SQL Server, RHH, payers, printers, and other downstream systems from overload.
- Measure queue health, processing throughput, and failures.

### Current Flow

```text
Start Windows service
        ↓
Create a fixed number of threads
        ↓
Read items from the queue or queue table
        ↓
Process work
```

Example:

```text
Claims Windows Service
        ↓
Fixed pool of 4 worker threads
```

## Target Worker Model

Each Windows service uses a configurable worker pool and a safe, recoverable processing lifecycle. Capacity can be tuned within the limits of the host and its dependencies.

### Target Flow

```text
Start Windows service
        ↓
Read service, store, and workload configuration
        ↓
Create the configured worker pool
        ↓
Safely claim queue items
        ↓
Process claimed items in parallel
        ↓
Complete, retry, dead-letter, or release each item
        ↓
Report health, status, and processing metrics
```

Example:

```text
Claims Windows Service
        ↓
Configurable worker pool
        ↓
4, 8, or 12 workers, based on workload and capacity
        ↓
Operate within CPU, SQL Server, RHH, payer, and other dependency limits
```

## Required Worker Changes

### 1. Configurable Concurrency

Replace hardcoded thread counts with configuration-driven worker-pool sizes.

The service should support:

- A configurable maximum number of concurrent workers.
- Sensible defaults and safe upper limits.
- Configuration changes appropriate to the service, store, or workload.
- Validation that prevents invalid or unsafe concurrency settings.

This allows capacity to be increased or reduced without changing business logic.

### 2. Safe Queue Claiming and Locking

Queue items must be claimed atomically so that multiple workers—or multiple service instances—cannot process the same item at the same time.

The queue lifecycle should clearly represent states such as:

- Queued
- Claimed or in progress
- Completed
- Waiting for retry
- Failed or dead-lettered

Claims should include enough information to identify ownership and recover abandoned work, such as a worker or service-instance identifier and a claim timestamp or lease expiry.

### 3. Retry Handling

Transient failures should be retried automatically according to a consistent policy.

The policy should define:

- Which errors are retryable.
- Maximum retry attempts.
- Delay or exponential backoff between attempts.
- Optional jitter to prevent many workers from retrying simultaneously.
- Recording of attempt count, timestamps, and the last error.

Permanent or validation failures should not consume unnecessary retries.

### 4. Dead-Letter Handling

Items that exceed the retry limit or encounter a non-recoverable failure should move to a failed or dead-letter state.

Dead-letter records should preserve:

- The original work-item identifier and payload reference.
- Failure reason and diagnostic details.
- Attempt history.
- Service, store, and workload context.
- A controlled way to inspect, correct, and replay the item when appropriate.

### 5. Timeouts and Cancellation

Each operation should have a defined timeout so that one stuck job cannot hold a worker indefinitely.

Workers should support:

- Per-operation or per-work-item timeouts.
- Cooperative cancellation.
- Service-stop cancellation.
- Clear handling of partially completed work.
- Safe release or recovery of claims after timeout or cancellation.

### 6. Downstream Throttling

Concurrency must be constrained by the capacity of downstream dependencies, not only by local CPU or memory.

Workers should support limits for systems such as:

- SQL Server
- RHH
- Payers and external APIs
- Printers
- File shares or other integration endpoints

Throttling may be global, per dependency, per store, or per workload. The aim is to increase throughput without shifting the bottleneck or causing instability elsewhere.

### 7. Health and Status Reporting

Each service should expose enough operational status to determine whether it is functioning correctly.

Useful status includes:

- Service readiness and liveness.
- Configured and active worker counts.
- Idle, busy, stopped, or faulted workers.
- Availability of required dependencies.
- Current backlog and oldest queued item.
- Recent failures or sustained retry activity.

### 8. Metrics and Observability

The worker framework should emit consistent metrics across services.

Recommended metrics include:

- Queue depth.
- Age of the oldest queued item.
- Items claimed, completed, failed, retried, and dead-lettered.
- Processing rate or throughput.
- Average and percentile processing duration.
- Active, idle, and faulted worker counts.
- Timeout and cancellation counts.
- Dependency latency, errors, and throttling events.

Metrics should be tagged with useful dimensions—such as service, workload, store, and result—while avoiding labels that create excessive cardinality.

### 9. Graceful Restart and Recovery

Stopping or restarting a service should not lose work or leave queue items permanently locked.

The shutdown and recovery design should:

- Stop accepting or claiming new work during shutdown.
- Allow active work a configured grace period to finish.
- Cancel remaining work safely when the grace period expires.
- Preserve idempotency or otherwise prevent duplicate side effects.
- Release claims or let leases expire for unfinished items.
- Reclaim abandoned items after a process or host failure.

### 10. Per-Store and Per-Workload Configuration

Different stores and workloads may require different capacity and protection settings. For example, a small retail store and a large long-term-care store should not be forced to use identical worker counts.

Configuration may include:

- Worker count.
- Queue polling frequency and batch size.
- Timeout values.
- Retry count and backoff policy.
- Dependency-specific concurrency or rate limits.
- Graceful-shutdown duration.
- Feature enablement by store or workload.

Configuration precedence and ownership should be explicit—for example, system defaults overridden by service, workload, and store settings.

## Scope and What Does Not Change

This proposal focuses on enhancing the common worker execution model used by PropelRx Windows services.

In scope:

- Worker startup and lifecycle management.
- Concurrency configuration and worker-pool management.
- Queue claiming, locking, and state transitions.
- Retry, timeout, cancellation, and dead-letter behavior.
- Downstream throttling.
- Health reporting, metrics, restart, and recovery behavior.
- Store- and workload-specific configuration.

Not expected to change substantially:

- Existing claims, batch, print, pharmacy-sync, and other domain business rules.
- The user-facing PropelRx application as a whole.
- Unrelated synchronous application functions.
- Downstream systems themselves, except where integration contracts must support safe retries or idempotency.

Some business-processing components may need small changes to accept cancellation, support idempotent execution, classify errors, or expose useful telemetry. These are supporting changes rather than a rewrite of the underlying business logic.

## Concise Architecture Summary

> PropelRx will make its background Windows services independently scalable by replacing fixed-thread execution with configurable worker pools that safely claim work, retry transient failures, isolate unrecoverable items, enforce timeouts and downstream limits, recover cleanly after restarts, and expose consistent health and throughput metrics. The change primarily strengthens the worker framework around existing business logic rather than rewriting that logic or scaling the entire PropelRx application at once.
