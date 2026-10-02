# Workflow rc.4 alignment

**Plan**: dev/bundle/docs/specs/0.27.2/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: Let a maintainer run the one-story and inline workflows with the installed AndThen 1.0 plugin after its skill and story-status changes.

**Expected Outcomes**:

- [OC01] The one-story pipeline is available as `story-and-implement`, with an inline variant and `story.sh` helper, for an inline description or an existing FIS.
- [OC02] The maintainer custom workflows load and carry review findings into remediation without a retired council skill; inline plan execution requests the supported fast verification scope.
- [OC03] Plan discovery presents only runnable stories and describes done-only dependency pruning accurately.

## Required Context

- `docs/specs/0.27.2/andthen-rc4-alignment.md#decisions-settled-with-the-maintainer-2026-10-02` – fixes the rename, council removal, and inline flag.
- `docs/specs/0.27.2/andthen-rc4-alignment.md#changes` – assigns C1–C4 and workflow-side C7/C13/C14.
- `docs/specs/0.27.2/andthen-rc4-alignment.md#done-when` – defines the retired-term and fast-tier acceptance.
- `docs/specs/0.27.2/andthen-rc4-alignment.md#not-in-this-change` – excludes adjacent workflow repairs.

## Acceptance Scenarios

- **S01 [OC01] The renamed one-story pipeline handles both supported inputs**
  - **Given** a workflow registry containing shipped and maintainer definitions, and an inline description sufficient to draft Intent or a reusable existing FIS
  - **When** a maintainer selects `story-and-implement` or `story-and-implement-inline` with an inline description or an existing FIS
  - **Then** that name resolves, the description path generates one FIS, the existing path reuses it, and `implement` receives a nonempty `spec_path` from the unchanged `spec` step/output contract.

- **S02 [OC01] Written requirements are still rejected by the one-story classifier**
  - **Given** FEATURE points to an existing PRD or other written requirements that are not an AndThen FIS
  - **When** the renamed workflow classifies the input
  - **Then** it fails with the `plan-and-implement` direction before synthesis or implementation, rather than treating the file as inline text.

- **S03 [OC02] Custom reviews run and aggregate with only the installed plugin**
  - **Given** any of the three maintainer custom workflows previously carrying a council step
  - **When** its definition is loaded and its first review completes
  - **Then** no council skill is required, its remaining review report and counts feed the existing aggregate keys, and gating findings still enter remediation.

- **S04 [OC02] Inline plan execution passes the supported scope flag**
  - **Given** an inline plan has a runnable story
  - **When** its per-story `implement` step invokes `andthen:exec-plan`
  - **Then** the invocation includes `--no-full-tier` and the FIS path, while the shipped `plan-and-implement` invocation retains its full-tier behavior.

- **S05 [OC03] Discovery keeps blocked dependents out of a resume**
  - **Given** a JSON plan with done, skipped, and pending FIS-bearing stories, including a pending dependent of a skipped story
  - **When** `dartclaw-discover-andthen-plan` emits `story_specs`
  - **Then** it omits done/skipped stories and skipped dependents, prunes only raw `done` dependencies from emitted entries, and keeps the plan path with an empty catalog when no story is runnable.

- **S06 [OC01] Synthesis cannot succeed with an empty FIS handoff**
  - **Given** an inline FEATURE requiring the `spec` step to synthesize a FIS
  - **When** synthesis cannot produce a readable FIS and a nonempty `spec_path`
  - **Then** the producing `spec` step fails explicitly and `implement` does not run with an empty path; the classifier may still emit an empty path while synthesis is pending.

## Structural Criteria

- **SC01** The rename covers the workflow definition filename/name, custom filename/name, materialization/registry expectations, CLI fixtures, test and golden identities, shell runners, and `story.sh`; the old one-story name has no alias.
- **SC02** The `spec` step ID, `spec_path`/`spec_source` output names, `dartclaw-discover-andthen-spec` name, workflow review output keys, and configured failure policies stay intact. SchemaValidator and output normalization remain the only validation authorities; no second parser, validator, required-output setting, framework literal, or entry-gate workaround is added.
- **SC03** Owned production assets, tests, fixtures, and scripts contain none of the retired literals listed in the source's Done when section; rewritten negative tests retain an invalid-input assertion rather than losing rejection coverage.
- **SC04** Unconstrained scalar path outputs retain empty/null/no-claim capture, containment, and argument safety; list outputs and strict/soft behavior outside scalar filesystem path outputs remain unchanged. A declared scalar path schema violation fails the producing step.

## Scope & Boundaries

### Work Areas

- `packages/dartclaw_workflow/lib/src/workflow/definitions/`, `packages/dartclaw_workflow/skills/dartclaw-discover-andthen-{plan,spec}/SKILL.md`, and `.dartclaw/workflows/custom/`.
- Existing scalar path-output authorities: `packages/dartclaw_workflow/lib/src/workflow/{schema_validator,output_normalization,context_extractor,execution_envelope_schema}.dart` and their focused tests. Only string `minLength` support and scalar `format: path` schema enforcement/projection are added.
- `packages/dartclaw_workflow/test/` including contract, registry, integration, scenario, fixture, and golden files; `apps/dartclaw_cli/test/commands/` workflow and asset tests.
- `dev/tools/dartclaw-workflows/{run.sh,story.sh,review.sh}`, `dev/testing/profiles/workflow-contract/run.sh`, and `dev/testing/profiles/workflow-live/run.sh` selector/labels; `apps/dartclaw_cli/lib/` only if a real old-name reference is found.

### What We're NOT Doing

- Runtime composition and API/UI fixtures – story S02 owns them.
- Remaining Markdown docs, package `CLAUDE.md`/`README.md`, prose scenarios, visual NDJSON, changelog, source-wide sweep, and live provider qualification – story S03 owns them.
- The unrelated `technical_research`, `plan.md`, stale pre-0.19 docs, and code-review argument issues in the source's non-goals – this story is rc.4 alignment only.

## Architecture Decision

**Approach**: Rename existing assets and remove council branches. Extend SchemaValidator's string `minLength` support; validate resolved scalar path outputs through existing output normalization and project the same declared constraint through the envelope owner. Only the built-in/inline producing `spec_path` declares `minLength: 1`; the classifier remains unconstrained.
**Why this over the floor**: C1–C2 require the asset changes. Asset-only alignment cannot satisfy Done when's empty-success refusal: filesystem paths bypass authored-schema validation, and SchemaValidator rejects `minLength`. Extending these existing authorities supplies S06 without a second validator or workflow-specific engine rule.

## Constraints & Gotchas

- **Constraint**: The source's literal sweep includes tests and fixtures, including negative cases – replace stale literals with equivalent invalid or current examples while preserving each test's original assertion; story S03 handles history and documentation exceptions.
- **Constraint**: The producing path contract is enforced after filesystem resolution through `output_normalization.dart#validateSchema`. Keep nullable no-claim/capture in the envelope and unconstrained empty classifier output; an authored `minLength` does not work until the existing validator and scalar path validation/projection support it. No extra schema keyword or list-output support belongs to this fix.
- **Constraint**: The private FIS and plan are canonical; execution uses the exported bundle paths in the public checkout.

## Implementation Plan

### Implementation Tasks

- **TI01** Resolved scalar filesystem paths honor authored schemas through the existing output-normalization authority, and SchemaValidator supports string `minLength` with path-schema violations fatal.
  - `packages/dartclaw_workflow/lib/src/workflow/schema_validator.dart#SchemaValidator` and `packages/dartclaw_workflow/lib/src/workflow/output_normalization.dart#validateSchema` are the existing checking authorities.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/schema_validator_test.dart packages/dartclaw_workflow/test/workflow/workflow_validator_output_schema_rules_test.dart packages/dartclaw_workflow/test/workflow/context_extractor_path_outputs_test.dart` – the sole checker admits string `minLength` at workflow load; a missing or empty resolved constrained scalar path fails the producer, a valid path passes, and null/no-claim can still capture a valid artifact. SC04's unconstrained empty/null/capture, containment, argument safety, list-output, and unrelated strict/soft behavior are preserved.
  - **SATISFIES**: S06, SC02, SC04

- **TI02** The envelope owner projects the producer's declared string constraint while retaining nullable no-claim/capture; built-in and inline `spec` outputs declare `minLength: 1`, and both classifiers remain unconstrained.
  - After TI01; `packages/dartclaw_workflow/lib/src/workflow/execution_envelope_schema.dart#buildExecutionEnvelopeSchema` owns the model-facing schema, derived from the same authored schema the host validates. Add the focused `execution_envelope_schema_test.dart` suite for this projection.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/execution_envelope_schema_test.dart packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart` – both producers carry the same authored `minLength` in their envelope string branch, nullable capture remains available, classifier pending emptiness remains valid, and no additional schema keywords or list-output behavior are introduced.
  - **SATISFIES**: S06, SC02, SC04

- **TI03** The shipped one-story definition is `story-and-implement.yaml`, with its name and description aligned to `andthen:exec-plan`.
  - After TI01–TI02.
  - Rename its integration suite with `git mv` to `workflow_builtin_story_and_implement_test.dart`; S06 needs producer validation, not an implement entry gate that merely skips the step.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_registry_test.dart` – registry loads the new name and no old-name alias.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart` – the existing step and output contracts remain valid.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_builtin_story_and_implement_test.dart` – successful synthesis passes a readable nonempty FIS path to implement, while a producer claiming success with an empty path fails before implement; classifier-pending emptiness remains valid.
  - **SATISFIES**: S01, S06, SC01, SC02

- **TI04** The inline one-story definition is `story-and-implement-inline.yaml` and aggregates only `integrated-review`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart` – inline review source, aggregate keys, remediation gate, and no council dependency are asserted.
  - **SATISFIES**: S01, S03, SC01, SC02

- **TI05** The inline plan definition aggregates only `plan-review` and invokes per-story `andthen:exec-plan --no-full-tier` without its former verification-scope prose.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart` – the test compares inline and shipped per-story prompts and the remaining aggregate source.
  - **SATISFIES**: S03, S04, SC02

- **TI06** The inline review/remediation definition aggregates only `gap-review`, with the council step and council-only parallel framing gone.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_registry_test.dart` – all committed custom definitions load without exclusions.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart` – the single review source and remediation keys are asserted.
  - **SATISFIES**: S03, SC02

- **TI07** Discovery skill payloads use the new one-story name and accurately describe done-only pruning and an empty catalog with no runnable story.
  - `packages/dartclaw_workflow/skills/dartclaw-discover-andthen-plan/SKILL.md#Discovery Rules` and `dartclaw-discover-andthen-spec/SKILL.md#Classification` are the existing contracts.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/built_in_skill_inventory_test.dart packages/dartclaw_workflow/test/workflow/scenarios/discover_andthen_plan_test.dart` – payload text and skipped-dependent behavior agree.
  - **SATISFIES**: S02, S05, SC02

- **TI08** Workflow test drivers, fixtures, goldens, and negative cases use the new identity while preserving their original context-chain, rejection, materialization, and integration assertions.
  - After TI03, the shared stub symbol and `workflow-contract/run.sh` test path follow the renamed suite; keep the existing `live-e2e` tags on provider tests.
  - **Verify**: `cmd: bash dev/testing/profiles/workflow-contract/run.sh` – workflow contracts, the renamed one-story integration suite, review aggregation, and preconditions pass.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow` – materialization, golden, scenario, and other package tests preserve their assertions.
  - **SATISFIES**: S01, S02, S03, S06, SC01, SC02, SC03

- **TI09** CLI tests and embedded-asset expectations resolve and display `story-and-implement`; retired descriptive strings in owned tests and the sample JSON fixture are updated.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/commands/serve_asset_resolution_test.dart apps/dartclaw_cli/test/commands/workflow/cli_progress_printer_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_show_command_test.dart` – the new definition is materialized, shown, and named in progress output.
  - **SATISFIES**: S01, SC01, SC03

- **TI10** The helper is `story.sh`, runner examples and live-profile selectors use the new identity, and `review.sh` describes its surviving review path.
  - **Verify**: `cmd: bash -n dev/tools/dartclaw-workflows/story.sh dev/tools/dartclaw-workflows/run.sh dev/tools/dartclaw-workflows/review.sh dev/testing/profiles/workflow-live/run.sh` – shell syntax is valid.
  - **Verify**: `inspect: dev/tools/dartclaw-workflows/story.sh:16` – the helper invokes `story-and-implement-inline`.
  - **Verify**: `inspect: dev/testing/profiles/workflow-live/run.sh:196` – the canary selector, test filter, and log label use the new name.
  - **Verify**: `inspect: dev/tools/dartclaw-workflows/run.sh:13` – the runner example names `story.sh` and the new workflow.
  - **SATISFIES**: S01, SC01, SC03

- **TI11** Every retired literal in S01-owned files is mapped to a corrected contract, current fixture, or equivalent negative case, with no old-name alias.
  - **Verify**: `cmd: ! git grep -n -i -e 'andthen-some:' -e 'andthen:ops' -e 'andthen:prd' -e 'andthen:quick-review' -e 'exec-spec' -e 'spec-and-implement' -e 'spec-ready' -e '--mode trade-off' -- packages/dartclaw_workflow/lib packages/dartclaw_workflow/skills packages/dartclaw_workflow/test apps/dartclaw_cli/lib apps/dartclaw_cli/test .dartclaw/workflows/custom dev/tools/dartclaw-workflows/run.sh dev/tools/dartclaw-workflows/story.sh dev/tools/dartclaw-workflows/review.sh dev/testing/profiles/workflow-contract/run.sh dev/testing/profiles/workflow-live/run.sh` – no match in tracked owned files; inspect renamed untracked files before staging.
  - **SATISFIES**: SC01, SC03

## Implementation Observations

All TI01–TI11 Verify targets passed. The fast tier passed with 11,166 tests, 58 configured skips, and no analyzer issues; the post-review workflow package rerun passed 2,036 tests with 11 configured skips. Formatting checked 2,119 files with no changes. The contract profile passed 213 tests, the affected CLI suites passed 46, and shell syntax and the retired-literal scan passed.

Reviewed: Independent quick code review found one low-severity contradiction between the producer's path description and its `minLength: 1` schema; the reviewer fixed both shared descriptions and the affected contract assertion, then passed 76 affected tests. No findings remain open.

Chain attestation: OC01 is covered by S01/S02/S06 through TI01–TI04 and TI08–TI10: the renamed pipelines resolve, classify both input forms, and stop on an empty synthesis handoff. OC02 is covered by S03/S04 through TI04–TI06 and TI08: the three custom workflows aggregate their surviving review source and the inline plan passes `--no-full-tier`. OC03 is covered by S05 through TI07: discovery omits blocked dependents, prunes raw `done` dependencies only, and retains the plan path with an empty runnable catalog.

#### DRIFT

- spec-stale: S01 updated the two S02-owned runtime fixture name expectations in `service_wiring_andthen_skills_test.dart` and `headless_runtime_test.dart` after their old-name assertions failed the required fast tier; no runtime mechanism changed. | Stale targets: S01 Scope & Boundaries, S02 runtime fixture assignment | –
