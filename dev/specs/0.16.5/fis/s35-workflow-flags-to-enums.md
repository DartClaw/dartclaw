# Feature Implementation Specification — S35: Stringly-typed Workflow Flags → Enums

**Plan**: ../plan.md
**Story-ID**: S35

## Feature Overview and Goal

Replace four stringly-typed workflow public flags with proper Dart enums backed by `fromJsonString(String)` factories that throw `FormatException` listing valid values, plus `name`-based wire emission. Introduces enums on existing field names — S38 owns the `type` → `taskType` rename. JSON wire format stays byte-compatible.

> **Technical Research**: [.technical-research.md](../.technical-research.md) (S35 entry, Shared Decision #8 §8 ordering, binding constraints rows #1, #2, #53, #56, #71, #75)


## Required Context

> Cross-doc reference rules: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#cross-document-references).

> **Wave-internal ordering (added 2026-05-05 per cross-cutting review F4)**: S22 lands before S35 within W5. After S22, `WorkflowDefinition` and `WorkflowStep` live in `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart`. S35 enum-types the field at the post-S22 location. If S35 runs before S22 (unexpected wave-ordering deviation), `BLOCKED: S22 prerequisite not yet landed` and stop.

### From `dev/specs/0.16.5/plan.md` — "S35 Scope + Acceptance Criteria"
<!-- source: dev/specs/0.16.5/plan.md#p-s35-stringly-typed-workflow-flags--enums -->
<!-- extracted: e670c471721a128e77b039d4362a68d8e269598a -->
> **Scope**: Replace four stringly-typed public flags with proper enums + `fromJsonString` factories that throw `FormatException` naming the valid values. Keep JSON serialization unchanged via `toJson()/fromJson()` that returns/accepts the same strings. (a) `WorkflowStep.type: String` at `workflow_definition.dart:471` — introduce `WorkflowTaskType` enum and type the existing `type` field with it; S38 depends on this story and owns the later field rename to `taskType`. (b) `WorkflowGitExternalArtifactMount.mode` at `:806` (`'per-story-copy' | 'bind-mount'`) → `WorkflowExternalArtifactMountMode` enum. (c) `WorkflowGitWorktreeStrategy.mode` at `:869` (`'shared' | 'per-task' | 'per-map-item' | 'inline' | 'auto'`) → `WorkflowGitWorktreeMode` enum. (d) `TaskExecutor.identifierPreservation = 'strict'` → `IdentifierPreservationMode` enum (values TBD during implementation — likely `strict | lenient | off`). Reader impact: valid values become IDE-discoverable via autocomplete; typos become compile errors. Don't enum-ify `chat_card_builder.dart:338-380` status switches — those operate on Google Chat wire values already owned by upstream.
>
> **Acceptance Criteria**:
> - Four enums exist in their owning packages (`WorkflowTaskType` + `WorkflowExternalArtifactMountMode` + `WorkflowGitWorktreeMode` in `dartclaw_workflow`; `IdentifierPreservationMode` in `dartclaw_core` or `dartclaw_server`)
> - Each enum has a `fromJsonString(String)` factory that throws `FormatException` listing valid values for unknown input
> - Each enum has a `toJson()` / `name` getter returning the exact wire string
> - `WorkflowStep.type` remains the field name in S35 and is typed `WorkflowTaskType`; S38 owns the follow-up rename to `taskType`
> - YAML parser and validator use the enum-typed fields; JSON wire format is byte-compatible with the prior String representation
> - `dart analyze` and `dart test` workspace-wide pass
> - Changelog notes the internal type change (not a breaking wire change)
>
> **Key Scenarios**:
> - Happy: YAML says `mode: per-task` → parser resolves to `WorkflowGitWorktreeMode.perTask`; re-emitted YAML round-trips byte-identical
> - Edge: YAML says `mode: typo-value` → parser raises `FormatException` listing all valid values in the error message
> - Boundary: existing resolved-YAML baselines round-trip identically; new enum doesn't leak into public JSON responses

### From `dev/specs/0.16.5/.technical-research.md` — "Shared Decision #8 — S35 → S38 Enum then field-rename ordering"
<!-- source: dev/specs/0.16.5/.technical-research.md#shared-decisions -->
<!-- extracted: e670c471721a128e77b039d4362a68d8e269598a -->
> **8. S35 → S38 — Enum then field-rename ordering**
> - WHAT: S35 introduces `WorkflowTaskType` enum and types existing `WorkflowStep.type` field with it (field name unchanged); `fromJsonString(String)` factory throws `FormatException`; JSON wire format byte-compatible. S38 renames field `type` → `taskType`, deprecates old field via `@Deprecated('Use taskType')`.
> - PRODUCER: S35.
> - CONSUMER: S38.
> - WHY: Two-phase to avoid simultaneous rename+retype churn.

### From `dev/specs/0.16.5/prd.md` — "Binding PRD Constraints (rows #1, #2, #53, #56, #71, #75)"
<!-- source: dev/specs/0.16.5/.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c471721a128e77b039d4362a68d8e269598a -->
> - **#1** "JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged." (prd.md#out-of-scope)
> - **#2** "No new dependencies in any package." (prd.md#constraints)
> - **#53** "Enums for stringly-typed flags: `WorkflowTaskType`, `WorkflowExternalArtifactMountMode`, `WorkflowGitWorktreeMode`, `IdentifierPreservationMode` — each with `fromJsonString(String)` factory throwing `FormatException`; JSON wire format byte-compatible." (prd.md#fr10)
> - **#56** "Stringly-typed-flag enum factories throw `FormatException` listing all valid values on unknown input." (prd.md#fr10 Error Handling)
> - **#71** "Behavioural regressions post-decomposition: Zero — every existing test remains green." (prd.md#non-functional-requirements)
> - **#75** Re-applied here as: `dart analyze` workspace-wide 0 warnings (NFR DX, row #73).


## Success Criteria (Must Be TRUE)

- [ ] `WorkflowTaskType` enum exists with values for `agent`, `bash`, `approval`, `foreach`, `loop` and exact wire-string `name` getters (must-be-TRUE)
- [ ] `WorkflowExternalArtifactMountMode` enum exists with values for `per-story-copy`, `bind-mount` (Dart names: `perStoryCopy`, `bindMount`); wire strings preserved via overridden mapping (must-be-TRUE)
- [ ] `WorkflowGitWorktreeMode` enum exists with values for `shared`, `per-task`, `per-map-item`, `inline`, `auto` (Dart names with kebab→camelCase mapping); wire strings preserved (must-be-TRUE)
- [ ] `IdentifierPreservationMode` enum exists with values `strict`, `off`, `custom` (matches the three values already accepted by `BehaviorFileService` and `ContextConfig`) and exact wire-string `name` getters (must-be-TRUE)
- [ ] Each of the four enums exposes `static <Enum> fromJsonString(String value)` that throws `FormatException` whose message lists every valid wire-string value when input does not match (must-be-TRUE)
- [ ] Each of the four enums exposes a `toJson()` (or equivalent `String get wireName` / `name` reuse) returning the exact wire string used today (must-be-TRUE)
- [ ] `WorkflowStep.type` keeps its current field name (no rename); the field type changes from `String` to `WorkflowTaskType` (must-be-TRUE — S38 owns the rename)
- [ ] `WorkflowGitExternalArtifactMount.mode` is typed `WorkflowExternalArtifactMountMode`; `WorkflowGitWorktreeStrategy.mode` is typed `WorkflowGitWorktreeMode?`; `TaskExecutor.identifierPreservation` (and the matching `BehaviorFileService.identifierPreservation` + `ContextConfig.identifierPreservation`) is typed `IdentifierPreservationMode` (must-be-TRUE)
- [ ] `WorkflowDefinitionParser` and the validators consume the enum-typed fields directly (no parallel string copies) and surface invalid inputs through the existing `FormatException` / validator error paths (must-be-TRUE)
- [ ] JSON wire format byte-compatible with the prior `String` representation: `toJson()` of `WorkflowStep` / `WorkflowGitExternalArtifactMount` / `WorkflowGitWorktreeStrategy` produces the same `Map<String, dynamic>` content for every previously-valid input (must-be-TRUE — see Scenarios)
- [ ] `effectiveWorktreeMode(...)` continues to return the same wire-string-shaped result it returns today (callers that are wire-string-coupled keep working until S38 widens the contract) (must-be-TRUE)
- [ ] `CHANGELOG.md` "0.16.5" entry has a single line under non-breaking changes noting the internal type tightening with explicit "wire format unchanged" call-out (must-be-TRUE)
- [ ] `dart format --set-exit-if-changed packages apps` clean for changed files
- [ ] `dart analyze --fatal-warnings --fatal-infos` workspace-wide passes
- [ ] `dart test` workspace-wide passes (no regressions in workflow parser/validator/executor or behavior-service suites)

### Health Metrics (Must NOT Regress)
- [ ] All existing `workflow_definition_parser_test.dart`, `workflow_definition_validator_test.dart`, `behavior_file_service_test.dart`, and config-parser tests continue to pass without modification beyond enum-value substitutions
- [ ] No new package dependencies (binding #2)
- [ ] JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged (binding #1)
- [ ] Resolved YAML baselines (e.g. fixture files under `packages/dartclaw_workflow/test/.../fixtures/`) round-trip byte-identically
- [ ] `WorkflowStep`, `WorkflowGitExternalArtifactMount`, `WorkflowGitWorktreeStrategy` `toJson()` output unchanged for previously-valid inputs


## Scenarios

> Scenarios as Proof-of-Work: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#scenarios-and-proof-of-work).

### Happy: Worktree mode parses to enum and round-trips byte-identically
- **Given** a workflow YAML containing `gitStrategy: { worktree: { mode: per-task } }`
- **When** `WorkflowDefinitionParser.parse(...)` runs and the resulting `WorkflowDefinition` is re-serialised via `toJson()`
- **Then** the parsed `WorkflowGitWorktreeStrategy.mode` equals `WorkflowGitWorktreeMode.perTask` AND `toJsonValue()` emits `'per-task'` (string), so a YAML round-trip via the existing emitter produces byte-identical output to the input fixture

### Happy: WorkflowStep.type carries enum value through parser and validator
- **Given** a YAML step with `type: bash` and a single string `prompt`
- **When** `WorkflowDefinitionParser.parse(...)` and `WorkflowDefinitionValidator.validate(...)` run
- **Then** the parsed `WorkflowStep.type` equals `WorkflowTaskType.bash`, the validator's bash-step rule matches via the typed enum (no `step.type == 'bash'` string comparison required at the call site post-migration), and `toJson()` includes `'type': 'bash'` byte-identical with today

### Edge: Unknown worktree mode raises FormatException listing valid values
- **Given** a workflow YAML containing `gitStrategy: { worktree: { mode: typo-value } }`
- **When** `WorkflowDefinitionParser.parse(...)` runs
- **Then** parsing raises a `FormatException` whose message names the offending value `typo-value` AND enumerates every valid `WorkflowGitWorktreeMode` wire string (`shared`, `per-task`, `per-map-item`, `inline`, `auto`)

### Edge: Unknown identifier-preservation value raises FormatException listing valid values
- **Given** a `dartclaw.yaml` containing `context: { identifier_preservation: bogus }`
- **When** the config parser feeds the value into `IdentifierPreservationMode.fromJsonString('bogus')`
- **Then** `FormatException` is thrown listing `strict`, `off`, `custom`; the existing config-parser warning path (currently a `warns.add(...)` that falls back to default `strict`) continues to behave the same from the user's perspective (warning logged, default applied) — the exception is caught at the parser boundary and translated to the warning, preserving binding #71

### Boundary: External-artifact-mount mode round-trips both wire values
- **Given** two YAML inputs respectively setting `gitStrategy.worktree.externalArtifactMount.mode` to `per-story-copy` and `bind-mount`
- **When** each parses, then re-serialises via `WorkflowGitExternalArtifactMount.toJson()`
- **Then** the parsed `mode` is `WorkflowExternalArtifactMountMode.perStoryCopy` and `.bindMount` respectively AND `toJson()['mode']` returns the original kebab-case wire string in both cases

### Boundary: Existing resolved-YAML baselines and JSON envelopes unchanged
- **Given** every workflow definition fixture and SSE/REST payload sample committed in the repo today
- **When** S35 lands and the relevant tests/round-trip assertions run
- **Then** every fixture parses and re-serialises with byte-identical output AND no JSON envelope test (workflow REST routes, SSE serialization) needs adjustment — no enum value names leak into public JSON


## Scope & Boundaries

### In Scope
_Every scope item is covered by a scenario or a task with a behavioral Verify line._
- Define four enums (`WorkflowTaskType`, `WorkflowExternalArtifactMountMode`, `WorkflowGitWorktreeMode`, `IdentifierPreservationMode`) with `fromJsonString` + wire-string emission
- Type the four target fields on `WorkflowStep`, `WorkflowGitExternalArtifactMount`, `WorkflowGitWorktreeStrategy`, and `TaskExecutor`/`BehaviorFileService`/`ContextConfig` (the four shared `identifierPreservation` carriers)
- Update `WorkflowDefinitionParser` and `WorkflowDefinitionValidator` to use enum-typed fields end-to-end
- Update `dartclaw_config/config_parser.dart` `_parseContext` so `identifier_preservation` parsing uses `IdentifierPreservationMode.fromJsonString(...)`, mapped onto the existing warns/default-to-strict behaviour
- Update `BehaviorFileService.composeSystemPrompt` `switch` over `identifierPreservation` to switch over the enum (compiler-exhaustive)
- Verify byte-stable JSON for all three model classes plus resolved-YAML baseline round-trip
- CHANGELOG entry under 0.16.5 noting the internal type change with explicit "JSON wire format unchanged"

### What We're NOT Doing
- **Field rename `WorkflowStep.type` → `taskType`** — S38 owns this; doing it here doubles diff churn and breaks Shared Decision #8's two-phase ordering.
- **Enum-ifying `chat_card_builder.dart:338-380` status switches** — those values are owned by Google Chat upstream wire format; not under our control.
- **Adding more enums beyond the four named** — scope is fixed by binding constraint #53 and PRD FR10. No drive-by enum-ification of other stringly-typed fields.
- **Changing wire format** — binding #1 forbids it; enum `name` getters MUST emit the exact strings the wire uses today (including kebab-case for worktree/mount modes).
- **Repository / persisted-state schema changes** — `WorkflowRun`, persisted execution rows, etc. are out of scope.

### Agent Decision Authority
- **Autonomous**:
  - Owning package for `IdentifierPreservationMode` — research notes "core or server"; if `BehaviorFileService` (server) is the only consumer post-migration, place in `dartclaw_server`. If `ContextConfig` (config) needs to type the field too, the enum must live somewhere `dartclaw_config` can reach. **Default decision**: place `IdentifierPreservationMode` in `dartclaw_config` (the lowest package that needs it; `BehaviorFileService` already imports `dartclaw_core` types and the symbol can flow up via standard barrel exports).
  - Wire-string emission technique per enum — either override `toString` / add a `String get wireName` / use a `switch` in `toJson()`. Whichever keeps the four enums uniform and reads cleanly.
  - Whether `WorkflowGitWorktreeStrategy.mode` becomes nullable enum (`WorkflowGitWorktreeMode?`) or retains a sentinel "absent" representation — current type is `String?`, so default to `WorkflowGitWorktreeMode?`.
- **Escalate**: none expected. If a fixture round-trip fails byte-identically, stop and report rather than mutating fixtures.


## Architecture Decision

**We will**: Type the existing field name (`WorkflowStep.type`, not `taskType`) with a new `WorkflowTaskType` enum, plus the three sibling enums. S38 owns the later rename to `taskType` — Two-phase enum-then-rename ordering avoids simultaneous rename+retype churn (over a single big-bang change). Each enum exposes `fromJsonString(String)` throwing `FormatException` listing all valid values, and emits exact wire strings via `name` (where the Dart-name and wire-string match) or via an explicit `toJson()` switch (where they differ — kebab-case worktree/mount modes). JSON wire format stays byte-compatible per binding #1.

**Pattern reference**: An existing precedent lives in `packages/dartclaw_models/lib/src/workflow_definition.dart:914-928` — `MergeResolveEscalation` enum with `tryParse(...)` + `toYamlString()`. S35's enums use a stricter contract (throw vs `null`-on-unknown) per acceptance criterion + binding #56, but the dual-mapping shape (enum value ↔ kebab wire string) is the same.


## Technical Overview

### Data Models

Four new enums plus four typed fields:

- **`WorkflowTaskType`** in `packages/dartclaw_workflow/lib/src/workflow/workflow_task_type.dart` (or co-located in `workflow_definition.dart` once S22 migrates the model — but S22 has not landed yet at S35 time, so place in `dartclaw_models` next to `WorkflowStep` to avoid a cross-package field-type cycle). Values: `agent`, `bash`, `approval`, `foreach`, `loop`. Wire-string == enum `name` for all five — `name` getter is sufficient; `toJson()` returns `name`.
- **`WorkflowExternalArtifactMountMode`** alongside `WorkflowGitExternalArtifactMount`. Values: `perStoryCopy` (wire `per-story-copy`), `bindMount` (wire `bind-mount`). Needs an explicit `toJson()` switch since Dart `name` emits camelCase.
- **`WorkflowGitWorktreeMode`** alongside `WorkflowGitWorktreeStrategy`. Values: `shared` (wire `shared`), `perTask` (wire `per-task`), `perMapItem` (wire `per-map-item`), `inline` (wire `inline`), `auto` (wire `auto`). Mixed; explicit `toJson()` switch.
- **`IdentifierPreservationMode`** in `dartclaw_config` (so `ContextConfig.identifierPreservation` can be typed without lifting the field's home package). Values: `strict`, `off`, `custom` — wire-string == enum `name`; `toJson()` returns `name`.

**Owning-package note**: `WorkflowStep`, `WorkflowGitExternalArtifactMount`, and `WorkflowGitWorktreeStrategy` currently live in `dartclaw_models/lib/src/workflow_definition.dart` (S22 will move them later). S35 places `WorkflowTaskType`, `WorkflowExternalArtifactMountMode`, `WorkflowGitWorktreeMode` co-located with the model in `dartclaw_models` for now — this is wire-format-neutral; S22 carries them along when the model moves to `dartclaw_workflow`. Plan acceptance criterion text says "in `dartclaw_workflow`" — this is forward-looking phrasing; placing in `dartclaw_models` today and migrating with the host model in S22 satisfies the same intent without breaking package-boundary rules. **Document this nuance in the FIS NOT-doing list (above) and in the CHANGELOG note.**

### Integration Points
- `WorkflowDefinitionParser._parseSteps` (line ~306) reads `raw['type'] as String?`; replace with `WorkflowTaskType.fromJsonString(raw['type'] as String? ?? 'agent')` and assign the enum to `WorkflowStep.type`.
- `WorkflowDefinitionParser._parseExternalArtifactMount` (line ~742) currently `throw FormatException(...)` on unknown mode; replace with `WorkflowExternalArtifactMountMode.fromJsonString(mode)` (factory throws the same kind of `FormatException`, consolidating the listing of valid values).
- `WorkflowDefinitionParser._parseGitStrategy` worktree path (line ~683): `mode: worktreeRaw['mode'] as String?` → `mode: rawMode == null ? null : WorkflowGitWorktreeMode.fromJsonString(rawMode)`.
- `WorkflowDefinitionValidator.workflow_step_type_rules.dart` (line ~91): `_knownTypes` set becomes redundant — exhaustiveness now lives in the enum. Adjust the validator to compare enum values directly; preserve the existing user-facing error message ("Step ... uses removed step type ...") only for the `removedAgentStepMarker = 'custom'` legacy hint, which fires when the parser raises `FormatException`. Wrap the parser call so the legacy `'custom'` value gets the rename hint before the FormatException bubbles up.
- `WorkflowGitStrategy.effectiveWorktreeMode(...)` (line ~1085): callers consume a `String`; adapt return type by either keeping `String` and calling `mode?.toJson()` internally, OR widening to `WorkflowGitWorktreeMode?` if the call sites tolerate it. Default to keeping `String` return signature for S35 to minimize blast radius.
- `BehaviorFileService.composeSystemPrompt`'s `switch (identifierPreservation)` (line ~124) becomes exhaustive over the enum.
- `dartclaw_config/config_parser.dart:846-862` `_parseContext` uses `IdentifierPreservationMode.fromJsonString(ipRaw)` inside try/catch; on `FormatException` add to `warns` (existing pattern) and fall back to default `strict`. The user-facing warning text must continue to list valid values.


## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_models/lib/src/workflow_definition.dart:471 | WorkflowStep.type — target field for WorkflowTaskType
file   | packages/dartclaw_models/lib/src/workflow_definition.dart:825-871 | WorkflowGitExternalArtifactMount — target for WorkflowExternalArtifactMountMode
file   | packages/dartclaw_models/lib/src/workflow_definition.dart:994-1024 | WorkflowGitWorktreeStrategy — target for WorkflowGitWorktreeMode
file   | packages/dartclaw_models/lib/src/workflow_definition.dart:914-928 | MergeResolveEscalation — existing enum + dual-mapping pattern (tryParse/toYamlString); S35 uses a strict variant (throw on unknown)
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart:305-355 | step type parsing (raw['type'] read)
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart:683-756 | git-strategy worktree + external-artifact-mount parsing
file   | packages/dartclaw_workflow/lib/src/workflow/validation/workflow_step_type_rules.dart:91-115 | _knownTypes set + step.type usage in validator
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition_validator.dart | Top-level validator entry; check no other string compare on step.type left after migration
file   | packages/dartclaw_server/lib/src/behavior/behavior_file_service.dart:43-128 | identifierPreservation field + switch in composeSystemPrompt
file   | packages/dartclaw_server/lib/src/task/task_executor.dart:61,89,120,611,620 | TaskExecutor.identifierPreservation (ctor param + field + pass-through to BehaviorFileService)
file   | packages/dartclaw_config/lib/src/context_config.dart:15-27 | ContextConfig.identifierPreservation field
file   | packages/dartclaw_config/lib/src/config_parser.dart:803-862 | identifier_preservation parsing + warns fallback
file   | apps/dartclaw_cli/lib/src/commands/wiring/{harness,task}_wiring.dart, service_wiring.dart, workflow/cli_workflow_wiring.dart | identifierPreservation pass-through call sites (5 sites)
file   | packages/dartclaw_models/lib/src/session_key.dart:27 | Existing FormatException pattern (concise message format)
```


## Constraints & Gotchas

- **Constraint (binding #1)**: JSON wire format byte-compatible — enum emission MUST equal the exact wire strings used today (kebab-case for `per-task`, `per-map-item`, `per-story-copy`, `bind-mount`). Use explicit `toJson()` switch where Dart `name` would diverge.
- **Constraint (binding #2)**: No new dependencies. Stick to existing `package:meta` / core libraries.
- **Avoid**: Adding `taskType` field on `WorkflowStep` — S38 owns that rename. Touching the field name in S35 invalidates Shared Decision #8.
- **Avoid**: Enum-ifying `chat_card_builder.dart:338-380` Google Chat status switches — upstream-owned wire values.
- **Critical**: `WorkflowGitWorktreeStrategy.toJsonValue()` (line ~1004) returns either `null`, the bare `mode` string, or a map; preserve this asymmetric shape (the wire compatibility test hinges on it) — convert internally via `mode?.toJson()` or equivalent.
- **Critical**: `WorkflowDefinitionValidator._knownTypes` (line ~91) becomes redundant once `WorkflowStep.type` is enum-typed. The validator's user-facing error path for the legacy `removedAgentStepMarker = 'custom'` value must still trigger — wrap the parser's `WorkflowTaskType.fromJsonString('custom')` call to detect this specific input and surface the existing rename hint before/instead of the bare `FormatException`.
- **Critical**: `_parseContext` warning path in `dartclaw_config/config_parser.dart:846-862` — preserve the existing UX (warning logged, default-to-strict, no exception bubbling to user) per binding #71. The enum factory throws but the parser catches at the boundary.
- **Gotcha**: `dartclaw_models` dep policy says no `dartclaw_*` cross-imports. Placing `IdentifierPreservationMode` in `dartclaw_config` is fine because `dartclaw_models` does not consume it; the `ContextConfig` field lives in `dartclaw_config` already. Do not place this enum in `dartclaw_models`.
- **Gotcha**: External-artifact-mount mode default is `'per-story-copy'` (literal at `workflow_definition.dart:847`); this becomes `WorkflowExternalArtifactMountMode.perStoryCopy` as the constructor default — keep the default identical so omitted-mode YAMLs still parse to the same value.


## Implementation Plan

> **Vertical slice ordering**: First task lands `WorkflowTaskType` end-to-end (enum + field type + parser + validator) so the slice is provably wired before adding the other three enums.

### Implementation Tasks

- [ ] **TI01** `WorkflowTaskType` enum exists with `fromJsonString` (throws `FormatException` listing valid values) and wire-string emission
  - Place in `packages/dartclaw_models/lib/src/workflow_task_type.dart` (or co-locate in `workflow_definition.dart` if smaller); export from `dartclaw_models.dart` barrel. Pattern: see `MergeResolveEscalation` at `workflow_definition.dart:914-928` but throw vs return-null on unknown. Values: `agent, bash, approval, foreach, loop` — Dart `name` matches wire string, so `String toJson() => name` is sufficient.
  - **Verify**: Test asserts `WorkflowTaskType.fromJsonString('bash') == WorkflowTaskType.bash`; `WorkflowTaskType.fromJsonString('xyz')` throws `FormatException` whose message contains every wire string `agent`, `bash`, `approval`, `foreach`, `loop`; `WorkflowTaskType.bash.toJson() == 'bash'`.

- [ ] **TI02** `WorkflowStep.type` field is typed `WorkflowTaskType` (field name unchanged)
  - Edit `packages/dartclaw_models/lib/src/workflow_definition.dart:471-477`. Update constructor, `copyWith`, `toJson` (`'type': type.toJson()`), `fromJson` (`type: WorkflowTaskType.fromJsonString(json['type'] as String)`). DO NOT rename to `taskType` (S38 owns that). Update `WorkflowStep` dartdoc.
  - **Verify**: `WorkflowStep(type: WorkflowTaskType.bash, ...).toJson()['type'] == 'bash'`; `WorkflowStep.fromJson({...'type': 'agent'}).type == WorkflowTaskType.agent`; round-trip on a fixture step with `type: foreach` re-emits `'type': 'foreach'`.

- [ ] **TI03** `WorkflowDefinitionParser` step parsing uses `WorkflowTaskType` end-to-end
  - Edit `packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart:305-355`. Replace `final stepType = (raw['type'] as String?) ?? 'agent';` with enum resolution; pass enum to `WorkflowStep(type: ...)`. Wrap `WorkflowTaskType.fromJsonString(...)` so the legacy value `'custom'` (the `removedAgentStepMarker`) gets translated into a `FormatException` whose message matches the existing rename-hint user-facing wording at `workflow_step_type_rules.dart:101-115`.
  - **Verify**: Existing parser tests pass; new test asserts YAML with `type: typo` raises `FormatException` listing `agent, bash, approval, foreach, loop`; YAML with `type: custom` raises `FormatException` whose message includes the rename hint substring "agent-step marker has been renamed".

- [ ] **TI04** `WorkflowDefinitionValidator` consumes enum-typed `step.type`
  - Edit `packages/dartclaw_workflow/lib/src/workflow/validation/workflow_step_type_rules.dart` and any siblings (`workflow_structure_rules.dart` lines ~277-281, plus `step_dispatcher.dart`, `step_config_policy.dart`, `bash_step_runner.dart`, `approval_step_runner.dart`, `workflow_definition_resolver.dart`, `workflow_task_factory.dart`, `public_step_dispatcher_helpers.dart`). Replace every `step.type == 'bash'` style comparison with `step.type == WorkflowTaskType.bash`. Drop `_knownTypes` set in `workflow_definition_validator.dart` (now exhaustive via enum). Where the validator emits user-facing strings, render via `.toJson()`.
  - **Verify**: `dart analyze` clean across `packages/dartclaw_workflow`; existing validator tests pass without fixture changes; `rg "step\.type\s*==\s*'(agent|bash|approval|foreach|loop)'" packages apps` returns empty.

- [ ] **TI05** `WorkflowExternalArtifactMountMode` enum exists with `fromJsonString` + kebab-case wire emission
  - Add enum next to `WorkflowGitExternalArtifactMount` in `packages/dartclaw_models/lib/src/workflow_definition.dart`. Values: `perStoryCopy`, `bindMount`. `String toJson() => switch (this) { perStoryCopy => 'per-story-copy', bindMount => 'bind-mount' };`. `static fromJsonString(String value) => switch (value) { 'per-story-copy' => perStoryCopy, 'bind-mount' => bindMount, _ => throw FormatException('Unknown WorkflowExternalArtifactMountMode "$value"; valid values: per-story-copy, bind-mount') };`.
  - **Verify**: `fromJsonString('per-story-copy') == perStoryCopy`; `fromJsonString('bogus')` throws `FormatException` whose message contains `per-story-copy` AND `bind-mount`; `bindMount.toJson() == 'bind-mount'`.

- [ ] **TI06** `WorkflowGitExternalArtifactMount.mode` is typed with the enum
  - Edit `packages/dartclaw_models/lib/src/workflow_definition.dart:825-871`. Update field type, default value (`mode: WorkflowExternalArtifactMountMode.perStoryCopy` — same wire string), constructor, `toJson` (`'mode': mode.toJson()`), `fromJson` (`mode: json['mode'] == null ? WorkflowExternalArtifactMountMode.perStoryCopy : WorkflowExternalArtifactMountMode.fromJsonString(json['mode'] as String)`). Update `WorkflowDefinitionParser._parseExternalArtifactMount` (`workflow_definition_parser.dart:732-756`) to use the enum factory; the existing inline mode-validity `FormatException` branch is replaced by the factory's exception (preserve the `_at(sourcePath)` source-context suffix in the rethrow if behaviour-equivalent — wrap and rethrow).
  - **Verify**: Round-trip assertion on fixture mount with `mode: bind-mount` re-emits `'mode': 'bind-mount'`; round-trip with `mode: per-story-copy` re-emits identically; YAML with `mode: typo` raises `FormatException` listing both valid values.

- [ ] **TI07** `WorkflowGitWorktreeMode` enum exists with `fromJsonString` + mixed wire emission
  - Add enum next to `WorkflowGitWorktreeStrategy` in `packages/dartclaw_models/lib/src/workflow_definition.dart`. Values: `shared`, `perTask`, `perMapItem`, `inline`, `auto`. `String toJson() => switch (this) { shared => 'shared', perTask => 'per-task', perMapItem => 'per-map-item', inline => 'inline', auto => 'auto' };`.
  - **Verify**: `fromJsonString('per-map-item') == perMapItem`; `fromJsonString('inline').toJson() == 'inline'`; `fromJsonString('typo')` throws `FormatException` listing all 5 wire strings.

- [ ] **TI08** `WorkflowGitWorktreeStrategy.mode` is typed `WorkflowGitWorktreeMode?`
  - Edit `packages/dartclaw_models/lib/src/workflow_definition.dart:994-1024`. Update field type to `WorkflowGitWorktreeMode?`. `toJsonValue()` (line ~1004) preserves the existing asymmetric shape: when only `mode` set, return `mode!.toJson()` (bare string); when map-shaped, write `'mode': mode!.toJson()`. `fromJson` switch: `String mode => WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.fromJsonString(mode))`; `Map ... mode: map['mode'] == null ? null : WorkflowGitWorktreeMode.fromJsonString(map['mode'] as String)`. Update `WorkflowDefinitionParser._parseGitStrategy` (`workflow_definition_parser.dart:683-702`) to call the enum factory (string and map branches).
  - **Verify**: Fixture round-trip on YAML `worktree: per-task` and `worktree: { mode: per-map-item }` both emit byte-identical output. `WorkflowGitStrategy.effectiveWorktreeMode(...)` continues to return `String` (call existing `.toJson()` internally) so callers that compare against literal strings keep working until S38 widens the contract.

- [ ] **TI09** `IdentifierPreservationMode` enum exists in `dartclaw_config` with `fromJsonString` + wire emission
  - Add `packages/dartclaw_config/lib/src/identifier_preservation_mode.dart`. Values: `strict`, `off`, `custom`. `String toJson() => name` (Dart name == wire string). Export from `dartclaw_config.dart` barrel with explicit `show`.
  - **Verify**: `fromJsonString('strict') == strict`; `fromJsonString('typo')` throws `FormatException` listing `strict, off, custom`; `custom.toJson() == 'custom'`.

- [ ] **TI10** `ContextConfig.identifierPreservation` typed; config_parser uses enum factory + preserves warns/default-strict UX
  - Edit `packages/dartclaw_config/lib/src/context_config.dart` field type from `String` to `IdentifierPreservationMode`; default `IdentifierPreservationMode.strict`; update `==`/`hashCode`. Edit `packages/dartclaw_config/lib/src/config_parser.dart:803-862`: replace the inline `validValues` set + manual check with `try { identifierPreservation = IdentifierPreservationMode.fromJsonString(ipRaw); } on FormatException catch (e) { warns.add('Invalid value for context.identifier_preservation: "$ipRaw" — expected one of strict, off, custom; using default "strict"'); }`. Preserve the type-mismatch branch (`else if (ipRaw != null)`) unchanged — it's about non-String values, not enum membership.
  - **Verify**: `dart test packages/dartclaw_config` passes; existing context-config test cases (string `'off'`, `'custom'`, `'strict'`) all parse to the matching enum; YAML with `identifier_preservation: bogus` triggers a warns entry whose message includes `strict, off, custom` and the resulting `ContextConfig.identifierPreservation == IdentifierPreservationMode.strict`.

- [ ] **TI11** `BehaviorFileService.identifierPreservation` typed; consumers updated
  - Edit `packages/dartclaw_server/lib/src/behavior/behavior_file_service.dart`. Field type `IdentifierPreservationMode`; default `IdentifierPreservationMode.strict`. Replace `switch (identifierPreservation) { 'strict' => ... }` (line ~124) with exhaustive enum switch. Update `packages/dartclaw_server/lib/src/task/task_executor.dart:61,89,120,611,620` (ctor param + field + pass-through). Update `packages/dartclaw_server/lib/src/config/config_serializer.dart:114` (passing enum.toJson() through the serializer).
  - **Verify**: `dart test packages/dartclaw_server` passes; `behavior_file_service_test.dart` cases for `'strict'`/`'off'`/`'custom'` adapted to enum values pass; `config_serializer` round-trip emits the exact prior wire string.

- [ ] **TI12** Five CLI/server pass-through call sites updated to enum-typed pass
  - Edit `apps/dartclaw_cli/lib/src/commands/service_wiring.dart:641`, `apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart:225`, `apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart:115`, `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:287,366,567`. Each passes `config.context.identifierPreservation` (now an enum) to its consumer; type flows transitively. Also `behavior_file_service_test.dart:240,252,261,272,283,294` test fixtures move from `'strict'`/`'off'`/`'custom'` strings to the enum values.
  - **Verify**: `dart analyze` workspace-wide clean; `rg "identifierPreservation:\s*'(strict|off|custom)'" packages apps test` returns empty.

- [ ] **TI13** `WorkflowDefinitionResolver` and other byte-stable JSON consumers verified
  - Audit `packages/dartclaw_workflow/lib/src/workflow/workflow_definition_resolver.dart:122,259-260` and `workflow_task_factory.dart:263` (`stepType: step.type`) to ensure they emit the wire string (call `.toJson()`) rather than the enum `name`. The resolved-YAML emitter at `workflow_definition_resolver.dart:259-260` builds a `MapEntry('type', step.type)` — change to `MapEntry('type', step.type.toJson())`.
  - **Verify**: Resolved-YAML baseline test under `packages/dartclaw_workflow/test/` round-trips byte-identically (run the entire `dart test packages/dartclaw_workflow` suite and inspect any `--resolved` fixture comparisons).

- [ ] **TI14** Byte-stable JSON contract assertion test
  - Add a single test (in `packages/dartclaw_models/test/workflow_definition_test.dart` or a new `workflow_enum_wire_compat_test.dart`) that constructs a `WorkflowStep` / `WorkflowGitExternalArtifactMount` / `WorkflowGitWorktreeStrategy` from each previously-valid wire-string input, calls `toJson()`, and asserts the emitted map values exactly equal the input wire strings. Cover all four enums.
  - **Verify**: Test passes; running it after TI02/TI06/TI08 confirms binding #1 (wire format unchanged) is enforced from the model layer.

- [ ] **TI15** Resolved-YAML baseline + workflow scenario round-trip verified
  - Run `dart test packages/dartclaw_workflow` (focus: parser, validator, resolver, scenario tests). Run `dart test packages/dartclaw_workflow/test/.../scenario_test_support.dart`-driven cases. Inspect any committed YAML fixture files under `test/` for parser/resolver and confirm none need editing.
  - **Verify**: `dart test packages/dartclaw_workflow` exit code 0; no fixture file modified by the change set.

- [ ] **TI16** Workspace `dart analyze` + `dart test` pass
  - Run `dart format --set-exit-if-changed packages apps` over changed files; `dart analyze --fatal-warnings --fatal-infos`; `dart test`. Address any new warnings introduced by switch exhaustiveness checks.
  - **Verify**: Three commands exit 0; `rg "step\.type\s*==\s*'" packages apps` and `rg "identifierPreservation\s*==\s*'" packages apps` both empty.

- [ ] **TI17** CHANGELOG note added under 0.16.5
  - Edit `CHANGELOG.md` `## [0.16.5]` "Internal" / "Changed (non-breaking)" subsection. Single line: "Internal: typed four workflow flags (`WorkflowStep.type`, `WorkflowGitWorktreeStrategy.mode`, `WorkflowGitExternalArtifactMount.mode`, `IdentifierPreservationMode`) as enums with `fromJsonString` factories. JSON wire format unchanged — no consumer migration required."
  - **Verify**: `rg "wire format unchanged" CHANGELOG.md` returns the new line; `rg "WorkflowTaskType" CHANGELOG.md` returns context for the entry. Entry appears under the 0.16.5 heading, not as a top-level breaking-change banner.


### Testing Strategy
> Derive test cases from the **Scenarios** section. Tag with task ID(s) the test proves.
- [TI01,TI05,TI07,TI09] Each enum's `fromJsonString` round-trip + unknown-value `FormatException` listing all valid values
- [TI03,TI06,TI08] Scenario "Worktree mode parses to enum and round-trips byte-identically" — parser + emitter test on fixture YAML covering `worktree: per-task` (string form) and `worktree: { mode: per-map-item }` (map form)
- [TI03,TI04] Scenario "WorkflowStep.type carries enum through parser and validator" — parser test covering `type: bash` and `type: agent` (default) plus validator pass for both
- [TI03,TI06,TI08] Scenarios "Unknown worktree mode raises FormatException" + "Unknown WorkflowStep.type" — error path tests
- [TI10] Scenario "Unknown identifier-preservation value raises FormatException" — config-parser test that asserts warns entry + default-strict fallback (binding #71)
- [TI06] Scenario "External-artifact-mount mode round-trips both wire values"
- [TI13,TI14,TI15] Scenario "Existing resolved-YAML baselines and JSON envelopes unchanged" — wire-compat assertion test + workflow scenario suite

### Validation
- Verify byte-stable JSON via TI14's wire-compat test plus TI15's resolved-YAML round-trip pass (binding #1)
- Verify no new dependencies via `git diff packages/*/pubspec.yaml apps/*/pubspec.yaml` returning no `dependencies:` additions

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (column names, format strings, file paths, error messages) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, architectural advice, build troubleshooting — spawn in background when possible and do not block progress unnecessarily.
- After all tasks: run `dart format --set-exit-if-changed`, `dart analyze --fatal-warnings --fatal-infos`, `dart test` workspace-wide; keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met
- [ ] **All tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** — JSON wire format byte-compatible; all workflow + config + behavior tests green
- [ ] **CHANGELOG** entry under 0.16.5 with explicit "wire format unchanged" call-out


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
