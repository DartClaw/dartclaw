# ADR-064: Container Isolation Is Opt-In

**Status:** Accepted – 2026-11-20 (0.28.2)
**Deciders:** DartClaw team (owner decision, 2026-11-20)

**Supersedes:** [ADR-055](055-container-by-default-posture.md) (container-by-default posture). **Related, and amended by this ADR:** [ADR-012](012-per-type-container-isolation.md) (per-type container isolation and profiles), [ADR-015](015-container-isolation-strategy.md) (hardened `network:none` container boundary). Unchanged: [ADR-052](052-native-provider-web-tools-denied-all-container-profiles.md) (native provider web tools denied for every container profile), [ADR-053](053-subscription-default-provider-authentication.md) (host-mediated subscription credentials).

---

## Context

ADR-055 gave `container.enabled` a third state, unset, meaning "isolate if this host can". `dartclaw serve` probed for `docker` then `podman` at startup and isolated agent execution where one answered. To let a host without a runtime still start, every refusal under that inferred posture downgraded to host execution with a warning, while an explicit `true` kept every refusal fail-closed.

Running that posture showed four problems:

1. **The inferred boundary was never a guarantee.** Every refusal under an inferred posture downgraded to host mode, so an operator who needed isolation had to declare `true` anyway.
2. **The posture depended on ambient machine state at boot.** Whether the Docker daemon answered decided where agents ran, and with that whether native web tools exist, whether workspace git sync is registered, and which credentials work. The shipped development and test configs had to declare `false` to stay deterministic.
3. **The inferred path kept generating its own cases.** The 2026-11-13 amendment to ADR-055 existed because a default install with only a CLI login failed to start on hosts with Docker. The posture also forced a declared-vs-inferred asymmetry on every refusal site, on parsing and on `doctor`.
4. **An unset key had two meanings.** `serve` resolved it by probing; the zero-server `dartclaw workflow --standalone` lane read it as disabled.

## Decision

Container isolation is an explicit opt-in. `container.enabled` is two-state again.

1. **Unset means `false` on every host.** Only `container.enabled: true` isolates. No lane probes for a runtime to decide the posture.
2. **`true` keeps every fail-closed refusal.** No runtime, an engine architecture no bridge binary ships for, an undeliverable bridge, and a default provider with no credential a container can use each stop startup. Nothing downgrades to host mode.
3. **Runtime selection runs only when isolation is on.** With containers off, `serve` runs no runtime probe. With them on, one startup step, `selectContainerRuntime` (formerly `resolveContainerPosture`), picks `docker`, then `podman`, and every container call issues the selected binary.
4. **`execution: container` without `container.enabled: true` is refused when the config loads.** The cross-section check is a parse-time rule again; nothing defers it to startup.
5. **Containers off is advisory mode.** `serve` logs the existing warning that the agent has full host access and guards are the only security boundary.
6. **`doctor` and `init` follow the two states.** `doctor` reports its container rows as `skip` when isolation is off and `fail` on any refusal when it is on; there is no `warn` "will downgrade" case. The `init` Full track's "Enable Docker container isolation?" preselects No, and a track that never asks leaves an existing `container:` section untouched.

Removed with the inferred posture: the unset third state (`declaredEnabled`), the inferred-vs-declared branch at each refusal site, `inferredPostureCredentialGap`, the deferred execution-policy validation, and the post-wiring posture correction.

Carried forward from ADR-055 unchanged: `podman` support; the canonical mappings that let a container authority reach the six orchestration and content tools (`workflow_run`, `workflow_list`, `schedule_upsert`, `schedule_list`, `attach_media`, `wiki_write`) under the host lane's exposure rule, now because a container deployment must reach what the host lane of the same kind reaches; the native Windows refusal of an explicit `true`; ACP's startup-fatal `container_isolation_required`; and ADR-052's native web tool denial for every container profile.

## Consequences

- An upgrading install with no `container:` section on a host with Docker or Podman loses its OS boundary at 0.28.2 until the operator writes `container.enabled: true`. This trades the default boundary for a deterministic one. It reverses an accepted decision, which `dev/state/PRODUCT.md` § Deciding reserves to the owner; the owner approved it on 2026-11-20.
- Where agents run, which tools they have, whether workspace git sync is registered and which credentials work now follow from the config file alone, the same on every machine and in every lane. `serve` and `dartclaw workflow --standalone` read an unset key the same way.
- A default install with only a vendor CLI login starts on any host, because host execution can use that login.
- An operator who writes `true` gets isolation or a startup refusal naming the cause, and `dartclaw doctor` reports the same cause beforehand as a `fail`.

## Alternatives considered

- **Keep ADR-055.** Rejected for the four reasons in Context.
- **Keep auto-detection but make inferred refusals fatal.** Rejected: a host that merely has a broken or stopped runtime would fail to start without having asked for containers.
- **Have `init` detect a runtime and write `true` unasked.** Rejected: the Full track asks instead. Runtime detection in `init` is a separate decision.
