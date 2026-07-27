# FIS: Global sweep — type tiers, colour tiers and canon container adoption

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S07

> **Split note**: S07 and S16 were one story until it reached 18 tasks. S07 keeps the type, colour and CSS-token work; `fis/s16-global-sweep-shell-behaviour-states-formatting.md` takes the shared fragments, shell behaviour, states and data formatting, and runs immediately after on the same files. The `plan.json` story name and this file's name predate the split and still say "formatting" — the task list below is authoritative.

**All shell commands in this file run from the `dartclaw-public` repo root.** A path rooted anywhere else makes `rg` exit 2 and read as a pass.

## Feature Overview and Goal

**Intent**: The audit's largest cluster is not any one screen — it is defects that every one of the 23 surfaces inherits from `app.css` and the shared card fragment, so a per-surface sweep would fix the same defect five times and diverge five ways; this story closes the type, colour and stacking half of them once, in the layer they actually live in, before the surface stories fan out.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor to these):

- [OC01] The product reads as a hierarchy: `--text-sm` no longer exists anywhere, and every text run in the shared shell, page and card scaffolding resolves through a composite `.t-*` tier rather than a hand-derived set of four properties.
- [OC02] Text and status colour that carry meaning are legible: labels, metadata and table headers leave the placeholder tier, and every app-local badge meets WCAG AA in both themes.
- [OC03] Shared card scaffolding and app stacking come from canon: the card treatment all surfaces inherit composes on canon `.card`, and every app layer sits on the canonical `--z-*` ladder rather than an ad-hoc literal.


## Required Context

### From `plan.json` – sharedDecisions: "Canon-first, and canon closes after P1"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> Every story that changes a canon-owned rule edits `dev/design-system/` first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` — regenerating the two-line `/* Synced from … sha256: … */` provenance header — within the same story. `dev/tools/fitness/check_design_system_sync.sh` must be green at every story boundary. ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. […] A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked.

### From `plan.json` – sharedDecisions: "`--text-sm` retirement protocol"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> Two-step so the app never breaks mid-migration: S02 aliases `--text-sm` to `--text-base` in canon `tokens.css` and stops treating it as a tier in DESIGN.md; S07 migrates every remaining usage in `app.css` and `design-system.css` onto the composite classes and then deletes the alias from canon. No other story introduces a new `--text-sm` usage.

### From `plan.json` – sharedDecisions: "Composite type-class vocabulary"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `plan.json` – sharedDecisions: "Surface token roles — three distinct planes"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S01 fixes the structural rule that every later story consumes: chrome (`.sidebar`, `.topbar`) sits on the crust plane, the page ground on the base plane, and `.card` on its own sub-base plane, in both themes, with the body gradient never terminating on the card tone. Exact values are an S01 visual-validation outcome. No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.

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
- `docs/specs/0.22.1/canon-hoist-manifest.md` – the authority for which canon rule belongs to which P1 story, and the record that P3 stories consume canon rather than author it. This story's one hoist request (canon `.section-title`, to S02) belongs in its table. Its blanket statement that *no P3 story re-syncs anything* is in tension with the `--text-sm` retirement protocol, which assigns the alias deletion and its re-sync to this story by name — see Constraints & Gotchas.
- `docs/specs/0.22.1/fis/s16-global-sweep-shell-behaviour-states-formatting.md` – the behaviour half, which runs immediately after this story on the same `app.css`, `topbar.html` and `components.html`. Read its Execution Contract before editing those three files.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – capture and comparison procedure for the per-story visual gate.
- `../dartclaw-public/dev/testing/UI-SMOKE-TEST.md` – TC-01…TC-31; the badge and table cases exercise TI03, TI05 and TI06.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI02,TI03,TI04] The product renders a legible type ladder and the 13px tier is gone**
  - **Given** the `visual` profile serving all 23 surfaces (`bash dev/testing/profiles/visual/run.sh`, port 3338) after S02 shipped `.t-caption` / `.t-body` / `.t-label` / `.t-heading` / `.t-page-title` / `.t-display` / `.t-metric`
  - **When** any dashboard page (`/health`, `/tasks`, `/workflows`) is rendered in either theme
  - **Then** the topbar page title computes to 20px/600 (`.t-page-title`) and every section heading to 18px/600 with 1.3 leading, so the largest text on the page is no longer the 14px body tier
  - **And** no computed `font-size` anywhere on the page is below 12px, and every uppercase micro-label carries `letter-spacing: 0.08em`
  - **And** `--text-sm` resolves to nothing — the token is absent from `tokens.css` and no rule references it — while no text run has lost its size to an unresolved `var()` fallback
  - **And** a dense table that overflows at the 14px body tier is recorded as a deviation for its owning surface story, never reverted to a 13px literal

- [ ] **S02 [OC02] [TI05,TI06] Labels and badges that carry meaning meet WCAG AA in both themes**
  - **Given** `/health` (service card labels), `/tasks` (the CLAUDE provider badge on every row) and `/settings` in light theme, where the label tier measures 3.22:1 and `.provider-badge-codex` measures 2.13:1 today
  - **When** contrast is sampled on the rendered surfaces in both themes
  - **Then** every label, metadata field and table header measures ≥ 4.5:1 against the surface behind it, and `--fg-overlay` appears only on placeholder, disabled and helper text
  - **And** every app-local hue badge — `.provider-badge-*`, `.delivery-badge.*`, `.layer-badge--kg`, `.workflow-parallel-badge`, `.workflow-artifact-badge--*` — measures ≥ 4.5:1 in both themes and renders its status with a shape or label cue, not colour alone

- [ ] **S03 [OC03] [TI07] The app-local card clones and the shared `infoCard` compose on canon `.card`**
  - **Given** the eight app-local card clones in `app.css` this story composes on canon (`.heartbeat-card`, `.task-card-running`, `.task-chat-embed`, `.task-no-session`, `.task-review-bar`, `.agent-runner-card`, `.knowledge-summary-item`, `.knowledge-result-row`) — `.metric-card` is the audit's ninth and is left to S15, which deletes it
  - **When** a surface that uses them renders (`/scheduling` heartbeat card, `/knowledge` summary tiles)
  - **Then** each container carries canon `.card`'s `--shadow-sm` and `--border-highlight` top edge and reads as raised, with the card-vs-ground contrast S01 fixed unchanged
  - **And** the shared `infoCard` fragment emits `.card-header` → `.card-body` → `.card-footer` with a canon `.status-badge`, not `.card-rows` + `.card-badge`

- [ ] **S04 [OC03] [TI08] Every app layer stacks from the canonical ladder**
  - **Given** `/settings`, whose sticky tab bar, open `.custom-select` and post-save restart overlay are three of the seven ad-hoc `z-index` literals in `app.css`
  - **When** a config save raises the restart overlay over an open custom select
  - **Then** every app layer that stacks — the composer palettes, the open `.custom-select`, the sticky settings tab bar, the sticky task review bar, the attribution popover and the restart overlay — resolves its `z-index` from a `--z-*` token in the ascending order S04's ladder fixed
  - **And** the restart overlay paints above the open select and below the toast container, and no bare integer ≥ 10 is left in `app.css`


## Structural Criteria

- [ ] `dev/tools/fitness/check_design_system_sync.sh` exits 0 at the story boundary: `tokens.css`, `design-system.css` and `icons.css` are byte-identical to their canon sources with matching sha256 provenance headers.
- [ ] `--text-sm` exists nowhere: not as a token in `dev/design-system/tokens.css`, and not as a `var(--text-sm)` reference in canon `components.css`, `showcase.html`, `app.css`, `design-system.css`, templates or controllers.
- [ ] Card-vs-ground contrast stays ≥ 1.15:1 in both themes after the eight card clones compose on canon `.card`; no surface, chrome or ground token is re-toned by this story.
- [ ] `app.css` declares no bare `z-index` integer ≥ 10: every app-layer stacking value resolves from a `--z-*` token, and the only remaining literal is `.table-fade-wrap::after`'s component-local `1`.
- [ ] No canon RULE is authored by this story. The only `dev/design-system/` edits are the `--text-sm` call-site migrations and the alias deletion the retirement protocol assigns to S07, plus `DESIGN.md` / `showcase.html`, which are not drift-checked.
- [ ] `embedded_assets.g.dart` is not regenerated: `dart run dev/tools/embed_assets.dart` is S14's single run and is not executed here.


## Scope & Boundaries

### Work Areas
- `dev/design-system/` canon — `tokens.css` (the `--text-sm` alias deletion), `components.css` (its 19 `var(--text-sm)` call sites, including the `.text-sm` utility at :1628 and `.card-body` at :835), `DESIGN.md` § Typography and `showcase.html` (its 4 `var(--text-sm)` sites and the retired `text-sm` specimen row at :211); the three served copies re-synced with regenerated provenance headers.
- `packages/dartclaw_server/lib/src/static/app.css` — the 79 `--text-sm` sites, the 82 `--fg-overlay` sites, the app-local hue-badge recipes, the six off-scale sizes, the five untracked uppercase labels, eight of the nine card clones (`.metric-card` is S15's), and the six ad-hoc `z-index` literals plus the one deliberate survivor.
- Shared Trellis/Dart fragments — `templates/topbar.html` (applying the `.t-page-title` class to the two static titles, nothing else) and `templates/components.html` + `components.dart` (the `infoCard` fragment only).

### What We're NOT Doing
- Shell behaviour, states, shared `pageHeader` / `emptyState` fragments, controllers, `helpers.dart` and data formatting -- S16 owns them and runs immediately after this story.
- Per-surface adoption and glitches -- S08–S12 and S15 own each surface's own template edits; this story stops at the scaffolding those surfaces inherit, because the six W2 stories run in parallel on those files.
- Authoring or editing any canon rule outside the `--text-sm` call sites the retirement protocol assigns here. Canon `.section-title` still hand-derives its tier and lacks `--leading-tight` / `--tracking-tight` (`components.css:1541`); that is a canon type rule, so it is reported for hoisting into S02, not fixed here (see Implementation Observations).
- Applying `.t-heading` as a *class* to the five per-surface heading rules -- their markup lives in templates S08, S10 and S15 own. This story mirrors the tier's token values in the `app.css` rule instead (see TI02) and records the class conversion for the owning surface story.
- Renaming the `.text-sm` utility class or its 47 markup usages (`showcase.html` 30, `signal_pairing.html` 11, `whatsapp_pairing.html` 6). The class is repointed to `var(--text-base)` so it stops referencing a deleted token; the two pairing templates belong to S10, and the rename is recorded as a deferral.
- Composing `.metric-card` on canon `.card` or retiering `.metric-card .metric-label` (`app.css:590-595`) -- S15 deletes the family and re-renders its only consumer, `workflow_detail.html`, through `metricCardTemplate`.
- Adopting `.status-pill` in the tasks/scheduling STATUS columns and repointing the three divergent KPI-tile implementations -- those are per-surface template edits (S08–S11); this story only makes the app-local badge recipe AA-safe so the surfaces inherit a correct base.
- Writing the missing CSS for the 77 unstyled template classes, or adding a fitness check for orphan classes -- the load-bearing clusters belong to their surface stories, and a new check is tooling, not polish.
- Regenerating `embedded_assets.g.dart` -- S14 runs `dev/tools/embed_assets.dart` exactly once for the whole release.


## Architecture Decision

**Approach**: land the type, colour and stacking defects that all 23 surfaces inherit — the canon `--text-sm` call sites, `app.css`, and the shared card fragment — in one pass ahead of the parallel surface sweeps, so those sweeps adopt shared shapes instead of each inventing one.
**Why this over alternatives**: letting each surface story fix its own copy of a global defect is precisely what produced the 232-finding audit (six page-header treatments, eight empty-state classes, four timestamp formats); and because this story rewrites `app.css` globally, running it beside the W2 sweeps guarantees conflicts in the one file all of them touch. S16 is sequenced immediately after rather than beside it for the same reason — the two halves share `app.css`, `topbar.html` and `components.html`.


## Technical Overview


## Code Patterns & External References

```
# type | path#anchor or url                                                          | why needed (intent)
file   | dev/design-system/components.css#.t-heading                                 | The composite tiers TI01/TI02 migrate onto – apply the class where this story owns the markup, mirror its four token values only where it does not
file   | dev/design-system/components.css#.card                                       | shadow-sm + border-highlight + hover lift the eight clones must inherit rather than re-declare
file   | dev/design-system/components.css#.status-badge                               | The canon `color-mix(in srgb, var(--hue) 10%, var(--bg-base))` recipe TI06 rebases app badges on
file   | dev/design-system/components.css#.text-sm                                    | The utility at :1628 that must stop referencing the deleted token; its 47 markup usages are not this story's
file   | packages/dartclaw_server/lib/src/static/tokens.css#--z-overlay               | The served copy of S04's `--z-*` ladder TI08 consumes; `app.css` resolves against this file, not canon
file   | packages/dartclaw_server/lib/src/templates/components.html#infoCard           | Shared card fragment TI07 re-shapes; `metricCard` beside it is the emit shape to match
file   | packages/dartclaw_server/lib/src/templates/topbar.html#pageTopbar             | The `.session-title-static` span (:38) TI02 classes; S16 later promotes the same element to `<h1>`
tool   | dev/tools/fitness/check_design_system_sync.sh                                 | The byte-identity + sha256 gate every canon edit must leave green
```


## Constraints & Gotchas

- **Critical**: `design-system.css` is a *generated copy* of `dev/design-system/components.css` with a two-line sha256 provenance header. Its 19 `--text-sm` sites must be changed in canon and re-synced -- editing the served file directly fails `check_design_system_sync.sh`.
- **Critical**: `--text-sm` currently resolves through S02's alias to `--text-base`. Deleting the token before the last consumer migrates makes `font-size: var(--text-sm)` invalid, and the declaration silently drops to the inherited size rather than erroring -- migrate every consumer (TI01–TI03) before TI04 deletes it. `showcase.html` is a consumer too (4 sites) even though it is not drift-checked.
- **Critical**: an undefined custom property fails the same silent way. `var(--z-overlay)` resolves to nothing if S04's ladder is not in the *served* `static/tokens.css`, and the `z-index` declaration is dropped rather than erroring — the layer then stacks by document order, which looks correct on a short page and breaks on a long one. Confirm the seven tokens are present in the served file before starting TI08.
- **Constraint**: `app.css` loads *after* `design-system.css` (`layout.html:16-17`), so equal-specificity app rules win. Deleting an `app.css` declaration exposes the canon rule underneath -- confirm what surfaces before assuming a deletion is inert.
- **Constraint**: canon is closed after P1 for `tokens.css` / `components.css` / `icons.css`. This story holds one narrow exemption, granted by name in the `--text-sm` retirement protocol: migrating the existing `var(--text-sm)` call sites and deleting the alias. It authors no canon rule and edits no other canon rule. Anything else canon needs is reported for hoisting into S01–S04.
- **Avoid**: fixing a colour or contrast complaint by re-tuning a token. Per the shared surface decision, surface complaints go back to S01's tokens; this story's only sanctioned colour moves are retiering a class from `--fg-overlay` to `--fg-sub0` / `--fg-sub1` and rebasing an app-local badge onto the canon mix recipe.
- **Avoid**: editing a per-surface template to prove a shared fragment works. S08–S12 and S15 run in parallel on those files -- prove a fragment in its own render, and leave adoption to the owning surface story.
- **Handoff to S16**: S16 edits the same three shared files. It promotes `topbar.html`'s two static title spans to `<h1>` (keeping whatever class list this story leaves), adds the shared `pageHeader` / `emptyState` fragments beside `infoCard`, and collapses the eight bespoke empty-state classes in `app.css`. Two of this story's TI05 retierings — `.table-empty-cell` (:1126) and `.empty-state-text` (:1810) — are rules S16 subsequently folds into canon `.empty-state`; retier them anyway, because this story's gate runs at its own boundary and a half-migrated `--fg-overlay` set is what the sweep stories would otherwise inherit.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Every `--text-sm` consumer resolves through a composite tier
  - The 79 `var(--text-sm)` references in `packages/dartclaw_server/lib/src/static/app.css` and the 19 in `dev/design-system/components.css` (including the `.text-sm` utility at components.css:1628 and the `.card-body` rule at :835) move to the composite classes or to `var(--text-base)` where the rule is a one-off; apply `.t-*` classes in the markup this story owns. `showcase.html`'s 4 sites move with them. Follow `dev/design-system/components.css#.t-body`. Canon-side edits re-sync in TI04.
  - **Boundary**: the `.text-sm` *utility class* is repointed to `var(--text-base)`, not deleted — it has 47 live markup usages, 17 of them in `signal_pairing.html` / `whatsapp_pairing.html`, which are S10's templates. After the repoint the class is a no-op alias of the body tier; record the rename as a deferral in Implementation Observations rather than editing S10's markup.
  - **Verify**: `rg -c 'var\(--text-sm\)' packages/dartclaw_server/lib/src/static/app.css dev/design-system/components.css dev/design-system/showcase.html` prints nothing and exits 1 (it prints `app.css:79`, `components.css:19` and `showcase.html:4` today; `rg -c` never emits a zero-count line, so silence is the pass signal); rendered `.data-table` cells, sidebar items and card bodies measure 14px in both themes with no run left at 13px

- [ ] **TI02** Shared shell, page and card scaffolding renders the composite type ladder
  - `templates/topbar.html`'s two static titles — `pageTopbar`'s `<span class="session-title-static">` (:38) and `plainTopbar`'s `<span class="session-title">` (:26) — gain `t-page-title` in their class list. Canon's own `.topbar .session-title-static` tier is S02's and is not re-edited here.
  - The five section-heading rules that reach only through a per-surface element selector — `app.css#.task-status-group h3` (:1610), `#.task-chat-column h3, .task-artifact-column h3` (:1848), `#.agent-overview h3` (:2068), `#.channel-sub-card h3` (:1433) and `#.workflow-step-detail-content h4` (:2602) — cannot take a class from this story, because their markup is in templates S08, S10 and S15 own. They instead mirror `.t-heading`'s four token values (`var(--text-lg)` / `var(--weight-bold)` / `var(--leading-tight)` / `var(--tracking-tight)`), which is the precedent S02 set for canon `.card-header` and `.topbar .session-title-static` when a class could not be applied. Record each one for its surface story to convert to a `.t-heading` class.
  - **Ownership**: canon `.section-title` (`components.css:1541`) is the sixth heading rule and is canon-owned type work. It is **reported for hoisting into S02**, not edited here — see What We're NOT Doing.
  - Consumes TI01's migrated call sites.
  - **Verify**: `rg -n 't-page-title' packages/dartclaw_server/lib/src/templates/topbar.html` returns the two title elements (returns nothing today); `rg -nU --multiline-dotall '(\.task-status-group h3|\.agent-overview h3|\.task-chat-column h3|\.channel-sub-card h3|\.workflow-step-detail-content h4)[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg -c 'line-height'` prints `5` — it prints nothing and exits 1 today, because none of the five declares one; on `/health` and `/tasks` the topbar title computes to 20px/600 and every section heading to 18px/600 with `line-height` 1.3

- [ ] **TI03** No off-scale type remains and every uppercase micro-label is tracked
  - The six sub-floor sizes in `app.css` (`.channel-mode-badge` 0.625rem:1415, `.provider-badge` 0.625rem:1782, `.task-event` 11px:2259, `.task-event-icon` 10px:2264, `.workflow-artifact-badge` 10px:2631) rise to `var(--text-xs)` and the hardcoded 13px `.workflow-step-icon` (:2516) to a token; compensate density with padding, not size. `.layer-badge`, `.knowledge-summary-label`, `.unverified-flag`, `.kg-timeline-controls .field-label` and `.guard-editor-table th` gain `letter-spacing: var(--tracking-caps)`.
  - **Ownership**: per the plan's `Shared-surface ownership in the sweep phase` decision, this task is the **sole** owner of off-scale font-size normalization across the whole app. All six sites are listed above and none is shared with a sweep story: S08 keeps only its `.provider-badge` `margin-left` removal, S10 only its `.channel-mode-badge` semantics, S12 only its shell-side `.provider-badge` semantics, S15 only its `.workflow-artifact-badge` / `.workflow-step-icon` block work — none of them re-declares a `font-size` on these rules. A sweep story that finds an off-scale size this task missed reports it rather than fixing it locally.
  - **Verify**: `rg -n 'font-size:\s*(0\.(6|7)[0-9]*rem|1[01]px|13px)' packages/dartclaw_server/lib/src/static/app.css` returns no matches (it returns exactly the six lines 1415, 1782, 2259, 2264, 2516 and 2631 today, so a single missed site fails it); the five named uppercase rules each declare `var(--tracking-caps)`, and the CLAUDE provider badge renders at 12px

- [ ] **TI04** `--text-sm` no longer exists
  - Delete the migration alias from `dev/design-system/tokens.css` (:72), drop its remaining mention from DESIGN.md § Typography and the § Code prose at DESIGN.md:772 (which still says code wells render at `text-sm`), and re-sync all three served copies with regenerated `/* Synced from … sha256: … */` headers. Delete the retired `text-sm` specimen row from `showcase.html` (:211). Runs after TI01–TI03 have moved every consumer; this is the story's settlement of success metric 2.
  - **Verify**: `rg -n -e '--text-sm' dev/design-system/ packages/dartclaw_server/lib/src/` returns no matches — it returns 123 lines across six files today (`components.css` 19, `tokens.css` 1, `showcase.html` 4, served `design-system.css` 19, served `tokens.css` 1, `app.css` 79), so a single missed consumer or an unsynced served copy fails it; `rg -n 'text-sm' dev/design-system/DESIGN.md` returns no matches (it returns :772 today); `bash dev/tools/fitness/check_design_system_sync.sh` exits 0

- [ ] **TI05** `--fg-overlay` is reserved for placeholder, disabled and helper text
  - The label and copy classes DESIGN.md forbids it for move tier: `app.css#.detail-label` (:563), `#.card-row-label` (:583), `#.meter-label` (:1041), `#.tab-meta-label` (:1084), `#.table-empty-cell` (:1126), `#.info-subtitle` (:432), `#.settings-header p` (:489), `#.metric-sub-inline` (:1038), `#.error-code` (:313) to `--fg-sub0`; `#.empty-state-text` (:1810) to `--fg-sub1` and `#.empty-state-title` (:1809, already `--fg-sub0`) to `--fg`. `.metric-card .metric-label` (:595) is deliberately **not** retiered — S15 deletes the whole `.metric-card` family (`app.css:590-595`) and re-renders its only consumer through `metricCardTemplate`. Measure after S01's remap, not against the pre-0.22.1 values.
  - **Verify**: `rg -nU --multiline-dotall '(^\.detail-label|^\.card-row-label|^\.meter-label|^\.tab-meta-label|^\.table-empty-cell|^\.info-subtitle|^\.settings-header p|^\.metric-sub-inline|^\.error-code|^\.empty-state-text|^\.empty-state-title)[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg 'fg-overlay'` returns no matches — it returns exactly 10 lines today (313, 432, 489, 563, 583, 1038, 1041, 1084, 1126, 1810), so one missed rule fails it; on `/health`, `/task-detail` and `/settings` in **light** theme every label and metadata run measures ≥ 4.5:1 against the surface behind it (they measure 3.22:1 on cards today); any surviving `--fg-overlay` consumer elsewhere in `app.css` that is neither placeholder, disabled nor helper text is recorded in Implementation Observations for its owning surface story rather than retiered here

- [ ] **TI06** App-local hue badges use the canon contrast recipe
  - `.provider-badge-claude` (:1789), `.provider-badge-codex` (:1793), `.delivery-badge.announce` (:646), `.delivery-badge.webhook` (:647), `.layer-badge--kg` (:3033), `.workflow-parallel-badge` (:2582) and all four `.workflow-artifact-badge--*` variants (`--diff` :2639, `--document` :2644, `--data` :2649, `--pr` :2654 — the `--pr` variant is the one the audit's site list omits) rebase on `color-mix(in srgb, var(--hue) 10%, var(--bg-base))` with `border-color: color-mix(in srgb, var(--hue) 22%, var(--bg-surface1))` — reusing `dev/design-system/components.css#.status-badge` rather than re-declaring it.
  - **Boundary**: `app.css:1837` is `.task-meta-warning`, a padded warning panel rather than a badge, and keeps its own fill. Record the disposition so it does not read as a missed site. `.layer-badge--kg` already blends against `--bg-base` and needs only the contrast re-measure, not a base change.
  - **Verify**: `rg -nU --multiline-dotall '(^\.provider-badge-claude|^\.provider-badge-codex|^\.layer-badge--kg|^\.workflow-parallel-badge|^\.workflow-artifact-badge--|^\.delivery-badge\.announce|^\.delivery-badge\.webhook)[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg 'var\(--bg-surface0\)'` returns no matches — it returns exactly 9 lines today (646, 647, 1790, 1794, 2591, 2640, 2645, 2650, 2655), so one missed variant fails it; every rebased badge measures ≥ 4.5:1 in both themes (`.provider-badge-codex` is 2.13:1 light today)

- [ ] **TI07** The app-local card clones and the shared `infoCard` compose on canon `.card`
  - The eight clones — `.heartbeat-card` (:616), `.task-card-running` (:1740), `.task-chat-embed` (:1853), `.task-no-session` (:1872), `.task-review-bar` (:1908), `.agent-runner-card` (:2090), `.knowledge-summary-item` (:3111), `.knowledge-result-row` (:3141) — drop their `background` / `border` / `border-radius` surface declarations and keep layout only, so `--shadow-sm` and `--border-highlight` come from `dev/design-system/components.css#.card`. `.metric-card` (:590) is the ninth clone in the audit's list and is deliberately excluded: S15 deletes the family outright, so composing it on canon here is work S15 discards. `templates/components.html#infoCard` wraps its rows in `.card-body`, moves the badge to `.card-footer`, and emits `.status-badge` + `.status-badge-{variant}` instead of `.card-badge`.
  - **Verify**: `rg -n 'card-badge|card-rows' packages/dartclaw_server/lib/src/templates/components.html` returns no matches (it returns :34 and :36 today); on `/scheduling` and `/knowledge` each container's first pixel row shows the `--border-highlight` tone and a measurable `--shadow-sm` band, with card-vs-ground contrast still ≥ 1.15:1 in both themes

- [ ] **TI08** The app's ad-hoc stacking literals resolve from the canonical `--z-*` ladder
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

- TI04 (deleting `--text-sm` from canon) must run after TI01, TI02 and TI03 — the token is what keeps unmigrated consumers resolving, and deleting it early degrades silently to inherited sizes rather than erroring.
- TI08 has no ordering dependency inside this story, but it consumes S04's `--z-*` ladder from the served `static/tokens.css`. Run its presence check first; if the ladder is missing, TI08 stops and reports rather than adding the tokens — canon is closed after P1.
- This story must leave `check_design_system_sync.sh` green before S16 starts. S16 re-syncs canon again for its own shell-chrome edits, and a divergent served copy at the handoff makes S16's provenance header conflict on the same line.


## Final Validation Checklist

- [ ] No file outside `dev/design-system/`, `packages/dartclaw_server/lib/src/static/` and the three shared fragments named in Work Areas (`templates/topbar.html`, `templates/components.html`, `templates/components.dart`) is modified — no controller, service, schema, route or API change.
- [ ] No per-surface template owned by S08–S12 or S15 is edited, and `restart_banner.html` is left untouched for S12.
- [ ] `dart run dev/tools/embed_assets.dart` was not executed and `embedded_assets.g.dart` is unchanged — S14 owns the single regeneration.
- [ ] The canon rules this story reports rather than edits — `.section-title`'s missing `--leading-tight` / `--tracking-tight` (hoist to S02) — are recorded in Implementation Observations with the owning story named.
- [ ] The dispositions this story records rather than fixes — the `.text-sm` utility rename, `app.css:1837` `.task-meta-warning` as not-a-badge, `.table-fade-wrap::after`'s surviving literal, and the restart-overlay-over-modal limitation — are in Implementation Observations, which is the only block S14's glitch ledger reads.


## Implementation Observations

_No observations recorded yet._
