# FIS: Declarative workflow step-type rule source

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S16

> **Provenance**: deferred from 0.25 S63; moved into 0.26 by owner decision 2026-09-03. Salvage source is the branch
> `parked/s64-workflow-schema` at `a1e1bd95`, which is 2,256 files divergent from `main` – **cherry-pick the two
> commits onto a fresh branch, do not rebase**. The 0.25 PRD is the durable historical record after release
> consolidation; its anchored implementation record preserves the original S38/S63/S64 provenance.

## Feature Overview and Goal

**Intent**: What a workflow author is allowed to write is currently decided in three places that cannot see each
other — ten hand-maintained key sets in the parser, per-step-type `if` branches inline in the same parser, and
thirty imperative rule methods in the validator — so a step-type constraint can be enforced in one and silently
forgotten in another, and no consumer outside the engine (the guide, an editor, the generator the dynamic-workflows slice will
be handed) can read the accepted surface without re-deriving it from code.

**Expected Outcomes**

- [OC01] An author sees exactly the diagnostics they saw before, in the same order: every message text, error
  type, step/loop attribution and emission position is unchanged for every definition — the refactor is invisible
  from `workflow validate`, the registry and the web UI.
- [OC02] A step-type rule is decided once. The parser cannot accept a key the validator does not know about, and
  the two cannot disagree about which fields a `bash`, `approval`, `foreach`, `loop` or `aggregate-reviews` step
  may carry.
- [OC03] The complete accepted DSL surface — blocks, keys and their aliases, value kinds, enum members and
  per-step-type applicability — is readable as plain data by a consumer that neither parses nor validates, which
  is the precondition for generating the workflow JSON Schema instead of hand-maintaining it.

## Required Context

- `docs/specs/0.25/prd.md#fr11-one-workflow-runtime` – the acceptance bullet this story owns: *"Workflow validator
  becomes schema-emitting: the same rule source can emit the workflow JSON Schema … the surface 0.30's generator
  will be given."* (Quoted verbatim from the 0.25 PRD; that "0.30" is the milestone number the dynamic-workflows
  slice carried at the time.) This story produces the rule source and moves the validator onto it; **S17** does the
  emitting.
  **Scope note – the parser is included deliberately.** The plan story's scope names "the validator driving off
  it", but the keys, aliases, value kinds and enum members a JSON Schema is made of live in the parser's key sets,
  not in the validator's semantic rules; a validator-only table would hand S17 a rule source that cannot describe
  the grammar it must publish. TI03 is therefore in scope and traces to this bullet plus S17's "keep it strict"
  brief. Parse arms, coercions and normalization stay untouched — only the accepted-key and step-type-shape facts
  move.
- `docs/specs/0.25/prd.md#constraints` – Binding Constraint, verbatim: *"Workflow engine capability that 0.29/0.30
  need is preserved; engine stays framework-agnostic (ADR-041; \"no AndThen filenames in production code\"
  standing decision)."* Two obligations here: the rule source must not tighten the accepted grammar (a definition
  that loads today must still load), and it must name no skill, framework or artifact filename.
- `docs/specs/0.25/prd.md#non-functional-requirements` – the Maintainability row (docs currency in the same PR,
  per-package LOC ceilings only decrease) and the Compatibility row. This story is behaviour-preserving, so it
  has no CHANGELOG entry to write; if the executor finds itself writing one, the change has drifted.
- `docs/specs/0.25/prd.md#fr1--dead-surface-and-anti-pattern-deletions-s02-s03-s04-s38-s39` – **S38 shipped
  in 0.25.0, and it landed narrower than this FIS originally assumed.** Removed from the parser: `gate`,
  `as`/`mapAlias`, `max_items`, `setValue`, output `resolver`, `listMode`, `outputMode`, `outputExamples`,
  `gatingSeverity`, step and `stepDefaults` `maxTokens`, and inline-loop `finally`. **`onError` / `on_error`
  survived and is still an accepted authoring key** – it is in `_stepKeys` and parses into `OnErrorPolicy`
  (`packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart`,
  `workflow_definition.dart`). **The rule source must declare `onError` / `on_error`**; omitting it would make the
  emitted schema reject legal definitions. Re-declaring any of the genuinely retired keys would re-open them. S38
  also single-declares the gate condition patterns; that declaration stands as-is and is not folded into this
  table. Verify the whole delta against the parser's key sets before writing the table – do not trust this list.
- The 0.25 sibling stories that edited these files (S21 on `_outputConfigKeys` / `_outputResolverKeys` and
  `validation/workflow_output_schema_rules.dart`) have all shipped, so the wave-collision warnings in Constraints &
  Gotchas are historical. Re-read the files as they stand on `main`.
- `../dartclaw-public/dev/state/LEARNINGS.md#workflow-engine` – *"Validator file splits must preserve diagnostic
  ordering. `workflow validate` output order is observable; rule-group moves need either the original call
  sequence in the composer or golden coverage for ordering."* This story needs **both**, because a table-driven
  rule also changes emission order *within* a rule, which a composer-sequence argument does not cover.
- `../dartclaw-public/dev/state/LEARNINGS.md#testing` – *"Bound-asserting tests must enumerate the set"*: S04 and
  the Structural Criteria are proved by `unorderedEquals`/`containsAll` over the declared sets, never by
  `isNot(contains(...))`.
- `../dartclaw-public/packages/dartclaw_kernel/lib/src/config_meta.dart` plus
  `config_meta/{agent,channel,governance,server}_fields.dart` – the in-repo precedent for exactly this shape: a
  `const Map` of field metadata (type, allowed values, bounds) that the config validator reads instead of
  re-declaring bounds. (`dartclaw_config` was deleted in 0.25 by ADR-056; the registry moved to `dartclaw_kernel`.)
  Follow its structure and its const-data discipline. **The closer precedent is
  `../dartclaw-public/packages/dartclaw_kernel/lib/src/config_meta/json_schema.dart`** – the emitter that 0.25 S54
  shipped, which turns that same metadata into `schemas/dartclaw.schema.json`. It is the shape S17 will mirror, so
  the rule source this story produces should be structured to make that emitter's job the same job.
- `../dartclaw-public/packages/dartclaw_workflow/CLAUDE.md#conventions` – *"New validator rules: add as a sibling
  file under `lib/src/workflow/validation/`; do not expand `WorkflowDefinitionValidator`."* The rule source is a
  declaration, not a rule file; the convention needs a line saying where DSL facts are declared now, amended in
  this PR rather than left contradicting the code.

## Deeper Context

- `../dartclaw-public/dev/architecture/workflow-architecture.md#18-parser-contract` and `#19-validation-semantics`
  – the documented parser key surface and the validator's rule-category and hybrid-step-rule tables. Both are
  hand-maintained prose mirrors of the code this story consolidates. §19's `unsupported onError value` entry is
  **correct and stays**: `onError` survived S38. Re-derive any other drift against the current parser rather than
  against this FIS's original assumptions.
- `docs/specs/0.next-config-workflow-schemas/prd-draft.md#disposition-of-the-rest-of-this-draft-2026-09-03` – the
  disposition preserves former Track 2 and resolved decision 4 as per-step-type discrimination generated from the
  shared rule source, with semantic rules staying validator-only. The current accepted scope lives in the 0.26
  PRD, plan and this FIS; this historical row records why that boundary moved here.
- `docs/specs/0.next-config-workflow-schemas/prd-draft.md#disposition-of-the-rest-of-this-draft-2026-09-03` – the
  same Track 2 row records that former open question 3 moved to S16 and is answered here by making the step-type
  declarations walkable enough for S17 to generate conditional branches.
- `docs/specs/0.25/prd.md#deferred-the-workflow-schema-emitting-validator-s63-s64` – the durable post-release
  record for the deferred S63/S64 work and its parked commits. The superseded package-review YAGNI sizing was
  planning context only: this story does **not** delete rules, and no residual trim is scheduled.
- `../dartclaw-public/dev/adrs/041-framework-agnostic-workflow-engine-generic-output-validation.md#decision` – the
  two permitted output-validation mechanisms, and the boundary the framework-coupling fitness gate enforces.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI04,TI05,TI06] A definition that trips several rules at once reports the same diagnostics, with the same text, types and step attribution, in the same order as before the refactor**
  - **Given** a fixture corpus containing the three built-in workflows, the four maintainer `*-inline.yaml`
    definitions, and hand-written definitions that each trip multiple migrated rules on a single step (an
    `approval` step that is also `parallel` and also carries a prompt list; a step declaring both `map_over` and
    `parallel` with two `outputs` keys; a loop with an out-of-range `onMaxIterations` nested under a `foreach`)
  - **When** each is parsed and validated
  - **Then** the rendered `type|stepId|loopId|message` sequence for every fixture equals a golden file captured
    from the pre-refactor build, byte for byte and position for position — including the relative order of two
    diagnostics raised against the same step

- [ ] **S02 [OC01] [TI03,TI04,TI05,TI06] Every shipped and maintainer workflow still loads, validates clean and resolves exactly as before**
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart && bash dev/testing/profiles/workflow-contract/run.sh` – green – parity/regression across the three built-ins' output-key conventions, loop policies and gate keys plus the maintainer inline workflow contract suite

- [ ] **S03 [OC02] [TI02,TI03,TI04] Adding a step field to the rule source is enough to make it authorable and enforced — neither the parser's key sets nor a validator rule needs a second edit**
  - **Given** a throwaway optional step key declared in the rule source with a value kind and an applicability
    restricted to `bash` steps
  - **When** a definition declaring that key on a `bash` step is parsed, and a second definition declaring it on
    an `agent` step is parsed and validated
  - **Then** the first is accepted and the second is rejected naming the key and the step, with no edit to
    `workflow_definition_parser.dart`'s key sets or to any file under `validation/`

- [ ] **S04 [OC02] [TI03] The parser and the rule source describe the same DSL: for every block, the set of keys the parser accepts is exactly the set the rule source declares**
  - **Given** the workflow, variables, step, inline-foreach, inline-loop, outputs-entry, output-resolver,
    stepDefaults, gitStrategy and gitStrategy sub-block key sets
  - **When** each parser-accepted set is compared with the rule source's declared set for that block
  - **Then** they are equal as sets, asserted by enumeration (`unorderedEquals`) so a key added on one side and
    not the other fails the test rather than passing an absence check

- [ ] **S05 [OC03] [TI02,TI06] Every schema-relevant fact is readable as data: a consumer enumerates the whole accepted DSL without constructing a parser, a validator or a `WorkflowDefinition`**
  - **Given** only the rule source
  - **When** a consumer walks it for every block, every key with its accepted aliases, every value kind, every
    enum's member list, every required key, and every per-step-type applicability and mutual exclusion — including
    the `aggregate-reviews` required-outputs shape with its formats and preset names
  - **Then** the walk yields the complete set as const data with no predicate to invoke and no definition to
    supply, and the enum member lists match the runtime enums (`WorkflowTaskType`, `OutputFormat`, loop
    `onMaxIterations`, `workflowRoleDefaultAliases`) rather than restating them

- [ ] **S06 [OC01] [TI03,TI05] Rejections keep both their text and their layer: an unknown key still fails at parse and an unknown enum value still fails where it failed before**
  - **Given** a step carrying an unregistered key, a step declaring `type: nonesuch`, a step declaring the removed
    `type: custom`, and a loop declaring `onMaxIterations: sometimes`
  - **When** each is parsed and, where parsing succeeds, validated
  - **Then** the first three throw `FormatException` at parse with their current messages (unknown-field naming
    the block and key; unsupported-type listing the supported types; the `custom` migration message), and the
    fourth produces an `invalidLoopPolicy` validation error with its current text — the parser still fails fast on
    the first violation and the validator still accumulates

## Structural Criteria

- [ ] **SC01** `WorkflowDefinitionValidator.validate`'s rule-call sequence is unchanged: the same rule method names in the
      same order, so composer-level ordering is preserved by construction and only within-rule ordering needs the
      golden.
- [ ] **SC02** For every migrated rule, the emitted `ValidationErrorType`, the `stepId`/`loopId` population and the message
      text are unchanged; the golden corpus covers at least one emission of every migrated diagnostic, so a
      message with no pre-existing assertion cannot drift silently.
- [ ] **SC03** The imperative rules stay imperative and behaviourally untouched: node normalization, unique ids, loop
      references/overlap, aggregate-reviews placement and upstream resolution, `stepDefaults` glob matching,
      variable-reference and context-key consistency, `mapOver` ordering, gate-expression grammar, the whole of
      `workflow_git_strategy_rules.dart` and `workflow_output_schema_rules.dart`, the Codex advisory warning, the
      review-source prefixing rule, and the `continueSession` target/ordering/loop-boundary/cycle chain.
- [ ] **SC04** Schema-relevant facts in the rule source are const data — no closures, no `Function` fields, no runtime
      construction — so S17's generator can walk them; predicate-shaped checks stay in the imperative rules.
- [ ] **SC05** `dev/tools/fitness/check_no_framework_coupling.sh` passes with the new file inside its scan scope and **not**
      added to its exemption list; the rule source names no skill, framework or artifact filename.
- [ ] **SC06** `packages/dartclaw_workflow/test/fitness_baseline.json` names only files that exist, records the new file,
      and no surviving file exceeds its recorded ceiling; the `dartclaw_workflow` barrel is unchanged (`dev/fitness/test/barrel_show_clauses_test.dart` with `dev/fitness/test/allowlist/barrel_show_clauses.txt` untouched – the workflow barrel has no allowlist entries today)
      (the rule source is internal to `lib/src/`).
- [ ] **SC07** `dev/architecture/workflow-architecture.md` §18 and §19 and `packages/dartclaw_workflow/CLAUDE.md`
      § Conventions describe where DSL facts are declared and how a rule reads them; the §19 category and
      hybrid-step tables match the rules that exist after S38.
- [ ] **SC08** The full CI-equivalent gate passes: `dart analyze` clean, `dart format --line-length=120` clean, workspace
      tests green including the `component` and `integration` tags.

## Scope & Boundaries

### Work Areas

- **Rule source** – one new file under
  `../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/` declaring, per DSL block: accepted keys with
  their snake/camel aliases, value kinds, enum member sets, required keys, and per-`WorkflowTaskType`
  applicability and mutual exclusions.
- **Parser key surface** – `workflow_definition_parser.dart`: `_workflowKeys`, `_variableKeys`, `_stepKeys`,
  `_inlineForeachKeys`, `_inlineLoopKeys`, `_outputConfigKeys`, `_outputResolverKeys`, `_stepDefaultKeys`,
  `_gitStrategyKeys` and the `_gitPublish/_gitCleanup/_gitArtifacts/_gitWorktree/_externalArtifactMount` sets,
  plus the inline per-step-type branches around `_parseStep`'s prompt/script handling and `_parseStepType`.
- **Validator shape rules** – `validation/workflow_structure_rules.dart` (`_validateRequiredFields`,
  `_validateProviderAliases`, the alias arm of `_validateStepDefaults`),
  `validation/workflow_step_type_rules.dart` (`_validateMapStepConstraints`, `_validateAggregatorOutputShape`, the
  applicability half of `_validateHybridStepRules`), `validation/workflow_loop_policy_rules.dart` (the enum
  membership arm).
- **Diagnostics golden and validator suites** – a new golden corpus plus the eight
  `test/workflow/workflow_validator_*_rules_test.dart` files, their shared
  `workflow_validator_test_support.dart` spine, and `workflow_definition_parser_test.dart` with its
  `_support/workflow_parser_test_support.dart` helpers.
- **Fitness and gates** – `test/fitness_baseline.json` via `tool/regenerate_fitness_baseline.dart`, and
  `dev/tools/fitness/check_no_framework_coupling.sh`'s scan scope.
- **Docs** – `dev/architecture/workflow-architecture.md` §18/§19, `packages/dartclaw_workflow/CLAUDE.md`
  § Conventions and § Key files, `docs/guide/workflows-reference.md`'s step/output field tables.

### What We're NOT Doing

- **The schema artifact, its generator and the drift gate** – S17 owns all three. This story stops at making the
  facts walkable; it emits no JSON and adds no CI drift check.
- **Migrating the semantic rules** – graph shape, reference resolution, context-key consistency, git-strategy
  cross-field rules, output/preset interlock, gate grammar and the `continueSession` chain stay imperative. The
  schemas draft's resolved decision 4 scopes exactly these as validator-only and out of schema scope; forcing them
  into a table buys nothing S17 can use and puts 96 byte-locked messages at risk for no gain.
- **Deleting or trimming rules** – package review Y6 calls ~1,200 of the 1,902 LOC removable, but the retirement
  is S38's and the residual trim is unscheduled. Zero observable change means no rule loses coverage here.
- **`stepDefaults` glob collapse and the per-step override set** – package review S7's proposal; no story owns it,
  and it would change resolution behaviour.
- **Relocations and event ownership** – S61 (persistence/asset moves), S62 (git-support relocation) and S18
  (workflow events) touch the same package in the same milestone and are separately owned.

## Architecture Decision

**Approach**: One `const` rule source declaring the DSL's blocks, keys, aliases, value kinds, enums and
per-step-type applicability, read by both the parser's unknown-field rejection and the validator's shape rules —
modelled on `dartclaw_kernel`'s `ConfigMeta`/`FieldMeta`, which already does this for config, and readable by an emitter in the shape of `config_meta/json_schema.dart`.
**Why this over alternatives**: a validator-only table would leave the key surface in the parser and hand S17 a
rule source that cannot describe the grammar it is supposed to publish; a full migration of all thirty rules would
put 96 byte-locked messages and 30 rule methods at risk to express graph invariants a JSON Schema cannot carry
anyway.

## Code Patterns & External References

```
# type | path#anchor                                                                                          | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/config_meta.dart#ConfigMeta                       | the in-repo precedent: const field-metadata map with types, allowed values and bounds, read by the validator
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart#_rejectUnknownFields | the single choke point every block's key set flows through — the seam the rule source plugs into
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_definition_validator.dart      | the composer whose call sequence is the ordering contract
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/validation/workflow_step_type_rules.dart#_validateAggregatorOutputShape | the closure-carrying required-outputs map: the exact shape to replace with walkable data
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart#WorkflowTaskType | the enum whose wire values the rule source references rather than restates
file   | ../dartclaw-public/packages/dartclaw_workflow/test/workflow/workflow_validator_test_support.dart       | the shared `buildDef`/`step`/`hasError` spine every validator suite uses; golden fixtures build on it
file   | ../dartclaw-public/packages/dartclaw_workflow/tool/regenerate_fitness_baseline.dart                    | the supported way to re-emit fitness_baseline.json after adding a file
```

## Constraints & Gotchas

- **Critical – diagnostic order is observable but almost unpinned, and this refactor is exactly what breaks it.**
  Across the eight validator suites there are ~96 message-substring assertions but only three that assert
  position (`errors.first` / `errors[0]` in `workflow_validator_structure_rules_test.dart`); everything else goes
  through `hasError(...)`, which is set membership. `workflow validate` prints the report in list order, so a rule
  that today emits its per-step checks in hand-written statement order and tomorrow emits them in table-declaration
  order can reorder a multi-violation report with the whole suite green. Capture the golden **before** touching a
  rule (TI01), and author each table's entry order to match today's statement order.
- **Critical – the parser and the validator report differently, and one rule source must not unify that.** The
  parser throws `FormatException` on the first violation with a `${_at(sourcePath)}` suffix and no recovery; the
  validator accumulates typed `ValidationError`s across every step. Sharing the *facts* is the goal; sharing the
  *reporting* would change which of several problems an author is told about first. Message templates for the two
  layers stay distinct even where they describe the same fact.
- **Critical – S17 cannot walk closures.** `_validateAggregatorOutputShape`'s
  `Map<String, (OutputFormat, bool Function(String?))>` is the shape to avoid: a predicate is opaque to a
  generator. Preset expectations belong in the table as names (`review_report_path`, `findings_count`,
  `gating_findings_count`) with the format beside them; the preset-matching helpers stay as consumers of those
  names, not as the declaration.
- **Landed – the 0.25 sibling stories all shipped.** S21 and S38 are in 0.25.0; there is no wave to sequence
  against. What actually survives in `_outputConfigKeys` on `main` is `format`, `schema`, `source`, `description`,
  `pathPattern`, `path_pattern`, `preferPatterns`, `prefer_patterns` – **`pathPattern` and `preferPatterns` were not
  removed**; output `resolver` was. Enumerate against the parser as it stands, never against this FIS's prose.
- **Constraint – the rule source declares the surviving surface, and `onError` is part of it.** S38 retired eleven
  authoring keys, but `onError` / `on_error` stayed. Re-declaring a genuinely retired key would resurrect it;
  omitting `onError` would make the schema S17 emits reject legal definitions. Both failures are silent.
- **Constraint – ADR-041 framework agnosticism is enforced by CI on this exact directory.**
  `check_no_framework_coupling.sh` scans `packages/dartclaw_workflow/lib/src/` for `andthen` literals with a
  three-file exemption list. The rule source lands inside that scan and must stay clean — the
  `story_specs`/`review_report_path` preset names it references are generic data-shape names and already permitted.
- **Avoid**: proving key-set equality or rule preservation with `isNot(contains(...))`. Per the project's
  bound-asserting learning, enumerate the surviving key sets, applicability entries and composer rule sequence.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** A golden corpus captures every diagnostic the migrated rules can emit, in order, from the
      pre-refactor build.
  - Restore and adapt `packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart` and its two goldens
    from parked commit `b8eed65b`; they must land and be committed **before** any rule moves. Fixtures: the three built-ins, the four maintainer
    `.dartclaw/workflows/custom/*-inline.yaml` definitions, and hand-written multi-violation definitions covering
    each migrated rule at least once (S01 names the three ordering-sensitive shapes). Render each report as an
    ordered `type|stepId|loopId|message` sequence to a checked-in golden file; build fixtures on
    `test/workflow/workflow_validator_test_support.dart`'s existing spine rather than a second one.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart --name "diagnostic sequence stays byte-identical"` – the ordered golden covers every migrated diagnostic and fails on changed message text, type, attribution, emission position, or relative order
  - **SATISFIES**: S01, SC02

- [ ] **TI02** The DSL's accepted shape is declared once, as const data.
  - One new file under `lib/src/workflow/`, following `config_meta.dart#ConfigMeta`: per block (workflow,
    variables, step, inline foreach, inline loop, outputs entry, output resolver, stepDefaults, gitStrategy and
    its sub-blocks) the accepted keys with snake/camel aliases, value kind, required-ness, enum member sets
    referencing the runtime enums, and per-`WorkflowTaskType` applicability plus mutual exclusions. Internal to
    `lib/src/` — no barrel export, so `dev/fitness/test/allowlist/barrel_show_clauses.txt` is untouched. No closures on schema-relevant
    facts; entry order within each block mirrors today's statement order (TI01's golden is the check).
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart --name "rule source enumerates the accepted DSL surface"` – the walk enumerates every block, key, alias, value kind, enum member set and per-step-type applicability entry without constructing a parser, validator or definition, and every declared enum set equals its runtime source
  - **SATISFIES**: S03, S05, SC04

- [ ] **TI03** The parser's accepted keys and per-step-type shape rules come from the rule source.
  - Consumes TI02. The ten-plus `_*Keys` sets and the inline `type`-conditional branches around `_parseStep`
    (`script` only on `bash`, `prompt` xor `script` on `bash`, prompt-or-skill required except on
    bash/approval/foreach/aggregate-reviews) read the table; `_rejectUnknownFields` is the single seam, and every
    `FormatException` message and its `_at(sourcePath)` suffix is unchanged. Parse arms, coercions and normalization
    (`prompt` string→list, `timeout` duration→seconds, `outputs` shorthand) are untouched.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart --name "parser key surface is the exact declared surface|one rule-source field edit makes a field parseable and applicable|parser rejection layer and messages stay byte-identical"` – every parser key set equals the declaration under `unorderedEquals`; one declaration edit controls parsing and applicability; unknown fields, `nonesuch`, retired `custom`, and agent `script` retain their `FormatException` messages
  - **SATISFIES**: S02, S03, S04, S06

- [ ] **TI04** The validator's required-field and per-step-type applicability rules are driven by the rule source.
  - Consumes TI02 and is gated by TI01's golden. `_validateRequiredFields`' prompt-requirement branch,
    `_validateMapStepConstraints`' parallel/`mapOver` exclusion and single-aggregate-outputs-key rule, and the
    applicability half of `_validateHybridStepRules` (approval-in-loop warning, approval+parallel,
    bash|approval+multi-prompt, parallel+continueSession) read their facts from the table while keeping their
    message text, `ValidationErrorType`, step attribution and emission position. The `continueSession`
    target-resolution, ordering, provider-equality, loop-boundary and cycle checks stay untouched in place.
    Extend `workflow_dsl_rules_test.dart` with the `validator rule-call sequence stays unchanged` test named by
    Verify.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart --name "diagnostic sequence stays byte-identical|validator rule-call sequence stays unchanged" && dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_validator_structure_rules_test.dart packages/dartclaw_workflow/test/workflow/workflow_validator_step_type_rules_test.dart` – the golden remains byte-identical, the composer call sequence equals its pre-refactor enumeration, and the existing structure and step-type behavior stays green
  - **SATISFIES**: S01, S02, S03, SC01, SC02, SC03

- [ ] **TI05** Enum-membership and role-alias rules read their member sets from the rule source.
  - Consumes TI02. `_validateLoopMaxIterationsPolicy`'s allowed-value arm, `_validateProviderAliases` and the
    alias arm of `_validateStepDefaults` take their member lists from the table instead of re-declaring them; the
    nested-`continue` and top-level-`escalate` scope rules and the glob-matching arm stay imperative because
    neither is a membership fact. Messages that interpolate the allowed set keep their current rendering and
    ordering. Add the `loop policy and role aliases preserve diagnostics` case to `workflow_dsl_rules_test.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart --name "loop policy and role aliases preserve diagnostics" && dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_validator_loop_policy_rules_test.dart packages/dartclaw_workflow/test/workflow/workflow_validator_structure_rules_test.dart` – `sometimes` retains the ordered `fail, continue, escalate` diagnostic, `@executer` retains the supported-alias diagnostic, and the imperative scope and glob rules stay green
  - **SATISFIES**: S01, S02, S06, SC02, SC03

- [ ] **TI06** The `aggregate-reviews` required-output shape is declared as data, not as predicates.
  - Consumes TI02. `_validateAggregatorOutputShape`'s `Map<String, (OutputFormat, bool Function(String?))>` is
    replaced by a table entry naming each required output key with its expected `OutputFormat` and preset name;
    the preset-matching helpers (`isReviewReportPathPreset`, `_isFindingsCountPreset`,
    `_isGatingFindingsCountPreset`) become consumers of those names. The upstream-step resolution, source-scoped
    count requirement and report-key collision checks in `_validateAggregateReviewsConstraints` stay imperative.
    Add the `aggregate-review output rules are const data and preserve diagnostics` case to
    `workflow_dsl_rules_test.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart --name "aggregate-review output rules are const data and preserve diagnostics" && dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_validator_step_type_rules_test.dart` – wrong format and preset diagnostics retain every named value, while the required-output triples are walkable const key/format/preset data and upstream resolution behavior stays green
  - **SATISFIES**: S01, S02, S05, SC02, SC03, SC04

- [ ] **TI07** The package's fitness gates account for the new file and still prove framework agnosticism.
  - Consumes TI02-TI06. Regenerate `test/fitness_baseline.json` via `tool/regenerate_fitness_baseline.dart` so it
    records the rule source and the reduced rule-file ceilings; confirm the file is inside
    `dev/tools/fitness/check_no_framework_coupling.sh`'s scan scope and is **not** added to its exemption list.
  - **Verify**: `cmd: dart analyze --fatal-infos && dart format --line-length=120 --output=none --set-exit-if-changed . && bash dev/tools/test_workspace.sh && bash dev/tools/fitness/run_all.sh && git diff --exit-code -- dev/tools/fitness/check_no_framework_coupling.sh dev/fitness/test/allowlist/barrel_show_clauses.txt packages/dartclaw_workflow/lib/dartclaw_workflow.dart` – the CI-equivalent gate passes, the baseline records only existing files at actual ceilings, the new source remains inside the unchanged framework scan, and neither the barrel nor its allowlist changes
  - **SATISFIES**: SC05, SC06, SC08

- [ ] **TI08** The workflow documentation says where the DSL is declared and describes the rules that exist.
  - `dev/architecture/workflow-architecture.md` §18 states that the parser's accepted keys come from the rule
    source and §19's category and hybrid-step tables match the post-S38 rule set. The `unsupported onError value`
    row remains because `onError` survived S38; do not delete it. `packages/dartclaw_workflow/CLAUDE.md` § Conventions amends the "new validator rules:
    add as a sibling file" bullet to say declarative facts are declared in the rule source and only rules with
    behaviour get a sibling file, and § Key files lists it; `docs/guide/workflows-reference.md`'s step and output
    field tables list only keys the rule source declares. Add the `workflow documentation matches the declared DSL
    surface` contract case to `workflow_dsl_rules_test.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart --name "workflow documentation matches the declared DSL surface"` – architecture §18/§19, the package conventions and key-file list, and the workflow-reference step/output tables name the rule source and enumerate exactly its post-S38 rules and authoring keys
  - **SATISFIES**: SC07

### Execution Contract

- TI01 must be committed before TI04-TI06 begin. Its golden is captured from the pre-refactor build and is the
  only oracle for within-rule diagnostic ordering; capturing it after a rule moves records the regression as the
  baseline.

## Implementation Observations

_No observations recorded yet._
