# ADR-012: Per-Type Container Isolation

**Status:** Accepted (amended 2026-08-11 — a security profile is a filesystem/capability template, not a shared runtime container; each live container authority owns a dedicated container and harness)

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
- Every **live container authority** — one admitted container execution — owns a dedicated container, process namespace, harness lifetime, and generated state.
- **Container harnesses are never cached across authority release.** Release confirms root-process termination, runs the authority-revocation seam, removes generated state, and destroys the container before capacity is returned. Host harnesses remain reusable and cached as before.

Sharing one container per profile left siblings and successors inside one PID, `/tmp`, and generated-home namespace. Under a per-profile shared container, a compromised or merely leaky harness could observe or tamper with a co-resident harness of the same profile, and a released harness could leave state that the next lease inherits — which defeats the isolation the profile was chosen for and blocks binding credentials or capabilities to a single execution.

Container *count* therefore scales with concurrent container executions rather than with the number of profiles; `providers.<id>.pool_size` remains the only worker-capacity limit and bounds it.

**Scope of the amendment.** It governs *harness-owning* authorities: the primary harness and every coordinator-managed worker. The provider-CLI one-shot path (workflow steps driven by `ClaudeCliProvider`/`CodexCliProvider`) still executes through a shared per-profile container; that path is amended when Claude/Codex container parity lands, and it holds no harness and no worker lease.

### Security Profiles (0.8)

| Profile | Container | Mounts | Network | Used By |
|---|---|---|---|---|
| `workspace` | `dartclaw-<id>-workspace…` | `/workspace:rw`, `/project:ro` | `none` | Main chat, coding tasks, cron, user sessions |
| `restricted` | `dartclaw-<id>-restricted…` | No workspace | `none` | Search agent, research tasks |

Container naming: `dartclaw-<sha256(dataDir)[0:8]>-<profileId>`, with a per-authority suffix for each dedicated container. Deterministic prefix, collision-free, multi-instance safe across OS users.

### Dispatch Model

```
ExecutionCoordinator (5 worker leases)
  ├── coding task      → container/workspace   → its own container, destroyed on release
  ├── writing task     → container/workspace   → its own container, destroyed on release
  ├── research task    → container/restricted  → its own container, destroyed on release
  ├── logical agent    → resolved policy       → host process, or its own container
  └── cron job         → deployment default    → host process, or its own container
```

The Dart host mediates all routing: `execution request → effective execution policy → container`. Containers never communicate directly. Container lifetime is bound to the authority that owns it: the container is created when the authority is admitted and destroyed when it is released. `pool_size` accounting is unchanged — capacity is returned only after teardown completes.

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
- One container per live container execution instead of one per profile — more to monitor, debug, and clean up on crash
- Container creation cost is paid per authority rather than amortized across leases
- Harness pool must resolve the correct policy and provision a container per admitted execution — adds routing and lifecycle complexity
- Each container runs its own socat bridge — slightly more moving parts

### Neutral
- CredentialProxy remains shared (single proxy, all containers mount same socket dir)
- Docker image stays shared — security differentiation via launch flags, not image contents
- `container.enabled: false` path unchanged — all tasks share host process, no containers
- Coding tasks use git worktrees (directories within workspace mount) — worktree isolation is git-level, not container-level

## Alternatives Considered

### Status Quo (single shared container)
- **Pros**: Zero effort, simplest operations, lowest resources
- **Cons**: Cross-agent isolation gap remains open, hardcoded name blocks multi-instance, all task types get identical OS permissions, contradicts ADR-001 vision
- **Rejected because**: The search agent — the highest-risk agent (network-facing via MCP web tools) — has no OS-level filesystem restriction. This gap widens with the task orchestrator adding more task types with varying security needs.

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
