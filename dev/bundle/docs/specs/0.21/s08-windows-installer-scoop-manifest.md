# Windows Installer and Scoop Manifest

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S08

## Feature Overview and Goal

**Intent**: Windows users have no first-class way to install DartClaw without a source checkout or WSL; this ships a one-command PowerShell installer and a Scoop manifest that place `dartclaw.exe` and its DLLs on PATH so `dartclaw` just works in a new terminal.

**Expected Outcomes** (user-/business-observable success conditions):

- [OC01] Running the documented `install.ps1` command downloads the `dartclaw-v<version>-windows-x64.zip` asset, verifies its checksum, installs the archive's `VERSION`, `bin/dartclaw.exe`, and `lib/sqlite3.dll` together in the loadable layout, records a persistent user PATH entry, and a newly opened terminal resolves `dartclaw`.
- [OC02] Every documented failure path (download failure, checksum mismatch, unsupported architecture, PATH write failure, and an existing/older install) produces an actionable error and never leaves a partial *active* install.
- [OC03] A Scoop manifest installs the same release asset, exposes `dartclaw`, and is kept in version/checksum lockstep with the release (published to a bucket, analogous to the Homebrew tap).


## Required Context

### From `docs/specs/0.21/prd.md` – FR6 Windows Installer and Scoop Manifest (acceptance + validation + errors)
<!-- source: docs/specs/0.21/prd.md#fr6-windows-installer-and-scoop-manifest -->
<!-- extracted: ad8e7b9 -->
> **Acceptance Criteria**:
> - `install.ps1` downloads the Windows x64 zip, installs `dartclaw.exe` and DLLs together, and records a persistent user PATH entry.
> - A newly opened terminal resolves `dartclaw`.
> - Scoop manifest installs the same release asset and exposes `dartclaw`.
> - Installer handles existing installs, upgrades, and unsupported architecture with clear messages.
>
> **Inputs**: Release version, target install directory, user PATH. **Outputs**: Installed executable/DLLs and persistent PATH update.
> **Validation**: Installer test or manual evidence covers first install, upgrade, and new-terminal PATH resolution.
> **Error Handling**: Download failure, checksum mismatch, unsupported architecture, or PATH write failure produces an actionable error and does not leave a partial active install.

### From `docs/specs/0.21/prd.md` – US01 one-command install
<!-- source: docs/specs/0.21/prd.md#user-stories -->
<!-- extracted: ad8e7b9 -->
> As a Windows developer, I want to install DartClaw with one command so that I do not need WSL or a source checkout. **Acceptance**: Running the documented PowerShell command installs `dartclaw.exe` and required DLLs, and `dartclaw` resolves in a newly opened terminal.

### From `docs/specs/0.21/prd.md` – Edge cases the installer must handle
<!-- source: docs/specs/0.21/prd.md#edge-cases -->
<!-- extracted: ad8e7b9 -->
> | Existing install directory contains older DLL | Installer replaces the executable and required DLLs atomically or aborts before activating partial install. | User reruns installer after cleanup guidance. |
> | User PATH write fails | Installer reports PATH failure and leaves executable installed at a named path. | User adds path manually or reruns with corrected permissions. |

### Shared decision (S02→S08→S09) – Windows artifact naming and bundle layout (the contract S08 consumes)
<!-- source: docs/specs/0.21/plan.json#sharedDecisions -->
<!-- extracted: ad8e7b9 -->
> S02 fixes the release asset name `dartclaw-v<version>-windows-x64.zip` (v-prefixed, matching the existing `dartclaw-v${version}-<target>` release convention) and the zip-root `VERSION` + `bin/dartclaw.exe` + `lib/sqlite3.dll` layout. S08's installer and Scoop manifest preserve that exact tree so the executable resolves its sibling DLL. Built-in text assets are embedded per ADR-047; the archive has no `share/` sidecar.

### Binding Constraint (FR4) – POSIX release/packaging unchanged
<!-- source: docs/specs/0.21/prd.md#fr4-windows-release-artifact -->
<!-- extracted: ad8e7b9 -->
> Existing macOS/Linux artifacts and packaging behavior remain unchanged.


## Deeper Context

- `../dartclaw-public/dev/adrs/038-homebrew-formula-publication.md` – the accepted pattern this story mirrors for Scoop: a canonical in-repo manifest template + a Dart renderer that injects the build-derived SHA256 + a release-workflow job that pushes to a separate package-manager repo using a scoped token and no-ops when the secret is absent. Read before designing the Scoop publish path.
- `../dartclaw-public/dev/adrs/047-embedded-binary-assets.md` and `048-release-builds-dart-build-bundled-sqlite.md` – accepted archive contract: text assets embedded; `VERSION`, `bin/`, and sibling `lib/` ship together.
- `docs/specs/0.21/s02-windows-release-artifact-fts5-sqlite.md#acceptance-scenarios` – S02 scenario S01 defines the exact zip contents and loadable layout the installer extracts.
- `docs/specs/0.21/prd.md#non-functional-requirements` – Usability row: `dartclaw` resolves in a newly opened terminal after install; Observability row: failure diagnosis must identify the failed layer (…installer…).


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01] One-command PowerShell install puts `dartclaw` on PATH for a new terminal**
  - **Given** a Windows x64 host with no prior DartClaw install and a published `dartclaw-v<version>-windows-x64.zip` plus its `.sha256`
  - **When** the user runs the documented `install.ps1` command (default version = latest release)
  - **Then** the installer downloads the zip, verifies SHA256, and installs the tree under `$env:LOCALAPPDATA\Programs\DartClaw` by default (`VERSION`, `bin/dartclaw.exe`, `lib/sqlite3.dll`); that root's `bin` directory is added to persistent user PATH, and a freshly launched terminal runs `dartclaw --version`

- [x] **S02 [OC02] [TI02] Checksum mismatch aborts with no install**
  - **Given** a downloaded zip whose SHA256 does not match the published `.sha256`
  - **When** `install.ps1` runs its verification step
  - **Then** the installer exits non-zero with an actionable checksum-mismatch message naming the expected vs actual digest, and no `dartclaw.exe`, DLL, or PATH entry is written

- [x] **S03 [OC02] [TI02] Unsupported architecture is rejected before any download or install**
  - **Given** a host whose processor architecture is not x64 (e.g. `PROCESSOR_ARCHITECTURE=ARM64`)
  - **When** `install.ps1` runs
  - **Then** the installer exits non-zero with a message naming x64 as the only supported architecture for this release, and nothing is downloaded, extracted, or added to PATH

- [x] **S04 [OC02] [TI02] Upgrade over an existing install never leaves a partial active install**
  - **Given** an existing DartClaw install directory containing an older `dartclaw.exe` and `sqlite3.dll`
  - **When** `install.ps1` runs for a newer version and either succeeds or fails mid-way (e.g. a file is locked)
  - **Then** on success the executable and required DLLs are replaced together (no mixed old-exe/new-DLL state), and on failure the installer aborts before activating the new install and reports which step failed — it never activates a half-written install

- [x] **S05 [OC02] [TI02] PATH write failure still leaves a usable, discoverable executable**
  - **Given** installation succeeds but the persistent user PATH update fails (e.g. the `HKCU\Environment` write is denied)
  - **When** `install.ps1` finishes
  - **Then** `dartclaw.exe` remains installed and the installer reports the PATH failure and prints the exact directory it was installed to, with guidance to add it to PATH manually

- [x] **S06 [OC03] [TI03,TI04,TI05] Scoop manifest installs the same asset and stays in lockstep**
  - **Given** the rendered Scoop manifest for `<version>`
  - **When** its `version`, `architecture.64bit.url`, `architecture.64bit.hash`, and `bin` are inspected (and, on a Windows host, `scoop install` is run against it)
  - **Then** the manifest `version` equals `dartclawVersion`, the URL points at `dartclaw-v<version>-windows-x64.zip`, the `hash` equals that asset's published SHA256, `bin` targets `dartclaw.exe` inside the extracted archive, and installing exposes a working `dartclaw` command


## Structural Criteria

- [x] The existing macOS/Linux release assets (`dartclaw-v<version>-<target>.tar.gz` + `.sha256`), the shared-asset publish, the aggregate checksums job, and the Homebrew tap job in `.github/workflows/release-binaries.yml` are unchanged; the S02-owned Windows build/matrix rows are not modified by this story.
- [x] A portable structural test asserts the canonical Scoop manifest is version-lockstepped to `dartclawVersion`, references the `dartclaw-v#{version}-windows-x64.zip` asset, and carries a single 64-bit hash slot — mirroring `apps/dartclaw_cli/test/tool/homebrew_formula_test.dart`.
- [x] Existing `dart analyze --fatal-infos`, format, and workspace test gates remain green.


## Scope & Boundaries

### Work Areas
- `install.ps1` (repo root) – one-command PowerShell installer: version/dir/base-url parameters, download, checksum verify, arch gate, staged extract + atomic activation, persistent user PATH write, and the documented error paths.
- `package/scoop/dartclaw.json` (new canonical Scoop manifest template) – 64-bit URL/hash/`bin`, version pinned to `dartclawVersion`, placeholder hash (build-derived), mirroring the Homebrew template's role.
- `dev/tools/render_scoop_manifest.dart` (new) – inject the Windows asset's verified SHA256 into the manifest template, asserting version lockstep and exactly one hash slot (mirrors `render_homebrew_formula.dart`).
- `.github/workflows/release-binaries.yml` – add a `scoop` job (`needs: build`, modeled on the `homebrew` job) that downloads the Windows `.sha256`, renders the manifest, and pushes it to the `DartClaw/scoop-dartclaw` bucket repo via a `SCOOP_BUCKET_TOKEN` scoped-PAT secret, no-op when the secret is absent; leave all existing jobs untouched.
- `apps/dartclaw_cli/test/tool/scoop_manifest_test.dart` (new) – structural test for the canonical manifest (lockstep, asset name, single hash slot, `bin` target).

### What We're NOT Doing
- winget and Chocolatey packaging -- deferred; PowerShell + Scoop first per FR6 ("Add winget/Chocolatey immediately" was rejected in the PRD's decision log).
- Building or renaming the Windows zip / DLL bundle layout -- owned by S02; S08 only consumes the `dartclaw-v<version>-windows-x64.zip` zip-root `{VERSION,bin,lib}` layout contract.
- Changing macOS/Linux assets, the Homebrew job, or the aggregate-checksums job -- binding constraint keeps POSIX release/packaging unchanged.
- Machine-wide (system PATH / admin) installs -- the installer targets the per-user PATH so it runs without elevation; system-wide install is out of scope for 0.21.
- A new ADR for Scoop publication -- the approach is the direct analog of accepted ADR-038; reference it rather than re-deciding.


## Architecture Decision

**Approach**: A standalone `install.ps1` defaults to `$env:LOCALAPPDATA\Programs\DartClaw`, with an explicit install-root override, and performs download → checksum → arch-gate → staged extract → atomic activation → persistent `<install-root>\bin` user PATH. The Scoop manifest reuses the ADR-038 Homebrew mechanism.
**Why this over alternatives**: Mirroring ADR-038 keeps both package-manager manifests testable and drift-free from one build; a hand-maintained Scoop manifest would silently break on every release exactly as ADR-038 documents for Homebrew.


## Code Patterns & External References

```
# type | path#anchor                                                    | why needed (intent)
file   | .github/workflows/release-binaries.yml#homebrew                | Job shape to clone for `scoop`: needs:build, download .sha256, render, push to external repo, no-op without secret
file   | dev/tools/render_homebrew_formula.dart#main                    | Renderer shape: version-lockstep assert + single-slot digest injection to mirror for Scoop
file   | package/homebrew/dartclaw.rb                                   | Canonical-template-with-placeholder-digest pattern to mirror as package/scoop/dartclaw.json
file   | apps/dartclaw_cli/test/tool/homebrew_formula_test.dart#main    | Structural-test shape to mirror for the Scoop manifest
file   | packages/dartclaw_server/lib/src/version.dart#dartclawVersion  | The version the manifest/installer lockstep against
```


## Constraints & Gotchas

- **Critical**: The zip preserves the sibling layout where `bin/dartclaw.exe` resolves `lib/sqlite3.dll` (S02/ADR-048 contract). The installer and Scoop must preserve `VERSION` + `bin/` + `lib/`; do not flatten or drop `lib/`. Built-in text assets are embedded per ADR-047, so requiring or staging `share/` would resurrect a deleted contract. The PATH entry / Scoop `bin` targets the archive's `bin/` directory.
- **Critical**: Persistent user PATH on Windows is the `HKCU\Environment` `Path` value via `[Environment]::SetEnvironmentVariable('Path', …, 'User')`; the current session's `$env:Path` does NOT propagate to it. New-terminal resolution is the acceptance signal — verify in a fresh process, not the installing session.
- **Install/data separation**: The default program root is `$env:LOCALAPPDATA\Programs\DartClaw`; do not reuse DartClaw's runtime data directory. Persist `<install-root>\bin` only, not the whole root, on user PATH.
- **Constraint**: Download/checksum/extract must complete and verify into a staging location before the previous install is replaced, so a mid-run failure aborts before activation (satisfies the "no partial active install" edge case for both fresh and upgrade installs).
- **Constraint**: Windows-host is required to run `install.ps1` / `scoop install` end-to-end; the renderer and manifest structural test are portable Dart and run on any CI runner.
- **Avoid**: Editing the S02 Windows build/matrix rows or any existing release job. -- Instead: add the `scoop` job additively, exactly as the `homebrew` job was added.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** `install.ps1` performs a one-command install with persistent PATH
  - Parameters: version (default latest via GitHub releases API), install root (default `$env:LOCALAPPDATA\Programs\DartClaw`), and base-URL/local-artifact override for tests. Download and verify the zip, preserve `VERSION`+`bin/`+`lib/`, and add `<install-root>\bin` to persistent user PATH. An explicit install-root parameter overrides the default for all staging, activation, upgrade, and PATH behavior.
  - **Verify**: `Windows CI/manual: default install lands at %LOCALAPPDATA%\Programs\DartClaw with VERSION + bin\dartclaw.exe + lib\sqlite3.dll and no share sidecar; HKCU user Path contains exactly that root's bin; a new terminal prints the version; an explicit root override uses its own bin instead`

- [x] **TI02** `install.ps1` fails safe on every documented error path
  - Handle: download failure, SHA256 mismatch (name expected vs actual), non-x64 `PROCESSOR_ARCHITECTURE` (reject before download, naming x64-only), upgrade over an existing install (replace exe + DLLs together via stage-then-activate; on mid-run failure abort before activation), and persistent-PATH write failure (keep the exe installed, report failure, print the install directory). No error path leaves a partial *active* install.
  - **Verify**: `Windows CI/manual: (a) download failure -> exit!=0, actionable message, no files/PATH written; (b) tampered zip -> exit!=0, message names checksum mismatch, no files/PATH written; (c) PROCESSOR_ARCHITECTURE=ARM64 -> exit!=0 naming x64, nothing downloaded; (d) simulated PATH-write denial -> dartclaw.exe still present and install dir printed; (e) interrupted upgrade -> no mixed old-exe/new-DLL active state`

- [x] **TI03** A canonical Scoop manifest template describes the Windows asset with a placeholder hash
  - Add `package/scoop/dartclaw.json` with `version` = `dartclawVersion`, `architecture.64bit.url` = the `dartclaw-v#{version}-windows-x64.zip` release URL, a placeholder 64-bit `hash`, and `bin` targeting `dartclaw.exe` at its in-archive path (respecting any `bin/` subdir). Mirror the canonical-template role of `package/homebrew/dartclaw.rb`.
  - **Verify**: `Test: scoop_manifest_test.dart asserts the manifest version equals dartclawVersion, url contains 'dartclaw-v#{version}-windows-x64.zip', exactly one 64-bit hash slot exists, and bin resolves to dartclaw.exe`

- [x] **TI04** The release workflow renders and publishes the Scoop manifest without disturbing existing jobs
  - Add `dev/tools/render_scoop_manifest.dart` (inject the Windows asset SHA256, assert version lockstep + single hash slot, mirroring `render_homebrew_formula.dart`) and a `scoop` job in `.github/workflows/release-binaries.yml` (`needs: build`) that downloads `dartclaw-v*-windows-x64.zip.sha256`, renders the manifest, and pushes it to the `DartClaw/scoop-dartclaw` bucket repo via the `SCOOP_BUCKET_TOKEN` secret; the job no-ops (does not fail the release) when the secret is absent. Consumes the Windows `.sha256` published by S02. Leave every existing job byte-unchanged.
  - **Verify**: `CI: on a tag push the scoop job renders a manifest whose hash equals the published windows-x64 .sha256 and pushes it (or no-ops without the secret); the build/checksums/homebrew jobs and POSIX matrix rows are byte-unchanged`

- [x] **TI05** A structural test guards the Scoop manifest against drift
  - Add `apps/dartclaw_cli/test/tool/scoop_manifest_test.dart` asserting lockstep to `dartclawVersion`, the `dartclaw-v#{version}-windows-x64.zip` asset reference, a single 64-bit hash slot, and a `bin` pointing at `dartclaw.exe`. Mirror `apps/dartclaw_cli/test/tool/homebrew_formula_test.dart`.
  - **Verify**: `Test: dart test runs scoop_manifest_test.dart green; mutating the manifest version away from dartclawVersion fails the test`

### Testing Strategy
> `install.ps1` behavior (TI01/TI02) needs a Windows host; per FR6 an installer test (e.g. Pester on `windows-latest`, exercised against a fixture zip via the base-URL/local-artifact override) or recorded manual evidence covering first install, upgrade, and new-terminal PATH is acceptable. The renderer + manifest structural test (TI03/TI05) are portable Dart workspace tests. No provider credentials or network beyond the release asset are involved.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see [`data-contract.md`](data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](automation-mode.md). Spec authors: leave this section empty._

#### DECISION NOTE: windows-default-install-directory

Decision-Key: windows-default-install-directory
Altitude: fis-local
Affected surface: install.ps1 default installation root, persistent user PATH, upgrades, tests, and documentation
Decision: The default install root is $env:LOCALAPPDATA\Programs\DartClaw, and the persistent user PATH entry is its bin subdirectory. An explicit install-directory parameter may override the root.
Rationale: Uses the conventional non-admin per-user program namespace and keeps installed binaries separate from DartClaw runtime data.
Evidence: S08 requires one-command non-admin installation, stable upgrades, and new-terminal PATH resolution; the selected path gives each an exact target.

### Run: 2026-07-11 13:17 UTC – discovered-requirements

#### DISCOVERED REQUIREMENTS

- **Valid Scoop version substitution**
  - **Requirement**: The canonical manifest's install-time `architecture.64bit.url` must contain the concrete
    `dartclaw-v<version>-windows-x64.zip` URL. The `$version` placeholder may appear only in
    `autoupdate.architecture.64bit.url`; `#{version}` is not valid Scoop syntax.
  - **Rationale**: Scoop downloads the root architecture URL directly and performs version-variable substitution only
    while updating a manifest. A literal placeholder in the install-time URL would make the published manifest unusable.
  - **Evidence**: Official Scoop autoupdate documentation and updater/downloader source; verified 2026-07-11.

### Run: 2026-07-11 13:31 UTC – observations

#### NOTICED BUT NOT TOUCHING

- `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart`: the concurrent workspace state has 51 methods
  against the fitness limit of 40; this file was dirty before S08 and is outside the installer/Scoop scope.
