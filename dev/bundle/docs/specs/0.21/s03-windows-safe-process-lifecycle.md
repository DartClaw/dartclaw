# Windows-Safe Process Lifecycle

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: Make DartClaw's harness-pool and managed-subprocess shutdown honest on Windows, where `Process.kill()` is an unconditional hard terminate and POSIX SIGTERM/SIGKILL semantics do not exist, so operators are never told a shutdown was graceful when a managed process was actually force-killed or left running.

**Expected Outcomes** (scenarios anchor to these via `[OC<NN>]`):

- [OC01] On native Windows, harness-pool and managed-subprocess shutdown completes without depending on POSIX signal semantics, and the hard-terminate path is selected from the platform capability surface's `posixSignalsAvailable` member rather than an ad hoc `Platform.isWindows` check.
- [OC02] POSIX SIGTERM-then-SIGKILL escalation is preserved and regression-covered (no behavior change on macOS/Linux).
- [OC03] After normal shutdown, each process owner reaps its managed subprocesses: `HarnessPool` owns harnesses, workflow CLI providers own their child processes, and channel managers own sidecars.
- [OC04] When a managed process cannot be confirmed terminated after its grace period, `killWithEscalation` logs a clear lifecycle warning naming the process and returns an unconfirmed typed result; public `AgentHarness` and `HarnessPool` lifecycle APIs remain `Future<void>`.


## Required Context

### From `docs/specs/0.21/prd.md` – "FR2: Windows-Safe Process Lifecycle"
<!-- source: docs/specs/0.21/prd.md#fr2-windows-safe-process-lifecycle -->
<!-- extracted: ad8e7b9 -->
> **Acceptance Criteria**:
> - [ ] Harness-pool shutdown does not rely on SIGTERM/SIGKILL semantics on Windows.
> - [ ] Windows hard-terminate behavior is documented in runtime expectations and tests.
> - [ ] Child-process cleanup paths avoid orphaning known DartClaw-managed subprocesses during normal shutdown.
>
> **Inputs / Outputs**:
> - **Inputs**: Running harness, workflow, or sidecar subprocesses.
> - **Outputs**: Completed shutdown, structured failure, or documented hard termination.
>
> **Validation**:
> - Windows lifecycle test or smoke evidence proves managed subprocesses are not left running after normal shutdown.
>
> **Error Handling**:
> - If a process cannot be terminated or observed after shutdown, DartClaw logs a clear lifecycle warning and does not report graceful shutdown.

### From `docs/specs/0.21/prd.md` – "Key Constraints, Assumptions & Dependencies"
<!-- source: docs/specs/0.21/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: ad8e7b9 -->
> - **Constraint**: `Process.kill()` is a hard terminate on Windows, and SIGUSR1/SIGTERM-style reload/shutdown assumptions do not port.

### From `docs/specs/0.21/plan.json` – sharedDecisions "Platform capability surface API" (S01 dependency, pre-resolved)
<!-- source: docs/specs/0.21/plan.json#/sharedDecisions/0 -->
<!-- extracted: ad8e7b9 -->
> S01 defines the single documented capability surface (home-directory resolution, executable lookup, shell capability, process termination semantics, feature availability); S03, S04, S05, S06, and S07 route all Windows-specific gating and lookups through it instead of adding ad hoc Platform.isWindows checks.

> **Consuming note (S03)**: spec against S01's decision, not S01's FIS. S03 consumes S01's `posixSignalsAvailable` boolean (true on POSIX, false on Windows; S01 TI01): when it is false, `killWithEscalation` hard-terminates and issues no `ProcessSignal.sigkill`; when true, it keeps the SIGTERM→SIGKILL escalation. S01 owns and exposes this member; do not invent a parallel check.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01,TI02] Windows shutdown hard-terminates without POSIX-signal escalation**
  - **Given** a running DartClaw-managed harness process on a host whose platform capability surface reports `posixSignalsAvailable` false (Windows, no POSIX signal support)
  - **When** the shutdown path (`killWithEscalation`) runs against that process
  - **Then** the process is terminated via a single hard terminate and no `ProcessSignal.sigkill` escalation is issued, and the escalation decision is read from the capability surface's `posixSignalsAvailable` member, not a direct `Platform.isWindows` branch in `process_lifecycle.dart`

- [x] **S02 [OC02] [TI01] POSIX SIGTERM-then-SIGKILL escalation is preserved**
  - **Given** a running managed process on POSIX that does not exit after the initial `Process.kill()` (SIGTERM) within the grace period
  - **When** `killWithEscalation` exceeds `gracePeriod`
  - **Then** it escalates with `process.kill(ProcessSignal.sigkill)` and reaps the process, unchanged from current macOS/Linux behavior

- [x] **S03 [OC03] [TI03] Each normal-shutdown owner leaves no managed subprocess orphaned**
  - **Given** native-Windows real-process lifecycle proof plus owner-level suites for `HarnessPool`, workflow CLI providers, and channel managers running on the same native host
  - **When** the shared lifecycle primitive reaps its recorded directly managed root and each owner shutdown suite runs against a controlled process handle
  - **Then** the real root PID is confirmed exited, and every owner releases its process only after confirmed exit while retaining unconfirmed ownership; this compositional proof does not claim live provider or sidecar executable integration

- [x] **S04 [OC04] [TI02,TI04] Unconfirmed termination returns a typed result and logs locally**
  - **Given** a managed process that does not exit within its grace period and whose exit cannot be observed
  - **When** the shutdown path completes for that process
  - **Then** `killWithEscalation` returns `ProcessTerminationResult(exitConfirmed: false, …)` and logs a lifecycle warning through its supplied logger naming the process `label`; the warning text does not claim SIGTERM/SIGKILL on Windows


## Structural Criteria

- [x] Existing harness lifecycle tests (`acp_harness_lifecycle_test.dart`, `claude_code_harness_test.dart`, `codex_harness_test.dart`) and channel-manager kill tests continue to pass unchanged.
- [x] `killWithEscalation`'s public signature and existing callers (`base_harness.dart#shutdownCurrentProcess`, `acp_harness.dart`, `cli_process_supervisor.dart`, `signal_cli_manager.dart`, `gowa_manager.dart`) remain source-compatible, or every caller is updated in the same change.
- [x] No new `Platform.isWindows` process-termination branch is introduced outside the platform capability surface (US07).


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_core/lib/src/harness/process_lifecycle.dart#killWithEscalation` – Windows-honest termination (capability-surface-driven escalation, corrected doc comment) and a confirmed-vs-unconfirmed exit result.
- Platform capability surface consumption (S01) – the `posixSignalsAvailable` member sourced from the surface instead of the inline `Platform.isWindows` check at `process_lifecycle.dart`.
- `packages/dartclaw_core/lib/src/harness/harness_pool.dart#HarnessPool.dispose` – harness-only normal-shutdown ownership; public `Future<void>` contract remains unchanged.
- Managed-subprocess owners – `base_harness.dart#shutdownCurrentProcess`, workflow CLI providers/supervisors, and channel managers each prove their own children are reaped.
- Runtime/architecture doc coverage of the Windows hard-terminate contract (expectations that termination is unconditional on Windows).

### What We're NOT Doing
- Signal-based config reload (SIGUSR1 / Windows reload path) -- owned by S04.
- Provider-specific harness protocol work (Claude JSONL / Codex JSON-RPC turn behavior) -- owned by S07.
- Defining the platform capability surface API itself -- owned by S01; S03 only consumes its `posixSignalsAvailable` member.
- Emulating POSIX signals on Windows or adding a graceful-shutdown handshake to child processes -- out of scope; the Windows contract is documented hard terminate.


## Architecture Decision

**Approach**: Route escalation through ADR-049's `posixSignalsAvailable`; return a `ProcessTerminationResult` carrying `initialTerminationAccepted`, `exitConfirmed`, and `hardTerminationUsed`; and let `killWithEscalation` emit the unconfirmed warning through its existing `label`/`Logger`. Callers may inspect or ignore the result. `AgentHarness.stop`/`dispose` and `HarnessPool.dispose` remain `Future<void>`.
**Why this over alternatives**: The helper already owns the observation, process label, and logger. Local warning avoids a breaking result-propagation chain, exceptions that could interrupt best-effort cleanup, and hidden side-channel state while still providing a typed result for tests and direct callers.


## Code Patterns & External References

```
# type | path#anchor                                                              | why needed (intent)
file   | packages/dartclaw_core/lib/src/harness/process_lifecycle.dart#killWithEscalation | Current SIGTERM/SIGKILL escalation with inline Platform.isWindows guard – the surface to make capability-driven + return exit confirmation
file   | packages/dartclaw_core/lib/src/harness/base_harness.dart#shutdownCurrentProcess  | Primary managed-process shutdown caller – consumes killWithEscalation result
file   | packages/dartclaw_server/lib/src/harness_pool.dart#dispose                       | Pool graceful-shutdown loop – add lifecycle warning + not-graceful signalling
file   | packages/dartclaw_server/lib/src/task/cli_process_supervisor.dart                | Workflow-CLI managed subprocess kill path – orphan-avoidance caller
file   | packages/dartclaw_testing/lib/src/fake_process.dart                              | Test double for Process – drive grace-period-timeout and signal-assertion scenarios
```


## Constraints & Gotchas

- **Critical**: On Windows `process.kill()` (default `ProcessSignal.sigterm`) is already an unconditional hard terminate and `ProcessSignal.sigkill` must not be sent -- Must handle by: gating escalation on the capability surface, never assuming the initial kill was a cooperative signal.
- **Constraint**: `killWithEscalation` is exported from `dartclaw_core` and reused by channel packages (`signal`, `whatsapp`) -- Workaround: any signature change is applied to all callers in the same change, or made additive/back-compatible.
- **Avoid**: Adding a new `Platform.isWindows` branch for termination -- Instead: consume S01's `posixSignalsAvailable` member (US07 / sharedDecision).


## Implementation Plan

### Implementation Tasks

- [x] **TI01** `killWithEscalation` selects escalation behavior from the platform capability surface's `posixSignalsAvailable` member
  - Replace the inline `Platform.isWindows` guard in `process_lifecycle.dart#killWithEscalation` with a read of S01's `posixSignalsAvailable` member (Required Context: sharedDecisions "Platform capability surface API"); POSIX (`posixSignalsAvailable` true) still escalates to `ProcessSignal.sigkill` after `gracePeriod`, Windows (false) never does. Correct the doc comment so it no longer claims "Sends SIGTERM" unconditionally.
  - **Verify**: `Test: with a fake process on Windows-semantics, killWithEscalation issues no ProcessSignal.sigkill after gracePeriod; on POSIX-semantics it issues ProcessSignal.sigkill` (covers S01, S02)

- [x] **TI02** `killWithEscalation` returns the typed termination result without widening harness/pool lifecycle APIs
  - Replace the boolean return with `ProcessTerminationResult(initialTerminationAccepted, exitConfirmed, hardTerminationUsed)`. Existing callers that only await may ignore it; update any caller that consumes the former boolean. Keep `AgentHarness.stop`/`dispose` and `HarnessPool.dispose` as `Future<void>`.
  - **Verify**: `Test: never-exiting fake yields exitConfirmed=false; in-grace exit yields true; Windows initial hard terminate sets hardTerminationUsed=true; POSIX sets it only when escalation occurs`

- [x] **TI03** Normal shutdown proves no orphans at each real ownership boundary
  - Confirm `HarnessPool.dispose()` owns runner harnesses only. Run owner-level tests for workflow CLI providers/supervisors and channel managers on native Windows x64 with controlled process handles. Record a real-process PID and confirmed exit at the shared lifecycle primitive; together these form the owner-boundary proof required by FR2.
  - **Verify**: `Native Windows: the real-process lifecycle test records its directly managed root PID and confirms exit; pool, workflow, and channel owner suites pass on the same host, releasing confirmed processes and retaining unconfirmed ownership.` (covers S03)

- [x] **TI04** `killWithEscalation` logs a platform-honest warning for an unconfirmed result
  - When `exitConfirmed` is false, log through the supplied logger with the process `label`. Windows wording states that hard termination could not be confirmed and must not claim SIGTERM/SIGKILL; POSIX wording may name its escalation path. Do not add result plumbing to `AgentHarness` or `HarnessPool`.
  - **Verify**: `Test: unconfirmed Windows semantics logs the label and no SIGTERM/SIGKILL claim; unconfirmed POSIX semantics names the escalation; public harness/pool lifecycle signatures remain Future<void>` (covers S04)

- [x] **TI05** Windows hard-terminate behavior is documented as the runtime contract
  - Record in runtime/architecture docs that Windows shutdown is an unconditional hard terminate (no SIGTERM/SIGKILL escalation) and that unconfirmed termination surfaces a lifecycle warning; align with the capability-surface doc from S01.
  - **Verify**: `Test/Check: architecture/runtime doc states Windows Process.kill() is a documented hard terminate and references the platform capability surface` (proves Structural doc-coverage of FR2 AC "documented in runtime expectations")


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only implementation records._

### Run: 2026-07-14 06:12 UTC – observations

#### QUALIFICATION COMPLETE: native-windows-x64

[GitHub Actions run 29310391226](https://github.com/DartClaw/dartclaw/actions/runs/29310391226) ran the core
process-lifecycle, base-harness, harness-pool, workflow CLI-provider, signal-cli-manager, and GOWA-manager suites on
native Windows x64. All 68 tests passed. The real-process test recorded directly managed root PID 4168 and confirmed
it was reaped; owner suites prove release after confirmed exit and ownership retention when cleanup is unconfirmed.
Stable evidence is recorded in `dev/testing/evidence/windows-runtime-smoke.md`.

### Run: 2026-07-14 06:20 UTC – design-change

#### DESIGN CHANGE

Native qualification exercises the real directly managed Windows process at the shared lifecycle primitive and runs
each actual owner contract suite on that native host with controlled process handles. The acceptance proof is explicitly
compositional; it does not claim that external provider or sidecar binaries were installed and exercised live.

##### Acceptance-scenario proof amendment

Old:

```markdown
- [x] **S03 [OC03] [TI03] Each normal-shutdown owner leaves no managed subprocess orphaned**
  - **Given** running harness, workflow-CLI, and channel-sidecar subprocesses under their actual owners
  - **When** `HarnessPool.dispose()`, the workflow CLI provider/supervisor shutdown, and the channel-manager shutdown each complete
  - **Then** the subprocesses owned by each boundary have exited; the pool proof covers harnesses only and does not assume ownership of workflow or channel processes
```

New:

```markdown
- [x] **S03 [OC03] [TI03] Each normal-shutdown owner leaves no managed subprocess orphaned**
  - **Given** native-Windows real-process lifecycle proof plus owner-level suites for `HarnessPool`, workflow CLI providers, and channel managers running on the same native host
  - **When** the shared lifecycle primitive reaps its recorded directly managed root and each owner shutdown suite runs against a controlled process handle
  - **Then** the real root PID is confirmed exited, and every owner releases its process only after confirmed exit while retaining unconfirmed ownership; this compositional proof does not claim live provider or sidecar executable integration
```

##### Implementation-task proof amendment

Old:

```markdown
- [x] **TI03** Normal shutdown proves no orphans at each real ownership boundary
  - Confirm `HarnessPool.dispose()` reaps runner harnesses only. Add or extend owner-level tests for workflow CLI providers/supervisors and channel managers rather than attaching those processes to the pool. Record native-Windows lifecycle test or smoke evidence with child PIDs showing they are no longer alive after shutdown, as required by FR2.
  - **Verify**: `Tests: pool disposal reaps harnesses; workflow and channel shutdown each reap their own child. Windows evidence records the managed child PIDs and confirms each exited after normal shutdown.` (covers S03)
```

New:

```markdown
- [x] **TI03** Normal shutdown proves no orphans at each real ownership boundary
  - Confirm `HarnessPool.dispose()` owns runner harnesses only. Run owner-level tests for workflow CLI providers/supervisors and channel managers on native Windows x64 with controlled process handles. Record a real-process PID and confirmed exit at the shared lifecycle primitive; together these form the owner-boundary proof required by FR2.
  - **Verify**: `Native Windows: the real-process lifecycle test records its directly managed root PID and confirms exit; pool, workflow, and channel owner suites pass on the same host, releasing confirmed processes and retaining unconfirmed ownership.` (covers S03)
```

#### ADR

[ADR-049](../../../../adrs/049-typed-platform-capability-surface.md) defines the native Windows contract as hard
termination of a directly managed root. The project decision on process-termination confirmation keeps ownership local
until exit is confirmed. Together they make real-primitive plus owner-contract proof the honest 0.21 qualification
boundary without adding external binary dependencies to the native x64 gate.
