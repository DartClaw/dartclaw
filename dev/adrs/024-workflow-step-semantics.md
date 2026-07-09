# ADR-024: Workflow Step Semantics — Workflow-Level Project, Engine-Computed Task Bookkeeping

## Status

Accepted — 2026-04-21

## Context

The workflow YAML surface today requires authors to write two fields whose names do not describe what they actually control:

- **`step.type`** is advertised as a semantic label ("coding", "analysis", "research", "writing", plus the structural kinds `agent`, `bash`, `approval`, `loop`, `foreach`, `map`, `parallel`). In practice, the value `coding` silently activates engine mechanisms — worktree creation, review gating, artifact-collection routing — that have nothing to do with "this step writes code" and everything to do with how the task system (which predates workflows) treats standalone coding tasks.

- **`step.project`** is declared as "Project ID for worktree isolation (coding steps)". Authors are instructed by convention to write `project: "{{PROJECT}}"` on every coding step. The repeated literal has no authoring signal beyond tribal knowledge: omit it on a coding step and the worktree silently targets the default `_local` workspace; add it to an analysis step and the task needlessly blocks on project-clone readiness.

These conventions are the external API of workflow authoring — every built-in workflow, testing profile, and user YAML repeats them. The conflation traces back to a design-time decision to build the workflow engine on top of the existing task system. Task-system concepts (coding vs analysis tasks, task-level review mode, task-level project binding) bled into the workflow-authoring surface instead of being hidden behind it.

### Concrete authoring traps observed

- Omit `project:` on a coding step → worktree silently created in `_local` (silent wrong target).
- Omit `type: coding` on a step that writes files → no worktree at all, edits land inline in the workflow workspace.
- Add `project:` to an analysis step → task blocks on project-clone readiness for no reason.
- A paper-cut attempt (2026-04-21) to make all steps implicitly inherit the workflow's `PROJECT` variable was reverted the same day — three integration tests in `workflow_builtin_integration_test.dart` defend the legitimate "analysis steps are project-agnostic" semantic, confirming the separation is real but badly expressed.

### Why this is an architecture concern, not a code smell

Left in place, the conflation:

- Forces every workflow author to know the `type: coding` / `project: "{{PROJECT}}"` convention or silently produce broken workflows.
- Ties workflow-YAML evolution to task-system internals — renames and enum conversions (0.16.5 S35/S38) stay cosmetic because they cannot touch the coupling.
- Obscures the actual workflow concepts (git bootstrap, worktree lifecycle, step kinds, gates) under task-shaped bookkeeping.

The workflow model should describe workflow concerns. The task system underneath it should remain unchanged for standalone tasks — which continue to use `type: coding` as their "create a worktree and route through review" trigger, exactly as they do today.

## Decision

Treat workflow authoring and task-system bookkeeping as two different concerns. Remove task-system artifacts from the workflow step YAML; compute the task-level fields from workflow-level declarations and container context.

### Workflow step YAML — removed

- **`step.project`** — no longer declared per-step. Deprecated; parser still accepts it as an override for backward compat; removal is scheduled for a future milestone.
- **Semantic values of `step.type`** (`coding`, `analysis`, `research`, `writing`) — no longer consulted by the engine for worktree or review decisions. Structural values (`agent`, `bash`, `approval`, `loop`, `foreach`, `map`, `parallel`) remain — they select which engine execution path runs.
- **`step.review`** — the per-step review-mode field is ignored in workflow context. Review in workflows is expressed structurally via dedicated review/approval **steps** plus gate expressions, not via a task-level attribute.

### Workflow YAML — added

- **`project: <id>`** (top-level, peer of `gitStrategy`) — the one project this workflow targets. Resolves via template substitution like any other field. Replaces the per-step `project: "{{PROJECT}}"` convention.

### Engine-computed, invisible to authors

When the workflow executor creates a `Task` for a step:

- **`Task.projectId`** ← workflow-level `project:` (or `null` if absent). Per-step override still honored during the deprecation window.
- **`Task.type`** ← `TaskType.coding` for every workflow-created task. The distinction between "coding" and "analysis" tasks in the UI label becomes uniform for workflow tasks; artifact collection continues to route via `_collectCodingArtifacts` (over-collection for read-only steps produces an empty diff — harmless). If the cosmetic regression matters later, skill frontmatter can declare `taskKind:` as a follow-up — no schema change.
- **Worktree decision** ← `gitStrategy` + container context, via the existing `_workflowNeedsWorktree` signal the workflow executor already computes. The task-system's `_taskNeedsWorktree` continues to check `task.type == TaskType.coding || task.configJson['_workflowNeedsWorktree'] == true` — so workflow tasks get worktrees from the workflow-derived signal, and standalone tasks keep the type-driven behavior.
- **Review gating** ← workflow-created tasks auto-accept on completion. Task-system's `_isCodingTask` check is a standalone-task concern; workflow tasks bypass review-mode resolution entirely.

### Standalone tasks — unchanged

Tasks created directly through the task UI (not by a workflow) continue to use `task.type == TaskType.coding` as the trigger for worktree creation and review routing. This ADR does not touch the standalone-task surface. The task-system's `TaskType` enum remains; its semantics remain; only its authoring role in workflow YAML changes.

### Target authoring shape

```yaml
name: implement-feature
variables:
  PROJECT:
    required: false

project: "{{PROJECT}}"      # one project, declared once

gitStrategy:
  bootstrap: true
  worktree: auto
  publish:
    enabled: true

steps:
  - id: implement
    skill: dartclaw-exec-spec
    prompt: Implement the feature

  - id: review-findings
    skill: dartclaw-review
    outputs:
      verdict:
        format: json
        schema: verdict

  - id: approve
    type: approval            # structural — stays
    prompt: Approve the implementation
```

No per-step `project:`. No `type: coding` required. No `review:` attribute. Readers see step IDs, skills, prompts, and gates — nothing else.

## Consequences

**Positive**

- Workflow authoring reads as workflow concerns: what steps, what skill, what gate, what structure. Task-system vocabulary stops leaking into the YAML.
- The `project: "{{PROJECT}}"` duplication across coding steps collapses into a single workflow-level declaration.
- Omission traps disappear — there are no opt-in flags for worktree or review at the step level that an author can forget.
- Future engine work can refactor workflow-task coupling without the YAML surface dragging along.

**Negative**

- The workflow YAML no longer carries an explicit "this step does coding vs analysis" hint. UI labels and logs show all workflow tasks as type `coding`. Cosmetic only; can be recovered via skill frontmatter in a follow-up if it matters.
- Two mental models for `TaskType`: standalone tasks still use it as a dispatch key; workflow tasks uniformly set it to `coding`. Documented in the architecture doc so future contributors aren't surprised.

**Neutral (migration)**

- Fully additive. Every existing YAML continues to parse and execute. Step-level `project:` is deprecated but still honored; semantic `type: analysis` etc. are still accepted by the parser but no longer consulted for engine decisions.
- Built-in YAMLs (`spec-and-implement`, `plan-and-implement`, `code-review`) migrate to the new shape as part of the implementation FIS. The three integration tests in `workflow_builtin_integration_test.dart` are updated to match the new authoring, not to defend the old behavior.

## Alternatives considered

### Alt 1: Implicit `{{PROJECT}}` inheritance for all steps

Attempted 2026-04-21 as a "paper-cut" fix. Made every step that omits `project:` inherit the workflow's `PROJECT` variable. Rejected because it broke the legitimate "analysis steps are project-agnostic" case — the three integration tests caught the regression within the first test run. Implicit rules across a bag-of-concerns field compound rather than resolve confusion.

### Alt 2: Leave the conventions in place; document them better

The `type: coding` + `project: "{{PROJECT}}"` pattern is widely understood by the team. Rejected: documentation does not make the coupling visible at the call site. Every new workflow author has to learn the tribal rules. The problem is API-shape, not docs.

### Alt 3: Add explicit per-step `needsWorktree` / `requiresReview` booleans

Considered and rejected in the design conversation. Duplicates information that already lives in `gitStrategy` and the container structure (for worktrees) or is properly expressed via dedicated review/approval steps (for review). Adds surface instead of removing it.

### Alt 4: Rename `coding` to something more descriptive

Chosen over some internal name like `code-modifying` or `writes-source`. Rejected: the problem isn't the word "coding", it's that one word is doing five jobs. Renaming preserves the conflation.

### Alt 5: Engine-side skill-frontmatter derivation of `Task.type`

Skills declare `taskKind: coding` / `taskKind: analysis` in their SKILL.md frontmatter. Workflow executor reads it and sets `Task.type` accordingly. Considered as a refinement on top of the flat "always coding" default. Deferred — adds complexity without a concrete user-facing win; easy to layer on later if the cosmetic UI regression matters.

## Scheduling

- **ADR-024 landing**: 0.16.4 (this record)
- **Implementation**: 0.16.4 PRD, story S41.
- **Deprecation of `step.project` and semantic `step.type` values**: kept during 0.16.4–0.16.x transition; scheduled for removal in a future milestone once built-in coverage is at 100% new-shape. The implementation FIS lands parser-level deprecation warnings; removal is out of scope for this ADR.

## Update — 2026-04-28

ADR-024 left two follow-up items: (1) the structural step-value list in §Decision named `agent`, but the engine shipped that marker as the literal `'custom'`; (2) §Scheduling deferred deprecation removal to a future milestone once built-in coverage reached 100% new-shape. Both close in 0.16.4 via S74:

- The agent-step marker is renamed to `'agent'` across code and built-in YAMLs. `step.type` defaults to `'agent'` when omitted.
- The four semantic values (`coding`, `analysis`, `research`, `writing`) plus the never-deprecated `automation` and the renamed `custom` are removed entirely. Workflow YAMLs that use them fail validation with a clear error pointing at the new canonical shape.
- Per-step `project:` and per-step `review:` are removed (parser rejects them as unknown keys).
- The deprecation-window plumbing — `WorkflowStep.typeAuthored`, `WorkflowStep.review`, `StepReviewMode`, `_semanticStepTypes`, the `_workflowStepType` task-config key, and the `task_config_view.dart` `stepType == 'coding'` fallback — is deleted.
- `TaskType` enum is untouched; standalone tasks continue to use the full enum as their dispatch key.

The structural-type list in §Decision should be read as: `agent, bash, approval, foreach, loop`. The original list named `map` and `parallel`, but those are step-shape attributes (set via `mapOver:` / `parallel: true`), not `step.type` values; they are not part of `_knownTypes`.

Rename and cleanup provenance: 0.16.4 PRD, story S74.

## References

- ADR-021 — AgentExecution primitive
- ADR-022 — Workflow run status + step outcome protocol
- ADR-023 — Workflow–task architectural boundary
- TD-065 — Polymorphic `TaskExecutionStrategy` (related follow-up below the boundary)
- 2026-04-21 design conversation (revert of the paper-cut attempt)
- `docs/architecture/workflow-architecture.md` §"Step Types", §"Artifact Auto-Commit"
- `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` (`_resolveProjectId`, `_workflowNeedsWorktree`)
- `packages/dartclaw_server/lib/src/task/task_executor.dart` (`_taskNeedsWorktree`, `_isCodingTask`)

## Amendment (0.16.4–0.16.5) — step I/O contract evolution

Recorded retroactively 2026-05-31. Later milestones evolved the step-semantics surface this ADR governs:

- **Symmetric `inputs:` / `outputs:` map schema (0.16.4).** `contextInputs:` / `contextOutputs:` were removed; `outputs:` map keys are now the sole declaration of which context keys a step writes (per-key `format` / `schema`), and `contextInputs:` was renamed to `inputs:`. The validator throws a clear migration error on the old keys.
- **`OutputConfig.setValue` / `set_value` (0.16.4)** — a per-output literal slot written verbatim to context on step success (distinct from "unset" via a sentinel round-trip), enabling per-loop-iteration context-key reset.
- **Closed step-type vocabulary (0.16.5)** — `step.type` is now closed at `{agent, bash, approval, foreach, loop}` (`"custom"` → `"agent"`, default `"agent"`); the deprecation window this ADR opened in 0.16.4 is closed.

See CHANGELOG `[0.16.4]` / `[0.16.5]`. Native-first structured-output resolution is recorded separately in [ADR-031](031-native-first-structured-outputs.md); file-based artifact transport in [ADR-032](032-file-based-workflow-artifact-transport.md).
