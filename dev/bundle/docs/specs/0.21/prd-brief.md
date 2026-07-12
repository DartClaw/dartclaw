# Product Requirements Document: DartClaw 0.21 – Windows Support & Cross-Platform Hardening

**Status**: Scheduled brief – planned 0.21
**Date**: 2026-06-01
**Research**: [windows-cross-platform-support](../../research/windows-cross-platform-support/research.md)

> **Framing**: This is now the planned 0.21 milestone. The two front-loaded validation spikes (build toolchain, harness stdio) have both passed, so the remaining work is implementation planning. Title spans Windows support *and* the cross-platform abstraction work that enables it; future non-POSIX targets benefit from the same abstraction.

## Executive Summary

- **Project**: DartClaw — Windows binary + cross-platform hardening
- **Problem**: DartClaw ships only macOS + Linux binaries. Windows users cannot run the host at all. The runtime is already largely portable (Dart AOT, most platform hot-spots already guarded), but build/distribution, config hot-reload, storage source-mode, and a few Unix-coupled features (container isolation, bash workflow steps) block a usable Windows release.
- **Vision**: A native Windows binary that runs DartClaw's **core orchestration** (serve, Web UI, harness pool, sessions, storage/search, workflows-minus-bash) with first-class install UX, while *explicitly and gracefully degrading* the genuinely Unix-coupled features rather than blocking on them.
- **Target Users**: Windows-based developers and operators who want to run DartClaw locally without WSL.
- **Success Criteria**: See [Success Criteria](#success-criteria).
- **Philosophy**: Don't chase parity. Ship the 80% that ports cleanly with a great install experience; mark the Unix-coupled 20% (container isolation, bash steps) as unavailable-on-Windows with clear errors and docs. Build the platform abstraction once, correctly.

**Prerequisites**: Validation spikes S0a + S0b (below) passed. No hard dependency on 0.24 Workflow DSL v2.

## Problem Definition

1. **No Windows artifact** — Dart cannot cross-compile to Windows; the binary must be built on a Windows host. There is no Windows CI job, and [build.sh](../../../../dartclaw-public/dev/tools/build.sh) is POSIX-only (bash/`uname`/`tar`).
2. **Storage source-mode** — the workspace uses `sqlite3` `source: system` (a macOS codesigning escape hatch). On Windows that targets the ancient `winsqlite3.dll` with no FTS5 guarantee; DartClaw's search **requires** FTS5.
3. **Config hot-reload is signal-based** — SIGUSR1 (`reload_trigger_service.dart`) is not watchable on Windows; the hot-reload trigger is inoperative.
4. **Scattered platform handling** — Windows guards exist ad hoc across packages. There is no single platform-abstraction seam, so each new Windows concern is patched in place.
5. **Unix-coupled features have no clean Windows port** — the credential-proxy container isolation (Unix domain socket + `chmod 600`) and bash workflow steps (`/bin/sh -c`) cannot port 1:1 and currently fail or silently no-op rather than degrade explicitly.

## Scope

### Validation spikes (gate — do first)

> **Spikes resolved (2026-06-11): S0a + S0b both PASS — GO.** See [spikes-scoping-brief.md](spikes-scoping-brief.md) § Overall go/no-go. No scope rework triggered; carry the F06 (workspace-root sqlite3 source-mode) and F09 (codex app-server version-compat) findings into planning.

- **S0a — Build toolchain spike**: On a `windows-latest` runner, confirm whether `dart build cli` (vs `dart compile exe`, which fails when build hooks are present) correctly drives the `package:sqlite3` v3 build hook, downloads the prebuilt DLL, and produces a working `dartclaw.exe` + `sqlite3.dll`. Confirm FTS5 via `PRAGMA compile_options;`. _Ref: research §1.2, §2._
- **S0b — Harness stdio spike**: Drive native-Windows `claude --output-format stream-json` and `codex app-server --listen stdio://` from a Dart Win32 process; inspect raw line endings (CRLF vs LF) and confirm the JSONL/JSON-RPC transport round-trips. _Ref: research §4._

If either spike fails, stop and reassess scope.

### In Scope

**Phase A — Platform abstraction layer:**
- F01: `PlatformService` (or equivalent seam) centralizing OS-conditional behavior — home dir, executable resolution, shell selection, process-termination semantics — replacing scattered `Platform.isWindows` checks. Single place to reason about platform differences.
- F02: Process-lifecycle hardening — document/accept that `process.kill()` is a hard terminate on Windows (no SIGTERM grace); ensure harness-pool shutdown does not orphan children (ref dart-lang/sdk #49234). Add a non-signal graceful-stop path only if S0b shows harnesses need it.
- F03: Config hot-reload Windows path — replace SIGUSR1 trigger with a cross-platform mechanism (HTTP reload endpoint and/or file-sentinel watch via `FileSystemEntity.watch()`), or mark signal-trigger unavailable on Windows while keeping file-watch mode. SIGUSR1 retained on POSIX.
- F04: HOME-resolution cleanup — route `codex_environment.dart` direct `HOME` reads through `expandHome`/platform service (`HOME → USERPROFILE`).

**Phase B — Build & distribution (Windows host):**
- F05: `windows-latest` build job in [release-binaries.yml](../../../../dartclaw-public/.github/workflows/release-binaries.yml) producing `dartclaw.exe` + bundled `sqlite3.dll`.
- F06: Per-platform sqlite3 source-mode — Windows uses the **default bundled** mode (FTS5 guaranteed), not `source: system`; keep the macOS escape hatch where needed. Add an FTS5 `PRAGMA compile_options;` assertion to the test suite.
- F07: Windows packaging — `.zip` artifact + `.exe` naming alongside existing tarballs. (macOS/Linux packaging path unchanged.)
- F08: `install.ps1` (PowerShell `irm … | iex`) — arch detection, DLL placement next to exe, **persistent** PATH via `[Environment]::SetEnvironmentVariable(..., "User")` (avoid the session-only PATH bug). Plus a Scoop manifest.

**Phase C — Harness integration validation on Windows:**
- F09: Verify `claude`/`codex` native-Windows spawn through the harness pool. _S0b resolved the CRLF question: the parser already tolerates CRLF (step 1) and native providers emit LF in practice (step 2) — no parser change needed. Remaining F09 work: codex app-server version-compat (protocol drift at 0.139.0) + the `node_repl` MCP-on-Windows-ARM64 gap._ Executable resolution via platform service.
- F10: Windows smoke test (subset of UI/CLI) in CI or documented manual run: serve starts, Web UI loads, a harness turn completes, storage/search works.

**Phase D — Explicit feature degradation:**
- F11: Container isolation marked unavailable on Windows with a clear, actionable error (not a crash); `credential_proxy.dart` `chmod` path guarded. _Defer a real Windows isolation design (TCP loopback + token + ACLs) to a separate effort._
- F12: Bash workflow steps degrade explicitly on Windows — detect Git Bash `bash.exe` and use it if present; otherwise surface a clear "bash steps require Git Bash on Windows" message. _Full cross-platform shell scoped to Workflow DSL v2._
- F13: Capability/degradation matrix in the user guide — what works, what's degraded, what's unavailable on Windows, and why.

### Out of Scope (Deferred)

| Feature | Rationale | Target |
|---------|-----------|--------|
| Windows-native container isolation | Unix-socket + `chmod` credential proxy has no 1:1 Windows analogue; needs redesigned isolation (TCP loopback + token auth + Windows ACLs) | Separate effort |
| Cross-platform workflow shell (embedded POSIX interpreter / PowerShell steps) | Real design decision overlapping `script:` polyglot steps | [Workflow DSL v2](../0.24/workflow-dsl-v2.md) |
| Native-Windows harness sandboxing parity | Claude Code sandbox needs WSL2 on Windows; Codex uses AppContainer — provider-specific, not DartClaw's layer | Future |
| First-class channel sidecars on Windows | signal-cli (JRE) + gowa (WSL-recommended, FFmpeg/libwebp) work but are secondary for a first release | Future |
| winget / Chocolatey packages | Scoop + install.ps1 cover the first release; add later for discoverability | Future |
| ARM64 Windows binary | Validate x64 first; arm64 is an additive matrix entry | Follow-on |

### MVP Boundary

**Minimum viable**: Spikes + Phase A + Phase B. A Windows user can install via `install.ps1` and run `dartclaw serve` with working storage/search and harness turns. Hot-reload may be file-watch-only.

**Recommended full scope**: + Phase C (validated harness integration + smoke test) + Phase D (explicit degradation + docs). This is what makes Windows a *supported* target rather than a "compiles but rough" one.

**Phase ordering**: Spikes gate everything. A and B can largely proceed in parallel after spikes (A is code, B is CI/packaging). C depends on B (needs a runnable Windows binary). D is independent and can run alongside C.

## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As a Windows dev, I want to install DartClaw with one command | `irm <url>/install.ps1 \| iex` installs `dartclaw.exe` + `sqlite3.dll` and `dartclaw` is on PATH in a *new* terminal | P0 |
| US02 | As a Windows dev, I want `dartclaw serve` to work | Server starts, Web UI loads, storage + FTS5 search work without errors | P0 |
| US03 | As a Windows dev, I want to run agent turns | A `claude`/`codex` harness turn completes over stdio without JSONL parse errors | P0 |
| US04 | As a Windows dev, I want clear messaging when a feature isn't available | Attempting container isolation or a bash workflow step (no Git Bash) yields an explicit actionable error, not a crash or silent no-op | P1 |
| US05 | As a Windows dev, I want config changes to apply | Editing `dartclaw.yaml` with file-watch mode applies changes without restart (SIGUSR1 substitute) | P1 |
| US06 | As a maintainer, I want Windows builds in CI | Tag push produces a `dartclaw-<ver>-windows-x64.zip` release asset built on a Windows runner | P0 |

### Non-Functional Requirements

| ID | Requirement | Metric |
|----|-------------|--------|
| NF01 | FTS5 present in the shipped Windows build | `PRAGMA compile_options;` includes `ENABLE_FTS5` (asserted in tests) |
| NF02 | `dart analyze` clean across packages incl. Windows-conditional code | Zero errors/warnings |
| NF03 | No regressions on macOS/Linux | Existing test suites pass; existing build/packaging path unchanged |
| NF04 | Install script sets persistent PATH | `dartclaw` resolves in a freshly opened terminal |
| NF05 | Degraded features fail loud, not silent | Unavailable features emit explicit errors with remediation guidance |

## Technical Design Notes

- **Build**: per-OS CI runners are the only viable multi-platform strategy (no cross-compile). Windows job uses `dart build cli` (confirmed S0a — stable since Dart 3.10, no experiment flag; output `build/cli/<os>_<arch>/bundle/{bin,lib}`); macOS/Linux jobs unchanged.
- **Storage**: `user_defines.sqlite3.source` set per-platform — Windows `sqlite3` (bundled, FTS5), macOS retains the codesigning escape hatch as needed. Keep the choice in one documented place.
- **Signals**: treat `Process.kill()` as hard-terminate on Windows; gate any SIGKILL/`watch()` calls behind the platform service. Hot-reload trigger: prefer an HTTP reload endpoint + file-watch over a signal substitute (works identically across platforms).
- **Degradation pattern**: a single capability check (`PlatformCapabilities`) that the container manager, bash step runner, and channel managers consult, so "unavailable on Windows" is expressed consistently and surfaced in `dartclaw doctor` (if/when shipped) and the docs matrix.

## Success Criteria

| Criterion | Metric |
|-----------|--------|
| Windows binary builds in CI | Tagged release produces a Windows zip asset with exe + sqlite3.dll |
| Core runtime works on Windows | serve + Web UI + harness turn + FTS5 search verified on Windows |
| Install UX | `install.ps1` + Scoop manifest install and PATH-register cleanly |
| No POSIX regressions | macOS/Linux build, packaging, and tests unchanged and green |
| Honest capability surface | Documented Windows capability/degradation matrix; unavailable features error explicitly |
| Spikes resolved | S0a (build) and S0b (harness stdio) documented with outcomes |

## Milestones & Delivery

**Target**: ~8–10 stories.
- **Spikes** (S0a build, S0b harness stdio) — gate. ~2 stories.
- **Phase A** (platform abstraction, hot-reload, HOME) — ~3 stories.
- **Phase B** (Windows CI build, sqlite3 source-mode, packaging, install.ps1/Scoop) — ~3 stories.
- **Phase C** (harness validation + smoke test) — ~1 story.
- **Phase D** (degradation + docs matrix) — ~1 story.

**Documentation impact** (per repo policy, explicit doc-update stories): public user guide (install on Windows, capability matrix), architecture deep-dives (system/protocol notes on platform abstraction), `STATE.md`/`ROADMAP.md`, and `feature-comparison.md` (cross-platform row). Private: this PRD + research kept in sync; an ADR if the platform-abstraction seam or Windows-isolation deferral warrants one.

## References

- [windows-cross-platform-support research](../../research/windows-cross-platform-support/research.md) — full findings + sources + validation gaps
- [Desktop App (Tauriel) — product backlog](../../PRODUCT-BACKLOG.md) — related cross-platform desktop track (macOS first, Linux/Windows follow)
- [Workflow DSL v2](../0.24/workflow-dsl-v2.md) — owns the cross-platform `script:` shell decision
- [build.sh](../../../../dartclaw-public/dev/tools/build.sh) · [release-binaries.yml](../../../../dartclaw-public/.github/workflows/release-binaries.yml) — current build/release entry points
