# Container Isolation Trade-off Analysis — Consolidated Research

> Date: 2026-03-15
> Decision: Should DartClaw add hypervisor-level isolation to its container model?
> Trigger: NanoClaw shipped Docker Sandboxes micro VMs (Mar 2026); multiple sources state Docker containers are insufficient for AI agent isolation

## Context

DartClaw's current container isolation model:
- Docker containers with `network:none` and `--cap-drop=ALL`
- `--read-only` root filesystem + `--tmpfs /tmp:rw,noexec,nosuid`
- `--security-opt no-new-privileges`
- Non-root user (uid 1000) inside container
- Credential proxy on Unix socket (API keys never in container)
- Per-type containers: workspace + restricted profiles (ADR-012)
- 3-layer guard pipeline (command/file/network guards)
- Content classification, input sanitization, message redaction
- Primary user base: macOS Apple Silicon (single-user, self-hosted)

## Options Evaluated

| # | Option | Technology | Approach |
|---|---|---|---|
| A | gVisor (`runsc`) | User-space kernel | Docker runtime replacement |
| B | Kata Containers | MicroVM per container | Dedicated kernel via Cloud Hypervisor |
| C | Firecracker | AWS microVM | Custom orchestration (non-OCI) |
| D | Docker Desktop VM | Docker Sandboxes | NanoClaw's approach — DinD inside micro VM |
| E | Status quo + hardening | Docker + seccomp/AppArmor/cgroups | Harden existing model, document defense-in-depth |
| F | Hybrid (tiered) | gVisor + Firecracker | Configurable isolation tiers |

## Platform Support Matrix — The Critical Constraint

| Technology | macOS Apple Silicon | Linux x86_64 | Linux ARM64 |
|---|---|---|---|
| Docker (runc) | Via Docker Desktop VM | Native | Native |
| gVisor (runsc) | **No** — requires Linux kernel | Yes | Yes |
| Firecracker | **No** — requires Linux KVM | Yes (KVM) | Yes (KVM) |
| Kata Containers | **No** — requires Linux KVM | Yes | Yes |
| Docker Sandboxes | Yes (Docker Desktop 4.40+) | Yes (Docker Desktop) | N/A |
| Docker hardening (seccomp/AppArmor) | Yes (inside Docker's VM) | Yes | Yes |

**Key finding**: gVisor, Firecracker, and Kata Containers all require Linux kernel interfaces (KVM, seccomp-bpf). Docker Desktop on macOS runs a Linux VM — these technologies would need to run *inside* that VM via nested virtualization:

- **Nested virtualization** on Apple Silicon requires **M3+ chip AND macOS 15+ (Sequoia)**. M1 and M2 are permanently excluded (`isNestedVirtualizationSupported` returns false). Even on M3+, deeper nesting (QEMU inside KVM inside Virtualization.framework) hits QEMU limitations (Lima issue #4498).
- **Docker-in-Docker** works universally on all Apple Silicon because it uses Linux namespaces/cgroups — no hardware virtualization needed. This is why NanoClaw's Docker Sandboxes work on M1/M2/M3/M4.
- **Firecracker on M3 via Lima** is technically possible (real KVM, not emulation) but only on M3+ with macOS 15+ and `nestedVirtualization: true` in Lima config. Not reproducible on M1/M2.

_Sources: Lima PR #2530, Lima issue #4498, Apple Virtualization.framework docs, `pkg/vz/vm_darwin.go`_

## Per-Option Research Summaries

### Option A: gVisor — Score 46.2% (macOS) / 65.4% (Linux)

**Strengths**: Strongest container-level isolation without hardware virtualization. Used by Anthropic, OpenAI, Google at massive scale. Go implementation eliminates memory corruption class. Drop-in Docker runtime replacement on Linux (~15-25 LOC change). All DartClaw Docker flags compatible.

**Fatal flaw**: Cannot run on macOS. Issue #1270 open since 2019, tagged P3, no development. Docker Desktop uses gVisor's *netstack library* for networking but NOT the container runtime.

**Recommendation**: Offer as optional `container.runtime: runsc` for Linux deployments. Not a primary isolation strategy.

### Option B: Kata Containers — Score 41.4%

**Strengths**: Dedicated kernel per container (9/10 isolation). Healthy community (7.6K stars, CNCF). Confidential Computing support.

**Fatal flaws**: (1) No macOS support (requires KVM). (2) Unix domain sockets cannot function across VM boundaries — DartClaw's credential proxy would need rewriting to use vsock. (3) Enterprise Kubernetes infrastructure, inappropriate for single-user deployment.

**Recommendation**: Not viable for DartClaw.

### Option C: Firecracker — Score 51.5%

**Strengths**: Strongest practical isolation tier. AWS-backed (Lambda/Fargate), 33K stars. Minimal attack surface (~50K LOC Rust). vsock would actually be better than DartClaw's current Unix socket + socat bridge.

**Fatal flaws**: (1) No macOS support (requires bare-metal KVM). (2) Not a Docker runtime — requires entirely separate container management (2,000-4,000 LOC). (3) Custom rootfs images, no Docker Hub.

**Recommendation**: Not viable for DartClaw's macOS-primary deployment.

### Option D: Docker Desktop VM (NanoClaw's approach) — Score 61.5%

**Strengths**: Genuine two-kernel boundaries (9/10 isolation). Works on macOS via Docker Desktop Virtualization.framework. Proven by NanoClaw. Credential proxy pattern preserved (Unix sockets work within VM). `network:none` works identically inside sandbox.

**Weaknesses**: Hard Docker Desktop lock-in (Colima/Podman can't use Sandbox feature). 6+ categories of patches required (NanoClaw needed same). Dart binary must be cross-compiled to Linux ARM64. Not CI-testable. Derivative positioning vs NanoClaw. Two code paths to maintain. MITM proxy trust concerns.

**Recommendation**: Viable but costly. 2-3 weeks implementation. Best if multi-tenant or feature parity with NanoClaw is required.

### Option E: Status Quo + Hardening — Score 79.5% ★ WINNER

**Strengths**: Zero architecture changes. Full macOS support (hardening runs inside Docker's Linux VM). 2-3 days implementation. Zero performance impact (policy enforcement, not virtualization). Defense-in-depth narrative unique in competitive landscape. Closes OpenClaw CVE gap (all Feb 2026 CVEs were application-level, not container escapes). gVisor escape hatch for future Linux-only option.

**Weaknesses**: Marketing disadvantage vs "micro VM with two hypervisor boundaries." Kernel 0-day residual (Dirty Pipe class). No answer for future multi-tenant.

**Key evidence**: >90% of disclosed container escape CVEs since 2019 require capabilities or network access that DartClaw already eliminates (`cap-drop ALL` + `network:none`). OpenClaw's Feb 2026 CVE cluster was entirely application-level (WebSocket auth, plugin RCE, supply chain) — not container escapes.

### Option F: Hybrid (tiered) — Score 60.8%

**Strengths**: Architecturally extensible. Per-profile isolation overrides.

**Fatal flaw**: Tiers 2 and 3 don't work on macOS. 3-tier model is over-engineered for single-user product. Adds user confusion. Maintenance burden disproportionate.

**Recommendation**: Over-engineered. Do not implement.

## Detailed Comparison Matrix

| Criterion (Weight) | A: gVisor | B: Kata | C: Firecracker | D: Docker VM | E: Hardening | F: Hybrid | Winner |
|---|---|---|---|---|---|---|---|
| Isolation (10) | 9 | 9 | 10 | 9 | 7 | 7 | C |
| macOS (10) | 1 | 0 | 0 | 8 | 9 | 2 | **E** |
| Effort (8) | 2* | 3 | 2 | 4 | 8 | 4 | **E** |
| Performance (7) | 6 | 5 | 8 | 7 | 9 | 6 | **E** |
| Ops complexity (8) | 3* | 3 | 2 | 4 | 7 | 3 | **E** |
| Architecture fit (9) | 3* | 4 | 3 | 5 | 10 | 6 | **E** |
| Competitive (7) | 7 | 4 | 5 | 6 | 6 | 4 | A |
| Future-proof (6) | 7 | 6 | 7 | 5 | 7 | 7 | A/E/F |
| **Weighted Total** | **300** | **269** | **335** | **400** | **517** | **304** | **E** |
| **Percentage** | **46.2%** | **41.4%** | **51.5%** | **61.5%** | **79.5%** | **46.8%** | **E** |

*gVisor macOS scores used (primary platform). Linux scores: effort 7, ops 8, arch 8 → 65.4%.

## Risk Analysis

### Option E Risks (recommended)

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Kernel 0-day escape (Dirty Pipe class) | Low | High | Keep Docker/kernel updated. Custom seccomp blocks io_uring/eBPF attack surface. Monitor CVEs |
| "No hypervisor" perception gap | Medium | Medium | Document 5-layer defense-in-depth. Reference OpenClaw CVE cluster as validation. Emphasize guard pipeline uniqueness |
| Future multi-tenant need | Low (not in roadmap) | Medium | Architecture supports future gVisor/VM tier. `ContainerManager` abstraction is clean |

### Option D Risks (runner-up)

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Docker Desktop lock-in | High | High | No mitigation — Docker Sandboxes are proprietary |
| Docker Desktop licensing change | Medium | High | Free for personal use today; could change |
| VirtioFS git corruption | Medium | Medium | Clone/worktree ops inside VM filesystem, not VirtioFS mounts |
| Two code paths diverge | High | Medium | Feature flags, shared test suites |

## Sources

Research documents produced by sub-agents:
- `docs/research/gvisor-container-isolation/research.md`
- `docs/research/kata-containers-cloud-hypervisor/research.md`
- `docs/research/firecracker-microvm/firecracker-microvm-evaluation.md`
- Sub-agent outputs: Docker Desktop VM, Status Quo + Hardening, Hybrid (in-context)

External references:
- [gVisor GitHub](https://github.com/google/gvisor) — macOS issue #1270
- [Firecracker GitHub](https://github.com/firecracker-microvm/firecracker) — macOS issue #2845
- [Kata Containers](https://github.com/kata-containers/kata-containers) — Unix socket issue #4244
- [Northflank — How to Sandbox AI Agents](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [NVIDIA — Practical Security for Agentic Workflows](https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/)
- [OpenClaw CVE cluster](https://www.adminbyrequest.com/en/blogs/openclaw-went-from-viral-ai-agent-to-security-crisis-in-just-three-weeks)
- [Docker AI Sandboxes](https://docs.docker.com/desktop/features/sandbox/)
- [NanoClaw Docker Sandboxes](https://github.com/qwibitai/nanoclaw/blob/main/docs/docker-sandboxes.md)
