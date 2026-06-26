# ADR-041: Framework-Agnostic Workflow Engine — Steps Are Skill + Inputs + Generic Output Validation; Skills Own Their Domain Semantics

## Status

Accepted — 2026-06-22 (0.19). Records the decision and its enforcement; the migration is specced separately as a sibling plan bundle (`dev/bundle/docs/specs/workflow-andthen-decoupling/`).

**Refines / extends:** [ADR-025](025-andthen-as-runtime-prerequisite.md) (depend on AndThen as a runtime prerequisite) and [ADR-040](040-andthen-skills-via-canonical-name-resolution.md) (resolve AndThen skills by canonical name, no clone/install). This ADR does **not** reverse either: AndThen remains the default operator-installed SDD framework, and skills are still referenced by canonical name. It adds the rule that the workflow engine's `.dart` code carries **no** framework-specific knowledge — the AndThen coupling lives only in bundled `definitions/*.yaml` and bundled DC-native `skills/` payloads, never in engine code.

**Related:** [ADR-031](031-native-first-structured-outputs.md) (the `outputMode: structured` / schema-preset mechanism this ADR makes the *sole* output-shape gate), [ADR-033](033-architectural-governance-via-fitness-functions.md) (the fitness-function governance level this ADR's enforcement check joins), [ADR-034](034-enforced-package-dependency-direction.md) (the dependency allowlist whose spirit the undeclared AndThen coupling violated).

## Context

`packages/dartclaw_workflow/` is positioned and documented as a framework-agnostic *workflow control plane* with a four-package production-dependency allowlist (`dartclaw_config`, `dartclaw_core`, `dartclaw_models`, `dartclaw_security`; enforced by `dev/tools/arch_check.dart`). Its engine `.dart` code under `lib/src/workflow/` (excluding `definitions/*.yaml`; package-root `skills/` payloads live outside `lib/src/`) contradicts that positioning: it carries hardcoded knowledge of AndThen. It dispatches behavior on literal AndThen skill names, re-implements AndThen artifact-schema validation (PRD markdown, `plan.json` `stories[].fis`/`status`, the status vocabulary `pending`/`spec-ready`/`in-progress`/`blocked`/`done`/`skipped`), and re-derives the discovery skill's own resume-filter logic.

`produced_artifact_resolver.dart` says so in a comment: the status enum is *"Mirrored from `dartclaw-discover-andthen-plan/SKILL.md` rule 6 … Keep these two sites in sync."* That is an **undeclared fifth dependency** — invisible to the package dependency allowlist — and a Connascence-of-Algorithm duplication between a skill prompt and engine code, with a manual "keep in sync" obligation that will drift.

A code review of the four validator files (`discover_andthen_plan_validator.dart`, `discover_andthen_spec_validator.dart`, `story_specs_contract_validator.dart`, `produced_artifact_resolver.dart`) found 22 distinct checks:

- **~14 generic.** Path containment / existence / argument-safety (concerns of a `format: path` output) and type / required / enum / object-shape (concerns of a declared `schema:`).
- **~8 AndThen-semantic.** Status vocabulary, `plan.json` parsing, rule-6 resume filtering, `spec_source` ↔ `spec_path` cross-field consistency, FIS marker headers.

Three of the semantic checks **mutate** the skill's output (normalize status → `pending`, prune satisfied deps on resume, clear an empty plan), and all three re-derive things the discovery skill *already does* from the *same* `plan.json` it reads — its `SKILL.md` rule 6 documents this. The engine duplication is defense-in-depth against the LLM, not a computation the skill cannot perform.

## Decision

**The workflow engine validates a step's output using only two framework-neutral mechanisms it already owns. All framework-specific semantics move out of engine `.dart` code into skills and workflow YAML.**

1. **Declared output schema** (`schema:` presets or inline) — types, required fields, enums, object shape, `additionalProperties: false` — enforced via `outputMode: structured` (prompt-suffix injection + fallback extraction turn) and the soft schema validator (ADR-031, `schema_presets.dart` / `schema_validator.dart`).
2. **Generic `format: path` trust-boundary validation** — workspace-relative containment, existence, argument-safe characters, symlink-aware escape rejection — applied uniformly to **every** path output from **any** skill, never gated on skill name. This is a security boundary an LLM cannot be trusted with, and it is framework-neutral.

Everything framework-specific is the skill's job:

- Skills own their domain semantics — status normalization, rule-6 resume filtering, dependency pruning, empty-plan handling, cross-field consistency — and emit a final, clean structured payload.
- Skip / resume decisions are expressed as workflow-YAML `entryGate` / `gate` expressions reading the skill's structured output (e.g. `spec_source == synthesized`, `story_specs.items isNotEmpty`), not re-derived in Dart.
- The only AndThen dependency in the package is the bundled `definitions/*.yaml` workflow files and the bundled DC-native `skills/` payloads — **never engine `.dart`**.

### Open edge case: no active workspace root

When no active workspace root resolves, the generic `format: path` validator performs **containment-only and skips the existence check** (existence is verified only when a root is present). This is behavior-preserving and consistent with the workspace-root cwd-fallback fix in `dev/bundle/docs/specs/standalone-workflow-active-workspace-root-cwd-fallback.md`.

## Consequences

### Positive

- Net deletion of the four bespoke validators, the skill-name dispatch gates (`workflow_executor_helpers.dart`, `step_dispatcher.dart`), the `DiscoverAndthen*` typedefs, the `step_outcome_normalizer` re-exports, and the hardcoded `andthen:*` allowlists (`workflow_artifact_committer.dart`, `workflow_definition_validator.dart`).
- The package becomes genuinely framework-agnostic and can host non-AndThen SDD frameworks (Spec Kit, OpenSpec, BMAD) via YAML + skills alone.
- The engine ↔ `SKILL.md` duplication — and its "keep these two sites in sync" drift risk — is eliminated.

### Trade-off (explicit)

The engine stops re-checking the skill's *domain* correctness in Dart, i.e. less code-side defense-in-depth. This is acceptable because the two failure modes that actually matter are still caught generically:

- **Security** (path escape / missing file) — by the `format: path` validator.
- **Malformed shape** (bad type / enum / extra field) — by the declared schema with `additionalProperties: false`.

What remains is the skill's responsibility — emitting domain-correct, well-formed, in-bounds output — which is correctly the skill's job. Re-implementing it in the engine is the duplication this ADR removes.

### Enforcement (fitness function)

A CI gate asserts **zero** `andthen` / `dartclaw-discover-andthen` literals (case-insensitive) in `packages/dartclaw_workflow/lib/src/`, excluding only built-in workflow `definitions/*.yaml`. Package-root `skills/` payloads are outside that scan scope; any `lib/src/skills` support code remains engine code and is scanned. This converts "framework-agnostic" from aspiration into an enforced, ratcheted invariant — **governance level 2**, sibling to the existing `dev/tools/arch_check.dart` ceilings (ADR-033).

## Alternatives considered

1. **Status quo — keep the bespoke validators, harden the "keep in sync" comments.** Rejected: the duplication is structural (Connascence of Algorithm across a process boundary), not a comment-discipline problem. The fifth dependency stays invisible to the allowlist and the package stays AndThen-specific in fact while documented as agnostic.
2. **Declare AndThen as an explicit fifth production dependency and own the coupling honestly.** Rejected: it codifies the very thing the package exists to avoid (framework lock-in in the control plane) and still leaves the skill ↔ engine algorithm duplication. The agnostic positioning is the product decision (ADR-025 §Positioning); this alternative reverses it.
3. **Push only the *mutating* semantics to skills, keep read-only semantic assertions in the engine as defense-in-depth.** Rejected: a partial move keeps the skill-name dispatch surface and the drift-prone mirror, for defense-in-depth already covered generically by schema + `format: path`. Half-agnostic is not enforceable as an invariant.
