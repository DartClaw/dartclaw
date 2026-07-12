# Windows Release Artifact with FTS5-Guaranteed SQLite

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: Windows developers and maintainers have no official binary and no release job that produces one; without a Windows x64 artifact whose bundled SQLite guarantees FTS5, DartClaw's core runtime and its search stay unusable on Windows or silently degrade to a system DLL with no full-text search.

**Expected Outcomes** (user-/business-observable success conditions):

- [OC01] A tagged release publishes a Windows x64 asset named `dartclaw-v<version>-windows-x64.zip` containing `dartclaw.exe` plus the required DLLs in a loadable layout, built on a Windows x64 CI host.
- [OC02] The Windows runtime loads the bundled FTS5-capable SQLite module (never system `winsqlite3.dll` or a stray on-PATH DLL); an FTS5 virtual table plus `MATCH` query round-trips.
- [OC03] Pre-publish artifact validation fails the release job (no asset uploaded) when the executable smoke, a required DLL, or the bundled-FTS5 module check does not pass.
- [OC04] Existing macOS/Linux build, packaging, and CI gates remain unchanged and green.


## Required Context

### From `docs/specs/0.21/prd.md` – FR4 Windows Release Artifact (acceptance + validation)
<!-- source: docs/specs/0.21/prd.md#fr4-windows-release-artifact -->
<!-- extracted: ad8e7b9 -->
> **Acceptance Criteria**:
> - Release workflow builds on `windows-latest` or equivalent Windows x64 host.
> - The workflow uses the build command that runs native build hooks and produces the `build/cli/windows_x64/bundle/{bin,lib}` layout.
> - Published asset is named `dartclaw-<version>-windows-x64.zip` and contains `dartclaw.exe` plus required DLLs.
> - Existing macOS/Linux artifacts and packaging behavior remain unchanged.
>
> **Validation**: CI runs `dartclaw.exe --help` or equivalent executable smoke against the built bundle before upload.
> **Error Handling**: Missing executable, missing DLL, or failed smoke prevents artifact publication.

### From `docs/specs/0.21/prd.md` – FR5 FTS5-Guaranteed SQLite on Windows (acceptance + validation)
<!-- source: docs/specs/0.21/prd.md#fr5-fts5-guaranteed-sqlite-on-windows -->
<!-- extracted: ad8e7b9 -->
> **Acceptance Criteria**:
> - Windows build neutralizes `source: system` at every level that can affect the workspace build.
> - Tests assert `ENABLE_FTS5` and verify the loaded module is the bundled SQLite library shipped with the artifact.
> - FTS5 virtual table creation and MATCH query succeed in Windows verification.
>
> **Validation**: Windows CI or smoke test fails if the runtime loads `winsqlite3.dll` or any non-bundled module for the release artifact.
> **Error Handling**: Missing FTS5 fails fast with a clear storage/search initialization error that identifies the loaded module.

### Binding Constraint (FR4) – Windows-host build
<!-- source: docs/specs/0.21/prd.md#constraints -->
<!-- extracted: ad8e7b9 -->
> Windows artifacts must be built on Windows hosts; no macOS/Linux cross-compilation path is available.

### Binding Constraint (FR4) – POSIX packaging unchanged
<!-- source: docs/specs/0.21/prd.md#fr4-windows-release-artifact -->
<!-- extracted: ad8e7b9 -->
> Existing macOS/Linux artifacts and packaging behavior remain unchanged.

### Binding Constraint (FR5) – FTS5 required, no system DLL
<!-- source: docs/specs/0.21/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: ad8e7b9 -->
> DartClaw search requires FTS5. Windows must not depend on system `winsqlite3.dll`.

### From `docs/specs/0.21/spikes-scoping-brief.md` – S0a proven build path + the source-mode trap
<!-- source: docs/specs/0.21/spikes-scoping-brief.md#overall-go-no-go-both-spikes-resolved -->
<!-- extracted: ad8e7b9 -->
> Working build command: `dart build cli` (run from `apps/dartclaw_cli/`); `dart compile exe` is a non-option with build hooks present. Bundle layout: `build/cli/<os>_<arch>/bundle/bin/<exe>` + `bundle/lib/<dlls>`.
> F06 finding: `hooks.user_defines.sqlite3.source: system` exists in **both** the workspace-root `pubspec.yaml` and `apps/dartclaw_cli/pubspec.yaml`, and in a pub workspace the hook honors the **workspace root's** user_defines. Stripping only the app pubspec left the hook emitting `DynamicLoadingSystem('sqlite3.dll')` — nothing bundled — and the FTS5 probe *appeared* to pass because a stray `sqlite3.dll` on the runner PATH was silently loaded. The per-platform source-mode override must neutralize the root-pubspec block, and the FTS5 assertion must verify *which* module loaded, not just that FTS5 answers. S0a confirmed the shipped `bundle/lib/sqlite3.dll` reports `ENABLE_FTS5` and round-trips a `CREATE VIRTUAL TABLE … USING fts5` + `MATCH` via raw FFI against the shipped DLL.

> **Reconciliation with accepted ADR-047/048**: The spike accurately describes the pre-0.20.1 baseline. ADR-048 subsequently removed every committed `source: system` block and standardized all release builds on default-bundled `dart build cli`; S02 guards that accepted baseline rather than reintroducing a Windows-only neutralization path. ADR-047 embeds built-in text assets, so the release archive contains `VERSION`, `bin/`, and `lib/` only — no `share/` sidecar.


## Deeper Context

- `docs/specs/0.21/prd.md#edge-cases` – expected behavior for accidental system SQLite, missing/misplaced `sqlite3.dll`, and the module-identity failure path.
- `docs/research/windows-cross-platform-support/research.md` – background on the Windows-host build constraint and `winsqlite3.dll` unreliability.
- `docs/specs/0.21/prd-brief.md` – milestone framing and the S0a/S0b gating outcomes.
- `../dartclaw-public/dev/adrs/047-embedded-binary-assets.md` – accepted embedded-text-asset contract; release archives no longer stage `share/`.
- `../dartclaw-public/dev/adrs/048-release-builds-dart-build-bundled-sqlite.md` – accepted release-build baseline: `dart build cli`, bundled SQLite on every platform, and no committed `source: system` blocks.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01,TI03,TI04,TI05] Tagged release publishes the Windows x64 zip with the pinned root layout**
  - **Given** a `v<version>` tag is pushed and the release workflow runs its Windows x64 matrix entry on a `windows-latest` host
  - **When** the Windows job builds with `dart build cli` from `apps/dartclaw_cli/` and packages the result
  - **Then** the published release asset is named `dartclaw-v<version>-windows-x64.zip`, and unzipping it yields the zip-root layout `VERSION`, `bin/dartclaw.exe`, and `lib/sqlite3.dll` with no `bundle/` wrapper or `share/` sidecar; built-in text assets are embedded per ADR-047, and the executable loads the sibling DLL at runtime

- [x] **S02 [OC02] [TI02,TI04] Bundled FTS5 SQLite loads and MATCH round-trips on the Windows artifact**
  - **Given** the built Windows bundle from S01
  - **When** artifact validation exercises the built runtime's package-SQLite binding, records the loaded module path, and runs `PRAGMA compile_options`, then `CREATE VIRTUAL TABLE t USING fts5(x); INSERT …; SELECT … WHERE x MATCH …`
  - **Then** `compile_options` includes `ENABLE_FTS5`, the loaded module resolves to the bundled `sqlite3.dll` shipped in the zip (not `winsqlite3.dll` and not an on-PATH `sqlite3.dll`), and the `MATCH` query returns the inserted row

- [x] **S03 [OC02] [TI02] Release configuration preserves the accepted bundled-SQLite baseline**
  - **Given** ADR-048 removed committed `hooks.user_defines.sqlite3.source: system` overrides from the workspace and standardized release builds on `dart build cli`
  - **When** the Windows build runs
  - **Then** no committed source override has returned, the build hook bundles `sqlite3.dll` rather than emitting `DynamicLoadingSystem('sqlite3.dll')`, and validation confirms the loaded module is the bundled DLL

- [x] **S04 [OC03] [TI04,TI05] Validation blocks a bad Windows artifact before publish**
  - **Given** a Windows build whose zip is missing `sqlite3.dll` or `VERSION`, unexpectedly contains a `share/` sidecar, fails `dartclaw.exe --help`, or whose loaded SQLite lacks `ENABLE_FTS5`
  - **When** the pre-publish validation step runs
  - **Then** the release job fails with an error naming the failed check (missing executable, missing DLL, unexpected `share/` sidecar, missing `VERSION`, failed smoke, or wrong/non-FTS5 module) and no Windows asset is uploaded to the release

- [x] **S05 [OC04] [TI06] macOS/Linux release output and the portable FTS5 guard are unchanged**
  - **Given** the existing macOS/Linux matrix entries and the POSIX build path in `dev/tools/build.sh`
  - **When** the release workflow and workspace tests run
  - **Then** the macOS/Linux assets keep their existing `dartclaw-v<version>-<target>.tar.gz` names and staging layout, the POSIX build path is unmodified, and the portable `ENABLE_FTS5` compile-option test passes on the CI runtime


## Structural Criteria

- [x] A portable test asserts the running SQLite reports `ENABLE_FTS5` in `PRAGMA compile_options`, guarding search-capability regressions on every platform.
- [x] macOS/Linux release asset names (`dartclaw-v<version>-<target>.tar.gz`) and the `dev/tools/build.sh` POSIX build/staging/sha256 behavior are unchanged.
- [x] Existing `dart analyze --fatal-infos`, format, workspace test, architecture, and fitness gates remain green.


## Scope & Boundaries

### Work Areas
- `.github/workflows/release-binaries.yml` – add a Windows x64 (`windows-latest`) matrix entry that builds, validates, and publishes the zip; leave macOS/Linux entries untouched.
- New Windows build/packaging script (e.g. `dev/tools/build_windows.ps1`) – `dart build cli`, zip packaging with the loadable layout, `.sha256`, and pre-publish artifact validation.
- Workspace and CLI pubspec regression guard – verify no committed `hooks.user_defines.sqlite3.source: system` override returns, preserving ADR-048's bundled-SQLite release baseline.
- FTS5 module-identity + compile-option verification used by artifact validation (asserts the bundled DLL loaded, not `winsqlite3.dll`).
- Portable FTS5 regression test under `packages/dartclaw_storage/test/` asserting `ENABLE_FTS5`.

### What We're NOT Doing
- Windows installer, Scoop manifest, and PATH handling -- owned by S08, which consumes this asset name/layout contract.
- The runtime Windows smoke path (server/Web UI/reload/harness turns) -- owned by S09.
- Changing the macOS/Linux release build or packaging behavior -- ADR-048 already uses bundled SQLite on every platform; this story adds Windows without altering those paths.
- Windows ARM64 artifact -- explicitly out of scope for 0.21 (x64 first).
- A new cross-platform SQLite loader abstraction -- the existing `sqlite3.open` path is unchanged; S02 validates the Windows artifact against ADR-048's shared bundled-SQLite contract.


## Architecture Decision

**Approach**: Build the Windows artifact with `dart build cli` (bundle mode, S0a-proven) in a dedicated Windows-only build/package script and a new release-workflow matrix entry, leaving the accepted POSIX `build.sh` path untouched; preserve ADR-048's no-`source: system` baseline and gate publication on validation that proves the runtime-loaded module identity, not just that FTS5 answers.
**Why this over alternatives**: A separate Windows script preserves the binding constraint that macOS/Linux packaging is unchanged; module-identity validation (not a bare FTS5 probe) is required because S0a showed a stray on-PATH `sqlite3.dll` can make a system-loaded build falsely pass.


## Code Patterns & External References

```
# type | path#anchor                                                      | why needed (intent)
file   | .github/workflows/release-binaries.yml#build                     | Matrix + version-read + gh-release publish pattern to extend for Windows
file   | dev/tools/build.sh                                               | POSIX packaging/sha256 reference — mirror shape in the Windows script; do NOT modify
file   | packages/dartclaw_storage/lib/src/storage/search_db.dart#openSearchDb | sqlite3.open entry point — runtime DLL load site
file   | packages/dartclaw_storage/lib/src/storage/memory_service.dart   | FTS5 CREATE VIRTUAL TABLE + MATCH usage — shape for the validation/regression check
```


## Constraints & Gotchas

- **Critical**: ADR-048 removed committed `source: system` overrides because any one can silently force a host SQLite. -- Must handle by: fail a regression guard if such an override reappears anywhere affecting the workspace release build.
- **Critical**: A bare "does FTS5 answer?" check can pass against `winsqlite3.dll` or a stray on-PATH `sqlite3.dll`. -- Instead: assert the loaded module is the bundled DLL shipped in the zip (module path/identity), then that it reports `ENABLE_FTS5` and round-trips `MATCH`.
- **Constraint**: `dart compile exe` cannot produce the bundle when build hooks are present. -- Workaround: use `dart build cli` (emits `build/cli/<os>_<arch>/bundle/{bin,lib}`).
- **Constraint**: Windows cannot be cross-compiled from macOS/Linux; the asset must build on a Windows x64 runner.
- **Avoid**: renaming or restaging the macOS/Linux `.tar.gz` assets. -- Instead: add Windows as an additive matrix entry only.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** A Windows x64 build produces the `dart build cli` bundle with the executable and SQLite DLL
  - Build from `apps/dartclaw_cli/` with `dart build cli` on `windows-latest`; the bundle lands at `build/cli/windows_x64/bundle/bin/dartclaw.exe` and `build/cli/windows_x64/bundle/lib/sqlite3.dll` (S0a-proven). Depends on TI02's accepted-baseline guard.
  - **Verify**: `Test/CI: after the Windows build, build/cli/windows_x64/bundle/bin/dartclaw.exe and build/cli/windows_x64/bundle/lib/sqlite3.dll both exist and dartclaw.exe --help exits 0`

- [x] **TI02** Release configuration preserves ADR-048's bundled-SQLite baseline
  - Add a regression check that rejects any committed `hooks.user_defines.sqlite3.source: system` override affecting the workspace release build; do not add a Windows-only mutation or temporary pubspec rewrite. The Windows build hook must bundle `sqlite3.dll` and must not emit `DynamicLoadingSystem('sqlite3.dll')`.
  - **Verify**: `CI: no committed source: system override exists in the release workspace; the Windows build's loaded module is bundle/lib/sqlite3.dll`

- [x] **TI03** The Windows release asset is packaged as `dartclaw-v<version>-windows-x64.zip` with the pinned root layout
  - Package the bundle into `dartclaw-v<version>-windows-x64.zip` with this exact **zip-root** layout, matching ADR-048's POSIX archive convention: `VERSION`, `bin/dartclaw.exe`, and `lib/sqlite3.dll`. The transient `dart build cli` `bundle/` directory is stripped; `bin/` and `lib/` are re-rooted to the zip root. Built-in text assets are embedded per ADR-047, so no `share/` sidecar is staged. Emit a matching `.sha256` and mirror `dev/tools/build.sh` sha/version handling without modifying it.
  - **Verify**: `CI: the published asset is named dartclaw-v<version>-windows-x64.zip and unzips to VERSION, bin/dartclaw.exe, and lib/sqlite3.dll only (no bundle/ or share/ wrapper); a .sha256 sidecar is published`

- [x] **TI04** Pre-publish validation proves the artifact before upload
  - Validate the packaged zip: `dartclaw.exe --help` smoke; required DLL and `VERSION` present; no obsolete `share/` sidecar; runtime-loaded SQLite module identity is the bundled `sqlite3.dll` (not `winsqlite3.dll`/on-PATH); `PRAGMA compile_options` includes `ENABLE_FTS5`; `CREATE VIRTUAL TABLE … USING fts5` + `MATCH` returns the inserted row. The module path must come from the built runtime's actual package binding; raw FFI against a chosen DLL may supplement but cannot replace that proof. Any failure aborts before publish. Consumes the bundle from TI01 and baseline guard from TI02.
  - **Verify**: `CI: injecting a missing sqlite3.dll, an unexpected share/ sidecar, a missing VERSION, a failing --help, or a wrong/non-FTS5 runtime-loaded module makes the Windows job fail with a named check and uploads no asset; a good bundle passes all checks; a stray FTS5-capable DLL on PATH still fails identity validation`

- [x] **TI05** The release workflow builds and publishes the Windows asset without disturbing POSIX assets
  - Add a `windows-latest` x64 matrix entry to `.github/workflows/release-binaries.yml` that runs the Windows build+validate+package script and publishes `dartclaw-v<version>-windows-x64.zip` (+ `.sha256`); macOS/Linux entries, shared-asset publish, checksums, and Homebrew jobs are unchanged. Consumes packaging (TI03) and validation (TI04).
  - **Verify**: `CI: on a tag push the workflow publishes the Windows zip alongside unchanged dartclaw-v<version>-{linux,macos}-*.tar.gz assets; the macOS/Linux matrix rows and build.sh invocation are byte-unchanged`

- [x] **TI06** A portable test guards FTS5 availability on every platform
  - Add a test under `packages/dartclaw_storage/test/` asserting the running SQLite reports `ENABLE_FTS5` via `PRAGMA compile_options` (open via `openSearchDbInMemory` / `sqlite3`), so a future source-mode or dependency regression that drops FTS5 fails the workspace test gate.
  - **Verify**: `Test: dart test asserts PRAGMA compile_options output contains 'ENABLE_FTS5'; passes on the CI runtime`

### Testing Strategy
> Windows-artifact assertions (module identity, exe smoke, packaged layout) run as CI/artifact-validation steps on `windows-latest`, since they need the built bundle and a Windows host. The `ENABLE_FTS5` compile-option guard is a portable workspace unit test. No provider credentials or network are involved.


## Final Validation Checklist
- [x] No Windows asset is publishable unless module identity resolves to the bundled `sqlite3.dll` (guards against a false FTS5 pass from an on-PATH or system DLL).


## Implementation Observations

Implementation observations are appended per execution run so later reviewers can distinguish intentional scope boundaries from missed work.

### Run: 2026-07-11 12:22 UTC – observations

#### NOTICED BUT NOT TOUCHING

- `packages/dartclaw_workflow/test/workflow/workflow_service_test.dart:773` failed once during the workspace gate, then passed both the focused retry and full workspace rerun.
