# Windows Runtime Smoke Test

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S09

## Feature Overview and Goal

**Intent**: Maintainers have no repeatable way to prove that the supported Windows core runtime actually works end-to-end, so a Windows release can be tagged on faith; a layered smoke path that gates release readiness turns "Windows is supported" into evidence instead of a claim, and localizes any Windows-only regression to a single layer.

**Expected Outcomes** (user-/business-observable success conditions):

- [OC01] A repeatable Windows smoke path exercises server startup, Web UI load, FTS5 search, file-watch (`auto`) config reload, and Claude + Codex harness turns against the Windows x64 artifact (or an equivalent source build), producing `pass`, `fail`, or `skipped` per layer and an overall `supported`, `incomplete`, or `failed` verdict.
- [OC02] The smoke path runs in CI when provider credentials are available and, when they are not, a documented manual profile records equivalent evidence for both Claude and Codex — OS/arch, provider versions, artifact or source under test, and turn results — so a credential-only CI skip without that recorded manual evidence does not satisfy release readiness.
- [OC03] Smoke evidence carries enough per-layer detail (environment metadata plus each layer's outcome) to diagnose a Windows-only failure by layer.
- [OC04] Any executed-layer failure names the failed layer and yields `failed`; an uncovered required skip yields `incomplete`; neither state is release-ready or reports Windows as supported.


## Required Context

### From `docs/specs/0.21/prd.md` – "FR8: Windows Runtime Smoke Test" (acceptance + validation + error handling)
<!-- source: docs/specs/0.21/prd.md#fr8-windows-runtime-smoke-test -->
<!-- extracted: ad8e7b9 -->
> **Acceptance Criteria**:
> - Smoke validation covers server startup, Web UI load, FTS5 search, Windows-compatible config reload, and Claude/Codex harness turns.
> - The smoke path is runnable in CI when credentials are available or documented as a manual profile when credentials/hardware make CI impractical.
> - Smoke output records enough evidence to diagnose Windows-only failures.
>
> **Inputs / Outputs**: Inputs: Windows artifact or source build, test config, optional provider credentials. Outputs: Pass/fail report with server, UI, storage, reload, and harness results.
>
> **Error Handling**: Partial smoke failures identify the failed layer and do not report the platform as supported.

### Binding Constraint (FR8) – recorded-manual-evidence rule (verbatim)
<!-- source: docs/specs/0.21/prd.md#fr8-windows-runtime-smoke-test -->
<!-- extracted: ad8e7b9 -->
> Release readiness requires the Windows smoke path to pass. Credential-only CI skips are acceptable only when recorded manual evidence covers the same provider checks for both Claude and Codex, including OS/arch, provider versions, artifact or source under test, and turn results.

### From `docs/specs/0.21/prd.md` – US02 (server-startup acceptance)
<!-- source: docs/specs/0.21/prd.md#user-stories -->
<!-- extracted: ad8e7b9 -->
> US02: As a Windows developer, I want `dartclaw serve` to work so that I can use the Web UI locally. Acceptance: On native Windows x64, `dartclaw serve` starts, the Web UI loads, and no Windows-specific startup crash occurs.

### From `docs/specs/0.21/plan.json` – sharedDecision "Windows config reload mechanism"
<!-- source: docs/specs/0.21/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-05 -->
> S04 selects and documents the supported per-platform reload mechanism (existing file-watch trigger is the leading candidate for Windows; SIGUSR1 stays POSIX-only); S09's smoke coverage and S10's documentation name the same mechanism.

### From `docs/specs/0.21/plan.json` – sharedDecision "Windows artifact naming and bundle layout"
<!-- source: docs/specs/0.21/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-05 -->
> S02 fixes the release asset name `dartclaw-v<version>-windows-x64.zip` ... and the `build/cli/windows_x64/bundle/{bin,lib}` executable/DLL layout; S08's installer and Scoop manifest and S09's smoke path consume that exact contract.


## Deeper Context

- `docs/specs/0.21/prd.md#fr7-native-windows-harness-validation` – the harness-turn behavior the smoke path drives (full DartClaw-managed Claude/Codex turns over stdio); evidence fields overlap FR7's validation record.
- `docs/specs/0.21/s04-cross-platform-config-reload.md#acceptance-scenarios` – the file-watch (`auto`) reload contract the smoke reload layer exercises (S1 there is the applied-without-restart proof).
- `../dartclaw-public/dev/adrs/047-embedded-binary-assets.md` and `048-release-builds-dart-build-bundled-sqlite.md` – accepted artifact contract: built-in text assets are embedded; the archive carries `VERSION`, `bin/`, and `lib/` only.
- `dev/testing/README.md#profile-quick-reference` – existing testing-profile convention (per-profile `run.sh` + seeded data + `dev/tools/release_check.sh` manual gates) the smoke path extends rather than replaces.
- `dev/testing/scenarios/README.md` – AI-native scenario format + evidence layout, for the manual smoke profile's structure.


## Acceptance Scenarios

- [ ] **S01 [OC01,OC03] Full Windows smoke run reports every layer green with providers configured**
  - **Given** the built `dartclaw-v<version>-windows-x64.zip` artifact (or an equivalent source build) on a native Windows x64 host with Claude and Codex credentials available
  - **When** the Windows smoke path runs end-to-end
  - **Then** it produces a report with a per-layer result for server startup, Web UI load, FTS5 search, config reload, Claude turn, and Codex turn — all passing — plus environment metadata (OS/arch, Dart SDK version, DartClaw version, provider versions, loaded SQLite module path), and the overall verdict is that Windows is supported

- [ ] **S02 [OC01] FTS5 search layer round-trips a MATCH against the bundled module**
  - **Given** the smoke run started `dartclaw serve` from the Windows artifact with seeded searchable content
  - **When** the FTS5 search layer issues a search that exercises an FTS5 `MATCH`
  - **Then** the seeded record is returned and the recorded loaded SQLite module path is the bundle's `sqlite3.dll` (not `winsqlite3.dll` or an on-PATH DLL), proving real FTS5 search rather than a stubbed response

- [ ] **S03 [OC01] Config-reload layer applies a change via the file-watch (`auto`) mechanism without restart**
  - **Given** the smoke server running with `gateway.reload.mode: auto` (the Windows-supported file-watch path named by S04)
  - **When** the reload layer atomically rewrites the config file with a valid reloadable change
  - **Then** the running server applies the change without a restart and the reload layer records success naming the file-watch (`auto`) mechanism — not SIGUSR1

- [ ] **S04 [OC01,OC03] Both harness turns complete through DartClaw and are recorded per provider**
  - **Given** the smoke server on Windows with Claude and Codex configured
  - **When** the harness layer drives one full DartClaw-managed prompt/response turn for each provider
  - **Then** each turn completes over stdio without a parse/transport error and the evidence records both provider versions and both turn results, so a run that exercised only one provider is not reported as a complete harness pass

- [ ] **S05 [OC02] Missing credentials in CI skip harness layers explicitly and require recorded manual evidence for both providers**
  - **Given** a CI smoke run on Windows x64 with no Claude or Codex credentials
  - **When** the smoke path runs
  - **Then** server/UI/FTS5/reload still run; Claude/Codex are marked skipped; valid manual evidence for both provider turns promotes the overall status to `supported`, while absent/stale/mismatched evidence leaves it `incomplete` and not release-ready. Native Windows ARM64 evidence may cover only the architecture-neutral provider transport slice; x64-sensitive layers remain x64 CI gates.

- [ ] **S06 [OC04] A single failed layer is named and produces the failed verdict**
  - **Given** a smoke run where one runtime layer fails (e.g. config reload does not apply, or the Codex turn errors)
  - **When** the smoke path completes
  - **Then** the report identifies the specific failed layer, remaining layers retain their results, overall status is `failed`, and release-ready is false


## Structural Criteria

- [ ] The smoke path extends the existing `dev/testing/` convention (a profile/runner plus, for provider gaps, a scenario-style manual profile) rather than introducing a parallel test framework.
- [ ] The smoke evidence output includes, at minimum, the fields named by FR8/FR7 validation: OS/arch, Dart SDK version, DartClaw version, provider versions (when the harness layers run), loaded SQLite module path, FTS5 result, config-reload result, and server/Web-UI result.
- [ ] The reload layer uses the file-watch (`auto`) mechanism named by S04's `sharedDecision`; no SIGUSR1/signal reload is asserted as the Windows path.
- [ ] The smoke path consumes the S02 artifact contract verbatim — asset `dartclaw-v<version>-windows-x64.zip` unpacking to the pinned zip-root `{VERSION,bin,lib}` layout (no `bundle/` or `share/` wrapper) — and does not redefine artifact naming or layout.
- [ ] The release-readiness reminder (`dev/tools/release_check.sh` manual gates and/or `dev/testing/README.md`) names the Windows smoke path and the both-provider recorded-manual-evidence condition, without altering automated-gate behavior.
- [ ] Existing POSIX testing profiles, scenarios, and `dev/tools/release_check.sh` automated gates remain unchanged and green.


## Scope & Boundaries

### Work Areas
- A Windows smoke runner under `dev/testing/` (PowerShell-based, since it runs on native Windows) that boots `dartclaw serve` from the artifact/source build and drives the server, Web UI, FTS5-search, config-reload, and Claude/Codex harness layers.
- Layered evidence emitter — `dev/testing/scenarios/windows-runtime-smoke.md` as the repeatable procedure and `dev/testing/evidence/windows-runtime-smoke.md` as the stable latest report.
- Optional provider-evidence input, defaulting to `dev/testing/evidence/windows-harness-turns.md` when present, validated before it may satisfy skipped Claude/Codex layers.
- Release-readiness wiring — the `dev/tools/release_check.sh` manual-gates reminder (and/or `dev/testing/README.md` profile table) names the Windows smoke path and the recorded-manual-evidence rule.
- Reuse of an existing seed config (`plain`-style) so the server/UI/FTS5 layers have deterministic searchable content.

### What We're NOT Doing
- Windows build/packaging and artifact validation (exe smoke, DLL presence, module-identity/FTS5 assertion at build time) -- owned by S02; S09 consumes the produced artifact and exercises the *runtime*.
- Defining the file-watch reload mechanism or the harness turn behavior -- owned by S04 and S07 respectively; S09 drives them as black boxes and records results.
- User-guide install/upgrade/capability-matrix documentation -- owned by S10; S09 owns only the testing-profile/manual-smoke artifact and its evidence.
- New test-framework infrastructure beyond what the smoke path needs -- explicitly excluded by the story scope; extend the existing profile/scenario convention.
- POSIX smoke changes -- the existing `plain`/UI smoke path and `release_check.sh` gates stay as-is.


## Architecture Decision

**Approach**: Add a Windows-only smoke runner that emits per-layer results plus an overall `supported | incomplete | failed` status and release-ready boolean. Provider skips may be satisfied only by validated both-provider evidence for the same DartClaw source/release and provider versions. ARM64 Parallels evidence is accepted for the architecture-neutral provider transport slice with architecture recorded; artifact/SQLite/installer/core runtime gates remain native x64.
**Why this over alternatives**: A layered evidence report (not a single pass/fail) is required so a Windows-only regression is localized to a layer and a partial pass cannot masquerade as "supported"; extending the existing profile/scenario convention avoids a parallel framework the story explicitly excludes.


## Constraints & Gotchas

- **Constraint**: The smoke path runs on native Windows x64 and consumes the S02 artifact contract (`dartclaw-v<version>-windows-x64.zip` → zip-root `{VERSION,bin,lib}`, `dartclaw.exe` + `sqlite3.dll`, no `share/` sidecar); wire to those exact names/layout, do not restage. -- Workaround: fail fast with a clear message if the artifact layout does not match, so packaging drift surfaces as a smoke failure not a false pass.
- **Critical**: An FTS5 "search returned something" check can pass against a system/on-PATH SQLite. -- Instead: the FTS5 layer records the loaded module path and treats a non-bundle module as a failed storage layer (mechanism fidelity), consistent with S02's module-identity rule.
- **Constraint**: The Windows reload path is file-watch (`auto`) only; SIGUSR1 is POSIX-only (S04). -- Must handle by: starting the reload layer's server in `auto` mode and never asserting signal reload on Windows.
- **Avoid**: Treating a credential-only skip of the harness layers as a pass. -- Instead: mark harness layers explicitly skipped and require the recorded both-provider manual-evidence record for release readiness (FR8 binding constraint).
- **Verdict invariant**: executed failure → `failed`; no failures but an uncovered required skip → `incomplete`; every required layer passed directly or through valid replacement evidence → `supported`. Only `supported` is release-ready.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Windows smoke runner boots the server from the artifact and reports the server-startup and Web UI layers
  - A PowerShell smoke runner under `dev/testing/` unpacks/locates the `dartclaw-v<version>-windows-x64.zip` zip-root `{VERSION,bin,lib}` layout, rejects an obsolete `share/` sidecar, starts `dartclaw serve` with a seeded (`plain`-style) config, and records server-startup (process up + health/ready) and Web-UI-load results. Follow the `dev/testing/profiles/plain/run.sh` seed/run shape; reuse its seed corpus.
  - **Verify**: `Test/smoke: runner locates dartclaw-v<version>-windows-x64.zip unpacking to the zip-root {VERSION,bin,lib} layout with no share/ sidecar, records server-startup=pass and web-ui=pass against a live serve, and fails the server layer (named) if serve does not come up` (covers S01)

- [ ] **TI02** FTS5-search layer round-trips a MATCH and records the loaded SQLite module path
  - The search layer issues a query exercising an FTS5 `MATCH` against seeded content and records the loaded SQLite module path; a non-bundle module (`winsqlite3.dll` or on-PATH `sqlite3.dll`) is a failed storage layer. Reuse the FTS5 usage shape from `packages/dartclaw_storage/lib/src/storage/memory_service.dart`.
  - **Verify**: `Test/smoke: FTS5 layer returns the seeded record for a MATCH query and records the loaded module path = bundle sqlite3.dll; a non-bundle module marks the storage layer failed` (covers S02)

- [ ] **TI03** Config-reload layer applies a change via file-watch (`auto`) without restart
  - The reload layer starts (or reuses) the smoke server with `gateway.reload.mode: auto`, atomically rewrites the config with a valid reloadable change, and confirms the change applied without a restart; the recorded result names the file-watch (`auto`) mechanism, never SIGUSR1. Consumes S04's `auto` reload path.
  - **Verify**: `Test/smoke: reload layer applies a valid config change with mode 'auto' without restarting serve and records the mechanism as file-watch/"auto"` (covers S03)

- [ ] **TI04** Harness layers drive one Claude turn and one Codex turn, credential-gated, recorded per provider
  - With credentials, drive and record both turns. Without them, mark each provider skipped. Accept an optional provider-evidence path, defaulting to S07's stable `dev/testing/evidence/windows-harness-turns.md`; validate native Windows OS/architecture, same DartClaw commit/source or release version, provider versions, timestamps, and both passing results before treating skipped provider layers as covered. ARM64 evidence covers only provider transport.
  - **Verify**: `Test/smoke: with credentials, Claude-turn and Codex-turn layers each record a completed turn + provider version; without credentials each records skipped (not pass)` (covers S04, S05)

- [ ] **TI05** Layered evidence report computes the settled tri-state status and release readiness
  - Write `dev/testing/evidence/windows-runtime-smoke.md` with environment metadata and every layer's `pass | fail | skipped` result. Compute: any executed failure → `failed`; otherwise any required skip without validated replacement evidence → `incomplete`; otherwise `supported`. Set release-ready true only for `supported`. Name all failed, skipped, and replacement-evidence-backed layers.
  - **Verify**: `Tests/table: all pass => supported/ready; provider skips + valid matching evidence => supported/ready; provider skips + absent/stale/mismatched evidence => incomplete/not-ready; any executed failure => failed/not-ready`

- [ ] **TI06** A documented manual smoke profile records both-provider evidence when CI is impractical
  - `dev/testing/scenarios/windows-runtime-smoke.md` documents the full procedure and how to supply S07 provider evidence. It states that ARM64 Parallels evidence is valid only for provider transport and cannot replace x64 artifact, SQLite, installer, or core runtime proof.
  - **Verify**: `Inspection: scenario names both stable evidence paths, metadata validation, tri-state table, ARM64 provider-only allowance, and x64-sensitive gates`

- [ ] **TI07** Release-readiness reminder names the Windows smoke path and the recorded-manual-evidence rule
  - The `dev/tools/release_check.sh` manual-gates reminder (and/or the `dev/testing/README.md` profile table) references the Windows smoke path and states that a credential-only CI skip is release-ready only with recorded both-provider manual evidence. Extend the existing manual-gates reminder block in `release_check.sh`; do not change automated-gate behavior.
  - **Verify**: `Grep: release_check.sh manual-gates output (or dev/testing/README.md) names the Windows smoke path and the both-provider recorded-manual-evidence condition; automated gate steps are unchanged` (proves the release-readiness Structural coverage of the FR8 binding constraint)

### Testing Strategy
> The smoke path is itself a Windows-host verification artifact, not a unit suite; Verify lines above assert its per-layer evidence output. The FTS5 module-identity guard mirrors S02's rule so a system-DLL load is caught here too. No new portable unit tests are required beyond confirming existing POSIX gates stay green (Structural Criteria).

### Execution Contract
- TI01 establishes the live server the FTS5 (TI02), reload (TI03), and harness (TI04) layers probe; TI05 consumes TI01–TI04 plus validated replacement evidence. Provider absence is an explicit skip; only TI05 may promote it to covered.


## Final Validation Checklist
- [ ] The four verdict-table cases pass exactly; no uncovered skip or executed failure reports `supported`/release-ready.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see [`data-contract.md`](data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](automation-mode.md). Spec authors: leave this section empty._

#### DECISION NOTE: skipped-provider-supported-verdict

Decision-Key: skipped-provider-supported-verdict
Altitude: fis-local
Affected surface: Windows smoke evidence validation, overall runtime status, release readiness, and provider-skip handling
Decision: The report uses supported, incomplete, or failed. All executed required layers passing yields supported; any executed failure yields failed; skipped provider layers without valid replacement evidence yield incomplete. Matching manual evidence for both provider turns may satisfy skipped provider layers when it records native Windows OS/architecture, the same DartClaw commit/source or release version, provider versions, timestamps, and passing results. ARM64 Parallels evidence may cover the architecture-neutral provider transport slice, but not x64 artifact, SQLite, installer, or core runtime gates.
Rationale: Distinguishes untested from broken, prevents false support claims, allows authenticated manual provider verification, and preserves the Windows x64 release target.
Evidence: S09 S05 and the FR8 binding require both-provider manual evidence for credential skips; the scoping brief establishes provider stdio as architecture-neutral and build/FTS5 as x64-sensitive.
