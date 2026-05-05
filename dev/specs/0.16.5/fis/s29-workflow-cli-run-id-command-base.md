# Feature Implementation Specification — S29: Workflow CLI Run-ID Command Base Class + AndThen bootstrap (TD-072 item 1)

**Plan**: ../plan.md
**Story-ID**: S29

## Feature Overview and Goal

Extract a `WorkflowRunIdCommand` abstract base for run-id-anchored workflow CLI subcommands (`pause`/`resume`/`retry`) and lift the duplicated `_serverOverride()` / `_globalOptionString()` helpers into a single `cli_global_options.dart` library shared by all eight workflow subcommand files. While `workflow_show_command.dart` is in the touch set, route `WorkflowShowCommand._runStandalone(...)` through `bootstrapAndthenSkills(...)` (closing TD-072 item 1) so a freshly-installed instance produces correct `--resolved --standalone` output on first contact.

> **Technical Research**: [.technical-research.md](../.technical-research.md) — Story-Scoped File Map § "S29", Shared Decisions #19 (CLI command base class) + #28 (`bootstrapAndthenSkills` reuse seam).


## Required Context

### From `dev/specs/0.16.5/plan.md` — "S29: Workflow CLI Run-ID Command Base Class"
<!-- source: dev/specs/0.16.5/plan.md#s29-workflow-cli-run-id-command-base-class -->
<!-- extracted: e670c47 -->
> **Scope**: Extract a `WorkflowRunIdCommand` abstract base in `apps/dartclaw_cli/lib/src/commands/workflow/`. Base owns `_config`, `_apiClient`, `_writeLine`, `_exitFn` fields, `_requireRunId()` (currently duplicated in 7 files), `_resolveApiClient()` (same), and a `runAgainstRun(String path, {String verb})` template method that performs the common POST + JSON-or-text output pattern. Collapse `workflow_pause_command.dart` (84 LOC), `workflow_resume_command.dart` (84 LOC), and `workflow_retry_command.dart` (85 LOC) to ~20 LOC each. Move file-private `_serverOverride()` and `_globalOptionString()` helpers (currently duplicated across 8 files) to a shared `cli_global_options.dart` library within `apps/dartclaw_cli/lib/src/commands/` and re-import from `workflow_cancel_command.dart`, `workflow_status_command.dart`, `workflow_show_command.dart`, `workflow_runs_command.dart` too (even where not fully collapsible, the shared helpers remove the file-local copies). Zero behaviour change.
>
> **Added 2026-04-30 — TD-072 item 1**: While `workflow_show_command.dart` is being touched, route `WorkflowShowCommand._runStandalone(...)` through the same `bootstrapAndthenSkills(...)` helper used by `cli_workflow_wiring.dart:190–219` and `service_wiring.dart:196–230`. Currently `--resolved --standalone` builds a transient `SkillRegistryImpl` without provisioning AndThen on first contact, so on a freshly-installed instance where neither `dartclaw serve` nor `dartclaw workflow run` has run, `--resolved` output omits SKILL.md frontmatter defaults until any other workflow command provisions AndThen. Gate the bootstrap call on a `runAndthenSkillsBootstrap` flag for tests that opt out (mirror the `CliWorkflowWiring` pattern). Add a regression test asserting bootstrap fires on first `show --resolved --standalone` invocation.

### From `dev/specs/0.16.5/prd.md` — "Constraints"
<!-- source: dev/specs/0.16.5/prd.md#constraints -->
<!-- extracted: e670c47 -->
> - **No new user-facing features.** Any feature-shaped work defers to 0.16.6+.
> - **No breaking protocol changes.** JSONL control protocol, REST payloads, SSE envelope format all stable.
> - **No new dependencies** in any package.
> - **Workspace-wide strict-casts + strict-raw-types** must remain on throughout.

### From `dev/state/TECH-DEBT-BACKLOG.md` — "TD-072 item 1 Fix"
<!-- source: dev/state/TECH-DEBT-BACKLOG.md#td-072 -->
<!-- extracted: e670c47 -->
> Route `WorkflowShowCommand._runStandalone(...)` through the same `bootstrapAndthenSkills(...)` helper used by run/serve, gated on a `runAndthenSkillsBootstrap` flag for tests that opt out (mirror the `CliWorkflowWiring` pattern). Add a regression test asserting bootstrap fires on first `show --resolved --standalone` invocation.


## Deeper Context

- `dev/specs/0.16.5/.technical-research.md#s29-workflow-cli-run-id-command-base-class--andthen-bootstrap-td-072-item-1` — File map for the touched files
- `dev/specs/0.16.5/.technical-research.md#shared-architectural-decisions` — Decision #19 (base class shape) + Decision #28 (bootstrap reuse seam)
- `apps/dartclaw_cli/CLAUDE.md` — package-scoped conventions: `connected_command_support.dart` helpers, `--config`/`--server`/`--token` global overrides, AOT constraints (no `dart:mirrors`)


## Success Criteria (Must Be TRUE)

> Each criterion has a proof path: a Scenario (behavioral) or task Verify line (structural).

- [ ] **`WorkflowRunIdCommand` base class exists**; `WorkflowPauseCommand`/`WorkflowResumeCommand`/`WorkflowRetryCommand` extend it (proof: TI01, TI02 Verify lines)
- [ ] **`_requireRunId` and `_resolveApiClient` are defined once and shared** through the base class (proof: TI01 Verify; `rg "String _requireRunId|DartclawApiClient _resolveApiClient" apps/dartclaw_cli/lib/src/commands/workflow/` returns only the base class)
- [ ] **`_serverOverride` and `_globalOptionString` live in a single `apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` library** (proof: TI03 Verify; `rg "^String\\?\\s+_(server|globalOption)" apps/dartclaw_cli/lib/src/commands/workflow/` empty)
- [ ] **Net LOC reduction ≥150** across `apps/dartclaw_cli/lib/src/commands/workflow/workflow_{pause,resume,retry,cancel,status,show,runs}_command.dart` plus the new base + shared helpers, measured `before − after` (proof: TI07 Verify)
- [ ] **`dart test apps/dartclaw_cli` passes with zero pre-existing test edits** (proof: Scenario "Identical behavior across pause/resume/retry"; TI08 Verify)
- [ ] **`workflow {pause,resume,retry,cancel,status,show,runs}` produce identical output** (stdout text, stderr text, exit code, JSON shape) before/after the refactor (proof: Scenarios "Identical behavior" + "Missing run-id error message")
- [ ] **TD-072 item 1**: `WorkflowShowCommand._runStandalone(...)` calls `bootstrapAndthenSkills(...)` with a test-gateable `runAndthenSkillsBootstrap` constructor flag (default `true`, mirror `CliWorkflowWiring`) (proof: TI05 Verify)
- [ ] **TD-072 item 1**: Regression test asserts AndThen bootstrap fires on first `show --resolved --standalone` invocation against a fresh-install fixture (no pre-staged `<dataDir>/andthen-src/`); test uses an injectable `ProcessRunner` fake to observe the provisioning call (proof: Scenario "Fresh-install AndThen bootstrap on standalone resolved show"; TI06 Verify)
- [ ] **TD-072 entry updated** in `dev/state/TECH-DEBT-BACKLOG.md` to remove item 1 (or the whole TD-072 section deleted if S03 closes item 2 in the same sprint) (proof: TI09 Verify)

### Health Metrics (Must NOT Regress)

- [ ] All existing `apps/dartclaw_cli/test/commands/workflow/` tests pass unmodified (zero diff in pre-existing test files except imports if a renamed import is unavoidable; trivial import-fix only, no assertion changes)
- [ ] `dart analyze --fatal-warnings --fatal-infos apps/dartclaw_cli` clean
- [ ] `dart format --set-exit-if-changed apps/dartclaw_cli` clean
- [ ] CLI invocation surface unchanged: command names, help text, flag set, exit codes, stdout/stderr formatting all byte-identical (validated by existing tests + new spot-checks per scenario)


## Scenarios

### Identical behavior across pause/resume/retry (happy path)

- **Given** the server is running and a workflow run with id `run-42` exists in state `running` (for pause), `paused` (for resume), or `failed` (for retry)
- **When** the operator runs `dartclaw workflow pause run-42`, then on a separately staged run `dartclaw workflow resume run-42`, then on a separately staged run `dartclaw workflow retry run-42`
- **Then** each command POSTs to `/api/workflows/runs/run-42/{pause|resume|retry}`, prints `Workflow run-42 {paused|resumed|retried} (<status>).` to stdout, and exits with code 0 — byte-identical to the pre-refactor output captured by the existing `apps/dartclaw_cli/test/commands/workflow/` suite

### Identical behavior with `--json` (happy path / output-shape stability)

- **Given** a workflow run as above
- **When** the operator runs `dartclaw workflow pause run-42 --json`
- **Then** stdout is the indented JSON object returned by the API (`JsonEncoder.withIndent('  ').convert(result)`), with the same key set as before the refactor — pause/resume/retry tests in the existing suite assert this shape and continue passing without edits

### Missing run-id error message (edge case — negative path)

- **Given** any of `pause`, `resume`, `retry`, `cancel`, `status`, `show` (without `--standalone`) — i.e. commands that require a positional run-id / workflow name
- **When** the operator invokes the command without a positional argument
- **Then** the command throws `UsageException('Run ID required', usage)` (or the existing analogue for `show`: `'Workflow name required'`) producing the same stderr text and exit code (`64 EX_USAGE`) as before the refactor

### Non-2xx server response (error path)

- **Given** the server returns a non-2xx response (e.g. 404 with `{"error":"workflow run not found"}`) for `/api/workflows/runs/missing/pause`
- **When** the operator runs `dartclaw workflow pause missing`
- **Then** the command catches `DartclawApiException`, writes `error.message` to the configured `WriteLine` sink (stdout under the existing pattern, preserved verbatim), and calls `_exitFn(1)` — byte-identical to pre-refactor formatting, validated by the existing pause/resume/retry test cases

### Fresh-install AndThen bootstrap on standalone resolved show (TD-072 item 1)

- **Given** a freshly-installed instance: a temp `dataDir` with no `andthen-src/` checkout, no prior `dartclaw serve` or `dartclaw workflow run` invocation, and a workflow YAML in `<dataDir>/workflows/definitions/` that references a `dartclaw-*` skill whose `SKILL.md` ships defaults under `workflow.default_prompt`
- **When** the operator runs `dartclaw workflow show <name> --resolved --standalone` for the first time, with `runAndthenSkillsBootstrap: true` (production default) and an injected `ProcessRunner` fake stubbed for the provisioner clone/copy steps
- **Then** the command calls `bootstrapAndthenSkills(...)` exactly once before constructing the transient `SkillRegistryImpl`, and the resolved YAML output contains the SKILL.md `default_prompt` value (verified via the same fixture pattern as existing `workflow_show_command_test.dart` "standalone resolved mode" tests)

### Test opt-out preserves existing fixture-based tests (no regression)

- **Given** an existing test that constructs `WorkflowShowCommand(config: ..., write: ..., writeLine: ..., exitFn: ...)` against a pre-staged native skill fixture and does **not** want a provisioner clone/copy
- **When** that test passes `runAndthenSkillsBootstrap: false` to the constructor
- **Then** `_runStandalone(...)` skips `bootstrapAndthenSkills(...)` and behaves identically to the current code path — all existing `workflow_show_command_test.dart` tests pass without modification (only the new regression test exercises the `true` branch)


## Scope & Boundaries

### In Scope

_Every scope item maps to at least one task with a Verify line._

- New file `apps/dartclaw_cli/lib/src/commands/workflow/workflow_run_id_command.dart` — abstract `WorkflowRunIdCommand extends Command<void>` with shared fields, `_requireRunId()`, `_resolveApiClient()`, and `runAgainstRun(String path, {required String verb})` template method (TI01)
- Collapse `workflow_pause_command.dart`, `workflow_resume_command.dart`, `workflow_retry_command.dart` to ~20 LOC each by extending the new base (TI02)
- New file `apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` — public top-level `serverOverride(ArgResults?)` + `globalOptionString(ArgResults?, String)` helpers (no leading underscore — they're library-public). Note: identifier rename from the duplicated `_serverOverride`/`_globalOptionString` is intentional because Dart privacy is library-scoped — see Architecture Decision (TI03)
- Re-import `cli_global_options.dart` from `workflow_cancel_command.dart`, `workflow_status_command.dart`, `workflow_show_command.dart`, `workflow_runs_command.dart` and delete the file-local copies; keep call sites byte-identical except for the bare-symbol renames (TI04)
- TD-072 item 1: Add `runAndthenSkillsBootstrap` field + `skillProvisionerProcessRunner` field to `WorkflowShowCommand`; gate the new `bootstrapAndthenSkills(...)` call inside `_runStandalone(...)` on the resolved branch only (no bootstrap on raw-mode standalone, since SKILL.md defaults aren't merged there) (TI05)
- New regression test in `apps/dartclaw_cli/test/commands/workflow/workflow_show_command_test.dart` covering fresh-install bootstrap (TI06)
- LOC delta verification (TI07)
- Full `dart test apps/dartclaw_cli` + `dart analyze` + `dart format` clean run (TI08)
- TD-072 entry updated in `dev/state/TECH-DEBT-BACKLOG.md` (TI09)

### What We're NOT Doing

- **Not changing CLI output format or text** — no rewording of `Workflow ... paused (...)`, no JSON key changes, no exit-code changes; binding constraint #1 (REST/SSE wire format unchanged) and the zero-behaviour-change goal forbid it
- **Not renaming public commands or adding new commands** — binding constraint #4 (no new CLI commands)
- **Not refactoring `cli_workflow_wiring.dart`** — S17 owns CLI-side wiring decomposition; touching it here would create merge conflicts with S17 and is out of scope
- **Not modifying TD-072 item 2 (glossary cluster)** — S03 (Doc Currency Critical Pass) closes item 2; S29 only closes item 1. If S03 lands first and the whole TD-072 section is gone, S29 is a no-op for the backlog edit (verify only)
- **Not bootstrapping AndThen for raw-mode standalone show** — only the `--resolved` branch consumes SKILL.md defaults; raw-mode just emits authored YAML and never reads skills, so adding bootstrap there would slow first-contact CLI and contradict the targeted scope of TD-072 item 1
- **Not extracting a base class for `cancel`/`status`/`show`/`runs`/`run`/`list`/`validate`** — those commands diverge meaningfully (different verbs, response handling, multiple paths in `run`/`status`); the run-id POST + JSON-or-text pattern is specific to pause/resume/retry. Forcing a wider base would inflate the diff without removing real duplication

### Agent Decision Authority

- **Autonomous**: Exact private-vs-public visibility of base-class members within the workflow folder; whether `_resolveApiClient()` stays `protected`-style (Dart has no protected — use library-private by placing base in the `workflow/` directory and relying on the library boundary, or expose as `@protected` from `package:meta`); choice of identifier names for the lifted helpers (`serverOverride`/`globalOptionString` recommended; `kServerOverride`-style forbidden by S36 conventions but that's not even tempting here)
- **Escalate**: Any change that alters CLI stdout/stderr text or exit codes; any change that touches a test other than the new regression case (existing tests must keep their assertions intact); any change to `cli_workflow_wiring.dart` or `service_wiring.dart` beyond the TD-072 item 1 scope


## Architecture Decision

**We will**: Introduce `WorkflowRunIdCommand` as an abstract base owning the four duplicated fields (`_config`, `_apiClient`, `_writeLine`, `_exitFn`), the duplicated `_requireRunId()` and `_resolveApiClient()` methods, and a `runAgainstRun(String path, {required String verb})` template method that performs the POST → JSON-or-text → exit pattern shared by pause/resume/retry. Lift the file-private `_serverOverride()` and `_globalOptionString()` helpers into a shared library `apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` exposing them as top-level functions (`serverOverride`, `globalOptionString`) — Dart's library-scoped privacy means the original underscore names cannot stay underscore-prefixed once they're public to other libraries, and the rename is mechanical at the call sites. For TD-072 item 1, add a `runAndthenSkillsBootstrap` boolean field (default `true`) plus an optional `ProcessRunner? skillProvisionerProcessRunner` field to `WorkflowShowCommand`, mirroring the `CliWorkflowWiring` test-opt-out pattern at `cli_workflow_wiring.dart:120-160` and the production caller at `:190-198`. Inside `_runStandalone(...)`, on the `--resolved` branch only, call `bootstrapAndthenSkills(...)` exactly once before building the transient `SkillRegistryImpl`.

**Rationale**: Mechanical refactor with zero behaviour change. Reuses an already-proven seam (`bootstrapAndthenSkills` + `runAndthenSkillsBootstrap` flag) rather than inventing a new test affordance. Library-scoped helpers are the standard Dart way to share file-private utilities without exporting from the package barrel. Keeping the `--resolved` branch as the only bootstrap site honours the targeted scope of TD-072 item 1 and avoids slowing raw-mode standalone show.

**Alternatives considered**:
1. **Mixin instead of abstract base** — rejected: pause/resume/retry have nothing useful to mix into anything else, and abstract base + `extends` is more readable here than `with WorkflowRunIdMixin`.
2. **Keep `_serverOverride`/`_globalOptionString` underscore-prefixed via a `part of` directive** — rejected: `part of` adds compile-graph fragility and AOT cost surface, and the constraints in `apps/dartclaw_cli/CLAUDE.md` ("avoid `dart:mirrors`, runtime `import` strings, and reflective package APIs") implicitly favour vanilla library imports.
3. **Bootstrap unconditionally in `WorkflowShowCommand.run()` (not just `_runStandalone(--resolved)`)** — rejected: only the resolved-standalone path needs SKILL.md defaults; bootstrapping on every connected `show` would slow CLI startup for no operator benefit and would diverge from the narrow TD-072 item 1 fix.


## Technical Overview

### Data Models (if applicable)

No new data models. The new `WorkflowRunIdCommand` base class holds four existing dependency fields. The new `runAndthenSkillsBootstrap`/`skillProvisionerProcessRunner` fields on `WorkflowShowCommand` mirror exact field shapes already proven in `CliWorkflowWiring` and `ServiceWiring`.

### Integration Points (if applicable)

- **`apps/dartclaw_cli/lib/src/commands/workflow/workflow_command.dart`** — registers the existing `WorkflowPauseCommand`/`WorkflowResumeCommand`/`WorkflowRetryCommand`/`WorkflowShowCommand` subclasses; constructor signatures stay backward-compatible (all new fields default-valued or optional named) so this file is **untouched**.
- **`bin/dartclaw.dart`** — registration only; untouched.
- **`apps/dartclaw_cli/test/commands/workflow/workflow_show_command_test.dart`** — extended with the new TD-072 regression test; existing tests pass `runAndthenSkillsBootstrap: false` if needed (most already work because they pre-stage the skill fixture in the temp `dataDir`'s native-tier roots — confirm during TI06 whether the default-true bootstrap interferes; if it does, add `runAndthenSkillsBootstrap: false` to existing fixture tests as the only allowed pre-existing-test edit).


## Code Patterns & External References

```
# type | path/url                                                                                          | why needed
file   | apps/dartclaw_cli/lib/src/commands/workflow/workflow_pause_command.dart:12-71                    | Source — current 84-LOC shape of pause (resume/retry are byte-equivalent, only verb + past-tense word differ)
file   | apps/dartclaw_cli/lib/src/commands/workflow/workflow_resume_command.dart:12-71                   | Source — current 84-LOC resume shape; identical structure to pause
file   | apps/dartclaw_cli/lib/src/commands/workflow/workflow_retry_command.dart:12-71                    | Source — current 85-LOC retry shape; identical structure to pause
file   | apps/dartclaw_cli/lib/src/commands/workflow/workflow_pause_command.dart:73-84                    | Source — duplicated `_serverOverride`/`_globalOptionString` block (identical block in all 7 files)
file   | apps/dartclaw_cli/lib/src/commands/workflow/workflow_show_command.dart:121-179                   | Target — `_runStandalone(...)` body for TD-072 item 1 bootstrap insertion
file   | apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:120-198                     | Pattern — `runAndthenSkillsBootstrap` flag + optional `ProcessRunner` + gated `bootstrapAndthenSkills(...)` call (mirror this exactly)
file   | apps/dartclaw_cli/lib/src/commands/service_wiring.dart:133-200                                   | Pattern — same flag + provisioner-environment + provisioner-runner trio in `ServiceWiring` (cross-check naming)
file   | apps/dartclaw_cli/lib/src/commands/workflow/andthen_skill_bootstrap.dart:37-76                   | Reference — `bootstrapAndthenSkills(...)` signature; required `builtInSkillsSourceDir`, optional `environment` and `processRunner`
file   | apps/dartclaw_cli/test/commands/workflow/cli_workflow_wiring_test.dart:76,125,166,...            | Pattern — how existing tests opt out via `runAndthenSkillsBootstrap: false`
file   | apps/dartclaw_cli/test/commands/workflow/workflow_show_command_test.dart:1-180                   | Pattern — `setUp`/`tearDown`, fixture creation under `tempDir/.dartclaw-data/workflows/definitions/`, native skill fixture under fake-HOME `~/.agents/skills/`, `_FakeExit` for `exitFn`
file   | apps/dartclaw_cli/lib/src/commands/connected_command_support.dart                                | Reference — package-scoped convention: server-talking commands use `resolveCliApiClient`; preserve this pattern
file   | apps/dartclaw_cli/CLAUDE.md                                                                       | Reference — package-scoped rules: dependency injection, AOT constraints, command registration alphabetical-with-grouping
```


## Constraints & Gotchas

- **Constraint**: Dart privacy is library-scoped, not file-scoped. Lifting `_serverOverride`/`_globalOptionString` out of each file into a shared library means they can no longer keep the underscore prefix without becoming inaccessible to importers. Workaround: rename to `serverOverride`/`globalOptionString` (still lower-camelCase, no `k`-prefix per S36 conventions); update all call sites verbatim.
- **Constraint**: `connected_command_support.dart` already exists in the same directory and provides `resolveCliApiClient(globalResults: ...)` per `CLAUDE.md`. Workaround: do **not** consolidate into that file — its responsibility is server-talking-command setup; the new `cli_global_options.dart` is narrower (global flag access only). Keep them separate to preserve single-responsibility per file.
- **Critical**: Existing tests must remain unmodified. If any existing `workflow_show_command_test.dart` test breaks because the default `runAndthenSkillsBootstrap: true` causes a provisioner clone attempt, the **only** acceptable edit is adding `runAndthenSkillsBootstrap: false` to that test's constructor call. Document any such edit in the task line. Do **not** change assertions, fixtures, or test names.
- **Avoid**: Eagerly inheriting `runAgainstRun(...)` for `cancel`/`status`/`show`/`runs` — those don't share the POST → JSON-or-text shape (cancel POSTs with body then GETs; status/show have multiple modes; runs is GET-only). Forcing them into the base widens the diff and breaks the "low-risk mechanical" framing. **Instead**: only pause/resume/retry extend the base; cancel/status/show/runs share only the lifted `cli_global_options.dart` helpers.
- **Avoid**: Bootstrapping AndThen on the connected (server-mode) `show` path. **Instead**: bootstrap only when `_runStandalone(...)` is called with `resolved: true`; the connected path goes via the server which already provisions through `service_wiring.dart`.
- **Critical (binding constraint #2)**: No new package dependencies. The refactor uses existing imports only (`args`, `dartclaw_config`, in-package files).


## Implementation Plan

> **Vertical slice ordering**: TI01 establishes the base; TI02 collapses pause/resume/retry; TI03–TI04 lift the helpers; TI05–TI06 close TD-072 item 1; TI07–TI08 verify the size/health metrics; TI09 cleans up the backlog.

### Implementation Tasks

- [ ] **TI01** `WorkflowRunIdCommand` abstract base exists at `apps/dartclaw_cli/lib/src/commands/workflow/workflow_run_id_command.dart` with constructor `({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})`, fields `_config`/`_apiClient`/`_writeLine`/`_exitFn`, abstract command-name/description/invocation getters left for subclasses, concrete `_requireRunId()` (throws `UsageException('Run ID required', usage)` when `argResults!.rest` empty), concrete `_resolveApiClient()` (delegates to `loadCliConfig` + `DartclawApiClient.fromConfig` using lifted `cli_global_options.dart` helpers), and concrete `Future<void> runAgainstRun(String path, {required String verb}) async` that POSTs to `path`, formats stdout as `Workflow <id> $verb (<status>).` for plain mode and `JsonEncoder.withIndent('  ').convert(result)` for `--json`, and catches `DartclawApiException` writing `error.message` + `_exitFn(1)`.
  - Mirror the field/constructor shape of `workflow_pause_command.dart:12-24` exactly.
  - **Verify**: `dart analyze apps/dartclaw_cli` clean; `rg -n "abstract class WorkflowRunIdCommand" apps/dartclaw_cli/lib/src/commands/workflow/workflow_run_id_command.dart` returns 1.

- [ ] **TI02** `WorkflowPauseCommand`, `WorkflowResumeCommand`, `WorkflowRetryCommand` each `extends WorkflowRunIdCommand`, ≤25 LOC each (constructor + name/description/invocation getters + `run()` calling `runAgainstRun('/api/workflows/runs/${_requireRunId()}/<verb>', verb: '<past-tense>')`).
  - Subclass constructors forward to `super(...)` named params; argParser still adds `--json` flag.
  - **Verify**: `wc -l apps/dartclaw_cli/lib/src/commands/workflow/workflow_{pause,resume,retry}_command.dart` each ≤25; `dart test apps/dartclaw_cli/test/commands/workflow/` for the existing pause/resume/retry tests passes unchanged.

- [ ] **TI03** `apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` exists with public top-level functions `String? serverOverride(ArgResults? results)` and `String? globalOptionString(ArgResults? results, String name)` — bodies byte-identical to the duplicated copies (`return globalOptionString(results, 'server')` for `serverOverride`; try/catch `ArgumentError` returning `null` for unparsed for `globalOptionString`). No imports beyond `package:args/args.dart`.
  - **Verify**: `rg -n "^String\\?\\s+serverOverride|^String\\?\\s+globalOptionString" apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` returns 2; `dart analyze apps/dartclaw_cli` clean.

- [ ] **TI04** All workflow command files (`workflow_pause`, `workflow_resume`, `workflow_retry`, `workflow_cancel`, `workflow_status`, `workflow_show`, `workflow_runs`) import `cli_global_options.dart` and call `serverOverride(...)`/`globalOptionString(...)` instead of the file-local underscore variants; the file-local definitions are deleted. `workflow_run_command.dart` (mentioned in research grep at `:687-691`) is **also** updated for consistency since it carries the same duplicated block.
  - **Verify**: `rg -n "String\\?\\s+_serverOverride|String\\?\\s+_globalOptionString" apps/dartclaw_cli/lib/src/commands/workflow/` returns 0; `rg -n "import '../cli_global_options.dart'" apps/dartclaw_cli/lib/src/commands/workflow/` returns ≥7.

- [ ] **TI05** `WorkflowShowCommand` constructor accepts `bool runAndthenSkillsBootstrap = true` and `ProcessRunner? skillProvisionerProcessRunner` (import from `package:dartclaw_workflow/dartclaw_workflow.dart`); `_runStandalone(...)` calls `await bootstrapAndthenSkills(config: ..., dataDir: config.server.dataDir, builtInSkillsSourceDir: builtInSkillsDir, environment: _environment, processRunner: _skillProvisionerProcessRunner)` exactly once on the `--resolved` branch (before `SkillRegistryImpl` construction) when both `resolved == true` **and** `_runAndthenSkillsBootstrap == true`. Use the same `_assetResolver.resolve()` / `WorkflowSkillSourceResolver.resolveBuiltInSkillsSourceDir()` chain already present in `_runStandalone` to compute `builtInSkillsDir`, then pass that through to `bootstrapAndthenSkills(...)` (no second resolution).
  - Pattern reference: `cli_workflow_wiring.dart:120-160` for field shape; `cli_workflow_wiring.dart:188-198` for the gated call; `andthen_skill_bootstrap.dart:37-76` for the bootstrap signature.
  - **Verify**: `rg -n "bootstrapAndthenSkills" apps/dartclaw_cli/lib/src/commands/workflow/workflow_show_command.dart` returns ≥1; `dart analyze apps/dartclaw_cli` clean.

- [ ] **TI06** New regression test in `apps/dartclaw_cli/test/commands/workflow/workflow_show_command_test.dart` named like "standalone resolved mode bootstraps AndThen on first invocation": creates a fresh `tempDir` with **no** `andthen-src/` pre-staged, writes a workflow YAML referencing a `dartclaw-*` skill, injects a `ProcessRunner` fake (recording calls), constructs `WorkflowShowCommand(..., runAndthenSkillsBootstrap: true, skillProvisionerProcessRunner: fakeRunner, environment: <fake HOME pointing inside tempDir>)`, runs `['show', '<name>', '--resolved', '--standalone']`, then asserts the fake recorded at least one provisioner-shaped invocation (e.g. clone or copy of `dartclaw-*` skills) **before** YAML emission.
  - For the existing fixture-based tests at `workflow_show_command_test.dart` that pre-stage `dartclaw-default-demo` directly under `~/.agents/skills/` (lines 93-180): if those tests fail with the default `runAndthenSkillsBootstrap: true`, add `runAndthenSkillsBootstrap: false` to those constructor calls (the only allowed edit to existing tests). If they don't fail (fake HOME isolates the bootstrap from real `~/.agents`), leave them untouched.
  - **Verify**: `dart test apps/dartclaw_cli/test/commands/workflow/workflow_show_command_test.dart` passes including the new test; the new test fails (red) when TI05's bootstrap call is removed, proving it gates the production behaviour.

- [ ] **TI07** Net LOC reduction ≥150 across the touched workflow CLI command files. Compute as: sum of `wc -l` for `workflow_{pause,resume,retry,cancel,status,show,runs,run}_command.dart` **before** the refactor minus the same sum **after** plus the size of the new `workflow_run_id_command.dart` and `cli_global_options.dart` (so net = before − after − new_files).
  - Baseline (current state, captured in this FIS for accountability): pause 84, resume 84, retry 85, cancel 93, status 277, show 208, runs 116, run (helpers tail only) ~5; totals dominated by pause+resume+retry triple at 253 LOC for the structural collapse target, plus ~12 LOC × 8 files = ~96 LOC from helper duplication, ≥349 LOC of duplication available to remove.
  - **Verify**: A short calc recorded in the implementation observations or commit message: `before=<N>; after=<M>; new_files=<K>; delta=before-after-new_files; assert delta >= 150`.

- [ ] **TI08** Full validation: `dart format apps/dartclaw_cli` produces no changes; `dart analyze --fatal-warnings --fatal-infos apps/dartclaw_cli` clean; `dart test apps/dartclaw_cli` all-green with at most the trivial `runAndthenSkillsBootstrap: false` edits to existing show-command fixture tests (per TI06).
  - **Verify**: All three commands exit 0; PR diff shows no edits to existing test assertions or fixture bodies.

- [ ] **TI09** `dev/state/TECH-DEBT-BACKLOG.md` TD-072 entry: if TD-072 item 2 is still open at S29 merge time, edit the entry to remove only item 1 (delete the item-1 paragraphs in **Context** and **Fix** sections, and adjust the heading from "(workflow show standalone bootstrap + glossary residual drift)" to "(glossary residual drift)"). If item 2 is already closed by S03 (entry empty or marked Resolved), delete the entire TD-072 section and remove TD-072 references from the open-items index at the top of the file (if present).
  - **Verify**: `rg -n "TD-072" dev/state/TECH-DEBT-BACKLOG.md` returns either 0 lines (full delete case) or only item-2-scoped lines (partial edit case).

### Testing Strategy

- [TI01,TI02] Scenario "Identical behavior across pause/resume/retry" → existing pause/resume/retry tests in `apps/dartclaw_cli/test/commands/workflow/` (no new tests; existing assertions are the proof)
- [TI02] Scenario "Identical behavior with `--json`" → existing `--json` assertions in pause/resume/retry tests
- [TI02,TI04] Scenario "Missing run-id error message" → existing `UsageException` tests in pause/resume/retry/cancel/status; if absent for any of these commands, add a one-liner asserting `UsageException` is thrown when `rest` is empty (do not assert the exact message text — pull it from the code)
- [TI02] Scenario "Non-2xx server response" → existing API-error tests; new test only if no existing coverage for one of pause/resume/retry (unlikely given existing fakes)
- [TI05,TI06] Scenario "Fresh-install AndThen bootstrap on standalone resolved show" → new regression test in `workflow_show_command_test.dart`
- [TI06] Scenario "Test opt-out preserves existing fixture-based tests" → covered by the trivial-edit allowance in TI06 (any pre-existing test that needs the opt-out gets `runAndthenSkillsBootstrap: false`; otherwise unchanged)

### Validation

Standard validation (build/test, analyze, format, code review) is sufficient. No feature-specific validation needed — this is a mechanical refactor.

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (file paths, identifier names, error messages) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs (none expected for this story).
- After all tasks: `dart format apps/dartclaw_cli`, `dart analyze --fatal-warnings --fatal-infos apps/dartclaw_cli`, `dart test apps/dartclaw_cli` all green; `rg "TODO|FIXME|placeholder|not.implemented" apps/dartclaw_cli/lib/src/commands/workflow/ apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` empty.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met (each one mapped to a Scenario or Verify line)
- [ ] **All tasks** TI01–TI09 fully completed, verified, and checkboxes checked
- [ ] **No regressions**: zero edits to existing test assertions or fixture bodies; only the TI06 `runAndthenSkillsBootstrap: false` additions allowed if needed
- [ ] **CLI behaviour byte-identical**: `dartclaw workflow {pause,resume,retry,cancel,status,show,runs}` produce the same stdout, stderr, exit codes, and JSON shapes as before
- [ ] **TD-072 item 1 closed**: bootstrap call lives in `WorkflowShowCommand._runStandalone`; regression test passes; `dev/state/TECH-DEBT-BACKLOG.md` updated
- [ ] **Net LOC reduction ≥150** measured and recorded


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
