# Phase 1 Assessment: Solution Inventory, Dependency Map, Evidence Index, and Current Component Architecture

## 1) Scope and Guardrails
- **Phase executed:** Phase 1 only (inspection/inventory/architecture baseline).
- **No production modification performed:** No changes to code, stored procedures, config, or deployment artifacts.
- **Evidence standard:** Every conclusion below cites exact file/class/method or stored-procedure reference.
- **Runtime verification labels:** Any item requiring execution-time proof is explicitly labeled **[RUNTIME VERIFICATION REQUIRED]**.

---

## 2) Solution Inventory (Project-Level)

### 2.1 Total projects discovered
- **41 projects** in solution. *(Evidence: E01)*

### 2.2 Functional grouping (inventory baseline)

#### A. Desktop shell + UI modules
- `Nexxsys.Shell\Nexxsys.Shell.csproj`
- `Nexxsys.UserControls\Nexxsys.UserControls.csproj`
- `Nexxsys.Modules.*` (Misc, Workbench, Pharmacy, Province, Patient, Drug, Inventory, Doctor, RxEvaluate, OrderSupplier, RxDetail, Groups, Navigation, Security, Reports, Pricing)

**Conclusion:** The solution is modular desktop-centric with separate domain modules under `Nexxsys.Modules.*`. *(Evidence: E01, E05-E07)*

#### B. Core shared layers
- `Shared.Models\Shared.Models.csproj`
- `Shared.Infrastructure\Shared.Infrastructure.csproj`
- `Shared.Infrastructure.UI\Shared.Infrastructure.UI.csproj`
- `Shared.DataAccess\Shared.DataAccess.csproj`
- `Shared.RxCore\Shared.RxCore.csproj`
- `Shared.Security\Shared.Security.csproj`
- `Shared.Validation\Shared.Validation.csproj`
- `Shared.Processing\Shared.Processing.csproj`
- `Shared.Print\Shared.Print.csproj`

**Conclusion:** Shared layered architecture exists with model/infrastructure/data/service/security boundaries. *(Evidence: E01, E03, E04, E15)*

#### C. Services / background processors
- `PropelRxExtService\PropelRxExtService.csproj`
- `PropelRxFaxService\PropelRxFaxService.csproj`
- `PropelRxPrintService\PropelRxPrintService.csproj`
- `CPS_Monitor\CPS_Monitor.csproj`
- `CPS_Report\CPS_Report.csproj`
- `CPS_Library\CPS_Library.csproj`

**Conclusion:** Dedicated long-running/background workloads are separated into service projects. *(Evidence: E01, E13, E14)*

#### D. Web/reporting/API-adjacent
- `PatientCenter.Web\PatientCenter.Web.csproj`
- `PatientCenter.Reports\PatientCenter.Reports.csproj`
- `Nexxsys.Reports\Nexxsys.Reports.csproj`
- `Nexxsys.Reports.Library\Nexxsys.Reports.Library.csproj`
- `PHS\PHS.csproj`

**Conclusion:** The ecosystem includes web/reporting surfaces alongside desktop and service workloads. *(Evidence: E01)*

#### E. Test projects
- `Nexxsys.UnitTests\Nexxsys.UnitTests.csproj`
- `Shared.UnitTests\Shared.UnitTests.csproj`
- `Nexxsys.UnitTests.PrescribeIT\Nexxsys.UnitTests.PrescribeIT.csproj`

**Conclusion:** Unit-test coverage projects exist for core and integration-specific areas. *(Evidence: E01)*

---

## 3) Dependency Map (Phase 1, evidence-backed)

## 3.1 Confirmed method-level dependency chain (runtime stack)
1. `Shared.RxCore.Services.SharedService.GetPreferenceValueByEntity(...)`
   - File: `Shared.RxCore\Services\SharedService.cs` lines 1569-1572
2. calls `Shared.DataAccess.SharedDAO.GetPreferenceValueByEntity(...)`
   - File: `Shared.DataAccess\Implementation\SharedDAO.cs` lines 2764-2768
3. which calls `Shared.DataAccess.DapperDbContext.QueryFirstOrDefault<T>(...)`
   - File: `Shared.DataAccess\DapperDbContext.cs` lines 169-176
4. which executes through `ExecuteOnNewConnection<TResult>(...)`
   - File: `Shared.DataAccess\DapperDbContext.cs` lines 557-636

**Conclusion:** `Shared.RxCore -> Shared.DataAccess` dependency is directly confirmed at method level. *(Evidence: E05, E06, E07, E08)*

## 3.2 Confirmed DB object usage in that path
- SQL executed in `SharedDAO.GetPreferenceValueByEntity(...)`:
  - `SELECT dbo.f_PreferenceRetrieve(@entityCode, @entityId, @preferenceCode)`

**Conclusion:** Preference retrieval depends on DB scalar function `dbo.f_PreferenceRetrieve`. *(Evidence: E06)*

## 3.3 Confirmed authentication/error-handling dependency in data access
- `DapperDbContext.ExecuteOnNewConnection(...)` uses:
  - `DBUtils.IsDefaultUserException(...)`
  - `DBUtils.RefreshDefaultUserCredentials(...)`
  - `DBUtils.HandleAction(...)`

**Conclusion:** SQL login failure handling is centralized in `Shared.DataAccess` and not in individual business services. *(Evidence: E08, E09, E10, E11)*

## 3.4 Service and messaging components present in codebase
- External service processes include:
  - `PropelRxExtService\ServiceImplementations\MessageOutQueueProcess.cs`
  - `...\PrescribeITProcess.cs`, `...\ReportSchedulePrintProcess.cs`, etc.
- RxCore messaging service code includes:
  - `Shared.RxCore\Services\SendCommunication\MessageOutQueueService.cs`
- Messaging model artifacts include:
  - `Shared.Models\SendCommunication\MessageOutQueue.cs`

**Conclusion:** Messaging is implemented across service host (`PropelRxExtService`), business services (`Shared.RxCore`), and shared models (`Shared.Models`). *(Evidence: E03, E13, E15)*

## 3.5 Batch/monitor components present in codebase
- `CPS_Monitor\Program.cs`
- `CPS_Monitor\frmMonitor.cs`
- `CPS_Monitor\ProcUtil.cs`
- `Shared.RxCore\Services\BatchService.cs`

**Conclusion:** Batch capability appears split between a monitor executable and shared business service layer. *(Evidence: E03, E14)*

## 3.6 Stored procedure integration signals
- DataAccess entities include stored-procedure result types, e.g.:
  - `Shared.DataAccess\Entities\p_GetAllMessages_Result.cs`
  - `Shared.DataAccess\Entities\p_Labyrinth_GetUserLoginInfo_Result.cs`
  - `Shared.DataAccess\Entities\p_GetUsers_Result.cs`

**Conclusion:** DB access includes mapped stored-procedure result contracts in `Shared.DataAccess`. *(Evidence: E04, E16)*

---

## 4) Current Component Architecture Diagram (Phase 1)

```mermaid
flowchart LR
	UI[Nexxsys.Shell + Nexxsys.Modules.*] --> CORE[Shared.RxCore Services]
	CORE --> DA[Shared.DataAccess]
	DA --> DB[(SQL Server: Nexxsys DB)]

	CORE --> MODELS[Shared.Models]
	CORE --> INFRA[Shared.Infrastructure]
	CORE --> SEC[Shared.Security]

	EXT[PropelRxExtService\n(ServiceImplementations/*)] --> CORE
	EXT --> DA

	MON[CPS_Monitor\n(Program/frmMonitor/ProcUtil)] --> CORE

	WEB[PatientCenter.Web] --> CORE
	RPT[Nexxsys.Reports / PatientCenter.Reports] --> CORE
```

Diagram conclusions:
1. `Shared.RxCore` is the orchestration/business layer between UI/services and `Shared.DataAccess`. *(Evidence: E05-E07, E03)*
2. `PropelRxExtService` and `CPS_Monitor` are sidecar/background components tied into shared layers. *(Evidence: E13, E14, E03)*
3. SQL access convergence occurs in `Shared.DataAccess\DapperDbContext.cs`. *(Evidence: E08)*

---

## 5) Evidence Index

| ID | Exact evidence | Type |
|---|---|---|
| E01 | `get_projects_in_solution` returned 41 project paths including `Nexxsys.Shell`, `Shared.*`, `PropelRxExtService`, `CPS_Monitor`, `PatientCenter.Web` | Solution inventory |
| E02 | `Nexxsys.Shell` file list includes `BootStrapper.cs`, `App.xaml.cs`, `ShellViewModel.cs` | Shell structure |
| E03 | `Shared.RxCore` file list includes `Services\SharedService.cs`, `Services\BatchService.cs`, `Services\SendCommunication\MessageOutQueueService.cs` | Core services |
| E04 | `Shared.DataAccess` file list includes `DapperDbContext.cs`, `DBUtils.cs`, `Implementation\SharedDAO.cs`, many `Entities\*.cs` | Data access structure |
| E05 | Call stack source: `Shared.DataAccess\DapperDbContext.cs` lines 169-176, method `QueryFirstOrDefault<T>` calls `ExecuteOnNewConnection(...)` | Method dependency |
| E06 | Call stack source: `Shared.DataAccess\Implementation\SharedDAO.cs` lines 2764-2768, method `GetPreferenceValueByEntity(...)` runs `SELECT dbo.f_PreferenceRetrieve(...)` | DAO + DB function |
| E07 | Call stack source: `Shared.RxCore\Services\SharedService.cs` lines 1569-1572, method `GetPreferenceValueByEntity(...)` delegates to `SharedDAO` | Service->DAO |
| E08 | `Shared.DataAccess\DapperDbContext.cs` lines 557-636 method `ExecuteOnNewConnection<TResult>(...)` with SQL exception catch and rethrow | DB execution path |
| E09 | `Shared.DataAccess.DBUtils.IsDefaultUserException(Exception, string)` implementation (symbol output) | SQL auth classification |
| E10 | `Shared.DataAccess.DBUtils.RefreshDefaultUserCredentials(string)` implementation (symbol output) | Credential refresh path |
| E11 | `Shared.DataAccess.DBUtils.HandleAction<TResult>(string, Func<IDbConnection,TResult>)` implementation (symbol output) | Retry path |
| E12 | Runtime expression: `connectionString` value includes `User ID=ServiceAccount` and password token; SQL error number 18456 captured in `$exception.Number` | Runtime auth evidence |
| E13 | `PropelRxExtService` file list includes `Services\PropelRxExtService.cs` and `ServiceImplementations\MessageOutQueueProcess.cs` etc. | Messaging/background service inventory |
| E14 | `CPS_Monitor` file list includes `Program.cs`, `frmMonitor.cs`, `ProcUtil.cs` | Batch/monitor inventory |
| E15 | `Shared.Models` file list includes `SendCommunication\MessageOutQueue.cs` and many queue/workflow models | Messaging model layer |
| E16 | `Shared.DataAccess\Entities\p_*_Result.cs` files (e.g., `p_GetAllMessages_Result.cs`) | Stored-procedure mapping indicators |

---

## 6) Runtime Verification Register

1. **Verify actual startup orchestration of background processes** in:
   - `PropelRxExtService\Program.cs`
   - `PropelRxExtService\Services\PropelRxExtService.cs`
   - `CPS_Monitor\Program.cs`
   - `CPS_Monitor\ProcUtil.cs`

Status: **[RUNTIME VERIFICATION REQUIRED]** (source content not retrievable in current tool state).

2. **Verify effective runtime DB credentials per process** (Shell, ExtService, CPS_Monitor) and whether each uses shared default-service-account flow.

Status: **[RUNTIME VERIFICATION REQUIRED]**.

3. **Verify failure behavior under SQL auth outage** (retry, backoff, queue accumulation, alerting).

Status: **[RUNTIME VERIFICATION REQUIRED]**.

---

## 7) Phase 1 Recommendation: First Business Workflow to Investigate

### Recommended first workflow
**“Preference retrieval + default credential refresh workflow”**
- Entry method: `Shared.RxCore.Services.SharedService.GetPreferenceValueByEntity(...)`
- DAO method: `Shared.DataAccess.SharedDAO.GetPreferenceValueByEntity(...)`
- DB call: `SELECT dbo.f_PreferenceRetrieve(...)`
- DB execution/error handling: `Shared.DataAccess.DapperDbContext.ExecuteOnNewConnection(...)` + `DBUtils.IsDefaultUserException(...)` + `DBUtils.RefreshDefaultUserCredentials(...)`

### Why this should be first
1. It is a **confirmed runtime failure path** (not inferred) tied to SQL login failure `18456` for `ServiceAccount`. *(Evidence: E05-E12)*
2. It sits in **shared infrastructure** used by service/business layers, so instability here can cascade into UI, messaging, and batch behavior. *(Evidence: E03, E04, E05-E08, E13-E14)*
3. It directly touches both **business workflow state** (preferences) and **platform reliability** (credential refresh/retry strategy). *(Evidence: E06, E08-E11)*

---

## 8) Notes
- This document is intentionally Phase-1 only and architecture-baseline focused.
- No production artifacts were changed.