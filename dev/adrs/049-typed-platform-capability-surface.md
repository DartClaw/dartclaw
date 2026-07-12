# ADR-049: Typed Platform Capability Surface

**Status:** Accepted – 2026-07-11. Targets 0.21 Windows support.
**Deciders:** DartClaw team

**Related:** [ADR-015](015-container-isolation-strategy.md) (container-isolation capability), [ADR-048](048-release-builds-dart-build-bundled-sqlite.md) (cross-platform release baseline)

---

## Context

DartClaw's Windows milestone needs one auditable source for home resolution, executable lookup policy, shell choice, signal and termination semantics, POSIX file-permission availability, and feature availability. Direct `Platform.isWindows` branches across consumers make security and degradation claims drift and are difficult to test from non-Windows CI.

### Decision drivers

- Security-relevant platform claims must be explicit and honest.
- Windows behavior must be testable from POSIX CI through injected inputs.
- The surface must serve the known lifecycle, reload, isolation, bash, and harness consumers without speculative extension points.
- Platform policy must stay separate from subprocess execution and other effects.

## Decision

Create one immutable `PlatformCapabilities` value in `dartclaw_config`, constructed with injectable operating-system and environment inputs that default to `Platform`.

The public contract uses named members:

- nullable home-directory resolution with `HOME` → `USERPROFILE` precedence;
- executable lookup command data: `where` on Windows, `which` on POSIX;
- `BashShellPolicy.systemSh | gitBashRequired`;
- the required `posixSignalsAvailable` boolean;
- `ProcessTerminationSemantics.posixSignalEscalation | hardTerminate`;
- POSIX file-permission availability;
- container-isolation availability.

Expose one structured `UnsupportedCapabilityError` carrying the capability name, attempted context, and remediation. Consumers own executable lookup execution, remediation wording, and other process I/O.

The platform truth table is:

| Capability | Windows | POSIX |
|---|---|---|
| Bash shell policy | Git Bash required | `/bin/sh` |
| POSIX signals | Unavailable | Available |
| Process termination | Hard terminate | SIGTERM → SIGKILL escalation |
| POSIX file permissions | Unavailable | Available |
| Container isolation | Unavailable | Available |

## Consequences

**Positive**

- Platform claims become explicit, discoverable, and host-independently testable.
- S03–S07 share one contract instead of adding raw OS branches.
- Security degradation is represented as capability data rather than inferred from scattered code.

**Negative / accepted**

- Consumers gain a dependency on `dartclaw_config`'s capability type.
- New capabilities require intentional public API additions.
- The flat surface may eventually need grouping; that is deferred until coherent categories exist.

## Alternatives Considered

1. **Typed category objects** – rejected for now: explicit but adds structure before categories have enough independent behavior.
2. **Enum-keyed table** – rejected: less discoverable and encourages a registry posture.
3. **OS subclasses** – rejected: hides a small truth table behind unnecessary indirection.
4. **Operational service** – rejected: mixes deterministic policy with subprocess I/O and failure handling.

## Implementation Notes

- S01 owns the value, enums, error type, package export, and dual-OS tests.
- S03–S07 consume exact members from this contract.
- Structural checks prevent new raw platform branches in the touched decision paths.
- Executable availability remains an effectful consumer concern; the surface supplies only lookup policy and command data.

## Project Compliance

This decision follows DartClaw's smallest-change, reuse-first, security-honesty, and approachable-over-clever requirements. It centralizes policy without speculative registries or hierarchies.

## References

- [Public research appendix](research/049-typed-platform-capability-surface.md)
