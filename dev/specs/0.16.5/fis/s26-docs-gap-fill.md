# FIS — S26: Docs Gap-Fill (pick 2 of 5)

**Plan**: ../plan.md
**Story-ID**: S26

> **Stretch — only if capacity remains after Blocks A–G complete (W7 placement).** Per PRD Decisions Log, scope pressure slips this forward to 0.16.6 entirely; DartClaw does not ship a 0.16.5.1 patch.

## Feature Overview and Goal

Pick **2 of 5** candidate user-guide pages and either author or promote them so the public user guide has internally-consistent coverage of two long-standing gap areas at 0.16.5 reality. Doc-only — no code touched. The other 3 candidates defer to a dedicated docs gap-fill milestone.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see § "S26 — Docs Gap-Fill (pick 2 of 5)")_


## Required Context

> Cross-doc reference rules: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#cross-document-references).

### From `dev/specs/0.16.5/plan.md` — "S26 Scope + Acceptance Criteria"
<!-- source: dev/specs/0.16.5/plan.md#s26-docs-gap-fill-pick-2-of-5 -->
<!-- extracted: e670c47 -->
> **Scope**: Pick **2 of 5** candidate new or promoted user-guide pages: (a) promote `recipes/08-crowd-coding.md` to `docs/guide/crowd-coding.md` + add row to `docs/guide/README.md` Features table; (b) author new `docs/guide/governance.md` (rate limits, budgets, loop detection, `/stop`/`/pause`/`/resume`, admin sender model); (c) author new `docs/guide/skills.md` (SkillRegistry source priority, frontmatter schema, validation rules, user vs managed skills, `.dartclaw-managed` marker); (d) add Workflow Triggers section to `workflows.md` (chat commands, web launch forms, GitHub PR webhook setup + HMAC secrets); (e) add Alert Routing + Compaction Observability sections under `web-ui-and-api.md` or new `docs/guide/observability.md`. The other 3 defer to a dedicated docs gap-fill milestone.
>
> **Acceptance Criteria**:
> - [ ] 2 of the 5 candidate pages exist and are internally consistent with 0.16.5 reality
> - [ ] `docs/guide/README.md` Features table / index updated for the new page(s)
> - [ ] Cross-references from related guide pages added
> - [ ] A user-guide reader can get from `README.md` to the new pages within ≤2 clicks

### From `dev/specs/0.16.5/plan.md` — "S26 Dependencies"
<!-- source: dev/specs/0.16.5/plan.md#s26-docs-gap-fill-pick-2-of-5 -->
<!-- extracted: e670c47 -->
> **Dependencies**: S01, S02, S03, S05, S09, S10, S11, S12, S13, S15, S16, S17, S18, S19, S22, S23, S24, S25, S27, S28, S29, S31, S32, S33, S34, S35, S36, S37, S38. This is the concrete dependency set behind the wider "Blocks A–G complete" intent. S03, S05, S19, and S22 are the substantive doc-content prerequisites; the full non-retired Block A–G list is also included so dependency-aware workflow fan-out cannot start the W7 stretch story before the sprint implementation state is current.

### From `dev/specs/0.16.5/prd.md` — "FR9 (Stretch): Documentation Gap-Fill"
<!-- source: dev/specs/0.16.5/prd.md#fr9-stretch-documentation-gap-fill -->
<!-- extracted: e670c47 -->
> **Description**: Pick 2 of 5 candidate gap-fill pages if capacity permits.
>
> **Acceptance Criteria** (pick 2 of 5):
> - [ ] Promote `recipes/08-crowd-coding.md` → `docs/guide/crowd-coding.md` + link from Features table, OR
> - [ ] New `docs/guide/governance.md` (rate limits, budgets, loop detection, `/stop`/`/pause`/`/resume`), OR
> - [ ] New `docs/guide/skills.md` (SkillRegistry source priority, frontmatter schema, user vs managed skills), OR
> - [ ] Workflow Triggers section in `workflows.md` (chat commands, web launch forms, GitHub PR webhook + HMAC), OR
> - [ ] Alert Routing + Compaction Observability sections under `web-ui-and-api.md` or new `observability.md`
>
> **Priority**: Should / P2 (stretch only)

### From `dev/specs/0.16.5/.technical-research.md` — "Binding PRD Constraints (#2, #4, #78)"
<!-- source: dev/specs/0.16.5/.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> | 2 | "No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`." | Constraint | All stories |
> | 4 | "No new user-facing features. No new CLI commands, channels, workflow step types, or MCP tools." | Constraint / Out of Scope | All stories |
> | 78 | "No 0.16.5.1 patch — slip scope forward to 0.16.6." | Decisions Log | All stories |


## Deeper Context

- `docs/guide/recipes/08-crowd-coding.md` — canonical source for candidate (a) promotion; structure/feature taxonomy shows what an inverted "feature page" view should cover.
- `docs/guide/security.md` — short reference page in current style; structural template for a new short page (e.g. governance.md).
- `docs/guide/workflows.md` — long-form guide page with sectioned reference; structural template for adding the Workflow Triggers section in candidate (d).
- `docs/guide/web-ui-and-api.md` — host page if candidate (e) is added inline rather than as a new `observability.md`.
- `docs/guide/README.md` — index file with `## Features` table that every candidate must update.
- `docs/guide/architecture.md` and `dev/state/UBIQUITOUS_LANGUAGE.md` — terminology source of truth; new pages must use canonical terms.


## Success Criteria (Must Be TRUE)

> Every criterion has a proof path: a Scenario (behavioral) or task Verify line (structural).

### Pages exist
- [ ] Exactly 2 candidates from the (a)–(e) set are produced — not fewer, not more (proof: TI01 Verify)
- [ ] Each chosen page exists at the documented target path and is non-empty (proof: TI02/TI03 Verify)
- [ ] Each chosen page is internally consistent with 0.16.5 reality — no stale CLI flag, config key, version pin, or feature claim that contradicts current `docs/guide/configuration.md`, `docs/guide/cli-operations.md`, or shipped 0.16.x behaviour (proof: TI02/TI03 Verify — cross-reference grep)

### Index + cross-references updated
- [ ] `docs/guide/README.md` Features table contains a row for each new/promoted page with a one-line description (proof: TI04 Verify)
- [ ] At least one related guide page links into each new page (e.g. `tasks.md` → governance.md if (b) chosen) (proof: TI05 Verify)
- [ ] If (a) is chosen, `docs/guide/recipes/08-crowd-coding.md` either redirects to or coexists cleanly with `docs/guide/crowd-coding.md` — no duplicated content rot (proof: TI02 Verify)

### Navigation
- [ ] A reader starting at `README.md` (workspace root) reaches each new page in ≤2 clicks via the documented link path (proof: scenario "Reader navigates from root README to new page in ≤2 clicks")

### Selection decision recorded
- [ ] The 2-of-5 decision (which candidates were chosen + brief rationale) is recorded in this FIS's `Implementation Observations` section before TI02 starts (proof: TI01 Verify)

### Health Metrics (Must NOT Regress)
- [ ] No code changes — `git diff --stat` shows zero non-`docs/` files modified (proof: TI07 Verify)
- [ ] No new dependencies added to any `pubspec.yaml` (proof: TI07 Verify — guards against accidental scope creep)
- [ ] Existing user-guide pages structurally unchanged except for the small cross-reference link additions in TI05 (proof: TI07 Verify — `git diff --stat docs/guide/` review)


## Scenarios

> Scenarios as Proof-of-Work: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#scenarios-and-proof-of-work).

### Operator reads governance.md (if candidate (b) chosen)
- **Given** candidate (b) was selected and `docs/guide/governance.md` was authored
- **When** an operator opens the page after the workspace ships 0.16.5
- **Then** they can find rate-limit configuration keys, token-budget configuration keys, loop-detection thresholds, the `/stop` / `/pause` / `/resume` chat commands, and the admin-sender model — each section terms match `docs/guide/configuration.md` exactly (no parallel/divergent vocabulary)

### Skill author reads skills.md (if candidate (c) chosen)
- **Given** candidate (c) was selected and `docs/guide/skills.md` was authored
- **When** a developer wants to ship a custom skill for their fork
- **Then** they can read the SkillRegistry source-priority order (user → managed → bundled or whatever 0.16.5 ships), the frontmatter schema (matching what `dartclaw_workflow` validators accept), validation rules, the user-vs-managed distinction, and the `.dartclaw-managed` marker file's role — and the import path for `SkillInfo` matches its post-S22 location in `dartclaw_workflow`

### Reader navigates from root README to new page in ≤2 clicks
- **Given** both new pages are linked from `docs/guide/README.md` Features (or appropriate) table
- **When** a reader starts at the workspace-root `README.md`
- **Then** click 1 reaches `docs/guide/README.md` (existing "Documentation" link), click 2 reaches each new page

### Promotion does not orphan the recipe (if candidate (a) chosen)
- **Given** `recipes/08-crowd-coding.md` was promoted to `docs/guide/crowd-coding.md`
- **When** a reader follows the existing recipe-table link in `docs/guide/README.md`
- **Then** they either land on the recipe (if it stayed in place as a copy-pasteable workshop config) or are redirected with a one-line pointer to `crowd-coding.md` — no broken link, no silently-stale parallel copy

### Capacity exhausted before 2 candidates land
- **Given** Blocks A–G consumed all sprint capacity and the team cannot land 2 candidates with quality
- **When** the FIS executor evaluates capacity at TI01
- **Then** the story is explicitly slipped forward to 0.16.6 (via STATE.md note + plan status `Skipped (slipped to 0.16.6)`); no partial 1-of-5 ship; no 0.16.5.1 patch is created


## Scope & Boundaries

### In Scope
_Every scope item is covered by at least one scenario or task with a Verify line._
- Pick exactly 2 candidates from the (a)–(e) set; the recommended pairing is **(b) governance + (d) workflow-triggers** — both reference shipped 0.16.x features, both close the largest documented gap, both are user-facing operator/author pages.
- Author or promote the 2 chosen pages to the documented target paths.
- Update `docs/guide/README.md` Features table / index for each new page.
- Add cross-references from related existing pages.
- Verify the ≤2-click navigation contract from workspace-root `README.md`.

### What We're NOT Doing
- **Writing all 5 pages** — intentional pick-2; the other 3 are reserved for a dedicated docs gap-fill milestone. Trying to ship more here dilutes the stretch budget.
- **Restructuring existing user-guide pages** — only small additive cross-reference link insertions are allowed. No reorg of `workflows.md`, `tasks.md`, `web-ui-and-api.md`, etc.
- **Touching `cli-reference.md` or `architecture.md`** — those are owned by S03/S19 doc-currency work; out of scope here.
- **Promoting any recipe other than `08-crowd-coding`** — the other 7 recipes stay in `recipes/`; only the crowd-coding promotion is on the candidate list.
- **Deferring overflow to a `0.16.5.1` patch release** — DartClaw does not ship patch releases (PRD Decisions Log). If 2 cannot be authored with quality, slip the entire story forward to 0.16.6.
- **Code changes** — doc-only story; any code touch is a sign that the chosen page is overreaching its scope.

### Agent Decision Authority
- **Autonomous**: Which 2 of (a)–(e) to pick — based on highest-user-impact heuristic (default: (b) governance + (d) workflow-triggers); page section ordering; whether candidate (e) lands as a `web-ui-and-api.md` section vs new `observability.md`; whether candidate (a) leaves the recipe in place (preferred) or replaces it with a redirect stub.
- **Escalate**: Slip-forward decision (skipping the entire story to 0.16.6) — surface to user before marking story `Skipped`; any deviation from the constraint that exactly 2 land (e.g. "could we add a 3rd small one?" — answer is no without explicit user override).


## Architecture Decision

**We will**: pick 2 of (a)–(e) at FIS-execution time based on a highest-user-impact heuristic (default recommended pairing: **(b) governance + (d) workflow-triggers** — both reference shipped 0.16.x features and have the largest documented gap relative to user-facing operational complexity). The other 3 candidates defer to a dedicated docs gap-fill milestone. If capacity does not allow even 2 to land with quality, the story slips forward to 0.16.6 entirely (per PRD Decisions Log: "No 0.16.5.1 patch") rather than shipping a partial 1-of-5.

The recommended pairing rationale: (b) closes the operator-side gap (rate limits / budgets / loop detection / `/stop`-`/pause`-`/resume` are scattered across `configuration.md` + `tasks.md` + recipe text and have no single reference); (d) closes the workflow-author gap (chat commands, web launch forms, GitHub PR webhook with HMAC are mentioned across `workflows.md` + `web-ui-and-api.md` but never assembled into a single triggers section). (a) crowd-coding promotion is a close third — recipe content is high-quality but already linked. (c) skills page is medium-impact but blocked on S22 settling the `SkillInfo` import path. (e) alert routing + compaction observability is medium-impact but partially covered by `web-ui-and-api.md` SSE section after S05.


## Technical Overview

### UI/UX Design
N/A — text content only. Each new page follows the existing user-guide structural template: H1 page title, optional 1-paragraph orientation, sectioned reference content with internal links, `## See also` footer cross-referencing related guide pages.

### Page-shape conventions (apply to every new page)
- H1 title matches the link text in `docs/guide/README.md`.
- Internal references use canonical terms from `dev/state/UBIQUITOUS_LANGUAGE.md`.
- Configuration-key references use the same notation style as `docs/guide/configuration.md` (e.g. `providers.claude.executable`, not `agent.claude_executable`).
- All version pins / feature-claim language reflects 0.16.5 — no "in 0.14.3 we added…" framing copied from `08-crowd-coding.md` unless directly relevant.

### Integration Points
- `docs/guide/README.md` Features table is the canonical index — every new page lands there.
- Cross-references go in both directions: existing guide pages link into the new page, and the new page links back via `## See also`.


## Code Patterns & External References

```
# type | path/url | why needed
file   | docs/guide/recipes/08-crowd-coding.md           | Source content for candidate (a) promotion + structural template for feature taxonomy framing
file   | docs/guide/security.md                          | Short-page structural template (143 LOC) — good model for governance.md / observability.md
file   | docs/guide/workflows.md                         | Long-form structural template + host page if (d) Workflow Triggers section is added inline
file   | docs/guide/web-ui-and-api.md                    | Long-form structural template + host page if (e) is added inline
file   | docs/guide/README.md                            | Index page with Features table — every chosen candidate updates this
file   | docs/guide/configuration.md                     | Source of truth for config keys referenced by governance.md / workflow-triggers / observability
file   | dev/state/UBIQUITOUS_LANGUAGE.md                | Canonical terms — new pages must align
```


## Constraints & Gotchas

- **Constraint (PRD #2)**: No new dependencies. Doc-only story; this is a guard against scope creep masquerading as "I needed a small helper."
- **Constraint (PRD #4)**: No new user-facing features. New pages **document existing** behaviour — do not introduce config keys, CLI commands, or behaviours that don't already ship.
- **Constraint (PRD #78)**: No 0.16.5.1 patch. If only 1 candidate can land with quality, slip the **entire** story to 0.16.6 — do not ship a half-FIS.
- **Avoid**: Copying obsolete content from referenced files. (e.g. `08-crowd-coding.md` says "0.14.3 adds …" — that framing is wrong in a 0.16.5 user-guide page.) **Instead**: rewrite version-anchored claims as plain present-tense feature description.
- **Avoid**: Promoting a candidate when its dependencies are not landed. (Candidate (c) skills.md is most exposed: needs S22 `SkillInfo` import path settled.) **Instead**: pick from the dependency-clean set first; recommended pairing (b)+(d) is dependency-light.
- **Critical**: Internal consistency check. After authoring, grep each new page for any term, config key, or version pin and confirm it matches `docs/guide/configuration.md` + `docs/guide/cli-operations.md` ground truth. Drift here is worse than absence.


## Implementation Plan

> **Vertical slice ordering**: TI01 picks the candidates and records the decision; TI02–TI03 author them one at a time so a partial slip (1 of 2 fails) is recoverable; TI04–TI06 wire them into navigation; TI07 verifies non-regression.

### Implementation Tasks

- [ ] **TI01** Pick exactly 2 of the 5 candidates and record the decision in `Implementation Observations` (chosen pair + rationale + any deviation from the recommended (b)+(d) pairing). If capacity assessment indicates fewer than 2 will land with quality, mark the story `Skipped` and slip to 0.16.6 — do not proceed to TI02.
  - Default to (b) governance + (d) workflow-triggers unless dependency status or capacity points elsewhere; check S22 status before picking (c) skills.
  - **Verify**: `Implementation Observations` section contains a dated entry naming the 2 picks and 1-paragraph rationale; the pair is a subset of {a, b, c, d, e}; no third candidate listed.

- [ ] **TI02** First chosen candidate page exists at its documented target path, follows the page-shape conventions (Technical Overview), and is internally consistent with 0.16.5 reality.
  - Use `docs/guide/security.md` (short) or `docs/guide/workflows.md` (long) as structural template; cross-reference `docs/guide/configuration.md` for any config-key mention; if candidate is (a), preserve `recipes/08-crowd-coding.md` and avoid duplicated rot.
  - **Verify**: file exists at target path; non-empty (>40 LOC); `rg -n "0\.14\.[0-9]+ adds|0\.13\.[0-9]+ adds|Bun standalone|Phase A in progress" <new-page>` returns zero hits; every config-key mentioned in the page also appears in `docs/guide/configuration.md`.

- [ ] **TI03** Second chosen candidate page meets the same standard as TI02.
  - Same structural template selection logic; same internal-consistency contract.
  - **Verify**: same checks as TI02, applied to the second page.

- [ ] **TI04** `docs/guide/README.md` Features table (or appropriate section) has a row for each new/promoted page with a one-line description.
  - Link text matches the new page's H1; description matches the page's leading sentence.
  - **Verify**: `rg -n "<new-page-1-filename>|<new-page-2-filename>" docs/guide/README.md` returns at least one hit per page; the row appears in the same table style as existing entries.

- [ ] **TI05** Each new page has at least one inbound link from a related existing guide page (e.g. governance.md → linked from `tasks.md`; workflow-triggers → linked from `workflows.md` introduction).
  - Add a single sentence + link, not a structural section. Reciprocal `## See also` footer on each new page links back.
  - **Verify**: `rg -n "<new-page-1-filename>|<new-page-2-filename>" docs/guide/` returns ≥3 hits per page (1 in README index + ≥1 inbound + ≥1 self-internal); each new page contains a `## See also` section linking ≥1 existing page.

- [ ] **TI06** A reader navigating from workspace-root `README.md` reaches each new page in ≤2 clicks.
  - Path 1: workspace `README.md` → `docs/guide/README.md` link → new page row click. If `README.md` already links to the guide index this is automatic; verify the link exists and the index entry from TI04 is reachable without further redirection.
  - **Verify**: Manual trace recorded in `Implementation Observations`: starting URL, click 1 target, click 2 target, ending URL — for each new page.

- [ ] **TI07** Spell/grammar pass + non-regression sweep on all touched files.
  - No automated spellchecker required; a careful read-through is enough at this scale. Confirm no other files mutated beyond the new pages, the README index update, and the small cross-reference link additions.
  - **Verify**: `git diff --stat origin/main..HEAD -- ':!docs/' ':!dev/specs/0.16.5/fis/s26-docs-gap-fill.md'` shows no non-doc files mutated; `git diff --stat docs/guide/` lists only the new pages, `README.md`, and ≤4 existing pages with cross-reference link additions; `rg "TODO|FIXME|placeholder|TBD|XXX" <new-page-1> <new-page-2>` returns zero hits.

### Testing Strategy
> Doc-only story — no automated tests. Validation is verification of the structural Verify lines above.

- [TI01] Scenario: "Capacity exhausted before 2 candidates land" → confirm Implementation Observations records either 2 picks or an explicit slip-forward decision.
- [TI02,TI03] Scenarios: "Operator reads governance.md" / "Skill author reads skills.md" / "Promotion does not orphan the recipe" — pick the scenarios that match the chosen candidates; manual read-through of each new page proves the scenario.
- [TI04,TI05,TI06] Scenario: "Reader navigates from root README to new page in ≤2 clicks" → manual trace recorded in Implementation Observations.
- [TI07] Health metrics: `git diff --stat` proves no code mutation.

### Validation
- Manual reviewer (or self) read-through each new page once focusing on internal consistency vs `docs/guide/configuration.md` and `docs/guide/cli-operations.md`.

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- TI01 is a gating decision: if the executor's capacity check fails, stop and slip the story; do not author 1 page and call it done.
- Prescriptive details (file paths, link-row format) are exact — implement them verbatim.
- After all tasks: confirm `git diff --stat` shows only doc files; confirm `rg "TODO|FIXME|placeholder|TBD|XXX" <new-page-1> <new-page-2>` is clean.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met
- [ ] **All tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** or breaking changes introduced (zero non-doc files mutated)
- [ ] **2-of-5 selection decision** recorded in `Implementation Observations`
- [ ] **≤2-click navigation trace** recorded in `Implementation Observations`


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only. Tag semantics: see [`data-contract.md`](${CLAUDE_PLUGIN_ROOT}/references/data-contract.md). Spec authors: leave this section empty._

_No observations recorded yet._
