# Scoping Brief: Windows Validation Spikes (S0a + S0b) – gate-only

**Status**: Complete – gating evidence for [0.21 Windows Support](prd-brief.md)
**Date**: 2026-06-09
**Relation**: Standalone, gate-only slice of the Windows PRD. Resolves the two make-or-break unknowns **before** committing to Phase A/B/C/D. No production code, no Windows release.

## Why this exists

The full PRD gates everything on two validation spikes. This brief lets us run *only* those spikes as a tiny, throwaway effort and decide — with evidence — whether the Windows scope is worth committing. If either spike fails, we stop and reassess scope (per PRD § Validation spikes).

**Output is a decision, not a feature**: a documented PASS/FAIL per spike with evidence and any newly-discovered gaps.

## Where to run — route per spike

The two spikes have different arch-sensitivity, so they route to different environments.

- **S0a → GitHub Actions `windows-latest` (x64).** Throwaway `workflow_dispatch` workflow; artifacts/logs are the gating evidence. S0a's core question (does the `package:sqlite3` v3 build hook ship a working FTS5 DLL?) is **arch-sensitive** — prebuilt-DLL availability can differ between x64 and ARM64. `windows-latest` is x64, matching the PRD's x64-first target.
  - **Do not gate S0a on an Apple-Silicon Parallels VM**: Parallels on Apple Silicon runs Windows-on-**ARM64** (the deferred arch). An ARM64 result can be a false negative (no ARM64 prebuilt) or false positive (x64 path differs); building x64 under emulation is non-representative. The VM is fine for a quick *indicative* poke only — not the gating answer.
- **S0b → a local Windows VM (e.g. Parallels) is fine, even preferable.** CRLF/line-ending and JSON-RPC transport behavior is **arch-agnostic** (Windows console/process semantics), so ARM64 vs x64 is immaterial, and the VM already has `claude`/`codex` installed + authenticated — avoiding CI-secret setup. Record the VM's arch in the findings. `windows-latest` + secrets remains an option if you prefer reproducible CI evidence.

## S0a — Build toolchain + FTS5 spike

**Question**: Can we produce a working `dartclaw.exe` + `sqlite3.dll` on a Windows runner with **FTS5** present, given the `package:sqlite3` v3 build hook?

**Setup**
- Build in sqlite3 **bundled** mode (default), NOT `source: system`. The `apps/dartclaw_cli/pubspec.yaml` `hooks.user_defines.sqlite3.source: system` escape hatch must be overridden/absent for Windows so the v3 build hook downloads the prebuilt DLL. (`source: system` → `winsqlite3.dll`, no FTS5 guarantee — the F06 risk.)

**Steps**
1. Checkout, install Dart on `windows-latest`.
2. `dart pub get`.
3. Build with `dart build cli` (the PRD-hypothesized command — `dart compile exe` is expected to fail when build hooks are present; confirming the correct command **is part of the spike**).
4. Confirm the build emits `dartclaw.exe` and a co-located `sqlite3.dll`.
5. Run a minimal FTS5 probe against the shipped sqlite3:
   - `PRAGMA compile_options;` includes `ENABLE_FTS5`.
   - `CREATE VIRTUAL TABLE t USING fts5(x); INSERT …; SELECT … MATCH …;` round-trips.
6. Upload `dartclaw.exe` + `sqlite3.dll` as a CI artifact.

**PASS criteria**
- A runnable `dartclaw.exe` is produced on `windows-latest`.
- `sqlite3.dll` ships alongside it and loads.
- `ENABLE_FTS5` present in `compile_options` AND a functional FTS5 query succeeds.

**Decision rule**: If FTS5 is absent or the toolchain can't produce a working exe, **stop** — search is non-negotiable; the Windows scope needs rework before any Phase B.

## S0b — Harness stdio spike

**Question**: Does the JSONL / JSON-RPC harness transport round-trip over native-Windows process stdio, and do CRLF line endings appear / get tolerated?

**Setup (de-risk in two steps)**
1. **Parser-tolerance (no auth, runs anywhere)**: drive a tiny fake process that emits the provider's line protocol with **CRLF** endings; confirm the existing JSONL / JSON-RPC line parser tolerates `\r\n`. This isolates "our transport handles CRLF" from provider auth.
2. **Real binary (on `windows-latest`, creds as secrets)**: install `claude` + `codex` on the runner, authenticate via repo secrets, and drive:
   - `claude --output-format stream-json` (JSONL), and
   - `codex app-server --listen stdio://` (bidirectional JSON-RPC)
   from a Dart Win32 process. Inspect **raw** bytes for CRLF vs LF; confirm a full prompt→response turn round-trips.

**PASS criteria**
- The line parser handles CRLF (step 1).
- At least one real provider completes a turn over stdio on Windows without parse/transport errors (step 2); line-ending behavior documented.

**Decision rule**: If CRLF breaks the parser, it's a small, known fix (note it). If native-Windows provider stdio is fundamentally broken (e.g. provider requires WSL), record that as a capability constraint feeding Phase C/D — it may narrow the first Windows target (e.g. host-only vs workflow-runner).

## Deliverables

- Throwaway `windows-spike.yml` (`workflow_dispatch`) — deleted or kept disabled after the spikes.
- A short findings note per spike (outcome, evidence/log links, newly-found gaps) appended to or linked from this brief and the [research doc](../../research/windows-cross-platform-support/research.md).
- A go / no-go / narrow-scope recommendation for the full Windows PRD.

## Explicitly out of scope

- No `PlatformService` seam, no hot-reload rework, no `HOME` cleanup (that's Phase A).
- No packaging, `install.ps1`, Scoop, or release-asset wiring (Phase B).
- No production code changes beyond a throwaway CI workflow and, if needed, a documented one-line parser CRLF note.
- No commitment to Windows as a supported target — that decision follows the spike outcomes.

## S0a findings

**Date**: 2026-06-10 · **Outcome: PASS (all criteria)** — `windows-latest` (x64, Windows Server 2025), Dart SDK 3.12.0, sqlite3 3.3.2.

| Criterion | Result | Evidence |
|---|---|---|
| Runnable `dartclaw.exe` produced | **PASS** | `dart build cli` exit 0 → `build/cli/windows_x64/bundle/bin/dartclaw.exe`; `--help` runs, exit 0 |
| sqlite DLL ships alongside + loads | **PASS** | `bundle/lib/sqlite3.dll` (hook-downloaded prebuilt, sqlite 3.53.1); loads via `DynamicLibrary.open` |
| `ENABLE_FTS5` + functional MATCH | **PASS** | Probed twice: via `package:sqlite3` under `dart run` (hook artifact confirmed loaded via `K32EnumProcessModules`) AND via raw `dart:ffi` against the *shipped* bundle DLL — `sqlite3_compileoption_used('ENABLE_FTS5')` = 1, `CREATE VIRTUAL TABLE … USING fts5` + `MATCH` round-trip returns the row |

**Working build command**: `dart build cli` (run from `apps/dartclaw_cli/`). Confirmed stable since Dart 3.10 — no `--enable-experiment` flag, no pubspec opt-in. Bundle layout: `build/cli/<os>_<arch>/bundle/bin/<exe>` + `bundle/lib/<dlls>`. `dart compile exe` remains a non-option with build hooks present, as hypothesized.

**Newly-found gap (feeds F06)**: `hooks.user_defines.sqlite3.source: system` exists in **both** the workspace root `pubspec.yaml` and `apps/dartclaw_cli/pubspec.yaml`, and in a pub workspace the hook honors the **workspace root's** user_defines. Runs 1–2 stripped only the app pubspec: the hook emitted `DynamicLoadingSystem('sqlite3.dll')` — nothing bundled, and the FTS5 probe *appeared* to pass because a stray sqlite3.dll (3.50.4) on the runner's PATH was silently loaded. The F06 per-platform source-mode override must neutralize the root-pubspec block, and the planned FTS5 test assertion should also verify *which* module loaded, not just that FTS5 answers.

**Evidence runs** (workflow `windows-spike.yml` on `feat/0.18`; artifacts `windows-spike-s0a` contain exe + dll):
- All-PASS, fully bundled mode: [run 27254681527](https://github.com/DartClaw/dartclaw/actions/runs/27254681527)
- Reproduced from final manual-dispatch-only workflow state: [run 27254806319](https://github.com/DartClaw/dartclaw/actions/runs/27254806319)
- Diagnostic runs (root-pubspec `source: system` still active — the gap above): [27254304689](https://github.com/DartClaw/dartclaw/actions/runs/27254304689), [27254534997](https://github.com/DartClaw/dartclaw/actions/runs/27254534997)

CI note: a `workflow_dispatch`-only workflow on a non-default branch is not dispatchable until GitHub registers it; a temporary branch+path-scoped `push` trigger bootstrapped registration and was removed after — the committed workflow is manual-dispatch-only.

**Recommendation**: **Go** on the S0a gate — toolchain and FTS5 are not blockers; the PRD's Phase A/B technical premises (build command, bundled source-mode, bundle layout for F05–F08 packaging) are confirmed. Per the decision rules, full go/no-go for the Windows PRD awaits S0b (harness stdio), which remains open.

## S0b step 1 findings (parser CRLF tolerance)

**Date**: 2026-06-10 · **Outcome: PASS (13/13 checks)** — `windows-latest` (x64), Dart SDK 3.12.0. Run via a second job in the same throwaway workflow (no auth/secrets needed). Evidence: [run 27273422931](https://github.com/DartClaw/dartclaw/actions/runs/27273422931).

**What was tested**: a fake provider child process spawned over real Win32 pipes, emitting JSONL (claude stream-json shape) and bidirectional JSON-RPC (codex app-server shape) with explicit `\r\n` line endings — parsed with a verbatim replica of the production byte→line chain (`utf8.decoder | LineSplitter | where(isNotEmpty)` from `dartclaw_core` `base_harness.attachProcess`, also used by `bridge/ndjson_channel.dart` for ACP).

| Check | Result |
|---|---|
| CRLF traverses the Win32 pipe untranslated (raw-byte inspection) | PASS |
| Parsed lines carry no trailing `\r`; all JSON-decode cleanly | PASS |
| Empty CRLF line dropped, not crashed on | PASS |
| Identical result when `\r\n` is split across chunk boundaries | PASS |
| Child side parses CRLF-terminated stdin lines cleanly (bidirectional) | PASS |
| JSON-RPC request→response round-trip with CRLF both ways | PASS |

**Why it holds by construction**: every stdio byte→line boundary in the codebase goes through `dart:convert`'s `LineSplitter`, which handles `\r\n`/`\r`/`\n` per spec — no hand-rolled `split('\n')` in the transport path. The CI run makes that empirical rather than a code-reading claim. No parser fix needed (the brief's "small, known fix" contingency is moot).

**Still open — S0b step 2**: a real `claude --output-format stream-json` / `codex app-server` turn over native-Windows stdio, to be run on the local Parallels VM (already authenticated; arch-agnostic per this brief, record VM arch in findings). Decided 2026-06-10: hybrid route — step 1 in CI (above), step 2 on the VM rather than putting provider API keys into Actions secrets. Step 2 is the remaining gate input for the full Windows PRD go/no-go.

## S0b step 2 findings (real provider turns over native-Windows stdio)

**Date**: 2026-06-11 · **Outcome: PASS — both providers.** VM: Parallels on Apple Silicon, **Windows 11 Pro 26100, ARM64**; Dart 3.12.1 (native `windows_arm64`); `claude` 2.1.172; `codex-cli` 0.139.0. Driver: [s0b-step2-probe/](s0b-step2-probe/) (`s0b_step2_probe.dart`); raw evidence captured to `s0b2-output.txt` / `s0b2-codex-output.txt` on the VM.

| Provider | Transport | Turn result | Line endings on the wire |
|---|---|---|---|
| `claude --print --input-format stream-json --output-format stream-json` | JSONL over stdio | **PASS** — `system` init + assistant "pong" + `result` `is_error=false`; 12 lines, all parse | **lone LF only — 0 CRLF** |
| `codex app-server` | bidirectional JSON-RPC over stdio | **PASS** — `initialize`→`thread/start`→`turn/start`→`turn/completed` (6.8s), `agentMessage` delta "pong"; 21 lines, all parse | **lone LF only — 0 CRLF** |

**Core finding (answers the S0b question)**: native-Windows `claude` and `codex` both emit **LF line endings with zero CRLF** on stdout. The feared CRLF does not appear in practice; and S0b step 1 already proved the parser tolerates CRLF if it ever did. The JSONL / JSON-RPC transport round-trips cleanly over native-Windows process stdio with no parse or transport errors. **No CRLF handling change is needed in the harness or parser** — the brief's "small, known fix" contingency is fully moot.

**Newly-found notes (feed Phase C / F09 — none are S0b blockers):**
- **codex `turn/start` `sandboxPolicy.type` is camelCase** (`readOnly` / `workspaceWrite` / `dangerFullAccess` / `externalSandbox`), distinct from the kebab-case `sandbox` field on `thread/start`. `codex_protocol_adapter.dart` already passes turn values through verbatim and its comment documents the casing split — confirmed correct against codex-cli 0.139.0. (The probe initially sent kebab-case `read-only` and got `-32600 unknown variant`; that was a probe bug, since fixed, not a DartClaw bug.) F09 should add a codex-version-compat check — the app-server protocol is still moving.
- **codex emits many notification methods the adapter doesn't explicitly handle** (`thread/started`, `mcpServer/startupStatus/updated`, `thread/status/changed`, `turn/started`, `item/started`, `thread/tokenUsage/updated`, `account/rateLimits/updated`). `parseLine`'s switch falls through to `null` for unknown methods, so all 21 lines parsed and nothing crashed — forward-compat holds. Noted for awareness; no action required.
- **One codex built-in MCP server (`node_repl`) failed to start on Windows ARM64** ("handshaking with MCP server failed: connection closed: initialize response"); `codex_apps` started fine and the turn completed regardless. Codex-side, not DartClaw — but if any workflow depends on `node_repl`, it's a Windows-ARM64 codex gap to track.
- **codex project-trust on Windows**: an untrusted project folder emits a `configWarning` and disables project-local `.codex` config/hooks/exec policies (skills still load); the turn completes regardless. Phase D doc note: Windows users wanting project-local codex config must add the project as trusted in `~/.codex/config.toml`.
- **Native ARM64 Dart SDK works**: 3.12.1 ran natively as `windows_arm64` (not x64 emulation). Additive data point for the deferred "ARM64 Windows binary" item — the toolchain runs on arm64, though S0a's build + FTS5 evidence remains x64-only.

**VM arch recorded**: Windows 11 ARM64 (Parallels / Apple Silicon). Per this brief, S0b is arch-agnostic (console/process semantics), so the result is representative for the LF/CRLF and transport questions regardless of x64 vs ARM64.

## Overall go/no-go (both spikes resolved)

Both gating spikes **PASS**; neither "stop and reassess" decision rule was triggered.

- **S0a (build toolchain + FTS5)** — **GO**. `dart build cli` produces a working `dartclaw.exe` + bundled FTS5-enabled `sqlite3.dll` on `windows-latest` x64. Confirmed in shipped-bundle FFI probe.
- **S0b (harness stdio)** — **GO**. Parser tolerates CRLF (step 1, CI) and both real providers complete turns over native-Windows stdio emitting LF (step 2, VM).

**Recommendation: GO on the full Windows PRD** (Phases A–D), with **no scope rework required by the spikes**. Carry these confirmed inputs into planning:
- **F06**: the per-platform sqlite3 source-mode override must neutralize the `source: system` block in **both** the workspace-root and CLI-app pubspecs (S0a finding); add an FTS5 assertion that also checks *which* module loaded.
- **F09**: codex app-server protocol is moving (0.139.0) — add a version-compat check; the camelCase/kebab-case sandbox-policy split and the unknown-notification fallthrough both already work but warrant a regression test. Track the `node_repl` MCP-on-Windows-ARM64 failure.
- **F05/F07**: build command and bundle layout (`build/cli/<os>_<arch>/bundle/{bin,lib}`) confirmed for packaging.

The throwaway `windows-spike.yml` (S0a + S0b-step-1 jobs) and this VM probe have served their purpose and can be removed once the PRD is scheduled.
