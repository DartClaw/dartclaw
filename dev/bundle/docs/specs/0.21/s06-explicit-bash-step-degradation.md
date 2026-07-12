# Explicit Bash-Step Degradation — Feature Implementation Specification

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S06

## Feature Overview and Goal

**Intent**: Make workflow bash steps behave predictably on native Windows — run through Git Bash when it is present, and fail with an explicit, actionable message when it is not — so a Windows operator is never told a bash step "succeeded" when no shell ran.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] POSIX bash-step execution is unchanged: steps run through `/bin/sh` and existing success/failure reporting is preserved.
- [OC02] On native Windows with Git Bash present, bash steps run through the detected `bash.exe`, qualified for version capture, environment propagation, basic POSIX commands, and the clarified path contract: a native Windows cwd with drive letter/spaces maps to Git Bash `pwd` and supports quoted relative-file access; arbitrary command arguments are not rewritten.
- [OC03] On native Windows without Git Bash, a bash step fails with the structured unsupported-capability error carrying "bash steps require Git Bash on Windows" and remediation — it never returns an empty success result.


## Required Context

> Load-bearing upstream spans inlined verbatim. The inlined text is the contract the executor builds to.

### From `prd.md` – "FR10: Explicit Bash-Step Degradation"
<!-- source: docs/specs/0.21/prd.md#fr10-explicit-bash-step-degradation -->
<!-- extracted: ad8e7b9 -->
> **Description**: Make workflow bash-step behavior on Windows predictable.
>
> **Acceptance Criteria**:
> - If Git Bash's `bash.exe` is available, bash steps can run through it with documented expectations.
> - If bash is unavailable, bash workflow steps fail with a clear message: bash steps require Git Bash on Windows.
> - Full cross-platform script semantics remain deferred to Workflow DSL v2.
>
> **Inputs / Outputs**: Inputs: Workflow step requiring bash, detected shell capabilities. Outputs: Step execution through bash or structured unsupported error.
>
> **Validation**: Tests cover Windows with Git Bash detected, Windows without bash, and existing POSIX behavior. Git Bash qualification covers version capture, cwd, environment propagation, path handling, and basic POSIX command execution.
>
> **Error Handling**: Missing bash fails the step explicitly and preserves workflow error reporting; it never returns an empty success result.

### From `plan.json` – binding constraint FR10 (applies to S06 verbatim)
<!-- source: docs/specs/0.21/prd.md#fr10-explicit-bash-step-degradation -->
<!-- extracted: ad8e7b9 -->
> Missing bash fails the step explicitly and preserves workflow error reporting; it never returns an empty success result.

### From `prd.md` – "US05" (User Stories table)
<!-- source: docs/specs/0.21/prd.md#user-stories -->
<!-- extracted: ad8e7b9 -->
> US05 | As a Windows developer, I want unsupported features to fail clearly so that I know whether to install Git Bash, use POSIX, or wait for a future feature. | Container isolation and unavailable bash steps return explicit actionable errors, not crashes, silent no-ops, or misleading security claims. | Must / P0

### From `plan.json` – shared decisions this story consumes
<!-- source: docs/specs/0.21/plan.json#sharedDecisions -->
<!-- extracted: ad8e7b9 -->
> **Platform capability surface API**: S01 defines the single documented capability surface (home-directory resolution, executable lookup, shell capability, process termination semantics, feature availability); S03, S04, S05, S06, and S07 route all Windows-specific gating and lookups through it instead of adding ad hoc `Platform.isWindows` checks.
>
> **Unsupported-capability error contract**: S01 defines the structured unsupported-feature/lookup-failure error shape (names the capability, includes attempted context, points at remediation); S04's POSIX-only signal-reload message, S05's container-isolation rejection, and S06's missing-bash step failure all use it.


## Deeper Context

- `../dartclaw-public/dev/adrs/049-typed-platform-capability-surface.md` and the S01 FIS – the exact `bashShellPolicy`, executable-lookup command-data, and structured-error contracts S06 consumes.
- `docs/specs/0.21-windows-bash-path-qualification/requirements-clarification.md` – resolved 0.21 path-handling boundary: native cwd fidelity and relative access, no arbitrary argument translation.
- `docs/specs/0.24/workflow-dsl-v2.md` – where full cross-platform / PowerShell / polyglot `script:` semantics land; confirms S06 is scoped to Git Bash detection + degradation only.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI02] POSIX bash step runs unchanged through `/bin/sh`**
  - **Given** a `type: bash` step with prompt `echo hello` executed on a POSIX host (capability surface reports `operatingSystem: 'linux'`)
  - **When** the step runs
  - **Then** the step completes with `status = 'success'`, `exitCode = 0`, and the command actually executed (stdout `hello` captured)

- [x] **S02 [OC01] [TI01] POSIX shell selection resolves to `/bin/sh`**
  - **Given** a capability surface constructed with `operatingSystem: 'linux'`
  - **When** the bash-step shell is selected for command `echo ok`
  - **Then** the selected executable is `/bin/sh` with argument prefix `['-c', 'echo ok']` (no executable lookup performed)

- [x] **S03 [OC02] [TI01] Windows with Git Bash detected selects the resolved `bash.exe`**
  - **Given** a capability surface with `operatingSystem: 'windows'` and a bash lookup that resolves `bash.exe` to `C:\Program Files\Git\bin\bash.exe`
  - **When** the bash-step shell is selected for command `echo ok`
  - **Then** the selected executable is `C:\Program Files\Git\bin\bash.exe` with argument prefix `['-c', 'echo ok']`

- [x] **S04 [OC03] [TI01,TI03] Windows without Git Bash fails explicitly, never empty success**
  - **Given** a `type: bash` step on a capability surface with `operatingSystem: 'windows'` whose bash lookup resolves nothing
  - **When** the step runs
  - **Then** the step outcome has `success = false` and `${step.id}.status = 'failed'`, and the error is the structured unsupported-capability error whose message contains `bash steps require Git Bash on Windows`, names the bash/shell capability, and points at remediation (install Git Bash / use POSIX / WSL) — and no `status = 'success'` outcome is ever produced

- [ ] **S05 [OC02] [TI04] Windows host with Git Bash qualifies the run**
  - **Given** a native Windows host with Git Bash installed and a `type: bash` step whose native cwd contains a drive letter and spaces and whose fixture filename also contains spaces
  - **When** the step runs (via the Windows runtime smoke path or recorded manual evidence)
  - **Then** the step completes successfully; evidence records the native cwd, its Git Bash POSIX-style `pwd`, successful quoted relative-file access, an allowlisted env value, a basic POSIX command result, and the Git Bash version


## Structural Criteria

> Proved by task Verify lines, not scenarios.

- [x] Existing `dartclaw_workflow` bash-step tests remain green on macOS/Linux — POSIX bash execution via `/bin/sh`, success/failure reporting, output extraction, and timeout handling are unchanged.
- [x] The bash step runner no longer spawns a hardcoded unconditional `/bin/sh`; shell selection uses ADR-049's `bashShellPolicy`, and the runner adds no ad hoc `Platform.isWindows` branch.


## Scope & Boundaries

### Work Areas
- Bash-step shell selection in `packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart` (`executeBashStep`) — the hardcoded `/bin/sh` spawn becomes surface-driven selection.
- A testable shell-selection seam consuming `bashShellPolicy` + an injectable bash lookup executor, returning the shell invocation or raising the structured unsupported-capability error.
- Threading the platform capability surface through `StepExecutionContext` / `bashStepRun` (default: real `Platform`-backed surface) in `workflow_runner_types.dart`.
- Unit + regression tests in `packages/dartclaw_workflow/test/workflow/bash_step_runner_test.dart`.
- Committed native-Windows qualification scenario at `dev/testing/scenarios/windows-bash-step.md` plus stable latest-run evidence at `dev/testing/evidence/windows-bash-step.md`; git history preserves prior records.

### What We're NOT Doing
- PowerShell, cmd, or polyglot `script:` semantics -- deferred to Workflow DSL v2 (`docs/specs/0.24/workflow-dsl-v2.md`); S06 covers only Git Bash detection + degradation.
- Automatic conversion of arbitrary Windows paths in command arguments – explicitly outside the clarified 0.21 contract; template values and authored commands keep existing escaping/interpretation semantics.
- Defining the capability surface or the unsupported-capability error type -- owned by S01; S06 consumes both.
- Windows process-tree termination for bash steps -- the existing `_descendantPids` path is POSIX-only (`pgrep`); Windows child-tree cleanup is S03's lifecycle scope, not S06.
- Auto-installing or bootstrapping Git Bash -- the degradation only detects and reports; installation is the user's remediation step.
- Adding a bash layer to S09 – S06 owns its qualification scenario/evidence; S09 remains the server/UI/storage/reload/harness runtime smoke path.


## Architecture Decision

**Approach**: Replace the unconditional `SafeProcess.start('/bin/sh', ['-c', cmd], …)` with ADR-049's shell contract: `BashShellPolicy.systemSh` selects `/bin/sh`; `gitBashRequired` executes the surface's lookup command for `bash`, then uses the resolved `bash.exe`. A missing executable raises the shared structured unsupported-capability error and maps to `bashFailure`.
**Why this over alternatives**: An injectable OS + bash-lookup seam (mirroring S01's dual-OS pattern) makes the Windows selection and the missing-bash failure unit-testable from a POSIX CI host, so the FR10 "never empty success" guarantee is proven without a Windows runner; S06's own committed scenario and stable evidence record qualify real Git Bash working-directory behavior on Windows.


## Code Patterns & External References

```
# type | path#anchor                                                                              | why needed (intent)
file   | packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart#executeBashStep        | The hardcoded `/bin/sh` spawn (line ~78) to make surface-driven; keep env sanitize, workdir, output paths intact
file   | packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart#bashFailure            | Failure-outcome shape to reuse for the missing-bash case (success=false, status=failed, error text)
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_runner_types.dart#StepExecutionContext | Where to thread the injectable capability surface alongside hostEnvironment/bashStep* fields
file   | packages/dartclaw_config/lib/src/platform_capabilities.dart                              | S01 surface: injectable OS/env, executable-lookup command as data, structured unsupported-capability error (consume, do not redefine)
spec   | docs/specs/0.21/s01-platform-capability-surface.md#implementation-tasks                  | S01 accessor + error-type shapes S06 depends on
```


## Constraints & Gotchas

- **Avoid**: adding a `Platform.isWindows` branch inside the bash runner -- Instead: read the OS and executable-lookup command from the injected S01 surface, so the shell choice stays unit-testable and future stories inherit it (US07).
- **Constraint**: the missing-bash outcome must map to the existing failure shape (`success = false`, `${step.id}.status = 'failed'`, populated `.error`) -- Must handle by: routing the structured unsupported-capability error through `bashFailure`, never falling through to a `StepOutcome` with `success = true` or empty outputs.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** Bash-step shell selection is chosen through the S01 capability surface: POSIX yields `/bin/sh`, Windows yields the resolved Git Bash `bash.exe`, and Windows-with-no-bash raises the structured unsupported-capability error naming the bash/shell capability with "bash steps require Git Bash on Windows" and remediation.
  - Pure/injectable seam driven by `bashShellPolicy` + `executableLookupCommand('bash')` (stubbed in tests); argument prefix stays `['-c', resolvedCommand]` for both shells. Consumes the S01 error type – does not define a new one.
  - **Verify**: `Test: linux surface selects '/bin/sh' with ['-c','echo ok']; windows surface with bash resolved to 'C:\\Program Files\\Git\\bin\\bash.exe' selects that path with ['-c','echo ok']; windows surface with no bash throws the structured error whose message contains 'bash steps require Git Bash on Windows'`

- [x] **TI02** `executeBashStep` spawns via the selected shell with the capability surface threaded through `StepExecutionContext`/`bashStepRun` (default real `Platform`-backed surface); POSIX execution, env sanitize, workdir containment, output extraction, and timeout handling are unchanged.
  - Reuse `SafeProcess.start` with the selected executable/args; keep `EnvPolicy.sanitize`, `resolveBashWorkdir`, and bounded-output collection as-is. Later tasks consume the surface added here.
  - **Verify**: `Test: a bash step 'echo hello' on the POSIX host still completes with status='success', exitCode=0, stdout 'hello'; existing bash_step_runner_test.dart suite passes unchanged`

- [x] **TI03** A bash step on a Windows surface with no Git Bash produces a failed outcome via `bashFailure`, never an empty success.
  - Map the TI01 structured error onto `bashFailure(step, '<error message>')` so `success = false`, `${step.id}.status = 'failed'`, and `${step.id}.error` carries the message; assert no `status = 'success'` path is reachable when bash is unresolved.
  - **Verify**: `Test: executeBashStep with a windows surface + empty bash lookup returns a StepOutcome where success is false, outputs['${step.id}.status'] == 'failed', and outputs['${step.id}.error'] contains 'bash steps require Git Bash on Windows'; no outcome has status 'success'`

- [ ] **TI04** On a native Windows host with Git Bash, a bash step is qualified for version capture, working directory, environment propagation, path handling, and basic POSIX command execution.
  - Add `dev/testing/scenarios/windows-bash-step.md` as the committed manual scenario and record the latest completed run in `dev/testing/evidence/windows-bash-step.md`. The scenario uses a Windows cwd with a drive letter and spaces plus a relative fixture filename containing spaces. The evidence records native cwd, Git Bash `pwd`, quoted relative access, Git Bash version, an allowlisted env value, a POSIX command result, OS/arch, and artifact/source under test. It does not claim automatic argument-path conversion.
  - **Verify**: `Inspection/run: both stable paths exist; latest evidence identifies OS/arch + artifact/source, and from a native cwd containing drive letter/spaces records the corresponding Git Bash pwd, quoted relative-file success, env/POSIX command result, and bash version`

### Testing Strategy
> The injectable policy + bash-lookup seam makes TI01/TI03 unit-testable on POSIX CI; TI02 is covered by the existing regression suite. TI04 is S06-owned native-Windows proof through `dev/testing/scenarios/windows-bash-step.md`, persisted at `dev/testing/evidence/windows-bash-step.md`; it is not delegated to S09.

### Validation
> Leave empty — standard exec-spec build/test/analyze gates apply.

### Execution Contract
> Leave empty — natural TI01 → TI02 → TI03 ordering is stated in the task descriptions; no further cross-task constraints.


## Final Validation Checklist
> Leave empty — Acceptance Scenarios, Structural Criteria, and task Verify lines are the completion gates.


## Implementation Observations

_No observations recorded yet._
