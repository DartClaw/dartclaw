# ADR-026: Skill-Reference Validation via Harness Introspection

## Status

Accepted — 2026-05-30 (implemented in 0.17; recorded retroactively during the S11 milestone-documentation pass)

**Amends:** [ADR-025](025-andthen-as-runtime-prerequisite.md) — refines *how* DartClaw validates references to AndThen/plugin skills: this ADR replaces the load-time filesystem-mirroring validation mechanism with a run-preflight harness-introspection probe. (When this ADR was written, ADR-025's `install-skills.sh --prefix dartclaw-` provisioning was still in force; that provisioning was subsequently retired by [ADR-040](040-andthen-skills-via-canonical-name-resolution.md). The introspection-probe validation mechanism here is unchanged by ADR-040 and applies equally to the canonical `andthen:*` references it introduces.)

## Context

DartClaw shipped a filesystem-based `SkillRegistry` (`skill_registry_impl.dart`) that scanned nine source tiers (project `.claude`/`.agents`, workspace, data-dir native roots, user `~/.claude/skills` and `~/.agents/skills`, data-dir DC-managed, built-in DC-native, and a never-populated `pluginDirs` slot) to validate that workflow YAML `skill:` references resolved to an installed skill before a run started. It also parsed each skill's SKILL.md frontmatter to pull `workflow.default_prompt` / `workflow.default_outputs` / `emitsOwnOutcome` fallbacks.

This asserted an invariant over filesystem layouts DartClaw does not own and cannot reliably mirror:

- AndThen is installed as a Claude Code **plugin** at `~/.claude/plugins/cache/andthen/andthen/<version>/skills/`. `SkillRegistry.discover()` never scanned that path (the `pluginDirs` tier was defaulted to `const []` by all three CLI callers).
- Even scanning it would not help: Claude Code binds the `andthen:` namespace from the plugin manifest **at invocation time**, not on disk. Plugin SKILL.md files carry no `name:` field, so the parser fell back to the directory basename (`review`), producing registry key `review` — never the `andthen:review` the resolver expects for the `claude` provider. `_invocationNameFor` only worked for codex because AndThen authors hyphenated codex-tier directories (`andthen-review/`).
- The `workflow:` frontmatter fallbacks were an unused abstraction: 4 DC-native skills author the block; **0 of 27** AndThen claude-tier and **0 of 27** codex-tier skills do. Per-step `prompts:`/`outputs:` already override them.

Concrete failure (2026-05-27 maintainer run): `bash plan.sh <exported 0.17 plan>` excluded the `plan-and-implement-inline` workflow at load time with `Skill "andthen:review" not found for provider "claude"`, even though a spawned `claude` session lists `andthen:review` among its skills. DartClaw was failing on a layout it doesn't control while the true authority — the harness — could answer the question directly.

## Decision

**Delete the filesystem `SkillRegistry` and validate skill references against what the harness actually advertises.**

1. Remove `skill_registry_impl.dart`, its nine-tier discovery wiring, the `pluginDirs` plumbing, and the `workflow:` SKILL.md frontmatter extension. DartClaw no longer reads third-party SKILL.md frontmatter.
2. Replace load-time validation with a one-shot **agent-introspection probe** (`cli_skill_introspector.dart` behind a `SkillIntrospector` seam) that asks each referenced provider's harness which skills it can invoke. Validation runs at **run preflight** (`workflow_skill_preflight.dart`), before any step fires.
3. A typo'd or unavailable skill reference fails preflight with a clear error naming the missing skill and the provider that does not expose it — authoring errors still surface early, but are diagnosed by the actual authority (the harness) rather than a mirror.
4. DC-native skills (`dartclaw-*`) continue to be provisioned by `SkillProvisioner` to user-tier roots and invoked by both `claude` and `codex` harnesses, unchanged.

## Consequences

### Positive

- Workflows referencing plugin-provided skills (`andthen:review`, etc.) load and run regardless of install layout — the original blocker is gone.
- DartClaw stops mirroring marketplace/plugin/cache directory conventions it doesn't own and would have to chase on every upstream change.
- ~750 lines of registry implementation and its test surface (`skill_registry_impl_test.dart`) are deleted; the validation authority is single and correct.
- Validation is now provider-truthful: it reflects exactly what the spawned harness can invoke, including namespace binding done at invocation time.

### Negative

- Preflight now spends a one-shot harness probe per referenced provider (process spawn + introspection) instead of a filesystem scan — slower preflight, and it depends on the harness binary being runnable in the run environment.
- Validation moved from definition-load time to run preflight; a bad `skill:` reference is no longer caught at registry/load time, only at run start (still before any step fires).
- The probe couples preflight correctness to harness introspection output format; an upstream change to how a harness lists skills could require an adapter update.

## Alternatives Considered

1. **Scan the plugin/cache directories from `SkillRegistry`** — rejected: requires parsing the Claude Code plugin manifest format to recover the `andthen:` namespace (basename ≠ invocation name), and would still chase undocumented layout changes across Claude Code and AndThen releases. DartClaw would own a mirror of someone else's install contract.
2. **Reference `andthen:*` skills directly with no validation** — rejected: silently drops the early-error guarantee; a typo'd skill reference would surface only mid-run as a failed step instead of at preflight.
3. **Require AndThen authors to add `name:` frontmatter / flat directories** — rejected: DartClaw cannot impose authoring conventions on an upstream dependency, and it would not fix the invocation-time namespace binding that is the root cause.

## Implementation Notes

- Standalone FIS provenance: skill-discovery-removal, surfaced while running the 0.17 maintainer workflow.
- Key files: `cli_skill_introspector.dart`, `skill_introspector.dart`, `workflow_skill_preflight.dart` (added); `skill_registry_impl.dart` and `skill_registry_impl_test.dart` (removed); `skill_introspector_test.dart`, `workflow_executor_preflight_test.dart` (added coverage).
- Related constructor-size governance is recorded in [ADR-033](033-architectural-governance-via-fitness-functions.md): `constructor_param_count_test.dart` keeps service-wiring growth intentional after the registry removal.

## Project Compliance

- Aligns with the DartClaw guardrail "Never re-invent the wheel / don't assert invariants over what you don't own": the harness is the authority on its own skills.
- Preserves ADR-025's runtime-prerequisite model; only the validation mechanism changes, keeping the namespace and provisioning decisions intact.
- Honors the multi-provider design: validation is per-provider and reflects each harness's real capability surface.

## References

- [ADR-025: AndThen as Runtime Prerequisite](025-andthen-as-runtime-prerequisite.md)
- FIS provenance: skill-discovery-removal, 0.17 maintainer workflow.
- [Workflow architecture](../architecture/workflow-architecture.md)
- [Built-in workflows guide](../../docs/guide/workflows.md)
