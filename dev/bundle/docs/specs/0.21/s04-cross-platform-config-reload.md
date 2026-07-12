# Cross-Platform Config Reload

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: Give Windows operators a working config-reload path and stop the runtime from silently pretending signal-based reload works on a platform that has no SIGUSR1.

**Expected Outcomes** (user-/business-observable success conditions):

- [OC01] On Windows, an operator can change the config file and have the running server apply reloadable changes without a restart, via the file-watch (`auto`) reload path.
- [OC02] Requesting signal-based reload on a platform without signal support (Windows) produces a clear POSIX-only message that names the capability and points at the file-watch mechanism — never a silent no-op.
- [OC03] POSIX SIGUSR1 reload keeps working exactly as before and stays regression-tested.
- [OC04] A config that fails to load or validate on reload is rejected and the previously valid config stays active, on both platforms.


## Required Context

### From `prd.md` – "FR3: Cross-Platform Config Reload"
<!-- source: prd.md#fr3-cross-platform-config-reload -->
<!-- extracted: ad8e7b9 -->
> **Description**: Make config reload usable on Windows without breaking POSIX SIGUSR1 reload.
>
> **Acceptance Criteria**:
> - Windows has a supported reload path, such as file-watch or an authenticated local endpoint.
> - Signal-triggered reload clearly reports POSIX-only behavior when invoked or documented on Windows.
> - POSIX SIGUSR1 behavior remains available and regression-tested.
> - Documentation names the supported reload mechanism per platform.
>
> **Inputs / Outputs**: Inputs: config file changes or reload trigger. Outputs: reloaded configuration, validation error, or explicit POSIX-only message for signal-triggered reload.
>
> **Error Handling**: Invalid config reload leaves the previous valid config active and reports validation failures.

### From `prd.md` – FR3 binding constraint (verbatim)
<!-- source: prd.md#fr3-cross-platform-config-reload -->
<!-- extracted: ad8e7b9 -->
> POSIX SIGUSR1 behavior remains available and regression-tested.

### From `plan.json` – sharedDecision "Platform capability surface API"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: ad8e7b9 -->
> S01 defines the single documented capability surface (home-directory resolution, executable lookup, shell capability, process termination semantics, feature availability); S03, S04, S05, S06, and S07 route all Windows-specific gating and lookups through it instead of adding ad hoc `Platform.isWindows` checks.

### From `plan.json` – sharedDecision "Unsupported-capability error contract"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: ad8e7b9 -->
> S01 defines the structured unsupported-feature/lookup-failure error shape (names the capability, includes attempted context, points at remediation); S04's POSIX-only signal-reload message, S05's container-isolation rejection, and S06's missing-bash step failure all use it.

### From `plan.json` – sharedDecision "Windows config reload mechanism"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: ad8e7b9 -->
> S04 selects and documents the supported per-platform reload mechanism (existing file-watch trigger is the leading candidate for Windows; SIGUSR1 stays POSIX-only); S09's smoke coverage and S10's documentation name the same mechanism.


## Deeper Context

- `apps/dartclaw_cli/lib/src/commands/reload_trigger_service.dart#ReloadTriggerService` – the existing trigger to modify; `start()` currently gates SIGUSR1 with a raw `!Platform.isWindows` check and skips it silently on Windows.
- `apps/dartclaw_cli/lib/src/commands/serve_command.dart` – reload trigger construction/wiring (around the `ReloadTriggerService(...)` / `reloadTrigger.start()` block); the capability surface is injected here.
- `packages/dartclaw_config/lib/src/gateway_config.dart#ReloadConfig` – `mode` (`signal`/`auto`/`off`, default `signal`) + `debounceMs`; dartdoc names the per-platform supported mechanism.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI02] Windows-supported file-watch reload applies changes without restart**
  - **Given** a running server started with `gateway.reload.mode: auto`, exercising the file-watch trigger (the signal-independent path that is the Windows-supported mechanism)
  - **When** the config file is atomically rewritten with a valid reloadable change
  - **Then** `ConfigNotifier.reload` is invoked and the changed section is applied to the live process without a restart, and the trigger reports the reload with the changed keys

- [x] **S02 [OC02] [TI01] Signal reload requested where unsupported reports POSIX-only via the capability surface**
  - **Given** a `ReloadTriggerService` whose injected platform capability surface reports `posixSignalsAvailable` false (the Windows case) and `mode: signal`
  - **When** `start()` runs
  - **Then** no SIGUSR1 handler is registered, and a structured unsupported-capability message is emitted that names the capability (signal-based config reload), states the attempted context, and points at the file-watch (`auto`) remediation — not a silent skip

- [x] **S03 [OC03] [TI01] POSIX SIGUSR1 still triggers reload**
  - **Given** a live server on a POSIX host with the default `mode: signal`
  - **When** the process receives `SIGUSR1`
  - **Then** a config reload cycle runs (existing behavior), proving the signal path is unchanged

- [x] **S04 [OC04] [TI03] Invalid reload keeps the previous valid config active**
  - **Given** a running server with a valid loaded config
  - **When** a reload fires against a config file that now fails to load or validate
  - **Then** the previous valid config stays active, a validation/load failure is logged, and the process does not crash

- [x] **S05 [OC02] [TI01] `off` mode on an unsupported-signal platform stays silent**
  - **Given** a `ReloadTriggerService` whose capability surface reports `posixSignalsAvailable` false and `mode: off`
  - **When** `start()` runs
  - **Then** no triggers are registered and no unsupported-capability message is emitted (an explicit opt-out is not a failed signal request)


## Structural Criteria

- [x] Signal-reload gating in `reload_trigger_service.dart` routes through the S01 platform capability surface's `posixSignalsAvailable` member; no `Platform.isWindows` check remains in that file's signal path.
- [x] The POSIX-only report is built from S01's structured unsupported-capability contract, not an ad hoc inline string.
- [x] `ReloadConfig` (and/or `ReloadTriggerService`) dartdoc names the per-platform supported mechanism: SIGUSR1 = POSIX-only, file-watch (`auto`) = all platforms including Windows.
- [x] The existing POSIX SIGUSR1 integration test remains present and green (binding constraint: SIGUSR1 available and regression-tested).


## Scope & Boundaries

### Work Areas
- `apps/dartclaw_cli/lib/src/commands/reload_trigger_service.dart` – capability-gated signal registration + structured POSIX-only report.
- `apps/dartclaw_cli/lib/src/commands/serve_command.dart` – inject the S01 capability surface into the trigger.
- `packages/dartclaw_config/lib/src/gateway_config.dart` – `ReloadConfig` dartdoc names the per-platform mechanism.
- `apps/dartclaw_cli/test/commands/` – capability-gated message test, `off`-mode silence test, invalid-reload regression, existing file-watch and SIGUSR1 tests.

### What We're NOT Doing
- No new reload UI surface -- explicitly excluded by the story scope.
- No per-platform change to the default reload mode -- Windows keeps `signal` as the default and reports + recommends `auto`; silently switching defaults is an unrequested behavior change and risks the POSIX-preservation constraint.
- No user-guide / capability-matrix documentation -- S10 owns the Windows doc gate; S04 selects the mechanism and documents it at the dartdoc/config level only.
- No new file-watch or authenticated-endpoint mechanism -- the existing directory-watch trigger is already cross-platform and handles atomic writes; the story validates/promotes it (per the plan note), it does not reinvent it.
- Not implementing the platform capability surface itself -- S01 owns it; S04 consumes the pre-resolved interface.


## Architecture Decision

**Approach**: Adopt the existing cross-platform file-watch trigger (`auto` mode) as Windows' supported reload path; gate SIGUSR1 registration on S01's `posixSignalsAvailable` member instead of `!Platform.isWindows`, and when signal reload is requested on a platform lacking it, emit S01's structured unsupported-capability message pointing at `auto`/file-watch rather than skipping silently.
**Why this over alternatives**: Preserves POSIX SIGUSR1 (binding constraint) and avoids inventing a Windows IPC endpoint; the directory-watch path already handles atomic writes on all three OSes.


## Constraints & Gotchas

- **Constraint**: ADR-049 pins `posixSignalsAvailable` and `UnsupportedCapabilityError`; use those exact S01 symbols and do not invent parallel types.
- **Avoid**: Reintroducing a raw `Platform.isWindows` branch for the signal gate -- Instead: query the capability surface's `posixSignalsAvailable` member.
- **Assumption (AUTO_MODE)**: The Windows default reload mode stays `signal`; the POSIX-only report fires at `start()` and recommends `auto`. Conservative choice: no default change, honest reporting, no new config keys.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** Signal-reload registration is capability-gated and reports POSIX-only when unavailable
  - `ReloadTriggerService.start()` registers SIGUSR1 only when injected `PlatformCapabilities.posixSignalsAvailable` is true; when false and `mode == 'signal'`, it constructs `UnsupportedCapabilityError` naming "signal-based config reload", attempted mode/context, and S04-owned `auto`/file-watch remediation. `mode == 'off'` emits nothing.
  - **Verify**: `Test: fake capability surface reporting posixSignalsAvailable false + mode 'signal' → no SIGUSR1 subscription created and a message naming "signal" reload plus the "auto" remediation is emitted; false + mode 'off' → no message; true + mode 'signal' → SIGUSR1 subscription created. Plus: reload_trigger_service_sigusr1_test.dart still passes on POSIX (SIGUSR1 triggers reload).`

- [x] **TI02** File-watch is the documented Windows-supported reload path
  - `auto` mode registers the directory file-watch regardless of signal availability (unchanged mechanism), and `ReloadConfig`/`ReloadTriggerService` dartdoc names file-watch (`auto`) as the all-platform/Windows path and SIGUSR1 as POSIX-only. Follow existing watch logic in `reload_trigger_service.dart#ReloadTriggerService._startFileWatch`.
  - **Verify**: `Test: file-watch mode applies a valid config change to ConfigNotifier without restart on the current host (reload_trigger_service_test.dart). Grep: dartdoc for ReloadConfig contains "file-watch"/"auto" as the Windows path and "SIGUSR1"/"POSIX" as POSIX-only.`

- [x] **TI03** Invalid reload leaves the previous valid config active
  - `_doReload` continues to catch load/validation failure and keep the existing config (no notifier update, no crash); covered by an explicit regression test. Pattern: `reload_trigger_service.dart#ReloadTriggerService._doReload`.
  - **Verify**: `Test: triggering doReload() with a config loader that throws leaves ConfigNotifier's active config unchanged, logs a reload-failure warning, and does not throw.`

### Testing Strategy
> Leave empty — per-task Verify lines plus the SIGUSR1 integration regression cover the mechanism. The capability surface is injected as a test double so the Windows path is exercised on any host.

### Execution Contract
- Depends on S01's platform capability surface and unsupported-capability error contract (`sharedDecisions`): wire to S01's shipped symbols; if unavailable at execution, treat as a blocking dependency rather than re-implementing.


## Final Validation Checklist
> Standard gates (scenarios, structural criteria, task Verify lines) apply.
