# Windows Documentation and Capability Matrix

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S10

## Feature Overview and Goal

**Intent**: Synchronize user, architecture, and planning documentation with the actually-shipped 0.21 Windows contract so Windows users, contributors, and maintainers see honest support boundaries — install paths, a capability/degradation matrix, the platform capability surface, and roadmap alignment — with no page claiming unsupported Windows parity.

**Expected Outcomes** (scenarios anchor via `[OC<NN>]`):

- [OC01] A Windows user reading the guide finds install/upgrade, smoke validation, provider setup, and an accurate capability/degradation matrix (supported / degraded / unavailable / unverified + remediation); no page claims Windows parity for container isolation, bash steps, channel sidecars, or provider sandboxing.
- [OC02] Architecture documentation describes the platform capability surface and the Windows-specific process-lifecycle, config-reload, and storage constraints so contributors understand the seam instead of re-discovering scattered `Platform.isWindows` behavior.
- [OC03] Planning documents agree that Windows support is 0.21, Workflow DSL v2 is 0.24, and Dynamic Workflows is 0.25 across both repos, Workflow DSL v2 planning treats 0.21's Git Bash behavior as the Windows baseline, and `STATE.md` / `ROADMAP.md` / `feature-comparison.md` reflect the completed milestone.
- [OC04] The platform capability surface and the Windows container-isolation deferral are captured in ADR(s), so the durable architectural rationale is discoverable.


## Required Context

> Load-bearing upstream spans inlined verbatim. Binding constraints flow from `plan.json`; behavioral doc-truths flow from the PRD FR11 acceptance criteria and sibling-story shipped contracts.

### From `docs/specs/0.21/prd.md` – "FR11: Windows Documentation and Capability Matrix"
<!-- source: docs/specs/0.21/prd.md#fr11-windows-documentation-and-capability-matrix -->
<!-- extracted: ad8e7b9 -->
> **Acceptance Criteria**:
> - [ ] User guide documents Windows install, upgrade, smoke validation, provider setup caveats, and capability/degradation matrix.
> - [ ] User guide documents Codex project-trust setup on Windows and explains warnings when project-local `.codex` config, hooks, or exec policy are disabled.
> - [ ] Architecture docs describe the platform capability surface and Windows-specific process/storage constraints where relevant.
> - [ ] Public and private roadmap summaries agree that Windows support is 0.21, Workflow DSL v2 is 0.24, and Dynamic Workflows is 0.25.
> - [ ] Workflow DSL v2 planning docs treat 0.21's Git Bash behavior as the Windows baseline and scope later `script:` work to polyglot runtime declarations, capability warnings, and any additional shell portability decisions.
> - [ ] `STATE.md`, `ROADMAP.md`, and `feature-comparison.md` are updated at milestone completion.
> - [ ] Any ADR needed for the platform capability surface or Windows isolation deferral is added or updated.
>
> **Validation**: Documentation review confirms no page claims unsupported Windows parity for container isolation, bash steps, channel sidecars, or provider sandboxing.
> **Error Handling**: If a feature remains unverified on Windows, docs label it unverified or unavailable rather than omitting the limitation.

### From `plan.json` – bindingConstraint FR3 (config reload)
<!-- source: docs/specs/0.21/prd.md#fr3-cross-platform-config-reload -->
> POSIX SIGUSR1 behavior remains available and regression-tested.

Reconciled shipped mechanism (S04 FIS): Windows-supported reload is the file-watch path (`gateway.reload.mode: auto`); SIGUSR1 stays POSIX-only and signal-triggered reload on Windows returns a POSIX-only message pointing at the file-watch mechanism. Reload docs must name this exact per-platform contract, identical to S09 smoke coverage.

### From `plan.json` – bindingConstraint FR5 (FTS5 SQLite)
<!-- source: docs/specs/0.21/prd.md#key-constraints-assumptions--dependencies -->
> DartClaw search requires FTS5. Windows must not depend on system `winsqlite3.dll`.

### From `plan.json` – bindingConstraint FR8 (smoke evidence)
<!-- source: docs/specs/0.21/prd.md#fr8-windows-runtime-smoke-test -->
> Release readiness requires the Windows smoke path to pass. Credential-only CI skips are acceptable only when recorded manual evidence covers the same provider checks for both Claude and Codex, including OS/arch, provider versions, artifact or source under test, and turn results.

### From `plan.json` – bindingConstraint FR10 (bash degradation)
<!-- source: docs/specs/0.21/prd.md#fr10-explicit-bash-step-degradation -->
> Missing bash fails the step explicitly and preserves workflow error reporting; it never returns an empty success result.

### From `plan.json` – bindingConstraint FR4 (packaging unchanged)
<!-- source: docs/specs/0.21/prd.md#fr4-windows-release-artifact -->
> Existing macOS/Linux artifacts and packaging behavior remain unchanged.

### Pre-resolved sibling-story contracts (document these exact facts)
<!-- source: docs/specs/0.21/plan.json#sharedDecisions -->
- **Windows release asset name**: `dartclaw-v<version>-windows-x64.zip` (v-prefixed, per S02 FIS + sharedDecision "Windows artifact naming and bundle layout"). The PRD FR4 gloss `dartclaw-<version>-windows-x64.zip` is un-prefixed and is reconciled to the v-prefixed form — install docs use the v-prefixed name.
- **Install paths (S08)**: `install.ps1` (downloads the zip, installs `dartclaw.exe` + DLLs together, records a persistent user PATH entry) and a Scoop manifest installing the same asset. macOS/Linux stay Homebrew — the existing "Homebrew is the only package manager" claim is now Windows-inaccurate and must be corrected to a per-platform statement.
- **Platform capability surface (S01)**: single documented surface in `dartclaw_config` covering home-directory resolution (`HOME` → `USERPROFILE` fallback), executable lookup, shell availability, process termination semantics, file-permission capability, and feature availability, plus a structured unsupported-capability error (names the capability, includes attempted context, points at remediation).
- **Config reload (S04)**: file-watch `auto` mode is the Windows-supported reload path; SIGUSR1 POSIX-only.
- **Container isolation (S05)**: unavailable on native Windows; enabling it returns an actionable unsupported-feature error naming the capability and pointing to POSIX/WSL. POSIX unaffected.
- **Bash steps (S06)**: run through Git Bash when `bash.exe` is detected; otherwise fail with "bash steps require Git Bash on Windows" — never an empty success.
- **Process lifecycle (S03)**: `Process.kill()` is a hard terminate on Windows; harness-pool shutdown does not rely on SIGTERM/SIGKILL semantics.


## Deeper Context

- `docs/specs/0.21/s04-cross-platform-config-reload.md#acceptance-scenarios` – exact reload wording (`gateway.reload.mode: auto`, POSIX-only message) to mirror in reload docs.
- `docs/specs/0.21/s01-platform-capability-surface.md` – capability surface shape + error contract for the architecture-doc description.
- `docs/specs/0.21/s05-explicit-container-isolation-degradation.md` / `s02-windows-release-artifact-fts5-sqlite.md` – isolation-unavailable and asset/FTS5 contracts.
- `../dartclaw-public/dev/adrs/015-container-isolation-strategy.md`, `012-per-type-container-isolation.md` – existing isolation ADRs to update for the Windows deferral.
- `../dartclaw-public/dev/adrs/038-homebrew-formula-publication.md` – distribution-ADR precedent/style if a capability-surface ADR is authored.
- `../dartclaw-public/docs/guide/getting-started.md#install-dartclaw`, `deployment.md` – install surfaces carrying the Homebrew-only claim.
- `docs/specs/feature-comparison.md#deployment` (line ~415), Install row (line ~22), Phase Coverage Summary (line ~628) – rows to update for Windows.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01] Windows install + upgrade documented with the correct asset name**
  - **Given** the user guide install/upgrade pages
  - **When** a Windows reader looks for how to install and upgrade DartClaw
  - **Then** the guide documents `install.ps1` and Scoop, the default root `%LOCALAPPDATA%\Programs\DartClaw`, its `bin` PATH entry, and the v-prefixed asset; the previous Homebrew-only claim becomes a per-platform statement without altering macOS/Linux instructions

- [x] **S02 [OC01] [TI02] Capability/degradation matrix is present and complete**
  - **Given** the Windows user-guide page
  - **When** the reader consults the capability matrix
  - **Then** it lists each of container isolation (unavailable → POSIX/WSL), bash workflow steps (degraded → Git Bash), config reload (supported via file-watch `auto`; SIGUSR1 POSIX-only), FTS5 storage/search (supported), and channel sidecars / provider sandbox parity (unavailable or documented-not-solved), each with an explicit state from {supported, degraded, unavailable, unverified} and remediation text

- [x] **S03 [OC01] [TI03] Smoke validation and provider setup caveats documented, including Codex project-trust**
  - **Given** the Windows user-guide page
  - **When** the reader looks for verification and provider setup
  - **Then** it documents the Windows smoke validation profile (server startup, Web UI, FTS5 search, config reload, Claude/Codex turns) including the recorded-manual-evidence rule for credential-gated CI, and documents Codex project-trust setup — the warning when project-local `.codex` config, hooks, or exec policy are disabled and the `~/.codex/config.toml` trust remediation

- [x] **S04 [OC01] [TI01,TI02,TI03] No page claims unsupported Windows parity**
  - **Given** the full public user guide after edits
  - **When** documentation is reviewed for parity claims
  - **Then** no page asserts Windows support for container isolation, bash steps without Git Bash, channel sidecars, or provider sandbox parity; unverified features are labeled unverified/unavailable rather than omitted

- [x] **S05 [OC02] [TI04] Architecture docs describe the capability surface and Windows constraints**
  - **Given** the architecture deep-dive documentation
  - **When** a contributor reads about platform behavior
  - **Then** it describes the platform capability surface (home resolution, executable lookup, shell/signal/file-permission capability, feature availability, structured unsupported-capability error) and the Windows-specific process-lifecycle (hard terminate), config-reload (file-watch `auto`), and storage (bundled FTS5 SQLite, no `winsqlite3.dll`) constraints, with the "Current through" marker bumped to 0.21

- [x] **S06 [OC03] [TI05] Workflow docs treat Git Bash as the Windows baseline**
  - **Given** the workflows user guide and the `docs/specs/0.24/workflow-dsl-v2.md` planning doc
  - **When** a reader looks at bash-step behavior on Windows
  - **Then** the workflows guide states bash steps require Git Bash on Windows (with the failure message), and the Workflow DSL v2 planning doc records 0.21's Git Bash behavior as the Windows baseline and scopes later `script:` work to polyglot runtime declarations / capability warnings / shell-portability decisions

- [x] **S07 [OC03] [TI06] Roadmap and milestone state aligned across both repos**
  - **Given** private `docs/ROADMAP.md`, public `../dartclaw-public/dev/state/ROADMAP.md`, `STATE.md`, and `docs/specs/feature-comparison.md`
  - **When** the milestone completes
  - **Then** all agree Windows support = 0.21, Workflow DSL v2 = 0.24, and Dynamic Workflows = 0.25, `STATE.md` reflects 0.21 completion, and `feature-comparison.md` records Windows x64 support (Install/Deployment rows + a 0.21 phase-coverage entry)

- [x] **S08 [OC04] [TI07] Capability-surface and isolation-deferral ADR coverage exists**
  - **Given** `../dartclaw-public/dev/adrs/`
  - **When** a contributor looks for the rationale behind the platform capability surface and Windows isolation unavailability
  - **Then** ADR-049 captures the typed platform capability surface decision, and ADR-015 records the native-Windows container-isolation deferral, each with status/date and rationale


## Structural Criteria

- [x] No user-facing page (user guide, CHANGELOG, README) references 0.21 story IDs or plan artifacts — audience rule per CLAUDE.md (development docs are exempt).
- [x] Existing macOS/Linux install and packaging instructions remain substantively unchanged (additive Windows edits only) — FR4 packaging-unchanged constraint.
- [x] Every occurrence of the Windows asset name in docs uses the v-prefixed form `dartclaw-v<version>-windows-x64.zip`.
- [x] Reload documentation names the same per-platform mechanism as S04/S09 (file-watch `auto` on Windows, SIGUSR1 POSIX-only) — no divergence.


## Scope & Boundaries

### Work Areas
- **User-guide install/upgrade** – `getting-started.md`, `deployment.md`, `cli-reference.md`: add Windows PowerShell + Scoop paths; correct the Homebrew-only claim.
- **User-guide Windows page** – new/extended page carrying the capability/degradation matrix, smoke validation profile, provider setup caveats, and Codex project-trust setup.
- **Workflow docs** – `workflows.md` bash-step Windows behavior; `docs/specs/0.24/workflow-dsl-v2.md` Git Bash baseline.
- **Architecture deep-dives** – capability surface + Windows process/reload/storage constraints; bump "Current through" marker.
- **Roadmap alignment** – private `docs/ROADMAP.md` + public `../dartclaw-public/dev/state/ROADMAP.md`.
- **Milestone state** – `../dartclaw-public/dev/state/STATE.md`, `docs/specs/feature-comparison.md`.
- **ADRs** – platform capability surface ADR + Windows container-isolation deferral (new or update to existing isolation ADR).

### What We're NOT Doing
- No behavior/code changes — this is a documentation-only story; the shipped behavior lands in S01–S09.
- No new wireframes or UI surfaces — the PRD confirms no new primary UI is required on Windows.
- No winget/Chocolatey/ARM64 documentation — those are out of the 0.21 milestone scope.
- No PowerShell/polyglot `script:` semantics doc beyond naming Git Bash as the baseline — that belongs to the 0.24 Workflow DSL v2 milestone.

## Architecture Decision

**Approach**: Documentation-only synchronization pass across public user guide, public architecture deep-dives + ADRs, and private planning docs (roadmap, STATE mirror, feature-comparison), driven by the shipped S01–S09 contracts and the FR11 acceptance criteria; honesty over completeness — unverified features are labeled, never omitted.

## Code Patterns & External References

```
# type | path#anchor                                              | why needed (intent)
file   | ../dartclaw-public/docs/guide/getting-started.md#install-dartclaw | Homebrew-only claim + install layout to correct/extend
file   | ../dartclaw-public/docs/guide/deployment.md              | second Homebrew-only claim; service-install surface
file   | ../dartclaw-public/docs/guide/workflows.md               | bash-step section to annotate with Windows/Git Bash behavior
file   | docs/specs/0.21/s04-cross-platform-config-reload.md      | exact reload mechanism wording to mirror
file   | ../dartclaw-public/dev/adrs/038-homebrew-formula-publication.md | ADR style/precedent for a distribution/capability ADR
file   | docs/specs/feature-comparison.md                         | Install/Deployment rows + Phase Coverage entry for Windows
```

## Constraints & Gotchas

- **Constraint**: Docs must reflect actually-shipped behavior — verify each claim against the merged S01–S09 implementation before writing, not against the PRD's intent. If a feature is unverified at doc time, label it unverified rather than asserting support.
- **Avoid**: Copying the PRD's un-prefixed asset name `dartclaw-<version>-windows-x64.zip` — Instead: use the v-prefixed `dartclaw-v<version>-windows-x64.zip` (S02 reconciliation).
- **Avoid**: Leaving the "Homebrew is the only package manager" claim (present in both `getting-started.md` and `deployment.md`) — Instead: make it per-platform.
- **Constraint**: Both roadmaps + STATE mirror live in the public repo except private `docs/ROADMAP.md`; the private↔public roadmap pair must stay consistent per PUBLIC_REPO_SYNC_RULES.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** User-guide install/upgrade pages document the Windows PowerShell + Scoop paths and correct the Homebrew-only claim
  - Edit `getting-started.md` and `deployment.md`: add `install.ps1` + Scoop install/upgrade; state `%LOCALAPPDATA%\Programs\DartClaw` as the default root and `<root>\bin` as the PATH entry; reference the v-prefixed asset; replace the Homebrew-only sentence with a per-platform statement.
  - **Verify**: `Inspection: Windows docs name install.ps1, Scoop, exact default root + bin PATH, and v-prefixed asset; no unqualified Homebrew-only claim remains`

- [x] **TI02** A Windows capability/degradation matrix exists on a user-guide page
  - Table with columns state {supported|degraded|unavailable|unverified} + remediation, covering container isolation, bash steps, config reload, FTS5 search, channel sidecars, provider sandbox; matrix states match shipped S03/S04/S05/S06 behavior
  - **Verify**: `Inspection: matrix present; each of the six capabilities has an explicit state + remediation; container isolation = unavailable→POSIX/WSL, bash = degraded→Git Bash, reload = supported (auto) + SIGUSR1 POSIX-only`

- [x] **TI03** Windows smoke validation + provider setup + Codex project-trust documented
  - Document the smoke profile layers and the recorded-manual-evidence rule for both providers; document Codex project-trust warning + `~/.codex/config.toml` remediation
  - **Verify**: `Inspection: page names server/UI/FTS5/reload/Claude+Codex smoke layers, the manual-evidence rule, and Codex project-trust setup`

- [x] **TI04** Architecture deep-dive describes the capability surface and Windows constraints
  - Describe the `dartclaw_config` platform capability surface (home resolution, executable lookup, shell/signal/file-permission capability, feature availability, structured error) + hard-terminate lifecycle, file-watch reload, bundled FTS5 SQLite; bump the doc's "Current through" marker to 0.21
  - **Verify**: `Inspection: architecture doc references the capability surface + the three Windows constraints; "Current through" marker reads 0.21`

- [x] **TI05** Workflow docs treat Git Bash as the Windows baseline
  - Annotate `workflows.md` bash-step section with the Windows/Git Bash requirement + failure message; update `docs/specs/0.24/workflow-dsl-v2.md` to record 0.21 Git Bash as the Windows baseline and scope later `script:` to polyglot runtime/capability-warning/portability decisions
  - **Verify**: `Inspection: workflows.md states bash requires Git Bash on Windows; workflow-dsl-v2.md names 0.21 Git Bash baseline`

- [x] **TI06** Roadmaps, STATE, and feature-comparison agree on 0.21 (Windows) / 0.24 (DSL v2) / 0.25 (Dynamic Workflows) and record Windows support
  - Align private `docs/ROADMAP.md` + public `dev/state/ROADMAP.md` (Windows=0.21, DSL v2=0.24, Dynamic Workflows=0.25); update `STATE.md` to 0.21 completion; add Windows x64 to `feature-comparison.md` Install/Deployment rows + a 0.21 phase-coverage entry
  - **Verify**: `Inspection: both roadmaps + STATE + feature-comparison consistently show Windows=0.21 / DSL v2=0.24 / Dynamic Workflows=0.25 and a Windows x64 support entry`

- [x] **TI07** ADR coverage for the capability surface and Windows isolation deferral exists
  - Keep accepted ADR-049 as the capability-surface record and ADR-015's 2026-07-11 amendment as the native-Windows isolation-deferral record.
  - **Verify**: `Inspection: ADR-049 documents the typed platform capability surface; ADR-015 captures native-Windows unavailability, POSIX/WSL remediation, and reopening conditions`

### Validation
- Documentation review (FR11 validation): confirm no page claims unsupported Windows parity for container isolation, bash steps, channel sidecars, or provider sandboxing.


## Final Validation Checklist
- [x] No user-facing page references 0.21 story IDs or transient plan artifacts.
- [x] Every Windows asset-name reference is v-prefixed and reload docs match the S04/S09 mechanism.


## Implementation Observations

_No observations recorded yet._
