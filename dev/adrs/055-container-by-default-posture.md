# ADR-055: Container-by-Default Posture — Detect at Startup, Downgrade Only What Was Inferred

**Status:** Accepted – 2026-08-27 (0.25)
**Deciders:** DartClaw team

**Related, and amended by this ADR:** [ADR-012](012-per-type-container-isolation.md) (per-type container isolation and profiles), [ADR-015](015-container-isolation-strategy.md) (hardened `network:none` container boundary), [ADR-051](051-container-bridge-binary-packaging.md) (host-shipped bridge binary), [ADR-052](052-native-provider-web-tools-denied-all-container-profiles.md) (native provider web tools denied for every container profile), [ADR-053](053-subscription-default-provider-authentication.md) (host-mediated subscription credentials — the gate that made this default affordable).

---

## Context

DartClaw's stated posture is "OS boundaries over application boundaries", but a default install shipped `container.enabled: false`. On exactly the installs most likely to run unattended work, the documented posture and the shipped posture disagreed: guards were the whole boundary and nothing said so at startup.

Flipping the *parsed* default to `true` is not available. Every refusal inside container wiring — no runtime, an engine architecture no bridge binary ships for, an undeliverable bridge — is startup-fatal today, so a parsed `true` would stop `dartclaw serve` from booting on every host without a container runtime. Isolation-by-default and "a host with no runtime still starts" have to hold simultaneously.

ADR-053 is the precondition: before host-mediated subscription credentials, the container path cost an operator a metered API key, so making it the default would have made the secure path the expensive one.

## Decision

`container.enabled` gains a third state — **unset** — meaning "isolate if this host can".

1. **Parse stops asserting a default it cannot know.** `ContainerConfig` distinguishes an unset section from an explicit `false`. The keys the parser reads are unchanged (`enabled`, `image`), and both stay registered in the config field registry at restart tier.
2. **One resolution step settles the posture before anything wires against it.** `resolveContainerPosture` probes the supported container CLIs in order and hands wiring a config whose `enabled` is a settled boolean, so every existing reader — startup banner, `ExecutionPolicyResolver`, `ConfigNotifier`, the server, `init` — keeps reading a plain boolean and the unresolved state is unreachable after startup.
3. **Requested and inferred do not share a failure path.** An explicit `container.enabled: true` keeps every fail-closed refusal. An inferred posture logs the same diagnosis and falls through to advisory mode, where the startup warning names *this host's* reason and points at `docs/guide/security.md`. The asymmetry is implemented once, at the refusal site inside container wiring, keyed on what the operator declared.
4. **Cross-section execution-policy validation moves behind resolution.** `execution: container` cannot be judged at parse time when the posture is unset, because the answer is process I/O. Parsing defers it; resolution re-runs it. `execution: container` under a posture that resolved to disabled is still startup-fatal — container execution is never silently replaced by host execution.
5. **A second container runtime is detected and used.** The runtime binary the probe answered with is carried on the resolved config and is what every subsequent container call issues. `podman` joins `docker` in the probe order.

## Consequences

- A default install on a host with a container runtime isolates agent execution with no config edit. A host without one starts, and says in unmissable terms that no OS boundary is active and why.
- Refusals that were only reachable on installs that asked for containers are now reachable on installs that did not. That is the whole risk surface of this change, and it is why every one of them downgrades under an inferred posture.
- `ExecutionPolicyResolver.hostOverrideWarnings()` now fires on installs that never saw it: an explicit `agent.execution: host` on a default install produces a boundary-weakened warning. Intended, and deliberately not suppressed.
- Native Windows is unchanged: `PlatformCapabilities.containerIsolationAvailable` gates detection, so auto-enable never runs there and the existing Windows-specific refusal for an explicit `true` stands.
- ACP's startup-fatal `container_isolation_required: true` admission is untouched. An auto-resolved posture neither satisfies nor softens it.
- Test suites and the shipped development and testing configurations now declare `container.enabled: false` explicitly. An undeclared posture would make what they exercise depend on whether the machine running them happens to have a container runtime installed.

### Known residual: the engine-architecture probe

Every verb container wiring issues is CLI-compatible across both supported runtimes **except** the engine-architecture probe's format field. A runtime that cannot answer it is treated as an ordinary downgrade signal, not as a startup hazard and not as a runtime special-cased by name. The practical effect is that such a host lands in advisory mode with the failure named, rather than failing to boot.

### Reviewed widening: the orchestration and content tools

The six orchestration and content tools (`workflow_run`, `workflow_list`, `schedule_upsert`, `schedule_list`,
`attach_media`, `wiki_write`) shipped with no `CanonicalTool` mapping, which made `_BridgeToolPolicy` refuse them for
every container authority — deny by default, opt in later. Making container the default posture turned that into a
capability regression: on a default install the primary agent could no longer call the tools this milestone added.

All six therefore carry canonical entries. The exposure rule is the host lane's, unchanged and not duplicated: the
primary agent is the deployment and reaches the whole servable map minus the session-spawning tools, while a task,
workflow or logical-agent lane reaches only what its own `allowedTools` names — so a lane that is capability-free on
the host stays capability-free in a container. Guarded dispatch, the audit entry per call and each tool's closed
schema are untouched.

### Scope limit: the zero-server workflow lane

Resolution runs in `dartclaw serve`. The zero-server `dartclaw workflow --standalone` lane keeps the parsed posture, so an undeclared posture there is disabled, exactly as it was before this change. Lifecycle-only verbs must not touch the container runtime at all, and extending detection into that lane is a separate decision with its own cost.

## Alternatives considered

- **Flip the parsed default to `true`.** Rejected: turns a missing runtime into a startup failure on every host without one.
- **Probe inside container wiring rather than at a resolution seam.** Rejected: the requested-vs-inferred distinction would then be re-derived at every refusal, which is how one branch silently drifts from the others.
- **Keep a boolean and add a separate "auto" key.** Rejected: two keys describing one posture is a second authority on the same question, and the config API would have to reconcile them.
