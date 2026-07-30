# FIS: Global sweep — type tiers, colour tiers and canon container adoption

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
**Story-ID**: S07

> **Split note**: S07 and S16 were one story until it reached 18 tasks. S07 keeps the type, colour and CSS-token work; `fis/s16-global-sweep-shell-behaviour-states-formatting.md` takes the shared fragments, shell behaviour, states and data formatting, and runs immediately after on the same files. The `plan.json` story name and this file's name predate the split and still say "formatting" — the task list below is authoritative.

**All shell commands in this file run from the `dartclaw-public` repo root.** A path rooted anywhere else makes `rg` exit 2 and read as a pass.

## Feature Overview and Goal

**Intent**: The audit's largest cluster is not any one screen — it is defects that every one of the 23 surfaces inherits from `app.css` and the shared card fragment, so a per-surface sweep would fix the same defect five times and diverge five ways; this story closes the type, colour and stacking half of them once, in the layer they actually live in, before the serialized surface sweep sequence begins.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor to these):

- [OC01] The product reads as a hierarchy: `--text-sm` no longer exists anywhere, and every text run in the shared shell, page and card scaffolding resolves through a composite `.t-*` tier rather than a hand-derived set of four properties.
- [OC02] Text and status colour that carry meaning are legible: labels, metadata and table headers leave the placeholder tier, and every app-local badge meets WCAG AA in both themes.
- [OC03] Shared card scaffolding and app stacking come from canon: the scheduling, task-detail and knowledge clone rows adopt canon `.card` as their baseline and lose their clone surface declarations; every app layer sits on the canonical `--z-*` ladder rather than an ad-hoc literal. S08 owns later task restructuring and S10 owns later semantic replacement and obsolete-selector cleanup.


## Required Context

### From `plan.json` – sharedDecisions: "Canon-first, and canon closes after P1"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> Only P1 stories S01-S04 author rules in the drift-checked `tokens.css`, `components.css` and `icons.css`; those rule families close after P1. This story has one serialized, deletion-only exception: after app-side migration it deletes the `--text-sm` alias from `tokens.css`, re-syncs only served `tokens.css`, regenerates embedded assets and closes generated parity green. It may not edit `components.css`, `icons.css` or any other canon family. A missing rule still stops and reports for hoisting to S01-S04. `DESIGN.md` and `showcase.html` remain writable because they are not drift-checked.

### From `plan.json` – sharedDecisions: "`--text-sm` retirement protocol"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 aliases `--text-sm` to `--text-base`, defines all seven composite classes and migrates every canon `components.css` consumer while the P1 type family is open. S07 migrates the remaining app-side and non-drift-checked demo usages, then uses its one token-only exception to delete the alias from `tokens.css`, sync served `tokens.css`, regenerate embedded assets and close parity green. No other story introduces `--text-sm` or reopens a canon family.

### From `plan.json` – sharedDecisions: "Composite type-class vocabulary"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `plan.json` – sharedDecisions: "Surface token roles — three distinct planes"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S01 fixes the structural rule every later story consumes: chrome (`.sidebar`, `.topbar`), page ground and `.card` occupy three mutually distinct planes in both themes, and the body gradient never terminates on the card tone. The mapping is theme-specific: dark starts from chrome → crust / ground → base / card → sub-base, while light uses card white on a tinted ground with chrome at the mantle tier. Exact values in both themes are an S01 visual-validation outcome. No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.

### From `plan.json` – sharedDecisions: "Shared-surface ownership in the sweep phase"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> (2) OFF-SCALE FONT SIZES: S07 alone normalizes every hard-coded off-scale font-size (`.provider-badge`, `.channel-mode-badge`, `.workflow-artifact-badge` and siblings); sweep stories keep only their own semantic edits to those rules and must not re-declare the size.

### From `prd.md` – FR2 acceptance criteria (type-scale rationalization)
<!-- source: docs/specs/0.22.1/prd.md#fr2-type-scale-rationalization--composite-type-layer -->
<!-- extracted: e18cf85 -->
> - [ ] Zero `--text-sm` usages in `app.css` and `design-system.css`.
> - [ ] Every tier in the DESIGN.md § Typography table has a backing composite class and a showcase panel.
> - [ ] The DESIGN.md table is updated so `body-sm` is no longer a legitimate choice.

### From `prd.md` – FR6 (re-sync + adoption sweep)
<!-- source: docs/specs/0.22.1/prd.md#fr6-re-sync--adoption-sweep -->
<!-- extracted: e18cf85 -->
> **Description**: Re-sync canon into the served CSS with the drift check green, purge app-local duplicates obsoleted by FR4, then work the 118 adoption findings. Priority clusters: health/memory/session-info metric + meter adoption; wide-container application; type-tier migration; empty/loading/error state coverage.
>
> **Acceptance Criteria**:
> - [ ] Drift check green; `design-system.css` byte-identical to canon.

### From `prd.md` – FR7 (glitch sweep)
<!-- source: docs/specs/0.22.1/prd.md#fr7-glitch-sweep -->
<!-- extracted: e18cf85; FR7 gained the durable-backlog criterion after this extraction (uncommitted) -->
> **Description**: Close the 64 distinct defects catalogued in the audit. No design decisions required.
>
> **Acceptance Criteria**:
> - [ ] All 23 high-severity glitches closed.
> - [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
> - [ ] […elided: every deferral carried into a durable backlog, with its reason and no target milestone — the release-boundary hand-off S14 owns; this story's part is recording the deferral in its own Implementation Observations…]

### From `prd.md` – Binding constraint: canon-first
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.

### From `prd.md` – Binding constraint: no backend work
<!-- source: docs/specs/0.22.1/prd.md#constraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `prd.md` – Binding constraint: out of scope
<!-- source: docs/specs/0.22.1/prd.md#out-of-scope -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `prd.md` – Binding constraint: FR1 surface contrast
<!-- source: docs/specs/0.22.1/prd.md#fr1-surface--depth-revision -->
<!-- extracted: e18cf85 -->
> Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.

### From `prd.md` – Binding constraint: NFR Accessibility
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone

### From `prd.md` – Binding constraint: NFR Visual quality
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – the `global` (22) block's type, colour and container findings. Read each *Evidence* paragraph for the exact file:line inventory a task must absorb; read *Fix* for the shape the auditor validated.
- `docs/specs/0.22.1/fis/s02-canon-type-and-container-tiers.md` – the `.t-*` definitions, the `--text-lg` 16→18px rescale and the DESIGN.md typography table this story migrates onto; read before touching any `font-size`. S02 also raises canon `.topbar .session-title-static` and `.card-header` to the heading/page-title tiers — this story does not re-edit those rules.
- `docs/specs/0.22.1/fis/s04-canon-dialog-and-feedback-table.md#TI01` – the `--z-*` ladder TI08 consumes, its ascending order, and the `showModal()` top-layer exception the restart overlay cannot beat.
- `docs/specs/0.22.1/canon-hoist-manifest.md` – the authority for which canon rule belongs to which P1 story. It records `.section-title` as an S02 obligation completed before canon closes and authorizes this story's sole token-retirement exception; no other post-P1 canon family reopens.
- `docs/specs/0.22.1/fis/s16-global-sweep-shell-behaviour-states-formatting.md` – the behaviour half, which runs immediately after this story on the same `app.css`, `topbar.html` and `components.html`. Read its Execution Contract before editing those three files.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – capture and comparison procedure for the per-story visual gate.
- `../dartclaw-public/dev/testing/UI-SMOKE-TEST.md` – TC-01…TC-31; the badge and table cases exercise TI03, TI05 and TI06.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01,TI02,TI03,TI04] The product renders a legible type ladder and the 13px tier is gone**
  - **Given** the `visual` profile serving all 23 surfaces (`bash dev/testing/profiles/visual/run.sh`, port 3338) after S02 shipped `.t-caption` / `.t-body` / `.t-label` / `.t-heading` / `.t-page-title` / `.t-display` / `.t-metric`
  - **When** any dashboard page (`/health`, `/tasks`, `/workflows`) is rendered in either theme
  - **Then** the topbar page title computes to 20px/600 (`.t-page-title`) and every section heading to 18px/600 with 1.3 leading, so the largest text on the page is no longer the 14px body tier
  - **And** no computed `font-size` anywhere on the page is below 12px, and every uppercase micro-label carries `letter-spacing: 0.08em`
  - **And** `--text-sm` resolves to nothing — the token is absent from `tokens.css` and no rule references it — while no text run has lost its size to an unresolved `var()` fallback
  - **And** a dense table that overflows at the 14px body tier is recorded as a deviation for its owning surface story, never reverted to a 13px literal

- [x] **S02 [OC02] [TI05,TI06] Labels and badges that carry meaning meet WCAG AA in both themes**
  - **Given** `/health` (service card labels), `/tasks` (the CLAUDE provider badge on every row) and `/settings` in light theme, where the label tier measures 3.22:1 and `.provider-badge-codex` measures 2.13:1 today
  - **When** contrast is sampled on the rendered surfaces in both themes
  - **Then** every label, metadata field and table header measures ≥ 4.5:1 against the surface behind it, and `--fg-overlay` appears only on placeholder, disabled and helper text
  - **And** every app-local hue badge — `.provider-badge-*`, `.delivery-badge.*`, `.layer-badge--kg`, `.workflow-parallel-badge`, `.workflow-artifact-badge--*` — measures ≥ 4.5:1 in both themes and renders its status with a shape or label cue, not colour alone

- [x] **S03 [OC03] [TI07] The app-local card clones and the shared `infoCard` compose on canon `.card`**
  - **Given** the eight app-local card clones in `app.css` this story gives a baseline canon `.card` class and strips of clone surface declarations: `.heartbeat-card`, `.task-card-running`, `.task-chat-embed`, `.task-no-session`, `.task-review-bar`, `.agent-runner-card`, `.knowledge-summary-item`, `.knowledge-result-row` — `.metric-card` is the audit's ninth and is left to S15, which deletes it
  - **When** the scheduling heartbeat, task-detail rows and knowledge rows render
  - **Then** each container carries canon `.card`'s `--shadow-sm` and `--border-highlight` top edge and reads as raised, with the card-vs-ground contrast S01 fixed unchanged
  - **And** the shared `infoCard` fragment emits `.card-header` → `.card-body` → `.card-footer` with a canon `.status-badge`, not `.card-rows` + `.card-badge`
  - **And** S08 may later restructure the task rows, and S10 may later replace the knowledge-row semantics and remove their now-obsolete clone selectors; neither repeats this baseline adoption or clone-declaration deletion

- [x] **S04 [OC03] [TI08] Every app layer stacks from the canonical ladder**
  - **Given** `/settings`, whose sticky tab bar, open `.custom-select` and post-save restart overlay are three of the seven ad-hoc `z-index` literals in `app.css`
  - **When** a config save raises the restart overlay over an open custom select
  - **Then** every app layer that stacks — the composer palettes, the open `.custom-select`, the sticky settings tab bar, the sticky task review bar, the attribution popover and the restart overlay — resolves its `z-index` from a `--z-*` token in the ascending order S04's ladder fixed
  - **And** the restart overlay paints above the open select and below the toast container, and no bare integer ≥ 10 is left in `app.css`


## Structural Criteria

- [x] `dev/tools/fitness/check_design_system_sync.sh` exits 0 at the story boundary: `tokens.css`, `design-system.css` and `icons.css` are byte-identical to their canon sources with matching sha256 provenance headers.
- [x] `--text-sm` exists nowhere: S02 already left zero references in canon `components.css` / served `design-system.css`; this story clears `showcase.html`, `app.css`, templates and controllers, deletes the one alias from canon `tokens.css`, and re-syncs only served `tokens.css`.
- [x] Card-vs-ground contrast stays ≥ 1.15:1 in both themes after the eight card clones compose on canon `.card`; no surface, chrome or ground token is re-toned by this story.
- [x] `app.css` declares no bare `z-index` integer ≥ 10: every app-layer stacking value resolves from a `--z-*` token, and the only remaining literal is `.table-fade-wrap::after`'s component-local `1`.
- [x] No canon rule is authored by this story. The only drift-checked canon edit is deleting the `--text-sm` alias from `tokens.css`; `components.css` and `icons.css` are unchanged from story entry. `DESIGN.md` / `showcase.html` are non-drift-checked documentation/demo updates, not a reopened rule family.
- [x] After the final template/static change, `dart run dev/tools/embed_assets.dart` refreshes the tracked bundle before objective verification and `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` passes; no generated test is allowed red.


## Scope & Boundaries

### Work Areas
- `dev/design-system/` — `tokens.css` for the one `--text-sm` alias deletion; non-drift-checked `DESIGN.md` § Typography and `showcase.html` for remaining retirement prose/demo usages. `components.css` and `icons.css` are read-only: S02 already migrated all canon type consumers. Only served `tokens.css` is re-synced, followed by embedded regeneration/parity.
- `packages/dartclaw_server/lib/src/static/app.css` — the 79 `--text-sm` sites, the 82 `--fg-overlay` sites, the app-local hue-badge recipes, the six off-scale sizes, the five untracked uppercase labels, the clone surface declarations for eight of the nine card clones (`.metric-card` is S15's), and the six ad-hoc `z-index` literals plus the one deliberate survivor.
- The scheduling, task-detail and knowledge templates that emit `.heartbeat-card`, `.task-card-running`, `.task-chat-embed`, `.task-no-session`, `.task-review-bar`, `.agent-runner-card`, `.knowledge-summary-item` and `.knowledge-result-row` — add the baseline `.card` class only. S08 owns later task restructuring; S10 owns later semantic replacement and obsolete-selector cleanup.
- Shared Trellis/Dart fragments — `templates/topbar.html` (applying the `.t-page-title` class to the two static titles, nothing else) and `templates/components.html` + `components.dart` (the `infoCard` fragment only).

### What We're NOT Doing
- Shell behaviour, states, shared `pageHeader` / `emptyState` fragments, controllers, `helpers.dart` and data formatting -- S16 owns them and runs immediately after this story.
- Per-surface adoption and glitches -- S08–S12 and S15 own each surface's own template edits; this story stops at the scaffolding those surfaces inherit. They execute later in serialized waves W4–W9, after S16's W3 shared-behaviour pass.
- Authoring or editing any canon rule. S02 already migrated canon `--text-sm` consumers and completed `.section-title`'s heading-tier binding before canon closed; this story consumes both. Its sole drift-checked canon mutation is deleting the alias declaration from `tokens.css`, not changing a rule family.
- Applying `.t-heading` as a *class* to the five per-surface heading rules -- their markup lives in templates S08, S10 and S15 own. This story mirrors the tier's token values in the `app.css` rule instead (see TI02) and records the class conversion for the owning surface story.
- Renaming the `.text-sm` utility class or its 47 markup usages (`showcase.html` 30, `signal_pairing.html` 11, `whatsapp_pairing.html` 6). The class is repointed to `var(--text-base)` so it stops referencing a deleted token; the two pairing templates belong to S10, and the rename is recorded as a deferral.
- Composing `.metric-card` on canon `.card` or retiering `.metric-card .metric-label` (`app.css:590-595`) -- S15 deletes the family and re-renders its only consumer, `workflow_detail.html`, through `metricCardTemplate`.
- Adopting `.status-pill` in the tasks/scheduling STATUS columns and repointing the three divergent KPI-tile implementations -- those are per-surface template edits (S08–S11); this story only makes the app-local badge recipe AA-safe so the surfaces inherit a correct base.
- Writing the missing CSS for the 77 unstyled template classes, or adding a fitness check for orphan classes -- the load-bearing clusters belong to their surface stories, and a new check is tooling, not polish.
- Hand-editing `embedded_assets.g.dart` -- this story regenerates it only through `dart run dev/tools/embed_assets.dart` after its final embed-root change, then closes generated parity green.


## Architecture Decision

**Approach**: land the type, colour and stacking defects that all 23 surfaces inherit — the canon `--text-sm` call sites, `app.css`, and the shared card fragment — in W2 ahead of S16 W3 and the serialized W4–W9 surface sweeps, so those sweeps adopt shared shapes instead of each inventing one.
**Why this over alternatives**: letting each surface story fix its own copy of a global defect is precisely what produced the 232-finding audit (six page-header treatments, eight empty-state classes, four timestamp formats). This story executes alone in W2 and S16 alone in W3 because the two halves share `app.css`, `topbar.html` and `components.html`; the later surface stories then consume their accumulated output one wave at a time.


## Technical Overview


## Code Patterns & External References

```
# type | path#anchor or url                                                          | why needed (intent)
file   | dev/design-system/components.css#.t-heading                                 | The composite tiers TI01/TI02 migrate onto – apply the class where this story owns the markup, mirror its four token values only where it does not
file   | dev/design-system/components.css#.card                                       | shadow-sm + border-highlight + hover lift the eight clones must inherit rather than re-declare
file   | dev/design-system/components.css#.status-badge                               | The canon `color-mix(in srgb, var(--hue) 10%, var(--bg-base))` recipe TI06 rebases app badges on
file   | dev/design-system/components.css#.text-sm                                    | Read-only arrival check: S02 repointed this utility before canon closed; its 47 markup usages are not this story's
file   | packages/dartclaw_server/lib/src/static/tokens.css#--z-overlay               | The served copy of S04's `--z-*` ladder TI08 consumes; `app.css` resolves against this file, not canon
file   | packages/dartclaw_server/lib/src/templates/components.html#infoCard           | Shared card fragment TI07 re-shapes; `metricCard` beside it is the emit shape to match
file   | packages/dartclaw_server/lib/src/templates/topbar.html#pageTopbar             | The `.session-title-static` span (:38) TI02 classes; S16 later promotes the same element to `<h1>`
tool   | dev/tools/fitness/check_design_system_sync.sh                                 | The byte-identity + sha256 gate every canon edit must leave green
```


## Constraints & Gotchas

- **Critical**: `design-system.css` is a generated copy of `dev/design-system/components.css`. S02 must hand this story both files with zero `var(--text-sm)` references; if either still has one, stop and report the incomplete P1 handoff. S07 does not edit or re-sync either file.
- **Critical**: `--text-sm` currently resolves through S02's alias to `--text-base`. Deleting the token before the last consumer migrates makes `font-size: var(--text-sm)` invalid, and the declaration silently drops to the inherited size rather than erroring -- migrate every consumer (TI01–TI03) before TI04 deletes it. `showcase.html` is a consumer too (4 sites) even though it is not drift-checked.
- **Critical**: an undefined custom property fails the same silent way. `var(--z-overlay)` resolves to nothing if S04's ladder is not in the *served* `static/tokens.css`, and the `z-index` declaration is dropped rather than erroring — the layer then stacks by document order, which looks correct on a short page and breaks on a long one. Confirm the seven tokens are present in the served file before starting TI08.
- **Constraint**: `app.css` loads *after* `design-system.css` (`layout.html:16-17`), so equal-specificity app rules win. Deleting an `app.css` declaration exposes the canon rule underneath -- confirm what surfaces before assuming a deletion is inert.
- **Constraint**: canon rule families close after P1. This story's named exemption is narrower than a type-rule pass: delete the single `--text-sm` alias declaration from `tokens.css`, re-sync only served `tokens.css`, regenerate embedded assets and close parity green. `components.css` and `icons.css` are read-only. Anything else canon needs is reported for hoisting into S01–S04.
- **Avoid**: fixing a colour or contrast complaint by re-tuning a token. Per the shared surface decision, surface complaints go back to S01's tokens; this story's only sanctioned colour moves are retiering a class from `--fg-overlay` to `--fg-sub0` / `--fg-sub1` and rebasing an app-local badge onto the canon mix recipe.
- **Avoid**: editing a per-surface template to prove a shared fragment works. S08–S12 and S15 own those files in later serialized waves -- prove a fragment in its own render, and leave adoption to the owning surface story.
- **Handoff to S16**: S16 edits the same three shared files. It promotes `topbar.html`'s two static title spans to `<h1>` (keeping whatever class list this story leaves), adds the shared `pageHeader` / `emptyState` fragments beside `infoCard`, and collapses the eight bespoke empty-state classes in `app.css`. Two of this story's TI05 retierings — `.table-empty-cell` (:1126) and `.empty-state-text` (:1810) — are rules S16 subsequently folds into canon `.empty-state`; retier them anyway, because this story's gate runs at its own boundary and a half-migrated `--fg-overlay` set is what the sweep stories would otherwise inherit.


## Implementation Plan

### Implementation Tasks

Before TI01, capture the four drift-checked files this story must not change:

```sh
BASE=.agent_temp/0.22.1-s07-entry
rm -rf "$BASE"
mkdir -p "$BASE/dev" "$BASE/static"
cp dev/design-system/components.css dev/design-system/icons.css "$BASE/dev/"
cp packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/icons.css "$BASE/static/"
```

- [x] **TI01** Every remaining app/demo `--text-sm` consumer resolves through a composite tier
  - Arrival gate: `rg -n 'var\(--text-sm\)' dev/design-system/components.css packages/dartclaw_server/lib/src/static/design-system.css` must return no matches. S02 owns those canon migrations; a match is an incomplete P1 handoff and stops this task rather than licensing a `components.css` edit.
  - Move the 79 `var(--text-sm)` references in `packages/dartclaw_server/lib/src/static/app.css` to composite classes or `var(--text-base)` where the rule is a genuine one-off; apply `.t-*` classes in markup this story owns. `showcase.html`'s four non-drift-checked demo usages move too. Follow `dev/design-system/components.css#.t-body` without editing that file.
  - **Boundary**: the `.text-sm` utility class was repointed by S02, not here, and is not deleted — it has 47 live markup usages, 17 of them in `signal_pairing.html` / `whatsapp_pairing.html`, which are S10's templates. Record the rename as a deferral in Implementation Observations rather than editing S10's markup.
  - **Verify**: `rg -c 'var\(--text-sm\)' packages/dartclaw_server/lib/src/static/app.css dev/design-system/showcase.html` prints nothing and exits 1; the canon/served arrival grep still returns no matches; rendered `.data-table` cells, sidebar items and card bodies measure 14px in both themes with no run left at 13px

- [x] **TI02** Shared shell, page and card scaffolding renders the composite type ladder
  - `templates/topbar.html`'s two static titles — `pageTopbar`'s `<span class="session-title-static">` (:38) and `plainTopbar`'s `<span class="session-title">` (:26) — gain `t-page-title` in their class list. Canon's own `.topbar .session-title-static` tier is S02's and is not re-edited here.
  - The five section-heading rules that reach only through a per-surface element selector — `app.css#.task-status-group h3` (:1610), `#.task-chat-column h3, .task-artifact-column h3` (:1848), `#.agent-overview h3` (:2068), `#.channel-sub-card h3` (:1433) and `#.workflow-step-detail-content h4` (:2602) — cannot take a class from this story, because their markup is in templates S08, S10 and S15 own. They instead mirror `.t-heading`'s four token values (`var(--text-lg)` / `var(--weight-bold)` / `var(--leading-tight)` / `var(--tracking-tight)`), which is the precedent S02 set for canon `.card-header` and `.topbar .session-title-static` when a class could not be applied. Record each one for its surface story to convert to a `.t-heading` class.
  - **Ownership**: canon `.section-title` (`components.css:1541`) is the sixth heading rule and is canon-owned type work. S02 already completes its full `.t-heading` binding before canon closes; this story verifies and consumes it, with no hoist request or canon edit left open.
  - Consumes TI01's migrated call sites.
  - **Verify**: `rg -n 't-page-title' packages/dartclaw_server/lib/src/templates/topbar.html` returns the two title elements (returns nothing today); `rg -nU --multiline-dotall '(\.task-status-group h3|\.agent-overview h3|\.task-chat-column h3|\.channel-sub-card h3|\.workflow-step-detail-content h4)[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg -c 'line-height'` prints `5` — it prints nothing and exits 1 today, because none of the five declares one; served `.section-title` computes to 18px/600 with 1.3 leading and tight tracking; on `/health` and `/tasks` the topbar title computes to 20px/600 and every section heading to 18px/600 with `line-height` 1.3

- [x] **TI03** No off-scale type remains and every uppercase micro-label is tracked
  - The six sub-floor sizes in `app.css` (`.channel-mode-badge` 0.625rem:1415, `.provider-badge` 0.625rem:1782, `.task-event` 11px:2259, `.task-event-icon` 10px:2264, `.workflow-artifact-badge` 10px:2631) rise to `var(--text-xs)` and the hardcoded 13px `.workflow-step-icon` (:2516) to a token; compensate density with padding, not size. `.layer-badge`, `.knowledge-summary-label`, `.unverified-flag`, `.kg-timeline-controls .field-label` and `.guard-editor-table th` gain `letter-spacing: var(--tracking-caps)`.
  - **Ownership**: per the plan's `Shared-surface ownership in the sweep phase` decision, this task is the **sole** owner of off-scale font-size normalization across the whole app. All six sites are listed above and none is shared with a sweep story: S08 keeps only its `.provider-badge` `margin-left` removal, S10 only its `.channel-mode-badge` semantics, S12 only its shell-side `.provider-badge` semantics, S15 only its `.workflow-artifact-badge` / `.workflow-step-icon` block work — none of them re-declares a `font-size` on these rules. A sweep story that finds an off-scale size this task missed reports it rather than fixing it locally.
  - **Verify**: `rg -n 'font-size:\s*(0\.(6|7)[0-9]*rem|1[01]px|13px)' packages/dartclaw_server/lib/src/static/app.css` returns no matches (it returns exactly the six lines 1415, 1782, 2259, 2264, 2516 and 2631 today, so a single missed site fails it); the five named uppercase rules each declare `var(--tracking-caps)`, and the CLAUDE provider badge renders at 12px

- [x] **TI04** `--text-sm` no longer exists under the one token-only canon exception
  - Delete the migration alias from `dev/design-system/tokens.css` (:72), drop its remaining mention from DESIGN.md § Typography and the § Code prose at DESIGN.md:772, and delete the retired `text-sm` specimen row from `showcase.html` (:211). Re-sync **only** `packages/dartclaw_server/lib/src/static/tokens.css` with a regenerated provenance header. Do not touch canon/served `components.css` or `icons.css`: S02 already left the component pair free of references, and no other canon family reopens. After the final static change run `dart run dev/tools/embed_assets.dart`, then the generated parity test. Runs after TI01–TI03; this settles success metric 2.
  - **Verify**: `rg -n -e '--text-sm' dev/design-system/ packages/dartclaw_server/lib/src/` returns no matches; with `BASE=.agent_temp/0.22.1-s07-entry`, `cmp -s "$BASE/dev/components.css" dev/design-system/components.css && cmp -s "$BASE/dev/icons.css" dev/design-system/icons.css && cmp -s "$BASE/static/design-system.css" packages/dartclaw_server/lib/src/static/design-system.css && cmp -s "$BASE/static/icons.css" packages/dartclaw_server/lib/src/static/icons.css` exits 0; `bash dev/tools/fitness/check_design_system_sync.sh` exits 0; `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` passes

- [x] **TI05** `--fg-overlay` is reserved for placeholder, disabled and helper text
  - The label and copy classes DESIGN.md forbids it for move tier: `app.css#.detail-label` (:563), `#.card-row-label` (:583), `#.meter-label` (:1041), `#.tab-meta-label` (:1084), `#.table-empty-cell` (:1126), `#.info-subtitle` (:432), `#.settings-header p` (:489), `#.metric-sub-inline` (:1038), `#.error-code` (:313) to `--fg-sub0`; `#.empty-state-text` (:1810) to `--fg-sub1` and `#.empty-state-title` (:1809, already `--fg-sub0`) to `--fg`. `.metric-card .metric-label` (:595) is deliberately **not** retiered — S15 deletes the whole `.metric-card` family (`app.css:590-595`) and re-renders its only consumer through `metricCardTemplate`. Measure after S01's remap, not against the pre-0.22.1 values.
  - **Verify**: `rg -nU --multiline-dotall '(^\.detail-label|^\.card-row-label|^\.meter-label|^\.tab-meta-label|^\.table-empty-cell|^\.info-subtitle|^\.settings-header p|^\.metric-sub-inline|^\.error-code|^\.empty-state-text|^\.empty-state-title)[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg 'fg-overlay'` returns no matches — it returns exactly 10 lines today (313, 432, 489, 563, 583, 1038, 1041, 1084, 1126, 1810), so one missed rule fails it; on `/health`, `/task-detail` and `/settings` in **light** theme every label and metadata run measures ≥ 4.5:1 against the surface behind it (they measure 3.22:1 on cards today); any surviving `--fg-overlay` consumer elsewhere in `app.css` that is neither placeholder, disabled nor helper text is recorded in Implementation Observations for its owning surface story rather than retiered here

- [x] **TI06** App-local hue badges use the canon contrast recipe
  - `.provider-badge-claude` (:1789), `.provider-badge-codex` (:1793), `.delivery-badge.announce` (:646), `.delivery-badge.webhook` (:647), `.layer-badge--kg` (:3033), `.workflow-parallel-badge` (:2582) and all four `.workflow-artifact-badge--*` variants (`--diff` :2639, `--document` :2644, `--data` :2649, `--pr` :2654 — the `--pr` variant is the one the audit's site list omits) rebase on `color-mix(in srgb, var(--hue) 10%, var(--bg-base))` with `border-color: color-mix(in srgb, var(--hue) 22%, var(--bg-surface1))` — reusing `dev/design-system/components.css#.status-badge` rather than re-declaring it.
  - **Boundary**: `app.css:1837` is `.task-meta-warning`, a padded warning panel rather than a badge, and keeps its own fill. Record the disposition so it does not read as a missed site. `.layer-badge--kg` already blends against `--bg-base` and needs only the contrast re-measure, not a base change.
  - **Verify**: `rg -nU --multiline-dotall '(^\.provider-badge-claude|^\.provider-badge-codex|^\.layer-badge--kg|^\.workflow-parallel-badge|^\.workflow-artifact-badge--|^\.delivery-badge\.announce|^\.delivery-badge\.webhook)[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg 'var\(--bg-surface0\)'` returns no matches — it returns exactly 9 lines today (646, 647, 1790, 1794, 2591, 2640, 2645, 2650, 2655), so one missed variant fails it; every rebased badge measures ≥ 4.5:1 in both themes (`.provider-badge-codex` is 2.13:1 light today)

- [x] **TI07** The app-local card clones adopt canon `.card`, their clone surface declarations are deleted, and the shared `infoCard` uses canon anatomy
  - Add the baseline `.card` class to each existing scheduling, task-detail and knowledge clone row: `.heartbeat-card`, `.task-card-running`, `.task-chat-embed`, `.task-no-session`, `.task-review-bar`, `.agent-runner-card`, `.knowledge-summary-item` and `.knowledge-result-row`. Delete each clone's `background`, `border`, `border-radius` and clone-owned shadow declarations from `app.css`; retain only layout declarations, so `--shadow-sm` and `--border-highlight` come from `dev/design-system/components.css#.card`. `.metric-card` (:590) is the ninth clone in the audit's list and is deliberately excluded: S15 deletes the family outright, so composing it on canon here is work S15 discards. S08 consumes the task rows' baseline for later task restructuring; S10 consumes the knowledge rows' baseline for semantic replacement and obsolete-selector cleanup, rather than repeating these declaration deletions.
  - `templates/components.html#infoCard` wraps its rows in `.card-body`, moves the badge to `.card-footer`, and emits `.status-badge` + `.status-badge-{variant}` instead of `.card-badge`.
  - **Verify**: every named clone row has `.card` in its emitted class list; its `app.css` clone block contains none of `background`, `border`, `border-radius` or `box-shadow`; `rg -n 'card-badge|card-rows' packages/dartclaw_server/lib/src/templates/components.html` returns no matches (it returns :34 and :36 today); on `/scheduling`, task detail and `/knowledge` each container's first pixel row shows the `--border-highlight` tone and a measurable `--shadow-sm` band, with card-vs-ground contrast still ≥ 1.15:1 in both themes.

- [x] **TI08** The app's ad-hoc stacking literals resolve from the canonical `--z-*` ladder
  - S04 ships `--z-base` / `--z-sticky` / `--z-scrim` / `--z-sidebar` / `--z-dropdown` / `--z-overlay` / `--z-toast` in ascending order into canon `tokens.css` and adopts them in canon's own rules, but is a canon-only story with no app-side consumer; this task is that consumer. Five of the seven literals take a tier by role: `.composer-palette` / `.composer-reference-palette` (:12, `20`), `.custom-select[data-open="true"]` (:855, `30`) and `.attribution-popover` (:3228, `30`) are transient layers over page content → `var(--z-dropdown)`; `.settings-tabs` (:1176, `10`) and `.task-review-bar` (:1905, `10`) are sticky chrome inside the content column → `var(--z-sticky)`. Adds no rule to canon — the ladder already exists.
  - `.restart-overlay` (:2008, `9999`) is the sixth and the outlier, and gets a **deliberate** tier, not a mechanical swap: it is a full-viewport scrim built as a plain `<div>` by `dc_shell_controller.js:501-508`, so it takes `var(--z-overlay)` — above every dropdown, the sidebar and the mobile scrim, and below `--z-toast` so a restart-failure toast stays readable over it. It does **not** cover an open `.dialog`: every dialog in the app opens with `showModal()`, which promotes it into the browser top layer that no `z-index` beats (S04's Critical gotcha), and `9999` does not beat it today either — so this is a like-for-like outcome, not a regression. Record it in Implementation Observations as a known limitation of the overlay-over-modal case rather than raising a literal that cannot fix it.
  - `.table-fade-wrap::after` (:638, `1`) is the seventh literal and stays literal: it stacks only against its own table wrapper, which is exactly the component-local micro-stacking S04 excludes from the ladder (alongside the film-grain `-1` and `.pipeline-node`'s `1`). Record the disposition so it does not read as a missed site.
  - **Verify**: `rg -n 'z-index:\s*(1[0-9]|[2-9][0-9]|[0-9]{3,})' packages/dartclaw_server/lib/src/static/app.css` returns no matches — it returns lines 12, 855, 1176, 1905, 2008 and 3228 today, so any missed site fails it; `rg -c 'z-index:\s*var\(--z-' packages/dartclaw_server/lib/src/static/app.css` prints `6` (it prints nothing and exits 1 today); and because a token *name* is not a resolved value, confirm in the browser on `/settings` that `getComputedStyle` reports `.restart-overlay`'s `z-index` strictly greater than the open `.custom-select`'s and strictly less than `.toast-container`'s, with the restart overlay visually covering an open custom-select dropdown
  - **Depends on**: S04's `--z-*` tokens being live in the *served* copy — verify with `rg -n '^\s*--z-(base|sticky|scrim|sidebar|dropdown|overlay|toast):' packages/dartclaw_server/lib/src/static/tokens.css`, which must list all seven and returns nothing today, before starting. `app.css` reads the served file, not canon, so an unsynced ladder resolves to nothing and silently drops the declaration. If the ladder is absent, stop and report it rather than adding it — canon is closed after P1.

### Testing Strategy

- This story is entirely CSS and shared-fragment markup — there is no Dart or browser-runtime behaviour in it, and no new test suite. The per-task Verify greps prove the change landed; the visual gate below proves it looks right. The story's two pure-Dart units moved to S16 with the formatting tasks.
- Contrast is the one outcome a grep cannot prove: every run whose size or colour changed is re-measured in the browser in both themes, per Validation.

### Validation

- Validate against the `visual` testing profile (`bash dev/testing/profiles/visual/run.sh`, port 3338 — the only profile rendering all 23 surfaces) in **both** themes at desktop 1440×900 (matching the audit baseline capture) and 768px, comparing against this story's own story-start captures per the plan's visual-baseline protocol.
- Re-check WCAG AA text contrast on every run whose size or colour changed — the migrated `--text-sm` sites, the retiered `--fg-overlay` labels, and every rebased badge — in both themes.
- Any dense table that overflows at the 14px body tier is recorded in Implementation Observations for its owning surface story (S08–S12, S15) as a deviation, per S02's edge-case protocol; it is never reverted to a 13px literal.

### Execution Contract

- TI04 must run after TI01, TI02 and TI03. Its canon mutation is exactly one declaration deletion in `tokens.css`; sync only served `tokens.css`, then regenerate embedded assets and close parity green. Any `components.css` or `icons.css` delta violates the exception.
- TI08 has no ordering dependency inside this story, but it consumes S04's `--z-*` ladder from the served `static/tokens.css`. Run its presence check first; if the ladder is missing, TI08 stops and reports rather than adding the tokens — canon is closed after P1.
- This story executes in W2 and must leave `check_design_system_sync.sh` and generated parity green before S16 W3 starts. After TI08's final embed-root change, run `dart run dev/tools/embed_assets.dart` before objective verification, then run `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart`; re-run both after any remediation that changes an embed root.


## Final Validation Checklist

- [x] No file outside this story's Work Areas is modified: `dev/design-system/`, `packages/dartclaw_server/lib/src/static/`, the three shared fragments (`templates/topbar.html`, `templates/components.html`, `templates/components.dart`), the three clone-row templates TI07 requires a baseline `.card` class in (`templates/scheduling.html`, `templates/task_detail.html`, `templates/knowledge_hub.html` — class-list additions only), `templates/health_dashboard.dart` (sole repo-wide caller of the `infoCardTemplate` signature TI07 changes; the rename does not compile without it), the generated `lib/src/generated/embedded_assets.g.dart` (regenerated only via `dart run dev/tools/embed_assets.dart`), and `test/templates/health_dashboard_test.dart` (assertions tightened onto the reshaped fragment). No controller, service, schema, route or API change.
- [x] No per-surface template owned by S08–S12 or S15 is edited beyond the two adoptions TI07 mandates: the baseline `.card` class on the eight clone rows, and the `infoCardTemplate` caller update in `templates/health_dashboard.dart` (S09's surface) forced by the `badgeClass` → `variant` rename. Both are recorded in Implementation Observations as boundary crossings; `restart_banner.html` is left untouched for S12.
- [x] `dart run dev/tools/embed_assets.dart` ran after the final embed-root change; `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` and the full declared gate set are green, and both generated asset files remain tracked.
- [x] S02's `.section-title` handoff is closed on arrival: served `.section-title` has the complete heading-tier binding, and this story records no post-P1 canon request for it. The S07 entry-snapshot `cmp` proves `components.css`, `icons.css` and their served copies stayed unchanged.
- [x] The dispositions this story records rather than fixes — the `.text-sm` utility rename, `app.css:1837` `.task-meta-warning` as not-a-badge, `.table-fade-wrap::after`'s surviving literal, and the restart-overlay-over-modal limitation — are in Implementation Observations – the preferred write-back location; S14's ledger sweep reads the whole canonical FIS as a safety net, but a prose-only deferral relies on that net rather than the supported path.


## Implementation Observations

### Run: 2026-07-29 22:37 UTC – observations

#### DECISIONS RECORDED

- **Restart-overlay stacking tier — `var(--z-overlay)` (30), deliberately below `--z-toast` (100).** `.restart-overlay` (`app.css`) moved off its `9999` literal. The old literal beat the toast container; the token does not, so a restart-failure toast now paints over the blocker. Chosen deliberately: canon's own token comments assign the tier (`--z-overlay` = "Skip link, full-screen blockers, non-modal floats"; `--z-toast` = "Top of the ladder — no other tier is above it"), and the overlay carries its own `#restart-status` line for normal progress, so the toast channel is only needed when the restart fails — exactly the case that must stay readable. Verified in-browser: open `.custom-select` 25 < `.restart-overlay` 30 < `.toast-container` 100.
- **Restart-overlay-over-modal is a known limitation, unchanged by this story.** Every dialog opens with `showModal()`, which promotes it into the browser top layer that no `z-index` beats. `9999` did not beat it either, so this is like-for-like, not a regression. Not fixable with a stacking value.
- **`.channel-sub-card h3` — heading tier applied, uppercase label treatment removed.** TI02 lists this among the five heading rules, but it arrived styled as an uppercase micro-label (`text-transform: uppercase` + `--tracking-caps` + `--fg-sub0` at the body size). Its markup is genuine sentence-case heading text ("Pending Pairing Requests", "Known DM Allowlist", "Allowed Groups", "Mention Gating", "Task Trigger" — `channel_detail.html:74, 98, 162, 194, 206`), so it is a section heading, not a label. Applying `.t-heading`'s four values *and keeping* uppercase would have produced an 18px bold muted uppercase run louder than the body it labels — inverting the hierarchy OC01 exists to create — and DESIGN.md § Typography forbids `--tracking-tight` on uppercase. Resolution: the rule now takes `.t-heading`'s four token values exactly (incl. `--tracking-tight`) and drops `text-transform: uppercase`. Colour left at `--fg-sub0` (deliberate sub-card de-emphasis; measures 7.37:1 dark / 5.59:1 light on card). **S10 owns `channel_detail.html`** — the six sub-card headings now render sentence case rather than caps.

#### HOIST REQUEST TO S01 — light-theme brand/teal token luminance (blocks Acceptance Scenario S02)

TI06 rebased every named app-local hue badge onto canon `.status-badge`'s recipe. That closed the gap for every badge whose hue token is dark enough, but **three scenario-named badges still miss WCAG AA in light theme**, and the cause is the hue token itself, not the recipe:

| Badge | Light | Dark | Hue token (light) | Token raw on white card |
|---|---|---|---|---|
| `.provider-badge-claude` | **3.12:1** | 4.86:1 | `--brand-claude` `#c05d35` | 4.32:1 |
| `.provider-badge-codex` | **2.73:1** | 8.71:1 | `--brand-codex` → `--teal` `#179299` | 3.74:1 |
| `.layer-badge--kg` | **2.73:1** | 8.71:1 | `--teal` `#179299` | 3.74:1 |

Proof this is token-level, not recipe-level: canon's own `.status-badge-{success,error,warning,info,running,muted}` all **pass** light theme (4.76–5.36:1) on the identical recipe, because `--success`/`--error`/`--warning`/`--info` measure 7.02–7.90:1 raw on the white card. The three failures sit on tokens already at or below the AA floor *before* any tint is applied — no mix ratio can rescue them.

`tokens.css` already ships darker light-theme variants (`--teal: #179299` vs dark `#94e2d5`; `--brand-claude: #c05d35` vs `#e07c4f`); they need to go one step darker still to clear 4.5:1 at the 12px badge size. **This story cannot fix it**: canon closed after P1, S07's only sanctioned canon edit is the `--text-sm` deletion, and the FIS explicitly forbids resolving a contrast complaint by re-tuning a token ("surface complaints go back to S01's tokens"). Routed to S01 as the token owner. **Acceptance Scenario S02's "in both themes" clause is therefore NOT closed by this story.**

Adjacent, not scenario-named, same root cause — recorded so they are not re-discovered: `.channel-mode-badge` 3.69:1 light (`--accent` on `--bg-surface0`, never rebased — outside TI06's site list) and the neutral `.delivery-badge` base 3.62:1 light (`--fg-sub0` on `--bg-surface0`, pre-existing).

#### DEFERRALS AND DISPOSITIONS

- **`.text-sm` utility rename — deferred, no target milestone.** S02 repointed the class to `var(--text-base)`, so its name is misleading but it references no deleted token. Not renamed here: 62 live markup usages (`dev/design-system/showcase.html` 44, `signal_pairing.html` 11, `whatsapp_pairing.html` 6 — the two pairing templates are S10's). The FIS's "47 usages (showcase 30)" count is pre-S02 and stale.
- **`.task-meta-warning` (`app.css:1699`) is not a badge.** A padded warning *panel* (`padding: var(--sp-3)`, own border and fill). Deliberately excluded from TI06's rebase; keeps its own fill. Recorded so it does not read as a missed site.
- **`.table-fade-wrap::after` keeps its `z-index: 1` literal** (`app.css:641`, inside the ≤768px block). Component-local micro-stacking against its own table wrapper, which S04's ladder explicitly excludes. Sole surviving literal in `app.css`.
- **Five per-surface heading rules mirror `.t-heading`'s tokens and still need a class conversion** by their owning surface story, since their markup is not S07's: `.task-status-group h3` and `.task-chat-column h3, .task-artifact-column h3` (**S08**), `.agent-overview h3` (**S08**), `.channel-sub-card h3` (**S10**), `.workflow-step-detail-content h4` (**S15**). Each should become a `.t-heading` class when its template is next edited.
- **Dense-table overflow deviations: none observed.** No table was reverted to a 13px literal; the `--text-sm` → `--text-base` swap was pixel-identical by construction (`--text-sm` was defined as `var(--text-base)`), so no table changed width. FR3's mid-word table-header wrapping remains open for S08, untouched here.

#### BOUNDARY CROSSINGS

- **`templates/health_dashboard.dart` edited — S09's surface.** TI07 renames `infoCardTemplate`'s `badgeClass` parameter to `variant` (the fragment now emits `status-badge-{variant}`). `health_dashboard.dart` is the sole caller repo-wide, so the rename does not compile without updating it; the edit is confined to the `badge-success`→`success` style value mapping and the call site. Minimal and contract-forced, but it is outside the FIS's Final Validation item 1 file list.
- **`.workflow-step-detail-content h4` colour retiered `--fg-overlay` → `--fg` — S15's surface.** Not on TI05's list. TI02 promotes this rule to the 18px bold heading tier, which would otherwise have left a section heading rendering at the placeholder-text tier — a self-inflicted AA defect created by this story's own change. Retiered to match the other four heading rules in the same task. Flagged for S15 to confirm.
- **FIS Final Validation item 1 is internally inconsistent with TI07 and Work Areas.** Item 1 permits only `dev/design-system/`, `static/` and three shared fragments, but Work Areas and TI07 explicitly require adding the baseline `.card` class to the scheduling, task-detail and knowledge templates, and Structural Criteria requires regenerating `embedded_assets.g.dart`. Item 1 is the stale artifact; the template edits are class-list additions only (`scheduling.html:8`, `task_detail.html:117/137/197`, `knowledge_hub.html:36/47`). `restart_banner.html` untouched.

#### VERIFY RE-TARGETS (FIS line numbers and counts were stale on arrival)

- **TI08 expects `rg -c 'z-index:\s*var\(--z-'` to print `6`; it prints `5`.** `.settings-tabs` no longer exists in `app.css` — `settings.html:13` now renders canon `.tabs.tabs--sticky`, which already resolves `z-index: var(--z-sticky)`. Six literals existed at story entry, not seven; five were tokenized and one (`.table-fade-wrap::after`) deliberately survives. The sticky settings tab bar named in Acceptance Scenario S04 is satisfied through canon, not through an `app.css` rule.
- **TI01 cites 79 `var(--text-sm)` sites in `app.css`; 72 were present at story entry.** The 79 figure predates S05/S06's edits to the same file. All 72 migrated; zero remain repo-wide.
- Every `app.css` line number in the FIS was stale by the time this story ran (S05/S06 shifted the file). All targets were re-inventoried by selector rather than by line.

#### NOTICED BUT NOT TOUCHING

- **Canon `.card` has no flat opt-out, so three non-affordance containers now animate on hover.** `.card:hover` (accent border, `--shadow-md` + glow, radial-gradient repaint, `translate: 0 -1px`) now fires on `.task-chat-embed` (a `max-height: 500px; overflow-y: auto` scroll container — every pointer entry to read the log lifts it) and `.task-review-bar` (`position: sticky; bottom: 0`, `fixed` below 768px). Baseline `.card` adoption is what TI07 requires and canon ships no `.card--flat`; adding one would reopen a closed canon family. Routed to **S08** (task surface) — either a canon flat variant hoisted to a P1 story, or a local `:hover` neutralization.
- **`.card-tint-*` classes were dead and are now live on `/tasks`.** Deleting `.task-card-running`'s `background` un-shadows `tl:classappend="${task.cardTintClass}"` (`tasks.html:37`); the canon `.card-tint-*` rules previously lost to app.css's later same-specificity `background`. Running task cards now render their intended accent tint. Presumed correct, but it is a visual change on **S08**'s surface that no task in this story asked for.
- **`.task-card-running:hover` needed an explicit `border-left-color` restatement.** Canon `.card:hover` sets the `border-color` *shorthand* (specificity 0,2,0), which repaints all four edges and beat the deliberately-retained `border-left: 3px solid var(--success)` running-state accent (0,1,0). Pre-existing (the element already carried `.card` before this story), but surfaced by TI07's clone-declaration deletion, so it is restated locally rather than left broken.
- **TI05's stated premise is stale post-S01, and two rules now sit 0.02 over the AA floor.** TI05 justifies the retiering with "they measure 3.22:1 on cards today". After S01's remap, light `--fg-overlay` `#585d6f` measures 6.54:1 on `--bg-card` and `--fg-sub0` `#62677d` measures 5.59:1 — so in light theme the nine retierings slightly *reduce* contrast. The move is still correct on semantics (`--fg-overlay` is reserved for placeholder/disabled/helper text, which none of these ten are) and dark theme improves (6.57 → 7.37). But `.table-empty-cell`, `.meter-label`, `.tab-meta-label` and `.detail-label` land at **4.52:1 against the page ground** — 0.02 above the 4.5 floor. Any future ground re-tone breaks AA on all four. Flagged for S01/S14.
- **65 `--fg-overlay` consumers survive in `app.css`.** Most are legitimately placeholder, disabled, decorative or helper text. Ones that look like labels/metadata and belong to a surface story: `.guard-config-section-label` (:523) and `.pagination-info` (:566) → S12; `.cron-expr` (:646), `.cron-preview`, `.cron-human` → S11; `.info-footer` (:650) → S12; `.task-artifact-empty` → S08; `.workflow-card-steps` → S15. `.metric-card .metric-label` is deliberately left for S15 to delete with the whole family.
- **`.empty-state-title` needed no S07 edit.** TI05 lists it as "`--fg-sub0` → `--fg`", but no `app.css` rule exists; canon `design-system.css:1778` already declares `.empty-state-title { color: var(--fg); }`. Closed upstream by S05.
- **`infoCard` row rhythm required one new app-local rule.** Canon `.card-body` is typography-only (`font-size` + `color`), while the retired `.card-rows` supplied `display: flex; gap: var(--sp-2)`. Added `.card-body > .card-row + .card-row { margin-top: var(--sp-2) }` so the reshaped fragment keeps its 8px rhythm. Scoped with `>` to `.card-body` so it cannot double up with the surviving `.card-rows` consumers (`health_dashboard.html:22`, `memory_dashboard.html:64/:122`), which are flex containers with their own `gap`.
- **`.card-badge` and `.card-rows` are not orphaned by the `infoCard` reshape.** Still consumed by `kg_timeline.html` (:35, :47, :56, :57), `memory_dashboard.html` (:62, :64, :120, :122, :254) and `health_dashboard.html` (:22). Their `app.css` rules are deliberately retained for those owners.

### Run: 2026-07-29 22:46 UTC – observations

#### CORRECTION — the S01 hoist request in the preceding block is RESOLVED; Acceptance Scenario S02 is closed

The preceding `### Run:` block recorded three badges failing WCAG AA in light theme and routed a hoist request to S01. **That measurement was taken against a stale browser cache of `/static/v0.22.0/tokens.css` and no longer reflects the tree.** While this story was executing, S01 darkened exactly the two light-theme tokens involved:

- `--teal: #179299` → `#0d686d` (`--brand-codex` follows it)
- `--brand-claude: #c05d35` → `#954727`

S01's own token comment names this story's consumers as the reason: *"`--teal` and `--brand-claude` are held darker than that would ask for: they are the only two that render as badge TEXT, and the provider and layer badges tint them into the ground, which costs ~1.5:1 of contrast."*

Re-measured after a cache-bypassing reload, with colour resolution through a canvas (which normalizes `oklab()` / `color(srgb …)` / `color-mix()` — a naive `rgb()`-only parser silently misreads all three and was the source of the bad numbers):

| Badge | Light | Dark |
|---|---|---|
| `.provider-badge-claude` | **4.61** | 4.89 |
| `.provider-badge-codex` | **4.59** | 8.67 |
| `.layer-badge--kg` | **4.59** | 8.67 |
| `.delivery-badge.announce` | 5.12 | 6.44 |
| `.delivery-badge.webhook` | 5.04 | 7.52 |
| `.workflow-parallel-badge` | 5.12 | 6.44 |
| `.workflow-artifact-badge--diff` | 5.12 | 6.44 |
| `.workflow-artifact-badge--document` | 4.77 | 8.49 |
| `.workflow-artifact-badge--data` | 4.93 | 8.71 |
| `.workflow-artifact-badge--pr` | 4.93 | 8.71 |

**Every badge named in Acceptance Scenario S02 now clears 4.5:1 in both themes.** No hoist to S01 is outstanding; ledger entry `S07-AA-BADGE-TOKENS` is reconciled. The three light-theme values sit 0.09–0.11 above the floor, so any future re-tone of `--bg-card`, `--bg-base` or these two hues must re-measure the badges.

Still below AA in light theme, both **outside** Acceptance Scenario S02's named set and both pre-existing (neither was rebased by TI06): `.channel-mode-badge` 3.69 (`--accent` tinted into `--bg-surface0`; not in TI06's site list) and the neutral `.delivery-badge` base 3.62 (`--fg-sub0` on `--bg-surface0`). `.unverified-flag` now measures 4.89 and passes.

#### CANON DEFECT FOUND — `tokens.css` stacking-order comment is malformed and silently drops `--z-base`

Not this story's change and **not fixed here** (canon is closed to S07 apart from the `--text-sm` deletion, and this text belongs to S04's uncommitted ladder work — it is absent from `HEAD`).

`dev/design-system/tokens.css` § Stacking order opens a comment, **closes it** at `… what that costs a toast. */`, and then leaves four lines of prose terminated by a second, unmatched `*/`:

```
     See DESIGN.md § Elevation & Depth for what that costs a toast. */
     Each comment states the ROLE the tier is for, not an inventory of what
     … Read a row as "what belongs here", not "what is here". */
  --z-base:     0;    /* In-flow content */
```

Those four lines are raw content inside `:root { }`. The CSS parser treats them as a malformed declaration and discards input up to the next `;` — which is the one ending `--z-base: 0`. Verified in-browser: `getPropertyValue('--z-base')` returns **empty**, while `--z-sticky` … `--z-toast` all resolve. Confirmed identically in the served copy, since the sync is a verbatim byte copy.

Impact today is nil — `var(--z-base)` has zero consumers in `dev/design-system/` or `packages/dartclaw_server/lib/src/static/` — so TI08's ladder migration is unaffected (it consumes `--z-sticky`, `--z-dropdown` and `--z-overlay`, all of which resolve). But the token is unusable by the first consumer that reaches for it, and **`check_design_system_sync.sh` cannot catch this**: it compares canon and served byte-for-byte and never parses the CSS, so a syntax error stays green forever. Fix is deleting the stray `*/` on the last prose line (one character). Routed to **S04** as the ladder's author, or to S14's release gate.

#### VERIFY RE-TARGET — card-vs-ground contrast measured, criterion met

Structural criterion "card-vs-ground ≥ 1.15:1 in both themes" verified after the eight clones composed on canon `.card`: **1.200:1 dark** (ground `#1e1e2e` → card `#2c2c3e`) and **1.237:1 light** (ground `#e4e7ef` → card `#ffffff`). All eight clones measure byte-identical to a bare canon `.card` in both themes, which is the positive proof that every clone surface declaration was removed and canon alone now paints them. No surface, chrome or ground token was re-toned by this story.

### Run: 2026-07-29 23:03 UTC – observations

#### SPEC AMENDMENT — Final Validation checklist items 1–2 rewritten to the verified as-built delta

Closes ledger entry `S07-FINAL-CHECKLIST-FILE-LIST`. Applied identically to the public bundle copy and the private canonical copy.

**Tooling note on the write path.** This amendment was applied as a direct edit plus this audit record, *not* through `andthen:ops update-fis … design-change`. That form is scoped to "the FIS Intent and/or Acceptance Scenario text only" and explicitly must not edit "task checkboxes, Structural Criteria, plan provenance, or Implementation Observations"; the Final Validation Checklist is outside its writable region, and its body contract additionally requires `#### DESIGN CHANGE` + `#### ADR` + `Old:`/`New:` fenced pairs targeting that region. Invoking it here is a guaranteed `BLOCKED: invalid design-change body` no-op. The exact old/new spans are reproduced below so this record carries the same auditability the form would have.

**Item 1 — Old:**

```
- [ ] No file outside `dev/design-system/`, `packages/dartclaw_server/lib/src/static/` and the three shared fragments named in Work Areas (`templates/topbar.html`, `templates/components.html`, `templates/components.dart`) is modified — no controller, service, schema, route or API change.
```

**Item 1 — New:**

```
- [x] No file outside this story's Work Areas is modified: `dev/design-system/`, `packages/dartclaw_server/lib/src/static/`, the three shared fragments (`templates/topbar.html`, `templates/components.html`, `templates/components.dart`), the three clone-row templates TI07 requires a baseline `.card` class in (`templates/scheduling.html`, `templates/task_detail.html`, `templates/knowledge_hub.html` — class-list additions only), `templates/health_dashboard.dart` (sole repo-wide caller of the `infoCardTemplate` signature TI07 changes; the rename does not compile without it), the generated `lib/src/generated/embedded_assets.g.dart` (regenerated only via `dart run dev/tools/embed_assets.dart`), and `test/templates/health_dashboard_test.dart` (assertions tightened onto the reshaped fragment). No controller, service, schema, route or API change.
```

**Item 2 — Old:**

```
- [ ] No per-surface template owned by S08–S12 or S15 is edited, and `restart_banner.html` is left untouched for S12.
```

**Item 2 — New:**

```
- [x] No per-surface template owned by S08–S12 or S15 is edited beyond the two adoptions TI07 mandates: the baseline `.card` class on the eight clone rows, and the `infoCardTemplate` caller update in `templates/health_dashboard.dart` (S09's surface) forced by the `badgeClass` → `variant` rename. Both are recorded in Implementation Observations as boundary crossings; `restart_banner.html` is left untouched for S12.
```

**Why the checklist was the stale side, not the implementation** — three in-FIS contradictions, each load-bearing:

1. **TI07 mandates the template edits item 1 forbade.** TI07 says "Add the baseline `.card` class to each existing scheduling, task-detail and knowledge clone row", and its Verify line requires "every named clone row has `.card` in its emitted class list" — unsatisfiable without editing `templates/scheduling.html`, `templates/task_detail.html` and `templates/knowledge_hub.html`. Work Areas names those same three templates explicitly ("add the baseline `.card` class only"). Item 1 omitted them.
2. **TI07's fragment reshape forces the `health_dashboard.dart` caller update.** TI07 requires `infoCard` to emit `.status-badge` + `.status-badge-{variant}` instead of `.card-badge`, changing `infoCardTemplate`'s parameter from `badgeClass` (`badge-success`) to `variant` (`success`). `templates/health_dashboard.dart` is the sole caller repo-wide, so the rename fails `dart analyze` without it. The alternative — keeping `badgeClass` and stripping a `badge-` prefix inside the fragment — was rejected as exactly the "misguided workaround" the project's core philosophy forbids.
3. **A Structural Criterion requires regenerating a file item 1 omitted.** The final Structural Criterion requires `dart run dev/tools/embed_assets.dart` to refresh the tracked bundle and the parity test to pass, which necessarily modifies `lib/src/generated/embedded_assets.g.dart`.

**Evidence the as-built delta is minimal.** Every S07-attributable hunk in the three surface templates is a class-list addition and nothing else: `scheduling.html:8`, `task_detail.html:117`, `:137`, `:197`, `knowledge_hub.html:36`, `:47`. The `health_dashboard.dart` change is confined to the badge-class-to-variant value mapping and the call site. `restart_banner.html` is untouched. `test/templates/health_dashboard_test.dart` was tightened rather than rewritten, because its assertions matched `badge-success` as a substring of both the old and new markup and so could not detect the reshape at all; the tightened version is mutation-verified — reverting `infoCard` to `.card-rows` + `.card-badge` turns four tests red.

**No scope was widened.** The amendment records what TI07 and Work Areas already required and what the implementation actually did. The two boundary crossings (`health_dashboard.dart` into S09's surface; `.workflow-step-detail-content h4`'s colour into S15's) remain recorded above for their owning stories.
