# Package Rules — `dartclaw_workflow`

**Role**: Owns the workflow control plane — YAML parsing, validation, registry, executor, and skill provisioning. Concrete entry points: `WorkflowExecutor`, `WorkflowDefinitionParser`, `WorkflowDefinitionValidator`, `WorkflowRegistry`, `SkillRegistry`, `SkillProvisioner`. Built-in workflow YAML lives at `lib/src/workflow/definitions/{spec-and-implement,plan-and-implement,code-review}.yaml`.

## Architecture
- **Authoring pipeline** — `WorkflowDefinitionParser` (YAML → typed model), `WorkflowDefinitionValidator` (rules under `lib/src/workflow/validation/`: gate, git-strategy, output-schema, reference, step-type, structure), `WorkflowRegistry` (lookup by name).
- **Executor** — `WorkflowExecutor` (run loop, gate evaluation, per-step persistence, crash recovery, role-alias provider resolution).
- **Step dispatch + iteration** — `step_dispatcher.dart` plus 3 step runners (`bash`, `approval`, `loop`) and 3 iteration controllers (`foreach`, `map`, `parallel_group`). Foreach/map produce a single aggregate output key; parallel_group produces one per branch.
- **Output capture** — `OutputConfig` (sentinel-backed slots so absence vs explicit `null` round-trip distinctly) + `context_extractor.dart` (parses inline `<workflow-context>`, falls back to a second extraction turn).
- **Skills subsystem** — `SkillRegistry` (step-time lookup), `SkillPromptBuilder` (prompt augmentation with `SKILL.md` body + step args), `SkillProvisioner` (startup AndThen clone gated by `AndthenNetworkPolicy` + DC-native skill copy from `packages/dartclaw_workflow/skills/`).
- **Host ports** — `WorkflowGitPort` (worktree / merge / push / PR) and `WorkflowTurnAdapter` (turn execution); both injected by `dartclaw_server`. This package never calls `Process.run` for git nor spawns harnesses directly.

## Shape
- **Authoring**: YAML → `WorkflowDefinitionParser.parse` → `WorkflowDefinitionValidator.validate` (rules split by concern under `lib/src/workflow/validation/`) → `WorkflowRegistry.register`. Built-in workflows ship at `lib/src/workflow/definitions/`.
- **Execution loop**: `WorkflowExecutor.execute` walks `WorkflowStep`s → `step_dispatcher.dispatch` → typed runner → outputs via `OutputConfig.setValue` → context persisted → next step. Context persists after every step; crash recovery resumes at the next un-completed step.
- **Step types**: `bash_step_runner` (shell), `approval_step_runner` (human checkpoint), `loop_step_runner` (re-runs inner sequence until a gate fires), `foreach_iteration_runner` (sequential), `map_iteration_runner` (parallel up to `maxParallel`), `parallel_group_runner` (fixed parallel branches). Foreach/map produce one aggregate output key; parallel_group produces one per branch.
- **Output capture**: agent emits a `<workflow-context>` payload inline → executor parses → outputs land in `OutputConfig`. Inline-parse failure triggers a second extraction turn; happy path is one turn.
- **Iteration + worktrees**: `gitStrategy.worktree: auto` resolves to `per-map-item` when `maxParallel > 1`, else `inline` (via `WorkflowGitStrategy.effectiveWorktreeMode()`). Worktree-promotion inference depends on this resolution.
- **Skills**: at step time, `SkillRegistry` looks up the skill → `SkillPromptBuilder` augments the prompt with the `SKILL.md` body + step arguments. `SkillProvisioner` clones AndThen at server startup (gated by `AndthenNetworkPolicy`) and copies DC-native skills from `packages/dartclaw_workflow/skills/` into the native user-tier Codex/Claude skill roots.
- **Host seam**: this package never calls `Process.run` for git nor spawns agents directly. The host (`dartclaw_server`) injects `WorkflowGitPort` (worktree / merge / push / PR) and `WorkflowTurnAdapter` (turn execution).

## Boundaries
- Allowed prod deps (enforced by `dev/tools/arch_check.dart`): `dartclaw_config`, `dartclaw_core`, `dartclaw_models`, `dartclaw_security`, `dartclaw_storage` only. Adding anything else fails the L1 dependency-graph check.
- Definition model (`WorkflowDefinition`, `WorkflowStep`, `WorkflowRun`, `OutputConfig`) lives in `dartclaw_models` — do not duplicate types here. New authoring fields land in two places: a typed field on the model and a corresponding branch in `WorkflowDefinitionParser`.
- Server-only concerns belong in `dartclaw_server`: HTTP routes (`workflow_routes.dart`), git implementations (`MergeExecutor`, `RemotePushService`, `PrCreator`), task execution glue. Inject git lifecycle through `WorkflowTurnAdapter` / `WorkflowGitPort`, never call `Process.run` for git from here.
- Cross-package `lib/src/` imports are forbidden — consume other workspace packages through their barrels.

## Conventions
- `outputs:` map keys are the single source of truth for context-write keys (`WorkflowStep.outputKeys` derives from them). Legacy `contextOutputs:` is rejected with a `FormatException` in `WorkflowDefinitionParser`. `OutputConfig.setValue` short-circuits extraction with a sentinel-backed slot so absence vs explicit `null` round-trip distinctly.
- Validators are split by concern under `lib/src/workflow/validation/` (gate, git-strategy, output-schema, reference, step-type, structure). Add new rules as a sibling file rather than expanding `WorkflowDefinitionValidator`.
- Step dispatch goes through `step_dispatcher.dart` → typed runners (`bash_step_runner`, `approval_step_runner`, `loop_step_runner`, `foreach_iteration_runner`, `map_iteration_runner`, `parallel_group_runner`). Don't add step-type branching in the executor.
- Workflow-spawned tasks always use `reviewMode: auto-accept`. Human checkpoints are structural — author an explicit review or `approval` step.
- Role aliases (`@executor`, `@reviewer`, `@planner`, `@workflow`) are skipped by continuity-provider validation — runtime `WorkflowExecutor._resolveContinueSessionProvider` handles family-mismatch fallback.
- DC-native skill names are listed explicitly in `dcNativeSkillNames` in `skill_provisioner.dart` — never wildcard-delete; update the list when adding a native skill under `skills/`.

## Gotchas
- `gitStrategy.worktree: auto` resolves through `WorkflowGitStrategy.effectiveWorktreeMode()` — to `per-map-item` only when `maxParallel > 1`, else `inline`. Promotion inference depends on the resolved mode.
- Writing a structured output requires the agent to emit a valid `<workflow-context>` payload inline; the executor only falls back to a second extraction turn when inline parse fails. Don't assume two turns.
- Foreach/map controllers parse `outputs:` through the standard path — exactly one aggregate key allowed.
- The executor persists context after every step for crash recovery — keep step runners idempotent and resume-safe.
- `dartclaw_core` barrel must not re-export `dartclaw_config` (arch_check enforces); workflow code must import config types directly.

## Testing
- `fake_async` is mandatory for any timer/loop logic — see `iteration_runner_wake_pattern_test.dart`. No real-time waits.
- Scenario-driven tests under `test/workflow/scenarios/` use `scenario_test_support.dart`. Layer 4 E2E lives behind `@Tags(['integration'])` and uses `test/fixtures/e2e_fixture.dart` (preset selectable via `DARTCLAW_TEST_PROVIDER`).
- Built-in workflow YAML is contract-tested by `built_in_workflow_contracts_test.dart` and skill-inventory by `built_in_skill_inventory_test.dart` — keep them green when editing definitions or `dcNativeSkillNames`.
- Use shared fakes from `dartclaw_testing` (dev_dependency); never redeclare a fake locally.

## Key files
- `lib/src/workflow/workflow_executor.dart` — main run loop, gate evaluation, persistence, recovery.
- `lib/src/workflow/workflow_definition_parser.dart` / `workflow_definition_validator.dart` — YAML → typed model + rule application.
- `lib/src/workflow/step_dispatcher.dart` + sibling `*_step_runner.dart` / `*_iteration_runner.dart` — step type plumbing.
- `lib/src/workflow/workflow_turn_adapter.dart` + `workflow_git_port.dart` — host-injected git callbacks; do not import server impls.
- `lib/src/workflow/skill_registry_impl.dart` + `skill_prompt_builder.dart` — skill lookup and prompt augmentation.
- `lib/src/skills/skill_provisioner.dart` — startup AndThen clone + DC-native skill copy; honors `AndthenNetworkPolicy`.
- `lib/src/workflow/definitions/*.yaml` — shipped built-in workflows; changes affect the contract test.
- `lib/src/workflow/validation/` — split validator rule files.
