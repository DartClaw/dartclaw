# Product Requirements Document: Provider-Neutral Execution Isolation

> **Source Trust**: trusted-local
> **Context**: `dev/state/ROADMAP.md#024--logical-agent-correctness--scheduling-operability` and `dev/adrs/012-per-type-container-isolation.md#context`; 0.24 release correction for the mixed-execution gap.
> **Related Assets**: `dev/adrs/012-per-type-container-isolation.md`, `dev/adrs/015-container-isolation-strategy.md`, `dev/adrs/016-multi-provider-harness-architecture.md`, `dev/adrs/037-universal-acp-harness.md`, `dev/adrs/039-outbound-mcp-trust-boundary-and-transport.md`

## Executive Summary

- **Problem**: DartClaw cannot express the required mixed execution posture, and current provider paths do not consistently
  enforce their advertised container profile or deliver host-mediated tools to network-isolated containers.
- **Vision**: Operators can deliberately mix trusted host execution with isolated agents while every configured boundary
  is enforced, credentials stay host-owned, and restricted research remains useful through scoped host capabilities.
- **Target Users**: Single-operator DartClaw deployments, especially personal assistants that combine untrusted channel or
  web input with native coding work.
- **Success Metrics**: Every supported provider honors its resolved boundary; approved host web tools work from no-egress
  containers; direct container Internet remains blocked; provider credentials remain absent from containers;
  unsupported combinations are rejected before execution.

### Capabilities at a Glance

- **FR1: Per-Agent Execution Policy** _(Must / P0)_ – Select host or container execution per logical agent with a task-type fallback.
- **FR2: Enforced Multi-Harness Isolation** _(Must / P0)_ – Claude, Codex, and compatible ACP registrations honor the resolved boundary.
- **FR3: Host-Owned Provider Credentials** _(Must / P0)_ – Containerized providers authenticate without receiving reusable credentials.
- **FR4: Scoped Host Capabilities** _(Must / P0)_ – Approved MCP tools remain reachable from containers without general network access.
- **FR5: Fail-Closed Operations and Compatibility** _(Must / P0)_ – Invalid, contradictory, or unsupported postures are rejected and observable.

### Scope Highlights

- **In scope**: Per-agent execution, native task fallback, Claude/Codex container enforcement, compatible ACP validation,
  provider credential mediation, scoped host MCP access, migration/docs, and conformance tests.
- **Out of scope**: General or allowlisted direct container egress, universal ACP compatibility, universal forward proxy,
  VM backends, and macOS toolchains inside Linux containers.
- **MVP boundary**: One 0.24 deployment can run coding on the host while keeping untrusted-content agents in real no-egress
  containers that retain approved host tool access on Linux and Docker Desktop.

### Key Constraints, Assumptions & Dependencies

- *Constraint:* Existing container execution remains the default when `container.enabled` is true; weakening requires an
  explicit operator choice.
- *Constraint:* Provider credentials never enter a container through environment, mounts, arguments, or generated config.
- *Constraint:* Restricted Codex uses a fresh, unmounted client home; existing Codex login state must not enter or influence
  the container.
- *Constraint:* Containerized Claude supports only host-held `ANTHROPIC_API_KEY` mediation in 0.24; OAuth/setup-token
  authentication remains host-only until a stable credential-free gateway contract is proven.
- *Dependency:* ADR-012 must be reconciled with per-agent execution and provider-neutral enforcement.

## Problem Definition

### Problem Statement

Container isolation is currently selected globally and task security profiles are resolved by a fixed task-type mapping.
This forces operators to choose between fully native execution, which weakens isolation for untrusted channel and web
content, and fully containerized execution, which prevents coding workloads from using native macOS tooling, package
resolution, and full test suites.

The existing behavior also overstates its security guarantees. Claude containers can reach the Anthropic credential
gateway but cannot reach DartClaw's host MCP endpoint. Long-lived Codex and some ACP paths may carry a restricted profile
identity while running on the host. A policy label that is not enforced is worse than an explicit unsupported error because
operators cannot reason accurately about the boundary.

### Evidence & Context

- Field feedback reports a macOS assistant deployment that needs containerized chat, cron, channel, and search agents while
  coding tasks run natively.
- The workspace container uses Linux with `network:none`, so it cannot run macOS/Xcode tools or ordinary dependency and
  integration workflows.
- Task routing currently maps research to `restricted` and all other task types to `workspace` without configuration.
- Logical agents already select a security profile, establishing a per-agent configuration seam, but cannot select host execution.
- The host registers guarded web search/fetch tools, yet the container receives a host-loopback MCP URL without a reachable bridge.
- DartClaw is multi-harness by design; security behavior that only works for Claude contradicts the product contract.
- A 2026-08-11 spike proved Codex 0.146 can call a custom Responses gateway without auth from a fresh container, while a
  logged-in Codex process forwarded its saved bearer and Docker Desktop rejected a bind-mounted host Unix socket. A
  follow-up proof carried bytes over `docker exec -i` with the container still on `network:none`.
- Current Claude OAuth/setup-token mode mounts host auth into the container, and no stable credential-free subscription
  OAuth gateway contract is documented; it cannot satisfy the accepted secret boundary in 0.24.
- 0.24 is awaiting release, so this defect is a release correction rather than a later roadmap feature.

## Scope

### In Scope

- A restart-required execution setting for the primary/default agent and each logical agent.
- A task-type execution fallback for tasks that do not carry logical-agent identity.
- Resolution precedence and worker compatibility that keep provider constraints, host/container execution, and container
  filesystem posture unambiguous.
- Actual host and container execution for Claude and Codex.
- ACP registration validation that permits only execution modes the registered agent can uphold.
- Host-owned credential mediation for supported containerized provider authentication modes.
- Host-mediated MCP access scoped to the effective agent/session/tool policy.
- Preservation of `network:none` through a host-controlled, bounded framed stdio bridge over `docker exec -i`.
- Secret-free diagnostics, audit events, startup validation, user documentation, architecture documentation, ADR lineage,
  and end-to-end conformance coverage.

### Out of Scope

- Direct container Internet access, including a Docker bridge-network research profile.
- Destination-level egress presets for browsers, shells, package managers, or arbitrary APIs.
- Passing reusable provider credentials into a container.
- Claiming that every ACP binary supports containerized provider access.
- Persisting logical-agent identity onto every existing background task.
- Runtime mutation of execution-boundary settings.
- New container, VM, or macOS virtualization backends.

### MVP Boundary

The 0.24 release is ready when an operator can explicitly run coding agents and coding task types on the host while all
other configured execution remains containerized by default; supported containerized providers authenticate through
host-owned mediation; approved search/fetch calls traverse a host-authorized capability path; and every unsupported or
failed boundary is rejected without fallback.

## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As an operator, I want each logical agent to select host or container execution so that trust posture follows the agent's work. | Two logical agents using the same provider can run concurrently with different enforced execution modes and cannot reuse each other's worker. | Must / P0 |
| US02 | As an operator, I want a task-type fallback so that coding tasks without agent identity can use native toolchains. | `coding` can resolve to host while `research` resolves to a restricted container in the same deployment. | Must / P0 |
| US03 | As an operator, I want provider-neutral enforcement so that security labels match actual process placement. | Claude and Codex honor host/container requests; compatible ACP registrations honor required isolation; unsupported requests fail. | Must / P0 |
| US04 | As a research user, I want approved search and fetch from an isolated agent so that research works without arbitrary container egress. | A restricted container completes approved search/fetch through the host while direct Internet requests remain blocked. | Must / P0 |
| US05 | As an operator, I want credentials retained on the host so that a compromised container cannot recover provider secrets. | Supported containerized provider flows authenticate successfully without credential material in container-visible surfaces. | Must / P0 |
| US06 | As an operator, I want actionable failures and warnings so that deliberate native execution is visible and unsupported isolation never fails open. | Startup/dispatch names the affected provider or configuration path and never silently downgrades execution. | Must / P0 |

### Feature Specifications

#### FR1: Per-Agent Execution Policy

**Description**: DartClaw must resolve an explicit host or container execution mode for its primary/default agent and each
logical agent. Background tasks that lack logical-agent identity must use a separate task-type fallback. Existing container
behavior remains the default when container isolation is enabled.

**Acceptance Criteria**:

- [ ] The primary/default agent and every logical-agent definition may inherit or explicitly select host/container execution.
- [ ] Background task types may explicitly select host execution without changing unrelated task types or logical agents.
- [ ] Resolution distinguishes execution location from container filesystem/security profile.
- [ ] Host and container executions have different worker/cache identities and are never substituted for each other.
- [ ] Explicitly weakened host selections produce a startup warning naming the affected agent or task type.
- [ ] Existing configurations retain their effective default execution behavior.

**Resolution Precedence**:

| Request context | Requested mode |
|-----------------|----------------|
| Logical agent with an explicit execution setting | Use that setting. |
| Logical agent without an explicit execution setting, or the primary agent | Inherit the primary/default agent setting. |
| Background task without logical-agent identity and with a task-type override | Use the task-type override. |
| Background task without a task-type override | Use the deployment default derived from whether containers are enabled. |

Provider and platform requirements validate the requested mode after this lookup. A conflict is rejected; it is never
silently weakened, strengthened, or substituted. Container profiles are valid only for container mode.

**Inputs / Outputs**:

- **Inputs**: Restart-time YAML configuration, logical-agent identity when present, task type when present, provider identity,
  and provider-enforced minimum requirements.
- **Outputs**: One validated effective execution policy and compatible worker identity per execution request.

**Validation**:

- Reject unknown modes, unknown task types, contradictory host/profile combinations, and explicit container requests when
  containers are unavailable.
- Providers may declare a stronger minimum boundary, but an operator selection below that minimum is rejected rather than
  upgraded or substituted automatically.

**Error Handling**:

- Invalid settings identify the exact YAML path and accepted values.
- No invalid or unsupported policy falls back to host execution.

**Priority**: Must / P0

#### FR2: Enforced Multi-Harness Isolation

**Description**: Every supported harness must execute at the location represented by the effective policy. Claude and Codex
are first-class 0.24 targets. ACP registrations may use only modes whose required launch, credential, and host-capability
mechanisms they declare and satisfy.

**Acceptance Criteria**:

- [ ] Claude host and container requests launch through their corresponding process boundary.
- [ ] Codex host and container requests launch through their corresponding process boundary.
- [ ] Workflow-owned and ordinary executions apply the same effective policy rather than diverging by runner path.
- [ ] Direct/verified ACP registrations may use host execution only when allowed by effective policy.
- [ ] Relay, unverified, or otherwise container-required ACP registrations cannot discard their required container manager.
- [ ] A harness unable to uphold the requested mode is rejected before its turn begins.
- [ ] Every live container authority owns one container/process namespace, harness lifetime, bridge pipe set, and generated
      state; container harnesses are disposed rather than cached across authority release.
- [ ] Shutdown, crash attribution, reuse, and capacity accounting remain correct across distinct execution identities.

**Inputs / Outputs**:

- **Inputs**: Effective execution policy, harness/provider capabilities, and execution request metadata.
- **Outputs**: An enforced harness process or a typed unsupported-capability failure.

**Validation**:

- Conformance tests must inspect real process placement and reachable resources, not only profile identifiers or generated
  configuration.

**Error Handling**:

- Unsupported provider/mode diagnostics name the provider, requested mode, and remediation without exposing secrets.

**Priority**: Must / P0

#### FR3: Host-Owned Provider Credentials

**Description**: Supported containerized providers must authenticate through a provider-specific host boundary. Provider
credentials remain absent from container-visible environment variables, files, arguments, and generated client configuration.

**Acceptance Criteria**:

- [ ] Containerized Claude uses host-held `ANTHROPIC_API_KEY` mediation without receiving the key; OAuth/setup-token
      combinations are rejected with deliberate host execution as the supported alternative.
- [ ] Codex uses a custom Responses provider pointed at the host gateway from a fresh client home with no reusable login
      state, mounted host config, or provider credential.
- [ ] The packaged container installs a pinned Codex release using its current platform asset naming.
- [ ] Credential requests are constrained to the configured provider destination and protocol surface.
- [ ] Provider adapters cannot turn the credential boundary into arbitrary Internet access.
- [ ] Future harnesses add explicit provider adapters or declare container authentication unsupported.
- [ ] ACP registrations without a compatible provider-credential mechanism are unavailable in container mode.

**Inputs / Outputs**:

- **Inputs**: Host credential registry, provider identity, supported authentication mode, and provider request stream.
- **Outputs**: Authenticated provider traffic or a typed, secret-free authentication/capability failure.

**Validation**:

- Container inspection and adversarial tests verify that credential values are absent from environment, mounts, arguments,
  generated config, and error output.
- Provider destinations and accepted request shape are validated before forwarding.

**Error Handling**:

- Missing or incompatible credentials prevent provider startup or turn admission; no credential copy fallback is allowed.

**Priority**: Must / P0

#### FR4: Scoped Host Capabilities

**Description**: Containerized agents must reach approved DartClaw MCP capabilities through a host-authorized transport while
direct agent egress remains disabled. Authorization must be enforced on the host for the effective principal and tool set
rather than trusted to client-side tool suppression.

**Acceptance Criteria**:

- [ ] A restricted Claude container can call its approved DartClaw search/fetch tools.
- [ ] A restricted Codex container can call its approved DartClaw search/fetch tools.
- [ ] The bridge carries or resolves sufficient caller context to enforce per-agent/session tool policy on the host.
- [ ] Bridge authorization is bound to one execution principal and lifetime; authorization captured from one agent,
      session, or worker cannot be replayed by another or after the originating execution ends.
- [ ] Direct invocation of an unapproved MCP tool is rejected by the host.
- [ ] The bridge does not expose the shared operator/steward MCP surface without scoped authorization.
- [ ] Existing host SSRF, content, audit, and outbound-MCP protections remain on the network-performing side.
- [ ] Linux and Docker Desktop retain `network:none` and use host-controlled, surface-separated framed stdio pipes over
      `docker exec -i`; the design requires neither a host AF_UNIX mount nor an egress-capable relay.
- [ ] Restricted execution cannot invoke unmediated provider-native search or fetch as a fallback.
- [ ] Arbitrary direct Internet requests from the same container continue to fail.

**Inputs / Outputs**:

- **Inputs**: Container MCP request, authenticated execution principal, resolved tool policy, and host tool registry.
- **Outputs**: Approved tool result or audited policy denial.

**Validation**:

- The transport authenticates every request and enforces bounded payloads and tool exposure.
- Framing carries a surface and request ID with explicit length bounds, concurrency limits, backpressure, cancellation,
  malformed-frame rejection, and deterministic pipe/process teardown; raw `socat` multiplexing is not sufficient.
- End-to-end tests make real MCP calls from a no-egress container on Linux and Docker Desktop and directly probe denied
  Internet/tool paths.
- Concurrency and reuse tests prove that credentials captured by execution A are denied from execution B and after A ends.
- Restricted Codex tests prove native web search cannot bypass the approved host capability path.

**Error Handling**:

- Bridge startup, authentication, or authorization failure fails the turn closed without switching to provider-native or
  direct-network behavior silently.

**Priority**: Must / P0

#### FR5: Fail-Closed Operations and Compatibility

**Description**: Operators must be able to understand the effective boundary, deliberate exceptions, and unsupported
combinations. Documentation and ADRs must describe actual provider behavior, and validation must prevent misleading
security claims.

**Acceptance Criteria**:

- [ ] Startup output lists deliberate host-execution overrides and unavailable provider/mode combinations without secrets.
- [ ] Configuration errors use stable, actionable paths and accepted-value guidance.
- [ ] Architecture and user guides distinguish execution mode, container security profile, provider credential mediation,
  and host capability mediation.
- [ ] ADR-012 is amended or superseded with explicit lineage.
- [ ] The 0.24 release notes include the mixed-execution capability and the corrected research/container behavior.
- [ ] Cross-provider tests cover Claude, Codex, supported ACP, workflow one-shots, ordinary tasks, logical agents, and failure paths.
- [ ] Existing 0.24 memory-plan artifacts remain unchanged and independently executable.

**Inputs / Outputs**:

- **Inputs**: Validated deployment configuration, provider capability inventory, runtime health, and documentation baseline.
- **Outputs**: Clear diagnostics, accurate documentation/ADR state, and a passing conformance matrix.

**Validation**:

- Claims must be backed by an integration path that performs the action; generated-config or profile-label assertions alone
  are insufficient.

**Error Handling**:

- A failed conformance path blocks release readiness rather than being documented as supported with caveats.

**Priority**: Must / P0

### User Flows

1. Operator enables containers, configures `search` for restricted container execution, configures `coder` for host
   execution, and configures coding task fallback for host execution.
2. DartClaw validates the full provider/execution matrix at startup and reports deliberate native exceptions.
3. A coding logical agent or coding background task receives a host worker and uses the native project toolchain.
4. A search logical agent or research task receives a restricted container worker and invokes approved web tools through
   the scoped host capability boundary.
5. Host-side policy performs network access and returns the bounded result while direct container Internet remains blocked.
6. If any requested provider cannot satisfy its boundary, DartClaw rejects that execution with remediation guidance.

## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Security | Provider secrets stay host-owned | Zero credential values in container env, mounts, args, generated config, logs, or errors |
| Security | Container network isolation remains effective | Every agent container uses `network:none`; arbitrary direct egress probe fails |
| Authorization | Host capabilities enforce caller scope | Every bridged MCP call authenticates a principal and denies tools outside the effective policy |
| Reliability | Isolation never degrades silently | 100% of unsupported/failed container requests reject before turn execution |
| Correctness | Provider labels match process placement | Conformance tests prove actual host/container execution for every supported harness path |
| Compatibility | Existing config defaults remain stable | No effective execution change without a new explicit override |
| Operability | Diagnostics are actionable and secret-free | Every rejection names provider/config surface and remediation; no secret-pattern matches |
| Resource safety | Mediation remains bounded and streaming | Existing request/body/result bounds apply; no unbounded buffering is introduced |

## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|----------|-------------------|---------------|
| Containers disabled but an agent explicitly requires one | Startup or dispatch rejects; host fallback is forbidden | Enable containers or select host explicitly where policy permits |
| Host mode configured with a container-only profile | Configuration is rejected as contradictory | Remove the profile or select container execution |
| Codex auth mode lacks secure mediation | Container mode is unavailable for that provider/auth combination | Use supported auth or deliberate host execution |
| Claude OAuth/setup-token is selected for container mode | Reject before spawn because the reusable credential would enter the container | Configure host-held `ANTHROPIC_API_KEY` or deliberate host execution |
| ACP binary has unknown topology or credential needs | Treat as unverified/container-required but unavailable until compatible transport is declared | Complete registration capability configuration |
| Scoped MCP bridge is unhealthy | Affected container turns fail before tool execution | Repair/restart bridge; no direct-network fallback |
| Agent bypasses client tool filtering and calls MCP directly | Host policy denies and audits the call | Correct allowlist only through operator configuration |
| Provider gateway receives another destination or protocol | Request is rejected | Use an explicitly supported provider adapter |
| Cached worker was created for another boundary | Worker is incompatible and not reused | Create a matching worker within capacity |
| Research has no configured host search provider | Search is unavailable with an actionable diagnostic; restricted execution does not fall back to unmediated provider-native search | Configure an approved host-mediated search provider |
| Windows requests container execution | Typed platform-capability rejection | Use host execution or a supported POSIX deployment |

## Constraints & Assumptions

### Constraints

- DartClaw remains a single-user, single-deployment runtime; multi-tenant policy administration is excluded.
- Containers use the existing hardened Docker model with `network:none`; a bounded Dart-owned framed stdio bridge over
  `docker exec -i` is the only container-to-host mediation path.
- One live container authority owns one container/process namespace and harness. Container harnesses are disposed on
  authority release after confirmed process termination, pipe revocation, and generated-state cleanup; they do not enter
  the reusable worker cache.
- Execution-boundary configuration is restart-required.
- `Task` currently has task type but no logical-agent identity; 0.24 uses a task-type fallback rather than a persistence migration.
- Provider-specific behavior stays behind harness/composition boundaries; scheduling remains provider-neutral.
- The implementation must preserve current provider capacity and primary-lane semantics.
- The existing shared inbound MCP token does not establish per-caller identity and cannot be exposed unchanged as the
  container capability boundary.

### Assumptions

- Claude and Codex CLIs expose sufficient request/config seams to support secure host-owned mediation. The Codex 0.146
  custom Responses-provider seam is verified; only an auth-clean container home is safe.
- Operators accept explicit host execution as a deliberate weakening of OS isolation for trusted workloads.
- Existing host web guards remain the correct enforcement point for fetched/search content.
- Breaking internal APIs and config refinements are acceptable before stable release, but default behavior should remain
  conservative and migration should be documented.

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| ADR-012 and ADR-015 | Define current container/profile posture and require reconciliation |
| ADR-016 and ADR-037 | Define multi-provider and ACP harness boundaries |
| ADR-039 | Defines outbound MCP trust and egress governance |
| ExecutionCoordinator | Owns provider/profile compatibility, reuse, capacity, and quarantine |
| ContainerManager | Owns hardened per-authority container construction and framed bridge-process/pipe lifecycle |
| CredentialRegistry | Resolves host-owned provider credentials |
| Internal MCP server and guard chain | Own host capabilities, authorization, SSRF/content policy, and auditing |
| Claude Code and Codex CLI behavior | Determines provider-specific gateway protocols and auth-clean launch requirements |

## Decisions Log

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| Target 0.24 as a release blocker | The production feedback invalidates the intended security/usefulness posture | Defer to 0.25; document workaround |
| Use a parallel `0.24-execution-isolation` bundle | The existing 0.24 plan covers unrelated memory work and must remain independently executable | Merge unrelated stories into the existing plan |
| Configure execution per logical agent with task-type fallback | Agents carry trust/capability identity, while existing background tasks do not carry agent identity | Task type only; add agent identity migration to Task |
| Preserve container execution as the enabled default | Avoids silently weakening current deployments | Make coding native by default |
| Keep raw container networking disabled | Current search/fetch needs can be safely host-mediated | Docker bridge or unrestricted Internet |
| Use framed `docker exec -i` mediation | It preserves `network:none` on Linux and Docker Desktop and binds the host pipe out of band to one authority | Host Unix-socket mount; internal-network relay |
| Do not cache container harnesses across authority release | Shared namespaces and immutable startup credentials cannot enforce cross-principal replay denial | Per-profile shared containers; bearer rotation in a shared namespace |
| Limit containerized Claude to API-key mediation | OAuth/setup-token requires container-visible auth and has no verified credential-free gateway contract | Mount `~/.claude.json`; speculative OAuth relay |
| Separate provider credential gateways from host MCP capabilities | The two boundaries carry different authority and risks | Generalize CredentialProxy into one universal proxy |
| Require host-owned provider credentials | Maintains defense-in-depth if a container is compromised | Read-only credential mounts; env injection |
| Support Claude and Codex directly, ACP by declared compatibility | Satisfies the multi-harness promise without making false claims about arbitrary agents | Claude-only support; universal ACP guarantee |
| Fail unsupported combinations closed | Security labels must describe real enforcement | Warn and fall back to host |
