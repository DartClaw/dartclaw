# Requirements Clarification: Provider-Neutral Execution Isolation

> **Source Trust**: trusted-local

## Summary

DartClaw 0.24 must let an operator choose host or container execution per logical agent while retaining a task-type
fallback for background tasks that do not carry logical-agent identity. Container execution must be enforced consistently
for Claude, Codex, and explicitly compatible ACP registrations, with provider credentials retained on the host and
host-mediated tools available without granting containers general network access.

## Scope

### In Scope

- Per-logical-agent host or container execution selection, with the existing container posture remaining the default.
- A task-type host-execution fallback for background tasks that do not identify a logical agent, including native coding.
- Real container enforcement for Claude and Codex rather than treating a security-profile label as enforcement.
- Fail-closed ACP capability declaration and validation for container-required registrations.
- Provider-specific, host-owned credential mediation for containerized Claude and Codex.
- A capability-scoped container-to-host bridge for approved MCP tools such as `web_search` and `web_fetch`.
- 0.24 documentation, configuration examples, migration notes, and cross-provider conformance tests.
- Reconciliation of ADR-012 with the new execution-selection and mediation model.

### Out of Scope

- General container Internet access.
- Direct browser, shell, package-manager, or arbitrary API egress from containers.
- Guaranteed container support for every possible ACP implementation.
- A universal credential-injecting forward proxy accepting arbitrary destinations.
- New VM isolation backends or macOS-in-container emulation.

### MVP Boundary

0.24 is complete when one deployment can keep chat, channel, cron, and search agents containerized while explicitly
running its coding agent and coding background tasks on the host; containerized Claude and Codex can call only their
provider API and approved host MCP tools; and unsupported ACP/provider combinations are rejected rather than silently
running with weaker isolation.

### Not Doing (for now)

- Allowlisted direct container egress – no demonstrated 0.24 workflow requires the DNS, redirect, IP, method, and binary
  enforcement needed to make it safe.
- Runtime-editable isolation policy – execution-boundary changes remain restart-required because they affect process and
  container construction.
- Arbitrary ACP credential brokering – ACP is a protocol spanning heterogeneous agents, so only declared mechanisms can
  be supported safely.

## Functional Requirements

### User Stories

- As an operator, I want to choose host or container execution for each logical agent so that trusted coding agents can
  use native toolchains without weakening untrusted-content agents.
- As an operator, I want background task types without agent identity to have an explicit execution fallback so that
  coding tasks can run natively while research tasks remain isolated.
- As an operator, I want container requests enforced consistently across harnesses so that a `restricted` label never
  masks host execution.
- As a research-agent user, I want search and fetch to work from a network-isolated container so that research remains
  useful without arbitrary Internet access.
- As an operator, I want provider and ACP incompatibilities rejected clearly so that configuration never fails open.

### Core Flows

1. Operator enables containers and retains container execution as the deployment default.
2. Operator configures a coding logical agent for host execution and configures coding background tasks for host fallback.
3. DartClaw resolves an execution request through provider constraints, logical-agent override, task fallback, and the
   deployment default, producing a distinct worker identity for each effective boundary.
4. A containerized Claude or Codex agent authenticates to its provider through a provider-specific host gateway without
   receiving the provider secret.
5. A restricted search or research execution calls an approved MCP web tool through a scoped host bridge; the host
   performs network I/O and applies its guards.
6. A requested provider/execution combination that cannot uphold the policy is rejected before execution.

### Alternate Flows

- With containers disabled, host execution remains available; an explicit container requirement is rejected clearly.
- A verified ACP registration may run on the host when permitted; a relay or unverified registration that requires a
  container must prove compatible launch, credential, and capability transport before it can start.
- A logical agent without an explicit execution setting inherits the deployment default.
- A background task without logical-agent identity resolves through its task-type fallback before the deployment default.

## Design Decisions

### Design Space Decomposition

Provider-neutral isolation
- Execution selection: per logical agent ← chosen | task type only | one global switch
- Background-task selection: task-type fallback ← chosen | add agent identity to every task | inherit global only
- Container Internet: none + mediated host capabilities ← chosen | destination allowlist | unrestricted bridge
- Credential handling: provider-specific host gateways ← chosen | credentials mounted into containers | universal proxy
- Provider coverage: Claude + Codex, declared-compatible ACP ← chosen | Claude only | every ACP implementation
- Failure policy: reject unsupported combinations ← chosen | warn and run on host | best-effort container

### Cross-Consistency Notes

- A `network:none` container is compatible with useful research only when approved host capabilities have a reachable
  scoped bridge. The portable path is a host-controlled, bounded framed stream over `docker exec -i`; it does not attach
  the container or a relay to an egress-capable network.
- Host execution cannot claim a container security profile; configuration and worker identity must keep these concepts
  distinct.
- Requiring support for arbitrary ACP binaries is incompatible with fail-closed credential mediation because ACP does not
  standardize provider endpoint or authentication transport.
- A shared unrestricted MCP endpoint is incompatible with per-agent tool policy; the bridge must carry a scoped principal
  or expose a per-execution tool surface.

### Resolved Decisions

| Dimension | Choice | Rationale |
|-----------|--------|-----------|
| Release | Required for 0.24 | The defect blocks the intended SecondBrain security posture. |
| Bundle location | Parallel `0.24-execution-isolation` directory | Preserves the existing 0.24 memory plan as a separate initiative. |
| Default execution | Preserve current container default when enabled | Avoids silently weakening existing deployments. |
| Native opt-out | Per logical agent plus task-type fallback | Logical agents need individual policy; current task records lack agent identity. |
| Provider scope | Claude and Codex; compatible ACP registrations | Meets the multi-harness product promise without claiming arbitrary ACP compatibility. |
| Secret boundary | Provider credentials never enter containers | Retains the documented defense-in-depth boundary. |
| Network | Raw container network remains disabled | Host-mediated capabilities satisfy current research needs with less attack surface. |
| Bridge transport | Bounded Dart-owned framed stdio over `docker exec -i` | Works on Linux and Docker Desktop without a socket mount or egress-capable relay. |
| Container authority | One container and harness per live container authority | Sibling `docker exec` processes cannot observe another execution's bridge or generated state. |
| Claude container auth | Host-held `ANTHROPIC_API_KEY` only | OAuth/setup-token has no verified credential-free mediation contract. |
| Failure behavior | Fail closed | A requested security boundary must be real or execution must not start. |

### Open Design Questions

None. ADR-012 is amended in the first implementation slice before gateway work begins.

### Technical Evidence

- A 2026-08-11 Codex 0.146 spike proved that a fresh, credential-free container routes Responses API traffic to a custom
  `base_url` without an `Authorization` header. The host gateway can therefore inject the upstream credential.
- A Codex process with existing login state still sent its saved bearer credential to the custom provider despite
  `requires_openai_auth = false`; restricted Codex must use a fresh, unmounted home with no reusable authentication state.
- Docker Desktop rejected a bind-mounted macOS AF_UNIX socket from the Linux VM. A follow-up proof carried request and
  response bytes over `docker exec -i` while the container retained `network:none`; production framing must be Dart-owned,
  bounded, backpressured, and surface-separated rather than raw `socat` multiplexing.
- Current Claude OAuth/setup-token mode mounts `~/.claude.json` into the container, and no documented stable gateway
  contract permits credential-free subscription OAuth mediation. 0.24 containerized Claude therefore supports host-held
  `ANTHROPIC_API_KEY` only; OAuth/setup-token remains available in explicit host mode and fails closed in container mode.

## Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| Container requested while containers are disabled | Reject configuration or dispatch; never fall back to host. |
| Host execution paired with a container-only profile | Reject the contradictory configuration with the exact agent key. |
| Provider lacks container launch support | Reject at startup or first dispatch before starting the harness. |
| ACP registration requires isolation but declares no compatible transport | Registration is unavailable with an actionable diagnostic. |
| Host capability bridge is unavailable | The turn fails closed; no direct-network fallback is attempted. |
| Credential gateway is unavailable or authentication fails | The provider turn fails without exposing or copying credentials. |
| Containerized Claude is configured without a host API key | Reject OAuth/setup-token container mode and direct the operator to configure `ANTHROPIC_API_KEY` or select deliberate host execution. |
| Worker cache contains a runner from another execution boundary | The runner is incompatible and cannot be reused. |
| Restricted agent calls an unapproved MCP tool directly | Host-side authorization rejects the call even if the client bypasses its own tool list. |
| Redirect or DNS resolution reaches a private address through `web_fetch` | Existing host SSRF policy blocks the request. |
| Containerized search is configured without a host search provider | Search is unavailable with an actionable diagnostic; provider-native search is not used as fallback. |

## Error Handling

| Error | User Message | Recovery |
|-------|--------------|----------|
| Unsupported provider/execution combination | Name the provider, requested mode, and missing capability | Select host mode or configure a supported adapter. |
| Invalid execution/profile combination | Name the exact YAML path and valid relationship | Correct configuration and restart. |
| MCP bridge startup or authentication failure | Identify the affected profile/agent without revealing tokens | Repair bridge configuration and restart; execution remains unavailable. |
| Provider gateway failure | Identify provider and failure category without secrets | Correct provider credentials/gateway configuration and retry. |
| Attempted unapproved host tool call | Report policy denial through the normal tool result/audit path | Change the agent allowlist intentionally or use an approved tool. |

## Non-Functional Requirements

- **Performance**: Local mediation must stream requests and responses without buffering unbounded provider or web payloads.
- **Reliability**: Effective execution policy and bridge readiness are verified before a turn is admitted; failures never
  downgrade to host execution or general network access.
- **Security**: Containers retain `network:none`, provider credentials remain host-owned, host MCP authorization enforces
  the resolved agent/tool scope, and logs/errors contain no secrets.
- **Portability**: POSIX hosts support container mode; unsupported platforms expose host mode and reject container-required
  configurations consistently.
- **Operability**: Startup logs identify deliberate host-execution overrides and unavailable provider combinations without
  logging credential values.
- **Accessibility**: No UI work is required; diagnostics must remain understandable in CLI and configuration workflows.

## Success Criteria

- [ ] One deployment can run its configured coding logical agent and coding background tasks on the host while keeping
      search/research and other default executions containerized.
- [ ] Claude and Codex honor the resolved host/container mode; neither carries a container profile label while running on
      the host unintentionally.
- [ ] Provider credentials used by containerized Claude and Codex are not present in container environment variables,
      mounted files, command arguments, or generated client configuration.
- [ ] A restricted container with no direct egress can successfully call its approved host-mediated `web_search` and
      `web_fetch` tools on Linux and Docker Desktop.
- [ ] The same container cannot make a direct request to an arbitrary Internet destination.
- [ ] An MCP call outside the agent's effective allowlist is rejected by the host even when invoked directly.
- [ ] Container-required ACP registrations either use a declared compatible mechanism or are rejected before spawn.
- [ ] Unsupported and contradictory configurations fail closed with actionable, secret-free diagnostics.
- [ ] Existing deployments retain their effective execution defaults unless an operator opts out explicitly.
- [ ] Cross-provider integration tests exercise the successful and rejected paths rather than only inspecting generated
      configuration.

## Dependencies

| Dependency | Purpose | Risk |
|------------|---------|------|
| ADR-012 | Existing profile/container routing decision | Must be amended or superseded to avoid contradictory guidance. |
| Claude Code CLI | Claude container launch and provider API protocol | Container mode supports host-held API-key mediation only; OAuth/setup-token requires host execution. |
| Codex CLI app-server | Codex container launch, auth, and MCP configuration | Custom Responses providers work only from an auth-clean container home; current Docker asset naming must be corrected. |
| ACP registration model | Declares topology and isolation requirements | ACP does not standardize provider credentials or network endpoints. |
| Docker exec stdio + framed bridge | Reaches host mediation while retaining `network:none` across Linux and Docker Desktop | Framing, backpressure, process teardown, and per-authority namespace ownership must fail closed. |
| DartClaw guard and MCP layers | Host-side capability authorization, SSRF, and content controls | Current inbound MCP token lacks per-caller identity. |

## Open Questions

None.

## Decisions Log

| Decision | Rationale | Date |
|----------|-----------|------|
| Treat as a feature-level 0.24 release blocker | The defect prevents the intended native-coding/containerized-assistant posture. | 2026-08-11 |
| Use a parallel 0.24 bundle | The existing 0.24 directory already governs unrelated MEMORY.md work. | 2026-08-11 |
| Accept all four clarified scope recommendations | User explicitly confirmed provider scope, secret boundary, defaults, and network scope. | 2026-08-11 |
