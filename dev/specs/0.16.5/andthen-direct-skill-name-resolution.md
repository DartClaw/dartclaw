# FIS - AndThen Direct Skill Name Resolution

> **Standalone FIS for milestone 0.16.5 - not part of `plan.md`.**

## Feature Overview and Goal

Remove DartClaw's AndThen skill rebranding/porting path and make built-in workflow steps reference AndThen skills by canonical logical names such as `andthen:spec`. DartClaw should resolve those canonical names to the provider-native invocation form for Codex and Claude Code with minimal hardcoded aliases and no operator-maintained alias configuration.


## Required Context

### From `packages/dartclaw_workflow/AGENTS.md` - Current `dartclaw-*` Namespace Contract
<!-- source: packages/dartclaw_workflow/AGENTS.md#built-in-workflows-shipped -->
<!-- extracted: 236ab396 -->
> All three orchestrate skills in the **`dartclaw-*` namespace** (`dartclaw-discover-project`, `dartclaw-prd`, `dartclaw-plan`, `dartclaw-exec-spec`, `dartclaw-quick-review`, `dartclaw-review`, `dartclaw-architecture`, `dartclaw-refactor`, `dartclaw-remediate-findings`) - never `andthen:*` plugin counterparts. The canonical DC-native inventory is `dcNativeSkillNames` in `lib/src/skills/skill_provisioner.dart`; do not wildcard-add or rename these without updating that list.

This FIS replaces the AndThen-derived half of that contract. DartClaw-native skills (`dartclaw-discover-project`, `dartclaw-validate-workflow`, `dartclaw-merge-resolve`) remain exact installed names; AndThen-owned skills move to canonical `andthen:<name>` references.

### From `docs/guide/andthen-skills.md` - Current Ported Provisioning Contract
<!-- source: docs/guide/andthen-skills.md#andthen-skills -->
<!-- extracted: 236ab396 -->
> DartClaw's built-in workflows (`spec-and-implement`, `plan-and-implement`, `code-review`) reference AndThen-derived skills through DartClaw's installed namespace (`dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`, `dartclaw-exec-spec`, `dartclaw-review`, `dartclaw-remediate-findings`, `dartclaw-quick-review`, `dartclaw-ops`). DartClaw provisions those skills into its data directory, then materializes per-skill links into project workspaces so Claude Code and Codex can discover them through their native project skill loaders.

This whole AndThen-derived provisioning behavior is removed. The replacement contract is: AndThen skills are an external harness capability installed by AndThen itself or by Claude Code plugin management; DartClaw validates and invokes them through canonical `andthen:<name>` references plus provider aliases.

### From `packages/dartclaw_core/lib/src/harness/agent_harness.dart` - Existing Activation Hook
<!-- source: packages/dartclaw_core/lib/src/harness/agent_harness.dart#agentharness -->
<!-- extracted: 236ab396 -->
> Workflow steps (and any caller that wants to hand the harness a skill to run) should use this to build the prompt preamble, so the harness can pre-load the `SKILL.md` body instead of asking the model to find and read it via a tool call.
>
> Subclasses override with the harness-native form (Codex uses `$skill-name`, Claude Code uses `/skill-name`, etc.).

The provider-specific activation hook already exists. The implementation must feed it the provider-resolved invocation name, not necessarily the canonical workflow reference.


## Deeper Context

- `dev/specs/0.16.5/data-dir-skill-provisioning.md` - prior standalone FIS that introduced data-dir provisioning; read before deleting or narrowing that surface.
- `docs/guide/workflows.md#skills-and-artifacts` - user-facing workflow docs that currently name `dartclaw-*` AndThen-derived skills.
- `dev/state/LEARNINGS.md#workflow-engine` - workflow-gate and provisioning gotchas, especially validator role-default resolution and data-dir skill provisioning notes.
- `dev/guidelines/TESTING-STRATEGY.md#workflow-integration-tests` - test-layer guidance for workflow/parser/CLI integration checks.


## Success Criteria (Must Be TRUE)

- [x] Built-in workflow YAML references AndThen-owned skills with canonical `andthen:<name>` values, not `dartclaw-*` ported names.
- [x] `dartclaw-discover-project`, `dartclaw-validate-workflow`, and `dartclaw-merge-resolve` remain DartClaw-native exact skill names; no `dartclaw:` alias layer is introduced.
- [x] Codex invocation of canonical `andthen:spec` resolves to the native activation line `$andthen-spec`; Claude Code invocation resolves to `/andthen:spec`.
- [x] Workflow validation resolves canonical AndThen references against provider-specific aliases without requiring per-workflow `name_codex`, `name_claude`, or operator configuration.
- [x] Runtime prompt building uses the same provider-resolved invocation name that validation accepted.
- [x] DartClaw no longer clones AndThen or runs `install-skills.sh --prefix dartclaw- --display-brand DartClaw` to create DartClaw-branded copies of AndThen skills or agents.
- [x] DartClaw-native skill provisioning/linking remains available for the three DC-native skills only.
- [x] The retired `andthen.*` source/provisioning configuration surface is removed from public config, metadata, serialization, docs, and tests; legacy YAML keys may produce a warning, but they must not appear as active settings.
- [x] Missing AndThen installations fail with provider-specific, actionable diagnostics naming the canonical skill and the concrete provider alias that was searched.
- [x] User-facing docs and package AGENTS guidance describe the new canonical naming contract and remove stale claims that built-ins use `dartclaw-*` for AndThen-derived skills.

### Health Metrics (Must NOT Regress)

- [x] Existing built-in workflow contract tests remain green after expected golden/name updates.
- [x] `dart analyze --fatal-warnings --fatal-infos` passes for touched packages.
- [x] Focused tests for `dartclaw_models`, `dartclaw_core`, `dartclaw_config`, `dartclaw_workflow`, `dartclaw_server`, and `dartclaw_cli` pass.
- [x] `dev/tools/check_versions.sh` and existing architecture/fitness gates are not weakened.


## Scenarios

### Codex Resolves Canonical AndThen Skill
- **Given** a workflow step declares `skill: andthen:spec` and the effective provider is `codex`
- **When** the workflow validator checks the step and `SkillPromptBuilder` builds its prompt
- **Then** validation accepts a discovered `andthen-spec` Codex skill, and the prompt starts with `$andthen-spec`, not `$andthen:spec` or `$dartclaw-spec`.

### Claude Code Resolves Canonical AndThen Skill
- **Given** a workflow step declares `skill: andthen:review` and the effective provider is `claude`
- **When** the workflow validator checks the step and `SkillPromptBuilder` builds its prompt
- **Then** validation accepts a Claude Code skill exposed as `andthen:review`, and the prompt starts with `/andthen:review`.

### Role Defaults Drive Provider Alias Resolution
- **Given** a workflow step declares `skill: andthen:plan` and `provider: @planner`
- **When** workflow role defaults resolve `@planner` to `codex`
- **Then** validation searches the Codex alias `andthen-plan`; changing the planner role to `claude` searches the Claude alias `andthen:plan` without changing the workflow YAML.

### Missing AndThen Install Produces Actionable Error
- **Given** a built-in workflow references `skill: andthen:exec-spec`, the effective provider is `codex`, and no `andthen-exec-spec` skill is discovered for Codex
- **When** `dartclaw workflow validate` runs
- **Then** the validation error names `andthen:exec-spec`, says provider `codex` searched `andthen-exec-spec`, and tells the operator to install AndThen for Codex rather than restart DartClaw's old `dartclaw-*` provisioner.

### DartClaw-Native Skills Stay Exact
- **Given** `spec-and-implement` starts with `skill: dartclaw-discover-project`
- **When** validation and prompt building run for either Codex or Claude Code
- **Then** the step resolves exactly as `dartclaw-discover-project`; no `andthen:` aliasing rules apply.

### No DartClaw-Ported AndThen Payloads Are Created
- **Given** a fresh DartClaw data dir and a workflow run in standalone mode
- **When** workflow bootstrap runs
- **Then** no `<dataDir>/.agents/skills/dartclaw-spec`, `<dataDir>/.claude/skills/dartclaw-spec`, `<workspace>/.agents/skills/dartclaw-spec`, or `<workspace>/.claude/skills/dartclaw-spec` path is created for AndThen-owned skills.


## Scope & Boundaries

### In Scope
- Introduce a first-class skill-reference resolution path that treats `WorkflowStep.skill` as a canonical reference and resolves a provider-specific invocation name at validation and prompt-build time.
- Define deterministic built-in alias rules for the `andthen:` namespace:
  - `codex`: `andthen:<name>` -> `andthen-<name>`
  - `claude`: `andthen:<name>` -> `andthen:<name>`
  - unknown provider: exact canonical name only, with the existing verbose activation fallback
- Update built-in workflow YAML to use `andthen:<name>` for AndThen-owned skills.
- Remove AndThen-derived `dartclaw-*` provisioning from `SkillProvisioner`, `WorkspaceSkillLinker`, CLI bootstrap/preflight checks, docs, config, and tests.
- Keep or replace the existing provisioning/linking code needed for DC-native skills only.
- Update model serialization and registry APIs only as much as needed to carry canonical and resolved skill names cleanly.
- Update tests and docs that currently assert `dartclaw-prd`, `dartclaw-spec`, `dartclaw-review`, or similar AndThen-derived names.

### What We're NOT Doing
- **No YAML-level alias maps** - do not add `name_claude`, `name_codex`, `aliases:`, or equivalent per-step config.
- **No operator alias configuration** - alias rules for `andthen:` are built-in and deterministic.
- **No AndThen source-management config** - remove the active `andthen.git_url`, `andthen.ref`, `andthen.network`, and `andthen.source_cache_dir` settings because DartClaw no longer clones or installs AndThen.
- **No `dartclaw:` namespace** - DartClaw-native skills keep their current exact `dartclaw-*` names.
- **No separate Claude user/plugin modes** - Claude Code uses `andthen:<name>` as its provider alias; this FIS does not support a second Claude alias for user-tier `andthen-<name>` installs.
- **No upstream AndThen installer changes** - DartClaw stops rebranding AndThen; it does not patch AndThen.
- **No broad workflow-engine refactor** - task execution, outputs, gates, worktrees, and artifact handling stay unchanged except for skill-name resolution.

### Agent Decision Authority
- **Autonomous**: Name the new resolver types and files in sympathy with existing `SkillRegistry`, `SkillInfo`, and `SkillPromptBuilder` patterns.
- **Autonomous**: Keep compatibility shims for existing serialized `WorkflowStep.skill` strings if tests reveal persisted runs need them, but do not preserve `dartclaw-*` AndThen names in built-in YAML.
- **Escalate**: Any decision to support both Claude `andthen:<name>` and `andthen-<name>` aliases, because the user explicitly narrowed this FIS to one Claude Code alias.
- **Escalate**: Any plan to delete DC-native skills or rename them away from `dartclaw-*`.


## Architecture Decision

**Approach**: Add a provider-aware skill-reference resolver behind `SkillRegistry`, using canonical `andthen:<name>` as the workflow contract and deterministic provider aliases for invocation. Keep `WorkflowStep.skill` as a scalar canonical string so workflow YAML remains concise.

**Rationale**: This follows CUPID's Predictable and Idiomatic properties: workflow authors see one stable name, providers receive the invocation string they natively understand, and aliases live in one runtime boundary instead of being copied into every step. It also avoids reviving the old porting path, which was configuration-heavy and created a second DartClaw-branded copy of upstream AndThen behavior.

**Alternatives considered**:
1. **Per-step fields such as `name_claude` / `name_codex`** - rejected: it repeats harness details throughout workflow YAML and makes built-ins harder to audit.
2. **Install AndThen with `--prefix dartclaw-` and keep `dartclaw-*` references** - rejected: this is the behavior being removed; it couples DartClaw releases to a branded copy of upstream skills.
3. **Accept only exact skill names** - rejected: exact names cannot express the real Codex/Claude Code naming split without either changing one harness convention or reintroducing workflow-level aliases.


## Technical Overview

### Data Models

Keep `WorkflowStep.skill` as `String?`, but treat the value as the canonical reference. Add a small resolution value type near the workflow skill registry boundary, for example:

- canonical reference: `andthen:spec`
- provider id: `codex`
- resolved invocation name: `andthen-spec`
- matched discovered skill name: `andthen-spec`
- matched `SkillInfo` metadata from the discovered concrete skill, used for default prompt/output lookup
- native harness availability: provider-specific boolean

The exact type name is implementation-owned. The canonical reference and resolved invocation name must remain distinct: `WorkflowStep.skill` stays canonical for authored/resolved YAML, while dispatch uses the resolved invocation name for harness activation and the matched `SkillInfo` for skill metadata. Do not add an object-valued `skill:` YAML shape unless scalar resolution proves impossible.

### Integration Points

- `SkillRegistry` and `SkillRegistryImpl` own lookup by canonical reference plus provider; exact `getByName` can stay for UI/listing and direct lookups.
- `WorkflowDefinitionValidator` must validate skill references using effective providers, including role defaults such as `@planner`, `@executor`, and `@reviewer`.
- Runtime dispatch must recompute skill resolution with the same effective provider calculation used by validation. Do not rely on a validation-time cache; workflows can be loaded and executed through different service seams.
- `SkillPromptBuilder` must receive the resolved invocation name, not the canonical reference, when building the provider-native activation line.
- Skill default prompt/output lookup must use the matched discovered `SkillInfo` from resolution, so a canonical Codex reference such as `andthen:spec` can still read metadata from the discovered `andthen-spec` skill.
- `workflow show --resolved` must keep the authored canonical `skill: andthen:<name>` value in emitted YAML; if it shows provider-specific detail, expose it as diagnostic/resolution metadata rather than rewriting `skill:`.
- CLI standalone preflight `_missingNativeSkillInstalls` must use the same resolver rather than checking only `skillName.startsWith('dartclaw-')`.
- `SkillProvisioner` should stop cloning/installing AndThen-derived skills. If retained, narrow its purpose and naming to DC-native skill provisioning; stale AndThen config/docs/tests must be removed or rewritten.


## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_models/lib/src/workflow_definition.dart:453-464                  | WorkflowStep.skill currently scalar exact reference; preserve scalar shape
file   | packages/dartclaw_models/lib/src/skill_info.dart:49-84                              | SkillInfo currently stores exact name + nativeHarnesses; extend or pair with resolver
file   | packages/dartclaw_workflow/lib/src/workflow/skill_registry.dart:7-20                 | Registry interface currently exact lookup/validation; add provider-aware resolution
file   | packages/dartclaw_workflow/lib/src/workflow/skill_registry_impl.dart:66-88            | Source priority and nativeHarnesses discovery; use discovered names as alias targets
file   | packages/dartclaw_workflow/lib/src/workflow/skill_registry_impl.dart:367-399          | Current validateRef/isNativeFor exact-name behavior to replace
file   | packages/dartclaw_workflow/lib/src/workflow/validation/workflow_reference_rules.dart:4-55 | Validator currently validates exact skill and explicit provider only
file   | packages/dartclaw_workflow/lib/src/workflow/skill_prompt_builder.dart:80-124          | Prompt construction point that needs resolved invocation name
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition_validator.dart:84      | Artifact-producing skill list currently uses old exact names
file   | packages/dartclaw_workflow/lib/src/workflow/validation/workflow_git_strategy_rules.dart:39-55 | Artifact-producer validation must keep working after canonical names
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_artifact_committer.dart:22-29     | Artifact-commit classification currently uses old exact names
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor_helpers.dart:21-40       | Skill default prompt/output lookup must use matched alias metadata
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition_resolver.dart:94-121   | Resolved workflow output must preserve canonical authored skill values while resolving metadata
file   | packages/dartclaw_workflow/lib/src/workflow/step_dispatcher.dart:19                    | Discover-project special case must remain exact DC-native behavior only
file   | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart:181-182               | Claude Code activation prefix
file   | packages/dartclaw_core/lib/src/harness/codex_harness.dart:96-97                       | Codex activation prefix
file   | packages/dartclaw_workflow/lib/src/skills/skill_provisioner.dart:88-100               | Current AndThen-derived provisioning contract to remove/narrow
file   | packages/dartclaw_workflow/lib/src/skills/skill_provisioner.dart:371-390              | Current installer args hard-code `--prefix dartclaw- --display-brand DartClaw`
file   | packages/dartclaw_workflow/lib/src/skills/workspace_skill_linker.dart:37-43           | Current managed patterns only cover `dartclaw-*`; narrow to DC-native if retained
file   | packages/dartclaw_config/lib/src/andthen_config.dart                                  | Retired active `andthen.*` config value type
file   | packages/dartclaw_config/lib/src/config_parser.dart                                   | Legacy `andthen.*` YAML parsing should be removed or warn-only
file   | packages/dartclaw_config/lib/src/config_meta.dart                                     | Public config metadata must stop advertising retired settings
file   | packages/dartclaw_server/lib/src/config/config_serializer.dart                        | Serialized config output must stop exposing retired active settings
file   | apps/dartclaw_cli/lib/src/commands/workflow/workflow_run_command.dart:815-832         | Standalone missing-skill preflight currently special-cases `dartclaw-*`
file   | packages/dartclaw_workflow/lib/src/workflow/definitions/*.yaml                       | Built-in workflow skill names to migrate
file   | packages/dartclaw_workflow/test/workflow/skill_registry_impl_test.dart                | Registry tests for source priority, nativeHarnesses, validateRef
file   | packages/dartclaw_workflow/test/skills/skill_provisioner_test.dart                    | Tests that currently assert `dartclaw-prd` provisioning; rewrite for DC-native-only behavior
file   | packages/dartclaw_config/test/andthen_config_test.dart                                | Retired active config contract tests to remove or replace with legacy-warning tests
file   | apps/dartclaw_cli/test/commands/service_wiring_andthen_skills_test.dart               | Wiring tests currently prove DartClaw-branded AndThen provisioning
doc    | docs/guide/andthen-skills.md                                                          | User-facing provisioning/naming contract to rewrite
doc    | packages/dartclaw_workflow/AGENTS.md                                                   | Package rules must stop saying built-ins never use `andthen:*`
```


## Constraints & Gotchas

- **Provider role aliases are resolved late.** Validation must use the same effective provider calculation as runtime. The learning "Workflow validators that compare provider roles need runtime role defaults" applies here.
- **Do not break exact-name custom skills.** A custom workflow using `skill: my-local-skill` should continue exact lookup for both providers; aliasing applies only to `andthen:<name>`.
- **Activation name and registry match are separate concepts.** The canonical reference remains `andthen:spec`; the prompt activation for Codex is `andthen-spec`. Do not mutate `WorkflowStep.skill` during parsing.
- **Runtime hardcoded skill-name checks are part of the migration.** Artifact-producer detection, artifact commits, resolved workflow display, skill default lookup, and discover-project special cases must not retain old AndThen-derived exact-name assumptions.
- **Missing-skill errors must be concrete.** "Skill not found" is insufficient; include canonical reference, provider id, and searched alias.
- **Old `dartclaw-*` AndThen entries may exist in user or workspace skill dirs.** Do not auto-delete operator-owned copies; docs may include manual cleanup guidance.
- **Retired `andthen.*` config must not become a dead active surface.** If legacy keys are accepted for transition, parse them only to emit compatibility warnings; do not serialize or document them as active settings.
- **Docs and package AGENTS drift is part of the bug.** Any code-only fix leaves future agents following stale `dartclaw-*` rules.
- **Serialized in-flight workflows may reference `dartclaw-*`.** If persisted workflow runs are loaded from prior definitions, keep a best-effort compatibility path for execution or produce a clear "definition must be reloaded" diagnostic. Do not keep the old names in new built-in YAML.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** Add provider-aware skill resolution to the workflow skill registry.
  - Keep exact lookup for non-`andthen:` skill names. For `andthen:<name>`, resolve aliases deterministically: `codex -> andthen-<name>`, `claude -> andthen:<name>`.
  - **Verify**: New `skill_registry_impl_test.dart` cases prove `resolve(andthen:spec, codex)` matches discovered `andthen-spec`, `resolve(andthen:spec, claude)` matches discovered `andthen:spec`, and `resolve(custom-skill, codex)` still requires exact `custom-skill`.

- [x] **TI02** Thread resolved invocation names into validation and prompt building.
  - `WorkflowDefinitionValidator` should validate with effective provider role defaults. Runtime dispatch should resolve again with the same effective provider calculation, then pass the resolved invocation name to `SkillPromptBuilder`.
  - Skill default prompt/output lookup should use the matched discovered `SkillInfo` returned by resolution, not `getByName(step.skill)` on the canonical reference.
  - **Verify**: Focused validator and prompt-builder tests assert the exact activation lines `$andthen-spec` and `/andthen:spec` from canonical `skill: andthen:spec`, including a Codex case where default prompt/output metadata is discovered under `andthen-spec`.

- [x] **TI03** Update built-in workflow definitions from ported AndThen names to canonical AndThen references.
  - Change AndThen-owned steps only: `dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`, `dartclaw-exec-spec`, `dartclaw-review`, `dartclaw-remediate-findings`, `dartclaw-quick-review`, `dartclaw-architecture`, and `dartclaw-refactor` become `andthen:<name>`. Leave `dartclaw-discover-project` and `dartclaw-merge-resolve` exact.
  - Do not introduce `andthen:ops` or migrate `dartclaw-ops`; current built-ins do not contain that step, and DartClaw has no ported `andthen:ops` equivalent.
  - **Verify**: `rg "skill: dartclaw-(prd|plan|spec|exec-spec|review|remediate-findings|quick-review|architecture|refactor|ops)" packages/dartclaw_workflow/lib/src/workflow/definitions` returns zero; `rg "skill: dartclaw-(discover-project|merge-resolve)" ...` still finds the DC-native references.

- [x] **TI04** Remove AndThen-derived `dartclaw-*` provisioning and narrow provisioning/linking to DC-native skills only.
  - Stop cloning AndThen and running `install-skills.sh --prefix dartclaw- --display-brand DartClaw` for workflow startup. Retain only the copy/link behavior needed to expose `dcNativeSkillNames` to project/worktree native skill roots.
  - **Verify**: Tests prove fresh bootstrap creates `dartclaw-discover-project`, `dartclaw-validate-workflow`, and `dartclaw-merge-resolve`, but does not create `dartclaw-prd`, `dartclaw-spec`, or `dartclaw-review` in data-dir or workspace skill roots.

- [x] **TI05** Retire the active `andthen.*` source/provisioning config surface.
  - Remove active config fields and UI/serialization metadata for `andthen.git_url`, `andthen.ref`, `andthen.network`, and `andthen.source_cache_dir`. Legacy YAML keys may be accepted only to emit warnings that DartClaw no longer provisions AndThen.
  - Remove or rewrite tests that assert active AndThen source-cache behavior; keep only compatibility-warning coverage if legacy parsing remains.
  - **Verify**: `rg "andthen\\.(git_url|ref|network|source_cache_dir)|AndthenConfig|AndthenNetworkPolicy" packages apps docs dev/state/STACK.md` returns no active-contract references except explicitly marked legacy warnings or removed-code migration notes.

- [x] **TI06** Replace standalone missing-skill preflight with provider-aware diagnostics.
  - `_missingNativeSkillInstalls` and related CLI validation should search aliases through the registry resolver and report canonical/alias/provider triples.
  - **Verify**: CLI tests for missing `andthen:exec-spec` under Codex assert the error mentions `andthen:exec-spec`, `codex`, and `andthen-exec-spec`, and does not mention restarting the old `dartclaw-*` provisioner.

- [x] **TI07** Replace runtime hardcoded exact-name checks for AndThen-derived skills.
  - Update artifact-producing skill detection, artifact commit classification, skill default lookup, resolved-definition emission, and any prompt/dispatch special cases that currently key on `dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`, `dartclaw-review`, `dartclaw-architecture`, or `dartclaw-remediate-findings`.
  - Preserve exact-name checks for DC-native skills where they are intentionally special, especially `dartclaw-discover-project` and `dartclaw-merge-resolve`.
  - **Verify**: `rg "dartclaw-(prd|plan|spec|exec-spec|review|remediate-findings|quick-review|architecture|refactor|ops)" packages/dartclaw_workflow/lib/src apps/dartclaw_cli/lib` returns no active runtime checks except explicitly marked legacy diagnostics or manual cleanup text.

- [x] **TI08** Update registry/listing surfaces so users can see canonical references and concrete provider names without extra config.
  - UI/API listing may show discovered concrete names, but validation messages and built-in workflow resolved output should show canonical `andthen:<name>` where authored.
  - **Verify**: `workflow show --resolved` for a built-in workflow displays `skill: andthen:spec` in the definition and does not rewrite the YAML to `andthen-spec`.

- [x] **TI09** Update tests and fixtures that stage or expect DartClaw-branded AndThen skills.
  - Rewrite fake installers/fixtures in `server_builder_integration_test.dart`, `cli_workflow_wiring_test.dart`, `service_wiring_andthen_skills_test.dart`, built-in inventory tests, and workflow contract tests to stage `andthen-*` for Codex and `andthen:*` for Claude where needed.
  - **Verify**: `dart test packages/dartclaw_workflow/test/workflow/skill_registry_impl_test.dart packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart apps/dartclaw_cli/test/commands/service_wiring_andthen_skills_test.dart` passes.

- [x] **TI10** Rewrite user-facing docs and agent guidance.
  - Update `docs/guide/andthen-skills.md`, `docs/guide/workflows.md`, root `AGENTS.md` / `CLAUDE.md`, and `packages/dartclaw_workflow/AGENTS.md` to describe canonical `andthen:<name>` references, provider aliases, and DC-native skill provisioning only.
  - **Verify**: `rg "AndThen-derived .*dartclaw|dartclaw-(prd|plan|spec|exec-spec|review|remediate-findings|quick-review|architecture|refactor|ops)" AGENTS.md CLAUDE.md docs packages/dartclaw_workflow/AGENTS.md` returns no stale claims except historical migration/manual-cleanup notes explicitly marked as legacy.

- [x] **TI11** Run focused validation gates for the touched surface.
  - Use package-scoped tests first; broaden only if failures suggest cross-package breakage.
  - **Verify**: `dart format --set-exit-if-changed packages/dartclaw_models packages/dartclaw_core packages/dartclaw_config packages/dartclaw_workflow packages/dartclaw_server apps/dartclaw_cli`; `dart analyze --fatal-warnings --fatal-infos`; focused tests from TI09; then any impacted CLI/server wiring tests.

### Testing Strategy

- [TI01] Scenario: Codex Resolves Canonical AndThen Skill -> registry unit test with discovered `andthen-spec`.
- [TI01] Scenario: Claude Code Resolves Canonical AndThen Skill -> registry unit test with discovered `andthen:review`.
- [TI02] Scenario: Role Defaults Drive Provider Alias Resolution -> validator test using `@planner` role defaults for Codex and Claude.
- [TI02] Scenarios: Codex/Claude prompt activation -> prompt-builder tests asserting `$andthen-spec` and `/andthen:spec`, plus Codex default prompt/output lookup through `andthen-spec`.
- [TI03, TI09] Scenario: DartClaw-Native Skills Stay Exact -> built-in workflow contract test keeps `dartclaw-discover-project`.
- [TI04] Scenario: No DartClaw-Ported AndThen Payloads Are Created -> skill provisioning/linker tests assert absence of `dartclaw-prd`, `dartclaw-spec`, `dartclaw-review`.
- [TI05] Scenario: Retired AndThen Config Does Not Advertise Active Settings -> config/parser/serializer tests assert no active `andthen.*` output, with legacy-warning coverage only if accepted.
- [TI06] Scenario: Missing AndThen Install Produces Actionable Error -> CLI workflow validate/run preflight test.
- [TI07] Scenario: Runtime Hardcoded Skill Names Removed -> artifact-producer, artifact-commit, resolved-definition, and default-lookup tests use canonical `andthen:<name>` inputs.

### Validation

- Run the focused package tests named in TI09 before any broad workspace test.
- Re-run `rg "dartclaw-(prd|plan|spec|exec-spec|review|remediate-findings|quick-review|architecture|refactor|ops)"` across workflow definitions, runtime code, and docs to catch stale active names.
- Re-run `rg "andthen\\.(git_url|ref|network|source_cache_dir)|AndthenConfig|AndthenNetworkPolicy" packages apps docs dev/state/STACK.md` to catch retired active config surfaces.

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (canonical names, provider aliases, and diagnostic fields) are exact - implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, architectural advice, UX/UI guidance, build troubleshooting, research - spawn in background when possible and do not block progress unnecessarily.
- After all tasks: run the applicable project validation gates for the feature - build/tests/lint-analysis where those checks exist and are relevant - and keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately upon completion - do not batch.


## Final Validation Checklist

- [x] **All success criteria** met
- [x] **All tasks** fully completed, verified, and checkboxes checked
- [x] **No regressions** or breaking changes introduced beyond the scoped removal of DartClaw-branded AndThen provisioning
- [x] **Docs and agent guidance** updated to the new naming contract


## Implementation Observations

> _Managed by exec-spec post-implementation - append-only. Tag semantics: see [`data-contract.md`](${CLAUDE_PLUGIN_ROOT}/references/data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](${CLAUDE_PLUGIN_ROOT}/references/automation-mode.md). Spec authors: leave this section empty._

Discovered Requirements entries use this shape:

- **Title**: short imperative phrase
- **Description**: 1-2 sentences on the discovered requirement
- **Rationale**: why it was missed in original spec
- **Interpretation** (AUTO_MODE only): the conservative interpretation chosen and why
- **Traced from**: task ID where the discovery occurred
- **Date**: YYYY-MM-DD

_No observations recorded yet._
