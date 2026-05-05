# S13 — Pre-Decomposition DRY Helpers + YamlTypeSafeReader

**Plan**: ../plan.md
**Story-ID**: S13

## Feature Overview and Goal

Two pure DRY passes shipped as one story, both prerequisites for the W4 decomposition wave:

1. **Part A — `workflow_executor` DRY helpers** (4 named extractions): `mergeContextPreservingPrivate`, `_fireStepCompleted` (or `WorkflowRunMutator.recordStep*`), workspace-level `truncate()` in `dartclaw_core`, `unwrapCollectionValue`. Removes 12+ duplicated context-merge spreads, 12 `WorkflowStepCompletedEvent` constructions, 4 char-count `_truncate` duplicates, and the byte-for-byte map/foreach auto-unwrap blocks.
2. **Part B — `YamlTypeSafeReader` + parser conversions**: typed YAML helpers in `dartclaw_config`; convert all "Invalid type for …" warn-and-ignore sites in `config_parser.dart` (≥51 per plan; `config_parser.dart` actual count is 57 + 23 in sibling `config_parser_governance.dart` part — see Constraints) to use them; apply the same typed-coercion pattern to the **mechanical** TD-086 sites in `workflow_definition_parser.dart` so scalar/list/extraction errors surface as field-specific `FormatException`s rather than raw `TypeError`/`ArgumentError`. Targets `config_parser.dart` ≤1,200 LOC (≥300 LOC reduction).

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S13" entry under per-story File Map; Shared Decisions #5 — DRY-helper contract; Binding Constraints #2, #26, #71, #73)_

## Required Context

### From `plan.md` — "S13: Pre-Decomposition DRY Helpers + YamlTypeSafeReader"
<!-- source: ../plan.md#s13-pre-decomposition-dry-helpers--yamltypesafereader -->
<!-- extracted: e670c47 -->
> **Part A — workflow_executor DRY helpers** (four one-shot extractions). (a) `mergeContextPreservingPrivate(WorkflowRun run, WorkflowContext context) → Map<String, dynamic>` — replaces the 12–14 duplicated map-spreads in `workflow_executor.dart` that preserve underscore-prefixed internal metadata keys (`_map.current`, `_foreach.current`, `_loop.current`, `_parallel.*`) across context merges. (b) `_fireStepCompleted(stepIndex, success, result)` helper (or equivalent `WorkflowRunMutator.recordStepSuccess/Failure/Continuation`) — replaces 12 duplicated `WorkflowStepCompletedEvent(...)` constructions. (c) Promote `truncate(String, int, {suffix})` from `packages/dartclaw_server/lib/src/templates/helpers.dart` to a new `dartclaw_core/lib/src/util/string_util.dart`. Delete 4 char-count `_truncate` duplicates in favour of the core util. Keep UTF-8-aware byte-truncate variants as separate named functions (`truncateUtf8Bytes`) with clear semantics. (d) `unwrapCollectionValue(Object? raw, {required String stepId, required String mapOverKey}) → List<dynamic>?` — dedupes the two verbatim auto-unwrap switches in `workflow_executor.dart:3285-3303` (map) and `3707-3725` (foreach) that promote a single-entry `Map` with a list value into the iteration collection. Place alongside `mergeContextPreservingPrivate` in a file-local workflow helper module.
>
> **Part B — YamlTypeSafeReader + config_parser conversion + workflow parser coercion (TD-086 mechanical slice)**. Add typed helpers to `packages/dartclaw_config/lib/src/` (likely a new `yaml_type_safe_reader.dart`): `readString`, `readInt`, `readBool`, `readMap`, `readStringList`, plus a generic `T? readField<T>(...)`. Each helper encapsulates the "type-check + warn-and-ignore" pattern. Mechanically convert the 51 inline "Invalid type for …" blocks in `config_parser.dart` to use these helpers. Target: cut `config_parser.dart` by ~300-400 LOC and keep it ≤1,200 LOC. … Also apply the same typed-coercion pattern inside `dartclaw_workflow` YAML parsing for the low-risk TD-086 defects: replace unguarded `as String?` / lazy `raw.cast<String>()` parser paths with eager typed reads that throw a friendly `FormatException` naming the offending field; normalize `extraction.type` / missing `pattern` errors away from `ArgumentError` / `TypeError`. Defer the design-heavy TD-086 pieces (duplicate-key policy, max-depth / max-bytes limits, parser-vs-validator semantic-home decision, and full gate-expression diagnostics) to S23 triage unless they prove mechanical during this pass.

### From `plan.md` — "S13 Acceptance Criteria"
<!-- source: ../plan.md#s13-pre-decomposition-dry-helpers--yamltypesafereader -->
<!-- extracted: e670c47 -->
> - [ ] `mergeContextPreservingPrivate` helper exists and is used at all duplicated sites in `workflow_executor.dart`
> - [ ] `_fireStepCompleted` (or `WorkflowRunMutator` method) exists and is used at all 12 sites
> - [ ] `truncate()` lives in `dartclaw_core`; 4 char-count `_truncate` duplicates removed
> - [ ] UTF-8-aware variants remain as separately-named functions with documented byte-vs-char semantics
> - [ ] `unwrapCollectionValue` replaces both map- and foreach-step auto-unwrap blocks
> - [ ] `YamlTypeSafeReader` (or equivalent typed helpers) exists in `dartclaw_config`
> - [ ] All 51 inline "Invalid type for …" sites in `config_parser.dart` replaced with helper calls
> - [ ] **TD-086 mechanical parser slice**: workflow parser scalar/list/extraction errors use typed coercion and surface as field-specific `FormatException`s, not raw `TypeError` / `ArgumentError`
> - [ ] `config_parser.dart` LOC reduced by ≥300
> - [ ] `dart test packages/dartclaw_workflow packages/dartclaw_config` passes without changes to test expectations

### From `.technical-research.md` — "Shared Architectural Decisions #5 — DRY-helper contract (S13 → S15)"
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **5. S13 → S15 — DRY-helper contract**
> WHAT: S13 produces `mergeContextPreservingPrivate(WorkflowRun, WorkflowContext) → Map<String, dynamic>`, `_fireStepCompleted(stepIndex, success, result)` (or `WorkflowRunMutator.recordStepSuccess/Failure/Continuation`), `truncate()` in `dartclaw_core/lib/src/util/string_util.dart` (char-count; `truncateUtf8Bytes` separate), `unwrapCollectionValue(...)`. `YamlTypeSafeReader` in `dartclaw_config`.
> PRODUCER: S13. CONSUMER: S15. WHY: S15 carries duplication across the split without these.

### From `.technical-research.md` — "Binding PRD Constraints" (S13-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #2 (Constraint): "No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`." — Applies to all stories.
> #26 (FR4): "`config_parser.dart` ≤1,200 LOC using new `YamlTypeSafeReader` helpers (51 inline warnings consolidated)." — Applies to S13.
> #71 (NFR Reliability): "Behavioural regressions post-decomposition: Zero — every existing test remains green." — Applies to S13 (no test-expectation changes permitted).
> #73 (NFR DX): "`dart analyze` workspace-wide: 0 warnings (maintained)." — Applies to S13.
> #75 (FR8): "`SidebarDataBuilder` extracted; 6 call sites collapsed." — listed as a sibling pre-decomposition pass; not directly applicable to S13 but the same call-site-collapse discipline applies here.

## Deeper Context

- `packages/dartclaw_config/CLAUDE.md` § "Gotchas" — `config_parser.dart` is a `part` file under the `dartclaw_config.dart` orchestrator (`part 'config_parser.dart'`, `part 'config_parser_governance.dart'`). New helper libraries imported as standalone files must be imported by the orchestrator (`lib/src/dartclaw_config.dart`); top-level functions in those files are visible inside the `part` files. Do **not** add a new `part` for the typed reader unless the helpers need access to private members of the orchestrator (they do not).
- `packages/dartclaw_workflow/CLAUDE.md` § "Architecture" — `WorkflowExecutor` already delegates per-node-kind dispatch to runners (`bash_step_runner`, `loop_step_runner`, `foreach_iteration_runner`, `map_iteration_runner`, `parallel_group_runner`). `WorkflowStepCompletedEvent` constructions are spread across these — the helper must be reachable from both `workflow_executor.dart` and the per-kind runner files.
- `packages/dartclaw_security/lib/src/content_guard.dart:88` — existing `_truncateUtf8(String, int maxBytes)` is the byte-aware variant; not a duplicate of the char-count `_truncate` family. Stays put or moves alongside `truncate` as `truncateUtf8Bytes` per AC; do not collapse it into `truncate()`.
- `dev/state/TECH-DEBT-BACKLOG.md#td-086` — TD-086 enumerates parser-coercion defects. Only the mechanical slice (raw `TypeError`/`ArgumentError` → field-named `FormatException`) lands here; design-heavy items (duplicate-key policy, max-depth/max-bytes limits, parser-vs-validator semantic-home, full gate-expression diagnostics) are deferred to S23 triage and explicitly out of scope for this story.
- `packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart:331` — sample TD-086 mechanical site: `ExtractionType.values.byName(extractionRaw['type'] as String)` chains a raw cast (throws `TypeError` on absent/non-string) into `byName` (throws `ArgumentError` on unknown enum value). Both throws should normalize to a `FormatException` naming the field.

## Success Criteria (Must Be TRUE)

### Part A — workflow_executor DRY helpers
- [ ] `mergeContextPreservingPrivate(WorkflowRun run, WorkflowContext context) → Map<String, dynamic>` exists in `packages/dartclaw_workflow/lib/src/workflow/` (file-local helper module — name suggested: `workflow_context_helpers.dart`) and is used at every duplicated context-merge site in `workflow_executor.dart`. Verify: `rg "if (e\.key\.startsWith\('_'\) && !e\.key\.startsWith" packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` returns zero post-extraction (the in-line spread pattern disappears).
- [ ] `_fireStepCompleted(stepIndex, success, result)` helper (or equivalent `WorkflowRunMutator.recordStepSuccess/Failure/Continuation` API) exists and is the only construction path for `WorkflowStepCompletedEvent` across `workflow_executor.dart`, `loop_step_runner.dart`, and `foreach_iteration_runner.dart`. Verify: `rg "WorkflowStepCompletedEvent\(" packages/dartclaw_workflow/lib/src/workflow/` returns exactly one match (the helper itself).
- [ ] `truncate(String, int, {String suffix})` lives in `packages/dartclaw_core/lib/src/util/string_util.dart` with char-count semantics; the existing implementation in `packages/dartclaw_server/lib/src/templates/helpers.dart` is removed and that file re-exports / imports the core util.
- [ ] The 4 char-count `_truncate` duplicates are removed: `packages/dartclaw_server/lib/src/turn_runner.dart:853`, `apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart:235`, `apps/dartclaw_cli/lib/src/commands/workflow/workflow_runs_command.dart:99`, plus the `templates/helpers.dart` original (now in core). Verify: `rg "String _truncate\(String " packages apps --include='*.dart'` returns zero matches (allowing `_truncateUtf8`, `_truncateMessage`, `_truncateMemory`, `_truncateBindingId`, `_truncateId` byte/domain variants to remain).
- [ ] UTF-8-aware byte variant exists as a separately-named function `truncateUtf8Bytes(String, int maxBytes)` (location: `packages/dartclaw_core/lib/src/util/string_util.dart` if promoted, otherwise documented to remain in `dartclaw_security/content_guard.dart`). Dartdoc on both `truncate` and `truncateUtf8Bytes` explicitly states char-count vs UTF-8-byte semantics and when to pick which. Verify: dartdoc inspection.
- [ ] `unwrapCollectionValue(Object? raw, {required String stepId, required String mapOverKey}) → List<dynamic>?` exists alongside `mergeContextPreservingPrivate` and replaces both auto-unwrap blocks: in `map_iteration_runner.dart:90-110` (map) and `foreach_iteration_runner.dart:42-60` (foreach). Verify: `rg "auto-unwrapped Map key" packages/dartclaw_workflow/lib/src/workflow/` shows the log message originating from the helper only (≤2 occurrences in source — the helper and the test fixture).

### Part B — YamlTypeSafeReader + parser conversions
- [ ] `YamlTypeSafeReader` helpers exist in a new file `packages/dartclaw_config/lib/src/yaml_type_safe_reader.dart` exposing top-level functions: `readString`, `readInt`, `readBool`, `readMap`, `readStringList`, plus generic `T? readField<T>(Map yaml, String key, List<String> warns, {T? defaultValue})`. The orchestrator `lib/src/dartclaw_config.dart` adds the matching `import` so the part file `config_parser.dart` can call them. (Helpers are ordinary library top-levels, not a new `part` — see Deeper Context note.) Verify: `rg "^(String|int|bool|Map|List).*read(String|Int|Bool|Map|StringList|Field)" packages/dartclaw_config/lib/src/yaml_type_safe_reader.dart` lists all six signatures.
- [ ] All "Invalid type for …" inline warn-and-ignore blocks in `packages/dartclaw_config/lib/src/config_parser.dart` are replaced with helper calls. Plan baselines this as 51; actual count at e670c47 is 57 in `config_parser.dart` plus 23 in the sibling part `config_parser_governance.dart` — convert mechanically wherever the helper applies. Verify: the only surviving `"Invalid type for"` literals are inside `yaml_type_safe_reader.dart` (where the warn-and-ignore message is now centralised). `rg "Invalid type for" packages/dartclaw_config/lib/src/config_parser.dart packages/dartclaw_config/lib/src/config_parser_governance.dart` returns only sites that genuinely cannot use the helper (each carries an inline `// reason: …` comment).
- [ ] **TD-086 mechanical slice**: `packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart` no longer chains raw `as String` / `cast<String>()` / `enum.values.byName(raw as String)` for scalar / list / extraction-type / pattern fields without a typed-coercion guard. Each replaced site throws a `FormatException` with a message naming the offending field (and source-path suffix via the existing `_at(sourcePath)` helper). Verify: deliberately corrupt fixtures (`extraction.type` non-string; `extraction.type` unknown enum value; `extraction.pattern` missing) round-trip through the parser as `FormatException` (not `TypeError` / `ArgumentError`).
- [ ] `packages/dartclaw_config/lib/src/config_parser.dart` LOC reduced by ≥300 from baseline (1,644 LOC at e670c47 → ≤1,344 LOC; ideally ≤1,200 to satisfy Binding Constraint #26). Verify: `wc -l packages/dartclaw_config/lib/src/config_parser.dart` shows the post-conversion count; CHANGELOG `0.16.5 - Unreleased` § Changed gains a one-line bullet recording the reduction and that all "Invalid type for" warnings now route through `YamlTypeSafeReader`.
- [ ] `dart test packages/dartclaw_workflow packages/dartclaw_config` passes with **zero changes to test expectations** (any test edit is a regression — Constraint #71). New tests for `YamlTypeSafeReader` and the TD-086 mechanical fixtures are additive only.

### Health Metrics (Must NOT Regress)
- [ ] `dart analyze` workspace-wide: 0 warnings, 0 errors (Constraint #73).
- [ ] `dart test` workspace-wide passes (covers downstream consumers of the moved `truncate()`: `dartclaw_server`, `dartclaw_cli`).
- [ ] No new dependencies in any pubspec (Constraint #2). The `truncate()` move adds zero deps to `dartclaw_core/pubspec.yaml`.
- [ ] JSON wire formats (workflow YAML schema, REST envelopes, SSE event payloads) unchanged (Constraint #1).
- [ ] `dart format --set-exit-if-changed packages apps` clean.
- [ ] Behavioural parity for both auto-unwrap call sites: existing scenario tests `map_step_execution_test.dart`, `foreach_step_execution_test.dart` (or sibling) remain green without modification.

## Scenarios

### Workflow context merge preserves underscore-prefixed metadata across step boundaries (happy)
- **Given** a workflow run whose `contextJson` carries `_map.current.iterIndex = 3`, `_loop.current.iterCount = 2`, and a user-defined key `analysis.summary = "x"`
- **When** the executor finishes a non-map step that produces a fresh `WorkflowContext` (no `_map.current.*` keys but with new `analysis.summary = "y"`)
- **Then** `mergeContextPreservingPrivate(run, context)` returns a map containing `_loop.current.iterCount = 2` (preserved), `analysis.summary = "y"` (updated), and **excludes** `_map.current.*` keys (filtered by the existing scoping policy on map step transitions); the merged result is byte-for-byte equivalent to today's inline spread at every former call site (verified by replaying recorded contexts through both code paths in a regression test)

### Char-count truncate vs UTF-8 byte truncate behave per documented semantics (edge)
- **Given** a string `s = "héllo"` (5 chars, 6 UTF-8 bytes)
- **When** the call is `truncate(s, 4)` vs `truncateUtf8Bytes(s, 4)`
- **Then** `truncate(s, 4)` returns a 4-char string with the suffix appended per existing `helpers.dart` semantics (`"hé…"` or equivalent — no surrogate-pair splitting at the char boundary because Dart strings are UTF-16 code units in `String.length`); `truncateUtf8Bytes(s, 4)` returns a string whose UTF-8 encoding is ≤4 bytes, never splitting a multi-byte sequence (uses `utf8.decode(..., allowMalformed: true)` to stop at a complete code-point boundary). Both helpers' dartdoc explicitly states which semantic applies and points the reader at the other for the alternative.

### Map / foreach auto-unwrap dedupe — single-entry Map<String, List<...>> promoted to iteration collection (happy)
- **Given** `context['items'] = {'rows': [1, 2, 3]}` (single-entry Map whose value is a List, as commonly emitted by upstream LLM-shaped JSON)
- **When** a `map`-kind step or a `foreach`-kind step runs with `mapOver: items`
- **Then** `unwrapCollectionValue(rawCollection, stepId: 'analyze', mapOverKey: 'items')` returns `[1, 2, 3]`; the controller logs `auto-unwrapped Map key 'rows' to List (3 items)` exactly once (the message originates from the helper, not duplicated in both runners). Existing scenario tests for both step kinds pass without modification.

### TD-086 mechanical slice — malformed `extraction.type` surfaces as friendly FormatException (error)
- **Given** a workflow YAML at `path/to/wf.yaml` whose `extraction.type` is the integer `42` (not a string)
- **When** `WorkflowDefinitionParser.parse()` runs against that input
- **Then** the call throws `FormatException` whose message names the field (`extraction.type` or equivalent) and includes the source-path suffix from `_at(sourcePath)`. The throw is **not** a raw `TypeError` ("type 'int' is not a subtype …") nor an `ArgumentError` from `enum.values.byName`. A second fixture with `extraction.type: 'unknown_value'` produces a `FormatException` listing the valid extraction-type names. A third fixture with missing `pattern` for a regex-mode extraction also produces a `FormatException` naming `extraction.pattern`.

### YamlTypeSafeReader warn-and-ignore preserves observable behaviour (boundary)
- **Given** a config YAML with `port: "not-a-number"` (string where int expected)
- **When** `_parseInt('port', cli['port'], yaml['port'], defaults.port, warns)` is converted to use `readInt('port', yaml, warns, default: defaults.port)`
- **Then** the returned port equals `defaults.port`; `warns` accumulates exactly one entry whose text is byte-equivalent to the pre-extraction message (`Invalid type for port: "String" — using defaults` or close enough that no test expectation needs to change). This holds for every converted site.

## Scope & Boundaries

### In Scope
- **Part A (workflow_executor DRY)**: extract the four named helpers (`mergeContextPreservingPrivate`, `_fireStepCompleted` / `WorkflowRunMutator`, `truncate` move-to-core, `unwrapCollectionValue`); update all duplicated call sites in `workflow_executor.dart`, `loop_step_runner.dart`, `foreach_iteration_runner.dart`, `map_iteration_runner.dart`; remove the 4 char-count `_truncate` duplicates in `turn_runner.dart`, `workflow_status_command.dart`, `workflow_runs_command.dart`, and the moved-from-server `templates/helpers.dart`.
- **Part B (YamlTypeSafeReader + conversions)**: author the typed reader in `dartclaw_config`; convert the inline "Invalid type for …" warn-and-ignore sites in both `config_parser.dart` and (where mechanical) `config_parser_governance.dart`; apply the typed-coercion pattern to the **mechanical** TD-086 sites in `workflow_definition_parser.dart` (scalar / list / extraction-type / pattern); add additive tests for the reader and for the TD-086 fixtures.
- **CHANGELOG entry** (one bullet under `0.16.5 - Unreleased` § Changed) recording the reduction and the centralised "Invalid type for" routing.

### What We're NOT Doing
- **Workflow_executor decomposition (S15)** — this story produces the helpers; consumption beyond the immediate dedupe at existing call sites belongs to S15. Do not start splitting `foreach_iteration_runner.dart`, `context_extractor.dart`, or `workflow_executor_helpers.dart` here.
- **Promoting helpers beyond the named four in Part A** — only `mergeContextPreservingPrivate`, `_fireStepCompleted`/`WorkflowRunMutator`, `truncate`, and `unwrapCollectionValue` are in scope. Other repeated patterns (e.g. context-filter-by-prefix, `recordFailure+persist+inFlightCount-- +fire-event` branches) are S15's `PromotionCoordinator` problem.
- **Design-heavy TD-086 portions** — duplicate-key policy, max-depth / max-bytes limits, parser-vs-validator semantic-home decision, full gate-expression diagnostics. Deferred to S23 triage; do not touch them here.
- **Test rewrites** — Constraint #71 forbids changing existing test expectations. New tests for the typed reader and TD-086 fixtures are additive; if an existing test breaks, the conversion is wrong, not the test.
- **Char-count vs byte semantics fusion** — `truncate` and `truncateUtf8Bytes` stay as separate functions; resist any "smart" combined helper that picks based on input.
- **Renaming `WorkflowStepCompletedEvent`** — only the construction path changes.

### Agent Decision Authority
- **Autonomous**: choosing between a free-function `_fireStepCompleted` helper module vs a `WorkflowRunMutator` extension type, naming the helper module file (`workflow_context_helpers.dart` is suggested but not prescribed), inlining vs hoisting the per-helper warn-message format, and whether `truncateUtf8Bytes` lives next to `truncate` in `dartclaw_core/lib/src/util/string_util.dart` or stays in `dartclaw_security` (pick whichever produces fewer cross-package imports — document the choice in the helper's dartdoc).
- **Escalate**: any test-expectation change (always a regression unless explicitly approved); any new pubspec dependency; any TD-086 site that turns out to need design input rather than mechanical conversion (defer to S23 with a one-line note in `dev/state/TECH-DEBT-BACKLOG.md` under TD-086).

## Architecture Decision

**We will**: bundle Part A + Part B as one story under the 1:1 story↔FIS invariant — both are mechanical DRY passes with no inter-coupling, and both unblock S15's decomposition (S13→S15 contract per Shared Decision #5). (Over a split that would carry two trivial FIS through the same wave with identical risk profile and no parallelism gain.)

## Technical Overview

### Data Models
No new data models. Helpers return existing types (`Map<String, dynamic>`, `List<dynamic>?`, `String`). `_fireStepCompleted` (or `WorkflowRunMutator.recordStepSuccess/Failure/Continuation`) consumes existing `WorkflowStepCompletedEvent` constructor parameters — only the construction call site relocates.

### Integration Points
- `mergeContextPreservingPrivate` and `unwrapCollectionValue` live in a new file-local helper module under `packages/dartclaw_workflow/lib/src/workflow/` (suggested name `workflow_context_helpers.dart`). Imported by `workflow_executor.dart`, `loop_step_runner.dart`, `foreach_iteration_runner.dart`, `map_iteration_runner.dart`.
- `_fireStepCompleted` / `WorkflowRunMutator` lives next door (same module or a sibling `workflow_run_mutator.dart`).
- `truncate` / `truncateUtf8Bytes` live in `packages/dartclaw_core/lib/src/util/string_util.dart`. Exported via `dartclaw_core` barrel under a `show truncate, truncateUtf8Bytes` clause (mind Shared Decision #20 / Binding Constraint #20: per-pkg soft cap `dartclaw_core ≤80`).
- `YamlTypeSafeReader` lives in `packages/dartclaw_config/lib/src/yaml_type_safe_reader.dart` as ordinary top-level functions. The orchestrator `lib/src/dartclaw_config.dart` gains a single `import 'yaml_type_safe_reader.dart';` line; the part file `config_parser.dart` calls the helpers without further import (part-of semantics — see `dartclaw_config/CLAUDE.md` § Gotchas). Not exported from the public barrel — these are internal parser helpers.

## Code Patterns & External References

```
# type | path/url                                                                                        | why needed
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart:253-281                      | Pattern A: representative context-merge spread that mergeContextPreservingPrivate replaces (8 startsWith('_') sites)
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart:283,378,587,670,698,748,776  | Part A.b: 7 of 12 WorkflowStepCompletedEvent construction sites in this file
file   | packages/dartclaw_workflow/lib/src/workflow/loop_step_runner.dart:188,254,430                   | Part A.b: 3 more of the 12 sites
file   | packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart:513,563               | Part A.b: final 2 of the 12 sites
file   | packages/dartclaw_workflow/lib/src/workflow/map_iteration_runner.dart:90-110                    | Part A.d: map auto-unwrap block (one of two verbatim copies)
file   | packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart:42-60                 | Part A.d: foreach auto-unwrap block (verbatim sibling — collapse with map into unwrapCollectionValue)
file   | packages/dartclaw_server/lib/src/templates/helpers.dart:47-51                                   | Part A.c: existing char-count truncate — promote to dartclaw_core/util/string_util.dart
file   | packages/dartclaw_server/lib/src/turn_runner.dart:853                                           | Part A.c: char-count _truncate duplicate to delete
file   | apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart:235                    | Part A.c: char-count _truncate duplicate to delete
file   | apps/dartclaw_cli/lib/src/commands/workflow/workflow_runs_command.dart:99                       | Part A.c: char-count _truncate duplicate to delete
file   | packages/dartclaw_security/lib/src/content_guard.dart:88-93                                     | Part A.c: byte-aware _truncateUtf8 — keep separate; promote to truncateUtf8Bytes if relocated
file   | packages/dartclaw_config/lib/src/config_parser.dart:164-171,180-200,260-275                     | Part B: representative "Invalid type for …" sites (57 total in this file)
file   | packages/dartclaw_config/lib/src/config_parser_governance.dart                                  | Part B: sibling part with 23 more "Invalid type for" sites — convert mechanically
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart:325-336             | Part B / TD-086: extraction.type / pattern raw-cast site
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart:131-160,275,306,339,356-377 | Part B / TD-086: representative `as String?` / `cast<String>()` sites for mechanical conversion
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart:53-76               | Part B / TD-086: existing FormatException-throwing helpers (`_requireString`, `_at(sourcePath)`) — reuse pattern for new typed reads
```

## Constraints & Gotchas

- **Constraint** (Binding #2): no new dependencies — Workaround: all helpers built from existing `dart:core`, `dart:convert`, `package:yaml` (already a dep of `dartclaw_config`).
- **Constraint** (Binding #71): zero behavioural regression / zero test-expectation changes — Workaround: convert one site at a time, run the relevant package's tests after each, treat any test-expectation diff as a conversion bug.
- **Avoid**: adding the typed reader as a new `part` of the orchestrator — Instead: add it as a normal library file imported by `lib/src/dartclaw_config.dart`. Top-level functions in imported libraries are visible inside `part` files without further plumbing. (See `dartclaw_config/CLAUDE.md` § Gotchas.)
- **Avoid**: making `truncate` "clever" (auto-detecting byte vs char) — Instead: keep two named functions with explicit dartdoc; the cognitive cost of reading the call site beats the cognitive cost of guessing what one fused helper does.
- **Avoid**: rewriting `WorkflowStepCompletedEvent` constructor signatures — Instead: only the construction path moves; the event class itself is untouched.
- **Critical** (TD-086 scope): mechanical slice only. If a site needs to decide *between* two valid behaviours (e.g. duplicate-key tolerate-vs-reject), stop, leave the raw cast in place with a `// TD-086: deferred to S23 — <reason>` comment, and move on. Do not invent semantics.
- **Critical** (auto-unwrap parity): the two existing log messages differ only in the controller-kind prefix (`Map step '…'` vs `Foreach step '…'`). The helper takes `stepId` + `mapOverKey` so the caller can format the log message with the right prefix — preserve byte-for-byte log-message parity (test fixtures may assert on the exact string).
- **Critical** (helpers from `_truncate` in `apps/dartclaw_cli`): the CLI uses `_truncate(value, width).padRight(width)` — verify the new `truncate()` has compatible behaviour for the exact-`maxLength` boundary case (current implementation in `helpers.dart` returns the original string when `s.length <= maxLength`, which `padRight` then pads correctly). Run the CLI status / runs unit tests after the swap.
- **Note** (LOC count discrepancy): plan AC says "all 51 inline 'Invalid type for …' sites in `config_parser.dart`"; actual baseline at e670c47 is 57 in `config_parser.dart` + 23 in `config_parser_governance.dart`. Convert all of them (the spirit of the AC is "every mechanical site"); plan baseline 51 was from an earlier audit and is not a hard cap.

## Implementation Plan

> **Vertical slice ordering**: Part A first (one helper per task — each task lands a working slice on its own), then Part B (reader → config conversions → workflow parser TD-086 mechanical slice). LOC verification + workspace-wide test sweep last.

### Implementation Tasks

#### Part A — workflow_executor DRY helpers

- [ ] **TI01** `mergeContextPreservingPrivate(WorkflowRun run, WorkflowContext context) → Map<String, dynamic>` extracted into a new file-local module `packages/dartclaw_workflow/lib/src/workflow/workflow_context_helpers.dart` and used at every duplicated context-merge site in `workflow_executor.dart`.
  - The 8 underscore-prefix-preserving spreads in `workflow_executor.dart:259,275,467,502,563,579,…` collapse to one call each. Helper takes the run's existing `contextJson`, the new `context.toJson()`, and an optional `extraExclusions: Set<String>` for the parallel-step-ids variants (`_parallel.current.stepIds`, `_parallel.failed.stepIds`).
  - **Verify**: `rg "if \(e\.key\.startsWith\('_'\) && !e\.key\.startsWith" packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` returns 0 matches; `dart test packages/dartclaw_workflow/test/workflow/` passes with zero test-expectation changes.

- [ ] **TI02** `_fireStepCompleted(stepIndex, success, result, …)` helper (or `WorkflowRunMutator.recordStepSuccess/Failure/Continuation` — pick one shape under Agent Decision Authority) becomes the only construction path for `WorkflowStepCompletedEvent`.
  - Replace all 12 sites: 7 in `workflow_executor.dart`, 3 in `loop_step_runner.dart`, 2 in `foreach_iteration_runner.dart` (file:line refs in Code Patterns table).
  - **Verify**: `rg "WorkflowStepCompletedEvent\(" packages/dartclaw_workflow/lib/src/workflow/` returns exactly 1 match (the helper itself); workflow tests pass unchanged.

- [ ] **TI03** `truncate(String s, int maxLength, {String suffix = '…'}) → String` lives in `packages/dartclaw_core/lib/src/util/string_util.dart` (new file) with the existing `helpers.dart:48-51` implementation moved verbatim. Exported from `dartclaw_core` barrel under a `show truncate, truncateUtf8Bytes` clause.
  - `packages/dartclaw_server/lib/src/templates/helpers.dart` deletes its local copy and imports the core util (or relies on the existing `dartclaw_core` re-export already pulled into the server). Add dartdoc on `truncate` explicitly stating "char-count semantics; for UTF-8 byte truncation use `truncateUtf8Bytes`".
  - **Verify**: `rg "String truncate\(String " packages/dartclaw_core/lib/src/util/string_util.dart` matches once; `dart analyze` clean; `dart test packages/dartclaw_core packages/dartclaw_server` passes.

- [ ] **TI04** Delete the 4 char-count `_truncate` duplicates in `packages/dartclaw_server/lib/src/turn_runner.dart`, `apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart`, `apps/dartclaw_cli/lib/src/commands/workflow/workflow_runs_command.dart`, and the now-redundant `templates/helpers.dart` copy. Each call site routes to the core `truncate()`.
  - Preserve byte-for-byte output for the exact-`maxLength` boundary used by `padRight(width)` in the CLI commands (helper returns original string when `s.length <= maxLength`).
  - **Verify**: `rg "String _truncate\(String " packages apps --include='*.dart'` returns 0 matches; `dart test packages/dartclaw_server apps/dartclaw_cli` passes unchanged.

- [ ] **TI05** `truncateUtf8Bytes(String text, int maxBytes) → String` either lives next to `truncate` in `dartclaw_core/lib/src/util/string_util.dart` or remains in `dartclaw_security/content_guard.dart` (current location) — pick whichever introduces fewer cross-package imports. Dartdoc on both functions cross-references the other and explicitly states char-count vs UTF-8-byte semantics.
  - **Verify**: dartdoc inspection shows the cross-reference; `_truncateUtf8` private helper in `content_guard.dart:88` is gone (replaced by a call to the public function — same file or imported from core).

- [ ] **TI06** `unwrapCollectionValue(Object? raw, {required String stepId, required String mapOverKey}) → List<dynamic>?` lives alongside `mergeContextPreservingPrivate` in `workflow_context_helpers.dart`. Replaces `map_iteration_runner.dart:90-110` and `foreach_iteration_runner.dart:42-60` byte-for-byte (preserving the `auto-unwrapped Map key '…' to List (N items)` log message exactly, with the controller-kind prefix passed in as `stepId`'s context).
  - **Verify**: `rg "auto-unwrapped Map key" packages/dartclaw_workflow/lib/src/workflow/` shows the message originating from `workflow_context_helpers.dart` only (≤2 matches in source — the helper and any test fixture); `dart test packages/dartclaw_workflow/test/workflow/` passes unchanged.

#### Part B — YamlTypeSafeReader + parser conversions

- [ ] **TI07** `YamlTypeSafeReader` authored at `packages/dartclaw_config/lib/src/yaml_type_safe_reader.dart` with top-level functions: `String? readString(String key, Map yaml, List<String> warns, {String? defaultValue})`, `int? readInt(...)`, `bool? readBool(...)`, `Map<String, dynamic>? readMap(...)`, `List<String>? readStringList(...)`, generic `T? readField<T>(...)`. Each helper encapsulates: type-check the raw value, warn-and-ignore-and-return-default on mismatch, handle the YAML `Map<dynamic,dynamic>` → `Map<String,dynamic>` normalisation centrally. Warn message format byte-equivalent to `'Invalid type for $key: "${raw.runtimeType}" — using ${defaultPhrase}'` so existing log-asserting tests do not regress. Add `import 'yaml_type_safe_reader.dart';` to `lib/src/dartclaw_config.dart`.
  - **Verify**: new file `test/yaml_type_safe_reader_test.dart` covers each helper happy-path + each type-mismatch path + missing-key-with-default; `dart test packages/dartclaw_config` passes.

- [ ] **TI08** Convert all "Invalid type for …" warn-and-ignore sites in `packages/dartclaw_config/lib/src/config_parser.dart` (57 at e670c47 baseline, plan AC says ≥51) and the sibling part `config_parser_governance.dart` (23 sites) to use the typed reader. Convert mechanically: a site like `if (raw is String) { … } else if (raw != null) { warns.add('Invalid type for $key …'); }` becomes `final value = readString(key, yaml, warns, defaultValue: …)`.
  - Sites that genuinely cannot use the helper (e.g. multi-typed unions like "string OR list") keep the inline pattern with an explicit `// not-mechanical: <one-line reason>` comment.
  - **Verify**: `rg "Invalid type for" packages/dartclaw_config/lib/src/config_parser.dart packages/dartclaw_config/lib/src/config_parser_governance.dart | wc -l` returns ≤5 (only the genuinely non-mechanical sites, each with the comment); `dart test packages/dartclaw_config` passes with zero test-expectation changes.

- [ ] **TI09** TD-086 mechanical slice in `packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart`: replace unguarded `as String?` / `cast<String>()` / `enum.values.byName(raw as String)` chains for scalar / list / extraction-type / pattern fields with eager typed reads that throw `FormatException` naming the offending field. Use the existing `_requireString` / `_at(sourcePath)` patterns at `:53-76` as the model. The local-typed reader can be a small private helper in this file (does not depend on `YamlTypeSafeReader` — workflow parser already throws `FormatException` rather than warn-and-ignore, so the contract differs). Specific sites:
  - `extraction.type` (line 331) — chain through a `_requireEnumByName<ExtractionType>(extractionRaw, 'type', ExtractionType.values, sourcePath)` style helper. Throws `FormatException` listing valid names if absent / non-string / unknown enum value.
  - `extraction.pattern` (line 332) — `_requireString(extractionRaw, 'pattern', sourcePath)`.
  - The `as String?` sites at lines 131, 133, 147, 252, 275, 306, 339, 356-377, 623-625, 678-679, 696 — convert to typed reads if mechanical (i.e. the field semantics are "scalar string, optional with default" or "scalar string, required"). If a site needs design input ("what should empty mean here?"), leave it and add a `// TD-086: deferred to S23 — <reason>` comment.
  - **Verify**: three new fixture-based tests in `packages/dartclaw_workflow/test/workflow/workflow_definition_parser_td086_test.dart` (or sibling) exercise (a) `extraction.type: 42` → `FormatException` naming `extraction.type`; (b) `extraction.type: 'unknown_value'` → `FormatException` listing valid values; (c) `extraction` missing `pattern` for a regex-mode extraction → `FormatException` naming `extraction.pattern`. Existing parser tests pass unchanged.

- [ ] **TI10** LOC verification + CHANGELOG entry. Confirm `wc -l packages/dartclaw_config/lib/src/config_parser.dart` ≤1,344 (≥300 reduction from 1,644 baseline; ideally ≤1,200 to satisfy Binding Constraint #26). Add one bullet under `0.16.5 - Unreleased` § Changed: `Centralised "Invalid type for" YAML warn-and-ignore via new YamlTypeSafeReader; config_parser.dart reduced by N LOC; workflow parser scalar/list/extraction errors now surface as field-named FormatException (TD-086 mechanical slice).` Update `dev/state/TECH-DEBT-BACKLOG.md` TD-086 entry: prepend `**Mechanical slice closed in 0.16.5 S13** — design-heavy items (duplicate-key policy, max-depth/max-bytes, parser-vs-validator semantic-home, full gate-expression diagnostics) remain; deferred to S23 triage.`
  - **Verify**: `wc -l` confirms reduction; `git diff CHANGELOG.md` shows the bullet; `git diff dev/state/TECH-DEBT-BACKLOG.md` shows the TD-086 update.

- [ ] **TI11** Workspace-wide regression sweep. Run `dart format packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test packages/dartclaw_workflow packages/dartclaw_config packages/dartclaw_core packages/dartclaw_server apps/dartclaw_cli`. Confirm zero test-expectation diffs in existing tests (only additions in the new reader / TD-086 fixture test files).
  - **Verify**: all three commands exit 0; `git diff --stat packages/*/test apps/*/test` shows only added files (no modifications to existing test files unless the modification is a one-line addition).

### Testing Strategy
- [TI01] Scenario "Workflow context merge preserves underscore-prefixed metadata" → regression test that replays a recorded `WorkflowRun` + `WorkflowContext` through both old (inline) and new (helper) code paths in a fixture-based comparison; assert byte-for-byte map equality.
- [TI03,TI05] Scenario "Char-count truncate vs UTF-8 byte truncate" → unit tests in `packages/dartclaw_core/test/util/string_util_test.dart` covering ASCII, multi-byte UTF-8, and exact-boundary cases for both helpers.
- [TI06] Scenario "Map / foreach auto-unwrap dedupe" → existing scenario tests in `map_step_execution_test.dart` and `foreach_step_execution_test.dart` (or sibling) assert continued green; no new tests required (parity-only change).
- [TI09] Scenario "TD-086 mechanical slice — malformed `extraction.type`" → three fixture tests in `workflow_definition_parser_td086_test.dart` (or appended to existing parser test) covering non-string type, unknown enum value, missing pattern.
- [TI07,TI08] Scenario "YamlTypeSafeReader warn-and-ignore preserves observable behaviour" → unit tests in `packages/dartclaw_config/test/yaml_type_safe_reader_test.dart` for each helper; existing `config_parser_test.dart` (and siblings) remain green without modification.

### Validation
> Standard validation (build/test checks, code review, 1-pass remediation) handled by exec-spec.

- LOC confirmation gate: `wc -l packages/dartclaw_config/lib/src/config_parser.dart` must show ≥300 LOC reduction before claiming TI10 done.

### Execution Contract
- Implement tasks in listed order — Part A before Part B, and within each part the helpers extract / land in dependency order so each task completes a working slice on its own.
- Treat any existing-test-expectation diff as a conversion bug, not a needed test update (Constraint #71).
- Each helper extraction runs the relevant package's tests immediately after; do not batch the test runs.
- After all tasks: workspace-wide `dart format` + `dart analyze --fatal-warnings --fatal-infos` + `dart test` (per TI11). Confirm `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean except for any `// TD-086: deferred to S23 — <reason>` comments deliberately added in TI09.
- Mark task checkboxes immediately upon completion.

## Final Validation Checklist

- [ ] **All success criteria** met (Part A 6 items + Part B 5 items + Health Metrics 6 items)
- [ ] **All 11 tasks** fully completed and checkboxes checked
- [ ] **No regressions** — `dart test` workspace-wide passes; zero existing test-expectation changes
- [ ] **CHANGELOG + TD-086 backlog entry** updated per TI10
- [ ] **Plan + STATE update** — set `**FIS**: fis/s13-pre-decomposition-helpers.md` and `**Status**: Spec Ready` (then `Done` post-implementation) in `dev/specs/0.16.5/plan.md` for this story; update `dev/state/STATE.md` if the story closure shifts the milestone progress line

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
