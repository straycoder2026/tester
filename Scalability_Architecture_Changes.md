# Scalability Architecture Changes (Local Store + Enterprise)

## Purpose
This document consolidates all required architecture and code-level changes so another AI/tooling system can quickly understand:
- current behavior,
- bottlenecks,
- required scalable target state,
- phased implementation plan.

---

## 1) Current State (Observed)

### 1.1 Access Pattern
- Desktop flows (Nexxsys) currently execute many operations via direct service/data-access calls to SQL.
- Confirmed path example:
  - `Nexxsys.exe -> SharedService/DAO -> DapperDbContext -> SQL`

### 1.2 API Service Role
- `PropelRxAPIService` is mostly a thin pass-through facade:
  - `Service -> DAO -> SQL` for stores, patients, drugs, prescriptions, prescribers, groups, etc.
- No strong evidence of built-in queueing/throttling/caching orchestration in this service.

### 1.3 Printing Path
- `PrintService` is in-process and can be invoked directly by app/UI flows.
- It queries DB through `PrintDAO`, reads preferences via `SharedService`, renders RDLC, and prints directly.
- Separate Windows print service (`LabelService`) also exists, indicating a second path for print processing.

### 1.4 Messaging / Queue Evidence
- SQL traces show repeated queue-style queries against `DISTransactionQueue`.
- This is strong evidence of DB-backed queue processing behavior.

### 1.5 SQL Hotspots Seen
Repeated high-read patterns include workstation-prefix lookups on:
- `Batch`
- `Patient`
- `PITTask`
- `DISTransactionQueue`
- `PrescriptionStaging`
- `Doctor`
- `Prescription`

Also note:
- `sp_reset_connection` appears frequently but is pool reset noise.

---

## 2) Key Problems

1. Too many direct DB access paths from client-side flows.
2. Heavy operations are not consistently offloaded to async worker queues.
3. SQL bottlenecks (missing/insufficient indexes, scan-heavy patterns).
4. Service responsibilities are mixed (UI-triggered work and background work overlap).
5. No confirmed centralized distributed cache strategy.

---

## 3) Target Scalable Model

### 3.1 Local Store (On-Prem)
- Front door (IIS ARR/reverse proxy) -> IIS API/Web nodes -> SQL + Worker pools.
- Heavy operations should go async through queue tables and worker services.

### 3.2 Enterprise Side
- Outbound integration from local workers to tenant/external services.
- Enterprise ingestion/reporting pipeline should be decoupled from store OLTP.

### 3.3 SQL-backed Queue Strategy
- Keep queue tables inside SQL Server initially (practical in current environment).
- Workers use atomic lease/claim pattern to avoid duplicate processing.

---

## 4) Required Changes (Consolidated)

## 4.1 Access Pattern Changes
- Route write-heavy workstation operations through internal API commands.
- Keep direct DB paths temporarily for legacy compatibility only.

## 4.2 Front Door / IIS Changes
- Introduce/standardize IIS ARR as front door.
- Add health endpoints:
  - `/health/live`
  - `/health/ready`
  - `/health/drain`
- Separate IIS app pools by workload (PatientCenter/API/MTS).

## 4.3 API Layer Changes
- Keep read APIs.
- Add command endpoints for async operations (create job, return tracking ID).
- Add status endpoints (query job/correlation state).
- Add centralized validation, idempotency checks, and throttling/rate limits.

## 4.4 Queue/Worker Model Changes
Create/standardize queues for:
- Messaging
- Claims
- Batch/AADL
- Sync
- Print/Fax
- Reporting

Workers must:
- atomically claim jobs,
- process,
- mark success/retry/failure,
- support DLQ replay.

## 4.5 Scheduler Changes
- Scheduler should enqueue only.
- Use single-active + standby pattern.

## 4.6 Print/Fax Changes
- Current direct in-process print path remains available.
- Prefer async print/fax queue processing for scalability.
- Track print/fax job lifecycle in queue/status tables.

## 4.7 SQL Performance Changes (High Priority)
Add/fix indexes for observed hotspots:
- `Batch(WorkStationId)` (confirmed missing from provided index list)
- `DISTransactionQueue(Status, WorkstationId)`
- `PITTask(LocalStatus, WorkStationId)`
- `Patient(WorkstationId)`
- `PrescriptionStaging(WorkstationId)`
- `Doctor(WorkstationId)`
- `Prescription(wb_status, WorkstationId)`

Also:
- reduce `SELECT *` usage where possible,
- review expensive `DISTINCT` usage,
- align parameter data types/lengths.

## 4.8 File Storage Pattern
- Keep file bytes in shared storage.
- Keep file metadata (path/id/type) in SQL tables.

## 4.9 Caching Strategy
- No confirmed distributed cache currently.
- Optional staged plan:
  - L1: in-process short TTL cache,
  - L2: SQL-backed cache tables (if Redis unavailable),
  - Later: dedicated distributed cache.

## 4.10 Observability / Operations
- Add correlation IDs end-to-end.
- Track per-service metrics:
  - queue depth,
  - oldest pending age,
  - retries,
  - DLQ count,
  - p95 latency,
  - error rate.
- Add alert thresholds and runbooks.

---

## 5) Messaging Service: Critical Scalability Requirements

## 5.1 DB Fields Needed (if missing)
- `LeaseOwner`
- `LeaseUntilUtc`
- `AttemptCount`
- `NextAttemptUtc`
- `LastError`
- `CorrelationId`

## 5.2 Atomic Claim Pattern
- Replace `SELECT pending -> UPDATE` with one atomic claim statement/procedure.
- Use lock hints (`UPDLOCK`, `READPAST`, `ROWLOCK`) for safe concurrency.

## 5.3 Status Lifecycle
- `Pending -> Leased -> Sent`
- `Pending -> Leased -> PendingRetry`
- `Pending -> Leased -> DeadLetter`

## 5.4 Endpoint Isolation
- Separate worker pools by target (tenant/CFM/payer/relay) to avoid head-of-line blocking.

---

## 6) Claims Service: Practical Scalability Requirements
- Queue-based submit/reversal/reconciliation commands.
- Idempotency keys to avoid duplicate adjudication effects.
- Retry/DLQ with classification of transient vs terminal failures.
- Per-payer worker pools and rate controls.

---

## 7) AADL/Batch Flow: Practical Scalability Requirements
- Batch creation should enqueue jobs asynchronously.
- Batch workers claim and process in parallel with lease safety.
- Partition large batches into manageable chunks.
- Track final status and reporting separately from UI request lifecycle.

---

## 8) Front Door Clarification
- Front door = edge reverse proxy/load balancer behavior.
- In this architecture it is expected to be IIS ARR (on-prem).
- It does routing/health/proxy behavior; business logic stays in API/services.

---

## 9) Single-Server vs Two-Server Modes

## 9.1 Single Server (Now)
- Separate app pools/processes.
- Scale via worker parallelism + vertical resource tuning.
- No full HA, but better throughput and isolation.

## 9.2 Two Servers (Later)
- Add second app node and optional second front-door node.
- Enable horizontal scaling + availability.
- Keep same app/service contracts for easy expansion.

---

## 10) Suggested Phased Execution

### Phase 1: Stabilize Performance
1. Apply SQL hotspot index/query fixes.
2. Harden IIS/app pools and health checks.
3. Improve observability baseline.

### Phase 2: Core Scalability
1. Introduce queue lease model.
2. Split worker pools (messaging/claims/sync/batch/print/report).
3. Convert scheduler to enqueue-only.

### Phase 3: Scale and Govern
1. Add/expand front-door routing model.
2. Standardize API command/status endpoints.
3. Mature enterprise ingestion/reporting integration.

---

## 11) Architectural Decision Summary (Short)
- Horizontal scale where possible (IIS/workers), vertical where needed (SQL/host).
- Async background processing for heavy operations.
- SQL-backed queues are acceptable now in on-prem constraints.
- Keep local store operational even when enterprise dependencies are slow.

---

## 12) What to Validate After Each Change
- Throughput increase under concurrent workstation load.
- Reduced SQL logical reads and p95 latency on hotspot queries.
- Queue processing correctness (no duplicate processing).
- Retry and DLQ behavior under failure simulation.
- Graceful drain during service restarts/deployments.

---

## 13) Known Code-Level Anchors Already Seen
- `Shared.RxCore.Services.PropelRxAPIService` (thin service/DAO pass-through)
- `Shared.RxCore.Services.PrintService` (in-process print and DB-driven data composition)
- `PropelRxPrintService.LabelService` (Windows print service path)
- `DISTransactionQueue` related service/models/entities (message queue behavior)

---

## 14) Immediate Next Actions (Practical)
1. Confirm queue schema fields and add missing lease/retry columns.
2. Implement atomic claim in messaging/claim/sync/batch workers.
3. Add missing `Batch(WorkStationId)` index first.
4. Define API command endpoints for heavy operations.
5. Produce runbook with owner/timeline/rollback for each phase.

---

# Appendix A: Current Codebase Structure Map (Practical)

This appendix adds a code-structure view so another AI/tool can map architecture decisions to projects/classes quickly.

## A.1 Solution-Level Project Grouping

### Presentation / UI
- `Nexxsys.Shell`
- `Nexxsys.Modules.*` (Patient, RxDetail, Province, Reports, Workbench, etc.)
- `Nexxsys.UserControls`
- `PatientCenter.Web`

### Business / Service Layer
- `Shared.RxCore`
- `Shared.Infrastructure`
- `Shared.Infrastructure.UI`
- `Shared.Security`

### Data Access
- `Shared.DataAccess`

### Models / Contracts
- `Shared.Models`

### Background/Host Services
- `PropelRxExtService`
- `PropelRxPrintService`
- `PropelRxFaxService`

### Reporting
- `Nexxsys.Modules.Reports`
- `Nexxsys.Reports`
- `Nexxsys.Reports.Library`
- `PatientCenter.Reports`

### Processing / Utility / Domain Extensions
- `Shared.Processing`
- `PHS`
- Other supporting projects in solution

---

## A.2 Key Classes and Responsibilities (Observed in this analysis)

### Data Access & DB execution
- `Shared.DataAccess.DapperDbContext`
  - Opens SQL connections and executes Dapper operations.
  - Handles default-user credential refresh logic on login failure paths.

- `Shared.DataAccess.DBUtils`
  - Builds connection strings.
  - Detects SQL login-related exceptions.
  - Refreshes default service-account credentials.

- `Shared.DataAccess.Implementation.SharedDAO` (and other DAOs)
  - Domain-specific SQL access.

### Service Layer
- `Shared.RxCore.Services.SharedService`
  - Business/service orchestration entry for many desktop and web flows.

- `Shared.RxCore.Services.PropelRxAPIService`
  - Thin service facade; mostly pass-through methods to `IPropelRxAPIDAO`.

- `Shared.RxCore.Services.PrintService`
  - In-process printing orchestration (data retrieval + RDLC render + device/file print).

### Background Services
- `PropelRxExtService.ServiceImplementations.MessageOutQueueProcess`
  - Messaging/outbound queue process path (identified by project/file layout).

- `PropelRxPrintService.LabelService`
  - Print windows service path.

- `PropelRxFaxService.FaxingService`
  - Fax windows service path.

### Queue/Integration Related
- `Shared.DataAccess.Entities.DISTransactionQueue`
  - Confirmed queue-like table/entity from SQL traces and references.

---

## A.3 Current Access Topology (Code-Observed)

1. Desktop can call shared services and DAOs directly to SQL.
2. API service (`PropelRxAPIService`) exists but is mostly DAO pass-through.
3. Printing has both:
   - direct/in-process path via `PrintService`, and
   - windows-service path via `LabelService`.

---

## A.4 If Full Class Structure of Entire Codebase Is Required

Yes, it can be added, but it should be generated automatically to stay accurate.

Recommended generated artifacts:
1. **Project -> Namespace -> Class Index**
2. **Class -> Methods/Properties summary**
3. **Dependency edges** (class A uses class B)
4. **Domain maps** (Patient, Claims, Print, Sync, Messaging, Batch)

Suggested approach:
- Use Roslyn-based scanner or static analysis script to parse all `.cs` files.
- Export markdown tables and Mermaid dependency graphs.
- Append outputs to this document or keep as separate docs under `docs/`.

---

## A.5 Practical Recommendation

Keep this file focused on architecture + change plan, and add two companion docs:

1. `docs/Codebase_Class_Index.md`
   - exhaustive class inventory.

2. `docs/Service_Responsibility_Map.md`
   - service-level responsibilities and data-flow ownership.

This split keeps architecture decisions readable while still preserving full structural detail for AI/tool consumption.

---

# Appendix B: Codebase Class Index (Initial Merged View)

> Note: This is an initial curated index based on currently inspected/identified components. It is designed for architecture planning and AI-assisted navigation. It can be expanded into a complete auto-generated inventory later.

## B.1 Core Data Access Classes

| Project | Namespace/Class | Primary Role |
|---|---|---|
| Shared.DataAccess | `Shared.DataAccess.DapperDbContext` | SQL connection/operation execution (Dapper), exception handling/retry paths |
| Shared.DataAccess | `Shared.DataAccess.DBUtils` | Connection string build, SQL login exception detection, credential refresh helpers |
| Shared.DataAccess | `Shared.DataAccess.Implementation.SharedDAO` | Shared DB operations used by service layer |
| Shared.DataAccess | `Shared.DataAccess.Implementation.AuthenticationDAO` | Service account credential retrieval (`p_SecureGet`) |
| Shared.DataAccess | `Shared.DataAccess.Implementation.BaseNexxsysDAO` | Base DAO utilities, default connection string initialization |

## B.2 Service Layer Classes

| Project | Namespace/Class | Primary Role |
|---|---|---|
| Shared.RxCore | `Shared.RxCore.Services.SharedService` | Cross-domain orchestration entry point |
| Shared.RxCore | `Shared.RxCore.Services.PropelRxAPIService` | Thin API service facade over `IPropelRxAPIDAO` |
| Shared.RxCore | `Shared.RxCore.Services.PrintService` | In-process print orchestration (RDLC, printer settings, DAO data composition) |
| Shared.RxCore | `Shared.RxCore.Services.Mts.DisTransactionQueueService` | Queue-related service path around `DISTransactionQueue` |

## B.3 API / Web Layer Classes (Key)

| Project | Namespace/Class | Primary Role |
|---|---|---|
| PatientCenter.Web | `PatientCenter.Web.Controllers.WorkflowController` | Workflow screen/controller orchestration |
| PatientCenter.Web | `PatientCenter.Web.Controllers.DialogController` | Dialog views/actions orchestration |
| PatientCenter.Web | `PatientCenter.Web.Controllers.FormController` | Form-level UI workflows |
| PatientCenter.Web | `PatientCenter.Web.ApiControllers.PatientsController` | Patient API endpoints |
| PatientCenter.Web | `PatientCenter.Web.ApiControllers.MedicationsController` | Medication API endpoints |
| PatientCenter.Web | `PatientCenter.Web.ApiControllers.HistoriesController` | History API endpoints |
| PatientCenter.Web | `PatientCenter.Web.ApiControllers.ConditionsController` | Condition API endpoints |
| PatientCenter.Web | `PatientCenter.Web.ApiControllers.LabResultsController` | Lab results API endpoints |

## B.4 Desktop/UI Layer Classes (Representative)

| Project | Namespace/Class | Primary Role |
|---|---|---|
| Nexxsys.Modules.Patient | `PatientProfileSearchViewModel` | Patient profile search orchestration |
| Nexxsys.Modules.Patient | `PatientProfileSelectionManager` | Patient selection state management |
| Shared.Security | `InstanceController` | Instance/multi-instance startup checks using preferences |
| Nexxsys.Shell | `App` | Startup flow, credentials initialization, warmup calls |

## B.5 Background Service Classes

| Project | Namespace/Class | Primary Role |
|---|---|---|
| PropelRxExtService | `Services.PropelRxExtService` | Host service entry point for ext/background processes |
| PropelRxExtService | `ServiceImplementations.MessageOutQueueProcess` | Outbound messaging queue processing |
| PropelRxExtService | `ServiceImplementations.ReportSchedulePrintProcess` | Scheduled print/report background process |
| PropelRxPrintService | `LabelService` | Windows print service |
| PropelRxFaxService | `FaxingService` | Windows fax service |

## B.6 Queue / Integration Entity Classes

| Project | Namespace/Class | Primary Role |
|---|---|---|
| Shared.DataAccess | `Entities.DISTransactionQueue` | DB-backed queue entity used in observed messaging flow |
| Shared.Models | `MtsInteractions.DISTransactionQueueModel` | Queue model contract |
| Shared.Models | `SendCommunication.MessageOutQueue` | Outbound message model contract |

## B.7 Batch / ADL Related Classes (Representative)

| Project | Namespace/Class | Primary Role |
|---|---|---|
| Shared.RxCore | `Services.BatchService` | Batch business service entry |
| Shared.DataAccess | `Implementation.BatchDAO` | Batch DAO persistence/query operations |
| Shared.DataAccess | `Entities.AlbertaADLBatchControl` | AADL batch control entity |
| Shared.DataAccess | `Entities.AlbertaADLBatchMaster` | AADL batch master entity |
| Shared.DataAccess | `Entities.AlbertaADLBatchDetail` | AADL batch detail entity |

## B.8 Printing Models/Helpers (Representative)

| Project | Namespace/Class | Primary Role |
|---|---|---|
| Shared.Models | `Print.PrintLabel` | Core print data model for label/report composition |
| Shared.Models | `Print.RxToPrint` | Print request source model |
| Shared.Models | `Print.ReportPrinterInfo` | Printer/report setup model |
| Shared.RxCore | `Services.Printing.RDLCPrintDocument` | RDLC print document wrapper |

## B.9 Startup/Auth-Credential Flow Classes

| Project | Namespace/Class | Primary Role |
|---|---|---|
| Nexxsys.Shell | `App` | Calls service-account setup + initializes default connection strings |
| Shared.DataAccess | `Implementation.AuthenticationDAO` | Retrieves service account password/token |
| Shared.DataAccess | `DBUtils` | Refresh credential and rebuild connection strings |
| Shared.Infrastructure (runtime singleton) | `AppInfo` | Holds default credentials/runtime state |

## B.10 Known Direct SQL Call Paths (From analysis)

1. Desktop/UI -> SharedService/DAO -> DapperDbContext -> SQL
2. PrintService (in-process) -> PrintDAO/SharedService -> SQL
3. APIService methods (PropelRxAPIService) -> IPropelRxAPIDAO -> SQL

---

## B.11 How to Expand This into Full Inventory

To convert this initial index into complete inventory:
1. Enumerate all projects from solution.
2. Parse all `.cs` files by namespace/class.
3. Extract method signatures and direct dependencies.
4. Generate machine-readable maps (markdown + mermaid + optional JSON).

Suggested output structure inside this same document:
- `Appendix C: Full Project-Class Inventory`
- `Appendix D: Method Index`
- `Appendix E: Dependency Graphs by Domain`

---

# Appendix C: Flow Change Plan (Current -> Target)

This section adds explicit flow-level transformation steps and exactly where each change is implemented.

## C.1 Flow 1: UI Direct DB Writes -> Internal API Command Flow

### Current
- `UI -> SharedService/DAO -> DapperDbContext -> SQL`

### Target
- `UI -> Front Door -> Internal API -> (validate/idempotency) -> SQL enqueue -> Worker -> SQL business update`

### Code/Component Change Points
- **UI projects** (`Nexxsys.Modules.*`, `PatientCenter.Web` client paths):
  - replace write-heavy direct service calls with internal API command calls.
- **Internal API layer** (IIS-hosted):
  - add command endpoints and status endpoints.
- **Shared.DataAccess**:
  - queue schema support and job status retrieval.

---

## C.2 Flow 2: Existing External API (Keep) + Internal API (Add)

### Current
- External API service (`PropelRxAPIService`) mostly pass-through to DAO.

### Target
- Keep external API behavior for partner/consumer read contracts.
- Add new internal API for operational commands and scalable write orchestration.

### Code/Component Change Points
- **Keep** `Shared.RxCore.Services.PropelRxAPIService` for existing external behavior.
- **Add** internal API endpoints in app/API host layer for:
  - submit claim/sync/batch/print jobs,
  - check async status by `JobId` / `CorrelationId`.

---

## C.3 Flow 3: In-Process Print -> Queue-Based Scalable Print

### Current
- `UI -> PrintService (in-process) -> DAO/SQL -> RDLC -> Printer/File`

### Target
- Preferred scalable path:
  - `UI/API -> enqueue print job -> LabelService workers -> render/print -> status update`
- Keep in-process print as compatibility fallback during migration.

### Code/Component Change Points
- `Shared.RxCore.Services.PrintService`:
  - add mode/feature toggle to route heavy print to queue.
- `PropelRxPrintService.LabelService`:
  - implement/standardize lease-based worker processing.
- `Shared.DataAccess`:
  - print job queue status/attempt/error fields.

---

## C.4 Flow 4: Messaging/Claim/Sync/Batch Worker Standardization

### Current
- Mixed patterns across background services.

### Target (Standard Worker Contract)
- Common lifecycle: `Pending -> Leased -> Completed | PendingRetry | DeadLetter`
- Common lease fields: `LeaseOwner`, `LeaseUntilUtc`, `AttemptCount`, `NextAttemptUtc`, `LastError`, `CorrelationId`
- Common claim method: atomic lease claim only.

### Code/Component Change Points
- `PropelRxExtService` service implementations (messaging/sync/batch/report processes)
- `PropelRxFaxService.FaxingService`
- `PropelRxPrintService.LabelService`
- `Shared.DataAccess` queue DAO + entities + SQL claim/update objects

---

## C.5 Flow 5: Scheduler Execution -> Enqueue-Only

### Current
- Scheduler may trigger heavy processing directly.

### Target
- Scheduler creates jobs only; workers perform execution.

### Code/Component Change Points
- Scheduler process classes under background service hosts.
- Queue command creation logic in service/data layer.

---

# Appendix D: Worker Standardization Implementation Details

## D.1 Required Queue Fields (Common)
- `JobId`
- `QueueName`
- `Status`
- `PayloadJson` (or payload pointer)
- `Priority`
- `LeaseOwner`
- `LeaseUntilUtc`
- `AttemptCount`
- `MaxRetry`
- `NextAttemptUtc`
- `CorrelationId`
- `LastError`
- `CreatedUtc`
- `UpdatedUtc`

## D.2 Required Queue Operations
1. `Enqueue(job)`
2. `ClaimBatch(workerId, batchSize, leaseSeconds)` (atomic)
3. `MarkCompleted(jobId, workerId)`
4. `MarkRetry(jobId, workerId, nextAttemptUtc, error)`
5. `MarkDeadLetter(jobId, workerId, error)`
6. `ReleaseExpiredLeases()`
7. `ReplayDeadLetter(jobId)`

## D.3 Where to Implement

### A) SQL Objects / DataAccess
- `Shared.DataAccess`:
  - queue entities (including `DISTransactionQueue` alignment),
  - DAO methods for claim/ack/retry/dlq,
  - SQL procedures for atomic claim/update.

### B) Worker Code
- `PropelRxExtService` process classes
- `PropelRxPrintService.LabelService`
- `PropelRxFaxService.FaxingService`

### C) API Orchestration
- internal API command endpoints (enqueue only)
- status endpoints for UI polling

### D) Observability
- standard logs and metrics emitted by all workers and API

---

# Appendix E: Priority Execution Order (What to do first)

## E.1 First (Immediate: performance and safety)
1. SQL hotspot indexes and query-shape fixes.
2. Add health endpoints and app-pool isolation.
3. Baseline metrics/logging with correlation IDs.

## E.2 Next (Scalable write orchestration)
1. Internal API command/status endpoints.
2. Queue schema normalization for at least one pilot domain.
3. Atomic claim implementation for pilot worker.

## E.3 Then (Broader worker rollout)
1. Expand worker standardization to messaging/claim/sync/batch/print/fax/report.
2. Scheduler conversion to enqueue-only.
3. DLQ replay and operational tooling.

## E.4 Finally (Cutover + simplification)
1. Shift remaining direct write paths to internal API.
2. Keep/read-only legacy paths temporarily as needed.
3. Decommission obsolete direct heavy execution paths.

---

# Appendix F: Service-by-Service "Scalability Done" Checklist

## Messaging
- [ ] Atomic claim in place
- [ ] Retry + DLQ + replay
- [ ] Endpoint-isolated workers
- [ ] Queue depth/age metrics

## Claims
- [ ] Async claim command path
- [ ] Idempotency key enforcement
- [ ] Payer-isolated worker pools
- [ ] Retry classification

## Batch/AADL
- [ ] Enqueue batch jobs
- [ ] Chunk/partition strategy
- [ ] Lease-based workers
- [ ] Status/report endpoint

## Print/Fax
- [ ] Queue-first scalable path
- [ ] In-process path controlled by feature flag
- [ ] Worker scaling by queue age
- [ ] Device/error telemetry

## Sync/Integration
- [ ] Outbound queue pattern
- [ ] Circuit breaker/timeouts
- [ ] Endpoint throttling
- [ ] Delivery audit trail

## API/Internal Orchestration
- [ ] Command endpoints
- [ ] Status endpoints
- [ ] Rate limits/throttling
- [ ] Health/drain endpoints