# S37 — Dartdoc Sweep + `public_member_api_docs` Lint Flip + Internal Dartdoc Trim

**Plan**: ../plan.md
**Story-ID**: S37

## Feature Overview and Goal

Three-part dartdoc governance rail. **Part A**: sweep undocumented public top-level types in `packages/dartclaw_server/lib/` (cluster begins at `advisor_subscriber.dart` lines 14/39/61/69/91 — five of the 26 known offenders). **Part B**: enable `public_member_api_docs` in four near-clean packages (`dartclaw_models`, `dartclaw_storage`, `dartclaw_security`, `dartclaw_config`) so new undocumented public surface fails CI from day one. **Part C** (slip candidate): apply the existing `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` § Proportionality & Anti-Rot rules to `lib/src/` of those four packages plus `dartclaw_workflow` — strip planning-history references, cleanup-leftover markers, unowned `// TODO`s, and consumer-coupled docstrings; trim verbose internal class/method dartdoc. Zero behaviour change; lint flip is the durable enforcement; manual trim is Boy-Scout-style.

> **Technical Research**: [.technical-research.md](../.technical-research.md) — see `## S37 — Dartdoc Sweep + public_member_api_docs Lint Flip + Internal Dartdoc Trim` and `### Conventions That Affect FIS → Comment policy (drives S37)`.

## Required Context

### From `dev/specs/0.16.5/plan.md` — "S37 Acceptance Criteria"
<!-- source: dev/specs/0.16.5/plan.md#p-s37-dartdoc-sweep-public_member_api_docs-lint-flip-internal-dartdoc-trim -->
<!-- extracted: 2026-05-04 -->
> - Zero undocumented public top-level types in `dartclaw_server/lib/` (grep-verified) (must-be-TRUE)
> - `public_member_api_docs` enabled in `dartclaw_models`, `dartclaw_storage`, `dartclaw_security`, `dartclaw_config` `analysis_options.yaml` (must-be-TRUE)
> - `dart analyze` clean in all 4 packages after the sweep (must-be-TRUE)
> - Adding a new undocumented public class to any of the 4 near-clean packages fails `dart analyze` locally
> - Each dartdoc summary is one sentence, third-person, starts with a verb (spot-check)
> - Where a type is referenced by name in prose, it uses the `[TypeName]` bracket syntax (spot-check)
> - `docs/guidelines/DART-EFFECTIVE-GUIDELINES.md` `### Proportionality & Anti-Rot` subsection covers each of: planning-history, control-flow restatement, identifier paraphrasing, multi-paragraph collapse, drift discipline, consumer-coupling, cleanup-leftover markers, unowned TODOs (must-be-TRUE)
> - `rg "(S\d+ integration|S\d+ flow|for the .* flow|used by the .* flow)" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns zero planning-history references in `///` comments (must-be-TRUE)
> - `rg "//\s*(REMOVED|was:|previously:)" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns zero cleanup-leftover markers (must-be-TRUE)
> - `rg --pcre2 "(?<!/)//\s*TODO\b(?!\s*\([^)]+\))" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns zero unowned `// TODO`s (must-be-TRUE)
> - Consumer-coupled dartdoc paragraphs removed from `lib/src/` of the 5 targeted packages (spot-check)
> - `skill_prompt_builder.dart` class-level dartdoc ≤ 8 lines; method dartdoc for `build()` ≤ 10 lines (spot-check — illustrative target, not a blanket LOC rule)
> - No new planning-history references introduced

### From `dev/specs/0.16.5/prd.md` — "FR6 Dartdoc Governance" (Binding Constraint #39)
<!-- source: dev/specs/0.16.5/prd.md#fr6-fitness-functions--dartdoc-governance -->
<!-- extracted: 2026-05-04 -->
> `public_member_api_docs` enabled in `dartclaw_models`, `dartclaw_storage`, `dartclaw_security`, `dartclaw_config` `analysis_options.yaml`; zero undocumented public top-levels in `dartclaw_server/lib/`.

### From `dev/specs/0.16.5/prd.md` — "Constraints" (Binding Constraint #2)
<!-- source: dev/specs/0.16.5/prd.md#constraints -->
<!-- extracted: 2026-05-04 -->
> No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`.

### From `dev/specs/0.16.5/prd.md` — "FR6 Acceptance" (Binding Constraint #40)
<!-- source: dev/specs/0.16.5/prd.md#fr6-fitness-functions--dartdoc-governance -->
<!-- extracted: 2026-05-04 -->
> Tests + dartdoc lint documented in `TESTING-STRATEGY.md`.

### From `dev/specs/0.16.5/.technical-research.md` — "Comment policy (drives S37)"
<!-- source: dev/specs/0.16.5/.technical-research.md#comment-policy-drives-s37 -->
<!-- extracted: 2026-05-04 -->
> **Anti-rot rules (FIS S37 enforces these via `public_member_api_docs` lint flip + manual sweep):**
> - **Drift > absence** — fix or delete wrong/outdated comments on sight.
> - **No planning-history references in `///`** — story IDs (`S01`), PR numbers (`#123`), sprint labels, "added for X flow", "used by Y". Durable refs (ADR links, `// TODO(#123): …` with issue link) OK.
> - **No control-flow restatement** — don't enumerate the `switch`/`if` cases the dartdoc would mirror.
> - **No identifier paraphrasing** — `/// The harness factory` on `harnessFactory` is noise.
> - **Collapse multi-paragraph internal class docs.**
> - **No consumer-coupling at definition site** — "X is rewrapped by `ServiceWiring.wire()`" / "called from Y flow" rots.
> - **No cleanup-leftover markers** — `// REMOVED …`, `// was: …`, `// previously: …`. Delete the code, then delete the marker.
> - **Every `// TODO` needs owner or tracking link** — `// TODO(name): …` or `// TODO(#123): …`. Bare `// TODO: fix later` is forbidden.

## Deeper Context

- `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md#proportionality--anti-rot` — already contains the eight named patterns; spot-check task confirms coverage rather than authoring.
- `dev/specs/0.16.5/.technical-research.md#s37--dartdoc-sweep--public_member_api_docs-lint-flip--internal-dartdoc-trim` — primary file map (Parts A/B/C).
- `packages/dartclaw_workflow/lib/src/workflow/skill_prompt_builder.dart` — illustrative Part C offender: ~30-line class-level dartdoc that restates the `switch` cases, plus "(S01 integration)" planning leak at the trailing line of the class doc.
- `packages/dartclaw_workflow/CLAUDE.md` — read before touching that package's `lib/src/` for Part C.

## Success Criteria (Must Be TRUE)

> Each criterion has a proof path: a Verify line on a task (structural) or a Scenario (behavioural).

**Part A — server sweep:**
- [ ] Zero undocumented public top-level types in `packages/dartclaw_server/lib/` — grep-verified across all `.dart` files (proven by TI01)
- [ ] Each new dartdoc summary is one sentence, third-person, starts with a verb (proven by TI01 spot-check sample)
- [ ] Where a type is referenced by name in prose, the `[TypeName]` bracket syntax is used (proven by TI01 spot-check sample)

**Part B — lint flip in 4 near-clean packages:**
- [ ] `public_member_api_docs` enabled in `analysis_options.yaml` of `dartclaw_models`, `dartclaw_storage`, `dartclaw_security`, `dartclaw_config` (proven by TI02–TI05)
- [ ] `dart analyze` is clean in all 4 packages with the lint enabled (proven by TI02–TI05 Verify lines + TI06 aggregate)
- [ ] Adding a new undocumented public class fails `dart analyze` locally (proven by Scenario "contributor adds undocumented public class")

**Part C — internal trim (slip candidate):**
- [ ] `rg "(S\d+ integration|S\d+ flow|for the .* flow|used by the .* flow)" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns zero matches (proven by TI07 Verify)
- [ ] `rg "//\s*(REMOVED|was:|previously:)" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns zero matches (proven by TI07 Verify)
- [ ] `rg --pcre2 "(?<!/)//\s*TODO\b(?!\s*\([^)]+\))" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns zero matches (proven by TI07 Verify)
- [ ] Consumer-coupled dartdoc paragraphs (e.g. _"is rewrapped by `ServiceWiring.wire()`"_) removed from `lib/src/` of the five targeted packages (proven by TI08 spot-check)
- [ ] `skill_prompt_builder.dart` class-level dartdoc ≤ 8 lines; method dartdoc for `build()` ≤ 10 lines (proven by TI09 Verify)

**Governance & docs:**
- [ ] `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` § Proportionality & Anti-Rot covers all eight named patterns: drift discipline, planning-history, control-flow restatement, identifier paraphrasing, multi-paragraph collapse, consumer-coupling, cleanup-leftover markers, unowned TODOs (proven by TI10 Verify)
- [ ] `dev/guidelines/TESTING-STRATEGY.md` references the dartdoc lint flip per binding constraint #40 (proven by TI11 Verify)
- [ ] No new planning-history references introduced by this work — governance via existing `andthen:quick-review` PR feedback flow; no new lint added (proven by TI07 Verify on the broader regex set)

### Health Metrics (Must NOT Regress)
- [ ] Workspace-wide `dart analyze --fatal-warnings --fatal-infos` remains clean
- [ ] Workspace-wide `dart test` remains green (zero behaviour change)
- [ ] `dart format --set-exit-if-changed` clean
- [ ] No new pubspec dependencies introduced (binding constraint #2)

## Scenarios

### Contributor adds undocumented public class to a lint-flipped package
- **Given** Part B has shipped (`public_member_api_docs: true` in `dartclaw_models/analysis_options.yaml`)
- **When** a contributor adds `class NewThing { ... }` (public, no dartdoc) under `packages/dartclaw_models/lib/`
- **Then** `dart analyze packages/dartclaw_models` reports an `info`/`warning` on the new declaration referencing `public_member_api_docs`, and (with `--fatal-infos`) the analyzer exits non-zero — the contributor cannot land the change without either documenting the class or scoping it to `lib/src/` and removing it from the barrel.

### `dartclaw_server` remains intentionally lint-off
- **Given** `dartclaw_server` has 26 undocumented public types pre-sweep, surface too large to keep clean in one sprint
- **When** Part A reaches zero undocumented public top-level types in `dartclaw_server/lib/`
- **Then** the package's `analysis_options.yaml` does **not** enable `public_member_api_docs` — the lint flip is deferred to a follow-up milestone (FR6 binding text names only the four near-clean packages) — and the sweep result is preserved by Part C's `andthen:quick-review` governance, not by a lint rail in this milestone.

### `dartclaw_core`/`dartclaw_workflow` deferred lint flip is honoured
- **Given** plan §S37 explicitly defers `dartclaw_core` (3 missing) to 0.17 and treats `dartclaw_workflow` (3 missing) as conditional ("flip if time allows; otherwise defer")
- **When** Part B completes
- **Then** neither package has `public_member_api_docs` enabled in this FIS — defending against scope creep that would pull in untouched packages.

### Internal dartdoc trim is opportunistic, not exhaustive
- **Given** Part C is the slip candidate within S37 — Part A + Part B are the non-negotiable rails
- **When** Parts A + B consume the wave-3 budget before Part C completes
- **Then** an `OBSERVATION:` is recorded in this FIS's "Implementation Observations" section explaining the slip, Part C deliverables (TI07–TI09) are checked off only for what shipped, the remaining work is captured as a 0.16.6 cleanup story (per plan §S37 wording), and Parts A + B alone still satisfy the governance contract for FR6 binding constraint #39.

### Spot-check finds offending comment patterns and removes them
- **Given** `lib/src/` of the five targeted packages contains planning-history leaks (story IDs in `///`), cleanup-leftover markers (`// REMOVED`, `// was:`), and unowned `// TODO`s
- **When** TI07 runs the three `rg` commands against those paths
- **Then** all three return zero matches — every offender that existed pre-Part C was either fixed (durable rationale linked to an ADR or `// TODO(#issue): …`) or deleted; no offender was masked by changing the regex.

### Sweep does not break dartdoc generation
- **Given** all Part A/Part C edits have landed
- **When** a maintainer runs `dart doc packages/dartclaw_models packages/dartclaw_storage packages/dartclaw_security packages/dartclaw_config` (and `dartclaw_server` for Part A)
- **Then** dartdoc completes without errors caused by malformed `[TypeName]` references or unbalanced fences introduced by the sweep.

## Scope & Boundaries

### In Scope
_Every In Scope item is exercised by a scenario or a task Verify line._

- **Part A**: add one-sentence dartdoc summaries to every undocumented public top-level type in `packages/dartclaw_server/lib/` (declaration sites — `class`, `enum`, `mixin`, `typedef`, `extension`, top-level functions/getters/constants).
- **Part B**: enable `public_member_api_docs` in the four named packages and resolve residual gaps (≤6 total: 0 in `dartclaw_models`, 0 in `dartclaw_storage`, 1 in `dartclaw_security`, 5 in `dartclaw_config`); aggregate analyze must be clean.
- **Part C** (slip candidate): apply the eight Anti-Rot rules to `lib/src/` of the four Part B packages plus `dartclaw_workflow` — strip planning-history references, cleanup-leftover markers, unowned `// TODO`s, consumer-coupled dartdoc paragraphs; trim multi-paragraph internal class dartdoc (illustrative target: `skill_prompt_builder.dart`).
- **Governance pointer**: confirm `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` § Proportionality & Anti-Rot already covers all eight patterns (it does — TI10 is verification, not authoring); add a one-line dartdoc-lint reference to `dev/guidelines/TESTING-STRATEGY.md` per binding constraint #40.

### What We're NOT Doing
- **Flip lint in `dartclaw_server`** — 26 undocumented types pre-sweep is too much surface to also lint-gate in one sprint; Part A reaches zero and the lint flip is deferred. _Reason: keeps scope to the FR6 binding text._
- **Flip lint in `dartclaw_core`** — 3 missing dartdocs but a much larger public surface that warrants a targeted sweep first; explicitly deferred to 0.17 by plan §S37. _Reason: avoid pulling in unscoped sweep work._
- **Flip lint in `dartclaw_workflow`** — 3 missing dartdocs; plan §S37 marks this as conditional ("flip if time allows; otherwise defer"). Default position for this FIS is **defer** (no flip); promotion would require an explicit scope-expansion call. _Reason: keep the FIS deterministic; promotion belongs in a follow-up if budget remains._
- **Rewrite class internals** — Part C is dartdoc/comment-only; bodies, signatures, and behaviour are untouched. _Reason: zero behaviour change; bug-fix-forward belongs in adjacent stories._
- **Add new public API or remove existing public types** — purely documentation hygiene. _Reason: scope discipline._
- **CLI app `apps/dartclaw_cli`** — application code, not SDK surface; explicitly excluded by plan §S37. _Reason: SDK-surface focus._

### Agent Decision Authority
- **Autonomous**: dartdoc summary wording (one sentence, third-person, verb-first), `[TypeName]` cross-ref placement, removal of clearly-offending comment patterns matched by the binding regexes, conversion of bare `// TODO` into `// TODO(#issue)` where an existing tracker is obvious from git blame, deletion of cleanup-leftover markers, ordering between Part A and Part B (Part B can run in parallel since the four packages already have ≤5 missing).
- **Escalate**: any case where removing a planning-history reference would break a load-bearing cross-link (rare — record as `OBSERVATION:` and surface the link to ADRs); any case where a public type's dartdoc would need >1 sentence to be honest (escalate as `CONFUSION:` so the team can decide between expanding the dartdoc vs. extracting a separate explanatory ADR); decision on whether to opportunistically promote `dartclaw_workflow` to a lint flip if Part C completes early (default: defer).

## Architecture Decision

**We will**: ship Part A (sweep `dartclaw_server` undocumented public types) + Part B (flip `public_member_api_docs` in `dartclaw_models`/`_storage`/`_security`/`_config`) as the non-negotiable governance rail; Part C (internal trim) is opportunistic Boy-Scout cleanup that defers to 0.16.6 if W3 budget tightens — over (a) flipping `dartclaw_server` lint now (rejected: 26-type surface is too large to keep clean alongside the sweep, and the FR6 binding constraint names only the four near-clean packages), (b) flipping `dartclaw_core` (rejected: 3 missing dartdocs but a larger public surface that warrants targeted-sweep work first; deferred to 0.17 per plan §S37), (c) bundling Part C as required scope (rejected: it is mechanical Boy-Scout work whose absence does not weaken the FR6 lint rail; the rail is the durable enforcement, the manual trim is one-time hygiene).

The lint flip itself is the architecturally load-bearing choice: durable enforcement at PR time is what keeps these four packages clean across all future stories. Manual sweeps are one-time costs that the lint rail prevents from recurring.

## Technical Overview

### Integration Points

- **`analysis_options.yaml` per package** — Part B creates four small files (each contains `include: package:lints/recommended.yaml` to inherit the existing workspace strict-casts/strict-raw-types config + the workspace lint set, then a `linter.rules:` block that adds `public_member_api_docs`). Pattern is standard Dart per-package override; no inheritance gotchas because the workspace root file is `include:`-pulled.
- **`dart analyze`** — invoked per package (`dart analyze packages/<name>`) for the per-package Verify lines, and once workspace-wide for the Health Metric.
- **`dev/guidelines/DART-EFFECTIVE-GUIDELINES.md`** — TI10 verifies the existing § Proportionality & Anti-Rot subsection covers all eight named patterns (it does; this is a regression check, not authoring).
- **`dev/guidelines/TESTING-STRATEGY.md`** — TI11 adds a brief reference to the dartdoc lint flip alongside the existing fitness-test documentation, satisfying binding constraint #40.

### Data Models
N/A — docs/lint configuration only.

## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_server/lib/src/advisor/advisor_subscriber.dart:14,39,61,69,91   | Five of the 26 undocumented public top-level types in Part A scope (AdvisorTriggerType, AdvisorStatus, AdvisorOutput, AdvisorTriggerContext, ContextEntry); plan §S37 cited line numbers (648/673/695/703/725) reflect a pre-refactor snapshot — actual current declarations live at the lines listed here, sweep targets the declarations not the line numbers
file   | packages/dartclaw_workflow/lib/src/workflow/skill_prompt_builder.dart:6-37        | Illustrative Part C offender — ~30-line class-level dartdoc that restates the switch cases plus a trailing "(S01 integration)" planning leak; trim target ≤8 lines class doc + ≤10 lines build() method doc
file   | dev/guidelines/DART-EFFECTIVE-GUIDELINES.md:63-89                                 | Proportionality & Anti-Rot subsection — read for the eight pattern definitions; TI10 verifies coverage
file   | analysis_options.yaml                                                             | Workspace-root analyzer config — per-package files inherit from this via include:; pattern to follow when creating four new analysis_options.yaml files
file   | packages/dartclaw_workflow/CLAUDE.md                                              | Read before any Part C edits to dartclaw_workflow/lib/src/ (per workspace package-scoped AGENTS.md discipline)
```

## Constraints & Gotchas

- **Constraint**: no new dependencies (PRD binding constraint #2). All sweep + lint work uses the existing analyzer; the dartdoc-tooling check via `dart doc` is part of the SDK and needs no new pubspec entries.
- **Constraint**: `apps/dartclaw_cli` is explicitly out of scope for Part A — application code, not SDK surface (plan §S37).
- **Avoid**: rewriting public-API contracts during the sweep. A one-sentence dartdoc that hides a behavioural change is worse than no dartdoc — Instead: if a one-sentence summary cannot honestly capture a type, escalate as `CONFUSION:` rather than expanding scope.
- **Avoid**: bulk-deleting `// TODO` comments via regex without inspecting each — Instead: convert to `// TODO(#issue)` form when an existing tracker is obvious; delete only when the work is genuinely done; otherwise escalate. Bare regex-driven mass deletion would silently lose tracking signals.
- **Avoid**: "fixing" the cited plan line numbers (`advisor_subscriber.dart:648,673,695,703,725`) inside the plan — those refer to a pre-refactor snapshot. The sweep targets the declarations themselves; the actual line numbers (14/39/61/69/91 in the current file) shift between commits and are not load-bearing.
- **Critical**: per-package `analysis_options.yaml` files must `include: package:lints/recommended.yaml` (or the workspace root file via relative path) so the existing strict-casts/strict-raw-types/`prefer_single_quotes`/etc. rules continue to apply — Must handle by: copying the workspace `analysis_options.yaml` shape and adding only the `public_member_api_docs` rule on top, not replacing the rule set.
- **Critical**: dartdoc summaries must use `[TypeName]` bracket syntax for cross-references (Effective Dart) — Must handle by: spot-check during TI01 sweep (sample 5 of the 26 entries); the analyzer warns on broken references when the surrounding type is in scope.
- **Gotcha**: Part C regex `rg --pcre2 "(?<!/)//\s*TODO\b(?!\s*\([^)]+\))"` uses PCRE2 lookbehind to exclude `///` dartdoc — verify your `rg` build supports `--pcre2` (the project's macOS Homebrew `rg` does); without PCRE2, fall back to the two-pass `rg ' // TODO' | rg -v ' // TODO('` form.

## Implementation Plan

> **Vertical slice ordering**: TI01 (Part A) and TI02–TI06 (Part B) are independent — Part B's four packages also run in parallel since each has ≤5 residual gaps. Part C (TI07–TI09) is the slip candidate; final-step TI10–TI11 verify the durable governance docs.

### Implementation Tasks

- [ ] **TI01 (Part A)** Zero undocumented public top-level types in `packages/dartclaw_server/lib/`.
  - Sweep all `.dart` files; add one-sentence dartdoc (third-person, starts with verb, `[TypeName]` for prose refs) to each public top-level `class`/`enum`/`mixin`/`typedef`/`extension`/top-level function/getter/constant. Anchor cluster: `packages/dartclaw_server/lib/src/advisor/advisor_subscriber.dart` lines 14/39/61/69/91 (`AdvisorTriggerType`, `AdvisorStatus`, `AdvisorOutput`, `AdvisorTriggerContext`, `ContextEntry`).
  - **Verify**: `rg -n '^(class|enum|mixin|sealed class|abstract class|extension)\s' packages/dartclaw_server/lib/ -t dart -g '!*.g.dart'` then for each match, confirm the immediately preceding line is `///` dartdoc (script: `dart run dev/tools/check_public_dartdoc.dart packages/dartclaw_server/lib/` if present, else manual `rg -B1` audit). Final scalar: zero declarations without a preceding `///` line. Spot-check 5 random summaries — each is one sentence, third-person, starts with a verb; types referenced in prose use `[TypeName]`.

- [ ] **TI02 (Part B)** `public_member_api_docs` enabled in `dartclaw_models`; package analyzes clean.
  - Pre-state per `.technical-research.md` line 588: 0 missing dartdocs. Create `packages/dartclaw_models/analysis_options.yaml` that inherits the workspace root rules and enables `public_member_api_docs`.
  - **Verify**: `test -f packages/dartclaw_models/analysis_options.yaml`; file contains both `include: package:lints/recommended.yaml` (or relative include of workspace root) and a `linter.rules:` block listing `public_member_api_docs`. `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_models` exits 0.

- [ ] **TI03 (Part B)** `public_member_api_docs` enabled in `dartclaw_storage`; package analyzes clean.
  - Pre-state: 0 missing dartdocs. Same shape as TI02.
  - **Verify**: `test -f packages/dartclaw_storage/analysis_options.yaml` with the same two ingredients; `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_storage` exits 0.

- [ ] **TI04 (Part B)** `public_member_api_docs` enabled in `dartclaw_security`; package analyzes clean (one residual fixed).
  - Pre-state: 1 missing dartdoc. Create `packages/dartclaw_security/analysis_options.yaml`; locate the missing dartdoc via a transient `dart analyze` run and add a one-sentence summary.
  - **Verify**: `test -f packages/dartclaw_security/analysis_options.yaml`; `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_security` exits 0; the residual fix is on a public top-level declaration (spot-check via `git diff packages/dartclaw_security/lib/`).

- [ ] **TI05 (Part B)** `public_member_api_docs` enabled in `dartclaw_config`; package analyzes clean (≤5 residuals fixed).
  - Pre-state: 5 missing dartdocs. Same shape as TI04 with up to five residual fixes.
  - **Verify**: `test -f packages/dartclaw_config/analysis_options.yaml`; `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_config` exits 0.

- [ ] **TI06 (Part B aggregate)** All four near-clean packages clean under `--fatal-infos`; new undocumented public class would fail locally.
  - Aggregate the four per-package analyses; manually validate the negative case by adding a transient public class without dartdoc to one package (e.g. `dartclaw_models`), confirming `dart analyze --fatal-infos` exits non-zero with a `public_member_api_docs` reference, then reverting.
  - **Verify**: `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_models packages/dartclaw_storage packages/dartclaw_security packages/dartclaw_config` exits 0. Negative case: add `class _SmokeProbe {}` (made public for the test) to a `lib/` file → `dart analyze` reports `public_member_api_docs`; revert the probe; analyze re-clean.

- [ ] **TI07 (Part C — slip candidate)** Three binding `rg` commands return zero matches across `lib/src/` of the five targeted packages.
  - Strip planning-history references (`S\d+ integration`, `S\d+ flow`, "for the X flow", "used by the Y flow"), cleanup-leftover markers (`// REMOVED`, `// was:`, `// previously:`), and unowned `// TODO`s. Convert `// TODO` cases that have an obvious owner/issue into `// TODO(name): …` or `// TODO(#issue): …`; delete tombstones outright; rewrite consumer-coupled dartdoc paragraphs to describe the contract this method offers (not what callers do with it).
  - **Verify**: `rg "(S\d+ integration|S\d+ flow|for the .* flow|used by the .* flow)" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` → zero matches. `rg "//\s*(REMOVED|was:|previously:)" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` → zero. `rg --pcre2 "(?<!/)//\s*TODO\b(?!\s*\([^)]+\))" packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` → zero.

- [ ] **TI08 (Part C — slip candidate)** Consumer-coupled dartdoc paragraphs removed from `lib/src/` of the five targeted packages (spot-check).
  - Search for definition-site dartdoc that documents a caller's behaviour — `rg "is rewrapped by|called from|wired by|consumed by|used by " packages/{dartclaw_models,dartclaw_storage,dartclaw_security,dartclaw_config,dartclaw_workflow}/lib/src/ -t dart` returns a small audit set; rewrite each hit to describe the contract the method offers, or delete the paragraph if it is purely consumer-coupled.
  - **Verify**: spot-check ≥3 hits before/after — each is reframed as a contract statement (or deleted). Final `rg "is rewrapped by|wired by|consumed by " packages/{...}/lib/src/ -t dart` returns zero matches; the broader phrases ("called from", "used by") may remain only when followed by a durable rationale (ADR link).

- [ ] **TI09 (Part C — slip candidate)** `skill_prompt_builder.dart` class-level dartdoc ≤8 lines; `build()` method dartdoc ≤10 lines.
  - Trim the ~30-line class doc at `packages/dartclaw_workflow/lib/src/workflow/skill_prompt_builder.dart:6-37` to one sentence + the genuinely non-obvious WHY; collapse the multi-case enumeration into named anchors (`// Case 1:` / `// Case 2:` / …) inside the method body the dartdoc can reference by label; remove the trailing "(S01 integration)" planning leak; keep `[HarnessFactory]` / `[PromptAugmenter]` / `[build]` cross-refs.
  - **Verify**: opening `///` block on the class declaration (the contiguous run starting at line 5–6) spans ≤8 lines including the one-sentence summary; `build()` method dartdoc spans ≤10 lines; behaviour unchanged (`dart analyze` clean; `dart test packages/dartclaw_workflow` green); no `S\d+` substring remains in the file's `///` comments (`rg -n "S\d+" packages/dartclaw_workflow/lib/src/workflow/skill_prompt_builder.dart` returns zero matches inside `///` lines).

- [ ] **TI10** `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` § Proportionality & Anti-Rot covers all eight named patterns.
  - This is verification, not authoring — the subsection (lines 63–89) already lists drift discipline, planning-history, control-flow restatement, identifier paraphrasing, multi-paragraph collapse, consumer-coupling, cleanup-leftover markers, unowned TODOs. If any pattern is missing, add a one-sentence bullet matching the existing voice; do not restructure the section.
  - **Verify**: against `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` § Proportionality & Anti-Rot, `rg -n "Drift|planning history|control flow|identifier|multi-paragraph|consumer|cleanup-leftover|TODO"` returns ≥8 distinct anchor matches inside the subsection; manual read confirms all eight patterns are named with the verbatim wording from `.technical-research.md` Comment policy.

- [ ] **TI11** `dev/guidelines/TESTING-STRATEGY.md` references the dartdoc lint flip per binding constraint #40.
  - Add a single sentence to the existing fitness-test or analyzer-checks subsection naming the four lint-flipped packages and the rail's purpose ("`public_member_api_docs` enabled in `dartclaw_models`, `_storage`, `_security`, `_config` — new undocumented public surface in those packages fails CI"). One sentence, no expansion.
  - **Verify**: `rg -n "public_member_api_docs" dev/guidelines/TESTING-STRATEGY.md` returns ≥1 match; the surrounding sentence names all four packages.

### Testing Strategy
- [TI01] Scenario "Sweep does not break dartdoc generation" → `dart doc packages/dartclaw_server` completes without errors caused by malformed `[TypeName]` references introduced by the sweep.
- [TI02–TI06] Scenario "Contributor adds undocumented public class to a lint-flipped package" → smoke-probe demonstration in TI06 negative case proves the lint fires.
- [TI06] Scenario "`dartclaw_server` remains intentionally lint-off" → confirmed by absence of `public_member_api_docs` in `packages/dartclaw_server/analysis_options.yaml` (no such file is created).
- [TI06] Scenario "`dartclaw_core`/`dartclaw_workflow` deferred lint flip is honoured" → confirmed by absence of `public_member_api_docs` in those two packages' analyzer config (no new `analysis_options.yaml` for either).
- [TI07,TI08,TI09] Scenario "Spot-check finds offending comment patterns and removes them" → the three regex commands plus the consumer-coupling spot-check return zero/clean.
- [TI09] Scenario "Sweep does not break dartdoc generation" → `dart doc packages/dartclaw_workflow` completes without errors after the trim.
- [—] Scenario "Internal dartdoc trim is opportunistic, not exhaustive" → if Part C slips, the slip is recorded as an `OBSERVATION:` here at exec-spec time; this scenario is satisfied by the recorded slip note plus surviving Part A + Part B verifications.

### Validation
- Run `bash dev/tools/release_check.sh --quick` after the sweep to confirm format/analyze/release-readiness gates remain clean.
- Manually run `dart doc packages/dartclaw_models packages/dartclaw_storage packages/dartclaw_security packages/dartclaw_config packages/dartclaw_server packages/dartclaw_workflow` after Parts A and C to confirm the sweep + trim did not introduce broken `[TypeName]` references or unbalanced fences.
- Spot-check sample for "third-person, starts with verb": pick 5 random declarations from TI01's edited set; confirm voice and shape.

### Execution Contract
- Implement tasks in listed order. TI02–TI05 may run in parallel since each touches a different package; TI06 aggregates them and must run after all four. Part A (TI01) and Part B (TI02–TI06) are mutually independent. Part C (TI07–TI09) follows Part B (so smoke-probe negative case in TI06 cleanly reverts before bulk Part C edits begin).
- Each **Verify** line must pass before proceeding.
- Prescriptive details — exact `analysis_options.yaml` shape (must `include:` workspace rules + add `public_member_api_docs`), the three TI07 regexes verbatim, the eight Anti-Rot pattern names in TI10, the TI09 line budgets (≤8 / ≤10) — are exact.
- After all tasks: run `dart analyze --fatal-warnings --fatal-infos`, `dart format --set-exit-if-changed`, `dart test`, and `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Slip handling: if Part C cannot complete inside the wave-3 budget, record an `OBSERVATION:` with the exact list of remaining offenders and the proposed 0.16.6 cleanup-story title; check off TI07–TI09 only for what shipped; Parts A + B alone still close the FR6 binding constraint #39.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] **All success criteria** met (verified via TI01–TI11)
- [ ] **All tasks** fully completed and checkboxes checked, OR Part C slip recorded with `OBSERVATION:`
- [ ] **No regressions** — workspace `dart analyze --fatal-warnings --fatal-infos`, `dart format --set-exit-if-changed`, and `dart test` all green
- [ ] **No new pubspec deps** (binding constraint #2)
- [ ] **`dartclaw_server` lint-off boundary preserved** — no `public_member_api_docs` in `packages/dartclaw_server/analysis_options.yaml`
- [ ] **`dartclaw_core` / `dartclaw_workflow` deferral honoured** — no new `analysis_options.yaml` enabling `public_member_api_docs` in either package

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
