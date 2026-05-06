# S27 — Workflow↔Task Boundary ADR (ADR-023)

**Plan**: ../plan.md
**Story-ID**: S27

## Feature Overview and Goal

Formalise the behavioural contract between `dartclaw_workflow` and the task orchestrator as ADR-023, naming three commitments (workflows-compile-to-tasks, `TaskExecutor` workflow-aware routing, narrow direct-insert affordance into `TaskRepository`) as **intentional** rather than refactor targets.

**Status note**: per `plan.md` line 292, S27 is _Implemented (awaiting review + commit)_ — the ADR file already exists at private repo `docs/adrs/023-workflow-task-boundary.md` (Accepted — 2026-04-21) and the doc-review findings (`023-workflow-task-boundary-doc-review-codex-2026-04-21.md`) are addressed inline. This FIS retrospectively documents the contract; the execution path is **verification + commit**, not authoring from scratch.

> **Technical Research**: [.technical-research.md](../.technical-research.md) — see `## S27 — Workflow↔Task Boundary ADR (ADR-023)` and Shared Decision #15.

## Required Context

### From `dev/specs/0.16.5/plan.md` — "S27 Acceptance Criteria"
<!-- source: dev/specs/0.16.5/plan.md#p-s27-workflow-task-boundary-adr-adr-023 -->
<!-- extracted: 2026-05-04 -->
> - `docs/adrs/023-workflow-task-boundary.md` exists in private repo and follows the ADR template (Status / Context / Decision / Consequences / Alternatives / References) (must-be-TRUE)
> - ADR names all three commitments with concrete code-seam references (must-be-TRUE)
> - `foreach` wording distinguishes the zero-task controller from its child agent steps that do create tasks (must-be-TRUE)
> - Fitness-function reference resolves to the existing test at `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` (must-be-TRUE)
> - ADR-021, ADR-022, private repo `docs/architecture/workflow-architecture.md` §13, and S28 fitness test are cross-referenced (must-be-TRUE)
> - Status line reads "Accepted — 2026-04-21"

### From `dev/specs/0.16.5/plan.md` — "ADR-023 Inline Reference Summary"
<!-- source: dev/specs/0.16.5/plan.md#adr-023-workflow-task-architectural-boundary -->
<!-- extracted: 2026-05-04 -->
> Status: Accepted — 2026-04-21. Context: DartClaw runs two orchestration subsystems on the same runtime — the workflow engine in `dartclaw_workflow` and the task orchestrator in `dartclaw_server/src/task/*`. ADR-021 reshaped the data layer (extracting `AgentExecution`/`WorkflowStepExecution` so workflow state no longer round-trips through `Task.configJson`); ADR-022 introduced the portable `<step-outcome>` protocol so gate evaluation does not infer intent from task lifecycle state. ADR-023 names the **behavioural** contract those data-layer ADRs depend on. Decision: three commitments are intentional, not refactor targets.
>
> 1. **Workflows compile to tasks.** Every workflow agent step creates a `Task`; the workflow engine does not own a parallel execution stack for agent work. `bash` and `approval` are zero-task by design. The `foreach` controller is also host-executed and zero-task, but its child agent steps still compile to tasks.
> 2. **`TaskExecutor` is workflow-aware and routes deliberately.** `_isWorkflowOrchestrated(task)` and the `_executeWorkflowOneShotTask()` path (via `WorkflowCliRunner`) are intentional — workflow-orchestrated tasks execute as one-shot CLI invocations rather than via the interactive harness pool because a workflow step is a bounded prompt-chain, not a long-lived conversation.
> 3. **`dartclaw_workflow` may write to `TaskRepository` directly.** `TaskService.create()` is intentionally bypassed for the narrow purpose of atomically inserting the three-row chain (`Task` + `AgentExecution` + `WorkflowStepExecution`) in a single transaction (`workflow_executor.dart:2585-2589`, inside `executionTransactor.transaction()`). All reads and lifecycle transitions still go through the narrow `WorkflowTaskService` interface defined in `dartclaw_core`; the direct-insert affordance is scoped to creation and must not be widened.

## Deeper Context

- `dev/specs/0.16.5/.technical-research.md#15-workflow-context-marker--adr-023` — Shared Decision #15: workflow-context marker constants (`workflowContextTag`/`Open`/`Close` in `packages/dartclaw_workflow/lib/src/workflow/workflow_output_contract.dart`), and S27/S28 division of labour.
- `packages/dartclaw_workflow/CLAUDE.md` — package boundary rules; the host seam (`WorkflowGitPort` / `WorkflowTurnAdapter`) that ADR-023's commitment #2 protects.
- Private repo `docs/adrs/023-workflow-task-boundary-doc-review-codex-2026-04-21.md` — doc-review report; both findings (MEDIUM: `foreach` precision; LOW: fitness reference path) addressed inline before acceptance.

## Success Criteria (Must Be TRUE)

> Each criterion is a structural file/text check verifiable via the corresponding task **Verify** line.

- [ ] ADR file exists at private repo path `docs/adrs/023-workflow-task-boundary.md` and contains all six headed sections in template order: `## Status`, `## Context`, `## Decision`, `## Consequences`, `## Alternatives Considered`, `## References` (proven by TI01)
- [ ] Status line reads exactly `Accepted — 2026-04-21` (proven by TI01)
- [ ] Decision section names all three commitments and includes the concrete code-seam references — `_isWorkflowOrchestrated`, `_executeWorkflowOneShotTask` / `WorkflowCliRunner` (commitment #2), and the three-row `Task` + `AgentExecution` + `WorkflowStepExecution` atomic-insert (commitment #3) (proven by TI02)
- [ ] `foreach` wording explicitly distinguishes the zero-task controller from its child agent steps that **do** compile to tasks (proven by TI03)
- [ ] ADR `## References` section contains a resolvable link to `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` and that file exists in `dartclaw-public` (proven by TI04)
- [ ] ADR `## References` cross-links to ADR-021, ADR-022, and `docs/architecture/workflow-architecture.md` §13 (Relationship to Task Executor); §13 substance is captured by ADR-023 per the plan's "Architecture deep-dives (orientation only)" note (proven by TI05)
- [ ] ADR is committed to the private repo (post-review) with a commit message that records the doc-review closure (proven by TI06)

### Health Metrics (Must NOT Regress)
- [ ] Zero code changes in `dartclaw-public` — workspace-wide `dart analyze` and `dart test` remain green
- [ ] S28 fitness test (`workflow_task_boundary_test.dart`) — already shipping — continues to pass; this ADR is the documentation half of the contract S28 enforces

## Scenarios

### Reader understands the workflow↔task contract from ADR-023 alone
- **Given** a contributor unfamiliar with DartClaw opens `docs/adrs/023-workflow-task-boundary.md`
- **When** they read the Decision section end-to-end
- **Then** they can name (a) which workflow step types create tasks (every agent step) and which do not (`bash`, `approval`, and the `foreach` controller itself — but **not** its child agent steps), (b) why `TaskExecutor` has two execution paths, and (c) the exact transactional shape that justifies the direct-insert affordance into `TaskRepository`.

### New contributor checks ADR-023 before adding a cross-package import
- **Given** a contributor preparing to add `import 'package:dartclaw_server/...';` inside `packages/dartclaw_workflow/lib/src/`
- **When** they consult the project ADR set
- **Then** ADR-023 (linked from `## References` of ADR-021/022 and from `workflow-architecture.md` §13) tells them the boundary is load-bearing, points to the S28 fitness test that will fail their PR, and tells them how to resolve a legitimate need (extract an interface to `dartclaw_core`).

### Cross-document consistency: no contradictions with neighbouring ADRs or architecture docs
- **Given** a doc reviewer cross-reads ADR-021, ADR-022, ADR-023, and `workflow-architecture.md` §13
- **When** they look for contradictions in the workflow↔task model (commitments, data shape, status semantics)
- **Then** none surface — ADR-023 names behavioural commitments that are consistent with ADR-021's data-layer decomposition and ADR-022's step-outcome protocol; §13 substance is captured by ADR-023 (per `plan.md` "Architecture deep-dives" note).

### `foreach` precision is preserved (doc-review MEDIUM finding closure)
- **Given** the ADR text covering commitment #1 (workflows compile to tasks)
- **When** the reader looks for `foreach` wording
- **Then** the text states the controller itself is host-executed and zero-task **and** that its child agent steps do compile to tasks — both halves present, neither implied by omission.

## Scope & Boundaries

### In Scope
- Verification that the ADR file at private repo `docs/adrs/023-workflow-task-boundary.md` exists, follows the project ADR template, names the three commitments with code-seam references, has the corrected `foreach` wording and the corrected fitness-function path, and cross-references the surrounding artefacts (ADR-021, ADR-022, `workflow-architecture.md` §13, S28 fitness test).
- Commit (if not already committed) to the **private repo** only.

### What We're NOT Doing
- **Enforcement** — S28 owns the fitness test (`packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`) that mechanically guards the import boundary. ADR-023 is the *named contract*; S28 is the *enforcement*. Splitting these is intentional.
- **Re-litigating ADR substance** — the three commitments and their alternatives are settled and accepted (2026-04-21). This story does not re-open the decision, edit the alternatives section, or change the foreach/`TaskExecutor`/direct-insert framing.
- **Rewriting `workflow-architecture.md` §13** — per `plan.md` line 1033, §13's substance is *captured by* ADR-023; §13 stays as the orientation pointer, ADR-023 is the load-bearing artefact.
- **Updating any code-seam line numbers** — the ADR cites `workflow_executor.dart:2585-2589` as the historical location of the `executionTransactor.transaction()` call. The actual atomic-insert call has since moved to `workflow_task_factory.dart:98-102` as part of executor decomposition. Per ADR practice, the original line reference is retained as a snapshot of state at the time of acceptance; the ADR is not re-pinned each time downstream code moves. (Captured here so a future reader does not flag this as drift.)
- **Public-repo documentation changes** — ADR-023 lives in the private repo by design; the public-repo plan/spec/research already carry the inline summary needed for public readers.

### Agent Decision Authority
- **Autonomous**: verify the existing ADR file matches all six Success Criteria; commit if not yet committed; commit message wording.
- **Escalate**: any drift between ADR text and Success Criteria — if a criterion fails, do **not** silently rewrite the ADR; surface as a `BLOCKED:` so the team can decide (this is a doc with cross-repo implications).

## Architecture Decision

This FIS **is** the documentation half of an architecture decision that is itself an ADR. No further architectural choice required.

See ADR: private repo `docs/adrs/023-workflow-task-boundary.md` (Accepted — 2026-04-21).

## Technical Overview

No code changes. The verification work touches only the private repo's ADR file and confirms paths/references resolve.

### Integration Points

- **Private repo** ADR set: ADR-021, ADR-022, ADR-023 form a coherent trio (data → status protocol → behavioural boundary).
- **Public repo** S28 fitness test: ADR-023's References section links to the public-repo fitness test path; the path resolution is part of the verification (TI04).
- **Private repo** `docs/architecture/workflow-architecture.md` §13: the orientation document; cross-referenced by ADR-023.

## Code Patterns & External References

```
# type | path/url | why needed
file   | dartclaw-private/docs/adrs/023-workflow-task-boundary.md                                        | Subject of this FIS — verify all six sections present
file   | dartclaw-private/docs/adrs/023-workflow-task-boundary-doc-review-codex-2026-04-21.md            | Doc-review report whose two findings (MEDIUM, LOW) are addressed inline
file   | dartclaw-private/docs/adrs/021-agent-execution-primitive.md                                     | Cross-referenced from ADR-023 References
file   | dartclaw-private/docs/adrs/022-workflow-run-status-and-step-outcome-protocol.md                 | Cross-referenced from ADR-023 References
file   | dartclaw-private/docs/architecture/workflow-architecture.md                                     | §13 (Relationship to Task Executor) is captured by ADR-023
file   | dartclaw-public/packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart          | Fitness test; ADR-023 References must resolve to this path
```

## Constraints & Gotchas

- **Constraint**: ADR lives in the **private repo**. Public-repo readers reach the substance via the inline summary in `dev/specs/0.16.5/plan.md` "Inline Reference Summaries" appendix. The FIS itself cites Required Context inline so a public-repo executor has full context.
- **Avoid**: silently rewriting the ADR to match Success Criteria if a criterion fails — Instead: emit `BLOCKED:` and surface the gap. ADR substance is settled; verification should pass without edits.
- **Critical**: code-seam line numbers in an Accepted ADR are a snapshot, not a live binding. The historical `workflow_executor.dart:2585-2589` reference is correct as written; do **not** "fix" it to `workflow_task_factory.dart:98-102` even though the atomic-insert call has since moved — that reframing belongs in a future ADR addendum, not in S27 verification.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** ADR file exists at the canonical private-repo path with all six template sections in order and the exact Accepted-on-date.
  - Path: `dartclaw-private/docs/adrs/023-workflow-task-boundary.md`. Six required sections: `## Status`, `## Context`, `## Decision`, `## Consequences`, `## Alternatives Considered`, `## References`.
  - **Verify**: `test -f dartclaw-private/docs/adrs/023-workflow-task-boundary.md && rg -n "^## (Status|Context|Decision|Consequences|Alternatives Considered|References)$" dartclaw-private/docs/adrs/023-workflow-task-boundary.md | wc -l` returns `6`; `rg -n "^Accepted — 2026-04-21$" dartclaw-private/docs/adrs/023-workflow-task-boundary.md` returns one match.

- [ ] **TI02** Decision section names all three commitments with concrete code-seam references.
  - Expected anchors: `_isWorkflowOrchestrated`, `_executeWorkflowOneShotTask`, `WorkflowCliRunner` (commitment #2); `Task` + `AgentExecution` + `WorkflowStepExecution` three-row chain (commitment #3).
  - **Verify**: each of `rg -n "_isWorkflowOrchestrated"`, `rg -n "_executeWorkflowOneShotTask"`, `rg -n "WorkflowCliRunner"`, `rg -n "AgentExecution"`, `rg -n "WorkflowStepExecution"` against the ADR file returns ≥ 1 match.

- [ ] **TI03** `foreach` wording distinguishes the zero-task controller from its child agent steps.
  - The Decision-section paragraph for commitment #1 must contain both halves: the controller is zero-task **and** child agent steps do compile to tasks.
  - **Verify**: `rg -n "foreach" dartclaw-private/docs/adrs/023-workflow-task-boundary.md` returns at least one match in commitment #1, and the surrounding sentence(s) reference both "zero-task" (or equivalent — "host-executed") and "child" steps that "compile to tasks" (or equivalent). Manual read confirms both halves are present, neither implied by omission.

- [ ] **TI04** Fitness-function reference in the ADR resolves to the existing public-repo test file.
  - Expected reference target: `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` (relative to `dartclaw-public`).
  - **Verify**: `rg -n "workflow_task_boundary_test\.dart" dartclaw-private/docs/adrs/023-workflow-task-boundary.md` returns ≥ 1 match **and** `test -f dartclaw-public/packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` succeeds.

- [ ] **TI05** ADR References section cross-links ADR-021, ADR-022, and `workflow-architecture.md` §13.
  - Expected entries (any link form): `021-agent-execution-primitive.md`, `022-workflow-run-status-and-step-outcome-protocol.md`, `workflow-architecture.md`.
  - **Verify**: against the `## References` section, `rg -n "021-agent-execution-primitive\.md|022-workflow-run-status-and-step-outcome-protocol\.md|workflow-architecture\.md"` returns ≥ 3 matches (one per file).

- [ ] **TI06** ADR is committed to the private repo (no in-flight uncommitted work) with a commit message that closes the doc-review.
  - **Verify**: in the private repo, `git log --oneline -- docs/adrs/023-workflow-task-boundary.md` returns at least one commit; `git status -- docs/adrs/023-workflow-task-boundary.md` shows clean. If not yet committed, commit with a message that references the doc-review report (e.g. _"adr-023: accept workflow↔task boundary; close doc-review (foreach precision, fitness path)"_) and re-run the verify.

### Testing Strategy
- [TI01,TI02,TI03,TI05] Scenario "Reader understands the workflow↔task contract from ADR-023 alone" → manual read of Decision + verify-line greps prove the three commitments and their concrete code-seam references are present.
- [TI03] Scenario "`foreach` precision is preserved" → grep + manual read of commitment #1.
- [TI04] Scenario "New contributor checks ADR-023 before adding a cross-package import" → fitness-function reference resolves; reader can follow the link and run the test.
- [TI01,TI05] Scenario "Cross-document consistency" → References section cross-links ADR-021/022 and `workflow-architecture.md` §13; manual read across the four documents confirms no contradictions.
- [TI06] Standard git-state check — the work is committed to the private repo.

### Validation
- This is a docs-only retrospective verification. The standard exec-spec build/test/lint loop applies trivially (zero code touched in `dartclaw-public`); explicit additions:
- Run S28's fitness test to confirm the contract this ADR documents is still mechanically guarded: `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`. (Sanity check, not a regression gate for this story.)

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding.
- All `Verify` commands assume the working directory is the **workspace root** (the directory containing both `dartclaw-public/` and `dartclaw-private/`), so `dartclaw-public/...` and `dartclaw-private/...` paths resolve as written.
- If any Verify fails, do **not** rewrite the ADR text. Emit `BLOCKED:` with the specific gap and stop — ADR substance is settled, drift indicates a real cross-repo issue requiring human review.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] **All success criteria** met (verified via TI01–TI06)
- [ ] **All tasks** fully completed and checkboxes checked
- [ ] **No regressions** — zero code changes in `dartclaw-public`; `dart analyze`/`dart test` unchanged
- [ ] **S28 fitness test** still passes (sanity check that the contract this ADR documents is mechanically guarded)

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: Formalises the behavioural contract between `dartclaw_workflow` and the task orchestrator. Builds on ADR-021 (AgentExecution primitive) and ADR-022 (workflow run status + step outcome protocol), which defined the data-layer decomposition. ADR-023 names three behavioural commitments as intentional: (1) workflows compile to tasks (every agent step creates a `Task`; `bash` and `approval` are zero-task; `foreach` is a zero-task controller whose child agent steps do create tasks); (2) `TaskExecutor._isWorkflowOrchestrated` branching deliberately routes to `WorkflowCliRunner` one-shot execution instead of the interactive harness-pool path; (3) `dartclaw_workflow` writes to `TaskRepository` directly inside `executionTransactor.transaction()` (`workflow_executor.dart:2585-2589`) to atomically insert the three-row `Task` + `AgentExecution` + `WorkflowStepExecution` chain. Lives at private repo `docs/adrs/023-workflow-task-boundary.md`. Doc review report at private repo `docs/adrs/023-workflow-task-boundary-doc-review-codex-2026-04-21.md` — both findings (MEDIUM: foreach precision; LOW: fitness reference path) addressed inline.

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [ ] `docs/adrs/023-workflow-task-boundary.md` exists in private repo and follows the ADR template (Status / Context / Decision / Consequences / Alternatives / References) (must-be-TRUE)
- [ ] ADR names all three commitments with concrete code-seam references (must-be-TRUE)
- [ ] `foreach` wording distinguishes the zero-task controller from its child agent steps that do create tasks (must-be-TRUE)
- [ ] Fitness-function reference resolves to the existing test at `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` (must-be-TRUE)
- [ ] ADR-021, ADR-022, private repo `docs/architecture/workflow-architecture.md` §13, and S28 fitness test are cross-referenced (must-be-TRUE)
- [ ] Status line reads "Accepted — 2026-04-21"
