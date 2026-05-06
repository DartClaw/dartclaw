# S09 — `dartclaw_workflow` Barrel Narrowing

**Plan**: ../plan.md
**Story-ID**: S09

## Feature Overview and Goal

Tighten the `dartclaw_workflow` public API by replacing 34 wholesale `export 'src/...'` lines in `packages/dartclaw_workflow/lib/dartclaw_workflow.dart` with explicit `show`-clause exports. Remove only symbols proven unused outside `dartclaw_workflow`; do not force a numeric cap by breaking live downstream consumers. This is a load-bearing prerequisite for S10's `barrel_show_clauses_test.dart` fitness gate; the numeric soft-cap ratchet belongs to S25.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S09" entry under per-story File Map; Shared Decisions #20 and "Cross-cutting" #11)_

## Required Context

### From `prd.md` — "FR2: Barrel & Public-API Discipline"
<!-- source: ../prd.md#fr2-barrel--public-api-discipline -->
<!-- extracted: e670c47 -->
> **Description**: Every `export 'src/...'` in a package barrel uses a `show` clause. Known over-exported types (canvas advisor re-exports, channel-package typedefs) are demoted.
>
> **Acceptance Criteria**:
> - `dartclaw_workflow` barrel has ≤35 exports with `show` clauses
> - `barrel_show_clauses_test.dart` fitness function passes
>
> **Error Handling**: Fitness function allowlist frozen at current intentional violators; any new wholesale export fails build.

> **Correction for execution**: the `≤35` count in the extracted PRD text is treated as a soft-cap target for S25, not a hard S09 gate. S09 must eliminate wholesale `src/` exports and may remove proven-unused internals, but it must preserve live public symbols needed by `dartclaw_server`, `dartclaw_cli`, and package tests.

### From `plan.md` — "S09: dartclaw_workflow Barrel Narrowing"
<!-- source: ../plan.md#s09-dartclaw_workflow-barrel-narrowing -->
<!-- extracted: e670c47 -->
> **Scope**: Add `show` clauses to every `export 'src/...'` in `packages/dartclaw_workflow/lib/dartclaw_workflow.dart`. Remove candidates that are truly internal-only (e.g. `workflow_definition_source.dart`, `workflow_turn_adapter.dart`, `workflow_template_engine.dart`, `skill_registry_impl.dart`, `shell_escape.dart`, `map_step_context.dart`, `json_extraction.dart`, `dependency_graph.dart`, `duration_parser.dart` — already in `dartclaw_config`, `step_config_resolver.dart`) only when audit proves no live downstream consumer. Fix downstream imports in `dartclaw_server` and `dartclaw_cli` that previously relied on the wholesale exports.
>
> **Acceptance Criteria**:
> - Every `export 'src/...'` in `dartclaw_workflow/lib/dartclaw_workflow.dart` uses a `show` clause
> - Barrel exposes explicit `show` clauses without dropping live downstream API
> - `dart analyze` workspace-wide is clean after downstream import fixes
> - `dart test` workspace-wide passes

### From `.technical-research.md` — "Binding PRD Constraints" (S09-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #11 (FR2): "`dartclaw_workflow` barrel has ≤35 exports with `show` clauses." — Applies to S09.
> #13 (FR2): "`barrel_show_clauses_test.dart` fitness function passes; allowlist frozen at intentional violators; new wholesale export fails build." — Applies to S09 + S10. (S09 produces the post-narrowing baseline; S10 freezes it.)
> #2 (Constraint): "No new dependencies in any package." — Applies to all stories; this story adds no deps.
> #73 (NFR DX): "`dart analyze` workspace-wide: 0 warnings (maintained)." — Applies to all code-touching stories.

> **Correction for execution**: #11's numeric count is baseline/ratchet data, not permission to remove live host-port or downstream API symbols.

### From `.technical-research.md` — "Shared Architectural Decisions #20"
<!-- source: ../.technical-research.md#cross-cutting-non-arrow-shared-decisions -->
<!-- extracted: e670c47 -->
> **20. Public API barrels** — every `export 'src/...'` uses `show` post-S09 + S10. Per-pkg soft caps (S25): `dartclaw_core ≤80`, `dartclaw_config ≤50`, `dartclaw_workflow ≤35`, others ≤25.

## Deeper Context

- `packages/dartclaw_core/lib/dartclaw_core.dart` — reference pattern for `show`-clause barrel layout (grouped exports with leading section comments; multi-line `show` for sealed hierarchies). Mirror this style.
- `packages/dartclaw_workflow/CLAUDE.md` § "Boundaries" — "Cross-package `lib/src/` imports are forbidden — consume other workspace packages through their barrels." Reinforces that any downstream consumer relying on the unscoped barrel must move to a `show`-listed symbol or accept a removal.
- `dev/state/PRODUCT.md` — pre-1.0 stage; no external SDK consumers; breaking-API removal acceptable when documented in CHANGELOG.
- `apps/dartclaw_cli/test/commands/workflow/workflow_materializer_test.dart:14` — uses `package:dartclaw_workflow/src/workflow/definitions/code-review.yaml` as an asset URI (not a Dart import). Asset URIs are unaffected by barrel narrowing; do not migrate.

## Success Criteria (Must Be TRUE)

- [ ] Every `export 'src/...'` line in `packages/dartclaw_workflow/lib/dartclaw_workflow.dart` uses an explicit `show` clause (zero unscoped src exports remain)
- [ ] The barrel exposes only explicit `show` clauses for `src/...` exports; the resulting symbol count is recorded for S25's soft-cap ratchet, but no live downstream symbol is removed solely to hit a number
- [ ] Each named likely-internal-only candidate from the plan scope (`workflow_definition_source.dart`, `workflow_turn_adapter.dart`, `workflow_template_engine.dart`, `skill_registry_impl.dart`, `shell_escape.dart`, `map_step_context.dart`, `json_extraction.dart`, `dependency_graph.dart`, `duration_parser.dart`, `step_config_resolver.dart`) is either removed from the barrel OR retained with a one-line comment-justified rationale on the export line
- [ ] `dart analyze` workspace-wide: 0 warnings, 0 errors after downstream import fixes
- [ ] `dart test` workspace-wide: passes (no behavioural regressions)
- [ ] CHANGELOG `0.16.5 - Unreleased` section gains a single bullet under a `### Changed` (or "Breaking" sub-bullet if any retained-but-renamed boundary): "Narrowed `dartclaw_workflow` public API surface — every `export 'src/...'` now uses an explicit `show` clause; internal-only types removed: <enumerated list>." Wording exact-form not prescribed; content must enumerate removed candidates or state that the first pass preserved all live symbols.

### Health Metrics (Must NOT Regress)

- [ ] Existing `packages/dartclaw_workflow/test/**` and downstream `packages/dartclaw_server/test/**`, `apps/dartclaw_cli/test/**` suites remain green
- [ ] JSON wire formats (workflow YAML schema, REST envelopes, SSE event payloads) unchanged — Constraint #1 / #76
- [ ] Built-in workflow YAML contract tests (`built_in_workflow_contracts_test.dart`, `built_in_skill_inventory_test.dart`) remain green
- [ ] `dev/tools/check_versions.sh` + `arch_check.dart` continue to pass

## Scenarios

### Barrel exports go from 34 wholesale → explicit `show` clauses
- **Given** `packages/dartclaw_workflow/lib/dartclaw_workflow.dart` currently has 34 `export 'src/...'` lines without `show` clauses
- **When** the story is complete
- **Then** `rg "^export 'src/" packages/dartclaw_workflow/lib/dartclaw_workflow.dart | rg -v ' show '` returns zero lines, and the distinct identifier count across all `show` clauses is recorded for S25

### Downstream import in `dartclaw_server` survives the cut
- **Given** a downstream file (e.g. `packages/dartclaw_server/lib/src/api/workflow_routes.dart`) currently imports `package:dartclaw_workflow/dartclaw_workflow.dart` referencing symbols that may be among the removed-internal candidates
- **When** the barrel is narrowed and any broken references are rewritten to typed `show`-listed imports (or, for genuine internal access, the import is moved to a different package's typed surface)
- **Then** `dart analyze packages/dartclaw_server` is clean, no symbol still resolves through the unscoped wildcard import

### Removed internal-only candidate is no longer reachable
- **Given** a removed candidate such as `WorkflowDefinitionSource` (if downstream usage proves it's truly internal)
- **When** any code outside `dartclaw_workflow` attempts `import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionSource`
- **Then** `dart analyze` reports `Undefined name 'WorkflowDefinitionSource'` (or equivalent), preventing reintroduction

### Future wholesale `export 'src/...'` PR fails the S10 fitness test
- **Given** S09 has shipped and S10's `barrel_show_clauses_test.dart` is in place against the post-S09 baseline
- **When** a hypothetical PR adds a new `export 'src/foo.dart';` (no `show`) to any workspace barrel
- **Then** `dart test packages/dartclaw_testing/test/fitness/barrel_show_clauses_test.dart` fails with file + line pointing at the offender — verified via plan's Constraint #82 ("Adding a new wholesale `export 'src/...'` … fails the build locally"). _Note: S10 owns the test file; S09 only ensures the post-narrowing baseline is the locked-in starting state._

### Retained borderline candidate carries rationale
- **Given** during audit (TI01) a candidate from the plan's list is found to have ≥1 legitimate downstream consumer (e.g. `workflow_turn_adapter.dart:WorkflowTurnAdapter` is host-injected by `dartclaw_server`)
- **When** the export survives the curation pass
- **Then** the `show` clause for that candidate carries a `// retained: <one-line rationale>` end-of-line comment (or is grouped under a section comment), making the decision auditable in code review

## Scope & Boundaries

### In Scope
- Replace every `export 'src/...'` line in `packages/dartclaw_workflow/lib/dartclaw_workflow.dart` with a `show`-clause variant (preserving all current symbols on first pass)
- Curate the surface: per-candidate-removal of likely-internal types, gated by downstream `dart analyze`
- Rewrite downstream imports in `packages/dartclaw_server/lib/` and `apps/dartclaw_cli/` (lib + test) that depended on removed symbols, switching to typed alternatives or accepting the removal
- Add CHANGELOG bullet under `0.16.5 - Unreleased`
- Update `packages/dartclaw_workflow/CLAUDE.md` § "Key files" if a removed-from-barrel file no longer represents public API (Boy-Scout)

### What We're NOT Doing
- Renaming any symbols (e.g. `k`-prefix drop, `get*`→getter conversion) — that is **S36's** scope; this story keeps every retained name byte-identical
- Authoring `barrel_show_clauses_test.dart` itself or any allowlist file — that is **S10's** scope; S09 only produces the post-narrowing baseline
- Touching `packages/dartclaw_core/`, `packages/dartclaw_models/`, or any other package's barrel — out of scope; those caps are S25's domain
- Introducing new exports — only narrowing/removing; if a new public type is genuinely needed it lands in a different story
- Modifying JSON wire formats (workflow YAML schema, REST envelopes, SSE) — Constraint #1 / #76 forbids; symbol removal is API-only, not protocol-affecting
- Adding new dependencies — Constraint #2

### Agent Decision Authority

- **Autonomous**: For each plan-named candidate, decide remove vs. retain based on `rg`-confirmed downstream usage. If zero downstream consumers exist outside `dartclaw_workflow/lib/src/`, remove. If ≥1 consumer exists in `dartclaw_server`/`dartclaw_cli`/test code, retain with rationale comment.
- **Autonomous**: Choose `show`-clause symbol set per file by inspecting public top-level declarations in each `lib/src/...` file and listing only those a downstream consumer demonstrably uses (verified via `rg`).
- **Autonomous**: If audit reveals that the live downstream surface cannot fit within the soft cap, preserve the live symbols, record the resulting count, and leave any further ratchet work to S25.

## Architecture Decision

**We will**: iteratively add `show` clauses preserving all current symbols first (TI02 — barrel still exports the union of every public top-level), then curate internal-only candidates one-by-one with `dart analyze` after each step (TI03–TI0N).

**Rationale**: minimises blast radius; downstream consumers can be located precisely per candidate; rollback is per-candidate rather than all-or-nothing. A big-bang barrel rewrite would conflate `show`-clause mechanics with curation decisions, making review and bisection harder and inflating the chance of accidentally dropping a symbol that turns out to be live.

**Alternatives considered**:
1. **Big-bang rewrite** (full curation in one commit) — rejected: harder to review; mixes mechanical change with semantic change; bisecting a downstream regression becomes painful.
2. **Force the S25 soft cap inside S09** — rejected: the previous execution proved this creates an impossible conflict between the numeric target and live downstream consumers. S09 locks the explicit-export baseline; S25 owns the count ratchet.

## Technical Overview

### Integration Points

- **Upstream consumers of the barrel**: `packages/dartclaw_server/lib/` (~17 import sites; most already use `show` per `rg` audit) and `apps/dartclaw_cli/lib/` + `apps/dartclaw_cli/test/` (~9 sites). Five `dartclaw_server` files and three `dartclaw_cli` files currently use unscoped imports of the workflow barrel — these need conversion to typed `show` imports as part of TI04 / TI05 fix-up.
- **Asset URIs**: `apps/dartclaw_cli/test/commands/workflow/workflow_materializer_test.dart:14` and `workflow_list_command_test.dart:18` reference `package:dartclaw_workflow/src/workflow/definitions/code-review.yaml` — these are URI strings, not Dart imports, and stay untouched.
- **Downstream of S09**: S10's `barrel_show_clauses_test.dart` (created in S10) consumes the post-S09 baseline as the locked allowlist starting point.

## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_core/lib/dartclaw_core.dart:1-50          | Reference pattern for grouped show-clause exports with section comments
file   | packages/dartclaw_workflow/lib/dartclaw_workflow.dart        | Target file — current state has 4 `show`-clause exports + 34 wholesale; end state is explicit `show`-clause exports plus the two existing `package:` re-exports
file   | packages/dartclaw_workflow/lib/src/workflow/                 | Source of truth for what each candidate file's public top-levels are; inspect to populate `show` clauses
file   | packages/dartclaw_server/lib/src/api/workflow_routes.dart:21 | Example downstream that already uses unscoped import of barrel — convert to typed show
file   | apps/dartclaw_cli/lib/src/commands/service_wiring.dart:9     | Example downstream that already uses unscoped import — convert to typed show
file   | packages/dartclaw_workflow/CLAUDE.md                         | Update "Key files" if removed file is no longer public-API-bearing
```

## Constraints & Gotchas

- **Constraint**: JSON wire formats (workflow YAML schema, REST envelopes, SSE event payloads) MUST NOT change — Binding Constraint #1 / #76. This story is API-shape only; serialization stays byte-identical.
- **Constraint**: No symbol renames — Binding Constraint scope of S36, not S09. If a candidate is `kFoo` or `getFoo()`, retain that name verbatim in the `show` clause if kept; do not pre-empt S36.
- **Constraint**: No new dependencies — Binding Constraint #2.
- **Avoid**: Breaking the `dartclaw` umbrella package — `packages/dartclaw/` re-exports the workflow barrel transitively; verify `umbrella_exports_test.dart` (in `packages/dartclaw/test/`) still passes after each candidate removal.
- **Avoid**: Removing a symbol that's host-injected (e.g. `WorkflowGitPort`, `WorkflowTurnAdapter` are explicitly host-port abstractions per `dartclaw_workflow/CLAUDE.md` § "Architecture > Host ports"). The plan names `workflow_turn_adapter.dart` as a candidate — audit it carefully; if `dartclaw_server` injects it, retain with rationale.
- **Critical**: `dartclaw_workflow/lib/src/skills/skill_provisioner.dart` already uses a `show` clause and is the canonical source of `dcNativeSkillNames` — leave that block as-is unless a symbol is verifiably unused; do not "tidy" working `show` clauses.
- **Gotcha**: `merge_resolve_attempt_artifact.dart` is positioned between `workflow_definition_validator.dart` and `workflow_executor.dart` in the barrel for narrative grouping; preserve grouping when adding `show` clauses.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Audit produces a per-file inventory: every `lib/src/...` currently wholesale-exported has its public top-level declarations enumerated, paired with a downstream-consumers check (`rg`-grepped against `packages/dartclaw_server`, `apps/dartclaw_cli`, `packages/dartclaw_*` test trees). Output: an in-spec working note (held in the agent's scratch context, not committed) that classifies each declaration as `keep` / `internal-only-remove` / `retain-with-rationale` and records the resulting count.
  - Use `rg "^(class|abstract class|enum|mixin|extension|typedef|sealed class|final class|interface class|const|final|void|Future)\s+[A-Z_]" packages/dartclaw_workflow/lib/src/workflow/<file>.dart` per file; cross-reference with `rg "<Symbol>" packages/dartclaw_server/lib apps/dartclaw_cli` for usage.
  - **Verify**: Working note enumerates classification for every line currently in the barrel; every plan-named likely-internal candidate has a remove-or-retain decision with one-line evidence (downstream consumer file:line, or "no downstream consumer found"); the resulting count is recorded for S25.

- [ ] **TI02** Mechanical pass: every `export 'src/...'` in `packages/dartclaw_workflow/lib/dartclaw_workflow.dart` carries a `show` clause that preserves the full set of currently-public top-level declarations from that file (no symbols dropped yet). The two `package:dartclaw_core` and `package:dartclaw_models` re-exports stay unchanged.
  - Pattern reference: `packages/dartclaw_core/lib/dartclaw_core.dart:24-50` for multi-line `show` formatting; group per file alphabetically inside each clause; one symbol per line when ≥3 symbols.
  - **Verify**: `rg "^export 'src/" packages/dartclaw_workflow/lib/dartclaw_workflow.dart | rg -v ' show '` returns zero lines; `dart analyze` workspace-wide is clean; `dart test` workspace-wide passes (the `show`-list union equals the prior wholesale set, so behaviour is unchanged).

- [ ] **TI03** Per-candidate curation pass: for each plan-named likely-internal candidate that TI01 classified `internal-only-remove`, delete the corresponding `export` line (or trim the `show` clause). After each removal, run `dart analyze` workspace-wide; fix any downstream breakage (typically by switching the consumer to a different package's typed import, or — if the consumer was inside `dartclaw_workflow/lib/src/` — confirming no fix is needed).
  - Removal candidates per plan: `workflow_definition_source.dart`, `workflow_turn_adapter.dart`, `workflow_template_engine.dart`, `skill_registry_impl.dart`, `shell_escape.dart`, `map_step_context.dart`, `json_extraction.dart`, `dependency_graph.dart`, `duration_parser.dart` (already in `dartclaw_config` per plan), `step_config_resolver.dart`. **Important caveat**: per Decision Authority above, retain any candidate with confirmed downstream consumers, marked with a one-line rationale comment on the `show` line. `WorkflowTurnAdapter` and `WorkflowDefinitionSource` are host-port-shaped — likely retained.
  - **Verify**: After each candidate decision, `dart analyze` workspace-wide is clean; for each removed candidate, `rg "<RemovedSymbol>" packages/dartclaw_server apps/dartclaw_cli packages/dartclaw_testing` returns zero hits (or only hits inside `dartclaw_workflow/lib/src/`).

- [ ] **TI04** Downstream import fix-up in `dartclaw_server`: every `import 'package:dartclaw_workflow/dartclaw_workflow.dart'` (without `show` clause) in `packages/dartclaw_server/lib/` is converted to a typed `show` import listing only the symbols actually used in that file. Files affected per pre-audit: `web/pages/workflows_page.dart`, `task/merge_executor.dart`, `task/workflow_git_port_process.dart`, `api/workflow_routes.dart`, `templates/workflow_detail.dart`.
  - Use `dart analyze` errors after TI03 removals to identify any "Undefined name" leaks; fix at the import site.
  - **Verify**: `rg "package:dartclaw_workflow/dartclaw_workflow.dart'$" packages/dartclaw_server/lib/` returns zero (every import has a `show` clause); `dart analyze packages/dartclaw_server` is clean; `dart test packages/dartclaw_server` passes.

- [ ] **TI05** Downstream import fix-up in `dartclaw_cli`: every unscoped import of the workflow barrel in `apps/dartclaw_cli/lib/` and `apps/dartclaw_cli/test/` is converted to a typed `show` import. Files affected per pre-audit: `lib/src/commands/service_wiring.dart`, `lib/src/commands/workflow/workflow_git_support.dart`, `lib/src/commands/workflow/workflow_show_command.dart`, `lib/src/commands/workflow/workflow_list_command.dart`, plus a small number of test files.
  - Asset URIs (`package:dartclaw_workflow/src/workflow/definitions/*.yaml`) are URI strings, not imports — leave untouched.
  - **Verify**: `rg "package:dartclaw_workflow/dartclaw_workflow.dart'$" apps/dartclaw_cli/` returns zero matches; `dart analyze apps/dartclaw_cli` clean; `dart test apps/dartclaw_cli` passes.

- [ ] **TI06** Final self-check: distinct symbol count across all `show` clauses in `dartclaw_workflow.dart` (excluding the two `package:` re-exports) is recorded; `umbrella_exports_test.dart` in `packages/dartclaw/test/` still passes.
  - Count via: read each `show` clause and collect unique identifiers. Treat the count as S25 baseline data, not an S09 failure condition.
  - **Verify**: `dart test packages/dartclaw` passes (umbrella contract); a manual count of `show`-clause identifiers from `packages/dartclaw_workflow/lib/dartclaw_workflow.dart` is recorded in Implementation Observations.

- [ ] **TI07** CHANGELOG entry under `## 0.16.5 - Unreleased` (or the project's current placeholder) names the narrowing and enumerates removed symbols. Boy-Scout: update `packages/dartclaw_workflow/CLAUDE.md` § "Key files" only if a file removed from the barrel was previously implied as public-API-bearing there.
  - Do not add other unrelated CHANGELOG content.
  - **Verify**: `rg "barrel" CHANGELOG.md` reveals a 0.16.5 entry naming the change and enumerating removed symbols; `git diff packages/dartclaw_workflow/CLAUDE.md` is either empty or limited to a single "Key files" line drop.

- [ ] **TI08** Workspace validation: `dart format --set-exit-if-changed packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test` all pass.
  - **Verify**: All three commands exit 0; no test reports skipped beyond the project's standard `integration` tag default.

### Testing Strategy

- [TI02] Scenario "Barrel exports go from 34 wholesale → explicit `show` clauses" → Add `show` clauses preserving all symbols; assert via `rg` count + workspace test pass
- [TI03] Scenario "Removed internal-only candidate is no longer reachable" → After candidate removal, `dart analyze` would flag any external `show: <RemovedSymbol>` import; absence of such errors confirms no consumer remained
- [TI03,TI06] Scenario "Retained borderline candidate carries rationale" → Manual review of the resulting barrel: every retained candidate from the plan list has a rationale comment or section rationale
- [TI04,TI05] Scenario "Downstream import in `dartclaw_server` survives the cut" → `dart analyze` + `dart test` workspace-wide pass after import fix-up
- [Sprint-level, S10] Scenario "Future wholesale `export 'src/...'` PR fails the S10 fitness test" → S10 produces the test; S09 just ensures the baseline it locks in is post-narrowing. Cross-story; this scenario proves out at S10 close.

### Validation

- Standard exec-spec validation gates apply (build/test/analyze + 1-pass remediation).
- Feature-specific: count distinct `show`-clause identifiers and record the result for S25 (manual or grep-based; not a test file — that's S10's domain).

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding.
- Prescriptive details (file paths and plan-named candidates) are exact; the numeric cap is baseline data for S25, not an S09 hard gate.
- Symbol names are byte-identical — any rename request defers to S36.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] All Success Criteria met
- [ ] All TI01–TI08 tasks fully completed, verified, and checkboxes checked
- [ ] No regressions: `dart test` workspace-wide passes; `dart analyze` clean
- [ ] CHANGELOG entry present and enumerates removed symbols
- [ ] `packages/dartclaw_workflow/CLAUDE.md` Boy-Scout updated only if a removed file was implied as public-API-bearing

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: Add `show` clauses to every `export 'src/...'` in `packages/dartclaw_workflow/lib/dartclaw_workflow.dart`. Remove candidates that are likely internal-only (e.g. `workflow_definition_source.dart`, `workflow_turn_adapter.dart`, `workflow_template_engine.dart`, `skill_registry_impl.dart`, `shell_escape.dart`, `map_step_context.dart`, `json_extraction.dart`, `dependency_graph.dart`, `duration_parser.dart` — already in `dartclaw_config`, `step_config_resolver.dart`) only when audit proves no live downstream consumer. Fix downstream imports in `dartclaw_server` and `dartclaw_cli` that previously relied on the wholesale exports.

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [ ] Every `export 'src/...'` in `dartclaw_workflow/lib/dartclaw_workflow.dart` uses a `show` clause (must-be-TRUE)
- [ ] Barrel exposes explicit `show` clauses without dropping live downstream API (must-be-TRUE)
- [ ] `dart analyze` workspace-wide is clean after downstream import fixes (must-be-TRUE)
- [ ] `dart test` workspace-wide passes
