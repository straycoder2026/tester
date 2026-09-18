# Phase4 ProcessNewRx CreateRxs Assessment

## Scope and Guardrails
- [CODE-PROVEN] This is a read-only workflow analysis from `ProcessNewRxViewModel.OnOkClick(...)` → `ProcessOkClick(...)` → runtime `CreateRxs()` implementations and downstream service/DAO effects.
- [CODE-PROVEN] Evidence is file/symbol/line based and follows the same evidence style used in prior phases.
- [UNKNOWN] Several SQL object definitions are not present in this repo (for example, internals of `dbo.p_SetRxWbStatus`, `dbo.p_AddPrescriptionStaging`, `dbo.p_UpdatePrescriptionStaging`, `dbo.p_Labyrinth_InsertRxPrintRequest`).

---

## 1) Runtime `RxItem` Type Resolution and `CreateRxs()` Implementation Map

### 1.1 Concrete runtime type mapping in navigator
- [CODE-PROVEN] `ProcessNewRxNavigator.GetRxItem(...)` maps by `WbTypeCode`:
  - `ics_Rx` → `PassthroughExistingRxInstance`
  - `ics_IntakePrescription` / `ics_MinorAilmentsPrescription` / `ics_BcPpmDownloadRx` → `RegularNewRxInstance`
  - `ics_PhotoRxPrescription` → `PhotoRxNewRxInstace`
  - `ics_PrescribeITTask` → `PITNewRxInstance`
  - Evidence: `Nexxsys.Modules.RxDetail/ViewModels/ProcessNewRxNavigator.cs:67-85`.

### 1.2 Which `CreateRxs()` runs for each runtime type
- [CODE-PROVEN] `PassthroughExistingRxInstance` overrides `CreateRxs()`, saves attachments, and returns the existing Rx as the result.
  - Evidence: `Nexxsys.Modules.RxDetail/ViewModels/PassthroughExistingRxInstance.cs:164-169`, `:181-197`.
- [CODE-PROVEN] `PITNewRxInstance` overrides `CreateRxs()` and then performs PIT-specific side effects (split-group record, attachment copy, PIT note copy, sticky note copy, conditional PIT lock release).
  - Evidence: `Nexxsys.Modules.RxDetail/ViewModels/PITNewRxInstance.cs:177-259`.
- [CODE-PROVEN] `RegularNewRxInstance.RegularProcessNewRxUIItem` does **not** override `CreateRxs()` in this file; runtime uses base implementation from `BaseProcessNewRxUIItem`.
  - Evidence: no `CreateRxs` override in `RegularNewRxInstance.cs`, base implementation at `Nexxsys.Modules.RxDetail/ViewModels/BaseProcessNewRxUIItem.cs:2278-2295`.
- [CODE-PROVEN] `PhotoRxNewRxInstace.PhotoRxProcessNewRxUIItem` does **not** override `CreateRxs()`; runtime also uses base `BaseProcessNewRxUIItem.CreateRxs()`.
  - Evidence: full class in `Nexxsys.Modules.RxDetail/ViewModels/PhotoRxNewRxInstace.cs:1-334` (contains `AddNewRx` override but no `CreateRxs` override), base method at `BaseProcessNewRxUIItem.cs:2278-2295`.

---

## 2) End-to-End Entry and Batch Orchestration

### 2.1 UI gate and validation chain (`OnOkClick`)
- [CODE-PROVEN] `OnOkClick(...)` performs PrescribeIT activation checks for bundle items, optional RxNumbers fast-path, then per-item `ValidateForProcess()` and cross-item validation (`ValidateAllRxs()`) before delegating to base modal OK.
  - Evidence: `Nexxsys.Modules.RxDetail/ViewModels/ProcessNewRxViewModel.cs:1674-1753`.
- [CODE-PROVEN] `ValidateAllRxs()` enforces unique authorization-chain processing by reading each item’s `_newRxActions` payload via `GetRxInfoToProcess()` and rejecting duplicates by `AuthRxId`.
  - Evidence: `ProcessNewRxViewModel.cs:1823-1861`; `BaseProcessNewRxUIItem.cs:2297-2305`.

### 2.2 Batch create execution (`ProcessOkClick`)
- [CODE-PROVEN] `ProcessOkClick(...)` loops all visible `RxNavigator.Items`, calls `newRxItem.RxItem.CreateRxs()`, and accumulates created/selected/skipped sets.
  - Evidence: `ProcessNewRxViewModel.cs:1768-1797`.
- [CODE-PROVEN] On first create failure (`!createResult.Success`) it clears accumulated results and breaks the loop.
  - Evidence: `ProcessNewRxViewModel.cs:1778-1783`.
- [CODE-PROVEN] OCR side-effects: updates recognized OCR save payload for created items and marks excluded OCR items as not recognized.
  - Evidence: `ProcessNewRxViewModel.cs:1785-1788`, `:1800-1804`.
- [CODE-PROVEN] If nothing was created, it cancels modal OK (`CancelOkClick = true`) and returns.
  - Evidence: `ProcessNewRxViewModel.cs:1807-1813`.
- [CODE-PROVEN] Post-create hooks are split by item category: `SkippedInCreateRx()` for skipped items, `PreProcessClick()` for selected items.
  - Evidence: `ProcessNewRxViewModel.cs:1815-1820`.

---

## 3) Base `CreateRxs()` Mechanics (Regular + Photo runtime paths)

### 3.1 Where business operation is actually decided
- [CODE-PROVEN] `ValidateDuplicateDrug()` initializes and populates `_newRxActions` with action closures for each selected drug.
  - Evidence: `BaseProcessNewRxUIItem.cs:1733-1737`.
- [CODE-PROVEN] Branches in closure construction:
  - New RX path closure calls `AddNewRx(rx)`.
	- Evidence: `BaseProcessNewRxUIItem.cs:1782-1855`.
  - ReAuth path closure releases lock then calls `AddReauth(ref rx)` and error handler.
	- Evidence: `BaseProcessNewRxUIItem.cs:1967-1984`.
  - Refill path closure conditionally releases staging/source lock, then calls `AddRefill(rx)` and error handler.
	- Evidence: `BaseProcessNewRxUIItem.cs:2042-2069`.
- [CODE-PROVEN] `CreateRxs()` itself is a dispatcher over `_newRxActions`, invoking each closure and collecting returned item(s).
  - Evidence: `BaseProcessNewRxUIItem.cs:2278-2295`.

### 3.2 Service calls behind closure methods
- [CODE-PROVEN] Base wrapper methods route to `PrescriptionService`:
  - `AddNewRx(...)` → `PrescriptionService.AddNewRx(...)`
  - `AddReauth(...)` → `PrescriptionService.AddReAuthRx(...)`
  - `AddRefill(...)` → `PrescriptionService.AddRefill(...)`
  - Evidence: `BaseProcessNewRxUIItem.cs:2359-2374`.

### 3.3 `PreProcessClick()` and staging source updates
- [CODE-PROVEN] For selected items, `PreProcessClick()` may update staging source linkage after create (`UpdatePrescriptionStagingSource`).
  - Evidence: `BaseProcessNewRxUIItem.cs:2268-2272`; `PrescriptionService.cs:11972-11974`; `PrescriptionDAO.cs:3213-3217`.

---

## 4) Specialized Runtime Paths

### 4.1 Passthrough existing Rx path
- [CODE-PROVEN] No new Rx creation, no new refill/reauth; only attachment persistence for existing Rx and return that existing Rx in result list.
  - Evidence: `PassthroughExistingRxInstance.cs:164-169`, `:181-197`.

### 4.2 PIT path
- [CODE-PROVEN] PIT `CreateRxs()` starts with base create, then applies PIT-only work:
  - conditional PIT task lock release when user effectively chose refill-existing semantics,
  - split Rx group insert,
  - copy PIT bundle attachments to RX entity,
  - save synthesized PIT notes,
  - copy sticky note from PIT task to RX.
  - Evidence: `PITNewRxInstance.cs:177-259`.
- [CODE-PROVEN] PIT overrides also alter refill/reauth behavior and lock sequencing, including additional save after reauth and lock handling.
  - Evidence: `PITNewRxInstance.cs:435-552`.

### 4.3 Photo path
- [CODE-PROVEN] Photo does not override `CreateRxs()`, but overrides `AddNewRx(...)` to set urgent/web-refill flags for app-origin cases and save additional info attachments after base add succeeds.
  - Evidence: `PhotoRxNewRxInstace.cs:167-205`, `:207-228`.

---

## 5) Downstream `PrescriptionService` Create/Save Call Chains

### 5.1 New Rx (`AddNewRx`)
- [CODE-PROVEN] `AddNewRx` hydrates and normalizes patient/doctor/drug/product defaults, status/workbench fields, staging-derived data and notes, language/sig fields, dosage defaults, BC branch defaults, then inserts via `InsertPrescription(...)`.
  - Evidence: `Shared.RxCore/Services/PrescriptionService.cs:7242-7512`.
- [CODE-PROVEN] Post-insert side-effects include BC notes save and Rx dosage header persistence, and minor-ailments post-processing.
  - Evidence: `PrescriptionService.cs:7513-7553`.

### 5.2 Refill (`AddRefill`)
- [CODE-PROVEN] `AddRefill(...)` is a decision hub that normalizes fields and routes by current status/authorization/expiry/quantity to one of several branches (activate-by-copy, refill-insert path, reauth path).
  - Evidence: `PrescriptionService.cs:6235-6554`, especially decision ranges `:6368-6495`.
- [CODE-PROVEN] In refill insert branch (`AddRefillRx` path), it resets refill context, copies notes/dosages, optionally split data, then inserts via `InsertPrescription(...)`; amend-next branch may copy pricing and regenerate/save claims.
  - Evidence: `PrescriptionService.cs:7068-7240`.

### 5.3 Reauth (`AddReAuthRx`)
- [CODE-PROVEN] Reauth resets auth/rx numbering and statuses, handles group/admin-time and DIS resets, computes dates/notes, inserts via `InsertPrescription(...)`, then applies post-insert updates (`AddDispill`, DIS type/route, optional status update for ATF).
  - Evidence: `PrescriptionService.cs:7864-8060`.

### 5.4 Common insert transaction (`InsertPrescription`)
- [CODE-PROVEN] Insert path executes within `Util.RunInTransaction(...)`; scrubs/new-id resets, calls `Save(newRx, ...)`, then additional post-save methods (`AddMethadoneInfo`, split copy, note updates).
  - Evidence: `PrescriptionService.cs:7636-7769`.
- [CODE-PROVEN] `Save(...)` calls DAO `SavePrescription(...)`, audit history methods, and invokes patient profile refresh event.
  - Evidence: `PrescriptionService.cs:57-146`.
- [CODE-PROVEN] DAO save chooses insert/update and includes Rx/extended/workflow/claims persistence logic; insert notes mention DB triggers for extended/workflow seed rows.
  - Evidence: `Shared.DataAccess/Implementation/PrescriptionDAO.cs:269-287`, `:776-1235`.

---

## 6) Database Reads/Writes and SQL Objects (proven in this path)

### 6.1 Key Rx persistence and status procedures/functions
- [CODE-PROVEN] Workbench status updates call `dbo.p_SetRxWbStatus`.
  - Evidence: `PrescriptionDAO.cs:1531-1558`; service wrapper `PrescriptionService.cs:5961-5978`.
- [CODE-PROVEN] Ready time updates call `dbo.p_UpdateRxReadyTimeAndPriority`.
  - Evidence: `PrescriptionDAO.cs:1595-1603`; service wrapper `PrescriptionService.cs:5447-5449`.

### 6.2 Staging and attachment propagation
- [CODE-PROVEN] Staging save/update uses `dbo.p_AddPrescriptionStaging` / `dbo.p_UpdatePrescriptionStaging`.
  - Evidence: `PrescriptionDAO.cs:3177-3188`.
- [CODE-PROVEN] Staging source reassignment updates `PrescriptionStaging.SourceId`.
  - Evidence: `PrescriptionDAO.cs:3213-3217`.
- [CODE-PROVEN] Staging attachments copied to rx by `dbo.p_AddRxStagingAttachmentsToRx`.
  - Evidence: `PrescriptionDAO.cs:295-299`.

### 6.3 Claims and print-request related objects reachable from traced methods
- [CODE-PROVEN] Claim persistence exists via `SaveClaims` path and claim table write helpers in DAO.
  - Evidence: `PrescriptionService.cs:10422-10424`; `PrescriptionDAO.cs:689` (method), `:176-193` (drop/resave claims).
- [CODE-PROVEN] Rx print request procedures exist in DAO (`dbo.p_Labyrinth_InsertRxPrintRequest`, `dbo.p_InsertRxPrintRequest`, `dbo.p_InsertOpioidPrintRequest`).
  - Evidence: `PrescriptionDAO.cs:2027-2054`.
- [INFERRED] Whether a given Phase4 create action enqueues a print request depends on deeper business conditions outside the directly shown `ProcessNewRxViewModel` methods.

---

## 7) Concurrency/Locking Model

- [CODE-PROVEN] Initial lock acquisition happens when ProcessNewRx items are materialized (`AcquireLock` per new item, including expanded OCR items).
  - Evidence: `ProcessNewRxViewModel.cs:180-209`.
- [CODE-PROVEN] Concrete lock target differs by runtime type:
  - Regular: staging lock and (for intake with source) source-Rx soft lock.
	- Evidence: `RegularNewRxInstance.cs:907-918`.
  - Photo: staging soft lock.
	- Evidence: `PhotoRxNewRxInstace.cs:292-300`.
  - PIT: PIT task soft lock.
	- Evidence: `PITNewRxInstance.cs:1297-1305`.
  - Passthrough: prescription soft lock.
	- Evidence: `PassthroughExistingRxInstance.cs:149-157`.
- [CODE-PROVEN] Lock release occurs on item removal/cancel flows and in certain create closures (refill/reauth paths) before service calls.
  - Evidence: `ProcessNewRxViewModel.cs:1080-1086`, `:1315-1319`, `:1340-1349`; `BaseProcessNewRxUIItem.cs:1974`, `:2054-2059`; `PITNewRxInstance.cs:189-190`, `:441-442`.

---

## 8) Error, Partial Failure, Retry, and Duplicate-Submission Risk

- [CODE-PROVEN] Batch behavior is stop-on-first-create-failure: clears accumulated result list and breaks loop.
  - Evidence: `ProcessNewRxViewModel.cs:1778-1783`.
- [CODE-PROVEN] Because creates run sequentially in the loop and each item can already have executed writes before a later failure, this is a partial-success exposure at the batch level.
  - Evidence: per-item create call in loop `ProcessNewRxViewModel.cs:1774-1777` + break behavior `:1778-1783`.
- [CODE-PROVEN] Duplicate chain protection exists before create execution (`ValidateUniqueAuthChains`) using all planned actions from each item.
  - Evidence: `ProcessNewRxViewModel.cs:1831-1861`.
- [INFERRED] User double-submit risk is reduced by modal flow and blocking async wait (`RunTaskASync(..., true).WaitWithPumping()`), but robust idempotency across retries would still require DB/service-level guarantees.
  - Evidence: `ProcessNewRxViewModel.cs:1770-1805`; `Shared.Infrastructure.UI/Events/EventHelper.cs:213-234`; `Shared.Infrastructure.UI/AsyncHelpers.cs:48-59`.

---

## 9) Transaction Boundaries

- [CODE-PROVEN] `InsertPrescription(...)` wraps core insert/save logic in `Util.RunInTransaction(...)`.
  - Evidence: `PrescriptionService.cs:7636-7769`.
- [CODE-PROVEN] `Save(...)` itself delegates to DAO save and then performs additional operations (audit history, refresh event), so end-to-end item processing includes work both inside and outside that transaction scope.
  - Evidence: `PrescriptionService.cs:57-146`.
- [INFERRED] Batch-level transaction across all `RxNavigator.Items` is not present in `ProcessOkClick`; each item is processed independently.
  - Evidence: per-item loop `ProcessNewRxViewModel.cs:1774-1797`.

---

## 10) Required Side-Effect Coverage Checklist

| Concern | Status | Evidence |
|---|---|---|
| UI validation and gating | [CODE-PROVEN] | `ProcessNewRxViewModel.cs:1674-1753`, `BaseProcessNewRxUIItem.cs:2224-2264` |
| Item creation/saving | [CODE-PROVEN] | `BaseProcessNewRxUIItem.cs:2278-2295`; `PrescriptionService.cs:7242-7553`, `:6235-6554`, `:7864-8060` |
| Concurrency locks | [CODE-PROVEN] | `ProcessNewRxViewModel.cs:180-209`; runtime acquire/release overrides in item classes |
| Claim creation/adjudication touchpoints | [CODE-PROVEN]/[INFERRED] | save/generate hooks in `PrescriptionService.cs:7212-7226`, `:10422-10424`; detailed adjudication runtime path not fully in current call slice |
| External calls/integrations (PIT, PharmaNet, MTS) | [CODE-PROVEN] | PIT/PharmaNet/MTS service calls in `PrescriptionService` and PIT instance methods |
| DB reads/writes | [CODE-PROVEN] | `PrescriptionDAO.cs` methods cited above |
| Audit/history records | [CODE-PROVEN] | `PrescriptionService.cs:97-114` |
| Workbench/queue updates | [CODE-PROVEN] | WB status wrappers `PrescriptionService.cs:5961-5978`; DAO SP `PrescriptionDAO.cs:1531-1558` |
| Print request hooks | [CODE-PROVEN] | DAO print SP methods `PrescriptionDAO.cs:2027-2054` |
| OCR updates | [CODE-PROVEN] | `ProcessNewRxViewModel.cs:1785-1788`, `:1800-1804` |
| Sticky notes/attachments | [CODE-PROVEN] | PIT and passthrough paths; staging attachment copy hooks |
| Post-save refresh/events | [CODE-PROVEN] | `PrescriptionService.cs:139-143` |
| Partial failure semantics | [CODE-PROVEN] | `ProcessNewRxViewModel.cs:1778-1783` |

---

## 11) Call-Count Model (requested variables `B`, `R`, `PL`, `CL`, `A`, `L`, `V`)

### 11.1 Variable definitions used in this report
- `B` = total visible items processed in one OK batch (`RxNavigator.Items.Count` at execution).
- `R` = number of created rx outputs (`ReadyToProcessRxs.Count` after `ProcessOkClick`).
- `PL` = number of PIT items in batch.
- `CL` = number of closure actions generated in `_newRxActions` across all selected items (approximately sum of selected drugs/actions; can exceed `B`).
- `A` = number of attachment records copied/inserted in post-create hooks.
- `L` = number of lock acquire/release operations executed in this modal session.
- `V` = number of item-level validations (`ValidateForProcess`) executed (normally `B`).

### 11.2 Deterministic counts from code structure
- [CODE-PROVEN] `ValidateForProcess` calls per OK attempt: `V = B` unless method exits early on first invalid item.
  - Evidence: `ProcessNewRxViewModel.cs:1726-1741`.
- [CODE-PROVEN] Create calls per OK attempt: up to `B` (`CreateRxs()` once per item), but may short-circuit at first failure.
  - Evidence: `ProcessNewRxViewModel.cs:1774-1783`.
- [CODE-PROVEN] Base closure invocations: total is `CL` (sum of `_newRxActions` entries across items that reached create stage).
  - Evidence: `BaseProcessNewRxUIItem.cs:1736`, `:2278-2292`.
- [CODE-PROVEN] OCR excluded-save calls: equals count of `_excludedOcrRxDrugInfoList`.
  - Evidence: `ProcessNewRxViewModel.cs:1800-1804`.

### 11.3 Formula view for key operation families
- Item create invocations: `CreateInvocations <= B` (exactly `B` only if no create failure).
- Core prescription service writes (new/refill/reauth): approximately `CL` action calls to one of `{AddNewRx, AddRefill, AddReAuthRx}`.
- PIT post-create extra operations:
  - split-group inserts ≈ `PL_with_split` (<= `PL`),
  - PIT attachment inserts contributes to `A`,
  - PIT note/sticky writes up to `PL` each when data exists.
- Lock operations:
  - acquires during load ≈ `B` (+ OCR expansion factor),
  - releases depend on user removals/cancel and per-closure release paths; total represented as `L` because exact count is path-dependent.

---

## 12) Sequence Diagram (Phase4 create path)

```mermaid
sequenceDiagram
	participant UI as ProcessNewRxViewModel
	participant Item as RxItem (runtime concrete)
	participant Base as BaseProcessNewRxUIItem
	participant PS as PrescriptionService
	participant DAO as PrescriptionDAO
	participant DB as SQL Server

	UI->>UI: OnOkClick()
	UI->>Item: ValidateForProcess() [for each item]
	UI->>UI: ValidateAllRxs()
	UI->>UI: ProcessOkClick()

	loop each RxNavigator item
		UI->>Item: CreateRxs()
		alt Regular/Photo (base create)
			Item->>Base: CreateRxs()
			loop each _newRxAction
				Base->>PS: AddNewRx/AddRefill/AddReAuthRx
				PS->>PS: InsertPrescription(...)
				PS->>PS: Save(...)
				PS->>DAO: SavePrescription(...)
				DAO->>DB: INSERT/UPDATE Prescription + related
			end
		else PIT
			Item->>Base: CreateRxs()
			Item->>PS: AddSplitRxGroup(...)
			Item->>DB: attachment/note/sticky writes via services
		else Passthrough
			Item->>DB: save attachments only
		end

		alt create failure
			UI->>UI: clear accumulated result; break loop
		else create success
			UI->>UI: accumulate returned item(s)
		end
	end

	UI->>DB: SaveSingleOcrRxDrugInfo(excluded OCR items)
	UI->>Item: PreProcessClick() / SkippedInCreateRx()
```

---

## 13) Key Findings Summary
- [CODE-PROVEN] `CreateRxs()` behavior is polymorphic and **not** uniform; PIT and passthrough have distinct side effects, while regular/photo rely on base closure dispatch.
- [CODE-PROVEN] Real business create decisions are built during validation (`ValidateDuplicateDrug`) and executed later in `CreateRxs()`.
- [CODE-PROVEN] Item-level transactions exist (`InsertPrescription`), but batch-level all-or-nothing transaction is absent at `ProcessOkClick`.
- [CODE-PROVEN] Batch loop has explicit stop-on-first-failure semantics and can produce partial-success outcomes.
- [CODE-PROVEN] Concurrency lock handling spans load, per-closure create logic, and cleanup paths; lock target varies by item type.

---

## 14) Runtime Verification Backlog
- [RUNTIME-VERIFY] Capture SQL execution counts/latencies for `SavePrescription`, `p_SetRxWbStatus`, staging SPs, and claim/save paths under mixed batches (`B` large, mixed `PL`, mixed `CL`).
- [RUNTIME-VERIFY] Validate print request SP invocation frequency for creation scenarios in production-like settings.
- [RUNTIME-VERIFY] Confirm duplicate-submit protection under rapid repeated OK interactions and transient DB/network failures.
