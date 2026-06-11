# ADR-015 Research Appendix: Container Isolation Strategy — Hardened Docker over Hypervisor Isolation

> Frozen synthesis supporting [ADR-015](../015-container-isolation-strategy.md). Point-in-time as of the decision date; not maintained as the design evolves.

## Question
Which container isolation mechanism should DartClaw use for agent execution?

## Options considered
- Standard containers — pragmatic and available, but not a sandbox by themselves.
- gVisor — stronger syscall mediation, with platform and performance trade-offs.
- Kata / microVMs / Firecracker — stronger isolation, but heavier and less portable locally.
- No containers — lowest friction, unacceptable for untrusted agent execution.

## Trade-off summary
The strategy stages isolation: use containers as the operational baseline while leaving stronger runtimes as deployment-specific hardening.

## Deciding evidence
The comparative research found no single isolation runtime met portability, simplicity, and high-assurance security simultaneously for the early product.

## Sources (private)
- `docs/research/container-isolation-tradeoff/recommendation.md`
- `docs/research/container-isolation-tradeoff/research.md`
- `docs/research/firecracker-microvm/firecracker-microvm-evaluation.md`
- `docs/research/gvisor-container-isolation/research.md`
- `docs/research/kata-containers-cloud-hypervisor/research.md`
- `docs/research/sdk-security-architecture/research.md`
