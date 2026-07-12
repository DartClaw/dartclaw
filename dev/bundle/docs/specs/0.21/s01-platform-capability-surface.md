# Platform Capability Surface — Feature Implementation Specification

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: Give DartClaw one documented place to ask "what can this OS do?" so Windows support is governed by an explicit capability model instead of `Platform.isWindows` checks scattered across the runtime, and so the sibling Windows stories (lifecycle, reload, degradation, harness) share a single home-resolution, lookup, and unsupported-feature contract.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] One immutable `PlatformCapabilities` value reports the accepted ADR-049 contract consistently for Windows and POSIX: nullable home-directory resolution, executable-lookup command data, `BashShellPolicy`, `posixSignalsAvailable`, `ProcessTerminationSemantics`, POSIX file-permission availability, and container-isolation availability.
- [OC02] The Codex environment path resolves its home directory through the shared surface (`HOME` → `USERPROFILE` fallback), so a native-Windows Codex home resolves instead of failing on a missing `HOME`.
- [OC03] Unsupported capabilities and failed lookups raise one structured error that names the capability, includes the attempted context, and points at remediation text the caller supplies — the exact shape S04/S05/S06/S07 reuse. S01 owns the error's structure only; each consumer owns its per-capability remediation string.


## Required Context

> Load-bearing upstream spans inlined verbatim. The inlined text is the contract the executor builds to.

### From `prd.md` – "FR1: Platform Capability Surface"
<!-- source: docs/specs/0.21/prd.md#fr1-platform-capability-surface -->
<!-- extracted: ad8e7b9 -->
> **Description**: Provide a single product/runtime capability surface for OS-dependent behavior: home-directory resolution, executable lookup, shell availability, process termination semantics, file permission capabilities, and feature availability.
>
> **Acceptance Criteria**:
> - Windows-specific behavior for home resolution, executable lookup, shell choice, process lifecycle, and feature availability is exposed through one documented platform capability surface.
> - Direct `HOME` reads in the Codex environment path use the shared home-resolution behavior.
> - New Windows feature gates use this surface instead of adding unrelated `Platform.isWindows` checks.
>
> **Validation**: Windows and POSIX tests cover home-directory fallback, executable lookup, shell capability detection, and unavailable-feature flags.
>
> **Error Handling**: Missing home directory, missing executable, or unavailable shell returns a structured error with the attempted lookup context.

### From `prd.md` – "US07" (User Stories table)
<!-- source: docs/specs/0.21/prd.md#user-stories -->
<!-- extracted: ad8e7b9 -->
> US07 | As a maintainer, I want platform differences centralized so that future non-POSIX work does not add more ad hoc checks. | New Windows-relevant decisions route through a documented platform capability surface; direct home-directory and executable lookup bypasses are removed in touched areas. | Must / P0

### From `plan.json` – shared decisions originating in S01
<!-- source: docs/specs/0.21/plan.json#sharedDecisions -->
<!-- extracted: ad8e7b9 -->
> **Platform capability surface API**: S01 defines the single documented capability surface (home-directory resolution, executable lookup, shell capability, process termination semantics, feature availability); S03, S04, S05, S06, and S07 route all Windows-specific gating and lookups through it instead of adding ad hoc `Platform.isWindows` checks.
>
> **Unsupported-capability error contract**: S01 defines the structured unsupported-feature/lookup-failure error shape (names the capability, includes attempted context, points at remediation); S04's POSIX-only signal-reload message, S05's container-isolation rejection, and S06's missing-bash step failure all use it.


## Deeper Context

- `docs/research/windows-cross-platform-support/research.md#8-codebase-platform-difference-inventory` – the source sweep behind this story: which sites already guard Windows (`expandHome`, init `where`/`which`, oauth chmod) and which bypass (Codex `HOME` reads). Read to confirm a site is a real bypass before routing it through the surface.
- `docs/research/windows-cross-platform-support/research.md#3-process-lifecycle--signals-on-windows` – why the process-termination and signal capability flags exist (S03/S04 consume them); `Process.kill()` ignores its signal arg on Windows.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01] Home resolves on POSIX**
  - **Given** a capability surface constructed with `operatingSystem: 'linux'` and environment `{HOME: '/home/dev'}`
  - **When** the caller requests the home directory
  - **Then** it returns `/home/dev`

- [x] **S02 [OC01] [TI01] Windows home falls back to `USERPROFILE`**
  - **Given** a capability surface constructed with `operatingSystem: 'windows'` and environment `{USERPROFILE: 'C:\\Users\\dev'}` (no `HOME`)
  - **When** the caller requests the home directory
  - **Then** it returns `C:\Users\dev`

- [x] **S03 [OC03] [TI01,TI02,TI03] Missing home is converted to the structured error at the consumer boundary**
  - **Given** a capability surface with neither `HOME` nor `USERPROFILE` set
  - **When** `CodexEnvironment.setup()` requires the nullable `homeDirectory` value
  - **Then** `CodexEnvironment` constructs and throws the structured unsupported-capability error naming the `home directory` capability, listing attempted variables (`HOME`, `USERPROFILE`), and carrying its caller-owned remediation text

- [x] **S04 [OC01] [TI01] Executable-lookup command is OS-correct**
  - **Given** a capability surface for `operatingSystem: 'windows'` and another for `'linux'`
  - **When** each is asked for the executable-lookup command for `dartclaw`
  - **Then** the Windows surface yields `where dartclaw` and the POSIX surface yields `which dartclaw`

- [x] **S05 [OC02] [TI03] Codex home resolves on native Windows via the surface**
  - **Given** `CodexEnvironment(useSystemCodexHome: true)` whose home resolution uses a surface for `operatingSystem: 'windows'` with `{USERPROFILE: 'C:\\Users\\dev'}` and no `HOME`
  - **When** `setup()` runs
  - **Then** it returns `C:\Users\dev\.codex` (the path the surface resolves) instead of throwing on a missing `HOME`

- [x] **S06 [OC03] [TI02] Unsupported feature reports through the shared error shape with caller-supplied remediation**
  - **Given** a capability surface for `operatingSystem: 'windows'` reporting container isolation unavailable
  - **When** a caller builds the unsupported-capability error for that feature, supplying its own remediation text pointing to POSIX/WSL
  - **Then** the error names the `container isolation` capability, carries the attempted context, and surfaces the caller's POSIX/WSL remediation verbatim — the same error type (structure owned by S01, remediation string owned by the caller) that S04/S05/S06 raise


## Structural Criteria

> Proved by task Verify lines, not scenarios.

- [x] Existing `dartclaw_config` and `dartclaw_core` test suites remain green on macOS/Linux — POSIX home resolution, Codex setup, and `expandHome` behavior are unchanged.
- [x] The Codex environment path (`codex_environment.dart`) no longer reads `Platform.environment['HOME']` directly for home resolution; its two direct reads route through the surface.
- [x] `expandHome` continues to resolve `~`/`~/` with `HOME` → `USERPROFILE` fallback (behavior preserved whether or not it delegates to the surface).


## Scope & Boundaries

### Work Areas
- New platform capability surface + injectable OS/environment seam in `dartclaw_config` (`lib/src/platform_capabilities.dart`), exported via the package barrel.
- Structured unsupported-capability error type (same file), covering both lookup-failure and unsupported-feature cases.
- Codex environment home resolution migrated onto the surface (`dartclaw_core/.../codex_environment.dart`).
- Dual-OS unit tests for every capability category and the error shape (`dartclaw_config/test`).

### What We're NOT Doing
- Container-isolation guarding, signal-reload messaging, or bash-step degradation behavior -- those consume this surface in S05/S04/S06; S01 only defines the capability flags and error shape they use.
- Harness executable resolution rewiring -- S07 routes harness binary lookup through the surface; S01 exposes the lookup command but does not change harness spawn code.
- Migrating already-correct guarded sites (`init_command._resolveBinPath` `where`/`which`, oauth-store chmod guards) -- they are not bypasses; leaving them avoids untraceable churn. `_resolveBinPath` is cited only as the reference pattern for the lookup command.
- Process-lifecycle shutdown changes -- S03 owns behavior; S01 only surfaces the termination-semantics capability flag.


## Architecture Decision

**Approach**: Implement ADR-049's flat typed `PlatformCapabilities` value in `dartclaw_config`, with injectable `operatingSystem` and `environment` inputs defaulting to `Platform`. Its named members are `homeDirectory`, `executableLookupCommand`, `bashShellPolicy`, `posixSignalsAvailable`, `processTerminationSemantics`, `posixFilePermissionsAvailable`, and `containerIsolationAvailable`; shell and termination values use the two-value enums fixed by the ADR. Expose one structured error type carrying capability, attempted context, and remediation. The capability value remains pure; consumers execute lookup commands and own remediation wording.
**Why this over alternatives**: The accepted trade-off scored this flat typed value highest for auditability, minimalism, deterministic testing, and exact S03–S07 fit. Registries, OS subclasses, nested category objects, and an effectful platform service add indirection or mix policy with process I/O.


## Code Patterns & External References

```
# type | path#anchor                                                              | why needed (intent)
file   | packages/dartclaw_config/lib/src/path_utils.dart#expandHome              | Home fallback + injectable-env pattern to mirror; HOME→USERPROFILE precedence
file   | packages/dartclaw_config/lib/dartclaw_config.dart                        | Barrel; add the surface + error export here (see existing `path_utils.dart` export line)
file   | packages/dartclaw_core/lib/src/harness/codex_environment.dart#CodexEnvironment | The two direct `Platform.environment['HOME']` reads (setup, _seedFromDefaultCodexHome) to route through the surface
file   | apps/dartclaw_cli/lib/src/commands/init/init_command.dart#_resolveBinPath | Reference only: existing `where`/`which` selection the lookup-command accessor formalizes
file   | packages/dartclaw_core/lib/src/harness/process_lifecycle.dart#killWithEscalation | Reference for the termination-semantics flag: Windows path skips `sigkill`
```


## Constraints & Gotchas

- **Cross-platform tests must not depend on the host OS.** Every capability behavior is proved by constructing the surface with an explicit `operatingSystem`/`environment`; never gate a test on the runner's real platform, or Windows behavior goes unverified on CI.
- **Avoid**: adding a new `Platform.isWindows` branch in a consuming site -- Instead: add/extend a capability accessor on the surface so future stories inherit it (this is the whole point of US07).


## Implementation Plan

### Implementation Tasks

- [x] **TI01** `PlatformCapabilities` implements ADR-049's complete named API and Windows/POSIX truth table from injectable `operatingSystem` + `environment` inputs (default `Platform`).
  - `homeDirectory` preserves `HOME`→`USERPROFILE` and returns null when neither contains a nonblank value. `executableLookupCommand(name)` returns `['where', name]` on Windows and `['which', name]` on POSIX. Windows maps to `BashShellPolicy.gitBashRequired`, `posixSignalsAvailable == false`, `ProcessTerminationSemantics.hardTerminate`, no POSIX file permissions, and unavailable container isolation. POSIX maps to `systemSh`, signals available, `posixSignalEscalation`, POSIX file permissions, and available container isolation.
  - **Verify**: `Test: Linux and Windows fixtures assert every named member and both enum values; lookup command data is correct; missing/blank HOME and USERPROFILE yields null without spawning a process`

- [x] **TI02** A structured unsupported-capability error type carries the capability name, attempted context, and remediation for lookup failures and unsupported features.
  - Single error type (sharedDecision "Unsupported-capability error contract"); `toString()` includes all three fields. Remediation is a required constructor argument supplied by the consumer. `PlatformCapabilities` reports pure values; CodexEnvironment and S04/S05/S06/S07 construct and raise the error at their behavior boundaries.
  - **Verify**: `Test: homeDirectory is null with neither HOME nor USERPROFILE; CodexEnvironment converts that null into the structured error naming 'home directory', listing both variables, and carrying its remediation; container isolation uses the same type with caller-supplied POSIX/WSL remediation`

- [x] **TI03** `CodexEnvironment` resolves its home directory through the surface, retiring the two direct `Platform.environment['HOME']` reads.
  - `setup()` (system-home branch) and `_seedFromDefaultCodexHome` use `homeDirectory`. When it is null, `setup()` constructs `UnsupportedCapabilityError` with Codex-specific remediation instead of the ad hoc `StateError`; `_seedFromDefaultCodexHome` keeps its best-effort behavior and skips seeding silently.
  - **Verify**: `Test: Codex setup with a windows surface and {USERPROFILE:'C:\\Users\\dev'} (no HOME) returns 'C:\\Users\\dev\\.codex'; with neither var set it throws the structured unsupported-capability error, not a bare StateError`

- [x] **TI04** The surface, enums, and error type are exported from `package:dartclaw_config` and covered by category-complete dual-OS unit tests.
  - Add the barrel export next to `path_utils.dart`; add `platform_capabilities_test.dart` covering every ADR-049 member for `operatingSystem` `'windows'` and `'linux'`.
  - **Verify**: `Test: the package barrel resolves PlatformCapabilities, BashShellPolicy, ProcessTerminationSemantics, and UnsupportedCapabilityError; Linux and Windows fixtures assert every member in the ADR truth table`

### Testing Strategy
> Leave empty — per-task Verify lines plus the dual-OS scenario tests are sufficient; the injectable-OS seam is the only non-obvious decision and it is stated in the Architecture Decision.

### Validation
> Leave empty — standard exec-spec build/test/analyze gates apply.

### Execution Contract
> Leave empty — no cross-task ordering beyond the natural TI01→TI03 dependency stated in TI03.


## Final Validation Checklist
> Leave empty — Acceptance Scenarios, Structural Criteria, and task Verify lines are the completion gates.


## Implementation Observations

#### DECISION NOTE: home-error-remediation-ownership

Decision-Key: home-error-remediation-ownership
Altitude: fis-local
Affected surface: PlatformCapabilities.homeDirectory and CodexEnvironment home resolution
Decision: PlatformCapabilities returns a nullable homeDirectory; a consumer that requires it constructs UnsupportedCapabilityError and supplies its remediation text.
Rationale: Keeps the capability value pure and makes consumer-specific remediation ownership explicit, consistent with accepted ADR-049.
Evidence: ADR-049 and the reconciled S01 scenarios and tasks specify nullable home data plus caller-owned error construction.
