# Feature Implementation Specification — S29: Workflow CLI Run-ID Command Base Class

**Plan**: ../plan.md
**Story-ID**: S29

## Feature Overview and Goal

Extract a `WorkflowRunIdCommand` abstract base for run-id-anchored workflow CLI subcommands (`pause`/`resume`/`retry`) and lift the duplicated `_serverOverride()` / `_globalOptionString()` helpers into a single `cli_global_options.dart` library shared by the workflow subcommand files. This is a mechanical cleanup with zero intended behavior change.

> **Scope reconciliation — 2026-05-06**: S29 no longer owns first-contact AndThen provisioning for `dartclaw workflow show --resolved --standalone`. Data-dir skill provisioning made the intended behavior explicit: standalone resolved show reads already-provisioned data-dir skill roots, and fresh installs should run `dartclaw serve` or `dartclaw workflow run --standalone` before relying on resolved skill defaults. See `docs/guide/workflows.md`.


## Required Context

### From `dev/specs/0.16.5/plan.md` — "S29: Workflow CLI Run-ID Command Base Class"

> **Scope**: Extract a `WorkflowRunIdCommand` abstract base for the workflow CLI commands (collapsing `pause`/`resume`/`retry` from ~85 LOC each to ~20 LOC), and move duplicated `_serverOverride()` and `_globalOptionString()` helpers into a shared `cli_global_options.dart`. Zero behaviour change.

### From `dev/specs/0.16.5/prd.md` — "Constraints"

> - **No new user-facing features.** Any feature-shaped work defers to 0.16.6+.
> - **No breaking protocol changes.** JSONL control protocol, REST payloads, SSE envelope format all stable.
> - **No new dependencies** in any package.
> - **Workspace-wide strict-casts + strict-raw-types** must remain on throughout.


## Success Criteria (Must Be TRUE)

- [ ] `WorkflowRunIdCommand` base class exists; `WorkflowPauseCommand`, `WorkflowResumeCommand`, and `WorkflowRetryCommand` extend it.
- [ ] `_requireRunId` and `_resolveApiClient` are defined once and shared through the base class.
- [ ] `_serverOverride` and `_globalOptionString` live in a single `apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` library as public top-level helpers (`serverOverride`, `globalOptionString`).
- [ ] Net LOC reduction is at least 150 across the touched workflow CLI command files plus the new base/helper files.
- [ ] `workflow {pause,resume,retry,cancel,status,show,runs}` preserve command names, flags, stdout/stderr text, exit codes, and JSON shapes.
- [ ] `dart format --set-exit-if-changed apps/dartclaw_cli`, `dart analyze --fatal-warnings --fatal-infos apps/dartclaw_cli`, and `dart test apps/dartclaw_cli` pass.


## Scenarios

### Identical behavior across pause/resume/retry

- **Given** the server is running and a workflow run exists
- **When** the operator runs `dartclaw workflow pause <runId>`, `dartclaw workflow resume <runId>`, or `dartclaw workflow retry <runId>`
- **Then** each command calls the same REST endpoint as before, prints the same human-readable output or JSON body as before, and exits with the same code.

### Missing run-id behavior is unchanged

- **Given** any run-id command that requires a positional run id
- **When** the operator invokes it without a positional argument
- **Then** it throws the same `UsageException` as before.

### Shared global-option helpers preserve connected-command behavior

- **Given** a workflow CLI subcommand that reads `--config`, `--server`, or `--token`
- **When** the helper moves from file-local functions to `cli_global_options.dart`
- **Then** parsed and absent global options resolve exactly as before, including the existing `ArgumentError` fallback for command tests without the global parser.


## Scope & Boundaries

### In Scope

- New file `apps/dartclaw_cli/lib/src/commands/workflow/workflow_run_id_command.dart` with shared constructor fields, `_requireRunId()`, `_resolveApiClient()`, and `runAgainstRun(String path, {required String verb})`.
- Collapse `workflow_pause_command.dart`, `workflow_resume_command.dart`, and `workflow_retry_command.dart` by extending the new base.
- New file `apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` exposing `serverOverride(ArgResults?)` and `globalOptionString(ArgResults?, String)`.
- Re-import the shared helper library from workflow command files that currently carry duplicated global-option helpers.
- LOC delta verification and normal CLI package validation.

### What We're NOT Doing

- Not changing CLI output format, command names, flags, REST payloads, or exit-code behavior.
- Not bootstrapping AndThen from `WorkflowShowCommand`. Standalone resolved show intentionally reads provisioned data-dir skill roots only.
- Not adding new commands or dependencies.
- Not refactoring `cli_workflow_wiring.dart` or `service_wiring.dart`.
- Not extracting a base class for `cancel`, `status`, `show`, `runs`, `run`, `list`, or `validate`; those commands only share the lifted global-option helpers.

### Agent Decision Authority

- **Autonomous**: Exact private/public visibility of base-class members, as long as command behavior and tests remain stable; helper names matching `serverOverride` / `globalOptionString`.
- **Escalate**: Any change that alters CLI stdout/stderr text, exit codes, command flags, or REST paths.


## Architecture Decision

**We will**: Introduce `WorkflowRunIdCommand` as an abstract base owning the duplicated run-id command fields, `_requireRunId()`, `_resolveApiClient()`, and POST-result formatting used by pause/resume/retry. Lift file-private `_serverOverride()` / `_globalOptionString()` copies into `apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` as `serverOverride` / `globalOptionString`, because Dart privacy is library-scoped and imported helpers cannot keep leading underscores.

**Rationale**: The cleanup removes real duplication without changing CLI semantics. Pause, resume, and retry share the same POST + JSON-or-text shape; other workflow commands do not, so forcing them into the base would widen the diff without reducing meaningful complexity.


## Technical Overview

### Integration Points

- `apps/dartclaw_cli/lib/src/commands/workflow/workflow_pause_command.dart`
- `apps/dartclaw_cli/lib/src/commands/workflow/workflow_resume_command.dart`
- `apps/dartclaw_cli/lib/src/commands/workflow/workflow_retry_command.dart`
- `apps/dartclaw_cli/lib/src/commands/workflow/workflow_cancel_command.dart`
- `apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart`
- `apps/dartclaw_cli/lib/src/commands/workflow/workflow_show_command.dart`
- `apps/dartclaw_cli/lib/src/commands/workflow/workflow_runs_command.dart`
- `apps/dartclaw_cli/lib/src/commands/workflow/workflow_run_command.dart`

### Code Patterns

```
# type | path | why needed
file | apps/dartclaw_cli/lib/src/commands/workflow/workflow_pause_command.dart | current run-id POST command shape
file | apps/dartclaw_cli/lib/src/commands/workflow/workflow_resume_command.dart | current run-id POST command shape
file | apps/dartclaw_cli/lib/src/commands/workflow/workflow_retry_command.dart | current run-id POST command shape
file | apps/dartclaw_cli/lib/src/commands/workflow/workflow_show_command.dart | shared global-option helper consumer
file | apps/dartclaw_cli/lib/src/commands/connected_command_support.dart | existing connected-command support pattern
file | apps/dartclaw_cli/CLAUDE.md | package-scoped CLI conventions
```


## Implementation Plan

- [ ] **TI01** Add `WorkflowRunIdCommand` at `apps/dartclaw_cli/lib/src/commands/workflow/workflow_run_id_command.dart`.
  - **Verify**: `rg -n "abstract class WorkflowRunIdCommand" apps/dartclaw_cli/lib/src/commands/workflow/workflow_run_id_command.dart` returns 1; `dart analyze apps/dartclaw_cli` clean.

- [ ] **TI02** Convert pause, resume, and retry commands to extend `WorkflowRunIdCommand`.
  - **Verify**: each file is <=25 LOC; existing pause/resume/retry command tests pass unchanged.

- [ ] **TI03** Add `apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` with `serverOverride` and `globalOptionString`.
  - **Verify**: `rg -n "^String\\?\\s+serverOverride|^String\\?\\s+globalOptionString" apps/dartclaw_cli/lib/src/commands/cli_global_options.dart` returns 2.

- [ ] **TI04** Replace duplicated file-local global-option helpers in workflow command files with imports of `cli_global_options.dart`.
  - **Verify**: `rg -n "String\\?\\s+_serverOverride|String\\?\\s+_globalOptionString" apps/dartclaw_cli/lib/src/commands/workflow/` returns 0.

- [ ] **TI05** Record the net LOC reduction.
  - **Verify**: `before - after - new_files >= 150`, with the calculation recorded in implementation observations or the commit message.

- [ ] **TI06** Run full CLI validation.
  - **Verify**: `dart format --set-exit-if-changed apps/dartclaw_cli`, `dart analyze --fatal-warnings --fatal-infos apps/dartclaw_cli`, and `dart test apps/dartclaw_cli` exit 0.


## Testing Strategy

- Existing pause/resume/retry tests prove output and JSON shape stability.
- Existing connected command tests prove global-option resolution behavior.
- Add narrow tests only if existing coverage misses a command touched by the helper move.


## Final Validation Checklist

- [ ] All success criteria met.
- [ ] All tasks TI01-TI06 completed and verified.
- [ ] CLI behavior byte-identical for touched commands.
- [ ] Net LOC reduction >=150 measured and recorded.


## Implementation Observations
