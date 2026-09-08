# Published workflow JSON Schema and drift gate

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S17

> **Provenance**: deferred from 0.25 S64; moved into 0.26 by owner decision 2026-09-03. Salvage source is the branch
> `parked/s64-workflow-schema` at `a1e1bd95`, which carries a 778-line `schemas/workflow.schema.json` absent from
> `main` and is 2,256 files divergent from it – **cherry-pick the two commits onto a fresh branch, do not rebase**.
> The 0.25 PRD is the durable historical record after release consolidation; its anchored implementation record
> preserves the original S54/S63/S64 provenance.

## Feature Overview and Goal

**Intent**: S16 makes the workflow DSL's accepted shape readable as const data, but nothing outside the engine can read it – a workflow author still finds a mistyped key by starting a run, and the surface the dynamic-workflows slice's generator is supposed to be handed does not exist as an artifact anyone can consume.

**Expected Outcomes**:

- [OC01] A workflow author editing a definition in a schema-aware editor sees an unknown key, a wrong-typed value, an invalid enum member and a key used on the wrong step type flagged before the run starts – from the same declaration the parser enforces.
- [OC02] Every workflow DartClaw ships or maintains – the three built-in definitions and the four git-tracked maintainer inline definitions – validates clean against the published artifact, so the files authors copy from produce no false errors.
- [OC03] The committed artifact cannot drift from the rule source: a rule-source change that is not regenerated fails CI with the regeneration command named.
- [OC04] The artifact is complete enough to generate from – every block, key, alias, value kind, enum member and per-step-type applicability the rule source declares is readable from the JSON alone, with no Dart to consult.

## Required Context

- `docs/specs/0.25/prd.md#fr11-one-workflow-runtime` – the acceptance bullet this story closes: *"Workflow validator becomes schema-emitting: the same rule source can emit the workflow JSON Schema (`0.next-config-workflow-schemas` Track 2 lands there or immediately after) – the surface 0.30's generator will be given."* (Quoted verbatim; that "0.30" is the milestone number the dynamic-workflows slice carried at the time.) S16 produces the rule source; this story does the emitting, publishing and gating.
- `docs/specs/0.25/prd.md#constraints` – Binding Constraint, verbatim: *"Workflow engine capability that 0.29/0.30 need is preserved; engine stays framework-agnostic (ADR-041; \"no AndThen filenames in production code\" standing decision)."* Two obligations: the artifact must describe the grammar the engine actually accepts (a schema that rejects a legal definition is a capability regression that only shows up in an editor), and neither the emitter nor the artifact may name a skill, framework or artifact filename.
- `docs/specs/0.25/prd.md#non-functional-requirements` – the Maintainability row (docs currency in the same PR), the Reliability row (every slice passes the full CI-equivalent gate including fitness) and the Compatibility row (a new published artifact is a CHANGELOG line).
- `docs/specs/0.26/s16-declarative-workflow-step-type-rule-source.md#structural-criteria` – the dependency and this story's only input. S16 declares, per DSL block, the accepted keys with their snake/camel aliases, value kinds, enum member sets, required keys, per-`WorkflowTaskType` applicability and mutual exclusions, **as const data with no closures**, precisely so a generator can walk it. It declares the surface as it stands after the 0.25 key retirement, so the emitter enumerates what is there, never what this FIS's prose recalls.
- `docs/specs/0.25/prd.md#fr12--one-config-schema-source-s10-s11-s12-s42-s53-s54-s59-s65-s81-s82-s83-s92-s93` – **the S54 config-side twin, shipped in 0.25.0. It is landed prior art to copy, not a sibling to coordinate with.** Read its consolidated delivery record and what it actually produced: the emitter `packages/dartclaw_kernel/lib/src/config_meta/json_schema.dart`, the generator `packages/dartclaw_kernel/tool/generate_config_schema.dart`, the committed artifact `schemas/dartclaw.schema.json`, and the drift gate registered in `dev/tools/fitness/run_all.sh` as `dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check`. Same generation-only rule, same closed-vocabulary discipline, same repo-root `schemas/` directory, same `--check` gate shape. The two share no generator (different packages, different rule sources); only the directory and the pattern are common.
- `docs/specs/0.next-config-workflow-schemas/prd-draft.md#disposition-of-the-rest-of-this-draft-2026-09-03` – the historical Track 2 row routes `workflow.schema.json`, generated per-step-type discrimination and CI validation of shipped workflow YAML into S16/S17. The accepted requirements are now owned by `docs/specs/0.26/prd.md#rider-owner-2026-09-03--workflow-schema-stories-s16s17`, the 0.26 plan and these FIS; the disposition is provenance, and its distribution/versioning row confirms that work is outside this story.
- `../dartclaw-public/dev/adrs/041-framework-agnostic-workflow-engine-generic-output-validation.md#decision` – the framework-agnosticism boundary CI enforces on `packages/dartclaw_workflow/lib/src/`, which is where the emitter lands.
- `../dartclaw-public/dev/adrs/033-architectural-governance-via-fitness-functions.md` – why the drift check joins the existing harness rather than becoming a new runner: gates live in one place, run in CI on every commit, and carry allowlists with mandatory rationale.

## Deeper Context

- `docs/specs/0.next-config-workflow-schemas/prd-draft.md#disposition-of-the-rest-of-this-draft-2026-09-03` – the Track 2 row records former open question 3 as answered by S16, while the distribution/versioning row moves hosting, versioning, modelines and schema-export commands to 0.25.1. Under S17's current 0.26 plan scope, this artifact remains generation-only with no `$id` and absorbs none of that distribution work.
- `../dartclaw-public/dev/architecture/workflow-architecture.md#18-parser-contract` – the documented normalization table (`prompt` string→list, omitted `type` defaults to `agent`, `timeout: "30s"`, `outputs.key: json` shorthand). Every row is an authoring shape the artifact must accept, and the section gains the emitted-artifact subsection.
- `../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart#_rejectUnknownFields` – the durable current parser inventory that supersedes the pruned 0.25 package-review snapshot; use it only to catch rule-source omissions, because S16's rule source is authoritative for emission.
- `../dartclaw-public/dev/state/DECISIONS.md` – the *"No AndThen-specific filenames in production code"* standing decision (2026-07-04) that `check_no_framework_coupling.sh` enforces, and the *"structural gates stay strict"* line covering the barrel gates.

## Acceptance Scenarios

- [ ] **S01 [OC02] [TI01,TI02,TI05] Every workflow DartClaw ships or maintains validates clean against the committed artifact**
  - **Given** the seven-file corpus – `packages/dartclaw_workflow/lib/src/workflow/definitions/{plan-and-implement,spec-and-implement,code-review}.yaml` and the git-tracked `.dartclaw/workflows/custom/{plan-and-implement,spec-and-implement,review-and-remediate,multi-agent-review}-inline.yaml`. All seven exist on `main` (verified 2026-09-02). The four `*-inline.yaml` files are a **deliberately maintained maintainer corpus**; the workflow-track brief's "do not resurrect duplicate `*-inline` definitions" line covers new *example* definitions and does not apply to them
  - **When** each is loaded as YAML and checked against `schemas/workflow.schema.json`
  - **Then** every file reports zero diagnostics – including `multi-agent-review-inline.yaml`'s `gitStrategy.integrationBranch: false`, its `worktree: inline` string form, `project: "{{PROJECT}}"` template placeholders in string-typed fields, folded `>-` descriptions, and consecutive `parallel: true` steps

- [ ] **S02 [OC01] [TI01,TI02,TI05] A mistyped key, a wrong-typed value, an invalid enum member and a key used on the wrong step type are each flagged, naming the path**
  - **Given** a corpus definition that validates clean
  - **When** the same document is checked with a step key misspelled, with `parallel: "yes"`, with a loop's `onMaxIterations: sometimes`, with `type: nonesuch`, and with `script:` declared on an `agent` step
  - **Then** each variant produces a diagnostic naming the offending path and the unmodified document still produces none – matching what the parser and validator reject, at the layer that rejects it

- [ ] **S03 [OC01,OC02] [TI01,TI02,TI05] The polymorphic authoring shapes the parser accepts are accepted by the schema, so no legal file becomes an editor error**
  - **Given** `prompt` as a string and as a list, an `outputs` entry as a format keyword shorthand, as a registered preset name and as a full mapping, `gitStrategy.worktree` as a string and as a mapping, `timeout` as `"30s"` and as an integer, `schema` as a preset name and as an inline object, and the snake/camel alias pairs the rule source declares (`map_over`/`mapOver`, `continue_session`/`continueSession`, `on_failure`/`onFailure`, …)
  - **When** each shape is checked against the artifact
  - **Then** all of them validate, and an `outputs` shorthand string that is neither an `OutputFormat` name nor a registered `schemaPresets` key is rejected – the shorthand enum is enumerated from those two sources, not left open

- [ ] **S04 [OC01] [TI02,TI05] Strictness and per-step-type conditionals compose: the union of step keys survives the closed object, and each key is still refused on the wrong type**
  - **Given** the emitted step schema closes with `additionalProperties: false` while the per-step-type branches are conditional
  - **When** a `bash` step declaring `script`, an `agent` step declaring `prompt`, a `bash` step declaring `prompt`, an `agent` step declaring `script`, and a step declaring an unregistered key are each checked
  - **Then** the first three validate and the last two are rejected – the closed object does not swallow a key that only one step type may carry, and the conditional branches do not leak strictness away from the base

- [ ] **S05 [OC03] [TI03,TI04] A rule-source change that is not regenerated fails CI**
  - **Given** the committed `schemas/workflow.schema.json` and the rule source agree and the fitness harness is green
  - **When** a key, alias, enum member or per-step-type applicability entry is changed in the rule source without re-running the generator
  - **Then** `bash dev/tools/fitness/run_all.sh` fails, naming the artifact path and the regeneration command, and passes again only after regeneration – while reordering declarations inside the rule source without changing their content leaves the artifact byte-identical and the harness green

- [ ] **S06 [OC04] [TI01,TI05] The artifact alone describes the whole accepted surface**
  - **Given** only `schemas/workflow.schema.json` and the rule source
  - **When** the artifact's declared blocks, property names, per-property value kinds, enum member lists, required keys and per-step-type applicability entries are compared with the rule source's declarations
  - **Then** the two are equal as sets, asserted by enumeration (`unorderedEquals`) in both directions so a key present on one side only fails – and the artifact's keyword set and `type` values fall inside the closed emitted vocabulary

## Structural Criteria

- [ ] **SC01** The rule source is unchanged: no key, alias, enum member, value kind or applicability entry is added, removed or altered to make emission easier. A gap found while emitting is fixed in the rule source under S16's contract, and the artifact never carries a fact the rule source does not declare.
- [ ] **SC02** No new barrel export line in `packages/dartclaw_workflow/lib/dartclaw_workflow.dart` – `dev/fitness/test/barrel_show_clauses_test.dart` stays green with `dev/fitness/test/allowlist/barrel_show_clauses.txt` unedited. **Re-derive the barrel gate before relying on this bullet**: 0.25 relocated the Dart fitness suite to `dev/fitness/`, and there is no `barrel_export_count_test` or `barrel_export_count.txt` anywhere in the tree today, so the earlier "44 exports against a ceiling of 35" figure has no gate behind it. What does exist is the show-clause gate, which the workflow barrel currently satisfies with no allowlist entries.
- [ ] **SC03** `SchemaValidator` is untouched and is not made to read this artifact: its `_supportedKeywords`/`_unsupportedKeywords` sets are unedited, `schema_validator_test.dart` passes unedited, and no workspace source routes `schemas/workflow.schema.json` through it.
- [ ] **SC04** `dev/tools/fitness/check_no_framework_coupling.sh` passes with the emitter inside its scan scope (`packages/dartclaw_workflow/lib/src/`, excluding only `**/definitions/*.yaml` and `**/generated/*`) and **not** added to its exclusion list; neither the emitter nor the emitted artifact contains a framework, skill or artifact-filename literal.
- [ ] **SC05** `packages/dartclaw_workflow/test/fitness_baseline.json` records the new emitter file, names only files that exist, and no surviving file exceeds its recorded ceiling.
- [ ] **SC06** The generator is the artifact's only writer: no hand-edit path, no committed template, no timestamp or version stamp in the output; running the generator twice in a row leaves the working tree clean.
- [ ] **SC07** The drift gate runs inside the existing fitness harness – one new step in `dev/tools/fitness/run_all.sh`, no edit to `.github/workflows/ci.yml`, and no second runner script or parallel harness.
- [ ] **SC08** The artifact, its regeneration command and its gate are documented where a contributor looks: `dev/architecture/workflow-architecture.md`, `dev/fitness/README.md`, `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`, `docs/guide/workflows.md` and the CHANGELOG.
- [ ] **SC09** The full CI-equivalent gate passes: `dart analyze --fatal-infos` clean, `dart format --line-length=120` clean, workspace tests green, `bash dev/tools/fitness/run_all.sh` green.

## Scope & Boundaries

### Work Areas

- `../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/` – one new emitter file projecting S16's rule source into a JSON Schema tree; internal to `lib/src/`, no barrel export.
- `../dartclaw-public/packages/dartclaw_workflow/tool/generate_workflow_schema.dart` – the regeneration entry point, with a `--check` mode for the gate.
- `../dartclaw-public/schemas/workflow.schema.json` – the committed generated artifact.
- `../dartclaw-public/dev/tools/fitness/run_all.sh` – one new step registering the drift check in the existing harness.
- `../dartclaw-public/packages/dartclaw_workflow/test/workflow/` – the corpus, mutation, polymorphic-shape, composition and parity suites; `test/fitness_baseline.json` via `tool/regenerate_fitness_baseline.dart`.
- `../dartclaw-public/dev/architecture/workflow-architecture.md`, `../dartclaw-public/dev/fitness/README.md`, `../dartclaw-public/dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`, `../dartclaw-public/docs/guide/workflows.md`, `../dartclaw-public/CHANGELOG.md` – doc currency for a new published artifact and a new gate.

### What We're NOT Doing

- **Distribution and versioning** – rolling `$id` URL, per-minor snapshots, hosting, a `# yaml-language-server:` modeline and a `dartclaw workflow schema --out` command. The draft's disposition moved that work to 0.25.1, while S17's current 0.26 plan requires a generation-only artifact with no `$id`; the artifact is attachable by path in this story.
- **The rule source, the parser and the validator** – S16 owns all three. This story reads the declaration and changes no accepted key, no diagnostic and no enforcement layer. A schema that disagrees with the parser is an emitter defect, never a reason to touch the parser.
- **Semantic rules in the schema** – ID uniqueness, reference resolution, gate-expression grammar, `continueSession` chains, `stepDefaults` glob resolution, output/preset interlock. The draft's resolved decision 4 scopes these as validator-only and out of schema scope; JSON Schema cannot carry them and pretending otherwise would make the artifact lie.
- **Expanding `SchemaValidator`** – it is the deliberately-subset reader for *step outputs* and explicitly lists `oneOf`/`if`/`then`/`else`/`not` as unsupported. Broadening it is the draft's own out-of-scope item.
- **Regenerating `docs/guide/workflows-reference.md` from the artifact** – no workflow twin of the config-side reference generator is scheduled; S16 keeps that guide's field tables aligned with the rule source. This story adds a pointer to the artifact in `docs/guide/workflows.md`, nothing more.
- **Validating untracked materialized copies** – `.dartclaw/workflows/built-in/`, `.dartclaw-example/workflows/` and `dev/testing/profiles/workflows/data/workflows/built-in/` are runtime state, not source (one already differs from the shipped definition it was materialized from). Gating them would gate a stale copy.

## Architecture Decision

**Approach**: an emitter inside `dartclaw_workflow` walks S16's const rule source and returns a `Map<String, Object?>` built from a closed, deliberately small keyword vocabulary; `tool/generate_workflow_schema.dart` writes it to `schemas/workflow.schema.json` and, under `--check`, regenerates in memory and fails on any byte difference; the existing fitness harness (`dev/tools/fitness/run_all.sh`) gains that `--check` invocation; the corpus, mutation, composition and parity proofs are package tests that import the emitter directly.
**Why this over alternatives**: putting the drift check in the Dart fitness suite (now at `dev/fitness/test/` after 0.25 S90 relocated it) would make it the first test there to import a production package – the existing gates are pure file scanners, and S90 stripped exactly those production dependencies while relocating the suite. `dev/tools/fitness/run_all.sh` is the same CI-wired harness (it ends by invoking `bash dev/tools/run-fitness.sh`) and **already runs precisely this shape of gate for the config schema**: `dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check`. Registering beside it is one harness, not two. The emitter lives in the package because `dev/tools/` scripts are not workspace members and cannot import the rule source at all.

## Technical Overview

The rule source is per-block declarations; the schema is a tree rooted at the workflow object. Each declared block becomes an object schema whose `properties` carry one entry per accepted key **and one per declared alias**, sharing the same value schema, closed with `additionalProperties: false`. Enum member sets emit as `enum`; polymorphic value kinds emit as `oneOf` over their branches. Keys are sorted at every level so the artifact is a function of declared content, not declaration order.

Per-step-type variation is the one construct that needs care. `additionalProperties: false` does not compose across `allOf`: a base object that closes on agent-step keys rejects `script` before any `bash` branch is consulted. So the step object declares the **union** of every key any step type may carry and closes once, and the conditional branches only narrow – `{"if": {"properties": {"type": {"const": "bash"}}, "required": ["type"]}, "then": {"required": [...], "not": {"required": [<keys inapplicable to bash>]}}}`, one branch per `WorkflowTaskType` wire value, with the omitted-`type` default (`agent`) expressed as its own branch. The corpus walker is a complete reader of that closed vocabulary rather than a partial JSON Schema implementation, and a test pins the emitted keyword set so it cannot fall behind the artifact.

## Code Patterns & External References

```
# type | path#anchor                                                                                             | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_workflow/tool/regenerate_fitness_baseline.dart                      | the workspace tool-script-writes-committed-JSON pattern: relative import of the package's own sources, JsonEncoder.withIndent('  '), trailing newline
file   | ../dartclaw-public/packages/dartclaw_workflow/test/fitness_support.dart#resolveRepoRoot                   | the existing repo-root resolver the corpus paths need – reuse it; do not add another copy
file   | ../dartclaw-public/dev/tools/fitness/run_all.sh                                                          | the harness entry: the `dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check` step is the exact shape to mirror, and the trailing `bash dev/tools/run-fitness.sh` line is why this is one harness
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/config_meta/json_schema.dart                          | the shipped config-side emitter (0.25 S54): closed keyword vocabulary, sorted keys, generation-only – copy its shape
file   | ../dartclaw-public/packages/dartclaw_kernel/tool/generate_config_schema.dart                             | the shipped generator + `--check` mode this story's generator mirrors
file   | ../dartclaw-public/schemas/dartclaw.schema.json                                                          | the shipped artifact: draft-2020-12, strict, no `$id` (hosting and version scheme still undecided)
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart            | the grammar the artifact must not contradict: alias pairs, the normalization table, and the `outputs` shorthand's accept-set
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/schema_presets.dart#schemaPresets          | the registered preset names the `outputs` shorthand and `schema:` string form accept – enumerate from here, never restate
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart#WorkflowTaskType  | the wire values the `if`/`then` branches key on
file   | ../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/schema_validator.dart#_unsupportedKeywords | read to confirm it cannot serve this artifact: oneOf/if/then/else/not are all listed unsupported
url    | https://json-schema.org/draft/2020-12/schema                                                             | the dialect declared in `$schema`; `if`/`then`/`const` require 2019-09 or later, so draft-07 compatibility is not available here
```

## Constraints & Gotchas

- **Critical – `additionalProperties: false` does not compose with `allOf`/`if`–`then`.** The obvious emission (a base step object closed on common keys, plus branches adding per-type keys) rejects every `bash` step's `script` and every legal file in the corpus. The union-then-narrow shape in *Technical Overview* is the fix, and S04 is the scenario that proves it – do not discover this by loosening `additionalProperties`.
- **Critical – a schema stricter than the parser is a capability regression, not extra safety.** The parser normalizes (`prompt` string→list, `timeout: "30s"`, `outputs.key: json`, omitted `type`), accepts snake and camel spellings of the same key, and takes `gitStrategy.worktree` as either a string or a mapping. Every one of those is a legal authoring shape; a schema that flags them turns the editor integration into noise the author learns to ignore. S03 enumerates the ones the corpus exercises.
- **Critical – `SchemaValidator` cannot validate this artifact and must not be pointed at it.** It lists `oneOf`, `anyOf`, `allOf`, `not`, `if`, `then`, `else` and `$ref` in `_unsupportedKeywords`, so `checkUnsupportedKeywords` would flag the whole file. It is the step-output reader, a different and deliberately subset surface. The corpus gate gets its own walker over the closed emitted vocabulary.
- **Landed – S90 already moved the Dart fitness suite.** It now lives at `dev/fitness/` (tests in `dev/fitness/test/`, allowlists in `dev/fitness/test/allowlist/`, README at `dev/fitness/README.md`), with `dartclaw_testing`'s production dependencies stripped. `packages/dartclaw_testing/test/fitness/` no longer exists. Register the drift check in `dev/tools/fitness/run_all.sh`, which S90 did not move.
- **Constraint – the emitter enumerates the rule source, not this FIS's prose.** 0.25 S38 retired eleven authoring keys but **not** `onError`/`on_error`, and `pathPattern`/`path_pattern`/`preferPatterns`/`prefer_patterns` all survive in `_outputConfigKeys` (only output `resolver` was retired there). Emitting from memory would either republish a retired key as accepted or drop a live one; the rule source is the only authority.
- **Constraint – the barrel gate is `dev/fitness/test/barrel_show_clauses_test.dart`**, which requires an explicit `show` clause on every barrel export line (allowlisted exceptions carry a mandatory rationale). Workaround, unchanged: the emitter stays internal to `lib/src/`, reached by the `tool/` script and the package's own tests via same-package imports (`src_import_hygiene_test` only fails cross-package `src/` imports), so no barrel line is added at all.
- **Constraint – ADR-041 framework agnosticism is enforced by CI on exactly the directory the emitter lands in.** `check_no_framework_coupling.sh` scans `packages/dartclaw_workflow/lib/src/` for `andthen` literals with a two-subtree exclusion; the emitter must stay clean and must not be added to the exclusion list. The corpus files it validates do name skills – they are data read by a test outside the scan scope, which is fine.
- **Avoid**: adding a JSON Schema package dependency for a test-only gate. The emitted vocabulary is closed and asserted, so a small walker is a complete reader of it; an open vocabulary is what makes a partial reader dangerous.
- **Avoid**: proving surface parity with `isNot(contains(...))`. Per the project's bound-asserting learning, enumerate both sides and compare as sets in both directions (S06).

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** The rule source projects into a strict JSON Schema tree covering every block, key, alias and value kind
  - One new file under `packages/dartclaw_workflow/lib/src/workflow/`, shaped after `packages/dartclaw_kernel/lib/src/config_meta/json_schema.dart`. Per declared block: an object schema whose `properties` carry one entry per accepted key and one per declared alias sharing the same value schema, `required` from the rule source's required keys, `additionalProperties: false`, keys sorted at every level. Enum member sets emit as `enum`; polymorphic value kinds emit as `oneOf`. The `outputs` shorthand's string branch enumerates `OutputFormat.values` names plus `schemaPresets` keys; `schema:` accepts a preset name or an inline object. Create `packages/dartclaw_workflow/test/workflow/workflow_json_schema_test.dart` with the focused emitter contract named by Verify; TI02, TI03 and TI06 extend that file. No barrel export.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_json_schema_test.dart --name "every declared block field alias and value kind is emitted" && git diff --exit-code -- packages/dartclaw_workflow/lib/src/workflow/workflow_dsl_rules.dart` – every declared block is closed, aliases share one value schema, polymorphic fields retain every branch, the shorthand enum is exactly `OutputFormat ∪ schemaPresets`, and S16's rule source is unchanged
  - **SATISFIES**: S01, S02, S03, S06, SC01

- [ ] **TI02** Per-step-type applicability emits as conditional branches without loosening the closed step object
  - The step object declares the union of every key any `WorkflowTaskType` may carry and closes once; one `if`/`then` branch per wire value narrows via `required` and `not: {required: [...]}` from the rule source's applicability and mutual-exclusion entries, with the omitted-`type` default (`agent`) as its own branch. Add the `step schema is closed and narrows each task type` case to `workflow_json_schema_test.dart`. Depends on TI01's node builder.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_json_schema_test.dart --name "step schema is closed and narrows each task type"` – the branch set equals every task-type wire value plus the omitted-type default; legal agent/bash shapes validate while agent `script` and unregistered keys are rejected with their paths
  - **SATISFIES**: S01, S02, S03, S04

- [ ] **TI03** `schemas/workflow.schema.json` is committed and regenerable by one command
  - `packages/dartclaw_workflow/tool/generate_workflow_schema.dart` writes `JsonEncoder.withIndent('  ')` output plus a trailing newline, following `packages/dartclaw_kernel/tool/generate_config_schema.dart` and `tool/regenerate_fitness_baseline.dart`, and reusing `test/fitness_support.dart#resolveRepoRoot`. `$schema` declares 2020-12; `title` is fixed; no `$id`, no timestamp, no version stamp. A `--check` flag regenerates in memory, compares bytes against the committed file, and on difference exits non-zero naming the artifact path and the regeneration command. Add the `committed artifact is deterministic and drift is actionable` case to `workflow_json_schema_test.dart`. Depends on TI01–TI02.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_json_schema_test.dart --name "committed artifact is deterministic and drift is actionable"` – two renders are byte-identical JSON with a closed root and no `$id`, while `--check` passes current bytes and reports both artifact and regeneration command for missing or changed output
  - **SATISFIES**: S05, SC06

- [ ] **TI04** The drift check runs in the existing fitness harness
  - One new step in `dev/tools/fitness/run_all.sh` invoking the generator's `--check`, placed beside the existing `dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check` step and ahead of the trailing `bash dev/tools/run-fitness.sh` line. No `.github/workflows/ci.yml` edit, no new runner script, no allowlist. Depends on TI03.
  - **Verify**: `cmd: bash dev/tools/fitness/test_run_all_prerequisites.sh && test -z "$(git diff --name-only -- dev/tools .github/workflows | rg -v '^dev/tools/fitness/run_all.sh$')"` – the existing harness passes with the drift check registered beside the config-schema check, and no other runner or CI workflow changes
  - **SATISFIES**: S05, SC07

- [ ] **TI05** The corpus validates against the artifact, invalid documents do not, and the emitted vocabulary is closed
  - Create `packages/dartclaw_workflow/test/workflow/workflow_schema_corpus_test.dart` importing the emitter: a walker descends the artifact per corpus document (resolving the step-type branch by reading `type`, then applying base plus branch) and checks properties, closure, types, enums, `oneOf` branches and `required`. Corpus is the three `lib/src/workflow/definitions/*.yaml` plus the four git-tracked `.dartclaw/workflows/custom/*-inline.yaml`, resolved via `resolveRepoRoot`. Companion assertions pin the emitted keyword set and `type` values to the closed vocabulary, and compare the artifact's declared keys, aliases, enum members and per-step-type applicability against the rule source in both directions. Depends on TI03.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_schema_corpus_test.dart` – all seven maintained definitions and every legal polymorphic shape validate; each invalid mutation reports its path; artifact vocabulary, keys, aliases, enums and applicability equal the rule source in both directions under `unorderedEquals`
  - **SATISFIES**: S01, S02, S03, S04, S06

- [ ] **TI06** The package's fitness gates account for the new file and still prove framework agnosticism
  - Regenerate `packages/dartclaw_workflow/test/fitness_baseline.json` via `tool/regenerate_fitness_baseline.dart` so it records the emitter; confirm the emitter is inside `dev/tools/fitness/check_no_framework_coupling.sh`'s scan scope and **not** added to its exclusion list; confirm the barrel gains no export line. Add the `emitted vocabulary is framework agnostic` case to `workflow_json_schema_test.dart`. Depends on TI01–TI05.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/fitness_test.dart dev/fitness/test/barrel_show_clauses_test.dart && dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_json_schema_test.dart --name "emitted vocabulary is framework agnostic" && bash dev/tools/fitness/check_no_framework_coupling.sh && git diff --exit-code -- packages/dartclaw_workflow/lib/dartclaw_workflow.dart packages/dartclaw_workflow/lib/src/workflow/schema_validator.dart packages/dartclaw_workflow/test/workflow/schema_validator_test.dart dev/fitness/test/allowlist/barrel_show_clauses.txt dev/tools/fitness/check_no_framework_coupling.sh` – the new emitter is recorded at its actual ceiling, framework and artifact literals stay absent, and the barrel, subset validator, allowlists and scan rules remain unchanged
  - **SATISFIES**: SC02, SC03, SC04, SC05

- [ ] **TI07** The artifact and its gate are discoverable in the docs
  - `dev/architecture/workflow-architecture.md` § 18 gains the emitted-artifact subsection (generation-only rule, the union-then-narrow step shape, what the schema deliberately does not cover) with its "Current through" marker bumped; `dev/fitness/README.md` gains the gate's what/why/how-to-resolve entry; `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` gains the regeneration command beside the fitness-baseline one; `docs/guide/workflows.md` points authors at the artifact and how to attach it in an editor; CHANGELOG records the new published artifact.
  - **Verify**: `cmd: rg -q 'workflow.schema.json' dev/architecture/workflow-architecture.md dev/fitness/README.md docs/guide/workflows.md CHANGELOG.md && rg -q 'generate_workflow_schema.dart' dev/fitness/README.md dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md && rg -qi 'validator.only' dev/architecture/workflow-architecture.md && rg -qi 'editor|attach' docs/guide/workflows.md && ! rg -q 'https?://[^ )]*workflow.schema.json' docs/guide/workflows.md && dart analyze --fatal-infos && dart format --line-length=120 --output=none --set-exit-if-changed .` – the architecture explains generation-only and validator-only scope, contributor docs give regeneration and resolution steps, the guide gives a local editor attachment without a false published URL, CHANGELOG records the artifact, and the CI-equivalent gate passes
  - **SATISFIES**: SC08, SC09

### Execution Contract

- TI01 → TI02 build one projection and must land before TI03 writes the artifact; TI04 and TI05 both read that artifact and are independent of each other.
- If the corpus gate (TI05) fails on a shape the parser accepts, the emitter is wrong. Fix the projection – never loosen `additionalProperties`, exempt a corpus file, or edit the workflow YAML.
- If the corpus gate fails because the rule source does not declare something the parser accepts, stop: that is an S16 gap, fixed in the rule source under S16's contract, not papered over in the emitter.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only._

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: bash dev/tools/fitness/test_run_all_prerequisites.sh && bash dev/tools/fitness/run_all.sh && test -z "$(git diff --name-only -- dev/tools .github/workflows | rg -v '^dev/tools/fitness/run_all.sh$')"` → `cmd: bash dev/tools/fitness/test_run_all_prerequisites.sh && test -z "$(git diff --name-only -- dev/tools .github/workflows | rg -v '^dev/tools/fitness/run_all.sh$')"`

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI07 Verify target repaired | Stale targets: – | `cmd: rg -q 'workflow.schema.json' dev/architecture/workflow-architecture.md dev/fitness/README.md docs/guide/workflows.md CHANGELOG.md && rg -q 'generate_workflow_schema.dart' dev/fitness/README.md dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md && rg -qi 'validator.only' dev/architecture/workflow-architecture.md && rg -qi 'editor|attach' docs/guide/workflows.md && ! rg -q 'https?://[^ )]*workflow.schema.json' docs/guide/workflows.md && dart analyze --fatal-infos && dart format --line-length=120 --output=none --set-exit-if-changed . && bash dev/tools/test_workspace.sh && bash dev/tools/fitness/run_all.sh` → `cmd: rg -q 'workflow.schema.json' dev/architecture/workflow-architecture.md dev/fitness/README.md docs/guide/workflows.md CHANGELOG.md && rg -q 'generate_workflow_schema.dart' dev/fitness/README.md dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md && rg -qi 'validator.only' dev/architecture/workflow-architecture.md && rg -qi 'editor|attach' docs/guide/workflows.md && ! rg -q 'https?://[^ )]*workflow.schema.json' docs/guide/workflows.md && dart analyze --fatal-infos && dart format --line-length=120 --output=none --set-exit-if-changed .`

### Run: 2026-09-08 14:19 UTC – observations

2026-09-08 16:14 CEST owner scheduling override: one focused independent review and relevant checks per story. Full workspace and full fitness runs in task Verify commands are deferred to the final combined A+B gate, with no acceptance requirement removed. The retained command proves the story-local checks; prose referring to full-suite success describes final milestone evidence. Standard fast-tier closure remains; broad integration, platform and release verification run at the end.
