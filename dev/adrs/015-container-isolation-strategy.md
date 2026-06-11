# ADR-015: Container Isolation Strategy — Hardened Docker over Hypervisor Isolation

**Status:** Proposed

## Context

NanoClaw shipped "Docker Sandboxes" (Mar 2026) — hypervisor-level micro VMs creating a two-kernel-boundary model (Host → Sandbox VM → NanoClaw → Docker-in-Docker → agent containers). Multiple authoritative sources (Northflank, NVIDIA, Elastic) now state that standard Docker containers are insufficient for AI agent isolation because they share the host kernel. OpenClaw experienced a major CVE cluster (Feb 2026) including container-related security concerns.

DartClaw needed to evaluate whether its current Docker-based isolation model is sufficient or whether hypervisor-level isolation should be added. A systematic trade-off analysis evaluated 6 options across 8 weighted criteria, including a new criterion: **setup complexity** for single-user self-hosted deployment.

### Current DartClaw Isolation Model (ADR-012)

- Docker containers with `--network=none`, `--cap-drop=ALL`, `--read-only`, `--security-opt=no-new-privileges`
- Non-root user (uid 1000) inside container
- Credential proxy on Unix socket (API keys never in container environment)
- Per-type container profiles: workspace + restricted (ADR-012)
- 3-layer guard pipeline (command-guard, file-guard, network-guard)
- Content classification, input sanitization, message redaction, audit logging

### Platform Reality

DartClaw's primary user base runs on **macOS Apple Silicon** (single-user, self-hosted):

| Technology | M1/M2 | M3+ (macOS 15+) | Linux |
|---|---|---|---|
| Docker (runc) | Via Docker Desktop VM | Via Docker Desktop VM | Native |
| Docker-in-Docker | **Yes** (namespaces, no virt needed) | **Yes** | **Yes** |
| gVisor (runsc) | **No** (no `/dev/kvm`) | **Partial** (systrap mode only) | **Yes** |
| Firecracker | **No** (no nested virt) | **Partial** (nested virt, M3+ only) | **Yes** (KVM) |
| Kata Containers | **No** | **No** (QEMU nested fails) | **Yes** (KVM) |

Key findings from research:
- **Nested virtualization** requires M3+ chip AND macOS 15+ (Sequoia). M1/M2 permanently excluded.
- **Docker-in-Docker** works universally because it uses Linux namespaces/cgroups (no hardware virtualization needed). This is why NanoClaw's Docker Sandboxes work on all Apple Silicon.
- **Unix domain sockets** cannot function across VM boundaries (Kata issue #4244) — DartClaw's credential proxy pattern would break with Kata/Firecracker approaches.

## Decision

**We will harden the existing Docker container model with custom seccomp profiles, cgroup resource limits, and AppArmor policies. We will NOT add hypervisor-level isolation at this time.** A future optional gVisor runtime flag for Linux deployments is preserved as an escape hatch.

### Concrete hardening measures (immediate):

1. **Cgroup limits**: `--memory 2g --cpus 2 --pids-limit 100` — prevents fork bombs, memory exhaustion, CPU starvation
2. **Custom seccomp profile**: Audit `claude` binary syscalls via `strace -c`, create allowlist JSON blocking io_uring, userfaultfd, eBPF, and other exploit-prone syscalls
3. **Home directory tmpfs**: `--tmpfs /home/dartclaw:rw,noexec,nosuid,size=500m` — write path for `claude` binary
4. **AppArmor profile**: Restrict file access to mounted workspace paths only
5. **Configurable limits**: Expose memory/CPU/PID limits in `dartclaw.yaml` container config
6. **Security posture check**: Add OWASP-informed checks to `dartclaw doctor` (0.11 security hardening work)

### Future escape hatches (preserved, not prioritized):

- `container.runtime: runsc` config flag for Linux-only gVisor deployments (~25 LOC)
- Monitor Apple Containerization framework maturity (revisit at v1.0+, macOS 27+)
- Docker Desktop Sandbox mode remains architecturally possible if multi-tenant requirements emerge

## Consequences

### Positive

- **Zero architecture changes** — all hardening is additive Docker flags in `ContainerManager.start()`
- **Full macOS compatibility** — seccomp/AppArmor/cgroups execute inside Docker's Linux VM, work on all Apple Silicon (M1–M4)
- **Minimal effort** — 2-3 days total implementation vs 2-3 weeks for Docker Sandboxes
- **Zero performance impact** — policy enforcement, not virtualization overhead
- **Zero setup complexity** — users install nothing extra; hardening is automatic
- **No new dependencies** — no Docker Desktop lock-in, no Lima, no separate VM management
- **Defense-in-depth narrative** — unique competitive position: no other personal AI runtime combines OS isolation + credential proxy + guard pipeline + content classification + audit logging
- **>90% of known container escape CVEs already mitigated** — `cap-drop ALL` + `network:none` eliminates the capabilities and network access required by the vast majority of disclosed escapes since 2019

### Negative

- **Marketing perception gap** — "Docker with seccomp" is less compelling than NanoClaw's "two hypervisor boundaries" narrative
- **Kernel 0-day residual** — pure kernel bugs (Dirty Pipe class) bypass all Docker configuration. These are rare, quickly patched, and affect all container-based solutions equally
- **No answer for future multi-tenant** — if DartClaw ever supports multiple untrusting users, hypervisor isolation becomes necessary. This is explicitly out of scope (not in roadmap)

### Neutral

- The competitive gap with NanoClaw is primarily **marketing, not technical**. NanoClaw's Docker Sandboxes provide stronger raw isolation (two kernel boundaries) but have zero guard pipeline — a prompt injection that gets the agent to `cat ~/.ssh/id_rsa` succeeds inside NanoClaw's containers regardless of VM count. DartClaw's FileGuard blocks it at the application layer.
- OpenClaw's Feb 2026 CVE cluster (WebSocket token exfil, 820+ malicious ClawHub skills, 135k exposed instances) was entirely application-level — not container escapes. DartClaw's architecture directly prevents every attack class: no WebSocket protocol, no npm supply chain, no skill marketplace.
- Docker on macOS already interposes a Linux VM between the host and containers. DartClaw's agents already run behind one hypervisor boundary by default on macOS.

## Alternatives Considered

### Option A: gVisor (`runsc`)

- **Pros**: Strongest container-level isolation without hardware virtualization. Used by Anthropic, OpenAI, Google. Drop-in Docker runtime flag on Linux (~25 LOC).
- **Cons**: Cannot run on macOS M1/M2 at all. macOS M3+ only via Docker Desktop VM (unsupported, fragile). Linux-only in practice.
- **Rejected because**: Primary user base is macOS Apple Silicon including M1/M2. Offering a feature most users can't use is poor product design. Preserved as optional Linux-only flag for future.

### Option B: Kata Containers

- **Pros**: Dedicated kernel per container (strong isolation). Healthy community (7.6K stars, CNCF).
- **Cons**: Requires Linux KVM (no macOS). Unix domain sockets don't work across VM boundaries — breaks DartClaw's credential proxy pattern (would require rewrite to vsock). Enterprise-grade K8s infrastructure, inappropriate for single-user.
- **Rejected because**: Architecture breaker (credential proxy) and platform blocker (macOS).

### Option C: Firecracker

- **Pros**: Strongest practical isolation tier. AWS-backed (Lambda/Fargate). 33K stars, minimal attack surface.
- **Cons**: Requires Linux KVM (M3+ only on macOS, M1/M2 excluded). Not OCI-compatible — requires entirely separate container management (2,000-4,000 LOC). Custom rootfs images, no Docker Hub.
- **Rejected because**: Massive implementation effort, platform restrictions, incompatible with Docker-based workflow.

### Option D: Docker Desktop VM / Sandboxes (NanoClaw's approach)

- **Pros**: Genuine two-kernel isolation. Works on all macOS (DinD doesn't need nested virt). Proven by NanoClaw.
- **Cons**: Hard Docker Desktop lock-in (Colima/Podman can't use Sandbox feature). 6 categories of patches required. Dart binary must be cross-compiled to Linux ARM64. MITM proxy trust concerns. Not CI-testable. Derivative positioning vs NanoClaw. Two code paths to maintain.
- **Rejected because**: High implementation effort (2-3 weeks), high setup complexity for users (Docker Desktop 4.40+ required, sandbox initialization, proxy config), Docker Desktop lock-in conflicts with minimal-dependency philosophy, and derivative competitive positioning. The isolation gain doesn't justify the cost for a single-user product.

### Option F: Hybrid (gVisor default + optional Firecracker)

- **Pros**: Architecturally extensible, per-profile isolation overrides.
- **Cons**: Tiers 2-3 don't work on macOS M1/M2. Over-engineered for single-user. Triple test matrix. User confusion.
- **Rejected because**: Over-engineered. YAGNI — solve the actual problem (harden Docker) before abstracting for hypothetical future isolation backends.

## Implementation Notes

All hardening changes go in `packages/dartclaw_core/lib/src/container/container_manager.dart`, specifically the `start()` method's Docker argument list.

### Seccomp profile

Ship a custom `seccomp.json` alongside the DartClaw binary (embed as a Dart asset or write to `<dataDir>/seccomp.json` on first run). Pass via `--security-opt seccomp=<path>`. Profile audited against `claude` binary's actual syscall usage.

### Cgroup limits

Three flags added to Docker create arguments. Made configurable via `containers.limits` section in `dartclaw.yaml` with sensible defaults:

```yaml
containers:
  limits:
    memory: "2g"     # default
    cpus: "2"        # default
    pids: 100        # default; critical fork bomb defense
```

### AppArmor profile

Ship a custom AppArmor profile that restricts file access to: `/workspace`, `/project`, `/tmp`, `/home/dartclaw`, `/var/run/dartclaw`. Load via `--security-opt apparmor=dartclaw-agent`. Only effective on Linux hosts with AppArmor enabled (Ubuntu/Debian); silently skipped on macOS (where AppArmor runs inside Docker's VM but the profile must be loaded into the VM's kernel).

### Setup complexity: zero

All hardening is applied automatically by `ContainerManager`. Users don't need to install anything, configure anything, or understand the security model. `dartclaw doctor` will verify hardening is active and report gaps.

## References

- [ADR-012](012-per-type-container-isolation.md) — per-type container isolation (0.8)
- [Security architecture](../architecture/security-architecture.md) — Layer 1 container isolation
- [Northflank — How to Sandbox AI Agents](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [OpenClaw CVE cluster](https://www.adminbyrequest.com/en/blogs/openclaw-went-from-viral-ai-agent-to-security-crisis-in-just-three-weeks)
- [Lima nested virtualization PR #2530](https://github.com/lima-vm/lima/pull/2530) — M3+ macOS 15+ only
- [Lima nested QEMU issue #4498](https://github.com/lima-vm/lima/issues/4498) — deeper nesting still broken
- Research sources are summarized in the linked research appendix.
