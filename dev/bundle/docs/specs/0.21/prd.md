# Product Requirements Document: DartClaw 0.21 – Windows Support & Cross-Platform Hardening

> **Context**: [ROADMAP](../../ROADMAP.md) · [0.21 brief](prd-brief.md)
> **Related Assets**: [Windows cross-platform research](../../research/windows-cross-platform-support/research.md) · [Windows validation spikes](spikes-scoping-brief.md) · [Workflow DSL v2](../0.24/workflow-dsl-v2.md)
>
> **Status**: Final · **Date**: 2026-06-24 · **Prerequisites**: 0.19 planning/active work complete enough to start 0.21. S0a and S0b validation spikes are complete and GO: Windows x64 build + FTS5 works, and native Windows Claude/Codex stdio turns round-trip without parser changes.


## Executive Summary

- **Problem**: DartClaw does not ship a Windows binary, so Windows developers and operators cannot run the core host without WSL or local source builds. The runtime is mostly portable, but build/distribution, SQLite source mode, config reload, process lifecycle, direct home-directory handling, container isolation, and bash workflow steps still expose Unix assumptions.
- **Vision**: Ship a native Windows x64 release that supports DartClaw's core orchestration surface – `dartclaw serve`, Web UI, harness pool, sessions, storage/search, and workflows except unavailable bash steps – with a first-class install path and honest capability messaging for Unix-coupled features.
- **Target Users**: Windows-based developers and single-user operators who want to run DartClaw locally without WSL, plus maintainers who need a repeatable cross-platform release process.
- **Success Metrics**:
  - Tagged release produces `dartclaw-<version>-windows-x64.zip` containing `dartclaw.exe` and a bundled `sqlite3.dll`.
  - Windows smoke validation proves `serve`, Web UI load, FTS5 search, and native Windows turns for both first-class harnesses, Claude and Codex; credential-only CI skips are allowed only with recorded manual evidence for both providers.
  - `install.ps1` and a Scoop manifest install DartClaw so `dartclaw` resolves in a newly opened terminal.
  - Existing macOS/Linux build, packaging, analyzer, and test gates remain green.
  - Attempts to use unavailable Windows features return explicit actionable errors, and the user guide contains a Windows capability/degradation matrix.

### Capabilities at a Glance

- **FR1: Platform Capability Surface** _(Must / P0)_ – Centralize OS-dependent behavior so Windows support is governed by one explicit capability model instead of scattered checks.
- **FR2: Windows-Safe Process Lifecycle** _(Must / P0)_ – Ensure harness and child-process shutdown behavior is predictable on Windows and does not rely on unsupported POSIX signals.
- **FR3: Cross-Platform Config Reload** _(Must / P0)_ – Provide a Windows-compatible reload path while preserving SIGUSR1 behavior on POSIX.
- **FR4: Windows Release Artifact** _(Must / P0)_ – Build and publish a Windows x64 zip from a Windows host with the expected executable and DLL layout.
- **FR5: FTS5-Guaranteed SQLite on Windows** _(Must / P0)_ – Ensure Windows uses bundled SQLite with FTS5 and test the actual loaded module.
- **FR6: Windows Installer and Scoop Manifest** _(Must / P0)_ – Provide one-command PowerShell install and a Scoop manifest with persistent PATH behavior.
- **FR7: Native Windows Harness Validation** _(Must / P0)_ – Validate Claude/Codex spawning through DartClaw on native Windows, including Codex protocol compatibility.
- **FR8: Windows Runtime Smoke Test** _(Must / P0)_ – Maintain a repeatable Windows verification path for core runtime behavior.
- **FR9: Explicit Container-Isolation Degradation** _(Must / P0)_ – Mark container isolation unavailable on Windows with clear errors instead of crashes or false security claims.
- **FR10: Explicit Bash-Step Degradation** _(Must / P0)_ – Run bash workflow steps via Git Bash when available and fail clearly otherwise.
- **FR11: Windows Documentation and Capability Matrix** _(Must / P0)_ – Update user and architecture documentation so Windows support, gaps, and rationale are visible.

### Scope Highlights

- **In scope**: Native Windows x64 binary; Windows CI/release artifact; FTS5-backed bundled SQLite; PowerShell + Scoop install; platform capability surface; Windows-compatible config reload path; native Windows Claude/Codex harness validation; Windows smoke test; explicit degradation for container isolation and bash workflow steps; user guide and architecture documentation.
- **Out of scope**: Windows-native container isolation redesign; PowerShell-first or polyglot workflow script semantics; native Windows harness sandbox parity; first-class channel sidecars on Windows; winget/Chocolatey packages; Windows ARM64 release artifact.
- **MVP boundary**: A Windows user can install via PowerShell, run `dartclaw serve`, open the Web UI, use storage/search with FTS5, reload config through a documented Windows-compatible path, and complete native Windows turns for both Claude and Codex when those providers are configured. Unix-coupled features may be unavailable, but must fail clearly.

### Key Constraints, Assumptions & Dependencies

- **Constraint**: Dart cannot cross-compile Windows executables from macOS/Linux. The Windows artifact must be built on a Windows host.
- **Constraint**: DartClaw search requires FTS5. Windows must not depend on system `winsqlite3.dll`.
- **Constraint**: `Process.kill()` is a hard terminate on Windows, and SIGUSR1/SIGTERM-style reload/shutdown assumptions do not port.
- **Assumption**: Windows x64 is the first supported target. ARM64 remains follow-on even though native Dart and harness stdio were probed successfully on Windows ARM64.
- **Dependency**: Users who want bash workflow steps on Windows need Git Bash unless Workflow DSL v2 later introduces a broader script model.


## Problem Definition

### Problem Statement

DartClaw's distribution and runtime behavior currently make Windows a second-class or unsupported environment. Users on Windows cannot install an official binary, and maintainers have no release job that produces one. Even if users build from source, the current source-mode SQLite configuration can load an unsuitable system DLL, config reload depends on POSIX signals, and Unix-coupled features do not communicate their limits consistently. If this remains unchanged, DartClaw's "single AOT Dart binary" product promise excludes a major developer platform and future platform-specific fixes will keep accumulating as scattered conditionals.

### Evidence & Context

- The S0a spike passed on `windows-latest` x64: `dart build cli` produced a runnable `dartclaw.exe` plus bundled `sqlite3.dll`; the shipped DLL reported `ENABLE_FTS5` and executed an FTS5 query.
- The S0a spike found a real planning risk: `source: system` exists at both workspace-root and CLI-app pubspec levels, and the workspace-root setting can force system loading unless neutralized.
- The S0b spike passed: Dart's line parser tolerates CRLF, and native Windows Claude/Codex real turns emitted LF and completed over stdio.
- The S0b spike found Codex compatibility items that should be regression-tested: app-server `sandboxPolicy.type` casing and forward-compatible unknown notification handling.
- Research confirms the hard Windows-host build constraint, the lack of clean Windows equivalents for Unix-socket credential proxy isolation, and the need to treat bash workflow steps as a Git Bash dependency or deferred design.


## Scope

### In Scope

- Native Windows x64 release artifact built on a Windows runner.
- Windows packaging as zip with `dartclaw.exe` and required DLLs in a loadable layout.
- One-command PowerShell install script and Scoop manifest.
- SQLite configuration and tests that guarantee FTS5 on Windows and avoid accidental `winsqlite3.dll` use.
- A centralized platform capability surface for executable lookup, home-directory resolution, shell capability, process termination semantics, and feature availability.
- Windows-compatible config reload path, while signal reload remains POSIX-only.
- Native Windows harness validation for Claude and Codex through the existing harness pool.
- Windows smoke validation covering server startup, Web UI load, config reload, Claude/Codex harness turns, and FTS5 search.
- Clear degradation for container isolation and bash workflow steps.
- User guide, architecture docs, state/roadmap, and feature-comparison updates required by the repo policy.

### Out of Scope

- Windows-native credential proxy/container isolation redesign using TCP loopback, token auth, Windows ACLs, or named pipes.
- Full cross-platform workflow shell semantics, embedded POSIX interpreter, or PowerShell `script:` support. This belongs with Workflow DSL v2.
- Native Windows sandbox parity for harness providers. Provider-specific sandbox behavior is documented but not solved in DartClaw's layer.
- First-class Signal/WhatsApp sidecar support on Windows.
- winget and Chocolatey distribution.
- Windows ARM64 release asset.

### MVP Boundary

The minimum viable 0.21 release is a supported Windows x64 core runtime: installation works, `dartclaw serve` starts, the Web UI loads, storage/search uses FTS5, config reload works through a Windows-compatible path, and native Windows turns complete for both Claude and Codex when provider credentials are available. Anything Unix-coupled may remain unavailable on Windows only if the product surfaces an explicit message and documentation explains the limitation.


## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As a Windows developer, I want to install DartClaw with one command so that I do not need WSL or a source checkout. | Running the documented PowerShell command installs `dartclaw.exe` and required DLLs, and `dartclaw` resolves in a newly opened terminal. | Must / P0 |
| US02 | As a Windows developer, I want `dartclaw serve` to work so that I can use the Web UI locally. | On native Windows x64, `dartclaw serve` starts, the Web UI loads, and no Windows-specific startup crash occurs. | Must / P0 |
| US03 | As a Windows developer, I want storage and search to work so that memory, knowledge, and task search behave like other platforms. | The Windows runtime loads the bundled SQLite module, reports `ENABLE_FTS5`, and completes an FTS5 search query. | Must / P0 |
| US04 | As a Windows developer, I want to run Claude and Codex turns so that Windows supports DartClaw's first-class harnesses, not just server startup. | Native Windows Claude and Codex harness turns complete through DartClaw without stdio parse or transport errors when each provider is configured. | Must / P0 |
| US05 | As a Windows developer, I want unsupported features to fail clearly so that I know whether to install Git Bash, use POSIX, or wait for a future feature. | Container isolation and unavailable bash steps return explicit actionable errors, not crashes, silent no-ops, or misleading security claims. | Must / P0 |
| US06 | As a maintainer, I want Windows builds in CI so that release assets are reproducible and not built manually. | A tag or release workflow produces a Windows x64 zip with the expected executable/DLL layout and verifies it before publishing. | Must / P0 |
| US07 | As a maintainer, I want platform differences centralized so that future non-POSIX work does not add more ad hoc checks. | New Windows-relevant decisions route through a documented platform capability surface; direct home-directory and executable lookup bypasses are removed in touched areas. | Must / P0 |

### Feature Specifications

#### FR1: Platform Capability Surface
**Description**: Provide a single product/runtime capability surface for OS-dependent behavior: home-directory resolution, executable lookup, shell availability, process termination semantics, file permission capabilities, and feature availability.

**Acceptance Criteria**:
- [ ] Windows-specific behavior for home resolution, executable lookup, shell choice, process lifecycle, and feature availability is exposed through one documented platform capability surface.
- [ ] Direct `HOME` reads in the Codex environment path use the shared home-resolution behavior.
- [ ] New Windows feature gates use this surface instead of adding unrelated `Platform.isWindows` checks.

**Inputs / Outputs**:
- **Inputs**: Current operating system, process environment, configured executable paths, available shell binaries.
- **Outputs**: Stable capability values and path/executable resolution results consumed by runtime services.

**Validation**:
- Windows and POSIX tests cover home-directory fallback, executable lookup, shell capability detection, and unavailable-feature flags.

**Error Handling**:
- Missing home directory, missing executable, or unavailable shell returns a structured error with the attempted lookup context.

**Priority**: Must / P0

#### FR2: Windows-Safe Process Lifecycle
**Description**: Ensure harness and child-process lifecycle behavior is honest on Windows, where POSIX signal semantics do not exist.

**Acceptance Criteria**:
- [ ] Harness-pool shutdown does not rely on SIGTERM/SIGKILL semantics on Windows.
- [ ] Windows hard-terminate behavior is documented in runtime expectations and tests.
- [ ] Child-process cleanup paths avoid orphaning known DartClaw-managed subprocesses during normal shutdown.

**Inputs / Outputs**:
- **Inputs**: Running harness, workflow, or sidecar subprocesses.
- **Outputs**: Completed shutdown, structured failure, or documented hard termination.

**Validation**:
- Windows lifecycle test or smoke evidence proves managed subprocesses are not left running after normal shutdown.

**Error Handling**:
- If a process cannot be terminated or observed after shutdown, DartClaw logs a clear lifecycle warning and does not report graceful shutdown.

**Priority**: Must / P0

#### FR3: Cross-Platform Config Reload
**Description**: Make config reload usable on Windows without breaking POSIX SIGUSR1 reload.

**Acceptance Criteria**:
- [ ] Windows has a supported reload path, such as file-watch or an authenticated local endpoint.
- [ ] Signal-triggered reload clearly reports POSIX-only behavior when invoked or documented on Windows.
- [ ] POSIX SIGUSR1 behavior remains available and regression-tested.
- [ ] Documentation names the supported reload mechanism per platform.

**Inputs / Outputs**:
- **Inputs**: Config file changes or reload trigger.
- **Outputs**: Reloaded configuration, validation error, or explicit POSIX-only message for signal-triggered reload.

**Validation**:
- Reload tests cover successful reload and invalid-config rejection without restart.

**Error Handling**:
- Invalid config reload leaves the previous valid config active and reports validation failures.

**Priority**: Must / P0

#### FR4: Windows Release Artifact
**Description**: Produce a Windows x64 release asset from a Windows host using the build path proven by S0a.

**Acceptance Criteria**:
- [ ] Release workflow builds on `windows-latest` or equivalent Windows x64 host.
- [ ] The workflow uses the build command that runs native build hooks and produces the `build/cli/windows_x64/bundle/{bin,lib}` layout.
- [ ] Published asset is named `dartclaw-<version>-windows-x64.zip` and contains `dartclaw.exe` plus required DLLs.
- [ ] Existing macOS/Linux artifacts and packaging behavior remain unchanged.

**Inputs / Outputs**:
- **Inputs**: Tagged release source, Dart SDK, package configuration.
- **Outputs**: Windows x64 zip release asset.

**Validation**:
- CI runs `dartclaw.exe --help` or equivalent executable smoke against the built bundle before upload.

**Error Handling**:
- Missing executable, missing DLL, or failed smoke prevents artifact publication.

**Priority**: Must / P0

#### FR5: FTS5-Guaranteed SQLite on Windows
**Description**: Ensure the Windows runtime loads bundled SQLite with FTS5, not an accidental system DLL.

**Acceptance Criteria**:
- [ ] Windows build neutralizes `source: system` at every level that can affect the workspace build.
- [ ] Tests assert `ENABLE_FTS5` and verify the loaded module is the bundled SQLite library shipped with the artifact.
- [ ] FTS5 virtual table creation and MATCH query succeed in Windows verification.

**Inputs / Outputs**:
- **Inputs**: SQLite build-hook configuration and runtime library search path.
- **Outputs**: Loaded FTS5-capable SQLite module and working search.

**Validation**:
- Windows CI or smoke test fails if the runtime loads `winsqlite3.dll` or any non-bundled module for the release artifact.

**Error Handling**:
- Missing FTS5 fails fast with a clear storage/search initialization error that identifies the loaded module.

**Priority**: Must / P0

#### FR6: Windows Installer and Scoop Manifest
**Description**: Provide first-class installation paths for Windows users.

**Acceptance Criteria**:
- [ ] `install.ps1` downloads the Windows x64 zip, installs `dartclaw.exe` and DLLs together, and records a persistent user PATH entry.
- [ ] A newly opened terminal resolves `dartclaw`.
- [ ] Scoop manifest installs the same release asset and exposes `dartclaw`.
- [ ] Installer handles existing installs, upgrades, and unsupported architecture with clear messages.

**Inputs / Outputs**:
- **Inputs**: Release version, target install directory, user PATH.
- **Outputs**: Installed executable/DLLs and persistent PATH update.

**Validation**:
- Installer test or manual evidence covers first install, upgrade, and new-terminal PATH resolution.

**Error Handling**:
- Download failure, checksum mismatch, unsupported architecture, or PATH write failure produces an actionable error and does not leave a partial active install.

**Priority**: Must / P0

#### FR7: Native Windows Harness Validation
**Description**: Validate DartClaw's Claude and Codex harness paths on native Windows, incorporating S0b findings into regression coverage.

**Acceptance Criteria**:
- [ ] Claude completes a full DartClaw-managed prompt/response turn on native Windows when configured.
- [ ] Codex completes a full DartClaw-managed prompt/response turn on native Windows when configured.
- [ ] Claude JSONL and Codex JSON-RPC line parsing remains tolerant of CRLF even though providers emitted LF in S0b.
- [ ] Codex app-server protocol compatibility covers `sandboxPolicy.type` camelCase values and ignores unknown notification methods without crashing.
- [ ] Codex Windows project-trust warnings are captured and surfaced so users know when project-local `.codex` config, hooks, or exec policy are disabled.
- [ ] Windows executable resolution for harness binaries uses the platform capability surface.

**Inputs / Outputs**:
- **Inputs**: Configured Claude/Codex binaries and provider credentials.
- **Outputs**: Completed harness turn or structured provider/auth/setup error.

**Validation**:
- Windows smoke or integration evidence records provider versions, OS/arch, artifact or source under test, and both turn results. CI may skip provider-auth portions only when the skip is explicit and a manual verification profile covers the same checks for both providers.

**Error Handling**:
- Missing binary, auth-required state, protocol mismatch, Codex project-trust warning, or MCP sidecar startup warning is surfaced as setup/compatibility information without corrupting the turn state.

**Priority**: Must / P0

#### FR8: Windows Runtime Smoke Test
**Description**: Maintain a repeatable Windows verification path for the supported core runtime.

**Acceptance Criteria**:
- [ ] Smoke validation covers server startup, Web UI load, FTS5 search, Windows-compatible config reload, and Claude/Codex harness turns.
- [ ] The smoke path is runnable in CI when credentials are available or documented as a manual profile when credentials/hardware make CI impractical.
- [ ] Smoke output records enough evidence to diagnose Windows-only failures.

**Inputs / Outputs**:
- **Inputs**: Windows artifact or source build, test config, optional provider credentials.
- **Outputs**: Pass/fail report with server, UI, storage, reload, and harness results.

**Validation**:
- Release readiness requires the Windows smoke path to pass. Credential-only CI skips are acceptable only when recorded manual evidence covers the same provider checks for both Claude and Codex, including OS/arch, provider versions, artifact or source under test, and turn results.

**Error Handling**:
- Partial smoke failures identify the failed layer and do not report the platform as supported.

**Priority**: Must / P0

#### FR9: Explicit Container-Isolation Degradation
**Description**: Prevent Windows users from receiving false security signals for Unix-socket credential proxy/container isolation.

**Acceptance Criteria**:
- [ ] Container isolation is marked unavailable on native Windows unless a future Windows-specific isolation design is implemented.
- [ ] Credential proxy Unix-socket and permission paths do not execute unguarded on Windows.
- [ ] Attempts to enable container isolation on Windows return an actionable unsupported-feature error.

**Inputs / Outputs**:
- **Inputs**: Runtime security/isolation configuration on Windows.
- **Outputs**: Explicit unsupported error or disabled capability state.

**Validation**:
- Tests cover Windows unavailable behavior and POSIX unaffected behavior.

**Error Handling**:
- The error names the unsupported capability and points users to POSIX/WSL or future Windows isolation work rather than crashing.

**Priority**: Must / P0

#### FR10: Explicit Bash-Step Degradation
**Description**: Make workflow bash-step behavior on Windows predictable.

**Acceptance Criteria**:
- [ ] If Git Bash's `bash.exe` is available, bash steps can run through it with documented expectations.
- [ ] If bash is unavailable, bash workflow steps fail with a clear message: bash steps require Git Bash on Windows.
- [ ] Full cross-platform script semantics remain deferred to Workflow DSL v2.

**Inputs / Outputs**:
- **Inputs**: Workflow step requiring bash, detected shell capabilities.
- **Outputs**: Step execution through bash or structured unsupported error.

**Validation**:
- Tests cover Windows with Git Bash detected, Windows without bash, and existing POSIX behavior. Git Bash qualification covers version capture, cwd, environment propagation, path handling, and basic POSIX command execution.

**Error Handling**:
- Missing bash fails the step explicitly and preserves workflow error reporting; it never returns an empty success result.

**Priority**: Must / P0

#### FR11: Windows Documentation and Capability Matrix
**Description**: Keep user, architecture, and planning documents synchronized with the supported Windows contract.

**Acceptance Criteria**:
- [ ] User guide documents Windows install, upgrade, smoke validation, provider setup caveats, and capability/degradation matrix.
- [ ] User guide documents Codex project-trust setup on Windows and explains warnings when project-local `.codex` config, hooks, or exec policy are disabled.
- [ ] Architecture docs describe the platform capability surface and Windows-specific process/storage constraints where relevant.
- [ ] Public and private roadmap summaries agree that Windows support is 0.21, Workflow DSL v2 is 0.24, and Dynamic Workflows is 0.25.
- [ ] Workflow DSL v2 planning docs treat 0.21's Git Bash behavior as the Windows baseline and scope later `script:` work to polyglot runtime declarations, capability warnings, and any additional shell portability decisions.
- [ ] `STATE.md`, `ROADMAP.md`, and `feature-comparison.md` are updated at milestone completion.
- [ ] Any ADR needed for the platform capability surface or Windows isolation deferral is added or updated.

**Inputs / Outputs**:
- **Inputs**: Implemented Windows behavior and known degradation decisions.
- **Outputs**: Public and private documentation aligned with shipped behavior.

**Validation**:
- Documentation review confirms no page claims unsupported Windows parity for container isolation, bash steps, channel sidecars, or provider sandboxing.

**Error Handling**:
- If a feature remains unverified on Windows, docs label it unverified or unavailable rather than omitting the limitation.

**Priority**: Must / P0

### User Flows

1. **Install and run**: User opens PowerShell, runs the documented install command, opens a new terminal, runs `dartclaw --version`, then starts `dartclaw serve`.
2. **Use core runtime**: User opens the Web UI, starts a chat/task with Claude or Codex, receives a harness response, reloads config through the documented Windows path, and can search persisted records backed by FTS5.
3. **Recover from unsupported feature**: User enables container isolation or runs a bash step without Git Bash, receives an explicit Windows limitation message, and can either install Git Bash, change config, use POSIX/WSL, or defer that feature.
4. **Maintainer release**: Maintainer tags a release, CI builds macOS/Linux/Windows assets, verifies Windows executable/DLL/FTS5 layout, and publishes the zip.

### UI Wireframes

- No new primary UI surface is required. Existing Web UI must load and remain usable on Windows.

### Data Requirements

- Windows release asset metadata: version, OS, architecture, zip filename, checksums, executable path, DLL path.
- Smoke evidence: OS/arch, Dart SDK version, DartClaw version, provider versions when harness validation runs, SQLite module path, FTS5 result, config reload result, server/Web UI result.
- Capability matrix entries: supported, degraded, unavailable, unverified, and remediation text.


## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Compatibility | Windows target | Windows x64 release artifact built on Windows runner; ARM64 explicitly out of scope. |
| Portability | POSIX behavior | Existing macOS/Linux build, packaging, analyzer, and tests remain green. |
| Storage | FTS5 availability | `PRAGMA compile_options;` includes `ENABLE_FTS5`, loaded module is bundled SQLite, and MATCH query succeeds. |
| Reliability | Smoke coverage | Server startup, Web UI load, FTS5 search, config reload, and Claude/Codex harness turns verified before support claim. |
| Security | Degraded security features | Container isolation unavailable on Windows unless explicitly redesigned; no false claims of equivalent isolation. |
| Usability | Installer PATH behavior | `dartclaw` resolves in a newly opened terminal after install. |
| Maintainability | Platform checks | New Windows behavior routes through the platform capability surface unless a localized exception is documented. |
| Observability | Failure diagnosis | Windows build/smoke failures identify failed layer: build, package, DLL/FTS5, server, UI, harness, installer, or unsupported feature. |


## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|----------|-------------------|---------------|
| Windows build accidentally uses system SQLite | Build or smoke fails before publication, identifying loaded module and missing/incorrect FTS5 state. | Fix source-mode override and rerun Windows build. |
| `sqlite3.dll` missing from zip or wrong directory | Artifact validation fails before upload. | Repackage bundle with DLL adjacent/locatable according to runtime loader expectations. |
| Existing install directory contains older DLL | Installer replaces the executable and required DLLs atomically or aborts before activating partial install. | User reruns installer after cleanup guidance. |
| User PATH write fails | Installer reports PATH failure and leaves executable installed at a named path. | User adds path manually or reruns with corrected permissions. |
| Claude/Codex binary missing on Windows | Harness setup reports missing binary with install guidance. | User installs/configures provider binary and retries. |
| Provider authenticated in shell but unavailable to service process | Harness setup reports auth/config context failure. | User configures provider credentials for the process environment. |
| Codex app-server protocol drifts | Compatibility test fails or runtime reports protocol mismatch rather than silently corrupting turn state. | Update adapter compatibility and document supported Codex version range. |
| Codex project folder is untrusted on Windows | Harness setup or turn evidence surfaces the Codex warning that project-local `.codex` config, hooks, or exec policy are disabled. | User adds the project as trusted in `~/.codex/config.toml` when project-local Codex behavior is required. |
| Git Bash not installed | Bash step fails explicitly with remediation. | Install Git Bash, run on POSIX/WSL, or wait for Workflow DSL v2 script support. |
| Container isolation enabled on Windows | Startup/config validation or task launch rejects with unsupported-feature error. | Disable isolation for native Windows or run on POSIX/WSL. |
| Signal reload trigger used on Windows | CLI/server reports that signal-triggered reload is POSIX-only and names the supported Windows reload path. | Use the documented Windows reload path. |


## Constraints & Assumptions

### Constraints

- Windows artifacts must be built on Windows hosts; no macOS/Linux cross-compilation path is available.
- Windows first release targets x64 only.
- Search requires FTS5, so Windows cannot depend on system `winsqlite3.dll`.
- POSIX signal semantics do not exist on Windows for DartClaw's reload/shutdown assumptions.
- Existing Docker credential-proxy isolation depends on Unix sockets and Unix file permissions; it has no safe 1:1 Windows port.
- Bash workflow semantics are deferred to Workflow DSL v2 except for Git Bash detection/degradation.
- Private repo commits/pushes are not automatic; this PRD is a local artifact unless the user explicitly requests git actions.

### Assumptions

- Native Windows Claude and Codex support remains available at implementation time; if provider install surfaces change, the harness validation story updates docs/tests rather than expanding milestone scope.
- The Windows capability target is core orchestration, not full feature parity with POSIX.
- Windows users accepting native mode may accept container isolation being unavailable if the product states that clearly.
- CI credentials for real provider turns may be unavailable; a documented manual smoke profile is acceptable for provider-auth portions only when it verifies both first-class harnesses.

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| GitHub Actions Windows runner or equivalent | Required to build and verify Windows x64 artifact. |
| `package:sqlite3` build hook behavior | Provides bundled SQLite DLL with FTS5. |
| Native Windows Claude/Codex binaries | Required for native harness validation. |
| Git Bash | Optional dependency for bash workflow steps on native Windows. |
| Public user guide and architecture docs | Required to avoid unsupported parity claims. |
| Workflow DSL v2 | Owns future cross-platform script semantics beyond Git Bash fallback. |


## Decisions Log

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| Ship Windows x64 core runtime first. | S0a/S0b prove the core path is viable; x64 matches the release runner and lowest-risk distribution target. | Wait for ARM64 too; require WSL; defer Windows entirely. |
| Do not chase feature parity for Unix-coupled features in 0.21. | Container isolation and bash semantics require separate designs; forcing them into the first Windows release risks false security claims and scope creep. | Redesign credential proxy now; implement PowerShell workflow steps now. |
| Use bundled SQLite on Windows. | FTS5 is required and system `winsqlite3.dll` is unreliable. | Use `source: system`; compile SQLite from source on the runner. |
| Provide PowerShell install plus Scoop first. | Covers one-command install and a package-manager path with manageable maintenance. | Add winget/Chocolatey immediately. |
| Treat config reload as cross-platform capability, not signal-only behavior. | SIGUSR1 cannot work on Windows; users need a real reload path while signal reload stays POSIX-only. | Attempt signal emulation; require restart for Windows config changes. |
| Keep Workflow DSL v2 as the home for broader script portability. | Script semantics affect workflow design beyond Windows support. | Add PowerShell/cmd semantics to bash steps in 0.21. |
