# ADR-027: Claude Harness Setting-Sources Default — Load User Scope by Default, Isolation Opt-In

## Status

Accepted — 2026-05-30 (implemented in 0.17; recorded retroactively during the S11 milestone-documentation pass)

**Related:** [ADR-016](016-multi-provider-harness-architecture.md) (owns harness CLI-arg construction — this adds `--setting-sources` to that surface), [ADR-025](025-andthen-as-runtime-prerequisite.md) (native user-tier install scope), [ADR-026](026-skill-reference-validation-via-harness-introspection.md) (harness-introspection skill validation). Container-path isolation is governed separately by [ADR-012](012-per-type-container-isolation.md) / [ADR-015](015-container-isolation-strategy.md); this ADR concerns only the **non-container direct spawn path**. This decision is a **trust-boundary change** and is cross-referenced from `dev/architecture/security-architecture.md`.

## Context

Spawned `claude` sessions — both the long-lived session harness (`claude_code_harness.dart`) and the task/workflow one-shot path (`claude_cli_provider.dart`) — passed `--setting-sources project` unconditionally. That flag tells Claude Code to load **only** project-scoped settings, ignoring user scope (`~/.claude`). Consequence: user-installed plugins and their skills were invisible to spawned sessions.

This collided directly with ADR-025's 2026-05-04 simplification, which installs AndThen natively at user tier (`~/.claude/plugins/...`, `~/.claude/skills`). A workflow step pinned to `provider: claude` that needs an `andthen:*` skill (e.g. the inline `plan-and-implement-inline` `plan-review-council` step) could not see it: the harness was told to ignore the very scope the skills were installed into. The mismatch also defeated the ADR-026 introspection probe, which must reflect the execution environment to be meaningful.

The default therefore had to be reconsidered, and it is security-relevant: loading user scope by default widens the trust boundary of a spawned agent to include everything the operating user has configured (settings, hooks, plugins, MCP servers).

## Decision

**Make loading all setting sources the default for spawned `claude` sessions; demote project-only isolation to an explicit per-provider opt-in.**

1. New config option `providers.claude.inherit_user_settings` (bool, default **`true`**), parsed in `dartclaw_config` (`claude_provider_options.dart`, `config_parser.dart`).
2. Default (`true`): no `--setting-sources project` flag is emitted — Claude Code loads user + project + local per its own default, so user-installed plugins/skills are available.
3. Opt-in isolation (`inherit_user_settings: false`): both spawn paths emit `--setting-sources project` (positioned before `--model`, preserving prior arg order), restoring project-only behavior. The isolation capability is preserved, not removed.
4. The workflow skill-preflight probe (ADR-026) reads the **same** option, so preflight visibility matches the execution environment: default config probes all sources; `inherit_user_settings: false` probes project-only.
5. The **containerized** spawn path is unchanged regardless of the option — the container already provides isolation; the new option does not alter it.
6. An invalid/unknown `inherit_user_settings` value degrades gracefully (warn + default to loading all sources), consistent with other `providers.<id>.*` parsing.

## Consequences

### Positive

- User-installed plugins/skills "just work" in spawned sessions — `andthen:*` skills become visible, aligning runtime behavior with the ADR-025 install model.
- Preflight (ADR-026) and execution agree on the provider-visible skill set.
- The previously rejected, repeatedly-hit failure ("Missing skills for provider claude: andthen:review") is resolved without per-workflow workarounds.
- Behavior matches ordinary interactive Claude Code usage, reducing surprise for operators.

### Negative

- **Widened default trust boundary.** A spawned agent now inherits user-scope settings, hooks, plugins, and MCP servers by default. Operators who relied on the implicit project-only isolation must now set `inherit_user_settings: false` explicitly. This is documented where harness/maintainer config lives.
- Two configuration realities (inherited vs isolated) must be reflected in harness arg-construction tests, the preflight probe, and docs.
- The non-container direct path is the one affected; reviewers must remember the container path is governed separately.

## Alternatives Considered

1. **Keep `--setting-sources project` as the hardcoded default, require per-step overrides to see user skills** — rejected: every workflow needing a plugin skill would carry a workaround, and the default would silently contradict the ADR-025 user-tier install. The failure mode is invisible until a step can't find a skill.
2. **Always load all sources, remove the isolation flag entirely** — rejected: project-only isolation is a legitimate security posture (e.g. running untrusted project workflows); removing it would be a capability regression.
3. **Install AndThen at project scope instead of user scope** — rejected: contradicts ADR-025's 2026-05-04 native user-tier decision and its rationale (OAuth/Git/MCP/plugin-state alignment with ordinary CLI usage).

## Implementation Notes

- FIS provenance: 0.17 maintainer workflow, claude-harness-setting-sources.
- Config surface: `claude_provider_options.dart` (`inheritUserSettingsKey`, `inheritUserSettings`, `useProjectSettingSources`).
- Emission sites: `claude_code_harness.dart` `_buildClaudeArgs`; `claude_cli_provider.dart` arg construction; workflow skill-preflight probe — all gated on the same option; no `--setting-sources project` token remains hardcoded in production code.
- Operators wanting project-only isolation on the direct (non-container) path must set `providers.claude.inherit_user_settings: false`.

## Project Compliance

- Consistent with the configuration philosophy: typed `providers.<id>.*` option, graceful degradation on invalid values, sensible default.
- Recorded as a security-relevant default change in `dev/architecture/security-architecture.md` per the "fail loud, surface trust-boundary changes" guardrail.
- Preserves multi-provider symmetry: the option is claude-specific because the `--setting-sources` flag is a Claude Code concept; the container isolation model is untouched.

## References

- [ADR-016: Multi-Provider Harness Architecture](016-multi-provider-harness-architecture.md) (harness CLI-arg surface this extends)
- [ADR-012: Per-Type Container Isolation](012-per-type-container-isolation.md) / [ADR-015: Container Isolation Strategy](015-container-isolation-strategy.md) (govern the container path, unchanged here)
- [ADR-025: AndThen as Runtime Prerequisite](025-andthen-as-runtime-prerequisite.md)
- [ADR-026: Skill-Reference Validation via Harness Introspection](026-skill-reference-validation-via-harness-introspection.md)
- FIS provenance: 0.17 maintainer workflow, claude-harness-setting-sources.
- [Security architecture](../architecture/security-architecture.md)
- [Control protocol](../architecture/control-protocol.md)
