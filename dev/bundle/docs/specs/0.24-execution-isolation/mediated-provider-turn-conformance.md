# Mediated Provider Turn Conformance

## Feature Overview and Goal

**Intent**: The 0.24 release gate currently proves containers can *read* host-staged state but never proves an agent can complete a *real provider turn* through the mediation machinery – the gap (G-HIGH-6 residue) that lets "host-mediated execution works" ship as an unverified claim.

**Expected Outcomes**:

- [OC01] For each provider (claude, codex), a real containerized turn completes end-to-end through host mediation alone – packaged CLI → framed `docker exec` provider-bridge pipe → `HostGateway` adapter → upstream – and produces a container-side file write the host observes in the mounted workspace.
- [OC02] During and after a real mediated turn, the host provider credential is absent from every container-readable surface and appears only on the host-to-upstream hop.
- [OC03] This evidence is wired into the release gate so it cannot silently rot: the fixtures run under the documented integration invocation and the conformance matrix names them as runtime evidence.

## Required Context

- `dev/bundle/docs/specs/0.24-execution-isolation/0.24-execution-isolation-remediation-decisions.md#release-gating-gates` – the G-HIGH-6 subsection is the gate this FIS closes; prerequisites (i)/(ii) and the dual-engine release-gate framing.
- `packages/dartclaw_server/test/integration/scoped_host_gateway_integration_test.dart` – the authority-assembly pattern to reuse verbatim: `HostGateway` + adapter with `upstream:` override, `ContainerManager` with `bridgeBinaryPath`, `startBridge`/`attach`/`ready`, `_FakeProviderUpstream`, probe-image build, teardown discipline.
- `packages/dartclaw_server/test/integration/container_provider_parity_integration_test.dart` – agent-image build (`_ensureAgentImage`), packaged-CLI probes, and the workspace-mount `startContainer` shape the mediated turn needs (the gateway suite mounts no workspace).
- `packages/dartclaw_server/lib/src/container/gateway/provider_adapter.dart#AnthropicMessagesAdapter` – both adapters already accept `Uri? upstream`; no production seam change is needed or permitted.
- `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` – the containerized spawn block (container env from `claudeContainerHardeningEnvVars`, placeholder `ANTHROPIC_API_KEY`, `CLAUDE_CONFIG_DIR` → generated-state mount) that a real claude turn must exercise, and `ClaudeCodeHarness.turn`'s control-protocol drive.
- `packages/dartclaw_core/lib/src/harness/codex_environment.dart#CodexEnvironment.containerAuthClean` – the auth-clean home whose `config.toml` points `base_url` at the provider bridge; already integration-tested at config level, now exercised by a live turn.
- `packages/dartclaw_server/lib/src/task/codex_cli_provider.dart#CodexCliProvider.run` – the codex one-shot lane builds its **own** auth-clean home per turn (`_buildContainerHome`, `gatewayBaseUrl` at the container's provider bridge) and recreates the directory on setup, so the fixture drives the lane and asserts the generated config rather than supplying a home; note the `CliTurnRequest` collaborators the driver must construct.
- `dev/state/learnings/agent-harness-protocols.md` – CLI protocol traps that will otherwise burn the executor: container mode skips host probes; one-shot needs `--output-format stream-json` (buffered json starves monitors); SCRUB failures land on stdout; codex reads `config.toml` only at app-server startup; `file_write` vs `file_edit` grant split.
- `dev/guidelines/RELEASE_PREPARATION.md#pre-tag-gates` – the documented gate invocation (`dart test --run-skipped -t integration packages/dartclaw_server/test/integration/` on Linux Docker **and** Docker Desktop, both recorded) the new fixtures must be picked up by.

## Deeper Context

- `packages/dartclaw_server/lib/src/task/claude_cli_provider.dart` – containerized one-shot spawn env and terminal `type: "result"` parsing, if the one-shot lane is used for claude assertions.
- `packages/dartclaw_server/test/execution_conformance_matrix_test.dart` – the `runtimeEvidence` name registry the new fixtures register into.
- `dev/guidelines/TESTING-STRATEGY.md` – layer conventions; integration tag semantics.
- `docs/guide/security.md#file-ownership-on-native-linux` – why the uid-1201 VM run is expected to fail these fixtures without root/`CAP_CHOWN`; the gate runs as root on Linux plus Docker Desktop.

## Acceptance Scenarios

- [x] **S01 [OC01,OC02] [TI01,TI02] A containerized claude turn completes through host mediation and writes into the mounted workspace**
  - **Given** a real workspace-profile container from the shipped agent image whose host workspace dir is owned `1000:1000` before start, its provider bridge attached to a `HostGateway` whose `AnthropicMessagesAdapter` holds a sentinel credential and points at a scripted fake Anthropic Messages upstream (first response: `tool_use` instructing a `Write` of `/project/mediated-proof.txt` with content `mediated-write-ok`; after the tool result returns: a final `end_turn` message)
  - **When** the packaged claude CLI is spawned by the real production spawn path (no host environment, placeholder API key, `ANTHROPIC_BASE_URL` at the loopback bridge) and driven through one complete turn
  - **Then** the turn completes; the host observes `mediated-proof.txt` with content `mediated-write-ok` inside the mounted workspace directory; the fake upstream saw the tool round-trip on `/v1/messages` (the second request body carries a `tool_result` whose `tool_use_id` matches the scripted `tool_use` – request count alone is not evidence, since `count_tokens` is allowlisted and retries also count) with the sentinel in `x-api-key` on every request it received; and the sentinel appears nowhere in the container's `env`, `/proc/1/environ`, `docker inspect`, the workspace, the generated-state mount (the CLI's `CLAUDE_CONFIG_DIR`, swept recursively host-side after the turn), or `/tmp`.

- [x] **S02 [OC01,OC02] [TI01,TI03] A containerized codex turn completes through host mediation via its auth-clean generated home and writes into the mounted workspace**
  - **Given** the same real container/gateway assembly (workspace dir likewise pre-owned `1000:1000`) with an `OpenAiResponsesAdapter` – sentinel credential, scripted fake Responses upstream instructing a shell write of `/project/mediated-proof-codex.txt` then completing
  - **When** the packaged codex CLI runs one complete one-shot turn through the production one-shot lane, which builds its own `CodexEnvironment.containerAuthClean` home
  - **Then** the turn completes; the generated `config.toml`'s `base_url` targets the provider bridge; the host observes the file in the mounted workspace; the upstream received the sentinel as `authorization: Bearer <sentinel>`; and the sentinel appears in none of S01's container-readable surfaces.

- [x] **S03 [OC01] [TI04] An upstream failure mid-turn surfaces as a failed turn, never a silent success**
  - **Given** the S01 assembly with the fake upstream scripted to return HTTP 500 to **every** request on the provider path – failing only the first request proves nothing, since the CLI retries 5xx and would be served the next queued (success) response
  - **When** the same claude turn is driven
  - **Then** the turn observably fails (non-zero exit or error result – no fabricated success output); the fake upstream recorded ≥1 request carrying the sentinel, so a failure that never reached mediation cannot satisfy this scenario; the workspace contains no proof file; and releasing the fixture's authority wrapper (gateway revoke + manager stop) still destroys the container and its generated state.

- [x] **S04 [OC03] [TI05] Deleting a mediated-turn fixture breaks the default-suite conformance matrix**
  - **Given** the conformance matrix's `runtimeEvidence` registry naming the mediated-turn fixtures
  - **When** a named fixture file or test name is removed or renamed
  - **Then** `execution_conformance_matrix_test.dart` fails in the default (untagged) suite run.

## Structural Criteria

- [x] No production `lib/` source changes anywhere in the workspace – this feature is test/support/registry-only. A bug the new coverage exposes is recorded as an Implementation Observation and surfaced, never silently fixed in the same change.
- [x] The existing scoped-gateway and parity integration suites still pass on real Docker after the fake-upstream support is shared.
- [x] New integration files carry `@Tags(['integration','slow'])` and follow the existing Docker-unavailable behavior of their siblings, so the default `dart test` run is unaffected.
- [x] The `max_test_file_loc` fitness ratchet passes without raising any existing file's budget (new files get their own entries only if over the default).

## Scope & Boundaries

### Work Areas

- `packages/dartclaw_server/test/integration/` – new mediated-turn fixture file(s) plus a shared support file (fake provider upstream extended with scripted Anthropic Messages SSE turns and scripted OpenAI Responses turns, plus the container/bridge/image scaffolding the two existing suites currently duplicate).
- `packages/dartclaw_server/test/integration/scoped_host_gateway_integration_test.dart` and `container_provider_parity_integration_test.dart` – consume the shared support file, behavior unchanged.
- `packages/dartclaw_server/test/execution_conformance_matrix_test.dart` – `runtimeEvidence` rows for the mediated-turn fixtures.
- Release-gate invocation – no doc change expected; `RELEASE_PREPARATION.md` already runs the whole `test/integration/` directory on both engines. Touch it only if wording proves inaccurate.

### What We're NOT Doing

- **No real-credential automated gate** – the automated fixtures use the fake upstream (deterministic, credential-free, offline). A live-credential run on the VM stays a manual pre-tag option, not part of this FIS.
- **No new production seam** – both adapters already expose `upstream:`; adding config or code for test reachability is out of scope and a red flag.
- **No MCP-bridge turn coverage** – the MCP surface has its own live coverage in the scoped-gateway suite; this FIS proves the provider surface's turn path.
- **No uid-1201 green requirement for these fixtures** – the unprivileged non-1000 posture is documented as requiring root/`CAP_CHOWN` or rootless Docker; the gate records root-Linux and Docker Desktop runs.
- **No long-lived-vs-one-shot lane matrix completion beyond the two lanes specified** – claude is driven through the long-lived harness spawn path and codex through the one-shot lane; covering the remaining two lane combinations is future work if the matrix demands it.

## Architecture Decision

**Approach**: Extend the proven scoped-gateway integration pattern (real container + bridge + `HostGateway` + fake upstream via the adapters' existing `upstream:` parameter) with scripted multi-step provider conversations, and drive the packaged CLIs through the real production spawn paths – claude via the long-lived harness lane, codex via the one-shot lane with its auth-clean home.
**Why this over alternatives**: A real provider credential would make the release gate nondeterministic, costly, and secret-dependent; a weaker "exec the CLI directly" drive would bypass the exact spawn/env/mediation code the gate exists to prove.

## Constraints & Gotchas

- **Fake-upstream protocol fidelity is the risk center**: the claude CLI expects Anthropic Messages SSE event grammar (`message_start` → `content_block_*` → `message_delta`/`message_stop`) including `tool_use` blocks and a follow-up request carrying `tool_result`; codex expects the OpenAI Responses API event grammar. Script per-request queues; assert on requests received, not on internal CLI behavior. Iterate against Docker Desktop locally before the VM run.
- **Workspace mounts are not uid-aligned – the fixture must do it**: `ContainerManager` chowns only the generated-state and artifacts dirs to `containerImageUidGid` (`container_manager.dart#_chownToImageUid`); `workspaceMounts` pass through exactly as the host created them, and the image user is uid 1000. A root-run gate on native Linux Docker therefore mounts a root-owned `/project` and the container-side write fails `EACCES`, while Docker Desktop's uid remapping hides it – i.e. green locally, red on the engine the gate mandates. Every fixture creates its host workspace dir owned `1000:1000` before `start()`. This is a fixture precondition, not a production gap – distinct from the uid-1201 posture excluded in *What We're NOT Doing*.
- **Container spawns set `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0` as of 2026-08-13** (`claudeContainerHardeningEnvVars`); a fixture asserting container spawn env must expect `0`, and CLI failure evidence lands on stdout, not stderr.
- **Suites share one OS process** (`dart test` isolates): the fake upstream must bind host port 0; bridge ports 8080/8081 are container-loopback and do not collide across containers.
- **Turn-driving timeouts**: a wedged CLI turn must fail the test, not hang the suite – bound every await (the gateway suite's `ready.timeout` pattern) and keep teardown best-effort. The new fixture files also declare a suite-level `@Timeout` sized for first-run image build + container start + bridge handshake + CLI init + two provider round-trips – `dart test` defaults to 30s per test, well under that path, and neither sibling suite declares one to copy.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** A shared integration-test support file serves scripted multi-step conversations for both provider protocols and carries the container/bridge scaffolding both existing suites duplicate
  - Extract `_FakeProviderUpstream` from `scoped_host_gateway_integration_test.dart`, plus the scaffolding the new fixtures also need and the two suites already carry in divergent copies (`_dockerAvailable`, `_repoRoot` – the suites disagree on `Isolate.resolvePackageUri` vs `git rev-parse`, converge on one – `_ensureBridgeBinary`, `_ensureAgentImage`, `_containerExists`, the authority wrapper). Extend the upstream with per-request scripted responses: Anthropic Messages SSE turns (tool_use → final) and OpenAI Responses turns; capture method/path/headers/bodies per request. Both existing suites consume the shared file with behavior unchanged.
  - **Verify**: `dart test --run-skipped -t integration packages/dartclaw_server/test/integration/` passes on real Docker – both the scoped-gateway and parity suites green against the shared support file (Structural Criterion 2).

- [x] **TI02** A claude mediated-turn fixture proves S01 end-to-end on real Docker
  - New integration file using the parity suite's agent image + workspace mount and the gateway suite's authority assembly; spawn the packaged claude CLI through the real production container spawn path (harness lane); consume TI01's scripted upstream. Assert the write, the `tool_result` round-trip carrying the sentinel, and sentinel absence per S01. Sequence the risk: first get **any** scripted turn (plain text response, no tools) completing inside the hardened image – read-only rootfs, freshly emptied `CLAUDE_CONFIG_DIR` – since the only existing in-image evidence is `--version`; script tool-use fidelity only once that probe passes.
  - **Verify**: the S01 fixture passes via `dart test --run-skipped -t integration` on real Docker; sentinel-absence assertions cover env, `/proc/1/environ`, inspect JSON, workspace contents, the generated-state mount, and `/tmp`.

- [x] **TI03** A codex mediated-turn fixture proves S02 end-to-end on real Docker
  - Same assembly with `OpenAiResponsesAdapter`; drive one one-shot turn of the packaged codex CLI through `CodexCliProvider.run`, which builds the auth-clean home itself before spawn (codex reads `config.toml` only at startup) – assert the generated config rather than supplying a home. Depends on TI01's Responses scripting.
  - **Verify**: the S02 fixture passes via `dart test --run-skipped -t integration` on real Docker.

- [x] **TI04** The upstream-failure path fails the turn visibly and leaks nothing
  - Script a persistent 500 on the provider path in the S01 assembly; assert failed turn, ≥1 recorded upstream request, absent proof file, and full authority-wrapper/container/state teardown per S03.
  - **Verify**: the S03 fixture passes on real Docker; after release the container and generated-state dir are gone.

- [x] **TI05** The conformance matrix names the mediated-turn fixtures as runtime evidence
  - Add **new** `runtimeEvidence` keys in `execution_conformance_matrix_test.dart` naming the mediated-turn fixtures by file + test name, in the style of the existing non-combination keys (`authority cleanup`, `no host credential in a container`). The registry holds one `(file, testName)` per key, so the advertised `claude/container/*` and `codex/container/*` rows stay pointed at the parity fixtures – repointing them would silently drop the evidence they already carry.
  - **Verify**: default `dart test packages/dartclaw_server/test/execution_conformance_matrix_test.dart` passes; renaming a mediated-turn test name in the registry entry (thought experiment or temporary edit) makes it fail (S04).

- [x] **TI06** The release-gate evidence run is recorded
  - Run the full `test/integration/` gate command on Linux Docker (VM, as root) and on Docker Desktop; record engine, host OS, date, and pass counts per `RELEASE_PREPARATION.md#pre-tag-gates` (destination: the release PR / STATE.md blocker note until the PR exists). Depends on TI01–TI05.
  - **Verify**: both engine runs are green and their results recorded; the change set carries no production `lib/` diff anywhere in the workspace (Structural Criterion 1); STATE.md blocker updated to reflect closed G-HIGH-6 coverage.

### Testing Strategy

- These fixtures ARE the tests; no additional unit layer. Keep every new assertion observable from outside the container (host-observed files, captured upstream requests, docker inspect), matching the suite's "configuration labels are not evidence" doctrine.

## Implementation Observations

### Run: 2026-08-13 09:05 UTC – observations

#### NOTICED BUT NOT TOUCHING

**PRODUCTION DEFECT 1 — a containerized long-lived Claude harness can never start.** `ClaudeCodeHarness` sets `_processWorkingDirectory = cwd` in its constructor (`packages/dartclaw_core/lib/src/harness/claude_code_harness.dart:149`) and `_startInternal` passes that value straight to `ContainerExecutor.exec(workingDirectory:)` (same file, ~line 507) without translating it through `containerPathForHostPath`. The host path does not exist inside the container, so `docker exec` fails with exit 127 and `OCI runtime exec failed: ... chdir to cwd ("<host path>") set in config.json failed: no such file or directory`. Production reaches this on every containerized long-lived spawn: `HarnessWiring._buildFactoryConfig` passes `cwd: Directory.current.path` (`apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart:840`), and both the CLI primary harness (`harness_wiring.dart:342`) and `ExecutionCoordinator` worker creation (`packages/dartclaw_server/lib/src/execution_coordinator.dart:204`) call `harness.start()` before any turn. The cause is invisible to operators: the OCI error arrives on the exec's stdout and is discarded as an unparseable JSONL line, so the only symptom is `Initialize handshake timed out after Ns`. `turn()` is unaffected — it resolves and translates the directory, then restarts — which is why the S01/S03 fixtures drive `turn(directory:)` on a harness that was never `start()`ed. Reproduced 2026-08-13 on Docker Desktop 29.4.2 and Linux Docker 29.7.2.

**PRODUCTION DEFECT 2 — a containerized Codex one-shot silently executes no tools under the default sandbox.** `CodexCliProvider._buildCommand` emits `--full-auto` whenever neither `sandboxOverride` nor `providerConfig.options['sandbox']` is set (`packages/dartclaw_server/lib/src/task/codex_cli_provider.dart:329-336`); production passes `sandboxOverride: null` (`packages/dartclaw_server/lib/src/task/task_executor.dart:560`) and no default exists anywhere in `lib/`. Codex then engages its own Linux sandbox and every tool call dies with `Process exited with code 101 ... panicked at linux-sandbox/src/launcher.rs:43:13: bubblewrap is unavailable: no system bwrap was found on PATH and no bundled codex-resources/bwrap binary was found next to the Codex executable`. The image ships no `bwrap`, and it could not run under the container's `--cap-drop ALL` / `no-new-privileges` hardening anyway — the same constraint already documented for Claude's `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0`. The turn still completes and returns assistant text, so a containerized Codex step reports success while having done nothing. With `sandboxOverride: 'danger-full-access'` the identical call succeeds and the write lands; the S02 fixture pins that value explicitly and says why. Reproduced 2026-08-13 on both engines.

**Pre-existing unrelated gate failure — `crash_recovery_smoke_test.dart`.** Red at HEAD in a clean worktree, and red on both engines in this run, so the dual-engine gate result is `37 passed, 1 pre-existing failure` rather than fully green. Three hardcoded repo-root-relative paths break under `dart test`, which roots test isolates at the package, not the invocation directory: `test/integration/crash_recovery_smoke_test.dart:44` (helper fixture path), `test/integration/_fixtures/crash_turn_process.dart:26` (`initTemplates`), and `:48` (`staticDir`). Fixing all three (verified locally, then reverted as out of scope) lets the helper boot, after which `POST /api/sessions/<id>/send` returns HTTP 500 `INTERNAL_ERROR` with nothing logged — a separate, deeper defect that needs its own investigation.

**Linux VM checkout permissions break every bridge-using suite.** The sync procedure in `dev/guidelines/PARALLELS_LINUX_AGENT_VM.md` leaves `/home/dartclaw-test`, the checkout, and `build/bridge/*` at mode 0700. The container runs as uid 1000 and reads the bridge through a bind mount, so every bridge handshake fails with `Bad state: Bridge pipe revoked before it became ready` — 19 failures including the entire pre-existing scoped-gateway suite. Docker Desktop's uid remapping hides this on macOS. `chmod 755` on the path plus `chmod -R a+rX build` makes the gate green. This is the same class as the workspace-mount uid alignment this FIS already handles in `createImageOwnedWorkspace`, but for the bridge binary, and it belongs in the VM guide's documented sync recipe.

**Codex code mode changes the tool wire shape.** The image ships codex 0.146.0, which sends no `tools` array on `/v1/responses`. The dispatchable tool names arrive in `client_metadata.x-codex-turn-metadata.code_mode_tool_names` (`apply_patch`, `exec_command`, `update_plan`, ...), and a single custom tool `exec` evaluates JavaScript that composes them. A `function_call` named `shell` is rejected with `unsupported call: shell`; `exec_command` dispatches directly. Any future fake-upstream scripting must target that shape, not the classic `shell` function tool.

**One off-surface provider path is denied during Claude init.** The gateway logs `path is not part of the claude provider surface` once while the claude CLI initializes; the turn completes normally. The denial reason deliberately omits the path (container-authored strings must not be logged), so the endpoint was not identified. Expected boundary behavior, recorded only so a future reader does not mistake the log line for a fault.
