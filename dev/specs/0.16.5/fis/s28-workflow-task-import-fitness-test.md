# S28 — Workflow↔Task Import Fitness Test

**Plan**: ../plan.md
**Story-ID**: S28

## Feature Overview and Goal

Mechanically enforce the ADR-023 workflow↔task import boundary as a Dart fitness test at `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`. The test scans every `.dart` file under `packages/dartclaw_workflow/lib/src/**` and asserts no `package:dartclaw_server/*` or `package:dartclaw_storage/*` imports — modulo a documented `_knownViolations` allowlist that empties when S12 lands. ADR-023 (S27) is the *named contract*; this is the *enforcement*.

**Status note**: per `plan.md` line 310, S28 is _Implemented (awaiting review + commit)_ — the test file already exists at the canonical path with the `_knownViolations` allowlist, file-header pointer to ADR-023, and the "how to resolve" remediation block. This FIS retrospectively documents the contract; the execution path is **verification + acceptance**, plus the lockstep commit-coordination with S12 (the `_knownViolations` map empties and `dev/tools/arch_check.dart` sanctioned-deps tightens in the same PR as S12's interface migration).

> **Technical Research**: [.technical-research.md](../.technical-research.md) — see `## S28 — Workflow↔Task Import Fitness Test`, Shared Decision #10 (fitness test location), Shared Decision #15 (workflow-context marker / ADR-023), Shared Decision #21 (S12+S28+arch_check lockstep).

## Required Context

### From `dev/specs/0.16.5/plan.md` — "S28 Acceptance Criteria"
<!-- source: dev/specs/0.16.5/plan.md#p-s28-workflow-task-import-fitness-test -->
<!-- extracted: 2026-05-04 -->
> - `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` exists and passes (must-be-TRUE)
> - Zero `dartclaw_server` imports from `dartclaw_workflow/lib/src/**` (must-be-TRUE — clean baseline)
> - `dartclaw_storage` allowlist is documented with file:line + remediation pointer to S12 (must-be-TRUE)
> - `dart analyze packages/dartclaw_testing` clean; `dart format` applied
> - File header comment links ADR-023 and explains how to resolve a legitimate violation (extract an interface to `dartclaw_core`)

### From `dev/specs/0.16.5/plan.md` — "S28 Scope"
<!-- source: dev/specs/0.16.5/plan.md#p-s28-workflow-task-import-fitness-test -->
<!-- extracted: 2026-05-04 -->
> Enforces the ADR-023 import boundary as a fitness test … Scans every `.dart` file under `packages/dartclaw_workflow/lib/src/**` and asserts no `package:dartclaw_server/*` or `package:dartclaw_storage/*` imports. Uses `dart:io` + `package:test/test.dart` only — no new deps. Current baseline: zero `dartclaw_server` violations (clean); two `dartclaw_storage` violations (`workflow_service.dart:26`, `workflow_executor.dart:54`, both importing `SqliteWorkflowRunRepository`) documented in an explicit `_knownViolations` allowlist tagged for closure by S12. When S12 lands, the allowlist empties in the same PR that removes the imports; `dev/tools/arch_check.dart` tightens to drop `dartclaw_storage` from `dartclaw_workflow`'s sanctioned deps in lockstep.

### ADR-023 cross-link (S27 FIS, Required Context)
<!-- source: dev/specs/0.16.5/fis/s27-workflow-task-boundary-adr.md -->
<!-- extracted: 2026-05-04 -->
> ADR-023 names the **behavioural** contract that ADR-021 / ADR-022 depend on. … `dartclaw_workflow` may write to `TaskRepository` directly … the direct-insert affordance is scoped to creation and must not be widened. Consequences: … the direct-insert affordance is a narrow exception that needs a fitness function (S28) to stay narrow.

## Deeper Context

- `packages/dartclaw_testing/CLAUDE.md` — package boundary rules; `test/fitness/` is the canonical fitness-suite location, runs via standard `dart test`, no integration tier.
- `dev/specs/0.16.5/.technical-research.md` Shared Decision #10 — fitness tests live in `packages/dartclaw_testing/test/fitness/**/*.dart`. Helper: `dev/tools/run-fitness.sh`.
- `dev/specs/0.16.5/.technical-research.md` Shared Decision #15 — workflow-context marker + ADR-023 division of labour: S27 names, S28 enforces.
- `dev/specs/0.16.5/.technical-research.md` Shared Decision #21 — S12 + S28 + `dev/tools/arch_check.dart` move in lockstep (single commit).
- `dev/tools/arch_check.dart` line 53 — workspace sanctioned-deps map; `dartclaw_workflow`'s set currently includes `dartclaw_storage` and is dropped in lockstep with S12. (Plan cites historical line 47; current ground truth is line 53. This is a snapshot drift, not a contract change.)
- `dev/tools/fitness/check_workflow_server_imports.sh` — predecessor shell script; retired once this Dart fitness test is wired into CI as the single source of truth.
- `packages/dartclaw_workflow/CLAUDE.md` — workflow package's own dep cap (config / core / models / security / storage) — this test enforces the import-direction half; storage drops out post-S12.

## Success Criteria (Must Be TRUE)

> Each criterion is a structural file/text/command check verifiable via the corresponding task **Verify** line.

- [ ] Test file exists at `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` and passes via `dart test` (proven by TI01)
- [ ] Test uses only `dart:io` + `package:test/test.dart` — zero new dependencies added to `packages/dartclaw_testing/pubspec.yaml` for this story (proven by TI02)
- [ ] Zero `package:dartclaw_server/*` imports from `packages/dartclaw_workflow/lib/src/**` (clean baseline; not allowlisted) (proven by TI03)
- [ ] `_knownViolations` documents exactly the two pre-existing `dartclaw_storage` violations (`src/workflow/workflow_service.dart` and `src/workflow/workflow_executor.dart`), each mapped to `{'dartclaw_storage'}`, with a comment block pointing to 0.16.5 S12 as the remediation (proven by TI04)
- [ ] File-header comment links ADR-023 (`docs/adrs/023-workflow-task-boundary.md` in dartclaw-private) and includes a "How to resolve a legitimate violation" block whose first remedy is "extract an interface into `dartclaw_core`" (proven by TI05)
- [ ] `dart analyze packages/dartclaw_testing` and `dart format --output=none --set-exit-if-changed packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` are clean (proven by TI06)
- [ ] When S12 lands, the `_knownViolations` map empties **and** `dev/tools/arch_check.dart` drops `dartclaw_storage` from `dartclaw_workflow`'s sanctioned-deps set in the same commit (lockstep coordination — proven by TI07; gated on S12 closure)

### Health Metrics (Must NOT Regress)

- [ ] Workspace-wide `dart analyze` and `dart test` remain green (no production-code changes in this story)
- [ ] `dart format` clean on the test file
- [ ] Existing CI fitness suite (`dev/tools/run-fitness.sh` / `dart test packages/dartclaw_testing/test/fitness/`) continues to discover and run this test on every commit

## Scenarios

### Happy: clean baseline passes against current `main`
- **Given** the workspace at the head of `feat/0.16.5` with the test file in place and the documented `_knownViolations` allowlist
- **When** a developer runs `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`
- **Then** the test reports a single passing case (`workflow package must not import from dartclaw_server or dartclaw_storage`) and exits 0.

### Error: a new server-side import in workflow code fails the test
- **Given** the test is passing on `main`
- **When** a contributor adds `import 'package:dartclaw_server/src/task/task_service.dart';` to a file under `packages/dartclaw_workflow/lib/src/` (a path **not** in `_knownViolations`)
- **Then** the test fails with a message of the shape `Workflow<->task boundary violations (see ADR-023, …):\n  src/<path>/<file>.dart:<LINE>: forbidden import package:dartclaw_server/...` — the violation is line-pinned and the failure message points at ADR-023.

### Error: a new storage import in a non-allowlisted file fails the test
- **Given** the two known `dartclaw_storage` violations are allowlisted in `_knownViolations`
- **When** a contributor adds `import 'package:dartclaw_storage/...';` to **any other** file under `packages/dartclaw_workflow/lib/src/`
- **Then** the test fails for the new file (existing allowlisted entries continue to be tolerated; only the new untracked import is reported).

### Edge: unlisted internal/third-party dep is also rejected
- **Given** `_allowedInternal` (`dartclaw_models`/`dartclaw_core`/`dartclaw_config`/`dartclaw_security`) and `_allowedThirdParty` (`logging`/`path`/`uuid`/`yaml`) are explicitly enumerated
- **When** workflow code imports a package not in either set (e.g. a fresh internal `dartclaw_xyz` or an undeclared third-party `crypto`)
- **Then** the test fails with `unlisted internal dep` or `unlisted third-party dep` — the allowlist must be updated in the same PR that adds the dependency to `pubspec.yaml`.

### Edge (post-S12): allowlist empties and `arch_check.dart` tightens in lockstep
- **Given** S12 has landed — `WorkflowRunRepository` is an abstract interface in `dartclaw_core`, `SqliteWorkflowRunRepository` `implements` it, and the two consumers (`workflow_service.dart`, `workflow_executor.dart`) have migrated to the abstract type
- **When** the same PR sets `_knownViolations` to `<String, Set<String>>{}` and removes `'dartclaw_storage'` from `dartclaw_workflow`'s entry in `dev/tools/arch_check.dart` (currently line 53)
- **Then** both `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` and `dart run dev/tools/arch_check.dart` (or whatever wires it into CI) pass — and a future re-introduction of either dep would fail both checks at once.

## Scope & Boundaries

### In Scope
- Verification that the existing test file at `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` matches every Success Criterion (file presence, dependency footprint, allowlist content, header comment, format/analyzer cleanliness, CI discovery).
- Confirming the failure-message shape and line-pinning behaviour match the Error scenarios (via a temporary local edit + revert; not a checked-in negative test).
- Cross-linking to S12's closure plan: when S12 lands, the allowlist empties and `dev/tools/arch_check.dart`'s sanctioned-deps map tightens in the same commit. S28's role here is to make sure that lockstep is documented and the test continues to enforce a non-empty contract afterwards.

### What We're NOT Doing
- **Extending the test to other package boundaries** — S25 owns the broader `dependency_direction_test.dart` fitness function. This test is scoped narrowly to the `dartclaw_workflow → dartclaw_server`/`dartclaw_storage` direction that ADR-023 names. Mixing concerns into one fitness test would bury failures.
- **Auto-fixing existing violations** — the two `dartclaw_storage` entries in `_knownViolations` are S12's work (interface extraction). S28 only documents and gates them.
- **Adding a `package:analyzer` dependency** — the regex-shaped grep over `.dart` files is sufficient for import-direction checks and keeps `dartclaw_testing`'s prod-dependency surface unchanged. (Per Binding Constraint #2: no new deps.)
- **Retiring `dev/tools/fitness/check_workflow_server_imports.sh` in this story** — the shell script's retirement is a follow-up; the Dart fitness test is the new source of truth, but removing the script is bookkeeping that lands when S10 / S25 establish the broader Dart fitness suite as canonical.
- **Editing the allowlist now** — the two entries stay until S12 removes the imports. Trying to drop them earlier reintroduces the leaky-abstraction smell ADR-023 names.

### Agent Decision Authority
- **Autonomous**: verify the existing file matches all Success Criteria; run `dart analyze` / `dart format` / `dart test` to confirm cleanliness; commit the file (if not yet committed) with a message that names ADR-023 and S28.
- **Escalate (BLOCKED)**: any drift between the test file and Success Criteria — e.g. an unexpected third allowlist entry, a missing header link to ADR-023, a new third-party import in `pubspec.yaml`. Do **not** silently rewrite the test; surface the gap. The test is contract-shaped and changes need an ADR pointer.

## Architecture Decision

We keep the test self-contained — `dart:io` + `package:test/test.dart` only, no `package:analyzer` — and rely on a regex-shaped import grep over the `.dart` files in `packages/dartclaw_workflow/lib/src/**`.

**Rationale**: simpler, no new deps (Binding Constraint #2), failure messages are exact line-pinned strings that a contributor can act on immediately, and the test's own surface area is small enough to read end-to-end (~140 LOC) without an analyzer-API mental model. Import statements are a syntactically simple subset of Dart — full AST parsing buys nothing here. The existing `dev/tools/fitness/check_workflow_server_imports.sh` shell script is superseded by this Dart fitness test (and is retired once the broader Dart fitness suite established by S10 / S25 owns the surface).

## Technical Overview

The test enumerates `.dart` files under `packages/dartclaw_workflow/lib/src/` recursively, scans each line for `import '<uri>';`, and classifies the imported package against three sets:

- `_forbiddenInternal = {'dartclaw_server', 'dartclaw_storage'}` — direct violations of ADR-023; allowlisted entries in `_knownViolations` are tolerated, anything else fails.
- `_allowedInternal = {'dartclaw_models', 'dartclaw_core', 'dartclaw_config', 'dartclaw_security'}` — sanctioned internal deps. Other `dartclaw_*` packages fail as `unlisted internal dep`.
- `_allowedThirdParty = {'logging', 'path', 'uuid', 'yaml'}` — sanctioned third-party deps mirroring `packages/dartclaw_workflow/pubspec.yaml`'s `dependencies:`. Other third-party imports fail as `unlisted third-party dep`.

Failure messages take the shape `<relative-path>:<line>: forbidden import <uri>` (or `unlisted internal dep` / `unlisted third-party dep`) and are aggregated into a single `fail(...)` call so the contributor sees all violations at once, with an ADR-023 pointer.

### Integration Points

- **CI** — runs as part of `dart test packages/dartclaw_testing/test/fitness/` on every commit; the existing `dev/tools/run-fitness.sh` wrapper is unchanged.
- **S12 closure** — the `_knownViolations` map empties and `dev/tools/arch_check.dart`'s sanctioned-deps list for `dartclaw_workflow` drops `dartclaw_storage` in the same PR (Shared Decision #21). S28 stays passing across that change with a strictly tighter contract.
- **ADR-023 (S27)** — the doc-side contract; the test's file-header comment links to it and to the "extract an interface into `dartclaw_core`" remediation pattern.

## Code Patterns & External References

```
# type | path/url | why needed
file   | dartclaw-public/packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart      | Subject of this FIS — verify content
file   | dartclaw-public/packages/dartclaw_testing/CLAUDE.md                                          | Package boundaries; fitness tests live under test/fitness/
file   | dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_service.dart            | Allowlisted violation #1 (line 26 import — closes via S12)
file   | dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart           | Allowlisted violation #2 (line 54 import — closes via S12)
file   | dartclaw-public/dev/tools/arch_check.dart                                                    | Sanctioned-deps map; line 53 drops `dartclaw_storage` for `dartclaw_workflow` in lockstep with S12
file   | dartclaw-public/dev/tools/run-fitness.sh                                                     | Wrapper that runs the fitness suite locally
file   | dartclaw-public/dev/tools/fitness/check_workflow_server_imports.sh                           | Retired predecessor (shell-based); kept for now, removed once the Dart suite is canonical
file   | dartclaw-private/docs/adrs/023-workflow-task-boundary.md                                     | Named contract (S27); referenced from the test's file-header comment
file   | dartclaw-public/dev/specs/0.16.5/fis/s27-workflow-task-boundary-adr.md                       | S27 FIS — peer story (doc side of the same contract)
```

## Constraints & Gotchas

- **Constraint (Binding #2 — no new deps)**: the test must not pull in `package:analyzer` or any other new dependency. `dart:io` + `package:test/test.dart` are the only allowed imports.
- **Constraint (Binding #15 — workflow↔task marker / ADR-023)**: this test is the import-direction enforcement of ADR-023. Do not weaken or generalise it; if a different boundary needs a fitness check, write a separate test (e.g. S25's `dependency_direction_test.dart`).
- **Constraint (Binding #21 — lockstep)**: when S12 lands, the `_knownViolations` map empties and `dev/tools/arch_check.dart` tightens in the **same PR**. Splitting them across PRs leaves a window where the contract is partially-enforced or partially-claimed-clean — both confusing.
- **Avoid**: adding a third allowlist entry "for the next PR". The allowlist documents pre-existing debt with a named remediation story. New entries require a new ADR per the file-header comment.
- **Avoid**: silently rewriting the test to make a downstream change pass. If a legitimate need arises (e.g. a workflow type genuinely needs to live in `dartclaw_core`), extract the interface — don't grow the allowlist.
- **Critical**: the test's `_findWorkflowLib()` walks up from `Directory.current` so `dart test` works from either the repo root or any package directory. If you change CI's working directory, sanity-check that the test still locates `packages/dartclaw_workflow/lib`.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Test file exists at the canonical path and passes against current `main`.
  - Path: `packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`.
  - **Verify**: `test -f packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` and `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` reports `+1: All tests passed!`.

- [ ] **TI02** Test depends only on `dart:io` and `package:test/test.dart` — no new deps.
  - **Verify**: `rg -n "^import " packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` returns exactly two lines: `import 'dart:io';` and `import 'package:test/test.dart';`. `git diff --stat origin/main -- packages/dartclaw_testing/pubspec.yaml` is empty for this story.

- [ ] **TI03** Zero `dartclaw_server` imports under `packages/dartclaw_workflow/lib/src/**`.
  - **Verify**: `rg -n "package:dartclaw_server" packages/dartclaw_workflow/lib/src/` returns no matches. (This is the clean-baseline arm of the Success Criteria — there is no `dartclaw_server` allowlist, so the test would already fail if any leaked.)

- [ ] **TI04** `_knownViolations` documents exactly the two `dartclaw_storage` entries.
  - Expected entries: `'src/workflow/workflow_service.dart' -> {'dartclaw_storage'}`, `'src/workflow/workflow_executor.dart' -> {'dartclaw_storage'}`.
  - Imports themselves still present at the documented lines: `workflow_service.dart:26` and `workflow_executor.dart:54`.
  - **Verify**: `rg -n "_knownViolations" packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` returns the const declaration; manual read confirms exactly two map keys and `'dartclaw_storage'` as the only forbidden package per entry; `rg -n "package:dartclaw_storage" packages/dartclaw_workflow/lib/src/workflow/workflow_service.dart packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` returns one match per file. The `_knownViolations` doc comment names "0.16.5 S12" as the remediation story.

- [ ] **TI05** File-header comment links ADR-023 and explains the remediation pattern.
  - Required content: a comment block at the top of the file that (a) states what the test enforces, (b) cites `docs/adrs/023-workflow-task-boundary.md` (private repo) by path, (c) contains a "How to resolve a legitimate violation" section whose **first** remedy is to extract an interface into `dartclaw_core` (the `WorkflowRunRepository` pattern from S12 is the worked example).
  - **Verify**: `rg -n "023-workflow-task-boundary\.md" packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` returns ≥ 1 match in the header; `rg -n "How to resolve a legitimate violation" packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` returns 1 match; manual read confirms the "extract an interface into `dartclaw_core`" wording is present and is the first listed remedy.

- [ ] **TI06** `dart analyze` and `dart format` are clean for the test file.
  - **Verify**: `dart analyze packages/dartclaw_testing` exits 0 with no warnings/infos; `dart format --output=none --set-exit-if-changed packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` exits 0.

- [ ] **TI07** Lockstep coordination with S12 is documented and ready.
  - The S12 FIS / closure checklist (when authored) must list, as a single-commit deliverable: (a) empty `_knownViolations` in this test, (b) drop `dartclaw_storage` from `dartclaw_workflow`'s sanctioned-deps set in `dev/tools/arch_check.dart` (currently line 53; plan cites historical line 47), (c) the workflow code-side migrations to the abstract `WorkflowRunRepository`. S28 itself only verifies the cross-link and the current allowlist; the empty-allowlist enforcement is gated on S12 closure.
  - **Verify**: plan section for S12 (line ~365) names the `_knownViolations` empties + `arch_check.dart` tightens lockstep; this FIS's Success Criteria mention that lockstep; `dev/specs/0.16.5/.technical-research.md` Shared Decision #21 documents the lockstep. (Three pointer-checks; no code change here until S12 lands.)

- [ ] **TI08** File is committed (or ready to commit) with a message that records the contract.
  - **Verify**: `git log --oneline -- packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` returns at least one commit; `git status -- packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` shows clean. If not yet committed, commit alongside S27's ADR with a message that names ADR-023 and S28 (e.g. _"fitness: workflow↔task import boundary (ADR-023, S28)"_).

### Testing Strategy
- [TI01] Happy scenario "clean baseline passes against current `main`" → run `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart`.
- [TI03,TI04] Error scenarios "new server-side import" / "new storage import in a non-allowlisted file" → temporarily add an offending import to a non-allowlisted file under `packages/dartclaw_workflow/lib/src/`, run the test, observe `src/.../<file>.dart:<LINE>: forbidden import …` plus the ADR-023 pointer in the failure message, then revert. (Local sanity check; not a checked-in negative test.)
- [TI04] Edge scenario "unlisted internal/third-party dep is also rejected" → the same temporary-edit approach, observing `unlisted internal dep` / `unlisted third-party dep` messages.
- [TI07] Edge scenario "post-S12 allowlist empties + `arch_check.dart` tightens in lockstep" → cross-document check: S12 plan section + this FIS + `.technical-research.md` Shared Decision #21 all describe the same single-commit deliverable.
- [TI06] Standard exec-spec validation — `dart analyze packages/dartclaw_testing`, `dart format` over the test file.

### Validation
- This is a docs-and-fitness retrospective verification. The standard exec-spec build/test/lint loop applies trivially (zero production-code changes); explicit additions:
  - `dart test packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` passes.
  - `dart analyze packages/dartclaw_testing` clean.
  - `dart format --output=none --set-exit-if-changed packages/dartclaw_testing/test/fitness/workflow_task_boundary_test.dart` clean.
  - `dev/tools/run-fitness.sh` (the project-wide fitness wrapper) discovers and runs the test.

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding.
- All `Verify` commands assume the working directory is `dartclaw-public/` (the public repo root) unless prefixed with `dartclaw-private/`.
- If any Verify fails, do **not** rewrite the test to match the criterion. Emit `BLOCKED:` with the specific gap and stop — the test is contract-shaped and changes need an ADR pointer.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] **All success criteria** met (verified via TI01–TI08)
- [ ] **All tasks** fully completed and checkboxes checked
- [ ] **No regressions** — zero production-code changes in `dartclaw-public`; workspace `dart analyze`/`dart test` unchanged
- [ ] **CI** — fitness test discovered and run by `dart test packages/dartclaw_testing/test/fitness/` on every commit
- [ ] **S12 lockstep** documented in S12 FIS / closure checklist (TI07)
- [ ] **ADR-023 pointer** present in the test's file-header comment (TI05)

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
