# Feature Implementation Specification: Scoped Host Gateway

**Plan**: dev/bundle/docs/specs/0.24-execution-isolation/plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: Give isolated executions narrowly authorized access to host-owned provider and MCP services without exposing
reusable credentials or restoring agent Internet access.

**Expected Outcomes**:

- [OC01] Containerized executions reach host mediation on Linux and Docker Desktop while retaining Docker `network:none`.
- [OC02] Provider traffic is authenticated on the host through a provider-specific adapter, with no reusable credential
  exposed to the container or usable for another destination.
- [OC03] Host MCP calls are authorized for the exact execution principal and tool set; unapproved, cross-execution, and
  expired use is denied on the host.
- [OC04] Gateway, bridge-process, pipe, framing, or container failures stop the affected execution without weakening
  isolation, leaking secrets, interleaving streams, or leaving reusable authority behind.

## Required Context

- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#stories.1` – authoritative story scope and dependency.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#sharedDecisions` – surface separation, framed stdio transport,
  authority-owned container lifecycle, and verified-auth decisions.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#bindingConstraints` – secret, authorization, replay, and
  `network:none` constraints.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr3-host-owned-provider-credentials` – credential boundary,
  fixed provider destination, and secret-absence requirements.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr4-scoped-host-capabilities` – principal/tool authorization,
  framing, replay denial, portability, and no-egress requirements.
- `dev/bundle/docs/specs/0.24-execution-isolation/requirements-clarification.md#technical-evidence` – verified Codex
  auth-clean behavior, Docker Desktop host-socket failure, and `docker exec -i` byte-path proof.
- `dev/adrs/015-container-isolation-strategy.md#decision` – hardened Docker remains the accepted OS boundary.
- `dev/architecture/security-architecture.md#container-isolation` – current shared profile container and socket behavior
  replaced by S01's authority-owned lifecycle and this story's stdio bridge.
- `dev/architecture/control-protocol.md#execution-coordination-and-harness-reuse` – lifecycle that owns authority and pipe
  teardown.

## Deeper Context

- `dev/adrs/039-outbound-mcp-trust-boundary-and-transport.md#decision` – precedent for a small, Dart-owned, auditable MCP
  trust boundary.
- `dev/adrs/051-container-bridge-binary-packaging.md` – governs bridge build, shipping, container delivery, and handshake.
- `dev/adrs/047-embedded-binary-assets.md` – the shipping mechanism ADR-051 extends.
- `dev/architecture/security-architecture.md#ssrf-hardening-webfetchtool` – existing host network guardrails that remain
  on the network-performing side.
- `dev/architecture/control-protocol.md#mcp-integration` – current shared MCP URL/token configuration that cannot become
  container authority.

## Acceptance Scenarios

- [x] **S01 [OC01,OC04] [TI03,TI04,TI05] Linux mediation preserves `network:none`**
  - **Given** a Linux Docker engine and S01's dedicated container/harness for execution A
  - **When** the provider and MCP loopback endpoints exchange framed requests with the host over their own
    `docker exec -i` pipes and the container probes an arbitrary Internet destination
  - **Then** authorized mediated requests succeed, the direct probe fails, and inspect shows `network:none` with no added
    network or host socket mount

- [x] **S02 [OC01,OC04] [TI03,TI04,TI05] Docker Desktop uses the same out-of-band pipe**
  - **Given** Docker Desktop, where mounting a macOS AF_UNIX socket into the Linux VM is unsupported
  - **When** execution A starts and calls its provider and approved MCP surfaces
  - **Then** the same framed stdio bridge succeeds without a host socket, published port, internal network, dual-homed
    relay, or direct Internet path

- [x] **S03 [OC02] [TI01,TI02,TI05] Provider mediation keeps reusable credentials host-only**
  - **Given** execution A has an active provider pipe and the host registry contains a sentinel provider credential
  - **When** its framed request reaches the matching provider adapter
  - **Then** the adapter validates the bound provider protocol/destination, adds the credential only to the host-to-provider
    request, streams the response, and the sentinel is absent from container env, mounts, argv, generated files, bridge
    state, logs, and errors

- [x] **S04 [OC02,OC03] [TI01,TI02,TI05] Pipe identity cannot cross surfaces or destinations**
  - **Given** separate host-owned provider and MCP pipes for execution A
  - **When** a provider frame is sent on the MCP pipe, an MCP frame is sent on the provider pipe, a request selects another
    destination/protocol, or a malformed/oversized frame is sent
  - **Then** the host rejects before outbound/tool dispatch and records a bounded, secret-free denial

- [x] **S05 [OC03] [TI01,TI02,TI05] MCP authorization is enforced on the host**
  - **Given** execution A is authorized for `web_search` but not another registered MCP tool
  - **When** its client invokes both tools directly rather than relying on client-side suppression
  - **Then** `web_search` reaches the existing host implementation and SSRF/content/audit protections, while the
    unapproved call is denied before `McpTool.call`

- [x] **S06 [OC03,OC04] [TI01,TI04,TI05] Authority and frames cannot be replayed**
  - **Given** concurrent executions A and B own different containers and pipes, followed by release of A
  - **When** B attempts to inject A's captured frame/request ID or any caller writes to A's closed pipe after release
  - **Then** transport ownership or host registry rejects the attempt, no provider credential/MCP result is returned, and
    no cached container harness can reactivate A's authority

- [x] **S07 [OC04] [TI03,TI04,TI05] Concurrency, backpressure, cancellation, and partial failures remain closed**
  - **Given** concurrent request IDs plus injected failures at bridge spawn, invalid length/type, queue saturation, host
    adapter timeout, response cancellation, pipe close, and container teardown
  - **When** DartClaw starts, uses, or releases an isolated execution
  - **Then** frames never interleave, configured bounds apply, cancellation reaches the matching request, the turn never
    starts with a partial boundary, and cleanup is idempotent with no host/direct-network fallback

## Structural Criteria

- [x] Provider request adaptation and MCP authorization remain separate host implementations and separate pipes; there is
      no universal destination proxy.
- [x] Pipe/process identity is the container authority. No shared Web UI bearer or reusable container-visible capability
      authenticates the bridge.
- [x] Every agent container uses `network:none`; there is no relay, published port, host networking, added Docker network,
      Docker socket, or bind-mounted host socket.
- [x] One live authority owns one container/process namespace, bridge-process set, generated state, and harness; release
      destroys them rather than caching the container runner.
- [x] Framing is versioned and length-prefixed with surface, request ID, message kind, bounded metadata/body chunks,
      terminal/error/cancel messages, concurrency limits, backpressure, and malformed-frame rejection.
- [x] The implementation introduces no user-facing relaxation knob or silent transport/provider fallback.

## Scope & Boundaries

### Work Areas

- Host-gateway lifecycle, per-authority pipe registry, and provider adapters under existing container/server boundaries
- Small Dart-owned loopback HTTP-to-framed-stdio bridge executable, cross-compiled for linux-x64/arm64 at release time, shipped with DartClaw, and mounted read-only (or copied to an exec-capable tmpfs) at container create — the agent image stays Dart-free
- Principal-scoped MCP dispatch before tool discovery/call
- `ContainerManager` long-lived `docker exec -i` process/pipe lifecycle under `network:none`
- CLI composition that admits a container turn only after every required bridge surface is ready
- Unit, protocol, adversarial, and real-Docker coverage in existing server container/MCP and CLI wiring suites

### What We're NOT Doing

- Claude/Codex client settings, auth-clean Codex homes, or packaged Codex installation – S03 owns client attachment.
- Execution-policy configuration or ADR-012 lifecycle selection – S01 supplies both before this story.
- Arbitrary ACP credential/capability compatibility – S04 owns declarations and rejection.
- Network relays, general egress, destination allowlists, browsers, shells, package managers, or arbitrary APIs.
- User guides, final architecture synchronization, release notes, or the cross-provider matrix – S04 owns convergence.

## Architecture Decision

**Approach**: Keep every agent container on `network:none`. Start one small Dart-owned loopback bridge process per
provider/MCP surface through host-controlled `docker exec -i`; bind each pipe out of band to S01's unique container
authority and dispatch provider/MCP frames to separate host handlers.
**Why this over alternatives**: It works across Linux and Docker Desktop without host socket mounts or an egress-capable
relay, makes the pipe itself unforgeable by another container authority, and supports explicit framing/backpressure that raw
`socat` cannot provide.

## Technical Overview

Each bridge process listens only on a distinct container-loopback port and owns one bidirectional stdio pipe to the host.
The bridge parses bounded HTTP/1.1 traffic only far enough to produce versioned frames; the host associates the pipe with
one authority and one provider-or-MCP surface, so frames cannot select a surface or destination. Request IDs multiplex a
fixed maximum of in-flight requests without interleaving; length-prefixed metadata/body chunks, explicit terminal/error/
cancel frames, bounded queues, and paused stream subscriptions enforce backpressure. EOF, malformed frames,
or process/container exit fail all matching requests and revoke the pipe; a frame naming an unknown request ID is
ignored, because a bridge may legitimately cancel a request the host has already completed.

Provider adapters own fixed upstream URI/protocol and reusable credentials, and apply per-authority audit and the existing capacity/usage accounting to all pipe traffic; processes inside a container share their authority's trust domain, so any in-container caller of the loopback bridge is mediated identically (accepted, documented residual risk). MCP frames carry the principal/tool policy
bound to their host pipe; `tools/list` filters and `tools/call` independently authorizes before dispatch. S01 guarantees no
sibling process from another authority shares the container namespace. Admission starts the dedicated container, bridge
processes, and host readers before the harness; release terminates the harness, closes/revokes pipes, removes generated
state, and destroys the container before returning capacity.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_server/lib/src/container/credential_proxy.dart#CredentialProxy | Retain provider-specific fixed-destination streaming while replacing socket transport and permissive auth copying
file | packages/dartclaw_server/lib/src/container/container_manager.dart#ContainerManager | Own dedicated container plus streaming docker-exec bridge processes and teardown
file | packages/dartclaw_server/lib/src/mcp/mcp_router.dart#mcpRoute | Reuse bounded request/authorization semantics without exposing its shared bearer
file | packages/dartclaw_server/lib/src/mcp/mcp_server.dart#McpProtocolHandler | Enforce pipe-bound caller policy before list/call dispatch
file | packages/dartclaw_server/lib/src/execution_models.dart#ExecutionRequest | Carry S01 principal into host pipe registry
file | packages/dartclaw_server/lib/src/execution_coordinator.dart#ExecutionCoordinator.acquire | Own admission/release and prohibit container-runner caching
file | apps/dartclaw_cli/lib/src/commands/wiring/security_wiring.dart#SecurityWiring._wireContainers | Replace global proxy/shared-profile manager composition
test | packages/dartclaw_server/test/container/container_manager_test.dart#ContainerManager | Fake Docker process and lifecycle-failure patterns
test | packages/dartclaw_server/test/mcp/mcp_router_test.dart#mcpRoute | Bounded MCP authentication patterns
```

## Constraints & Gotchas

- **Critical**: Do not pass bridge authority as a bearer, file, environment value, argument, URL secret, or shared temp
  config. The host-created pipe and dedicated container are the authority boundary.
- **Critical**: No container harness caching – immutable startup endpoints and container-visible state cannot rotate safely
  between principals.
- **Critical**: Raw `socat ... STDIO` is proof of reachability only, not a production protocol; concurrent HTTP streams can
  interleave without Dart-owned framing and request IDs.
- **Avoid**: Letting frames, HTTP headers, or client URLs select an upstream – bind destination, protocol, credential source,
  accepted request shape, and MCP policy to the host-side pipe registration.
- **Constraint**: Framing carries untrusted streaming bodies – cap metadata, chunk, total request/response, queue depth,
  in-flight count, and idle/total duration; redact bodies and authority identifiers from failures.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** Host pipe registry binds one authority, surface, policy, and lifetime
  - Define host-only registrations keyed by the spawned pipe/process with the S01 execution principal — session ID,
    worker identity, and logical-agent ID when present, as carried on the execution request — plus provider-or-MCP
    audience, the effective container profile (carrying the restricted flag the provider adapters consult for
    native-web rejection), the allowed MCP tool set (canonical tool names, derived host-side from the effective agent definition's
    allowed/denied tools at registration; absent an explicit allowlist no tools are exposed), readiness, active requests,
    and permanent revocation state. The host maps canonical names to registered tool implementations through the existing
    canonical taxonomy at dispatch.
  - **Verify**: Concurrent A/B and provider/MCP registrations accept only their own pipe while active; every pipe stays
    denied after close/release and no reusable credential/capability appears in container-visible state.

- [x] **TI02** Provider and MCP frames reach separate host-enforced handlers
  - Adapt `CredentialProxy` into exactly two fixed provider handlers — Anthropic Messages for Claude and OpenAI Responses
    for Codex — each owning its upstream URI (existing provider endpoint configuration where present, else the provider
    default, pinned at registration), and add pipe-bound MCP authorization before discovery/call via a per-authority
    protocol-handler instance bound at pipe registration. Strip client auth headers before host credential injection;
    never accept arbitrary targets or the shared operator token; reject restricted executions' provider requests that
    declare provider-native web tools; emit authorization denials through the existing guard audit sink.
  - **Verify**: Correct requests succeed; cross-surface, alternate-destination, client-auth, malformed, oversized, and
    unapproved-tool requests fail before upstream/tool dispatch; sentinels appear only at the fake provider upstream.

- [x] **TI03** Dart-owned bridge framing is bounded, multiplexed, and backpressured
  - Add the small bridge executable and matching host codec with versioned length-prefixed frames, request IDs, bounded
    chunking/queues/concurrency, explicit completion/error/cancel, paused-stream backpressure, and deterministic EOF rules.
    The first exchange on every pipe is a protocol-version handshake that fails closed on mismatch. The bridge's bounded
    HTTP/1.1 server supports keep-alive; connections beyond the in-flight cap receive bounded queuing then rejection, and
    client disconnect cancels the matching in-flight request. The bridge is cross-compiled for linux-x64/arm64 in
    `dev/tools/build.sh` and the release workflow, shipped via the ADR-047 embedded-asset mechanism, and materialized
    arch-matched by the host per ADR-051.
  - **Verify**: Protocol tests interleave concurrent requests and fragmented reads, saturate every bound, cancel one request
    without affecting another, fuzz invalid lengths/types/IDs, and prove byte-exact reconstruction with no unbounded buffer.

- [x] **TI04** Dedicated `network:none` containers own bridge readiness and teardown
  - Make `ContainerManager` create one authority-owned container whose name derives from the profile plus a unique
    authority identifier (creation never removes another authority's container by shared name), start one
    `docker exec -i` bridge per required surface — the bridge binary delivered by read-only bind mount or exec-capable
    tmpfs copy per ADR-051 — wait for loopback readiness and a successful protocol handshake, then
    admit the harness. Health monitoring is authority-keyed and deregisters on release before teardown so a normal
    release is never attributed as a crash. Release confirms root termination, revokes/closes pipes, removes
    generated state, and destroys the container idempotently on success, failure, cancellation, or quarantine.
  - **Verify**: Captured Docker calls and inspect output prove no networks/sockets/ports/relays beyond the sanctioned
    read-only bridge-binary mount, one namespace per concurrent
    authority, correct reverse-order cleanup for every injected failure, and no container runner enters the cache.

- [x] **TI05** Cross-platform adversarial evidence proves the boundary
  - Add real-Docker provider/MCP fakes plus direct egress, cross-surface, cross-authority, framing, cancellation, cleanup,
    and sentinel-secret probes using the same contract on Linux Docker and Docker Desktop.
  - **Verify**: `packages/dartclaw_server/test/integration/scoped_host_gateway_integration_test.dart` passes non-skipped
    on the executing platform for story completion; authorized calls succeed and every egress/tool/replay/framing/secret
    probe fails. Recorded non-skipped evidence on both Linux Docker and Docker Desktop is a 0.24 release-completion gate
    owned by S04's conformance matrix via the release checklist.

### Testing Strategy

- Unit-test the frame codec/state machines, pipe-bound authorization, request bounds, fixed destinations, header stripping,
  and idempotent lifecycle without Docker.
- Use existing fake command/process seams for exact Docker construction and cleanup assertions.
- Keep the real-Docker suite integration-tagged and self-cleaning. Local absence may skip a developer run, but 0.24 release
  completion requires recorded non-skipped Linux Docker and Docker Desktop evidence. Scenario S01 is provable only on
  Linux Docker hosts and scenario S02 only on Docker Desktop; the off-platform scenario's evidence lands with that
  release gate rather than story completion.

### Execution Contract

- S01, including its ADR-012 lifecycle amendment, completes before TI01–TI04.
- TI01 and TI03 settle the host/bridge protocol before handlers and container composition depend on it.
- Any need for a socket mount, added network, container bearer, shared namespace, or cached container harness is BLOCKED;
  it is not permission to weaken the PRD.

## Final Validation Checklist

- [x] Container/bridge inspect output contains no reusable provider credential, shared token, published port, socket mount,
      or network other than `none`.
- [x] No pipe/authority/container remains after release, including injected teardown failure paths.
- [x] The suite passes non-skipped on the executing platform with the same authorized/denied contract; recorded non-skipped runs on both Linux Docker and Docker Desktop are the S04-owned release gate.

## Implementation Observations

#### DECISION NOTE: mcp-principal-identity-source
Decision-Key: mcp-principal-identity-source
Altitude: project-decision
Affected surface: TI01 host pipe registry identity, profile, and tool-policy source
Decision: The execution principal is the S01 execution identity carried on the execution request — session ID, worker identity, logical-agent ID when present — and the registration additionally records the effective container profile (carrying the restricted flag the provider adapters consult for native-web rejection). Effective tool policy derives host-side at registration from the agent definition's allowed/denied tools using canonical names, mapped via the existing taxonomy at dispatch; absent an explicit allowlist, no tools are exposed.
Rationale: TI02's restricted-execution web-tool rejection needs a carrier field in the registration record; the re-check found none.
Evidence: Re-check item 5; earlier evidence stands (ExecutionRequest fields; interview-ratified deny-by-default).

Old:
```
    worker identity, and logical-agent ID when present, as carried on the execution request — plus provider-or-MCP
    audience, the allowed MCP tool set
```
New:
```
    worker identity, and logical-agent ID when present, as carried on the execution request — plus provider-or-MCP
    audience, the effective container profile (carrying the restricted flag the provider adapters consult for
    native-web rejection), the allowed MCP tool set
```

#### DECISION NOTE: provider-adapter-set-and-upstream-uri
Decision-Key: provider-adapter-set-and-upstream-uri
Altitude: fis-local
Affected surface: TI02 provider handlers and MCP authorization structure
Decision: S02 delivers exactly two provider adapters — Anthropic Messages (Claude) and OpenAI Responses (Codex). Each owns its upstream URI, taken from existing provider endpoint configuration where present, else the provider default, pinned at adapter registration. MCP authorization uses a per-authority protocol-handler instance bound at pipe registration; denials emit through the existing guard audit sink; restricted executions' provider requests declaring provider-native web tools are rejected host-side.
Rationale: S03 consumes precisely these two endpoints; per-authority handler instances avoid threading caller context through the shared body-only handler; adapter-side web-tool rejection is the only host-enforced denial (client suppression is explicitly insufficient per binding constraint).
Evidence: `credential_proxy.dart` hardcodes only Anthropic; `McpProtocolHandler.handleRequest(String body)` has no caller parameter; PRD FR4 requires audited policy denial.

Old:
```
  - Adapt `CredentialProxy` into fixed provider handlers and add pipe-bound MCP authorization before discovery/call. Strip
    client auth headers before host credential injection; never accept arbitrary targets or the shared operator token.
```
New:
```
  - Adapt `CredentialProxy` into exactly two fixed provider handlers — Anthropic Messages for Claude and OpenAI Responses
    for Codex — each owning its upstream URI (existing provider endpoint configuration where present, else the provider
    default, pinned at registration), and add pipe-bound MCP authorization before discovery/call via a per-authority
    protocol-handler instance bound at pipe registration. Strip client auth headers before host credential injection;
    never accept arbitrary targets or the shared operator token; reject restricted executions' provider requests that
    declare provider-native web tools; emit authorization denials through the existing guard audit sink.
```

#### DECISION NOTE: bridge-executable-packaging
Decision-Key: bridge-executable-packaging
Altitude: adr
Affected surface: Work Areas bridge bullet; TI03 build/ship; TI04 delivery and conformance enumeration; Deeper Context references
Decision: Per ADR-051: the bridge is cross-compiled for linux-x64/arm64 in `dev/tools/build.sh` and the release workflow, shipped via the ADR-047 embedded-asset mechanism, materialized arch-matched by the host, and delivered into the container by read-only bind mount or exec-capable tmpfs copy at create. Conformance inspection enumerates the sanctioned read-only bridge-binary mount as expected (it is not a socket mount or network attachment). Protocol-version handshake fails closed on mismatch. Earlier Work Areas/TI03 amendments stand.
Rationale: Re-check found the build/delivery mechanism had no owning task text and the inspection assertions would read the sanctioned mount as a violation.
Evidence: ADR-051 and research appendix; ADR-047 shipping mechanism.

Old:
```
    client disconnect cancels the matching in-flight request.
```
New:
```
    client disconnect cancels the matching in-flight request. The bridge is cross-compiled for linux-x64/arm64 in
    `dev/tools/build.sh` and the release workflow, shipped via the ADR-047 embedded-asset mechanism, and materialized
    arch-matched by the host per ADR-051.
```

Old:
```
    `docker exec -i` bridge per required surface, wait for loopback readiness and a successful protocol handshake, then
```
New:
```
    `docker exec -i` bridge per required surface — the bridge binary delivered by read-only bind mount or exec-capable
    tmpfs copy per ADR-051 — wait for loopback readiness and a successful protocol handshake, then
```

Old:
```
  - **Verify**: Captured Docker calls and inspect output prove no networks/sockets/ports/relays, one namespace per concurrent
```
New:
```
  - **Verify**: Captured Docker calls and inspect output prove no networks/sockets/ports/relays beyond the sanctioned
    read-only bridge-binary mount, one namespace per concurrent
```

Old:
```
- `dev/adrs/039-outbound-mcp-trust-boundary-and-transport.md#decision` – precedent for a small, Dart-owned, auditable MCP
  trust boundary.
```
New:
```
- `dev/adrs/039-outbound-mcp-trust-boundary-and-transport.md#decision` – precedent for a small, Dart-owned, auditable MCP
  trust boundary.
- `dev/adrs/051-container-bridge-binary-packaging.md` – governs bridge build, shipping, container delivery, and handshake.
- `dev/adrs/047-embedded-binary-assets.md` – the shipping mechanism ADR-051 extends.
```

#### DECISION NOTE: per-authority-container-naming
Decision-Key: per-authority-container-naming
Altitude: fis-local
Affected surface: TI04 container creation/lifecycle
Decision: Container names derive from the profile plus a unique authority identifier; creation never removes another authority's container by shared name. Readiness includes the protocol handshake. Health monitoring becomes authority-keyed and deregisters on release before teardown, so a normal release is never attributed as a crash.
Rationale: Today's `generateName(dataDir, profileId)` is profile-keyed and `start()` runs `docker rm -f <name>`, which would let concurrent same-profile authorities destroy each other; the profile-keyed health monitor would log every normal release as a crash.
Evidence: `container_manager.dart:61-64,112`; `container_health_monitor.dart:16-63`.

Old:
```
  - Make `ContainerManager` create one authority-owned container, start one `docker exec -i` bridge per required surface,
    wait for loopback readiness, then admit the harness. Release confirms root termination, revokes/closes pipes, removes
    generated state, and destroys the container idempotently on success, failure, cancellation, or quarantine.
```
New:
```
  - Make `ContainerManager` create one authority-owned container whose name derives from the profile plus a unique
    authority identifier (creation never removes another authority's container by shared name), start one
    `docker exec -i` bridge per required surface, wait for loopback readiness and a successful protocol handshake, then
    admit the harness. Health monitoring is authority-keyed and deregisters on release before teardown so a normal
    release is never attributed as a crash. Release confirms root termination, revokes/closes pipes, removes
    generated state, and destroys the container idempotently on success, failure, cancellation, or quarantine.
```

#### DECISION NOTE: dual-platform-conformance-evidence-protocol
Decision-Key: dual-platform-conformance-evidence-protocol
Altitude: project-decision
Affected surface: TI05 Verify; Final Validation Checklist; Testing Strategy platform scoping
Decision: Story completion requires the integration suite passing non-skipped on the executing platform; recorded non-skipped evidence on BOTH Linux Docker and Docker Desktop is the S04-owned 0.24 release-completion gate via the release checklist. Scenario S01 is provable only on Linux Docker hosts and scenario S02 only on Docker Desktop; the off-platform scenario's evidence lands with the release gate, not story completion. Applies bundle-wide (TI05 amendment already applied and stands).
Rationale: One execution host cannot honestly satisfy both platform scenarios or the old checklist line; the graded protocol needed to reach all three surfaces that state completion conditions.
Evidence: Re-check found the checklist line and platform-split scenarios unreconciled.

Old:
```
- [ ] Non-skipped Linux Docker and Docker Desktop runs pass the same authorized/denied contract.
```
New:
```
- [ ] The suite passes non-skipped on the executing platform with the same authorized/denied contract; recorded non-skipped runs on both Linux Docker and Docker Desktop are the S04-owned release gate.
```

Old:
```
- Keep the real-Docker suite integration-tagged and self-cleaning. Local absence may skip a developer run, but 0.24 release
  completion requires recorded non-skipped Linux Docker and Docker Desktop evidence.
```
New:
```
- Keep the real-Docker suite integration-tagged and self-cleaning. Local absence may skip a developer run, but 0.24 release
  completion requires recorded non-skipped Linux Docker and Docker Desktop evidence. Scenario S01 is provable only on
  Linux Docker hosts and scenario S02 only on Docker Desktop; the off-platform scenario's evidence lands with that
  release gate rather than story completion.
```

#### DECISION NOTE: in-container-bridge-caller-constraint
Decision-Key: in-container-bridge-caller-constraint
Altitude: project-decision
Affected surface: Technical Overview provider-adapter paragraph
Decision: All processes inside a container share their authority's trust domain; any in-container caller of the loopback bridge is mediated identically — per-authority audit and the EXISTING capacity/usage accounting apply to all pipe traffic. No new budget-enforcement mechanism is introduced by this story. In-container process separation is out of scope — accepted, documented residual risk.
Rationale: The earlier wording's "budget" implied an unowned new mechanism contradicting the plan's "provider capacity accounting remains unchanged"; audit plus existing accounting is what host-side mediation actually provides.
Evidence: Re-check found "budget" appears nowhere else in the FIS and no mechanism exists.

Old:
```
Provider adapters own fixed upstream URI/protocol and reusable credentials, and apply per-authority accounting, budget, and audit to all pipe traffic; processes inside a container share their authority's trust domain, so any in-container caller of the loopback bridge is mediated identically (accepted, documented residual risk).
```
New:
```
Provider adapters own fixed upstream URI/protocol and reusable credentials, and apply per-authority audit and the existing capacity/usage accounting to all pipe traffic; processes inside a container share their authority's trust domain, so any in-container caller of the loopback bridge is mediated identically (accepted, documented residual risk).
```

#### DECISION NOTE: mcp-bridge-default-tool-policy
Decision-Key: mcp-bridge-default-tool-policy
Altitude: requirements
Affected surface: TI01 registry tool exposure (statement already present)
Decision: Bridged MCP is deny-by-default for all container profiles; only explicitly configured allowlists expose tools. Ratified by the operator in preflight interview.
Rationale: The empty-allowlist=allow-all convention would expose steward tools to containers; no container can reach host MCP today, so deny-by-default preserves all working behavior.
Evidence: `tool_policy_cascade.dart:44` allow-all convention; unreachable container MCP URL today.

#### DECISION NOTE: mcp-tool-namespace-for-allowlist
Decision-Key: mcp-tool-namespace-for-allowlist
Altitude: fis-local
Affected surface: TI01 canonical-name mapping (statement already present)
Decision: Allowlists use canonical tool names (web_search, web_fetch); the host maps canonical names to registered implementations (brave_search, tavily_search, web_fetch) via the existing canonical taxonomy at dispatch.
Rationale: Aligns bridge policy with the established policy vocabulary instead of registry-internal names.
Evidence: `_ownMcpToolCanonicals` in CLI wiring is the existing mapping.

#### DECISION NOTE: mcp-denial-audit-sink
Decision-Key: mcp-denial-audit-sink
Altitude: project-decision
Affected surface: TI02 denial auditing (statement already present)
Decision: Bridge authorization denials emit through the existing guard audit sink as audited policy denials; no new audit channel.
Rationale: PRD FR4 requires audited denial; the guard audit sink is the established channel.
Evidence: `McpProtocolHandler` performs no auditing today.

#### DECISION NOTE: container-health-monitor-fate
Decision-Key: container-health-monitor-fate
Altitude: fis-local
Affected surface: TI04 health monitoring (statement already present)
Decision: Health monitoring is authority-keyed; release deregisters before teardown so normal release is not a crash event.
Rationale: Profile-keyed monitoring would log every per-authority release as a crash, breaking PRD FR2 crash attribution.
Evidence: `container_health_monitor.dart` keys by profileId and fires ContainerCrashedEvent on unhealthy transitions.

#### DECISION NOTE: bridge-http-connection-and-cancel-semantics
Decision-Key: bridge-http-connection-and-cancel-semantics
Altitude: fis-local
Affected surface: TI03 bridge HTTP contract (statement already present)
Decision: The bridge's bounded HTTP/1.1 server supports keep-alive; connections beyond the in-flight cap get bounded queuing then rejection; client disconnect cancels the matching in-flight request.
Rationale: Sharp defaults an executor can implement without inventing connection semantics.
Evidence: Scenario AS07 requires cancellation reach the matching request without naming a trigger.

#### DECISION NOTE: mcp-caller-policy-structure
Decision-Key: mcp-caller-policy-structure
Altitude: fis-local
Affected surface: TI02 handler structure (statement already present)
Decision: A per-authority protocol-handler instance is bound at pipe registration; the shared body-only handler signature is not threaded with caller parameters.
Rationale: Pipe identity IS the authority, so instance binding is the smallest structure that carries caller policy.
Evidence: `mcp_server.dart:44` handleRequest(String body) has no caller parameter.

#### DECISION NOTE: native-web-denial-enforcement-point
Decision-Key: native-web-denial-enforcement-point
Altitude: project-decision
Affected surface: TI02 restricted-execution web-tool rejection (statement already present)
Decision: Provider-native web denial for restricted executions is enforced host-side in the provider adapters (reject requests declaring provider-native web tools), in addition to client-side config disabling. Client suppression alone is insufficient.
Rationale: Provider-native web executes server-side at the provider through the gateway, so network:none and client config cannot enforce it; binding constraint FR4 rejects client-side-only suppression.
Evidence: plan.json bindingConstraints (host-enforced authorization); Claude WebSearch / Codex web_search are provider-side tools.

### Run: 2026-08-11 21:20 UTC – observations

#### NOTICED BUT NOT TOUCHING

- `dev/tools/arch_check.dart` L2 core LOC ceiling is RED before this story and stays red: 16509 lines in `packages/dartclaw_core/lib` against a hard cap of 16500. S02 changes no file under `packages/dartclaw_core` (`git diff HEAD -- packages/dartclaw_core` is empty), so this is S01 residue. Bumping the ratchet requires the CHANGELOG justification its own comment demands, which belongs to the story that grew core.
- `docker/Dockerfile:38` — the Codex download URL 404s (`codex-linux-<arch>` is no longer published; the current asset is `codex-<arch>-unknown-linux-musl.tar.gz`), so `dartclaw-agent:latest` cannot be built at all on a machine without a cached image. Pre-existing since v0.13.0 and explicitly S03 scope ("packaged Codex installation"). The gateway integration suite therefore builds its own minimal `debian:bookworm-slim` + curl probe image; the container flags, bridge mount, and `network:none` posture it exercises are the real ones.
- `docs/guide/security.md` (§ credential proxy, lines ~129-169) and `docs/guide/architecture.md:346` still describe the removed `CredentialProxy` Unix-socket egress path; `dev/architecture/security-architecture.md` and `control-protocol.md` still describe the socat bridge. S04 owns user-guide and architecture convergence.
- `ContainerTaskFailureSubscriber._affectedBy` (`container_task_failure_subscriber.dart:55`) still maps a crashed `profileId` through the task-type profile default, so one authority container crash fails every running task of that profile. TD-120 tracks it; its entry is updated with what S02 did and did not change.
- `docker/Dockerfile` no longer installs `socat`: the framed bridge replaced the socat TCP-to-Unix relay, leaving it an orphan of this change inside a `network:none` container.

#### DECISIONS TAKEN WITHIN FIS LATITUDE

- The bridge lives in a new zero-dependency workspace package, `packages/dartclaw_bridge`, holding the wire contract plus the container entry point. Host and container compile against the same codec by construction, which is what ADR-051 means by lockstep; a relative import into another package's `lib/src/` would have violated `avoid_relative_lib_imports`, and the bridge must stay hook-free to cross-compile.
- Embedded bridge assets are gzipped and staged separately (`dev/tools/build_bridge.sh --embed` writes `build/bridge-embed/*.gz`; plain `build_bridge.sh` writes only `build/bridge/`). Embedding ~14 MB of AOT binaries as base64 is a release cost; a source checkout resolves the uncompressed binary from `build/bridge/` and its generated asset library stays empty.
- `HostGateway` depends on a narrow `ProviderMediator` interface rather than the `base` `ProviderAdapter` class, so tests can substitute a surface without subclassing the credential-injection path. `ProviderAdapter` stays `base` on purpose.
- The workflow one-shot path moved from a shared per-profile `ContainerExecutor` map to a `ContainerAuthorityProvider` seam: each container-policy turn leases its own authority and releases it in a `finally`. Keeping the shared managers would have left containers with no bridge and no provider access once `CredentialProxy` was removed.
- Bridged MCP allowlists are intersected against `CanonicalTool` stable names, so a provider-native tool name in an agent's `allowed_tools` never widens host MCP exposure. Tools with no canonical mapping sit behind `mcp_call`, matching the existing taxonomy.

#### PLATFORM EVIDENCE

- `packages/dartclaw_server/test/integration/scoped_host_gateway_integration_test.dart`: 14/14 non-skipped on Docker Desktop, macOS arm64 (engine arch `arm64`), 2026-08-11 21:19 UTC. That is scenario S02's platform. Scenario S01 needs a Linux Docker engine; per the FIS's dual-platform-conformance-evidence-protocol decision that recording is the S04-owned release gate, not a story-completion condition.

### Run: 2026-08-11 21:40 UTC – observations

#### REVIEW REMEDIATION (fresh-context Critic pass)

A fresh-context Critic review raised 13 findings; 12 were accepted and remediated, 1 was accepted and left as a note. Every remediation is re-verified by a test.

Accepted and fixed:
1. HIGH — `content-encoding` was forwarded to the container alongside a body the host `HttpClient` had already gunzipped, so every non-streamed provider response would have failed to decode inside the container. `content-encoding`/`content-md5` now join the dropped response headers. Pinned by a gzipped-upstream adapter test.
2. HIGH — the restricted-execution denial matched only `web_search*`/`web_fetch*` inside `tools[]`, leaving provider-hosted remote MCP connectors (`mcp_servers`, `tools[].type == mcp`) and provider-side code sandboxes as live egress paths that `network:none` cannot see. The check now counts every provider-side network-reaching tool family and the top-level connector array.
3. HIGH — `mcp_call` is the canonical name for *every* host MCP tool without a semantic canonical, so one allowlist entry would have exposed the knowledge-graph tools and every outbound third-party MCP adapter to a container. Bridged MCP now fails closed on any tool with no explicit canonical mapping, and the allowlist derivation never yields `mcp_call`.
4. MEDIUM — the denial reason interpolated tool identifiers lifted verbatim from the request body into the guard audit trail, violating this story's own "redact bodies from failures" constraint. It now reports a count only.
5. MEDIUM — `ContainerManager.stop()` discarded both docker exit codes, so a failed `docker rm -f` still fired `ContainerStoppedEvent` and left a live container that no later run reclaims. Removal is now confirmed against `isHealthy()` and raises otherwise.
6. MEDIUM — `requestTimeout` covered only handler resolution, so a stalled upstream could hold an in-flight slot indefinitely. The response stream now carries an idle timeout and the exchange a total budget.
7. MEDIUM — the backpressure comment described a pause mechanism that was never wired. `onPause`/`onResume` now pause and resume the pipe subscription; the comment states the byte bound that applies when a handler never listens.
8. MEDIUM — the adapters read an invented, undocumented, unvalidated `providers.<id>.options.base_url` that also silently dropped any path prefix. Removed: each adapter uses its provider default, which is what structural criterion 6 asks for.
9. MEDIUM — the bridge binary resolved a cwd-relative `build/bridge/` path *before* the shipped asset, so a released binary started from any directory containing that path would execute a planted file inside every container. The embedded asset now wins; the source tree is reached only when nothing shipped.
10. LOW — a materialized bridge of equal length was reused without comparing content; it is now rewritten unconditionally.
11. LOW — a bridge that cannot exec (musl image) surfaced only as a 30-second readiness timeout. Bridge stderr is now logged at warning on non-zero exit.
12. LOW — two narrow leak windows (a bridge process spawned but not attached; a lease acquired outside the workflow one-shot's try block) plus speculative public surface on the boundary (`supportsProvider`, `attachedSurfaces`, `BridgeChannel.closed`). Leaks closed, dead surface removed.

Accepted, routed to Note (needs a decision, not a mechanical fix):
- The FIS Technical Overview says unknown request IDs "fail all matching requests and revoke the pipe", while the implementation ignores frames for unknown IDs. Revoking would break the legitimate race where a bridge cancels a request the host has already completed, so the code is right and the FIS sentence is over-broad. Class: spec-stale. Left for the S04 documentation pass rather than resolved here.
