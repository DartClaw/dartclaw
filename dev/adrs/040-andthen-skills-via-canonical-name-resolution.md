# ADR-040: AndThen Skills via Canonical-Name Resolution (No Runtime Clone/Install)

## Status

Accepted — 2026-06-04 (implemented in 0.17 as the SP-1/SP-2 security remediation; recorded retroactively 2026-06-18 during the 0.19 ADR-fidelity pass)

**Supersedes:** [ADR-025](025-andthen-as-runtime-prerequisite.md) §Decision (the runtime-provisioning architecture and the `dartclaw-*` install-time namespace). The *core* ADR-025 decision — depend on AndThen as a versioned runtime prerequisite rather than porting its skills — stands. What changes is *how* the dependency is satisfied: DartClaw no longer clones AndThen, runs its installer, or owns a branded namespace.

**Related:** [ADR-026](026-skill-reference-validation-via-harness-introspection.md) (validates the resolved reference at run preflight via a harness-introspection probe — the mechanism that surfaces a missing skill), [ADR-027](027-claude-harness-setting-sources-default.md) (spawned `claude` sessions load user-scope settings/plugins by default, so the user-installed `andthen:*` plugin skills are visible to workflow steps).

## Context

ADR-025 (and its 2026-04-27 / 2026-05-04 revisions) established that DartClaw cloned upstream AndThen into `<data_dir>/andthen-src/` at `dartclaw serve` startup and shelled out to `install-skills.sh --prefix dartclaw-` to materialise a DartClaw-branded `dartclaw-*` skill set in the native user-tier roots. Workflow YAMLs referenced those installed `dartclaw-*` names, and ADR-025 §Decision 2 stated explicitly that *"DartClaw does not invoke any `andthen-*` skill name at runtime."*

That model carried two structural problems:

- **Security (SP-1/SP-2).** The provisioner constructed `git` subprocess invocations from operator-supplied `andthen.git_url` / `andthen.ref`. A ref/URL shaped like an option is an argument-injection surface on a host-level subprocess. Hardening individual call sites does not remove the category — the safe move is to delete the git-source surface entirely.
- **It asserted ownership of a layout DartClaw does not control.** AndThen installs as a Claude Code **plugin** (`~/.claude/plugins/.../skills/`), and Claude binds the `andthen:` namespace from the plugin manifest at invocation time, not from a mirrored on-disk layout (see ADR-026 Context for the concrete load-time failure this produced).

## Decision

**Depend on AndThen as already installed for the active provider, and resolve canonical skill names to provider-native names at workflow-load time. Do not clone, install, or rebrand.**

1. **The git-source provisioning surface is retired.** `SkillProvisioner` has no `git_url`, `ref`, `network`, cached-source, or git-subprocess path. Legacy `andthen.*` keys in `dartclaw.yaml` are ignored with a warning and control nothing.
2. **Workflow YAMLs reference AndThen skills by canonical logical name** — `skill: andthen:spec`, `andthen:review`, `andthen:remediate-findings`, etc. — not by a `dartclaw-`-branded name. This reverses ADR-025 §Decision 2: DartClaw *does* reference the `andthen:`/`andthen-*` names at runtime.
3. **DartClaw resolves the canonical reference to the provider-native skill name:**
   - Claude Code → `andthen:spec` (plugin namespace, bound by the harness)
   - Codex → `andthen-spec` (hyphenated skill directory)
   - Unknown providers → the authored name verbatim.
4. **AndThen is an operator-installed prerequisite** for whichever provider runs the workflow. DartClaw neither installs nor version-pins it; the resolved AndThen is whatever the operator has installed. Provider skill roots are independent (a Codex install does not satisfy a Claude run).
5. **Only the four DC-native skills are bundled and copied** by `SkillProvisioner` (`packages/dartclaw_workflow/lib/src/skills/skill_provisioner.dart`): `dartclaw-discover-andthen-spec`, `dartclaw-discover-andthen-plan`, `dartclaw-validate-workflow`, `dartclaw-merge-resolve`. At `dartclaw serve` startup and before `dartclaw workflow run --standalone` they are copied into `<dataDir>/.agents/skills/` (Codex) and `<dataDir>/.claude/skills/` (Claude Code); configured project workspaces receive links or managed fallback copies for those directories only.
6. **A missing AndThen skill is caught at run preflight** by the harness-introspection probe (ADR-026), which names the canonical reference, the provider, and the concrete provider-native name searched — not a manual upstream install error.

## Consequences

### Positive

- The host-level git-subprocess argument-injection surface (SP-1/SP-2) is gone — not mitigated, deleted.
- DartClaw stops asserting an on-disk layout it does not own; correctness now defers to the authority (the harness) that actually binds skill names.
- No clone/install step at startup: faster, network-free boot for the AndThen-derived skills; only the four bundled DC-native skills are copied.
- Upstream AndThen improvements are picked up by the operator's normal AndThen update path, with no DartClaw-side version bump or reprovision.
- One honest operator surface: "install AndThen for your provider," documented in [`docs/guide/andthen-skills.md`](../../docs/guide/andthen-skills.md).

### Negative

- DartClaw cannot guarantee a minimum AndThen version — the resolved skills are whatever is installed. Version-skew (an upstream skill changing output shape) is an operator responsibility; preflight introspection catches *absence*, not *shape drift*.
- Operators running both providers must keep both provider skill roots current independently.
- No DartClaw-owned namespace isolation: a workflow speaks the upstream `andthen:*` names directly, so the AndThen origin is visible rather than an install-time detail (the coexistence concern ADR-025's 2026-04-27 revision optimised for is no longer addressed — accepted, because DartClaw no longer writes into any AndThen-adjacent namespace and so cannot stomp on a separate install).

## Alternatives considered

- **Keep the clone + `install-skills.sh --prefix dartclaw-` model (ADR-025 as written), hardening the git call sites.** Rejected: argument-injection is a category, not a bug; the safe design removes the subprocess surface. Also retains the unowned-layout fragility ADR-026 documents.
- **Vendor AndThen at a pinned commit** to regain version control. Rejected for the same reasons ADR-025 rejected it (source-tree weight, manual update cadence) and because it reintroduces a DartClaw-managed copy on disk; remains the escape hatch if shape-drift becomes a recurring problem.
