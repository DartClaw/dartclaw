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
- `dev/architecture/security-architecture.md#ssrf-hardening-webfetchtool` – existing host network guardrails that remain
  on the network-performing side.
- `dev/architecture/control-protocol.md#mcp-integration` – current shared MCP URL/token configuration that cannot become
  container authority.

## Acceptance Scenarios

- [ ] **S01 [OC01,OC04] [TI03,TI04,TI05] Linux mediation preserves `network:none`**
  - **Given** a Linux Docker engine and S01's dedicated container/harness for execution A
  - **When** the provider and MCP loopback endpoints exchange framed requests with the host over their own
    `docker exec -i` pipes and the container probes an arbitrary Internet destination
  - **Then** authorized mediated requests succeed, the direct probe fails, and inspect shows `network:none` with no added
    network or host socket mount

- [ ] **S02 [OC01,OC04] [TI03,TI04,TI05] Docker Desktop uses the same out-of-band pipe**
  - **Given** Docker Desktop, where mounting a macOS AF_UNIX socket into the Linux VM is unsupported
  - **When** execution A starts and calls its provider and approved MCP surfaces
  - **Then** the same framed stdio bridge succeeds without a host socket, published port, internal network, dual-homed
    relay, or direct Internet path

- [ ] **S03 [OC02] [TI01,TI02,TI05] Provider mediation keeps reusable credentials host-only**
  - **Given** execution A has an active provider pipe and the host registry contains a sentinel provider credential
  - **When** its framed request reaches the matching provider adapter
  - **Then** the adapter validates the bound provider protocol/destination, adds the credential only to the host-to-provider
    request, streams the response, and the sentinel is absent from container env, mounts, argv, generated files, bridge
    state, logs, and errors

- [ ] **S04 [OC02,OC03] [TI01,TI02,TI05] Pipe identity cannot cross surfaces or destinations**
  - **Given** separate host-owned provider and MCP pipes for execution A
  - **When** a provider frame is sent on the MCP pipe, an MCP frame is sent on the provider pipe, a request selects another
    destination/protocol, or a malformed/oversized frame is sent
  - **Then** the host rejects before outbound/tool dispatch and records a bounded, secret-free denial

- [ ] **S05 [OC03] [TI01,TI02,TI05] MCP authorization is enforced on the host**
  - **Given** execution A is authorized for `web_search` but not another registered MCP tool
  - **When** its client invokes both tools directly rather than relying on client-side suppression
  - **Then** `web_search` reaches the existing host implementation and SSRF/content/audit protections, while the
    unapproved call is denied before `McpTool.call`

- [ ] **S06 [OC03,OC04] [TI01,TI04,TI05] Authority and frames cannot be replayed**
  - **Given** concurrent executions A and B own different containers and pipes, followed by release of A
  - **When** B attempts to inject A's captured frame/request ID or any caller writes to A's closed pipe after release
  - **Then** transport ownership or host registry rejects the attempt, no provider credential/MCP result is returned, and
    no cached container harness can reactivate A's authority

- [ ] **S07 [OC04] [TI03,TI04,TI05] Concurrency, backpressure, cancellation, and partial failures remain closed**
  - **Given** concurrent request IDs plus injected failures at bridge spawn, invalid length/type, queue saturation, host
    adapter timeout, response cancellation, pipe close, and container teardown
  - **When** DartClaw starts, uses, or releases an isolated execution
  - **Then** frames never interleave, configured bounds apply, cancellation reaches the matching request, the turn never
    starts with a partial boundary, and cleanup is idempotent with no host/direct-network fallback

## Structural Criteria

- [ ] Provider request adaptation and MCP authorization remain separate host implementations and separate pipes; there is
      no universal destination proxy.
- [ ] Pipe/process identity is the container authority. No shared Web UI bearer or reusable container-visible capability
      authenticates the bridge.
- [ ] Every agent container uses `network:none`; there is no relay, published port, host networking, added Docker network,
      Docker socket, or bind-mounted host socket.
- [ ] One live authority owns one container/process namespace, bridge-process set, generated state, and harness; release
      destroys them rather than caching the container runner.
- [ ] Framing is versioned and length-prefixed with surface, request ID, message kind, bounded metadata/body chunks,
      terminal/error/cancel messages, concurrency limits, backpressure, and malformed-frame rejection.
- [ ] The implementation introduces no user-facing relaxation knob or silent transport/provider fallback.

## Scope & Boundaries

### Work Areas

- Host-gateway lifecycle, per-authority pipe registry, and provider adapters under existing container/server boundaries
- Small Dart-owned loopback HTTP-to-framed-stdio bridge executable included in the agent image
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
cancel frames, bounded queues, and paused stream subscriptions enforce backpressure. EOF, malformed frames, unknown IDs,
or process/container exit fail all matching requests and revoke the pipe.

Provider adapters own fixed upstream URI/protocol and reusable credentials. MCP frames carry the principal/tool policy
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

- [ ] **TI01** Host pipe registry binds one authority, surface, policy, and lifetime
  - Define host-only registrations keyed by the spawned pipe/process with S01 principal/session/worker identity,
    provider-or-MCP audience, allowed MCP tools, readiness, active requests, and permanent revocation state.
  - **Verify**: Concurrent A/B and provider/MCP registrations accept only their own pipe while active; every pipe stays
    denied after close/release and no reusable credential/capability appears in container-visible state.

- [ ] **TI02** Provider and MCP frames reach separate host-enforced handlers
  - Adapt `CredentialProxy` into fixed provider handlers and add pipe-bound MCP authorization before discovery/call. Strip
    client auth headers before host credential injection; never accept arbitrary targets or the shared operator token.
  - **Verify**: Correct requests succeed; cross-surface, alternate-destination, client-auth, malformed, oversized, and
    unapproved-tool requests fail before upstream/tool dispatch; sentinels appear only at the fake provider upstream.

- [ ] **TI03** Dart-owned bridge framing is bounded, multiplexed, and backpressured
  - Add the small bridge executable and matching host codec with versioned length-prefixed frames, request IDs, bounded
    chunking/queues/concurrency, explicit completion/error/cancel, paused-stream backpressure, and deterministic EOF rules.
  - **Verify**: Protocol tests interleave concurrent requests and fragmented reads, saturate every bound, cancel one request
    without affecting another, fuzz invalid lengths/types/IDs, and prove byte-exact reconstruction with no unbounded buffer.

- [ ] **TI04** Dedicated `network:none` containers own bridge readiness and teardown
  - Make `ContainerManager` create one authority-owned container, start one `docker exec -i` bridge per required surface,
    wait for loopback readiness, then admit the harness. Release confirms root termination, revokes/closes pipes, removes
    generated state, and destroys the container idempotently on success, failure, cancellation, or quarantine.
  - **Verify**: Captured Docker calls and inspect output prove no networks/sockets/ports/relays, one namespace per concurrent
    authority, correct reverse-order cleanup for every injected failure, and no container runner enters the cache.

- [ ] **TI05** Cross-platform adversarial evidence proves the boundary
  - Add real-Docker provider/MCP fakes plus direct egress, cross-surface, cross-authority, framing, cancellation, cleanup,
    and sentinel-secret probes using the same contract on Linux Docker and Docker Desktop.
  - **Verify**: `packages/dartclaw_server/test/integration/scoped_host_gateway_integration_test.dart` records non-skipped
    passing evidence on both platforms; authorized calls succeed and every egress/tool/replay/framing/secret probe fails.

### Testing Strategy

- Unit-test the frame codec/state machines, pipe-bound authorization, request bounds, fixed destinations, header stripping,
  and idempotent lifecycle without Docker.
- Use existing fake command/process seams for exact Docker construction and cleanup assertions.
- Keep the real-Docker suite integration-tagged and self-cleaning. Local absence may skip a developer run, but 0.24 release
  completion requires recorded non-skipped Linux Docker and Docker Desktop evidence.

### Execution Contract

- S01, including its ADR-012 lifecycle amendment, completes before TI01–TI04.
- TI01 and TI03 settle the host/bridge protocol before handlers and container composition depend on it.
- Any need for a socket mount, added network, container bearer, shared namespace, or cached container harness is BLOCKED;
  it is not permission to weaken the PRD.

## Final Validation Checklist

- [ ] Container/bridge inspect output contains no reusable provider credential, shared token, published port, socket mount,
      or network other than `none`.
- [ ] No pipe/authority/container remains after release, including injected teardown failure paths.
- [ ] Non-skipped Linux Docker and Docker Desktop runs pass the same authorized/denied contract.

## Implementation Observations

_No observations recorded yet._
