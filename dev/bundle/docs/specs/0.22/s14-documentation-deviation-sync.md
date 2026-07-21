# Documentation & deviation sync

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S14

## Feature Overview and Goal

**Intent**: After the Afterglow overhaul ships, the design-system docs still describe the pre-overhaul system — future UI work would reference stale guidance (missing tokens, undocumented icons, unrecorded divergences); this story makes the docs match what was actually built.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] The DESIGN.md icon vocabulary table lists every icon the shipped canonical `icons.css` defines — including the icons introduced by the canon-extension merge (S01) — so the table is a complete map of the served icon set.
- [OC02] DESIGN.md documents the provider-brand token group (`--brand-claude`, `--brand-codex`): what it is, that it identifies the provider (never state), and that it replaces Codex's former borrow of semantic `--info`.
- [OC03] Every intentional divergence introduced by this milestone is recorded — design-system deviations (e.g. the partial layout-container-family collapse) in DESIGN.md, wireframe-to-implementation divergences in the private `deviations.md` — so no undocumented deviation remains (every divergence has a row/note; when the private repo is unreachable, the rows are staged in the bundle-local fallback for manual sync rather than lost).
- [OC04] User-guide docs (`docs/guide/`) carry no stale screenshots of significantly changed surfaces.


## Required Context

### From `prd.md` — "FR7: Documentation & deviation sync"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr7-documentation--deviation-sync -->
<!-- extracted: 7d948b65 -->
> **Description**: Update affected documentation as part of the work: public design-system docs (icon vocabulary additions, the new provider-brand token group, any deviations discovered) and the private wireframe `deviations.md`; refresh user-guide screenshots where the visual change is significant.
>
> **Acceptance Criteria**:
> - [ ] DESIGN.md reflects the 5 upstreamed icons and the provider-brand token group.
> - [ ] `deviations.md` records any intentional divergences; no undocumented deviation remains.

### From `prd.md` — "FR2: Token rationalization & provider-brand canonicalization" (provider-brand rationale)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr2-token-rationalization--provider-brand-canonicalization -->
<!-- extracted: 7d948b65 -->
> Canonicalize a documented **provider-brand** token group so Codex's badge no longer borrows semantic `--info` (which collides with the info state in the same views).

### From `plan.json` — sharedDecisions "Provider-brand token group" (S01/S14 split)
<!-- source: dev/bundle/docs/specs/0.22/plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> S01 upstreams a documented provider-brand token group (e.g. `--brand-claude`, `--brand-codex`) to canonical tokens.css and fixes app badge use sites (Codex stops borrowing semantic `--info`); S14 completes the DESIGN.md documentation.

### From `DESIGN.md` — icon SoT scope (what the vocabulary table must cover)
<!-- source: dev/design-system/DESIGN.md#icons -->
<!-- extracted: 7d948b65 -->
> `icons.css` is the exception: its icon inventory is kept in strict sync – every icon the served file defines must exist here and in the vocabulary table below (enforced by `packages/dartclaw_server/test/static/design_system_icons_sync_test.dart`).


## Deeper Context

- `dev/bundle/docs/specs/0.22/s07-health-memory-dashboards-adoption.md#what-were-not-doing` + `s10-scheduling-projects-session-info-adoption.md#what-were-not-doing` — the two stories that flagged the partial layout-container-family collapse for cross-cutting review; read when composing the DESIGN.md deviation note.
- `dev/bundle/docs/specs/0.22/s01-css-foundation.md` … `s13-*.md` — each sibling FIS's **Implementation Observations** and **What We're NOT Doing** sections are the enumerable source of intentional divergences to sweep for OC03; read at execution time (S14 runs last, so these are populated).
- `packages/dartclaw_server/test/static/design_system_icons_sync_test.dart` — the strict icons sync test compares served vs canonical `icons.css`; it does **not** parse the DESIGN.md vocabulary table, so table currency is a manual discipline this story owns.
- `dev/design-system/DESIGN.md#colors` — the token-group documentation home (Semantic / Extended palette / Chart ramp bullets); the provider-brand group sits alongside these.
- The private repo's `docs/wireframes/deviations.md` + `page-inventory.md` — the deviations register (table format + "How to use this file") and the wireframe inventory to diff shipped UI against; lives outside this repo (resolve the private repo per the DECISION NOTE `private-repo-write-path`, not by a naive relative path).


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01] Icon vocabulary table is a complete map of the shipped icon set**
  - **Given** the canon-extension merge and S01 re-sync have landed (canonical `dev/design-system/icons.css` defines the extension icons, e.g. `--icon-arrow-up`, `--icon-plus`, `--icon-bell`, `--icon-git-branch`, `--icon-paperclip`, `--icon-corner-down-right`, plus the pre-existing `file-text`, `folder-git`, `gauge`, `workflow`, `wrench`)
  - **When** the DESIGN.md "Icon vocabulary (semantic → Lucide)" table is checked against every `--icon-*` definition in canonical `icons.css`
  - **Then** every defined icon has a table row (semantic key or `—`, Lucide name, `--icon-*` property, context) and no `--icon-*` is absent from the table

- [x] **S02 [OC02] [TI02] Provider-brand token group is documented**
  - **Given** S01 has upstreamed `--brand-claude` and `--brand-codex` to canonical `tokens.css`
  - **When** a contributor reads DESIGN.md's colour/token documentation
  - **Then** a provider-brand entry names `--brand-claude` and `--brand-codex`, states they identify the provider and never carry state, and records that they replace Codex's former borrow of semantic `--info`

- [x] **S03 [OC03] [TI03] The partial layout-container collapse is recorded as a deviation**
  - **Given** S07 collapsed `.dashboard/.dashboard-inner` and S10 collapsed `.info-content/.info-inner`, but `.page-content/.page-inner` survives as an app-only family — still consumed both by **in-scope** pages whose migration was deferred this milestone (tasks, task detail, scheduling, projects, memory dashboard) and by out-of-scope templates (the knowledge UI)
  - **When** the design-system docs are reviewed for undocumented divergences
  - **Then** DESIGN.md records that the layout-container collapse is intentionally partial for this milestone — `.content-area/.content-inner` is canonical, `.page-content/.page-inner` survives app-side until its last consumer migrates

- [x] **S04 [OC03] [TI04] No undocumented intentional deviation remains**
  - **Given** stories S01–S13 have shipped and each carries its Implementation Observations / non-goals
  - **When** those sections and the shipped UI are swept against the wireframe inventory and design-system canon
  - **Then** every intentional wireframe-to-implementation divergence has a `deviations.md` row and every design-system divergence has a DESIGN.md note; a reviewer confirms no flagged divergence is left unrecorded

- [x] **S05 [OC04] [TI05] User-guide docs carry no stale screenshots**
  - **Given** `docs/guide/` is the end-user reference
  - **When** it is checked for embedded screenshots of surfaces the overhaul changed significantly
  - **Then** any such screenshot is refreshed; where the guide embeds no screenshots of changed surfaces, the check confirms there is nothing to refresh

- [x] **S06 [OC01] [TI01] A new icon introduced during implementation cannot be silently undocumented**
  - **Given** an icon added to canonical `icons.css` during S01–S13 that has no DESIGN.md table row
  - **When** the OC01 reconciliation runs
  - **Then** the gap is caught and a table row is added (the reconciliation compares against the live `icons.css`, not a fixed list)


## Scope & Boundaries

### Work Areas
- `dev/design-system/DESIGN.md` — icon vocabulary table reconciliation (OC01), provider-brand token documentation (OC02), design-system deviation note for the partial layout-container collapse (OC03), and the `☐` Unicode-exceptions supersession by the S12 claw-mark (FR7 doc currency).
- Private `docs/wireframes/deviations.md` — cross-repo edit: resolve the private repo as a **sibling of the main public checkout root** (derive the main checkout via git worktree/common-dir resolution, not the story-worktree cwd) and existence-check it before writing; append a row for each intentional wireframe-to-implementation divergence this milestone introduced (OC03). If the private repo is absent/unreachable, write the rows to the bundle-local fallback `dev/bundle/docs/specs/0.22/deviations-staged.md` and record an Implementation Observation for manual sync. See the DECISION NOTE `private-repo-write-path`.
- Sibling FIS `Implementation Observations` / `What We're NOT Doing` sweep — the enumerable source that feeds the OC03 deviation records.
- `docs/guide/` — verification pass for stale screenshots of changed surfaces (OC04).

### What We're NOT Doing
- Editing any `.css` or token file — S01 owns the token/icon upstreaming and the served-file sync; S14 documents the shipped result only.
- Re-documenting doctrines already canonical in DESIGN.md (scarcity, glass-over-live-content, identicons-identity-only, chart ramp, safe-area/titlebar tokens) — those land with their owning stories / the canon-extension merge, not here.
- Proving the milestone's implementation binding constraints (zero-npm, mobile parity, `window.confirm`, `.meter` usage, byte-identical sync) — each is owned and gated by its implementing story (S01–S13); S14 records deviations from them but does not re-prove them.
- Authoring new wireframes or updating `page-inventory.md` structure — deviations are recorded against the existing inventory, not re-drawn.


## Architecture Decision

**Approach**: Documentation-only reconciliation, run last (depends on S12, S13) so every shipped divergence is observable; the canonical `icons.css` and `tokens.css` are the sources of truth the docs are reconciled against, and the sibling FIS observation sections are the divergence register.


## Constraints & Gotchas

- **Cross-repo edit + private-repo resolution**: `deviations.md` lives in the private repo (`docs/wireframes/deviations.md`), outside this repo's tree and git history. Resolve the private repo as a **sibling of the main public checkout root** — derive the main checkout via git worktree/common-dir resolution, never the current worktree cwd, because story worktrees nest inside the public repo at `.claude/worktrees/` and a naive `../dartclaw-private/` would resolve to a wrong nested path. Existence-check the resolved path before writing; edit `deviations.md` in place (it is not part of this repo's commit). **Absence fallback**: if the private repo is absent or unreachable, write the deviation rows to the bundle-local staging file `dev/bundle/docs/specs/0.22/deviations-staged.md` and record an Implementation Observation for manual sync — nothing is silently lost and no stray file is created at a wrongly-resolved path. See the DECISION NOTE `private-repo-write-path`.
- **The icons sync test does not guard the DESIGN.md table** — it compares served vs canonical `icons.css` only. A missing vocabulary-table row passes the test but leaves the doc stale; OC01 is a manual reconciliation, verified by comparing the table against `icons.css` by hand/script, not by the existing test.
- **Never hand-edit the synced CSS** to "fix" a doc mismatch — the drift check (S01) fails on any divergence between served and canonical CSS. Docs bend to the shipped CSS, never the reverse.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** DESIGN.md icon vocabulary table maps every icon in canonical `icons.css`
  - Compare the "Icon vocabulary (semantic → Lucide)" table against every `--icon-*` definition in `dev/design-system/icons.css`; add a row (semantic key or `—`, Lucide name, `--icon-*`, context) for each undocumented icon — the extension-added icons (`arrow-up`, `plus`, `bell`, `git-branch`, `paperclip`, `corner-down-right`, …) and any introduced during S01–S13. The pre-existing `file-text`, `folder-git`, `gauge`, `workflow`, `wrench` rows are already present — confirm, don't duplicate.
  - **Verify**: `Test: every custom property matching --icon-<name> in dev/design-system/icons.css has a matching --icon-<name> cell in the DESIGN.md vocabulary table (set difference is empty)`

- [x] **TI02** DESIGN.md documents the provider-brand token group
  - In the Colors/token documentation (alongside the Semantic / Extended-palette / Chart-ramp bullets), document `--brand-claude` and `--brand-codex`: they identify the agent provider on badges, never carry state, and replace Codex's former borrow of semantic `--info`. Match the values S01 upstreamed to `tokens.css`.
  - **Verify**: `grep -q -- "--brand-claude" dev/design-system/DESIGN.md && grep -q -- "--brand-codex" dev/design-system/DESIGN.md && grep -qi "info" <(grep -A2 "brand-codex" dev/design-system/DESIGN.md)` — the entry names both tokens and references the `--info` replacement (the `<(…)` process substitution requires bash, not POSIX `sh` — fine for agent-run checks)

- [x] **TI03** DESIGN.md records the partial layout-container-family collapse
  - Add a note where layout containers are documented (Shell / Layout primitives): `.content-area/.content-inner` is canonical; the parallel `.page-content/.page-inner` family intentionally survives as app-only for this milestone because it is still consumed both by in-scope pages whose migration was deferred (tasks, task detail, scheduling, projects, memory dashboard) and by out-of-scope templates (the knowledge UI), and it collapses when its last consumer migrates. Source the rationale from the S05/S07/S10 deferral notes and cross-cutting-review flags.
  - **Verify**: `grep -q "page-content" dev/design-system/DESIGN.md` and the note states the collapse is intentionally partial (canonical family named, surviving family named, in-scope + out-of-scope survivors distinguished)

- [x] **TI04** `deviations.md` records every intentional wireframe-to-implementation divergence from this milestone
  - Resolve the private `deviations.md` as a **sibling of the main public checkout root** (main checkout derived via git worktree/common-dir resolution, not the story-worktree cwd under `.claude/worktrees/`) and existence-check it before writing. If the private repo is absent/unreachable, write the rows to the bundle-local fallback `dev/bundle/docs/specs/0.22/deviations-staged.md` and record an Implementation Observation for manual sync — the rows still exist, staged for sync, so OC03 is satisfied. See the DECISION NOTE `private-repo-write-path`.
  - Sweep each sibling FIS (`s01`…`s13`) Implementation Observations / What-We're-NOT-Doing plus the shipped UI against `page-inventory.md`; append a dated `deviations.md` row per intentional divergence using the existing table columns. Design-system-only divergences go to DESIGN.md (TI03), not here. The enumerable set includes at least:
    - mascot CRT login hero vs `auth-login.html` (S11);
    - claw-mark empty states vs wireframe emoji, plus the mascot empty-state narrowing — no full mascot lands on any empty state (S12 uses the `.claw-mark`, not the mascot), and app-level/chat empty states keep the sanctioned prompt glyph (`❯_`);
    - identicon placements, including the granularity deviation from the audit's literal "hash channel id": the channel-detail hero identicon is hashed by `channelType` while sidebar channel/session rows hash the session id (S13);
    - if it ships, S07's eyebrow-title simplification (deleting `.dashboard .card-title` drops the uppercase eyebrow treatment on dashboard card headers).
  - **Verify**: `Test: for each intentional divergence flagged in an S01–S13 Implementation Observations / non-goal section, deviations.md (or the bundle-local deviations-staged.md when the private repo is unreachable, or DESIGN.md for design-system deviations) carries a corresponding row/note; a reviewer confirms no flagged divergence is unrecorded`

- [x] **TI05** `docs/guide/` screenshots reflect the shipped UI
  - Check `docs/guide/` for embedded screenshots of surfaces the overhaul changed significantly; refresh any stale ones. If the guide embeds no such screenshots, record that the check found nothing to refresh (currently `docs/guide/` carries no image assets).
  - **Verify**: `Test: no screenshot in docs/guide/ depicts a pre-overhaul rendering of a changed surface (find docs/guide -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.gif' -o -name '*.webp' \) enumerates the set to check; empty set → nothing to refresh)`

- [x] **TI06** DESIGN.md's `☐` Unicode-exceptions entry reflects the S12 claw-mark supersession
  - The `☐` glyph's only use site — the tasks empty state — is replaced by the `.claw-mark` in S12, so DESIGN.md's Unicode-exceptions line listing `☐` among "decorative empty-state glyphs" is now stale. Update that entry so `☐` is no longer claimed as a live empty-state glyph — remove it from the list (its use site now renders the claw-mark) or annotate the supersession — per this story's FR7 doc-currency mandate. Leave `💬`/`📋` untouched unless their own use sites also changed.
  - **Verify**: `grep -n "☐" dev/design-system/DESIGN.md` — the surviving Unicode-exceptions text no longer claims `☐` is a live decorative empty-state glyph (removed, or annotated as superseded by the S12 claw-mark)


## Final Validation Checklist

- [x] Docs-only: no served or canonical CSS/token file is modified — `git diff --name-only` touches no path under `dev/design-system/*.css` or `packages/dartclaw_server/lib/src/static/`.
- [x] The strict icons sync test stays green: `dart test packages/dartclaw_server/test/static/design_system_icons_sync_test.dart` passes (served `icons.css` unchanged by this story).
- [x] `deviations.md` keeps its existing table shape (`# | Area | Wireframe Shows | Implementation Does | Resolution | Canonical`) and its "How to use this file" trailer — new rows append to the table, nothing else in the file changes.

**PRD success-metric-2 app-wide re-assertions** (read-only cross-cutting capstone — each metric is owned/gated by its implementing story S01–S13; S14 re-confirms the aggregate at milestone close, changing no code):

- [x] ≤5 justified inline `style` attributes remain app-wide: `grep -rn 'style="' packages/dartclaw_server/lib/src/templates/ packages/dartclaw_server/lib/src/web/pages/` (excluding Trellis `tl:attr` dynamic bindings) counts ≤5, each justified.
- [x] Zero template-local `<style>` blocks remain: `grep -rn '<style' packages/dartclaw_server/lib/src/templates/ packages/dartclaw_server/lib/src/web/pages/` returns nothing.
- [x] Zero bespoke progress-bar / spinner class names remain: `grep -rEn '(budget-bar|fill-bar|task-progress|workflow-progress-bar|workflow-run-progress-bar|restart-spinner|wa-spinner)' packages/dartclaw_server/lib/src/templates/ packages/dartclaw_server/lib/src/web/pages/ packages/dartclaw_server/lib/src/static/` returns nothing.


## Implementation Observations

#### DECISION NOTE: private-repo-write-path

Decision-Key: private-repo-write-path
Altitude: story (implementation-level)
Affected surface: S14 executor cross-repo write to `../dartclaw-private/docs/wireframes/deviations.md` (TI04) — private-repo path resolution and the unreachable-repo fallback.
Decision: The private repo is resolved as a SIBLING OF THE MAIN PUBLIC CHECKOUT ROOT, deriving the main checkout via git worktree/common-dir resolution — never the current worktree cwd, since story worktrees nest inside the public repo at `.claude/worktrees/`. If `dartclaw-private` is absent or unreachable, the executor writes the deviation rows to a bundle-local staging file (`dev/bundle/docs/specs/0.22/deviations-staged.md`) and records an Implementation Observation for manual sync.
Rationale: The story completes, nothing is silently lost, and no stray file is created at a wrongly-resolved path — a story-worktree cwd would otherwise resolve the private sibling to a wrong nested location under `.claude/worktrees/`.
Evidence: Ratified by owner during 0.22 preflight, 2026-07-20.
