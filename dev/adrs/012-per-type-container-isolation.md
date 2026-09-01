# ADR-012: Per-Type Container Isolation

**Status:** Accepted (amended 2026-08-13 — profiles are templates; containers belong to one execution owner and never cross principals; amended 2026-08-27 by [ADR-055](055-container-by-default-posture.md) — an undeclared posture resolves to isolated wherever a container runtime is detected)

## Context

DartClaw's container isolation (S21, 0.6) uses a single shared Docker container (`dartclaw-agent`) for all agents. The `sleep infinity` + `docker exec` pattern dispatches turns into this container with strong host-level security flags (`--network none`, `--cap-drop ALL`, `--read-only`, `--tmpfs /tmp`, `--security-opt no-new-privileges`). API keys never enter the container — a CredentialProxy on Unix socket + socat TCP bridge handles credential injection.

**The problem:** Agent-level tool restrictions are application-only. The search agent's `ToolPolicyCascade` denies filesystem tools (`web_search` + `web_fetch` only), but inside the shared container the search agent's claude binary has full `/workspace:rw` access. A compromised search agent could read/write the workspace despite the tool policy. ADR-001's security architecture diagram (lines 207-223) already envisioned separate containers per agent type for Phase 4 — this was deferred, not rejected.

**Compounding factors:**
- The 0.8 task orchestrator introduces a harness pool with 3-5+ concurrent tasks (coding, research, writing, analysis). All would share one container with identical OS-level permissions regardless of their security needs.
- The hardcoded `_containerName = 'dartclaw-agent'` is a multi-instance collision bug — two DartClaw installs on the same Docker daemon silently destroy each other's containers.
- OpenClaw's `sandbox.scope: "agent"` validates the per-type model in production: one persistent container per agent type, shared across all sessions of that type.

## Decision

**We will use per-security-profile container templates**, where each distinct security profile defines one container's mounts, network, and capabilities, and every live execution authority is given its own container built from that template.

Container = security boundary (mounts, network, capabilities). Profile = the template that defines that boundary. Harness = provider protocol/process context launched inside one container.

### 2026-08-11 amendment — authority-owned container lifetime

The original decision let concurrent tasks and sessions of the same profile share one long-lived container via `docker exec`, amortizing container startup across leases. That is superseded:

- A **security profile** is a filesystem/capability *template*. It is not itself a running container and carries no execution location — placement is the separate host/container execution mode.
- Every **execution owner** owns a dedicated container, process namespace, harness lifetime, and generated state.
- A logical-agent session is a standing owner, so its container persists across that owner's turns and ends on discard, eviction, or shutdown. A task owns its container for one turn; a workflow step owns its container across all step turns. Host harnesses remain reusable as before.

Sharing one container per profile left siblings and successors inside one PID, `/tmp`, and generated-home namespace. Under a per-profile shared container, a compromised or merely leaky harness could observe or tamper with a co-resident harness of the same profile, and a released harness could leave state that the next lease inherits — which defeats the isolation the profile was chosen for and blocks binding credentials or capabilities to a single execution.

Container count is bounded by `providers.<id>.pool_size`; retained logical-agent owners compete within that bound and are evicted before a different owner can exceed it.

**2026-08-13 owner-lifetime clarification.** The 2026-08-11 amendment correctly prohibited sharing across principals but equated an authority with one turn. That destroyed provider-native continuation for standing logical agents and multi-turn workflow steps. An authority now tracks the trust owner: primary process lifetime, logical-agent session, task turn, or workflow step. The provider-CLI one-shot path holds one authority and one auth-clean provider home for the complete step, then releases both in `finally`.

**2026-08-23 task-profile declaration amendment.** The task lane defaults to the neutral `workspace` profile, while
an authenticated operator may declare `workspace` or `restricted` as a top-level task API field. Channel and
model-facing creation seams cannot express that declaration. Because the former `research` input selected
`restricted`, every input carrying it and every matching pre-upgrade stored row is refused with the
explicit-declaration remediation rather than silently widened to `workspace`. The profile table and
dispatch diagram below record the original decision; for current task placement, “Used By” is default tasks for
`workspace` and explicitly declared tasks for `restricted`, and dispatch is declared profile → effective policy →
owner container.

**Provider compatibility.** A container authority can only be granted to a provider whose container execution DartClaw actually mediates. The host gateway's provider adapters are verified for the Claude and Codex clients only, so an ACP registration has no mediated container execution: an ACP registration that requires a container is rejected at startup, and an ACP provider whose resolved policy is container execution is refused before admission rather than downgraded to host. Placement remains the resolved execution mode's decision; this only bounds which providers a container mode can carry.

### Security Profiles (0.8)

| Profile | Container | Mounts | Network | Used By |
|---|---|---|---|---|
| `workspace` | `dartclaw-<id>-workspace…` | `/workspace:rw`, `/project:ro` | `none` | Main chat, coding tasks, cron, user sessions |
| `restricted` | `dartclaw-<id>-restricted…` | No workspace | `none` | Search agent, research tasks |

> **2026-08-23 amendment:** the “Used By” cells above are the original 0.8 assignment. Current task use is default
> tasks for `workspace` and explicitly declared tasks for `restricted`; category contributes neither profile.

Container naming: `dartclaw-<sha256(dataDir)[0:8]>-<profileId>`, with a per-authority suffix for each dedicated container. Deterministic prefix, collision-free, multi-instance safe across OS users.

### Dispatch Model

```
ExecutionCoordinator (5 worker leases)
  ├── coding task      → container/workspace   → its own turn container
  ├── writing task     → container/workspace   → its own turn container
  ├── research task    → container/restricted  → its own turn container
  ├── logical agent    → resolved policy       → its own owner container across turns
  └── cron job         → deployment default    → host process, or its own container
```

> **2026-08-23 amendment:** the task rows above are historical. Current task dispatch is declared profile (or neutral
> `workspace`) → effective execution policy → owner container. The `research` input is refused.

The Dart host mediates all routing: `execution request → effective execution policy → owner container`. Containers never communicate directly or cross principals. Active execution capacity is lease-owned; owner containers may remain idle only within the provider's bounded retained-worker set.

### Future Profiles (when needed)

| Profile | Use Case |
|---|---|
| `integration` | Read-only workspace, bridge network — external API tasks |
| `sandbox` | Ephemeral tmpfs only — untrusted code execution |
| `macos-vm` | Lume full macOS VM — computer-use agents, Xcode, GUI automation |

The `macos-vm` profile is a separate tier using Apple's Virtualization.framework via Lume — full macOS VMs (not lightweight containers). Qualitatively different from Docker containers: enables agents that need macOS-native tools, GUI interaction, Xcode builds. Heavyweight (8GB+ RAM per VM), macOS-only. Deferred until computer-use agents enter the roadmap.

## Consequences

### Positive
- OS-level isolation matches application-level tool policies — the restricted container literally has no filesystem to access
- No sibling or successor harness shares a container's PID, `/tmp`, generated home, or bridge state — the isolation matches what the profile promises
- Container count is bounded by configured worker capacity, not by task parallelism in the abstract
- Multi-instance deployment works — unique container names per DartClaw install
- Directly implements ADR-001 Phase 4 vision
- Mirrors OpenClaw's production-validated `scope: "agent"` pattern
- Clean extension path: new security profiles are configuration, not architecture changes
- Enables future Lume VM tier without architectural changes

### Negative
- One container per live execution owner instead of one per profile — more to monitor, debug, and clean up on crash
- Container creation cost is amortized only across turns belonging to the same standing owner
- Harness pool must resolve the correct policy and provision a container per admitted execution — adds routing and lifecycle complexity
- Each container runs its own bridge process pair — slightly more moving parts

### Neutral
- Since the 2026-08-23 amendment, security profile is the neutral default or an authenticated operator declaration;
  the retired profile-bearing input fails closed.
- Host mediation is per owner authority: one gateway registration and pipe pair, revoked when that owner ends
- Docker image stays shared — security differentiation via launch flags, not image contents
- `container.enabled: false` path unchanged — all tasks share host process, no containers
- Tasks declaring `configJson.needsWorktree: true` use git worktrees (directories within the workspace mount) — worktree isolation is git-level, not container-level

## Alternatives Considered

### Status Quo (single shared container)
- **Pros**: Zero effort, simplest operations, lowest resources
- **Cons**: Cross-agent isolation gap remains open, hardcoded name blocks multi-instance, all tasks get identical OS permissions, contradicts ADR-001 vision
- **Rejected because**: The search agent — the highest-risk agent (network-facing via MCP web tools) — has no OS-level filesystem restriction. This gap widens as the task orchestrator adds work with varying security needs.

### Single Container + Mount Scoping
- **Pros**: Near-zero resource overhead
- **Cons**: Docker mounts are per-container, not per-exec. Cannot scope filesystem access per process. Only POSIX permissions possible, providing access control but not isolation (shared PID/net/IPC/cgroup namespaces).
- **Rejected because**: Technically unsound — the premise that Docker can scope mounts per `docker exec` is false.

### NanoClaw-style Per-Group Containers
- **Pros**: Maximum blast radius containment per use-case/channel
- **Cons**: ~2GB RAM for 10 containers, requires inventing a "group" concept that doesn't exist in DartClaw's domain, 3-4 week big-bang replacement
- **Rejected because**: Over-engineering. DartClaw's single-operator model doesn't have distinct trust boundaries between groups. Per-type (2-4 containers) provides the security benefit at a fraction of the cost.

### Apple Containerization Framework (lightweight Linux VMs)
- **Pros**: Hypervisor-level isolation (stronger than Docker namespaces)
- **Cons**: v0.1.0 with breaking-change warnings, requires macOS 26 for full networking, dual-backend maintenance (Docker still needed for Linux), 4.4x slower startup, 60% slower disk I/O
- **Rejected because**: Too immature. NanoClaw moved away from it as default. Docker provides sufficient isolation for DartClaw's threat model. Revisit when framework reaches 1.0 and macOS 26 is mainstream.

### Apple Virtualization via Lume (full macOS VMs)
- **Not rejected, but deferred.** Lume provides full macOS VMs — a different capability tier, not a Docker replacement. Useful when DartClaw adds computer-use agents needing Xcode, GUI automation, or macOS-native tools. The per-type container architecture enables adding a `macos-vm` profile seamlessly.

## Implementation Notes

Estimated ~250 LOC across 4-5 files. Stageable:

**Phase 1** (backward-compatible): Parameterize `ContainerManager.containerName`, add naming utility, update `ServiceWiring`. All existing tests pass.

**Phase 2** (per-type): Define security profiles, create `Map<String, ContainerManager>` per profile, integrate with harness pool routing, update shutdown path.

**Phase 3** (validation): Verify restricted container has no workspace mount, concurrent execs work, `sessions_send` routes correctly, `container.enabled: false` is unaffected, multi-instance names don't collide.

Key files: `container_manager.dart`, `service_wiring.dart`, harness pool (new in 0.8), `container_config.dart`.

## References

- [ADR-011: Lightweight Event Bus](011-event-driven-architecture.md) — container lifecycle events (`ContainerStartedEvent`, `ContainerCrashedEvent`) flow through event bus for observability
- [ADR-001: SDK Integration and Security Architecture](001-sdk-integration-and-security-architecture.md) — original container architecture, Phase 4 vision
- 0.6 PRD — container hardening implementation
- [OpenClaw sandboxing docs](https://docs.openclaw.ai/gateway/sandboxing) — `scope: "agent"` pattern
- [Lume docs](https://cua.ai/docs/lume/guide/getting-started/introduction) — Apple Virtualization VM orchestration
- Research sources are summarized in the linked research appendix.
