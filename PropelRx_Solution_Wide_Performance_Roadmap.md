# PropelRx Solution-Wide Performance Roadmap

## Executive Summary (one page)

This roadmap is assessment-only and sized for two developers at ~1.1–1.2 effective FTE. It preserves patient safety, claim/reversal/rebill correctness, and strict sequential execution for related claims. The plan is cumulative: 0–2 months establishes telemetry and fixes confirmed defects; 2–6 months removes measured hotspots and implements queue-safety controls; 6–12 months contains conditional architectural work only if earlier evidence and business approvals justify it.

Evidence status:
- **Measured bottlenecks:** not yet established in this source-only pass.
- **Code-proven defects/risks:** outbound queue defects (`D-001..D-003`), non-atomic queue claim pattern, stale in-process risk, queue chattiness, RxDetail UI waits/loading breadth, and ProcessNewRx partial-success retry risk.
- **Runtime-verify decisions:** canonical claim sequencing key across all legacy/rebill paths.

Guardrails:
- No intra-key claim parallelization.
- No new path that can bypass existing sequencing boundary.
- No logging of patient/prescription/claim identifiers (or hashes); telemetry uses random workflow correlation IDs and aggregate counts/timings/statuses.
- Atomic queue claiming is mandatory before increasing concurrent worker instances.

---

## 0–2 Months Horizon (cumulative)

| ID | Issue | Evidence and current impact | Why this horizon? | What should change? | How will it be done? | Effort and dependencies | Business/claim-ordering risk | How success will be measured |
|---|---|---|---|---|---|---|---|---|
| D-001 | Outbound worker reports success on failure path | [CODE-PROVEN] `Shared.RxCore/Services/SendCommunication/MessageOutQueueService.cs:66-158`. Current impact: reliability defect; false-success signaling possible. | Confirmed defect with local blast radius; fast fix suitable for immediate cycle. | Worker return/status behavior must represent actual send outcome. | **Test-first gate**: reproduce failing path; add unit/integration assertions; implement fix; canary rollout; rollback via revert branch. | 2 dev-days; QA test slot; release window. | Medium reliability risk if unfixed; low claim-ordering risk. | Baseline: failing-path test currently reproduces incorrect success. Target: tests pass and canary shows zero false-success events for this path. |
| D-002 | Diem success-list mapping gap in mixed outcomes | [CODE-PROVEN] `MessageOutQueueService.cs:935-977`. Current impact: result-state inconsistency under mixed send outcomes. | Confirmed defect; should be corrected before broader queue changes. | Success and failure persistence must be deterministic for mixed outcomes. | **Test-first gate**: mixed success/failure fixture; implement mapping correction; integration test; staged rollout; rollback by feature branch revert. | 2 dev-days; QA; vendor stub/test endpoint. | Medium reliability/audit risk; low claim-ordering risk. | Baseline: mixed-outcome test reproduces mismatch. Target: deterministic persisted results in tests and canary reconciliation. |
| D-003 | Unsafe `First(...)` lookup with ineffective null check | [CODE-PROVEN] `MessageOutQueueService.cs:811-816`, `:887-892`. Current impact: avoidable exception path. | Small confirmed defect; low effort and immediate stability value. | Missing-interface path must not throw avoidable exceptions. | **Test-first gate**: missing-data test case; safe selection fix; regression test; canary monitoring; rollback by revert. | 1 dev-day; QA. | Low-medium reliability risk; no direct claim-ordering risk. | Baseline: test reproduces exception path. Target: no throw in test and no recurrence in canary logs for that condition. |
| O-001 | Missing unified telemetry baseline for queue/workflow timing | [RUNTIME-VERIFY] No runtime baseline exists in repo; prior reports request metrics. | Required prerequisite for all medium/large changes and prioritization. | Establish production-safe telemetry baseline using random workflow correlation IDs and aggregates only. | Define telemetry contract; instrument queue/workflow timings and status transitions; deploy behind switches; validate retention/privacy; rollback by disabling switches. | 8–10 dev-days; Ops/Security logging approval; QA validation. | Low direct business risk; high decision-quality risk if delayed. | Baseline deliverable: first 2-week metric capture (queue lag/stale age, status counts, workflow timings). Target: baseline published and used in go/no-go gates. |
| Q-001 | Non-atomic queue claiming safety gap (design and proof phase) | [CODE-PROVEN] select/claim split pattern in `MessageOutQueueService.cs:76-130`; queue status updates in `Shared.DataAccess/Implementation/RxDetailDAO.cs:2236-2239`. Impact not yet measured in prod. | Mandatory safety precondition for worker scale-out; design must start now even if full rollout completes later. | Define atomic/conditional claim behavior and acceptance tests; do not increase worker concurrency until control is live. | Capture overlap/stale baseline; design SQL/DAO claim transition; add concurrency tests; pilot on one queue path; rollback to current claim mode if parity fails. | 5–7 dev-days in this horizon; DBA + QA + Ops. | High reliability risk under concurrency; moderate claim-ordering adjacency risk. | Baseline: overlap/stale metrics established. Target: approved design + passing concurrency tests + pilot readiness decision. |

---

## 2–6 Months Horizon (cumulative)

| ID | Issue | Evidence and current impact | Why this horizon? | What should change? | How will it be done? | Effort and dependencies | Business/claim-ordering risk | How success will be measured |
|---|---|---|---|---|---|---|---|---|
| Q-002 | Non-atomic claim implementation and stale in-process (`I`) recovery | [CODE-PROVEN]/[RUNTIME-VERIFY] queue claim split in `MessageOutQueueService.cs:76-130`; stale/lag concern in prior assessments. | Depends on 0–2 month baseline and DBA design; moderate change and rollout risk. | Queue claiming must be atomic/conditional, with explicit stale-`I` recovery policy. | Implement claim transition in DB/DAO path; add integration + race tests; canary with alerting; rollback to prior mode + scripts. | 10–15 dev-days; DBA design/review; QA concurrency tests; Ops canary support. | High reliability risk if incorrect; must preserve ordering and processing correctness. | Baseline: overlap/stale counts from month 2. Target: post-change overlap/stale metrics trend down without new processing errors. |
| Q-003 | Queue DB chattiness under loop processing | [CODE-PROVEN] loop-driven call pattern `MessageOutQueueService.cs:85-155`; impact not yet measured. | Needs baseline call cardinalities first; moderate refactor scope. | Reduce redundant per-item DB operations while preserving behavior. | Profile per-cycle DB calls; remove redundant calls and batch safe operations incrementally; regression tests; staged rollout; rollback by toggling batch path. | 8–12 dev-days; DBA query review; QA regression. | Medium reliability risk; low claim-ordering risk if queue semantics unchanged. | Baseline: calls/queue-item and p95 loop duration. Target: measurable reduction in calls and loop duration with no behavior regressions. |
| R-001 | RxDetail blocking waits (`WaitWithPumping`) on hot path | [CODE-PROVEN] `Nexxsys.Modules.RxDetail/ViewModels/RxDetailViewModel.cs:3192-3199`; helper `Shared.Infrastructure.UI/AsyncHelpers.cs:48-59`. Impact not yet measured. | Requires baseline user-path timings and careful parity checks; moderate UX/regression risk. | High-frequency UI paths should avoid blocking waits and reduce re-entrancy risk. | Identify highest-frequency path first; refactor to non-blocking flow incrementally; add UI regression tests; staged rollout; rollback via feature flag/path switch. | 10–14 dev-days; QA workflow parity testing. | Medium prescription-workflow risk if behavior changes; no direct claim-ordering change. | Baseline: first-render/interaction timing and re-entry incidents. Target: improved timing trend with no new workflow regressions. |
| R-002 | RxDetail broad hydration and lock/load fan-out | [CODE-PROVEN]/[RUNTIME-VERIFY] `RxDetailDAO.cs:31-107`, `:251`; `RxDetailViewModel.cs:3202-3235`; service usage in `RxDetailService.cs:61-96`. | Requires telemetry-backed hotspot ranking and parity test corpus. | Load only needed data for first render and reduce repeated lock/load fan-out. | Prioritize top-cost hydration branch; narrow initial payload; defer non-critical sections; verify parity; rollback by restoring prior load scope. | 10–15 dev-days; QA parity; DBA Query Store support. | Medium risk to prescription visibility if scope trimmed incorrectly; no claim ordering change. | Baseline: `p_GetPrescription_MultiRS` p50/p95/p99 + calls/open. Target: measurable reduction in first-render latency and calls/open with parity preserved. |
| P-001 | ProcessNewRx partial-success + retry amplification | [CODE-PROVEN]/[RUNTIME-VERIFY] `Nexxsys.Modules.RxDetail/ViewModels/ProcessNewRxViewModel.cs:1764-1821`; impact magnitude unmeasured. | Requires month-2 telemetry and Product/CareRx acceptance criteria. | Retry behavior should avoid duplicate side effects and provide explicit partial-success outcome handling. | Measure duplicate artifact patterns; implement idempotency/guard checks for chosen path; add scenario tests; controlled rollout; rollback via feature toggle. | 8–12 dev-days; Product/CareRx decision; QA scenario harness. | High prescription/audit risk if mishandled; indirect claim-ordering risk through downstream retries. | Baseline: partial-success and retry duplicate artifact rates. Target: downward trend with no new correctness regressions. |

---

## 6–12 Months Horizon (cumulative, conditional)

| ID | Issue | Evidence and current impact | Why this horizon? | What should change? | How will it be done? | Effort and dependencies | Business/claim-ordering risk | How success will be measured |
|---|---|---|---|---|---|---|---|---|
| A-001 | Shared sequencing boundary hardening across all claim producers | [CODE-PROVEN]/[RUNTIME-VERIFY] sequencing mechanics in `CPS_Library/Claim/Coordinator.cs:157-170`, `:471-479`, `:552-592`; queue keying in `RxDetailDAO.cs:2146-2156`, `:2209-2223`; unresolved universal key decision. | Cross-cutting and safety-critical; only after 6-month parity corpus and business key decision. | All claim/reversal/rebill/trace entry points must enforce one approved sequencing policy with no bypass. | Build producer inventory; add parity harness (regular/reversal/NMS/trace/rebill); implement boundary checks incrementally; canary by producer; rollback by disabling new boundary enforcement. | 4–8 dev-weeks (staged); QA + Product/CareRx + Pharmacy SMEs + Ops. | Very high claim-ordering and regulatory risk if incorrect. | Baseline: parity pass rate and bypass count before hardening. Target: 100% parity pass and zero approved-path bypass in monitored flows. |
| A-002 | Workflow reliability pattern for retries/side effects (journal/outbox where justified) | [RUNTIME-VERIFY] only justified if duplicate/replay issues remain after 2–6 month controls. | Architectural and optional; schedule only if evidence shows residual reliability gap. | Ensure retry-safe side effects with durable, ordered processing where needed. | Apply pattern to one bounded workflow first; integration tests for replay/idempotency; canary; rollback by reverting bounded workflow path. | 3–6 dev-weeks for bounded pilot; DBA + QA + Ops + Product. | Medium-high consistency/audit risk if implemented broadly without proof. | Baseline: residual duplicate/replay incidents after 6-month work. Target: incident trend reduction on piloted boundary with parity maintained. |
| A-003 | Integration-specific worker isolation (not scale-out by default) | [RUNTIME-VERIFY] depends on measured noisy-neighbor contention after queue safety controls. | Operational/architectural change; only if contention persists. | Isolate problematic integration workloads without breaking sequencing guarantees. | Partition one proven-problem integration path; enforce sequence-safe routing; operational runbooks; rollback by routing back to unified worker path. | 2–4 dev-weeks; Ops + QA + vendor coordination. | Medium risk if routing breaks sequence assumptions. | Baseline: per-integration latency/error/timeout before isolation. Target: improved stability on isolated path with unchanged ordering outcomes. |

---

## Unscheduled—decision or evidence required

| ID | Issue | Evidence and current impact | Why this horizon? | What should change? | How will it be done? | Effort and dependencies | Business/claim-ordering risk | How success will be measured |
|---|---|---|---|---|---|---|---|---|
| U-001 | Canonical claim sequencing key decision (including rebill semantics) | [CODE-PROVEN] queue/coordinator sequence mechanics exist; [RUNTIME-VERIFY] universal key across all legacy/rebill paths is not fully provable from source alone. Evidence: `PrescriptionService.cs:9955-9965`, `:10017-10035`; `Coordinator.cs:157-170`, `:471-479`, `:552-592`; `ProcUtil.cs:998-1095`, `:1513-1528`. | Cannot be safely scheduled into implementation horizon until CareRx policy decision is explicit. | Approve canonical sequencing policy and permitted exceptions, including trace-number reversal and rebill linkage. | CareRx/Product/Pharmacy SME decision workshop; convert decision to executable acceptance tests and parity gates. | 1–2 workshops + test-definition effort; CareRx/Product/QA/SMEs required. | Very high claim-ordering/patient-safety/regulatory risk if undefined. | Baseline: policy unresolved. Scheduling trigger: signed decision and testable acceptance criteria. |
| U-002 | Worker concurrency increase beyond current level | Atomic claim is not yet fully implemented in production-safe form. | Explicitly blocked by safety rule. | Do not increase worker count until atomic claim and stale recovery controls are live and validated. | Complete Q-001/Q-002 and canary evidence before any scale-out request. | Depends on DBA/Ops/QA and successful Q-002 rollout. | High duplicate-processing and ordering-adjacent risk if done early. | Scheduling trigger: atomic claim live + stable post-release metrics for overlap/stale and correctness. |

---

## 1) Top three actions Team should authorize now

1. Authorize **test-first defect remediation** for `D-001..D-003` with canary/rollback gates.
2. Authorize **telemetry baseline implementation** (random workflow correlation IDs; aggregate-only metrics; privacy-reviewed schema).
3. Authorize **atomic queue claim design and pilot preparation** as a mandatory precondition to any worker concurrency increase.

## 2) Decisions or access Team must provide

- DBA/Ops access to Query Store, XE, wait/deadlock telemetry, and safe release windows.
- Ops/Security approval of telemetry schema and retention.
- Product/CareRx decision for ProcessNewRx partial-success expectations.
- CareRx decision on canonical claim sequencing policy and rebill semantics.
- QA capacity for concurrency, parity, and rollback validation.

## 3) Deliverables at end of months 2, 6, and 12

- **End of month 2:** defect fixes `D-001..D-003` released (or explicitly held), telemetry baseline published, atomic-claim design with test results and go/no-go decision.
- **End of month 6:** atomic claim + stale recovery implemented (if gates pass), prioritized queue/RxDetail/ProcessNewRx improvements delivered with measured before/after comparisons.
- **End of month 12:** only conditional architectural pilots completed where 6-month evidence and business gates were satisfied; otherwise deferred with documented rationale.

## 4) Conditional vs committed changes

- **Committed now:** `D-001..D-003`, telemetry baseline, atomic-claim design/test gates.
- **Conditional (measurement-gated):** queue chattiness reductions, RxDetail payload/wait refactors, ProcessNewRx retry controls.
- **Conditional (decision + evidence gated, 6–12 month):** shared sequencing boundary hardening, reliability patterns (journal/outbox), integration worker isolation.

## 5) Major approaches that should not be pursued (and why)

- Increase worker concurrency before atomic claim controls: unsafe duplicate/stale processing risk.
- Parallelize claims within same sequencing domain: claim-ordering and patient-safety risk.
- Big-bang architecture rewrite (full DAO-to-API/microservices split): exceeds two-developer capacity and increases regression exposure.
- CQRS read-model replication as default: no current evidence it is required; adds consistency complexity.
- Logging patient/prescription/claim identifiers or hashed identifiers: privacy/compliance violation.

---

## Appendix A: Evidence index (detailed traces and diagrams)

- `Shared.RxCore/Services/SendCommunication/MessageOutQueueService.cs:66-158`, `:76-130`, `:811-816`, `:887-892`, `:935-977`
- `Nexxsys.Modules.RxDetail/ViewModels/RxDetailViewModel.cs:3192-3235`
- `Nexxsys.Modules.RxDetail/ViewModels/ProcessNewRxViewModel.cs:1764-1821`
- `Shared.Infrastructure.UI/AsyncHelpers.cs:48-59`
- `Shared.DataAccess/Implementation/RxDetailDAO.cs:31-107`, `:251`, `:2146-2156`, `:2209-2239`
- `Shared.RxCore/Services/PrescriptionService.cs:9729-9782`, `:9955-9965`, `:10017-10035`
- `CPS_Library/Claim/Coordinator.cs:157-170`, `:471-479`, `:552-592`
- `CPS_Library/Data/ProcUtil.cs:104-107`, `:743-767`, `:998-1095`, `:1513-1528`
