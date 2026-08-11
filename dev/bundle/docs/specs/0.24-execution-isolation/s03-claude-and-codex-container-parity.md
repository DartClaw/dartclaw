# Feature Implementation Specification: Claude and Codex Container Parity

**Plan**: dev/bundle/docs/specs/0.24-execution-isolation/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: Make Claude and Codex execute at the effective host/container boundary on every supported execution surface while provider authentication and approved research traffic remain host-mediated, scoped, and secret-free inside containerized executions.

**Expected Outcomes**:

- [OC01] Long-lived and workflow-owned Claude and Codex processes run at the effective location selected by S01, with no provider- or surface-specific fallback.
- [OC02] Containerized Claude and Codex authenticate through S02's host-owned provider adapters without provider credentials, host login state, or reusable gateway authority entering the container.
- [OC03] All containerized Claude and Codex executions reach host MCP only through the execution-scoped bridge with a deny-by-default tool inventory; restricted executions can use their approved DartClaw search/fetch tools while provider-native web access, unapproved MCP tools, and arbitrary Internet access remain unavailable, and workspace-profile containers retain provider-native web while sharing the same scoped-MCP and no-direct-egress boundary.
- [OC04] Every statically-detectable incompatibility (configuration, auth mode, missing binary, provider gateway, or bridge at admission) rejects before the turn is admitted; only genuinely runtime failures (bridge or container death mid-turn, expired authority) terminate the running turn — in both cases without silently changing location or transport.

## Required Context

- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#stories.2` – authoritative S03 scope, S01/S02 dependencies, risk, source references, and Codex launch note.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#sharedDecisions.0` – S01 effective-policy ownership consumed unchanged by S03.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#sharedDecisions.1` – conservative resolution and no-fallback behavior.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#sharedDecisions.2` – provider credential and host-capability authority separation.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#sharedDecisions.3` – portable `network:none` framed stdio transport.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#sharedDecisions.4` – execution-scoped, non-replayable bridge authority.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#sharedDecisions.5` – verified provider authentication only.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#bindingConstraints.0` – conflicting execution policy is rejected without substitution.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#bindingConstraints.1` – profiles are valid only in container mode.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#bindingConstraints.2` – provider credentials stay absent from all container-visible surfaces.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#bindingConstraints.3` – host authorization uses the effective principal and tool set.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#bindingConstraints.4` – bridge authority is execution-bound and non-replayable.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#bindingConstraints.5` – every live container authority owns a dedicated non-cached container harness.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#bindingConstraints.6` – every agent container retains `network:none`.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#bindingConstraints.7` – containerized Claude supports
  host-held API-key mediation only.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr2-enforced-multi-harness-isolation` – real placement parity for both providers and ordinary/workflow execution.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr3-host-owned-provider-credentials` – Claude auth compatibility, auth-clean Codex Responses routing, pinned image artifact, and secret-absence proof.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr4-scoped-host-capabilities` – scoped search/fetch, host guard enforcement, replay resistance, no native fallback, and arbitrary-egress denial.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#user-flows` – operator-visible Claude/Codex container and restricted-research flows.
- `dev/bundle/docs/specs/0.24-execution-isolation/requirements-clarification.md#technical-evidence` – verified Codex 0.146 custom Responses behavior, auth-state hazard, and Docker Desktop transport constraint.
- `dev/adrs/016-multi-provider-harness-architecture.md#part-4-one-execution-authority-capacity-leases-and-opportunistic-reuse` – common provider/profile allocation and lifecycle authority.
- `dev/adrs/016-multi-provider-harness-architecture.md#configtoml-scope` – static Codex config versus ephemeral launch/turn settings.
- `dev/architecture/control-protocol.md#10-mcp-integration` – current Claude/Codex MCP discovery and host tool inventory.
- `dev/architecture/control-protocol.md#11-execution-coordination-and-harness-reuse` – long-lived, worker, and workflow one-shot execution surfaces.
- `dev/architecture/security-architecture.md#container-isolation` – Docker boundary, profile containers, sandbox interaction, and current provider gaps.
- `dev/architecture/security-architecture.md#credential-security` – current Claude credential proxy and direct Codex credential behavior to replace only in container mode.

## Deeper Context

- `dev/adrs/016-multi-provider-harness-architecture.md#authentication-model` – existing host-mode Codex authentication baseline; container mode deliberately uses the newer FR3 custom-provider contract.
- `dev/adrs/016-multi-provider-harness-architecture.md#guard-chain-interception--permission-model-asymmetry` – provider-specific approval interception that remains active behind the OS boundary.
- `dev/architecture/control-protocol.md#13-container-dispatch` – current profile-container dispatch and no-profile-fallback behavior.
- `dev/architecture/security-architecture.md#canonical-tool-taxonomy` – semantic mapping for DartClaw MCP search/fetch and native provider web calls.
- `docker/Dockerfile#CODEX_VERSION` – floating Codex version and obsolete direct-binary asset path that must become a tested immutable install.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI02] Effective placement is identical across provider and execution surface**
  - **Given** S01 resolves one host execution and one container execution for each of Claude and Codex, exercised through both the long-lived harness/coordinator path and the workflow-owned one-shot path
  - **When** each execution starts and runs a location probe
  - **Then** all eight process observations prove the requested host or managed-container namespace and effective profile, with no provider-specific reinterpretation, host substitution, or container substitution
  - **And** container work directories resolve inside the selected profile container while host work directories retain their host path semantics

- [ ] **S02 [OC02] [TI03] Containerized Claude uses only verified API-key mediation**
  - **Given** host-held `ANTHROPIC_API_KEY` and the effective boundary set to container
  - **When** a long-lived or workflow-owned Claude turn reaches the Anthropic API through S02's Claude adapter
  - **Then** the request succeeds with host-applied authentication and the adapter accepts only the intended provider protocol/destination
  - **And** the container process environment, mounted files, command arguments, generated settings, stdout/stderr, and reported errors contain neither the provider credential nor host Claude login state
  - **And** an OAuth/setup-token-only host configuration is rejected before spawn with deliberate host execution as the
    supported alternative

- [ ] **S03 [OC02] [TI04] Containerized Codex uses an auth-clean custom Responses provider**
  - **Given** a fresh per-process Codex home with no mounted host Codex home, copied `auth.json`, login database, provider API key, or reusable token
  - **When** long-lived `codex app-server` or workflow-owned `codex exec` starts in a container and calls the configured model
  - **Then** ephemeral launch overrides select DartClaw's custom Responses provider, point it only at S02's Codex gateway, use the Responses wire API, and disable Codex/OpenAI authentication at the client boundary
  - **And** the host gateway supplies upstream authentication while captured container requests carry no `Authorization` header and the same environment/file/argument/config/output inspection used by S02 finds no provider credential or host login state

- [ ] **S04 [OC03] [TI05] Restricted Claude and Codex reach only approved scoped MCP research tools**
  - **Given** a restricted execution whose effective principal is authorized for one registered search tool and `web_fetch`, but not another registered MCP tool
  - **When** either provider discovers and calls the approved tools through S02's execution-scoped host bridge
  - **Then** search/fetch execute on the host through the existing MCP router, guard, SSRF/content, audit, and search-provider boundaries and return their normal bounded results
  - **And** the bridge authorizes the exact effective principal, session, worker, MCP surface, and tool set for that execution only; a second execution cannot replay its authority

- [ ] **S05 [OC03] [TI05,TI06] Native web, unapproved MCP, and arbitrary network access stay closed**
  - **Given** either provider runs in the restricted container with scoped MCP enabled
  - **When** it attempts provider-native web search/fetch, the denied MCP tool, direct DNS/TCP/HTTP access, or reuse of another execution's bridge authority
  - **Then** every attempt is denied and audited without invoking the provider-native web path, joining an egress-capable network, or treating bridge reachability as general network access
  - **And** absence or denial of an approved MCP search provider never falls back to native provider search, direct Internet, a broader shared MCP endpoint, or host execution

- [ ] **S06 [OC04] [TI02,TI03,TI04,TI05,TI06] Provider and bridge failures remain explicit and secret-free**
  - **Given** one failure at a time: missing container manager, mismatched profile, Claude OAuth/setup-token container auth,
    unrunnable packaged CLI, unavailable provider adapter, unavailable MCP bridge, expired execution authority, or
    container restart
  - **When** the execution requests admission — where the statically-detectable failures (missing container manager, mismatched profile, OAuth/setup-token container auth, unrunnable packaged CLI, unavailable provider adapter, unavailable MCP bridge) must reject — or performs its next mediated call, where the runtime failures (expired execution authority, container restart) terminate
  - **Then** DartClaw rejects or terminates that execution at the responsible boundary, cleans up its ephemeral home and authority, and never retries in-turn through the host, direct network, native web, another profile, or stale bridge, while the standard task retry policy may later re-admit the work through a fresh, fully validated authority
  - **And** the surfaced failure identifies provider, effective location/profile, and failed mediation class without including credentials, login material, scoped authority, or request bodies

## Structural Criteria

- [ ] S01 remains the sole owner of effective execution policy and worker identity; provider adapters consume its result unchanged and cannot select a boundary themselves.
- [ ] S02 remains the sole owner of provider-gateway and execution-scoped framed-pipe transport/authority; S03 configures
      provider clients against its loopback endpoints rather than adding another proxy, token service, or network.
- [ ] Containerized Codex always uses a newly created, permission-restricted home — generated host-side in the per-execution state directory and bind-mounted read-write into the container through S02's ContainerManager create path (this story supplies the home path and contents), never the host user's Codex home — that contains only required generated client configuration, is enumerated in mount/secret inspection, and is deleted on stop, crash, cancellation, and failed startup; host-mode Codex retains its existing user-home behavior.
- [ ] Neither container mode copies or mounts host provider homes/auth files nor injects provider credentials through environment, arguments, settings, MCP headers, or bridge URLs.
- [ ] Every containerized provider harness owns its dedicated S01 container and is disposed/destroyed on authority release;
      it never enters the reusable worker cache.
- [ ] The container image pins an exact Codex version and per-architecture sha256 checksum from the release's current Linux archive naming for every supported Docker architecture; the build verifies the checksum before install and executes `codex --version` before succeeding, and `latest` or unchecksummed fetches are rejected.
- [ ] Every containerized Claude and Codex execution exposes only the execution-scoped DartClaw MCP endpoint with the deny-by-default tool inventory authorized for the effective principal; restricted configuration additionally disables provider-native web capabilities, while workspace-profile containers retain them.
- [ ] Container processes retain Docker `network:none` and reach S02 only through their surface-separated loopback bridge
      processes and host-controlled stdio pipes; host-mode behavior and existing host guard chains remain intact.
- [ ] Conformance evidence observes real process/container placement and runtime surfaces; configuration labels or mocked profile selection alone are insufficient.

## Scope & Boundaries

### Work Areas

- Core Claude/Codex harness construction, process lifecycle, Codex home/config generation, and container execution parity
- Server workflow Claude/Codex one-shot providers and execution-scoped container/bridge inputs
- CLI composition of effective execution identity, provider gateways, scoped MCP, and native-tool denial
- Docker agent image Codex installation for supported architectures
- Provider/container conformance, failure, placement, and secret-inspection tests

### What We're NOT Doing

- S01 policy schema, precedence, compatibility validation, or agent/job inheritance – this story consumes its effective policy result.
- S02 framing, gateway protocol implementation, pipe registration, or bridge cleanup rules – this story attaches
  Claude/Codex clients to those boundaries.
- General or allowlisted direct container egress, arbitrary external APIs, a reusable universal proxy, or a shared cross-execution MCP steward.
- ACP or future-provider container parity; unsupported harnesses continue to fail compatibility validation rather than inheriting Claude/Codex behavior.
- Changes to host-mode provider login semantics beyond preserving existing supported behavior.

## Architecture Decision

**Approach**: Adapt each Claude/Codex launch surface to the same S01 execution descriptor and S02 mediation descriptor. Container clients receive only provider-specific endpoint configuration and execution-scoped connectivity; Codex additionally receives a fresh auth-clean home and ephemeral custom Responses overrides.
**Why this over alternatives**: Mounting login homes, injecting keys, enabling container egress, or falling back to native web would collapse the host/container trust boundary and contradict FR3/FR4.

## Technical Overview

The coordinator supplies the normalized provider, effective location/profile, worker identity, and S02 mediation handles to
host cached-harness construction, dedicated container-harness construction, and capacity-only workflow execution. Claude
and Codex must reach the same `ContainerExecutor` path when location is `container`; host requests continue through their
existing process factories. A missing compatible executor is an admission error, not a request to run natively.

For containerized Claude, both long-lived and one-shot launchers target S02's Claude provider loopback endpoint and omit
raw API keys and host authentication files. Only host-held `ANTHROPIC_API_KEY` is supported; OAuth/setup-token-only
container requests reject. For containerized Codex, the existing home abstraction gains a container-specific auth-clean
mode that never seeds authentication. Both app-server and exec receive ephemeral custom-provider overrides selecting the
S02 loopback endpoint, Responses protocol, and `requires_openai_auth=false`, delivered as generated configuration inside
the ephemeral container home (config-layer per ADR-016), with launch flags only where generated config cannot express a
setting; no override is persisted into or read from the user's Codex home. Generated state is deleted when the dedicated
container authority is released.

The provider-specific MCP configuration names only S02's container-loopback MCP bridge and requires no reusable bearer
inside the container. The host binds that pipe to the effective execution identity and exposes only the principal's
approved DartClaw tools. Restricted launches explicitly disable Claude/Codex native web tools. Thus approved search/fetch
happens in DartClaw's host MCP implementation, while Docker `network:none` rejects arbitrary external sockets.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_core/lib/src/harness/harness_factory.dart#HarnessFactoryConfig | Shared long-lived provider construction seam; Codex currently drops containerManager
file | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#ClaudeCodeHarness | Existing container-aware long-lived Claude lifecycle and MCP settings path
file | packages/dartclaw_core/lib/src/harness/codex_harness.dart#CodexHarness | Long-lived Codex spawn, launch overrides, and missing ContainerExecutor parity
file | packages/dartclaw_core/lib/src/harness/codex_environment.dart#CodexEnvironment | Current system/isolated homes seed auth; add an auth-clean container lifecycle without changing host behavior
file | packages/dartclaw_core/lib/src/harness/codex_config_generator.dart#CodexConfigGenerator | Generated MCP/static config must remain credential-free
file | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart#WorkflowCliRunner | Workflow-owned provider/profile allocation and ContainerExecutor dispatch
file | packages/dartclaw_server/lib/src/task/claude_cli_provider.dart#ClaudeCliProvider | One-shot Claude endpoint, environment, native-tool, and container launch settings
file | packages/dartclaw_server/lib/src/task/codex_cli_provider.dart#CodexCliProvider | One-shot Codex auth-clean home and custom Responses launch settings
file | packages/dartclaw_server/lib/src/container/container_manager.dart#ContainerManager | Actual docker exec placement and S02 bridge attachment
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#HarnessWiring | Production assembly of harness, profile, gateway, MCP, and effective agent policy
file | docker/Dockerfile#CODEX_VERSION | Replace floating/bare-binary install with pinned verified release archive and build-time version probe
```

## Constraints & Gotchas

- **One effective decision**: use the S01 location/profile attached to the execution request for construction, reuse, restart, and workflow one-shots. Never recalculate from task type or provider options.
- **One identity vocabulary**: "worker identity", "execution principal", and "effective principal" name the same S01 execution identity; "S02's Claude adapter/provider endpoint" is the Anthropic Messages adapter and "S02's Codex gateway" is the OpenAI Responses adapter.
- **Codex home modes are distinct**: existing host system-home and isolated-seeded-home behavior cannot serve restricted containers. The container mode creates a third, auth-clean lifecycle and must not call authentication seeding.
- **Launch overrides are ephemeral**: custom provider name, base URL, Responses wire API, and `requires_openai_auth=false` belong on the process launch; do not persist them in the host home or accept user config that can redirect the restricted provider.
- **No bearer ambiguity**: the Codex proof must inspect the outbound container-side request itself. A saved login can add `Authorization` even when `requires_openai_auth=false`, so config assertions alone are inadequate.
- **Scoped MCP is not Internet access**: expose only S02's container-loopback endpoint and host-controlled stdio pipe. The
  container retains `network:none` and no bearer identifies it to the host.
- **Native web denial is provider-specific and host-enforced**: preserve canonical guard/audit mapping and configure each CLI so it cannot bypass MCP via its built-in web tool, but the enforcement point is S02's provider adapter, which rejects restricted executions' requests that declare provider-native web tools — client-side suppression is defense in depth, not the boundary. Tool-policy denial alone does not prove the network path is absent.
- **Container harnesses are single-authority**: they are never cached or shared across authorities; disposal revokes pipes,
  deletes generated state, and destroys the container before capacity returns.
- **Secret inspection is exhaustive**: test env, mounts, argv, generated homes/settings, intercepted requests, stdout/stderr, and formatted failures for known sentinel values and auth-file material — including the shared operator MCP bearer, which containerized launches must never receive in any generated configuration or environment (the execution-scoped bridge replaces it).

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Long-lived Claude and Codex honor the effective execution descriptor
  - Carry S01's effective location/profile and S02 mediation inputs through `HarnessWiring` and `HarnessFactoryConfig`; make Codex use `ContainerExecutor` for executable probing, spawn, cwd translation, restart, cancellation, and confirmed teardown just as Claude does.
  - **Verify**: S01 passes for the host/container × Claude/Codex long-lived matrix; real location probes and container exec
    capture agree with the effective descriptor, a missing/mismatched executor fails before a turn, and released container
    harnesses are destroyed rather than cached.

- [ ] **TI02** Workflow-owned Claude and Codex preserve the same placement and lifecycle rules
  - Feed the execution descriptor and S02 mediation inputs into `WorkflowCliRunner`; keep both CLI providers on the selected `ContainerExecutor` through schema/temp-file translation, root-process observation, cancellation, and failure cleanup.
  - **Verify**: S01 and S06 pass for workflow one-shots with actual host/container process probes, correct
    restricted/workspace cwd behavior, confirmed root-process termination, pipe/home cleanup, container destruction, and no
    host retry after container failure.

- [ ] **TI03** Containerized Claude authenticates only through its host adapter
  - Configure both Claude launch surfaces for S02's loopback provider endpoint and remove container exposure of API keys
    and host Claude auth files. Support host-held `ANTHROPIC_API_KEY` only; reject OAuth/setup-token container mode with
    deliberate host execution as remediation.
  - **Verify**: S02 and S06 pass for API-key success and OAuth/setup-token rejection; a constrained fake upstream proves
    host-applied authentication and destination/protocol restriction while sentinel scans find no provider/login secret on
    any enumerated container surface.

- [ ] **TI04** Containerized Codex launches from an auth-clean home through a custom Responses provider
  - Add a non-seeding Codex home lifecycle and shared ephemeral custom-provider override builder used by app-server and exec; target S02's Codex gateway with Responses and disabled client auth, and update the image to a non-floating verified Linux archive for each supported architecture.
  - **Verify**: S03 and S06 pass for both Codex surfaces; captured requests lack `Authorization`, host gateway requests contain the expected upstream auth, teardown removes generated homes, amd64/arm64 image builds run `codex --version`, and a wrong asset/version fails the build or admission.

- [ ] **TI05** Containerized provider clients expose only their scoped host MCP inventory
  - Generate provider-specific MCP/native-tool launch settings from S02's loopback/pipe descriptor for both long-lived and
    workflow surfaces and for both container profiles; start no network relay, explicitly disable Claude/Codex native web
    paths for restricted executions, and leave workspace-profile native web enabled while its MCP access still flows only
    through the scoped bridge with the deny-by-default inventory.
  - **Verify**: S04–S06 pass for both providers; approved search/fetch traverse the existing host MCP guards;
    unapproved/direct/replayed attempts fail for both container profiles, native web fails for restricted while a
    workspace container retains it; bridge loss does not trigger fallback, and container inspect shows `network:none`
    with no extra attachment.

- [ ] **TI06** Conformance suites prove runtime placement, denial, cleanup, and secret absence
  - Add a shared provider/surface matrix fixture with sentinel provider credentials/login files and a sentinel shared operator MCP bearer, actual Docker namespace probes, captured provider/MCP requests, inspectable argv/env/mounts/generated homes, bridge authority replay, and injected startup/runtime failures.
  - **Verify**: all six scenarios pass non-skipped on the executing platform for story completion, with recorded evidence on both Linux Docker and Docker Desktop owned by S04's release conformance gate; focused unit tests
    cover launch construction and cleanup, integration tests exercise real provider-compatible fakes through Docker, and
    assertions fail when only a label changes, a container harness is cached, a sentinel leaks, native web is re-enabled,
    or direct egress succeeds.

### Testing Strategy

- [S01 → TI01,TI02] Extend `packages/dartclaw_core/test/harness/harness_factory_test.dart`, Codex/Claude harness tests, `packages/dartclaw_server/test/task/workflow_cli_runner_test.dart`, and CLI execution-coordinator wiring tests with one host/container × provider × surface table. Add a Docker conformance test that records PID namespace/container identity and cwd from the spawned process.
- [S02 → TI03,TI06] Extend Claude harness/workflow and credential-gateway tests with API-key success plus OAuth/setup-token
  container rejection. Use distinct sentinel values in host auth sources and assert success at the fake upstream plus
  absence across `docker inspect`, `/proc/<pid>/environ`, `/proc/<pid>/cmdline`, mounted/generated files, and captured
  output/errors.
- [S03 → TI04,TI06] Extend `codex_environment_test.dart`, `codex_harness_test.dart`, `workflow_cli_runner_codex_command_test.dart`, and Docker image checks. Start from a deliberately credentialed host home, assert the container home is fresh and unseeded, capture the client-side Responses request without auth, and verify the host-side request gains auth.
- [S04,S05 → TI05,TI06] Extend MCP wiring/tool-policy tests and add provider/container integration cases with approved search/fetch, denied MCP, native-web attempts, direct DNS/TCP/HTTP probes, and replay from a second principal/session. Assert the host router/guards/audit own accepted calls and Docker owns direct-network denial. Include a workspace-profile case: scoped-bridge-only MCP with the deny-by-default inventory, retained provider-native web, and denied direct egress.
- [S06 → TI01–TI06] Inject each binary/gateway/bridge/restart failure in both execution surfaces. Assert terminal no-fallback behavior, root-process/ephemeral-home/authority cleanup, stable capacity release, and redacted diagnostics.
- Keep provider CLIs and upstream APIs deterministic behind protocol-compatible local fakes; real Docker placement/network/image tests are mandatory because process-factory mocks cannot prove the OS boundary. The Codex bearer-forwarding hazard is additionally proven with the real pinned Codex binary in a live-tagged test (credentialed host home, fresh container home, captured request without Authorization); this recorded evidence is a 0.24 release-completion requirement, not per-commit CI.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS mutability contract. Spec authors leave this section empty._

#### DECISION NOTE: scoped-mcp-applies-to-workspace-profile
Decision-Key: scoped-mcp-applies-to-workspace-profile
Altitude: requirements
Affected surface: Intent; OC03; Structural Criterion; TI05; Testing Strategy
Decision: Scoped host MCP applies to ALL containerized executions (workspace and restricted), deny-by-default. Provider-native web is disabled for restricted executions and retained for workspace containers. TI05 generates launch settings for both container profiles and its verify asserts the workspace behaviors (scoped-bridge-only MCP, retained native web, denied direct egress); the Testing Strategy includes an explicit workspace-profile case. OC03/SC amendments already applied and stand. Ratified by the operator in preflight interview.
Rationale: Re-check found TI05 still restricted-only — contradicting amended OC03 and leaving no task configuring workspace-container MCP — and the workspace half unverified.
Evidence: PRD FR4 covers containerized agents generally; native-fallback ban is restricted-scoped.

Old:
```
- [ ] **TI05** Restricted provider clients expose only authorized host MCP research
```
New:
```
- [ ] **TI05** Containerized provider clients expose only their scoped host MCP inventory
```

Old:
```
  - Generate provider-specific MCP/native-tool launch settings from S02's loopback/pipe descriptor for both long-lived and
    workflow surfaces; start no network relay and explicitly disable Claude/Codex native web paths.
```
New:
```
  - Generate provider-specific MCP/native-tool launch settings from S02's loopback/pipe descriptor for both long-lived and
    workflow surfaces and for both container profiles; start no network relay, explicitly disable Claude/Codex native web
    paths for restricted executions, and leave workspace-profile native web enabled while its MCP access still flows only
    through the scoped bridge with the deny-by-default inventory.
```

Old:
```
  - **Verify**: S04–S06 pass for both providers; approved search/fetch traverse the existing host MCP guards,
    unapproved/native/direct/replayed attempts fail, bridge loss does not trigger fallback, and container inspect shows
    `network:none` with no extra attachment.
```
New:
```
  - **Verify**: S04–S06 pass for both providers; approved search/fetch traverse the existing host MCP guards;
    unapproved/direct/replayed attempts fail for both container profiles, native web fails for restricted while a
    workspace container retains it; bridge loss does not trigger fallback, and container inspect shows `network:none`
    with no extra attachment.
```

Old:
```
- [S04,S05 → TI05,TI06] Extend MCP wiring/tool-policy tests and add provider/container integration cases with approved search/fetch, denied MCP, native-web attempts, direct DNS/TCP/HTTP probes, and replay from a second principal/session. Assert the host router/guards/audit own accepted calls and Docker owns direct-network denial.
```
New:
```
- [S04,S05 → TI05,TI06] Extend MCP wiring/tool-policy tests and add provider/container integration cases with approved search/fetch, denied MCP, native-web attempts, direct DNS/TCP/HTTP probes, and replay from a second principal/session. Assert the host router/guards/audit own accepted calls and Docker owns direct-network denial. Include a workspace-profile case: scoped-bridge-only MCP with the deny-by-default inventory, retained provider-native web, and denied direct egress.
```

Old:
```
**Intent**: Make Claude and Codex execute at the effective host/container boundary on every supported execution surface while provider authentication and approved research traffic remain host-mediated, scoped, and secret-free inside restricted containers.
```
New:
```
**Intent**: Make Claude and Codex execute at the effective host/container boundary on every supported execution surface while provider authentication and approved research traffic remain host-mediated, scoped, and secret-free inside containerized executions.
```

#### DECISION NOTE: native-web-denial-enforcement-point
Decision-Key: native-web-denial-enforcement-point
Altitude: project-decision
Affected surface: Constraints & Gotchas native-web bullet
Decision: Restricted-execution provider-native web denial is enforced host-side in S02's provider adapters (requests declaring provider-native web tools are rejected), with client-side config disabling retained as defense in depth. Client suppression alone is insufficient.
Rationale: Provider-native web executes server-side at the provider through the credential gateway, so network:none and client config cannot enforce the denial; the binding constraint rejects trusting client-side tool suppression.
Evidence: plan.json bindingConstraints FR4; Claude WebSearch and Codex web_search are provider-side tools riding the gateway.

Old:
```
- **Native web denial is provider-specific**: preserve canonical guard/audit mapping, but also configure each CLI so it cannot bypass MCP via its built-in web tool. Tool-policy denial alone does not prove the network path is absent.
```
New:
```
- **Native web denial is provider-specific and host-enforced**: preserve canonical guard/audit mapping and configure each CLI so it cannot bypass MCP via its built-in web tool, but the enforcement point is S02's provider adapter, which rejects restricted executions' requests that declare provider-native web tools — client-side suppression is defense in depth, not the boundary. Tool-policy denial alone does not prove the network path is absent.
```

#### DECISION NOTE: codex-auth-leak-proof-fidelity
Decision-Key: codex-auth-leak-proof-fidelity
Altitude: project-decision
Affected surface: Testing Strategy fake-vs-real boundary
Decision: Deterministic CI keeps protocol-compatible fakes, but the FR3 bearer-forwarding hazard is additionally proven against the real pinned Codex binary in a live-tagged test (credentialed host home → container home fresh/unseeded → captured request carries no Authorization header). That live evidence is required for 0.24 release completion per the graded evidence protocol, not per-commit CI.
Rationale: The hazard is a behavior of the real logged-in Codex binary; fakes pass by construction even against an implementation that copies host auth into the container.
Evidence: requirements-clarification.md technical evidence — a logged-in Codex forwarded its saved bearer despite requires_openai_auth=false.

Old:
```
- Keep provider CLIs and upstream APIs deterministic behind protocol-compatible local fakes; real Docker placement/network/image tests are mandatory because process-factory mocks cannot prove the OS boundary.
```
New:
```
- Keep provider CLIs and upstream APIs deterministic behind protocol-compatible local fakes; real Docker placement/network/image tests are mandatory because process-factory mocks cannot prove the OS boundary. The Codex bearer-forwarding hazard is additionally proven with the real pinned Codex binary in a live-tagged test (credentialed host home, fresh container home, captured request without Authorization); this recorded evidence is a 0.24 release-completion requirement, not per-commit CI.
```

#### DECISION NOTE: codex-container-home-materialization
Decision-Key: codex-container-home-materialization
Altitude: fis-local
Affected surface: Structural Criterion on the containerized Codex home
Decision: The auth-clean Codex home is generated host-side in the per-execution generated-state directory and bind-mounted read-write into the container; mount options are supplied through S02's ContainerManager create path while this story supplies the generated home path and contents. It is enumerated in mount/secret inspection and deleted with the authority's generated state on release; never the host user's Codex home.
Rationale: Re-check flagged the mount-option plumbing as unowned between stories; S02's create path already handles the sanctioned bridge-binary mount, so it carries per-execution mounts.
Evidence: ContainerExecutor lacks mkdir/chmod; containers run read-only with tmpfs.

Old:
```
- [ ] Containerized Codex always uses a newly created, permission-restricted home — generated host-side in the per-execution state directory and bind-mounted read-write into the container, never the host user's Codex home — that contains only required generated client configuration, is enumerated in mount/secret inspection, and is deleted on stop, crash, cancellation, and failed startup; host-mode Codex retains its existing user-home behavior.
```
New:
```
- [ ] Containerized Codex always uses a newly created, permission-restricted home — generated host-side in the per-execution state directory and bind-mounted read-write into the container through S02's ContainerManager create path (this story supplies the home path and contents), never the host user's Codex home — that contains only required generated client configuration, is enumerated in mount/secret inspection, and is deleted on stop, crash, cancellation, and failed startup; host-mode Codex retains its existing user-home behavior.
```

#### DECISION NOTE: codex-image-artifact-pin-and-integrity
Decision-Key: codex-image-artifact-pin-and-integrity
Altitude: project-decision
Affected surface: Structural Criterion on the packaged Codex release
Decision: The Dockerfile pins an exact Codex version and per-architecture sha256 checksum for the release archive; the build verifies the checksum before install and executes `codex --version` after. `latest` and unchecksummed fetches are rejected. Claude's install path is out of scope for this story.
Rationale: A version probe alone passes for any runnable binary from any source; the spike's verified behavior binds to a specific release line.
Evidence: docker/Dockerfile currently uses ARG CODEX_VERSION=latest with an unverified fetch.

Old:
```
- [ ] The container image defaults to an immutable, verified Codex release from the release's current Linux archive naming for every supported Docker architecture; `latest` is not an accepted default, and the build executes `codex --version` before succeeding.
```
New:
```
- [ ] The container image pins an exact Codex version and per-architecture sha256 checksum from the release's current Linux archive naming for every supported Docker architecture; the build verifies the checksum before install and executes `codex --version` before succeeding, and `latest` or unchecksummed fetches are rejected.
```

#### DECISION NOTE: container-mcp-bearer-removal-and-scan-scope
Decision-Key: container-mcp-bearer-removal-and-scan-scope
Altitude: fis-local
Affected surface: Constraints & Gotchas secret-inspection bullet; TI06 fixture sentinels
Decision: Containerized launches receive no shared operator MCP bearer in any generated configuration or environment (the execution-scoped bridge replaces it); the shared bearer is a first-class sentinel in the TI06 conformance fixture alongside provider credentials and login files, scanned across all enumerated container-visible surfaces. Gotcha amendment already applied and stands.
Rationale: Re-check found the decision stated only in the gotcha while every verification surface still enumerated provider credentials only — decided but unproven.
Evidence: Shared bearer written into container-visible MCP config today; PRD forbids exposing it as the container capability boundary.

Old:
```
  - Add a shared provider/surface matrix fixture with sentinel provider credentials/login files, actual Docker namespace probes, captured provider/MCP requests, inspectable argv/env/mounts/generated homes, bridge authority replay, and injected startup/runtime failures.
```
New:
```
  - Add a shared provider/surface matrix fixture with sentinel provider credentials/login files and a sentinel shared operator MCP bearer, actual Docker namespace probes, captured provider/MCP requests, inspectable argv/env/mounts/generated homes, bridge authority replay, and injected startup/runtime failures.
```

#### DECISION NOTE: failure-rejection-timing-partition
Decision-Key: failure-rejection-timing-partition
Altitude: requirements
Affected surface: OC04; Scenario S06 failure-timing mapping
Decision: Statically-detectable failures (missing container manager, mismatched profile, OAuth/setup-token container auth, unrunnable packaged CLI, unavailable provider adapter, unavailable MCP bridge) reject at admission; runtime failures (expired execution authority, container restart) terminate at the next mediated call. Scenario S06's When now maps each failure class to its timing, so deferring static checks to mid-turn cannot pass. OC04 amendment already applied and stands.
Rationale: Re-check showed S06's undifferentiated disjunction let a fully-deferred implementation pass while violating the amended OC04 and the PRD's pre-turn rejection NFR.
Evidence: PRD NFR: 100% of unsupported/failed container requests reject before turn execution.

Old:
```
  - **When** a Claude or Codex long-lived/workflow execution is admitted or performs its next mediated call
```
New:
```
  - **When** the execution requests admission — where the statically-detectable failures (missing container manager, mismatched profile, OAuth/setup-token container auth, unrunnable packaged CLI, unavailable provider adapter, unavailable MCP bridge) must reject — or performs its next mediated call, where the runtime failures (expired execution authority, container restart) terminate
```

#### DECISION NOTE: dual-platform-conformance-evidence-protocol
Decision-Key: dual-platform-conformance-evidence-protocol
Altitude: project-decision
Affected surface: TI06 Verify completion criterion
Decision: Story completion requires the six scenarios passing non-skipped on the executing platform; recorded non-skipped evidence on both Linux Docker and Docker Desktop is a 0.24 release-completion gate owned by S04's conformance matrix via the release checklist. Same graded protocol as S02/S04.
Rationale: One execution host cannot honestly produce two-platform evidence; S02's Testing Strategy already carves this out and the bundle must be consistent.
Evidence: No Docker-gated Dart test exists; single ubuntu CI job.

Old:
```
  - **Verify**: all six scenarios record non-skipped passing results on Linux Docker and Docker Desktop; focused unit tests
```
New:
```
  - **Verify**: all six scenarios pass non-skipped on the executing platform for story completion, with recorded evidence on both Linux Docker and Docker Desktop owned by S04's release conformance gate; focused unit tests
```

#### DECISION NOTE: codex-override-delivery-mechanism
Decision-Key: codex-override-delivery-mechanism
Altitude: fis-local
Affected surface: Technical Overview Codex override delivery
Decision: Custom-provider overrides (provider name, base URL, Responses wire API, requires_openai_auth=false) are delivered as generated configuration inside the ephemeral container home (config-layer per ADR-016), created per execution and deleted at release; nothing is persisted into or read from the host user's Codex home, and launch-time flags are used only where generated config cannot express a setting.
Rationale: ADR-016 records model_providers as config-layer; the ephemeral home already exists to carry generated client configuration, making it the verified delivery seam.
Evidence: ADR-016 configtoml-scope section; the FIS already sanctions the ephemeral home holding generated client config.

Old:
```
mode that never seeds authentication. Both app-server and exec receive ephemeral custom-provider overrides selecting the
S02 loopback endpoint, Responses protocol, and `requires_openai_auth=false`; no override is persisted into or read from the
user's Codex home. Generated state is deleted when the dedicated container authority is released.
```
New:
```
mode that never seeds authentication. Both app-server and exec receive ephemeral custom-provider overrides selecting the
S02 loopback endpoint, Responses protocol, and `requires_openai_auth=false`, delivered as generated configuration inside
the ephemeral container home (config-layer per ADR-016), with launch flags only where generated config cannot express a
setting; no override is persisted into or read from the user's Codex home. Generated state is deleted when the dedicated
container authority is released.
```

#### DECISION NOTE: mediation-loss-retry-semantics
Decision-Key: mediation-loss-retry-semantics
Altitude: fis-local
Affected surface: Scenario failure-handling Then clause
Decision: Mediation loss terminates the turn without in-turn fallback; the standard task retry policy may re-admit the work later through a fresh, fully validated authority. No special retry machinery is added.
Rationale: "Never retries through a stale bridge" forbids in-turn substitution, not the normal retry path, which re-runs full admission validation.
Evidence: Existing task retry semantics re-enter admission.

Old:
```
  - **Then** DartClaw rejects or terminates that execution at the responsible boundary, cleans up its ephemeral home and authority, and never retries through the host, direct network, native web, another profile, or stale bridge
```
New:
```
  - **Then** DartClaw rejects or terminates that execution at the responsible boundary, cleans up its ephemeral home and authority, and never retries in-turn through the host, direct network, native web, another profile, or stale bridge, while the standard task retry policy may later re-admit the work through a fresh, fully validated authority
```

#### DECISION NOTE: s02-s03-mediation-interface-terms
Decision-Key: s02-s03-mediation-interface-terms
Altitude: project-decision
Affected surface: Constraints & Gotchas identity-vocabulary bullet
Decision: One identity vocabulary, now stated in the body: "worker identity", "execution principal", and "effective principal" name the same S01 execution identity (session ID, worker identity, logical-agent ID when present); "S02's Claude adapter/provider endpoint" is the Anthropic Messages adapter and "S02's Codex gateway" is the OpenAI Responses adapter, both named in S02.
Rationale: Re-check ruled the note-only record unreconciled — the body must state the equivalence at an affected surface.
Evidence: Term usage verified across all four documents; S02 TI02 names both adapters.

Old:
```
- **One effective decision**: use the S01 location/profile attached to the execution request for construction, reuse, restart, and workflow one-shots. Never recalculate from task type or provider options.
```
New:
```
- **One effective decision**: use the S01 location/profile attached to the execution request for construction, reuse, restart, and workflow one-shots. Never recalculate from task type or provider options.
- **One identity vocabulary**: "worker identity", "execution principal", and "effective principal" name the same S01 execution identity; "S02's Claude adapter/provider endpoint" is the Anthropic Messages adapter and "S02's Codex gateway" is the OpenAI Responses adapter.
```
