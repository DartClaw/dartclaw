# S02 — canvas_exports Advisor Re-export Cleanup

**Plan**: ../plan.md
**Story-ID**: S02

## Feature Overview and Goal

Delete the 14-line advisor re-export block from `packages/dartclaw_server/lib/src/canvas/canvas_exports.dart` and route `AdvisorSubscriber` through a dedicated `advisor_exports.dart` sub-barrel so the canvas barrel only carries canvas concerns. Closes H-1 (11 orphan re-exports cluttering the canvas surface).

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S02 — canvas_exports Advisor Re-export Cleanup" entry in File Map; Project Context §3 Boundaries; Binding Constraint #12)_


## Required Context

### From `../plan.md` — "S02: canvas_exports Advisor Re-export Cleanup"
<!-- source: ../plan.md#s02-canvas_exports-advisor-re-export-cleanup -->
<!-- extracted: e670c47 -->
> **Scope**: Delete the advisor re-export block at `packages/dartclaw_server/lib/src/canvas/canvas_exports.dart:1-14`. Update `service_wiring.dart` to direct-import `AdvisorSubscriber` from `src/advisor/advisor_subscriber.dart`. Remove the 10 orphan re-exports (`AdvisorOutput`, `AdvisorStatus`, `AdvisorTriggerContext`, `AdvisorTriggerType`, `CircuitBreaker`, `ContextEntry`, `SlidingContextWindow`, `TriggerEvaluator`, `AdvisorOutputParser`, `AdvisorOutputRouter`, `renderAdvisorInsightCard`). Verify no downstream consumer breaks via `dart analyze`.
>
> **Acceptance Criteria**:
> - [ ] `canvas_exports.dart` advisor re-export block is removed
> - [ ] `service_wiring.dart` still imports and wires `AdvisorSubscriber` correctly
> - [ ] `dart analyze` workspace-wide is clean
> - [ ] No test failures in advisor-related suites

### From `../prd.md` — "FR2: Barrel & Public-API Discipline"
<!-- source: ../prd.md#fr2-barrel--public-api-discipline -->
<!-- extracted: e670c47 -->
> **Description**: Every `export 'src/...'` in a package barrel uses a `show` clause. Known over-exported types (canvas advisor re-exports, channel-package typedefs) are demoted.
>
> **Acceptance Criteria**:
> - [ ] `canvas_exports.dart` advisor re-export block deleted; `AdvisorSubscriber` direct-imported by `service_wiring.dart`

### Plan-clarification note (real consumer is the CLI service_wiring)
<!-- source: codebase grep, current branch feat/0.16.5 -->
<!-- extracted: e670c47 -->
> The only `service_wiring.dart` that wires `AdvisorSubscriber` is `apps/dartclaw_cli/lib/src/commands/service_wiring.dart:352,845`. It already imports the umbrella `package:dartclaw_server/dartclaw_server.dart`, which transitively re-exports `canvas_exports.dart`. There is no `service_wiring.dart` under `packages/dartclaw_server/lib/src/`. CLI cannot import `package:dartclaw_server/src/...` (forbidden by Dart `src/` privacy convention) — so a new `advisor_exports.dart` sub-barrel is the structurally correct seam.


## Deeper Context

- `../.technical-research.md#s02--canvas_exports-advisor-re-export-cleanup` — File Map for this story
- `../.technical-research.md#multi-story-touch-points` — `advisor_subscriber.dart` is also touched by S05 (event wiring reference) and S37 (dartdoc sweep); keep this change small
- `../prd.md#fr2-barrel--public-api-discipline` — full FR2 contract, fitness function context
- `packages/dartclaw_server/CLAUDE.md` — package conventions; "the `dartclaw_server.dart` barrel is large but ceiling-checked (≤80 exports) — prefer adding sub-barrels (`*_exports.dart`)"


## Success Criteria (Must Be TRUE)

- [ ] Lines 1–14 of `packages/dartclaw_server/lib/src/canvas/canvas_exports.dart` (the advisor re-export block) are deleted; the file only re-exports canvas-domain symbols.
- [ ] `AdvisorSubscriber` is publicly reachable from `package:dartclaw_server/dartclaw_server.dart` via a dedicated `src/advisor/advisor_exports.dart` sub-barrel (added to the umbrella alongside the existing `*_exports.dart` rows).
- [ ] The 10 non-`AdvisorSubscriber` symbols (`AdvisorOutput`, `AdvisorStatus`, `AdvisorTriggerContext`, `AdvisorTriggerType`, `CircuitBreaker`, `ContextEntry`, `SlidingContextWindow`, `TriggerEvaluator`, `AdvisorOutputParser`, `AdvisorOutputRouter`, `renderAdvisorInsightCard`) are NOT re-exported from any barrel — `rg "show.*AdvisorOutput|show.*CircuitBreaker|show.*renderAdvisorInsightCard" packages/` returns empty.
- [ ] `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` continues to construct and dispose `AdvisorSubscriber` without source changes (umbrella import still resolves the symbol).
- [ ] `dart analyze` is clean across the workspace (`--fatal-warnings --fatal-infos`).

### Health Metrics (Must NOT Regress)
- [ ] Existing advisor test suites (`packages/dartclaw_server/test/advisor/`) pass unchanged.
- [ ] `package:dartclaw_server/dartclaw_server.dart` umbrella still observes its ≤80-export ceiling (per `dartclaw_server/CLAUDE.md`).
- [ ] No other re-exports in `canvas_exports.dart` are touched (canvas-domain re-exports stay intact).


## Scenarios

### Removal happy path — public API of `AdvisorSubscriber` preserved
- **Given** `canvas_exports.dart`'s advisor block (lines 1–14) is deleted and `src/advisor/advisor_exports.dart` (re-exporting `AdvisorSubscriber` only) is added to the umbrella
- **When** the workspace is analyzed (`dart analyze`)
- **Then** analysis is clean, `apps/dartclaw_cli/lib/src/commands/service_wiring.dart:352,845` still resolves `AdvisorSubscriber`, and the advisor test suite passes

### Orphan symbols are no longer reachable
- **Given** the advisor re-export block has been removed
- **When** `rg "AdvisorOutput\b|AdvisorStatus\b|AdvisorTriggerContext\b|AdvisorTriggerType\b|CircuitBreaker\b|ContextEntry\b|SlidingContextWindow\b|TriggerEvaluator\b|AdvisorOutputParser\b|AdvisorOutputRouter\b|renderAdvisorInsightCard\b" packages/dartclaw_server/lib/dartclaw_server.dart packages/dartclaw_server/lib/src/canvas/canvas_exports.dart packages/dartclaw_server/lib/src/advisor/advisor_exports.dart` is run
- **Then** no matches are returned (these symbols are private to `src/advisor/` and not re-exported)

### Canvas re-exports remain intact (regression guard)
- **Given** lines 15–22 of `canvas_exports.dart` (canvas-domain re-exports: `canvasAdminRoutes`, `canvasRoutes`, `CanvasService`, `canvasShareMiddleware`, `CanvasPermission`, `CanvasShareToken`, `CanvasState`, `CanvasTool`, `generateQrSvg`, `WorkshopCanvasSubscriber`)
- **When** the cleanup is applied
- **Then** every canvas-domain symbol remains exported from `canvas_exports.dart` and reachable through the umbrella; `rg "canvasRoutes\|CanvasService\|generateQrSvg" packages/dartclaw_server/lib/dartclaw_server.dart` (transitively) still resolves

### Downstream import-via-canvas regression
- **Given** a hypothetical downstream file imports `AdvisorSubscriber` directly via `package:dartclaw_server/src/canvas/canvas_exports.dart` (or a stale local import)
- **When** the cleanup is applied and analyze runs
- **Then** the analyzer flags an unresolved symbol; the fix is to switch the import to `package:dartclaw_server/dartclaw_server.dart` (now the only public seam for `AdvisorSubscriber`)


## Scope & Boundaries

### In Scope
- Deletion of `canvas_exports.dart` lines 1–14 (the advisor re-export block).
- Addition of `packages/dartclaw_server/lib/src/advisor/advisor_exports.dart` sub-barrel exporting `AdvisorSubscriber` only (the sole legitimate consumer-facing symbol; the other 10 stay package-private).
- Single-line addition to `packages/dartclaw_server/lib/dartclaw_server.dart` umbrella to mount the new sub-barrel.
- Workspace-wide `dart analyze` verification + advisor test suite run.

### What We're NOT Doing
- Refactoring `advisor_subscriber.dart` itself (touched by S05 and S37; keep diff minimal here) -- preserves merge surface for parallel stories.
- Changing the other re-exports in `canvas_exports.dart` (lines 15–22 are legitimate canvas concerns) -- out of scope per H-1.
- Re-exporting `AdvisorOutput`, `CircuitBreaker`, etc. through the new sub-barrel -- they are internal advisor implementation; H-1 confirms zero external consumers.
- Editing `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` source (the umbrella import already resolves `AdvisorSubscriber` after the sub-barrel is added) -- avoids speculative churn that the plan's literal "direct-import from src/advisor/advisor_subscriber.dart" would require, which is forbidden by Dart's cross-package `src/` privacy convention.
- Touching the umbrella's other `*_exports.dart` rows -- diff stays surgical.

### Agent Decision Authority
- **Autonomous**: choosing the sub-barrel filename (`advisor_exports.dart` matches the existing convention) and which symbols it exports (`AdvisorSubscriber` only).
- **Escalate**: any analyzer error that cannot be resolved by adding `AdvisorSubscriber` to a sub-barrel — e.g., if a downstream consumer outside the workspace's two repos depends on one of the 10 orphan symbols.


## Architecture Decision

**We will**: route `AdvisorSubscriber` through a new `packages/dartclaw_server/lib/src/advisor/advisor_exports.dart` sub-barrel mounted on the `dartclaw_server.dart` umbrella, then delete the 14-line advisor re-export block from `canvas_exports.dart`.

**Rationale**: H-1 confirms the 11 advisor re-exports have zero downstream consumers — they only clutter the canvas barrel and conflate domains. The package convention (per `dartclaw_server/CLAUDE.md`) is per-subsystem `*_exports.dart` sub-barrels, so `AdvisorSubscriber` deserves its own home. The plan's phrasing "direct-import `AdvisorSubscriber` from `src/advisor/advisor_subscriber.dart`" is structurally infeasible across the package boundary (Dart forbids cross-package `src/` imports); a domain-correct sub-barrel achieves the same FR2 outcome (canvas barrel only carries canvas concerns) without violating package privacy.

**Alternatives considered**:
1. **Add `export 'src/advisor/advisor_subscriber.dart' show AdvisorSubscriber;` directly to the `dartclaw_server.dart` umbrella** — rejected: violates the package's "prefer sub-barrels over umbrella accretion" convention.
2. **Leave `AdvisorSubscriber` as a `canvas_exports.dart` re-export, drop only the other 10** — rejected: still conflates advisor with canvas; the FR2 goal is domain separation.


## Technical Overview

### Integration Points
- `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` is the only call site (lines 352, 845, 933) — already imports the umbrella; no source change required after the sub-barrel lands.
- `packages/dartclaw_server/lib/dartclaw_server.dart` is the consumer-facing umbrella; one new `export 'src/advisor/advisor_exports.dart';` line slots in alphabetically between `audit_exports.dart` and `canvas_exports.dart` (keeping the ordering convention visible in lines 15–35 of the umbrella).


## Code Patterns & External References

```
# type | path/url                                                                       | why needed
file   | packages/dartclaw_server/lib/src/canvas/canvas_exports.dart:1-14               | Block to delete (the 11 advisor re-exports)
file   | packages/dartclaw_server/lib/src/canvas/canvas_exports.dart:15-22              | Canvas re-exports that MUST stay intact
file   | packages/dartclaw_server/lib/dartclaw_server.dart:15-35                        | Sub-barrel mount-point convention; insert advisor row alphabetically
file   | packages/dartclaw_server/lib/src/alerts/alerts_exports.dart                    | Reference shape for a per-subsystem sub-barrel
file   | packages/dartclaw_server/lib/src/advisor/advisor_subscriber.dart:475,500       | `AdvisorSubscriber` declaration (target of the new sub-barrel show clause)
file   | apps/dartclaw_cli/lib/src/commands/service_wiring.dart:352,845,933             | Sole consumer of `AdvisorSubscriber`; verify no source change needed
```


## Constraints & Gotchas

- **Constraint**: Dart forbids cross-package imports of `package:foo/src/...`. The plan's literal "direct-import from `src/advisor/advisor_subscriber.dart`" can only be satisfied within the server package itself; the actual CLI consumer must go through a public barrel — Workaround: add the `advisor_exports.dart` sub-barrel and mount it on the umbrella.
- **Avoid**: re-exporting any of the 10 orphan symbols from the new sub-barrel "just in case" — Instead: export `AdvisorSubscriber` only; the orphans are H-1-confirmed unused and re-adding them re-creates the surface clutter this story removes.
- **Avoid**: touching the canvas-domain re-exports (lines 15–22) — Instead: surgical 14-line deletion only.
- **Critical**: keep umbrella export order alphabetical to match the existing convention in `dartclaw_server.dart:15-35`.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** New file `packages/dartclaw_server/lib/src/advisor/advisor_exports.dart` exists, exporting `AdvisorSubscriber` only via a `show` clause.
  - Mirror the shape of `lib/src/alerts/alerts_exports.dart`. Single line: `export 'advisor_subscriber.dart' show AdvisorSubscriber;`. No other symbols.
  - **Verify**: `rg "^export" packages/dartclaw_server/lib/src/advisor/advisor_exports.dart` shows exactly one line containing `AdvisorSubscriber` and no other symbol names.

- [ ] **TI02** Umbrella `packages/dartclaw_server/lib/dartclaw_server.dart` re-exports the new sub-barrel.
  - Insert `export 'src/advisor/advisor_exports.dart';` alphabetically (between `src/alerts/alerts_exports.dart` and `src/audit/audit_exports.dart`). Preserve surrounding ordering.
  - **Verify**: `grep -n "advisor_exports" packages/dartclaw_server/lib/dartclaw_server.dart` returns one match; `dart analyze packages/dartclaw_server` is clean.

- [ ] **TI03** Advisor re-export block removed from `packages/dartclaw_server/lib/src/canvas/canvas_exports.dart`.
  - Delete lines 1–14 (the entire `export '../advisor/advisor_subscriber.dart' show ... ;` block). Lines 15–22 (canvas-domain re-exports) remain unchanged. Resulting file starts with `export 'canvas_admin_routes.dart' show canvasAdminRoutes;`.
  - **Verify**: `head -1 packages/dartclaw_server/lib/src/canvas/canvas_exports.dart` shows `export 'canvas_admin_routes.dart' show canvasAdminRoutes;`; `rg "advisor_subscriber|AdvisorSubscriber|AdvisorOutput|CircuitBreaker|renderAdvisorInsightCard" packages/dartclaw_server/lib/src/canvas/canvas_exports.dart` returns empty.

- [ ] **TI04** No CLI consumer source change is needed — `service_wiring.dart` resolves `AdvisorSubscriber` through the umbrella.
  - This task is a verify-only checkpoint (no edit). If `dart analyze apps/dartclaw_cli` flags `AdvisorSubscriber` as unresolved, TI01/TI02 are wrong — fix there, do not patch the CLI to import a sub-barrel directly.
  - **Verify**: `dart analyze apps/dartclaw_cli` is clean; `git diff -- apps/dartclaw_cli/lib/src/commands/service_wiring.dart` is empty.

- [ ] **TI05** None of the 10 orphan symbols are reachable from any public barrel.
  - **Verify**: `rg "AdvisorOutput\b|AdvisorStatus\b|AdvisorTriggerContext\b|AdvisorTriggerType\b|CircuitBreaker\b|ContextEntry\b|SlidingContextWindow\b|TriggerEvaluator\b|AdvisorOutputParser\b|AdvisorOutputRouter\b|renderAdvisorInsightCard\b" packages/dartclaw_server/lib/dartclaw_server.dart packages/dartclaw_server/lib/src/canvas/canvas_exports.dart packages/dartclaw_server/lib/src/advisor/advisor_exports.dart` returns no matches.

- [ ] **TI06** Workspace analyze + advisor test suite green.
  - Run `dart analyze --fatal-warnings --fatal-infos` from the workspace root, then `dart test packages/dartclaw_server/test/advisor/`.
  - **Verify**: analyzer reports zero issues across the workspace; advisor test suite passes with zero failures.

### Testing Strategy
- [TI03] Scenario: "Removal happy path" → `dart analyze` workspace clean + advisor suite green confirms `AdvisorSubscriber` still publicly reachable after the canvas-block deletion.
- [TI05] Scenario: "Orphan symbols are no longer reachable" → `rg` sweep over the three barrel files confirms zero re-exports of the 10 orphan symbols.
- [TI03] Scenario: "Canvas re-exports remain intact" → `tail -n +15 canvas_exports.dart` byte-equality with pre-change canvas-domain block.
- [TI04] Scenario: "Downstream import-via-canvas regression" → exec-spec verifies `service_wiring.dart` is unchanged; if a stale consumer surfaces, switching to the umbrella import is the documented fix path.

### Validation
- Standard exec-spec gates suffice (build, analyze, advisor test suite). No feature-specific validation required.

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (file paths, the 10-symbol orphan list, line ranges 1–14 vs 15–22 in `canvas_exports.dart`) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, build troubleshooting — spawn in background when possible.
- After all tasks: run `dart analyze --fatal-warnings --fatal-infos` workspace-wide and `dart test packages/dartclaw_server/test/advisor/`. Keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met
- [ ] **All tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** or breaking changes introduced
- [ ] **Advisor test suite** passes (`dart test packages/dartclaw_server/test/advisor/`)
- [ ] **Workspace analyze clean** (`dart analyze --fatal-warnings --fatal-infos`)


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only. Tag semantics: see [`data-contract.md`](${CLAUDE_PLUGIN_ROOT}/references/data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](${CLAUDE_PLUGIN_ROOT}/references/automation-mode.md). Spec authors: leave this section empty._

_No observations recorded yet._
