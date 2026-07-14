# Native Windows Harness Validation — Feature Implementation Specification

**Plan**: docs/specs/0.21/plan.json
**Story-ID**: S07

## Feature Overview and Goal

**Intent**: Prove that DartClaw's two first-class harnesses — Claude (JSONL) and Codex (JSON-RPC app-server) — actually complete real turns through the existing harness pool on native Windows, and lock the Windows-relevant protocol behaviors the S0b spike uncovered into regression tests so Windows harness support does not silently rot on the next provider or refactor.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] Native Windows Claude and Codex each complete a full DartClaw-managed prompt/response turn through the harness pool, with recorded evidence naming OS/arch, provider versions, artifact-or-source under test, and both turn results.
- [OC02] Codex app-server protocol compatibility is regression-guarded on any host: `turn/start` carries a camelCase `sandboxPolicy.type`, and unknown notification methods are ignored without crashing the turn.
- [OC03] A Codex project-trust warning on Windows is captured and surfaced so the operator knows project-local `.codex` config, hooks, or exec policy are disabled — the turn still completes.
- [OC04] Claude and Codex validate the configured binary with a direct `--version` probe and report the attempted command through S01's structured error contract, without an ad hoc `where`/`which` helper or `Platform.isWindows` branch in the spawn path.
- [OC05] Provider authentication failures, protocol incompatibility, and MCP startup warnings remain visible as setup/compatibility information and terminate or continue the affected turn according to the provider result without corrupting later turn state.


## Required Context

> Load-bearing upstream spans inlined verbatim. The inlined text is the contract the executor builds to.

### From `prd.md` – "FR7: Native Windows Harness Validation"
<!-- source: docs/specs/0.21/prd.md#fr7-native-windows-harness-validation -->
<!-- extracted: ad8e7b9 -->
> **Description**: Validate DartClaw's Claude and Codex harness paths on native Windows, incorporating S0b findings into regression coverage.
>
> **Acceptance Criteria**:
> - Claude completes a full DartClaw-managed prompt/response turn on native Windows when configured.
> - Codex completes a full DartClaw-managed prompt/response turn on native Windows when configured.
> - Claude JSONL and Codex JSON-RPC line parsing remains tolerant of CRLF even though providers emitted LF in S0b.
> - Codex app-server protocol compatibility covers `sandboxPolicy.type` camelCase values and ignores unknown notification methods without crashing.
> - Codex Windows project-trust warnings are captured and surfaced so users know when project-local `.codex` config, hooks, or exec policy are disabled.
> - Windows executable resolution for harness binaries uses the platform capability surface.
>
> **Validation**: Windows smoke or integration evidence records provider versions, OS/arch, artifact or source under test, and both turn results. CI may skip provider-auth portions only when the skip is explicit and a manual verification profile covers the same checks for both providers.
>
> **Error Handling**: Missing binary, auth-required state, protocol mismatch, Codex project-trust warning, or MCP sidecar startup warning is surfaced as setup/compatibility information without corrupting the turn state.

### From `prd.md` – "US04" (User Stories table)
<!-- source: docs/specs/0.21/prd.md#user-stories -->
<!-- extracted: ad8e7b9 -->
> US04 | As a Windows developer, I want to run Claude and Codex turns so that Windows supports DartClaw's first-class harnesses, not just server startup. | Native Windows Claude and Codex harness turns complete through DartClaw without stdio parse or transport errors when each provider is configured. | Must / P0

### From `plan.json` – binding constraint FR8 (recorded-evidence rule; governs OC01)
<!-- source: docs/specs/0.21/prd.md#fr8-windows-runtime-smoke-test -->
<!-- extracted: ad8e7b9 -->
> Release readiness requires the Windows smoke path to pass. Credential-only CI skips are acceptable only when recorded manual evidence covers the same provider checks for both Claude and Codex, including OS/arch, provider versions, artifact or source under test, and turn results.

### From `plan.json` – shared decision "Platform capability surface API" (governs OC04)
<!-- source: docs/specs/0.21/plan.json#sharedDecisions -->
<!-- extracted: ad8e7b9 -->
> S01 defines the single documented capability surface (home-directory resolution, executable lookup, shell capability, process termination semantics, feature availability); S03, S04, S05, S06, and S07 route all Windows-specific gating and lookups through it instead of adding ad hoc `Platform.isWindows` checks.


## Deeper Context

- `docs/specs/0.21/s01-platform-capability-surface.md#code-patterns--external-references` – the S01 surface: effect-free executable candidates and the structured unsupported-capability/lookup-failure error type this story consumes for OC04.
- `docs/specs/0.21/spikes-scoping-brief.md#s0b-step-2-findings-real-provider-turns-over-native-windows-stdio` – primary evidence: both providers emit LF (0 CRLF) on native Windows; the camelCase `sandboxPolicy.type` split, the unknown-notification fallthrough, and the untrusted-project `configWarning` are the three findings this story turns into regression tests / surfaced behavior.
- `docs/specs/0.21/s0b-step2-probe/README.md#what-it-does--pass-criteria` – the exact spawn shape (CLI flags, JSONL / JSON-RPC message sequence) a native-Windows turn round-trips through; the model for the OC01 evidence run.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI06] Claude completes a native-Windows turn**
  - **Given** DartClaw running on native Windows with `claude` configured and authenticated (x64 CI or ARM64 Parallels; architecture recorded)
  - **When** a DartClaw-managed prompt/response turn is driven through the harness pool
  - **Then** the turn completes with a `result` event `is_error=false` and no stdio parse or transport error, and the evidence record names the OS/arch, `claude` version, artifact-or-source under test, and the turn result

- [x] **S02 [OC01] [TI06] Codex completes a native-Windows turn**
  - **Given** DartClaw running on native Windows with `codex` configured and authenticated (x64 CI or ARM64 Parallels; architecture recorded)
  - **When** a DartClaw-managed prompt/response turn is driven through the harness pool
  - **Then** the app-server turn reaches `turn/completed` with an assistant message and no stdio parse or transport error, and the evidence record names the OS/arch, `codex` version, artifact-or-source under test, and the turn result

- [x] **S03 [OC02] [TI01] Codex `turn/start` uses camelCase `sandboxPolicy.type`**
  - **Given** a Codex turn built with the DartClaw config sandbox value `workspace-write`
  - **When** the `turn/start` request is constructed by `CodexProtocolAdapter.buildTurnRequest`
  - **Then** its params carry `sandboxPolicy: {type: 'workspaceWrite'}` (camelCase), and the config value `danger-full-access` likewise yields `dangerFullAccess`

- [x] **S04 [OC02] [TI02] Unknown Codex notifications are ignored without crashing**
  - **Given** a running Codex harness receiving app-server notifications
  - **When** notification methods the adapter does not explicitly handle arrive on stdout (e.g. `thread/started`, a non-warning `mcpServer/startupStatus/updated`, `thread/status/changed`, `thread/tokenUsage/updated`, `account/rateLimits/updated`)
  - **Then** each line parses to a null protocol message, `handleProcessStdoutLine` performs no work and throws nothing, and an interleaved `turn/completed` still completes the turn

- [x] **S05 [OC03] [TI04] Codex project-trust warning is surfaced**
  - **Given** a Codex turn started against an untrusted project folder on Windows, where Codex emits its project-trust `configWarning` and disables project-local `.codex` config/hooks/exec policy
  - **When** the harness receives that warning notification
  - **Then** Codex logs the warning and emits `ProviderProgressBridgeEvent(kind: 'provider_setup_warning', text: …)` naming that project-local Codex config is disabled; existing `TurnRunner` forwarding exposes it as `ProviderProgressEvent`, and the turn still completes

- [x] **S06 [OC04] [TI05] Harness binary validation is platform-neutral and fail-closed**
  - **Given** Claude and Codex harnesses configured with their provider executable names
  - **When** each harness resolves/validates its configured binary at startup
  - **Then** it directly runs `<bin> --version` with no lookup-helper subprocess and no `Platform.isWindows` branch in the harness spawn/probe path

- [x] **S07 [OC04] [TI05] Missing harness binary reports the attempted lookup**
  - **Given** a Claude or Codex harness whose configured binary does not resolve
  - **When** harness startup validates the binary
  - **Then** it fails with the structured lookup error naming the binary and the attempted `<bin> --version` command, not a bare `codex binary not found` string or an unhandled process exception

- [x] **S08 [OC05] [TI07] Setup and compatibility failures remain visible without corrupting harness state**
  - **Given** a harness receives, in separate cases, an authentication-required result, a protocol-incompatibility diagnostic, or an MCP startup warning
  - **When** DartClaw handles the provider result
  - **Then** the operator-visible failure or warning preserves the provider detail; a terminal auth/protocol failure completes the affected turn as an error, a warning does not prevent normal completion, and a subsequent turn is not blocked by stale completer or parser state


## Structural Criteria

> Proved by task Verify lines, not scenarios.

- [x] Claude JSONL and Codex JSON-RPC line parsing remains CRLF-tolerant: a `\r\n`-terminated provider line (and a `\r\n` split across read chunks) parses identically to its `\n` form, with no trailing `\r` reaching the JSON decoder.
- [x] Existing `dartclaw_core` harness test suites remain green on macOS/Linux — POSIX Claude/Codex turn, adapter, and executable-probe behavior are unchanged.
- [x] No new `Platform.isWindows` branch or PATH-resolved lookup-helper subprocess is introduced in the Claude/Codex harness spawn or `--version` probe path.


## Scope & Boundaries

### Work Areas
- Codex protocol regression coverage in `dartclaw_core` (`codex_protocol_adapter.dart` `buildTurnRequest`/`parseLine`, `codex_settings.dart` sandbox translation) — camelCase `sandboxPolicy.type` and unknown-notification tolerance.
- CRLF line-parsing regression coverage over the shared `base_harness.attachProcess` byte→line chain used by both JSONL and JSON-RPC harnesses.
- Codex project-trust `configWarning` capture/surfacing in `codex_harness.dart` / `codex_protocol_adapter.dart`.
- Harness binary resolution wiring: Claude (`claude_code_harness.dart`) and Codex (`codex_harness.dart`) startup lookup routed through the S01 surface, injected via `harness_factory.dart`.
- Native-Windows turn procedure at `dev/testing/scenarios/windows-harness-turns.md` and stable latest-run record at `dev/testing/evidence/windows-harness-turns.md`, covering both providers.

### What We're NOT Doing
- The broader runtime smoke path (server startup, Web UI, FTS5 search, config reload) -- S09 owns it; S07 delivers only the two harness-turn slices and their regression tests.
- Making S07 depend on S09 for evidence – S07 owns its durable record. S09 may reuse it only when OS/architecture, artifact-or-source, and provider versions match; otherwise S09 reruns provider checks.
- Codex `HOME`→`USERPROFILE` home-directory migration -- S01 (TI03) already routes `CodexEnvironment` home resolution through the surface; S07 only touches harness *binary* lookup.
- Provider sandbox parity or a Windows-native sandbox model -- out of scope for 0.21 per PRD; the sandbox regression test locks the existing translation, it does not add Windows sandbox behavior.
- A CRLF parser fix -- S0b proved the `LineSplitter` chain already tolerates CRLF and providers emit LF; this story adds the regression guard, not a code change to parsing.
- A Codex version-negotiation/pinning mechanism -- surfacing a protocol mismatch is in scope, but choosing/enforcing a supported Codex version range is not.


## Architecture Decision

**Approach**: Encode the three S0b protocol findings as host-agnostic regression tests; recognize Codex's live-confirmed project-trust `configWarning`, log it, and emit the existing provider-neutral progress event with fixed kind `provider_setup_warning`; inject ADR-049 capabilities into Claude/Codex binary lookup; and record both real native-Windows turns in the evidence path settled by preflight.
**Why this over alternatives**: the transport already works (S0b GO), so the durable risk is silent regression, not first-time bring-up — tests that run on any host guard it cheaply, while the genuinely Windows-only parts (real turns) stay as evidence rather than being faked in CI.


## Code Patterns & External References

```
# type | path#anchor                                                                      | why needed (intent)
file   | packages/dartclaw_core/lib/src/harness/codex_protocol_adapter.dart#parseLine     | Notification switch that falls through to null for unknown methods; add configWarning recognition here
file   | packages/dartclaw_core/lib/src/harness/codex_protocol_adapter.dart#buildTurnRequest | Where sandbox setting becomes sandboxPolicy:{type:...}; target of the camelCase regression test
file   | packages/dartclaw_core/lib/src/harness/codex_settings.dart#CodexSettings         | kebab→camel sandbox translation table (workspace-write→workspaceWrite, danger-full-access→dangerFullAccess)
file   | packages/dartclaw_core/lib/src/harness/base_harness.dart#attachProcess            | Shared utf8.decoder|LineSplitter chain both harnesses parse through; CRLF regression target
file   | packages/dartclaw_core/lib/src/harness/codex_harness.dart#handleProcessStdoutLine | Codex line handling + where warnings/events are emitted; configWarning surfacing site
file   | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart                   | claudeExecutable + commandProbe(--version) startup validation to route through the surface
file   | packages/dartclaw_core/lib/src/harness/harness_factory.dart#_createCodexHarness   | Where executable/harness deps are wired; inject the S01 surface here
file   | packages/dartclaw_config/lib/src/platform_capabilities.dart                       | Shared structured lookup error and effect-free candidate policy
```


## Constraints & Gotchas

- **Codex reports cache-inclusive `input_tokens`; the exact project-trust `configWarning` wire method is not recorded in-repo.** The S0b VM output was not brought back, so the executor MUST confirm the exact notification method/shape against a live `codex app-server` (this story already requires codex access) before finalizing S05's parse handling — spec the behavior (capture + surface project-local-config-disabled), not a guessed method string.
- **Provider scope**: This producer is Codex-specific because the app-server emits the project-trust warning. `ProviderProgressBridgeEvent` is shared transport, so a future provider may reuse `provider_setup_warning` for an equivalent warning, but S07 adds no speculative detection for Claude or other agents.
- **Cross-platform tests must not gate on the runner OS.** Every adapter/parse/lookup test constructs the surface or feeds the wire line explicitly (camelCase, CRLF, unknown methods, `operatingSystem:'windows'`); a test gated on the real host leaves Windows behavior unverified on POSIX CI (same rule as S01).
- **Avoid** adding a `Platform.isWindows` branch or a `where`/`which` helper to the harness spawn/probe path -- Instead: probe the configured provider binary directly and use the S01 structured error contract (US07).
- **Critical**: the two real-turn scenarios (S01/S02) are the only parts that require a Windows host + provider credentials. Per the FR8 recorded-evidence rule they may run in CI-with-credentials OR a recorded manual profile, but the evidence MUST cover both providers with OS/arch, provider versions, artifact-or-source, and turn results — a single-provider run does not satisfy OC01.
- **Architecture boundary**: Provider stdio/JSONL/JSON-RPC behavior is architecture-neutral per the S0b spike, so authenticated ARM64 Parallels evidence is valid for TI06 when architecture is recorded. It does not prove the x64 artifact, bundled SQLite, installer, or S09 core runtime layers.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** A regression test asserts Codex `turn/start` carries a camelCase `sandboxPolicy.type` for the mapped DartClaw sandbox values.
  - Drive `CodexProtocolAdapter.buildTurnRequest` with settings produced by `CodexSettings.buildDynamicSettings` (see `codex_settings.dart#CodexSettings`); the kebab→camel table maps only `workspace-write`/`danger-full-access`, so assert those two.
  - **Verify**: `Test: buildTurnRequest(sandbox 'workspace-write') → params['sandboxPolicy'] == {'type': 'workspaceWrite'}; sandbox 'danger-full-access' → {'type': 'dangerFullAccess'}`

- [x] **TI02** A regression test proves unknown Codex notification methods are ignored without crashing and do not block turn completion.
  - Feed `parseLine` the unknown methods observed in S0b (`thread/started`, a non-warning `mcpServer/startupStatus/updated`, `thread/status/changed`, `thread/tokenUsage/updated`, `account/rateLimits/updated`) then a `turn/completed`; the `parseLine` switch (`codex_protocol_adapter.dart#parseLine`) returns null on the default arm. (`turn/started` and `item/started` are excluded: both are explicitly cased in the switch — `turn/started` to null, `item/started` to a non-null item message — so they are not default-arm-null cases.)
  - **Verify**: `Test: parseLine returns null for each unknown method and throws nothing; handleProcessStdoutLine over the same batch is a no-op; a following turn/completed still completes the turn`

- [x] **TI03** CRLF-tolerant line parsing is regression-covered for both JSONL and JSON-RPC over the shared parse chain.
  - Exercise the `base_harness.dart#attachProcess` `utf8.decoder | LineSplitter` chain with `\r\n`-terminated lines, including a `\r\n` boundary split across two chunks; assert no trailing `\r` reaches the JSON decoder (mirrors the S0b step-1 checks, now a permanent test).
  - **Verify**: `Test: a \r\n-terminated claude stream-json line and a codex JSON-RPC line each parse identically to their \n form; empty CRLF line is dropped not crashed; chunk-split \r\n parses once`

- [x] **TI04** A Codex project-trust `configWarning` is captured and surfaced, and the turn still completes.
  - After confirming the exact wire shape against a live app-server, `parseLine` recognizes only the project-trust warning. `codex_harness.dart#handleProcessStdoutLine` logs it and emits `ProviderProgressBridgeEvent(kind: 'provider_setup_warning', text: normalized warning)`. The text names disabled project-local `.codex` config/hooks/exec policy and preserves useful provider detail. Do not surface unrelated `ProtocolDiagnostic` values or add a new event hierarchy.
  - **Verify**: `Test: project-trust configWarning logs and emits exactly one provider_setup_warning that TurnRunner forwards as ProviderProgressEvent; text names disabled project-local Codex configuration; unrelated ProtocolDiagnostic stays internal; following turn/completed succeeds`

- [x] **TI05** Claude and Codex harness binary validation is platform-neutral, and a missing binary reports the attempted probe context.
  - Startup validation directly probes the configured executable with `--version`; `ProcessException`, nonzero exit, or blank version output raises S01's structured lookup error (replacing the bare `StateError('codex binary not found …')`). No `Platform.isWindows`, `where`, or `which` helper exists in the spawn/probe path.
  - **Verify**: `Test: both harnesses call the configured binary with ['--version']; an unresolvable binary throws the structured lookup error naming '<bin> --version'; grep of the harness spawn/probe path shows no Platform.isWindows, where, or which branch`

- [x] **TI06** Native-Windows Claude and Codex turns are validated with recorded evidence covering both providers.
  - Add the repeatable procedure at `dev/testing/scenarios/windows-harness-turns.md`. Run it on native Windows (x64 CI or authenticated ARM64 Parallels) and write the stable latest result to `dev/testing/evidence/windows-harness-turns.md`, recording OS/arch, DartClaw commit/source or release version, `claude`/`codex` versions, timestamps, and both turn results. S09 may reuse it only for provider transport when DartClaw and provider versions match; architecture is recorded but need not be x64 for that slice.
  - **Verify**: `Inspection/run: both stable paths exist; evidence shows Claude result is_error=false and Codex turn/completed with no stdio parse/transport error, and records OS/arch, DartClaw + provider versions, artifact-or-source, timestamps, and both results`

- [x] **TI07** Authentication, protocol, and MCP setup diagnostics preserve turn-state integrity
  - Extend the existing harness tests with representative authentication-required, protocol-incompatibility, and MCP startup-warning inputs. Confirm the exact warning-bearing `mcpServer/startupStatus/updated` shape against the same live app-server used by TI04, log warning severity with provider detail, and continue ignoring non-warning status noise. Reuse each provider's existing error/diagnostic path; do not route generic diagnostics through the Codex-specific project-trust event added by TI04.
  - **Verify**: `Tests/table: auth-required and protocol-incompatible inputs surface provider detail and complete the affected turn as an error; warning-bearing MCP startup status is logged with provider detail while non-warning status remains ignored and a following completion succeeds; after each case a subsequent turn can start and complete without stale completer/parser state`

### Testing Strategy
> TI01–TI04 and TI07 are host-agnostic unit/regression tests; TI05 uses injected capabilities. TI06 is Windows-host + credential gated and is owned by the committed scenario and stable evidence paths above. POSIX CI skips real provider turns explicitly.

### Validation
> Leave empty — standard exec-spec build/test/analyze gates apply; TI06 evidence is the feature-specific gate captured in the Final Validation Checklist.

### Execution Contract
> Leave empty — TI01–TI05 and TI07 are independent; TI06 naturally runs last on a Windows host. No hidden ordering.


## Final Validation Checklist
- [x] `dev/testing/evidence/windows-harness-turns.md` exists and covers BOTH Claude and Codex with OS/arch, DartClaw/provider versions, artifact-or-source, timestamps, and turn results — a single-provider record does not satisfy OC01/FR8.


## Implementation Observations

#### DECISION NOTE: project-trust-warning-surface

Decision-Key: project-trust-warning-surface
Altitude: fis-local
Affected surface: Codex project-trust configWarning parsing, harness logging, and operator-facing turn progress
Decision: The Codex adapter/harness recognizes the live-confirmed project-trust warning, logs it, and emits ProviderProgressBridgeEvent with kind provider_setup_warning; existing TurnRunner forwarding exposes it as ProviderProgressEvent. Other providers are unchanged.
Rationale: Reuses the existing provider-neutral consumed path without exposing unrelated ProtocolDiagnostic messages or adding a new event hierarchy.
Evidence: S07 OC03 and current codex_harness.dart show the Codex warning requirement and dropped diagnostic; bridge_events.dart and turn_runner.dart already provide the shared forwarding path.

#### DECISION NOTE: windows-harness-evidence-location

Decision-Key: windows-harness-evidence-location
Altitude: fis-local
Affected surface: Native-Windows Claude/Codex turn procedure, durable evidence, and S09 reuse
Decision: S07 owns dev/testing/scenarios/windows-harness-turns.md and stable latest-run record dev/testing/evidence/windows-harness-turns.md. S09 may reuse it for the architecture-neutral provider transport slice when the DartClaw commit/source or release version and provider versions match; OS architecture is recorded but may be ARM64 Parallels. It cannot satisfy x64 artifact, SQLite, installer, or core runtime gates.
Rationale: Gives unattended execution exact durable paths, uses the available authenticated Parallels environment for architecture-neutral provider checks, and preserves x64 release proof.
Evidence: The S0b scoping brief establishes provider stdio as architecture-neutral and build/FTS5 as x64-sensitive; S07 and S09 require both-provider evidence with environment metadata.

#### DECISION NOTE: direct-harness-binary-probe

Decision-Key: direct-harness-binary-probe
Altitude: fis-local
Affected surface: Claude and Codex startup executable validation
Decision: Validate the configured provider binary directly with `--version`; do not launch `where` or `which`. Report failures through `UnsupportedCapabilityError` with the attempted command.
Rationale: Direct probing is platform-neutral, verifies both resolution and executable usability, and avoids trusting an additional PATH-resolved helper. ADR-049's candidate expansion remains the effect-free policy for consumers that need enumeration, such as Git Bash selection.
Evidence: ClaudeCodeHarness and CodexHarness probe the configured executable directly; their tests cover success, thrown `ProcessException`, nonzero exit, and blank output on injected Windows and POSIX capabilities.

### Run: 2026-07-13 11:52 UTC – observations

#### QUALIFICATION REOPENED: final-current-tree-native-windows

The checked proof surfaces record the successful Windows snapshot at its recorded fingerprint. Final review subsequently
changed provider timeout and Windows termination behavior, so plan status is reopened until both live provider turns are
recorded against the final source fingerprint. Portable regression gates remain green but do not replace native evidence.

### Run: 2026-07-14 06:12 UTC – observations

#### QUALIFICATION COMPLETE: final-provider-tree

Fresh native-Windows Claude and Codex turns passed against release artifact 0.20.1 from production source revision
`ec6ff1af9d4ff9cea4bf1434a1b3118217a2cee0`. Native-x64 qualification run 29310391226 verified that the final
production/build tree still matches that provider evidence before qualifying the artifact. Stable evidence at
`dev/testing/evidence/windows-harness-turns.md` records both provider versions, session/turn identifiers, terminal
results, and artifact identity.
