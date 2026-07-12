# FIS: Explicit Container-Isolation Degradation (Windows)

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S05

## Feature Overview and Goal

**Intent**: On native Windows the Docker + Unix-socket credential-proxy isolation stack cannot run safely, so enabling it must fail loudly with an actionable error instead of silently no-op'ing or booting a server that falsely claims agents are isolated.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] On native Windows, requesting container isolation (`container.enabled: true`) is refused at startup with an actionable unsupported-feature error that names the capability and points to POSIX/WSL; the server never reaches a running state that presents isolation as active.
- [OC02] The credential-proxy Unix-socket bind and owner-only permission (`chmod 600`) path never execute on native Windows — no partial isolation, no crash from an unsupported socket/chmod call.
- [OC03] POSIX (macOS/Linux) container-isolation behavior is unchanged: `container.enabled: true` still wires the credential proxy and container managers exactly as before.

## Required Context

> Load-bearing spans inlined from the PRD and the plan's shared decisions (S01 owns the surface/error contract this story consumes).

### From `docs/specs/0.21/prd.md` – "FR9: Explicit Container-Isolation Degradation"
<!-- source: docs/specs/0.21/prd.md#fr9-explicit-container-isolation-degradation -->
<!-- extracted: ad8e7b9 -->
> **Description**: Prevent Windows users from receiving false security signals for Unix-socket credential proxy/container isolation.
>
> **Acceptance Criteria**:
> - Container isolation is marked unavailable on native Windows unless a future Windows-specific isolation design is implemented.
> - Credential proxy Unix-socket and permission paths do not execute unguarded on Windows.
> - Attempts to enable container isolation on Windows return an actionable unsupported-feature error.
>
> **Validation**: Tests cover Windows unavailable behavior and POSIX unaffected behavior.
>
> **Error Handling**: The error names the unsupported capability and points users to POSIX/WSL or future Windows isolation work rather than crashing.

### From `docs/specs/0.21/prd.md` – "Constraints" (isolation has no 1:1 Windows port)
<!-- source: docs/specs/0.21/prd.md#constraints -->
<!-- extracted: ad8e7b9 -->
> Existing Docker credential-proxy isolation depends on Unix sockets and Unix file permissions; it has no safe 1:1 Windows port.

### From `docs/specs/0.21/plan.json` – sharedDecision "Platform capability surface API"
<!-- source: docs/specs/0.21/plan.json#sharedDecisions -->
<!-- extracted: ad8e7b9 -->
> S01 defines the single documented capability surface (home-directory resolution, executable lookup, shell capability, process termination semantics, feature availability); S03, S04, S05, S06, and S07 route all Windows-specific gating and lookups through it instead of adding ad hoc `Platform.isWindows` checks.

### From `docs/specs/0.21/plan.json` – sharedDecision "Unsupported-capability error contract"
<!-- source: docs/specs/0.21/plan.json#sharedDecisions -->
<!-- extracted: ad8e7b9 -->
> S01 defines the structured unsupported-feature/lookup-failure error shape (names the capability, includes attempted context, points at remediation); S04's POSIX-only signal-reload message, S05's container-isolation rejection, and S06's missing-bash step failure all use it.

## Deeper Context

- `docs/research/windows-cross-platform-support/research.md#5-container-isolation-on-windows-defer` – why isolation is deferred: `AF_UNIX` on Windows only in Dart 3.11 (unreleased), `chmod 600` has no NTFS equivalent, TCP-to-daemon disables TLS by default. Establishes "mark unavailable with a clear error" as the sanctioned outcome.

## Acceptance Scenarios

- [x] **S01 [OC01] [TI01,TI02] Windows startup refuses isolation with an actionable, capability-named error**
  - **Given** native Windows and a config with `container.enabled: true`
  - **When** security wiring runs during `dartclaw serve` startup
  - **Then** startup is aborted via the existing severe-log-then-exit path, and the emitted error names container isolation as the unsupported capability and directs the user to POSIX or WSL (not a generic crash or stack trace)

- [x] **S02 [OC02] [TI01] Credential-proxy Unix-socket/chmod path is never reached on Windows**
  - **Given** native Windows and `container.enabled: true`
  - **When** security wiring processes the isolation request
  - **Then** `CredentialProxy.start` is never invoked — no `proxy.sock` file is created under the data dir and no owner-only chmod is attempted — and no `ContainerManager` is constructed

- [x] **S03 [OC03] [TI01] POSIX isolation wiring is unchanged**
  - **Given** a POSIX host (macOS/Linux) and `container.enabled: true`
  - **When** security wiring runs
  - **Then** the availability gate permits the existing `_wireContainers` path, whose unchanged credential-proxy and container-manager component tests remain green

- [x] **S04 [OC01] [TI02] Windows without isolation starts normally (no false rejection)**
  - **Given** native Windows and a config with `container.enabled: false`
  - **When** `dartclaw serve` starts
  - **Then** startup completes normally with no unsupported-feature error, and the disabled-isolation warning states that the agent has full host access and that native-Windows isolation is unavailable, pointing to POSIX/WSL without telling the user to enable an unavailable feature

## Structural Criteria

> Each proved by a task Verify line, not a scenario.

- [x] The Windows isolation gate queries ADR-049's `containerIsolationAvailable` member rather than adding an inline `Platform.isWindows` branch in `security_wiring.dart` (US07 / FR1 alignment).
- [x] The Windows rejection is raised using S01's structured unsupported-capability error type (the shared "Unsupported-capability error contract"), not a bespoke local string.
- [x] Existing container/credential-proxy tests (`packages/dartclaw_server/test/container/*`) remain green — no change to `credential_proxy.dart`, `container_manager.dart`, or the POSIX wiring path.

## Scope & Boundaries

### Work Areas
- `apps/dartclaw_cli/lib/src/commands/wiring/security_wiring.dart#SecurityWiring.wire` — the sole runtime entry point that gates container isolation (`if (config.container.enabled) _wireContainers()`); the Windows unavailable-check lands here, ahead of `_wireContainers`.
- `apps/dartclaw_cli/lib/src/commands/service_wiring.dart#ServiceWiring._wireSecurity` — the composition root that constructs `SecurityWiring`; add the S01 capability surface as a new `SecurityWiring` constructor argument and pass it here (mirroring how S04 injects the surface at `serve_command.dart`), defaulting to the real `Platform`-backed surface so production wiring is unchanged.
- S01 platform capability surface (consumed) — container-isolation feature-availability query + structured unsupported-capability error type; exact symbols delivered by S01.
- `apps/dartclaw_cli/test/commands/wiring/` — new Windows-unavailable and POSIX-unaffected coverage for `SecurityWiring` (alongside existing `security_wiring_*_test.dart`).

### What We're NOT Doing
- No change to `credential_proxy.dart` / `container_manager.dart` internals — gating the single construction site (`_wireContainers`) fully prevents the Unix-socket/chmod path from executing, so guarding each call would be redundant.
- No Windows-native isolation redesign (TCP-loopback proxy, token auth, NTFS ACLs) — explicitly deferred to a separate future effort per the research conclusion; 0.21 only marks the feature unavailable.
- No new config surface or UI to toggle Windows isolation — the existing `container.enabled` flag plus the capability surface is the whole contract.
- No change to POSIX SIGUSR1 reload or bash-step degradation — those are S04 and S06; this story shares only S01's error contract with them.

## Architecture Decision

**Approach**: Fail-closed gate at the isolation entry point in `SecurityWiring.wire`: before `_wireContainers` runs, query ADR-049's `containerIsolationAvailable` member; when isolation is requested but unavailable, emit S01's structured unsupported-capability error and abort startup via the existing `ExitFn(1)` severe-log-then-exit pattern already used inside `_wireContainers`.
**Why this over alternatives**: gating the one construction site is simpler and strictly safer than sprinkling `Platform.isWindows` guards through `credential_proxy.dart`/`container_manager.dart`, and reusing S01's error type keeps the unsupported-feature message shape consistent with S04 and S06.

## Code Patterns & External References

```
# type | path#anchor                                                                  | why needed (intent)
file   | apps/dartclaw_cli/lib/src/commands/wiring/security_wiring.dart#SecurityWiring.wire | Gate site: add the unavailable-check ahead of the existing container.enabled branch
file   | apps/dartclaw_cli/lib/src/commands/wiring/security_wiring.dart#SecurityWiring._wireContainers | Existing severe-log-then-`_exitFn(1)` pattern to mirror for the Windows rejection
file   | packages/dartclaw_server/lib/src/container/credential_proxy.dart#CredentialProxy.start | The Unix-socket bind + `chmodOwnerOnly` path that must remain unreached on Windows
file   | apps/dartclaw_cli/test/commands/wiring/security_wiring_seam_integration_test.dart | Pattern for exercising SecurityWiring with an injected ExitFn/config
```

## Constraints & Gotchas

- **Constraint**: `SecurityWiring` calls `_exitFn(1)` (from `serve_command.dart#ExitFn`) to abort, not `exit()` directly — the Windows rejection must use the injected `_exitFn` so tests can assert the abort without killing the test process.
- **Avoid**: adding a raw `Platform.isWindows` branch in `security_wiring.dart` — Instead: route the availability decision through the S01 capability surface (US07 forbids new ad hoc platform checks in touched areas).
- **Critical**: the failure mode being prevented is a *false security claim*, not a crash — Must handle by: refusing to start (fail-closed) rather than logging a warning and continuing with isolation silently disabled.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** Native Windows never constructs the credential proxy or container managers when isolation is requested
  - Supply `PlatformCapabilities` as a new `SecurityWiring` constructor parameter, wired at `service_wiring.dart#ServiceWiring._wireSecurity` (defaulting to the real Platform-backed value). In `SecurityWiring.wire`, gate `config.container.enabled` on `containerIsolationAvailable`; when unavailable, do not enter `_wireContainers`. POSIX path unchanged.
  - **Verify**: `Test: wire() on a SecurityWiring constructed with a simulated Windows/unavailable capability and container.enabled: true creates no proxy.sock file, leaves containerManagers empty, and credentialProxy is null; inspection confirms the available branch still calls the unchanged _wireContainers method, and the existing credential-proxy/container-manager component tests remain green without requiring live Docker, credentials, or host sockets`

- [x] **TI02** Requesting unavailable isolation aborts startup with the structured unsupported-feature error
  - When isolation is requested but unavailable, emit S01's structured unsupported-capability error (names container isolation, includes attempted context, points to POSIX/WSL) and call the injected `_exitFn(1)`, mirroring the existing severe-log-then-exit pattern in `_wireContainers`. When `container.enabled: false` on Windows, no error is emitted and startup proceeds; replace the impossible generic advice to enable isolation with a platform-aware full-host-access warning that says native-Windows isolation is unavailable and points to POSIX/WSL. See `security_wiring.dart#SecurityWiring._wireContainers` for the exit pattern.
  - **Verify**: `Tests: unavailable capability + container.enabled: true calls exitFn(1) once and the emitted message names container isolation and references POSIX/WSL; container.enabled: false calls exitFn zero times, completes wiring, and emits a full-host-access warning that names native-Windows unavailability and does not advise enabling isolation`

### Testing Strategy
> Windows behavior is validated by simulating the capability-surface verdict (isolation unavailable) rather than requiring a real Windows host — the gate depends on the S01 capability value, not on `Platform.isWindows` directly, which keeps these tests runnable on the POSIX CI host. S09 owns real-Windows smoke evidence.

- Inject an unavailable-isolation capability result to drive the Windows path; use the real (available) surface for the POSIX-unaffected assertion.

## Implementation Observations

_No observations recorded yet._
