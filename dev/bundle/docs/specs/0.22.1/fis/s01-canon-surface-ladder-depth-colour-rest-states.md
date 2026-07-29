# Canon: surface ladder, depth and colour rest states

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: Four roles (`.sidebar`, `.topbar`, `.card`, and the body gradient's terminal stop) resolve to the same surface token, so cards read as holes or outlines and every page reads flat and gray – no amount of page-level work can separate layers that are literally the same colour, so the separation has to be created in the canon itself.

**Expected Outcomes**:

- [OC01] Chrome, page ground and cards read as three distinct planes on every surface in both themes, with cards reading as raised surfaces rather than as recessed wells or bare outlines.
- [OC02] A resting page carries visible colour and depth: metric and tint cards show their hue without hovering, the ambient ground reads as atmospheric, and a resting card casts a readable shadow in both themes.
- [OC03] The sidebar rail – chrome on 100% of views – reads with three distinct text tiers instead of one flat colour.
- [OC04] Text stays WCAG AA legible on every re-toned surface, and the composer's send button and focus indicator reach the WCAG 3:1 non-text minimum in both themes.
- [OC05] Every surface-and-chrome canon rule a later story consumes is already in canon when that story starts: the featured-card gradient border paints, `<hr>` renders as a designed rule, a short chat thread bottom-anchors, table headers band, shell rows can shrink inside `100dvh`, and skip navigation is hidden until focused. Canon closes with this story's family complete – no P3 sweep authors a surface rule.
- [OC06] S05 receives a written record of every `app.css` rule the re-tone displaces, in the canonical FIS, rather than having to re-derive it.


## Required Context

### From `docs/specs/0.22.1/prd.md` – "FR1: Surface & depth revision"
<!-- source: docs/specs/0.22.1/prd.md#fr1-surface--depth-revision -->
<!-- extracted: 2026-07-25, working tree – `prd.md` is modified since e18cf85, which predates the FR1 card-hover correction -->
> **Description**: Give chrome, page ground and cards three distinct planes in both themes. Stop the body gradient short of any card tone. Move a fraction of each colour variant's treatment to the rest state. Give the light theme its own surface mapping and a real `--shadow-sm` rather than a mirrored dark ladder.
>
> Proposed dark remap (exact values to be settled by visual validation; the *structure* is the decision):
>
> | Role | Current | Proposed |
> |---|---|---|
> | Chrome (`.sidebar`, `.topbar`) | `--bg-mantle` #181825 | `--bg-crust` #11111b |
> | Page ground (gradient end stop) | `--bg-mantle` #181825 | `--bg-base` #1e1e2e |
> | Card rest | `--bg-mantle` #181825 | `--bg-sub-base` |
> | Card hover | `--bg-mantle` + accent radial wash | re-derive from the new card rest tone |
>
> > Corrected 2026-07-25 during planning: an earlier draft of this table listed card hover as `--bg-surface0` #313244. It is not — `.card:hover` (components.css:793-800) paints an accent radial gradient over `var(--bg-mantle)`, the *same* token as card rest, and it is one of ~9 hover fills pinned to that token. Moving the card rest token therefore moves hover with it; hover cannot be left "unchanged".
>
> Light theme: card `#ffffff` on a tinted `--bg-base` #eff1f5 ground, chrome `--bg-mantle` #e6e9ef; raise `--shadow-sm` from `0 1px 2px rgba(0,0,0,.06)` to a perceptible elevation.
>
> **Acceptance Criteria**:
> - [ ] Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.
> - [ ] `.sidebar` / `.topbar` resolve to a token distinct from `.card` in both themes.
> - [ ] `.card-metric--*` and `.card-tint-*` carry visible hue at rest; hover amplifies rather than introduces.
> - [ ] All 23 surfaces pass visual validation in both themes at desktop + 768px.

### From `docs/specs/0.22.1/prd.md` – "Key Constraints, Assumptions & Dependencies" (binding)
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.
>
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `docs/specs/0.22.1/prd.md` – "Constraints" (binding)
<!-- source: docs/specs/0.22.1/prd.md#constraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `docs/specs/0.22.1/prd.md` – "Out of Scope" (binding)
<!-- source: docs/specs/0.22.1/prd.md#out-of-scope -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `docs/specs/0.22.1/prd.md` – "FR1" acceptance threshold (binding)
<!-- source: docs/specs/0.22.1/prd.md#fr1-surface--depth-revision -->
<!-- extracted: e18cf85 -->
> Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.

### From `docs/specs/0.22.1/prd.md` – "Non-Functional Requirements" (binding)
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone
>
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline

### From `docs/specs/0.22.1/prd.md` – "Executive Summary" § Success Metrics, metric 1
<!-- source: docs/specs/0.22.1/prd.md#executive-summary -->
<!-- extracted: e18cf85 -->
> 1. Card-vs-ground contrast ≥ 1.15:1 in **both** themes, with chrome, page ground and cards on three distinct planes; no page band equals the card fill.

_(The plan's `sourceRefs` cite this as `prd.md#success-metrics`; the Success Metrics list is a bullet under `## Executive Summary` and has no heading of its own.)_

### From `docs/specs/0.22.1/prd.md` – "Edge Cases", recovery path for a broken text pairing
<!-- source: docs/specs/0.22.1/prd.md#edge-cases -->
<!-- extracted: e18cf85 -->
> | Surface remap breaks WCAG AA text contrast on a re-toned card | Caught by the per-story contrast check before merge | Re-tune the card token, not the text token |

### From `docs/specs/0.22.1/plan.json` – shared decisions binding this story
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25, working tree — supersedes the earlier "Canon-first with per-story re-sync" and single-plane wordings this FIS quoted before remediation -->
> **Canon-first, and canon closes after P1** — A story that changes a canon-owned rule edits `dev/design-system/` (tokens.css / components.css / icons.css / DESIGN.md / showcase.html) first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` — regenerating the two-line `/* Synced from … sha256: … */` provenance header — within the same story. `dev/tools/fitness/check_design_system_sync.sh` must be green at every story boundary. ONLY the P1 stories S01-S04 author rules in the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those rule families close once P1 completes. S07 has one serialized, deletion-only exception: after migrating the app-side consumers it deletes the `--text-sm` alias from `tokens.css`, re-syncs only served `tokens.css`, regenerates embedded assets and closes generated parity green. S07 may not edit `components.css`, `icons.css` or any other canon family. S05 re-syncs nothing new — it verifies the post-P1 check is green after its purge. Every other P3 story consumes canon without re-syncing it; a P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04). `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.
>
> **Surface token roles — three distinct planes** — S01 fixes the structural rule every later story consumes: chrome (`.sidebar`, `.topbar`), page ground and `.card` occupy three mutually distinct planes in BOTH themes, and the body gradient never terminates on the card tone. The token assignment differs per theme and is not fixed here — the PRD's dark remap is chrome→crust / ground→base / card→sub-base, while the light theme gets its own mapping (card white on a tinted ground, chrome at the mantle tier), and exact values in both are an S01 visual-validation outcome. Card hover is not independent: `.card:hover` paints over the same token as card rest, so it re-derives from whatever S01 lands on. No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#a-canon-changes--the-design-system-itself-is-the-defect-40` – the colour-depth and accessibility findings this story closes, each with pixel evidence and a proposed fix; read the `global`, `global (light theme)`, `memory-dashboard`, `shell/sidebar`, `chat-session`, `chat/composer` and `tasks + task-detail` entries before tuning any value. The audit assigns no finding IDs, so match by surface and category rather than by count.
- `docs/specs/0.22.1/canon-hoist-manifest.md` – why six rules S08/S09/S12/S16 discovered are authored here instead, what the canon closure covers (the three drift-checked files only – `DESIGN.md` and `showcase.html` stay writable), and which stories consume each rule.
- `../dartclaw-public/dev/design-system/DESIGN.md#surface-ladder-7-levels` – the table whose `bg-mantle` row currently reads "Cards, sidebar, topbar"; TI13 rewrites it.
- `../dartclaw-public/dev/design-system/DESIGN.md#elevation--depth` – the shadow / luminous-top-edge / micro-lift doctrine that bounds the `--shadow-sm` change; light mode keeps neutral `rgba(0,0,0,…)`, dark keeps the blue-violet `rgba(9,9,26,…)` tint.
- `../dartclaw-public/dev/design-system/DESIGN.md#dos-and-donts` – the no-raw-hex-in-components rule and the WCAG AA rule the story must satisfy while changing surfaces.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – server setup, the agent-browser snapshot loop, the token-check `getComputedStyle` snippet, and the "CSS presence ≠ correct rendering" gotchas.
- `../dartclaw-public/dev/testing/profiles/visual/README.md` – how to start the only profile that renders all 23 surfaces, and where its auth token lives.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI02,TI15] Cards, ground and chrome sample as three planes on a card-dense dark surface**
  - **Given** the `visual` profile serving `/health-dashboard` in dark theme at 1440×900, where the card interior today samples `#181825`, the ground between the card columns `rgb(35,34,50)` and the sidebar the same `#181825` as the card
  - **When** the page is captured and the card interior, the ground directly above and beside that card, and the sidebar rail are pixel-sampled
  - **Then** the three samples are pairwise ΔE(oklab) ≥ 0.02 apart, card-vs-ground contrast is ≥ 1.15:1, and the card is lighter than the ground it sits on rather than 7–11 levels darker

- [ ] **S02 [OC01,OC02] [TI01,TI02,TI03] Light theme separates chrome, ground and card on its own terms**
  - **Given** the `visual` profile serving `/tasks` at 1440×900 with `data-theme="light"`, where the sidebar, the topbar and the card interior all measure exactly `#e6e9ef` today
  - **When** the chrome, the ground directly adjacent to the card, the card interior and the resting card's bottom edge are sampled
  - **Then** the chrome, adjacent ground and card samples are pairwise ΔE(oklab) ≥ 0.02 apart, card-vs-ground contrast is ≥ 1.15:1, and the card's shadow spans ≥3 pixel rows instead of one

- [ ] **S03 [OC02] [TI05,TI06] A resting page carries hue and atmosphere without any pointer interaction**
  - **Given** `/memory` in dark theme with the pointer parked off every card, where `.card-metric--*` and `.card-tint-*` today hold their entire treatment in `:hover`
  - **When** the KPI row's computed rest backgrounds are read and the content ground is sampled corner-to-corner
  - **Then** each `.card-metric--{color}` and `.card-tint-{color}` rest background is ΔE(oklab) ≥ 0.02 from plain `.card`, each variant's `:hover` background is ΔE(oklab) ≥ 0.02 from its own rest value, and the ground's corner-to-corner ΔE(oklab) is ≥ 0.04 (audit baseline 0.0185)

- [ ] **S04 [OC03] [TI07] The sidebar reads with three text tiers**
  - **Given** the sidebar on `/settings` in both themes, where the "WORKSPACE" section label, a resting session title and the "Health" nav item all resolve to `--fg-sub0`
  - **When** the computed `color` of those three elements is read
  - **Then** they resolve to three values pairwise ΔE(oklab) ≥ 0.02 apart, each ≥ 4.5:1 against the chrome plane

- [ ] **S05 [OC04] [TI08] The composer's send button and focus indicator clear the non-text minimum**
  - **Given** `/sessions/<id>` (the chat session view; `/` redirects there) in light theme with text typed into the composer so send is enabled, where the send glyph measures 1.72:1 against its fill and the focused container border 2.04:1 against `--bg-base`
  - **When** the send button's fill and glyph are sampled and the composer is focused
  - **Then** glyph-vs-fill is ≥ 3:1 and the `.composer:focus-within` border is ≥ 3:1 against `--bg-base`, in both themes

- [ ] **S06 [OC01,OC04] [TI04,TI16] No re-toned surface leaves text below AA, and the surface token is what moves**
  - **Given** the re-toned planes and the revised `--fg-overlay`, on `/settings` in light theme where `.form-hint` helper text measures ≈3.25:1 today
  - **When** the 23-surface contrast pass runs in both themes at 1440×900 and 768px
  - **Then** `.form-hint` clears 4.5:1, and no text pairing that cleared 4.5:1 (3:1 for ≥18px bold) against the audit baseline has regressed below it

- [ ] **S07 [OC01] [TI02,TI15] Canon-first is enforced – an app-side-only surface change is rejected**
  - **Given** a working tree where the served `packages/dartclaw_server/lib/src/static/design-system.css` carries a surface change that `dev/design-system/components.css` does not
  - **When** `bash dev/tools/fitness/check_design_system_sync.sh` runs
  - **Then** it exits non-zero reporting `design-system drift: design-system.css`; moving the same change into `dev/design-system/components.css` and regenerating the provenance header makes it exit 0

- [ ] **S08 [OC05] [TI02,TI09,TI10,TI11,TI12,TI14] The six hoisted surface rules are live in canon before any sweep story consumes them**
  - **Given** the `visual` profile after this story's re-sync, on a healthy `/health-dashboard`, `/sessions/<id>` with a two-turn conversation, and `/tasks` – where today the featured card's gradient border never paints, the six sidebar `<hr>` render at the UA `inset` bevel, the thread stacks from the top with the last message ~558px above the composer, and `<thead>` samples identically to the first body row – plus the shell-sizing and skip-link demos in `showcase.html`
  - **When** those regions are sampled and read with `getComputedStyle` in both themes, and the skip-link demo is keyboard-focused
  - **Then** the hero card's border differs from its own fill by ΔE(oklab) ≥ 0.02, every `hr.sidebar-divider` reports `borderTopStyle: "solid"` with `borderBottomWidth: "0px"`, the last message's bottom edge sits within one `--sp-4` of the `.input-area` top border, the `<thead>` band differs from the first body row by ΔE(oklab) ≥ 0.02, `.shell` resolves its second row through `minmax(0, 1fr)` with `.content-area { min-height: 0; }`, and `.skip-link` is visually hidden until focused then becomes visible
  - **And** all six are served from `dev/design-system/components.css` with `check_design_system_sync.sh` green, so S08, S09, S12 and S16 consume them without touching canon


## Structural Criteria

- [ ] `bash dev/tools/fitness/check_design_system_sync.sh` exits 0 – the served `tokens.css` and `design-system.css` are byte-identical to canon below their two-line provenance header, with a matching `sha256:`.
- [ ] `packages/dartclaw_server/lib/src/static/app.css` carries no edit from this story; the only app-side changes are the two re-synced CSS files, and `icons.css` is untouched. After the final served-CSS sync, `dart run dev/tools/embed_assets.dart` has refreshed the tracked bundle and `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` is green.
- [ ] DESIGN.md prose, the DESIGN.md `colors:` frontmatter block and `tokens.css` agree on every `bg-*` value and on which role each surface token serves.
- [ ] `showcase.html` demonstrates the revised ladder, the resting metric/tint colour and the composer's rest and focus states, with no new inline `style=` overrides.
- [ ] `components.css` introduces no new raw hex constants – intermediate surfaces derive from `tokens.css` via `color-mix(in oklab, …)`.
- [ ] The six rules hoisted to this story by `docs/specs/0.22.1/canon-hoist-manifest.md` are present in `dev/design-system/components.css` and in the re-synced `design-system.css`: the eight `.card-featured-*` background-layer fixes, the `hr` element reset, the `.messages` anchoring pair (with `.messages:empty::after` deleted), the `.data-table thead` band, the `.shell` / `.content-area` shrinkable-row sizing, and the focus-revealed `.skip-link`. The skip link temporarily uses `z-index: 30`, is proven above current chrome, and carries an explicit forward handoff to S04 TI01 for conversion to `var(--z-overlay)`. Canon's surface-and-chrome family is complete at this story's boundary; S08, S09, S12 and S16 add nothing to it.
- [ ] [OC06] This FIS's Implementation Observations carries the `app.css` displacement record for S05, in the canonical private repo – not only in the `dev/bundle/` export. OC06 is a document deliverable, so TI17's Verify and this criterion are its gates; it has no acceptance scenario because nothing about it renders.


## Scope & Boundaries

### Work Areas
- `../dartclaw-public/dev/design-system/tokens.css` – surface ladder values in both themes, `--fg-overlay`, `--shadow-sm`, `--ambient-a/-b/-c`.
- `../dartclaw-public/dev/design-system/components.css` – `body` ground gradient and glow placement, `.card`, `.sidebar` / `.topbar`, `.card-metric--*` / `.card-tint-*` rest **and** `:hover` states (nine hover fills are pinned to `--bg-mantle`), sidebar text tiers, `.composer-send` / `.composer:focus-within`, plus the six rules hoisted here per `canon-hoist-manifest.md`: § 10's eight `.card-featured-*` rules, a § 1 `hr` element reset, § 4's `.messages` (anchoring, and deleting the dead `:empty::after`), a `.data-table thead` band in § 14, shrinkable `.shell` / `.content-area` row sizing, and a focus-revealed `.skip-link`.
- `../dartclaw-public/dev/design-system/DESIGN.md` – `colors:` frontmatter, § Colors / § Surface ladder, § Body background, § Elevation & Depth, § Cards, § Composer, § Accessibility, § Gradient dividers, § Messages, and a new § Data tables entry. Not drift-checked and not closed after P1.
- `../dartclaw-public/dev/design-system/showcase.html` – surface-ladder swatches, card taxonomy panels (including the featured-card panels), divider panels, composer panel. Not drift-checked and not closed after P1.
- `../dartclaw-public/packages/dartclaw_server/lib/src/static/tokens.css` + `design-system.css` – re-synced copies with regenerated provenance headers.
- Visual validation of all 23 surfaces on the `visual` profile (port 3338), both themes, 1440×900 and 768px.
- `docs/specs/0.22.1/fis/s01-canon-surface-ladder-depth-colour-rest-states.md` (this file, in `dartclaw-private`) – the Implementation Observations record TI17 writes for S05.

### What We're NOT Doing
- Type scale, the composite `.t-*` classes, the card-title tier, and the § Typography table's `body-sm`-vs-`label-md` ambiguity that the sidebar rules inherit -- S02 owns the type layer; this story changes sidebar *colour* only and leaves every `font-size` declaration alone.
- Container tiers, form/tab/dialog primitives, toast severity, the z-index scale, grid primitives, and a chart/sparkline component -- S02/S03/S04 own the first four; the chart component is an explicit release-level deferral (a new capability).
- Reconciling `app.css` against the re-tone, and every per-page adoption of the revised tokens -- S05 is the sync hinge and owns the fallout; S07–S12 are the sweeps. 17 `app.css` rules reference `--bg-mantle` and will shift under this change; **TI17 records what shifts** into this FIS's Implementation Observations and hands that record to S05. Recording is in scope, repointing is not.
- The global `.btn:disabled { opacity: 0.4 }` rule -- genuinely disabled controls are exempt from WCAG 1.4.11; TI08 fixes the *enabled* resting state of `.composer-send` only.
- The topbar's near-empty action bar, the sidebar's markup and section behaviour, the message-thread scroll controller, and every other shell or chat *surface* defect in the same audit sections -- S12 owns them. The two canon rules underneath two of those findings are this story's, hoisted per `canon-hoist-manifest.md`: TI10's `hr` reset and TI11's `.messages` anchoring. This story ships the rules; S12 verifies them on its surfaces and writes no CSS for either.
- Adopting the six hoisted rules on any page -- authoring them in canon is TI02 and TI09–TI12; `.card-featured-*` adoption is S09's, the `hr` and `.messages` surface checks are S12's, the `.data-table` sweep is S08's, and S16 owns `.page-content { min-height: 0 }` plus the skip-link markup. This story changes no template, no controller and no `app.css` line.


## Architecture Decision

**Approach**: Fix the *roles* first – give `.card`, chrome and the page ground three different surface tokens and stop the body gradient short of the card tone – then settle exact hex values by visual validation rather than pinning them in the spec.
**Why this over alternatives**: per-page fixes in `app.css` fail the drift check and cannot separate layers that share a token; strengthening `.card`'s border and shadow alone was measured insufficient – a 1px `--border-highlight` adds ≈+18 levels on a single row and cannot reverse a card sitting 7–11 levels darker than its ground.


## Technical Overview

<!-- Self-evident from Architecture Decision + task descriptions. -->


## Code Patterns & External References

```
# type | path#anchor or url                                                  | why needed (intent)
file   | ../dartclaw-public/dev/design-system/tokens.css#:root                | Dark ladder, --fg-overlay, --shadow-sm, --ambient-* – the tokens TI01/TI03/TI04/TI05 move
file   | ../dartclaw-public/dev/design-system/tokens.css#[data-theme="light"] | Light override block – must be mapped on its own terms, not mirrored from dark
file   | ../dartclaw-public/dev/design-system/components.css#body             | The 3-stop ground gradient whose terminal stop is the card token
file   | ../dartclaw-public/dev/design-system/components.css#.card            | Card fill + luminous top edge + shadow – the plane that must rise
file   | ../dartclaw-public/dev/design-system/components.css#.card-tint-accent| Existing hover recipe to split into a rest fraction + a hover amplification
file   | ../dartclaw-public/dev/design-system/components.css#.composer-send    | Element-level opacity that collapses fill-vs-glyph contrast
file   | ../dartclaw-public/dev/tools/fitness/check_design_system_sync.sh      | Exact provenance-header contract: sha256 on line 2, canon body from line 3
file   | ../dartclaw-public/dev/design-system/components.css#.card-featured-accent | Bare-colour layer that invalidates the whole `background` shorthand – TI09's eight rules
file   | ../dartclaw-public/dev/design-system/components.css#.messages         | Chat thread (:415) TI11 bottom-anchors; the dead `:empty::after` sits at :422
file   | ../dartclaw-public/dev/design-system/components.css#.data-table       | Canon-owned table block (:1566-1588) with no `thead` band – TI12 adds one
file   | ../dartclaw-public/dev/design-system/components.css#.shell            | Shell row must use `minmax(0, 1fr)` so long content can shrink inside `100dvh` – TI02 carries the canon half S16 consumes
file   | ../dartclaw-public/dev/design-system/components.css#.content-area     | Row child needs `min-height: 0`; its inert `flex: 1` is removed with the shell sizing fix
file   | ../dartclaw-public/dev/design-system/components.css#.skip-link        | Focus-revealed keyboard skip navigation S16 inserts as `<body>`'s first child
file   | ../dartclaw-public/packages/dartclaw_server/lib/src/static/controllers/sidebar_sections.js | Injects `<hr class="sidebar-divider …">` at :57, :99 – TI10's element reset must reach these without touching JS
wire   | ../dartclaw-public/dev/design-system/showcase.html                    | Ladder + card taxonomy + featured-card + divider + composer panels TI14 updates
```


## Constraints & Gotchas

- **Constraint**: canon-first. Every rule this story changes lives in `dev/design-system/`; the served copies are regenerated from it in TI15. An edit made directly in the served `design-system.css` or `tokens.css` fails `check_design_system_sync.sh`.
- **Constraint**: canon **closes** for `tokens.css` / `components.css` / `icons.css` when P1 completes, so this story is the last chance to author a surface-or-chrome rule. That is why TI02 and TI09–TI12 carry the six hoisted rules: a rule left out here cannot be added by the story that needs it, and a P3 story that discovers a gap must stop and report rather than work around it in `app.css`. The closure does **not** cover `DESIGN.md` or `showcase.html` – neither is drift-checked, both stay writable, and S14 reconciles them at release close.
- **Constraint**: `dev/…` and `packages/…` paths are relative to the **`dartclaw-public`** repo root, and every Verify command runs from there. This FIS lives in `dartclaw-private`.
- **Avoid**: sampling `/health` or `/chat` – neither is a web-UI route. `/health` is a JSON API endpoint that answers 200, so it looks like it worked; the health dashboard is `/health-dashboard` and the chat surface is `/sessions/<id>` (`/` redirects there).
- **Critical**: when the remap drops a text pairing below AA, re-tune the *surface* token, never the text token. TI04's `--fg-overlay` change is the single sanctioned text-token move – it repairs a pre-existing AA failure, not a remap regression.
- **Avoid**: introducing raw hex constants for intermediate surfaces. Derive with `color-mix(in oklab, …)` from `tokens.css` so theme switching stays centralized.
- **Critical**: the light theme is a separate mapping, not a mirrored dark ladder. Today `.sidebar`, `.topbar` and `.card` all resolve to `#e6e9ef`, so the shell has no chrome/content separation at all – dark's fix does not transfer.
- **Avoid**: making the new rest-state colour depend on a transition or animation. `prefers-reduced-motion` disables both, and the rest state must still read.
- **Constraint**: "the chrome plane" (S04, TI07) means whatever token `.sidebar` / `.topbar` resolve to *after* TI01 in the theme under test, not a fixed token. Both binding sources now agree the assignment is per-theme – the plan's shared decision puts dark chrome on crust and light chrome "at the mantle tier", matching the PRD's FR1 table (`--bg-crust` `#11111b` dark, `--bg-mantle` `#e6e9ef` light). Never hardcode one token across themes; measure against the resolved value.
- **Constraint**: the card-vs-ground assertion needs a fixed sample point, because TI05 deliberately makes the ground vary across the viewport. Sample the ground **immediately adjacent to the card being measured** (the gap between card columns, or directly above the card), and require ≥ 1.15:1 there; TI16's capture-set check is the same rule applied at every card, not a page-average.
- **Constraint**: every desktop browser capture and pixel-sampling pass owned by this story uses exactly 1440×900; `768px` denotes the responsive-width capture required alongside it.
- **Constraint**: `.form-hint` and the other helper-text consumers live in `app.css`, which this story may not edit. Their only sanctioned fix path is the canon-side `--fg-overlay` value in TI04. A pairing that still fails for an `app.css` colour choice unrelated to the remap is recorded and handed to S05 or S07, not fixed here.
- **Constraint**: "differs" / "three different values" in S03, S04, TI06 and TI07 mean a *perceptible* difference, not a non-zero one. Require ΔE(oklab) ≥ 0.02 between the values being compared – a 99% colour-mix or a one-level hex step passes a bare inequality while leaving OC02 and OC03 unmet.
- **Constraint**: changing the served CSS drifts `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart`, which is tracked and gated by `dev/tools/release_check.sh` § 5. This Workflow run is serialized, so after the final served-CSS change run `dart run dev/tools/embed_assets.dart` before objective verification, then run `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart`; both the parity test and the story's other gates must be green. Re-run both after any remediation that changes an embed root. Never hand-edit the generated file.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Surface tokens place chrome, page ground and cards on three distinct planes in both themes
  - `dev/design-system/tokens.css` `:root` and `[data-theme="light"]`; the PRD's proposed remap is the starting structure, exact values are a visual-validation outcome. Light theme gets its own mapping (card above the ground, chrome below it), not dark's inverted – so the light card does **not** resolve to `--bg-sub-base` (light sub-base sits *below* `--bg-base` and already backs `.msg-content code`, `.notif-item--unread`, the showcase ladder swatch and one `app.css` rule; it is not redefined here). The PRD's illustrative values are a floor to tune *up* from, not a landing zone: they compute to 1.135:1 (dark `#27283b` on `#1e1e2e`) and 1.131:1 (light `#ffffff` on `#eff1f5`), both under the 1.15:1 gate.
  - **Verify**: on the `visual` profile at 1440×900, sample chrome, the ground directly above and beside the card, and the card interior on `/health-dashboard`, `/tasks` and `/memory` in both themes. The three samples are pairwise ΔE(oklab) ≥ 0.02 apart and card-vs-ground contrast is ≥ 1.15:1.

- [ ] **TI02** Surface roles and shell row sizing are complete in canon
  - `dev/design-system/components.css` `#.card`, `#.sidebar`, `#.topbar`, `#body` (audited build: 782 / 94 / 282 / 49). The ground gradient `linear-gradient(170deg, var(--bg-crust) 0%, var(--bg-base) 50%, var(--bg-mantle) 100%)` currently terminates on the card token and must end on a token that is never a card fill. The nine hover fills still pinned to `--bg-mantle` move with the card plane – `#.card:hover` (798), `#.card-metric--accent/-info/-error/-warning:hover` (994/1000/1006/1012) and `#.card-tint-accent/-info/-error/-warning:hover` (1032/1040/1048/1056): no `:hover` fill may resolve *below* the card's rest plane, or hovering visibly sinks the card. Consumes TI01's tokens.
  - Hoisted from S16 per `canon-hoist-manifest.md`: change `.shell`'s second row from `var(--topbar-h) 1fr` to `var(--topbar-h) minmax(0, 1fr)`; give `.content-area` `min-height: 0` and remove its inert `flex: 1`. S16 supplies the app-owned `.page-content { min-height: 0; }` half and validates the assembled shell.
  - **Verify**: at 1440×900 in both themes, `.sidebar` chrome, the page ground immediately adjacent to a card and the card interior are pairwise ΔE(oklab) ≥ 0.02 apart, card-vs-ground contrast is ≥ 1.15:1, and no `body` gradient stop equals the card fill. `rg -n 'grid-template-rows:\s*var\(--topbar-h\) minmax\(0, 1fr\)' dev/design-system/components.css` matches `.shell`; the `.content-area` block contains `min-height: 0` and no `flex: 1`.

- [ ] **TI03** `--shadow-sm` casts a readable elevation band in both themes
  - `dev/design-system/tokens.css` `--shadow-sm` in both blocks – today one visible pixel row in dark and less in light (`0 1px 2px rgba(0,0,0,.06)`). Two-layer ambient+key recipe, keeping the blue-violet `rgba(9,9,26,…)` tint in dark and neutral `rgba(0,0,0,…)` in light per DESIGN.md § Elevation & Depth.
  - **Verify**: a vertical pixel scan across a resting `.card` bottom edge on `/health-dashboard` shows a shadow band of ≥3 rows differing from the ground, in both themes.

- [ ] **TI04** `--fg-overlay` meets WCAG AA on every surface DESIGN.md sanctions it for, in both themes
  - `dev/design-system/tokens.css` `--fg-overlay` in both blocks – 4.44:1 dark on `--bg-base` and 3.47:1 light today, and the light value carries the settings page's primary helper text. DESIGN.md § Accessibility must name the surfaces the token is guaranteed against. Measure after TI01's remap, not before.
  - **Verify**: computed `--fg-overlay` is ≥ 4.5:1 against the card plane, the page-ground plane and `--bg-crust` in both themes, and DESIGN.md § Accessibility names those three surfaces.

- [ ] **TI05** The ambient ground reads as atmospheric rather than uniformly flat in both themes
  - `dev/design-system/tokens.css` `--ambient-a/-b/-c` and the glow placement in `components.css#body` – all three centres currently sit off-canvas (`at 12% -8%`, `at 90% -10%`, `at 50% 112%`), so only their tails are on screen. Keep the mixes below the level where they compete with semantic colour.
  - **Verify**: corner-to-corner ΔE(oklab) across the content ground of `/health-dashboard` is ≥ 0.04 in both themes (audit baseline 0.0185).

- [ ] **TI06** Metric and tint cards carry visible hue at rest, with hover amplifying rather than introducing it
  - `dev/design-system/components.css` `#.card-metric--accent` and siblings, `#.card-tint-accent` and siblings. The section-9 header comment "The tint is hover-only — at rest, these look like standard cards." states the retired contract, as does the DESIGN.md § Cards row "mantle, hover-only color shift"; both go with the behaviour. Consumes TI01's card token.
  - **Verify**: `rg -n "The tint is hover-only" dev/design-system/components.css packages/dartclaw_server/lib/src/static/design-system.css` and `rg -n "hover-only color shift" dev/design-system/DESIGN.md` each return no matches (exit 1); the computed rest background of `.card-metric--accent` and `.card-tint-accent` differs from `.card` by ΔE(oklab) ≥ 0.02, and each variant's `:hover` background differs from its own rest value by ΔE(oklab) ≥ 0.02.

- [ ] **TI07** The sidebar renders three distinct text tiers instead of one colour
  - `dev/design-system/components.css` `#.sidebar-section-label`, `#.session-item`, `#.sidebar-nav-item` – all three resolve to `--fg-sub0` today. Colour tiering only: the § Typography `body-sm`-vs-`label-md` ambiguity these rules inherit is S02's to resolve, so leave every `font-size` declaration untouched.
  - **Verify**: computed `color` of a section label, a resting session title and a nav item are pairwise ΔE(oklab) ≥ 0.02 apart in both themes, each ≥ 4.5:1 against the chrome plane.

- [ ] **TI08** The composer's send button and focus indicator meet the 3:1 non-text minimum in both themes
  - `dev/design-system/components.css` `#.composer-send` expresses its enabled rest state with element-level `opacity: 0.6`, which composites glyph and fill together toward the ground; dim the *fill* instead and hold the glyph at full strength. `#.composer:focus-within` computes to 2.04–2.72:1 against `--bg-base`. DESIGN.md § Composer's "send button rests at 0.6 opacity and wakes to full" and "**Focus is terminal-native and quiet**: no rings, no glow" must be amended to carry an explicit 3:1 floor so "quiet" is bounded. `.btn:disabled` stays at `opacity: 0.4`.
  - **Verify**: on `/sessions/<id>` with the composer non-empty, the enabled resting `.composer-send` glyph-vs-fill is ≥ 3:1 and the `.composer:focus-within` border is ≥ 3:1 against `--bg-base`, in both themes; DESIGN.md § Composer states the 3:1 floor.

- [ ] **TI09** The four `.card-featured-*` gradient borders actually paint, distinct from the card fill
  - Hoisted from S09 TI01 per `docs/specs/0.22.1/canon-hoist-manifest.md`; S09 consumes it. `dev/design-system/components.css` § 10, the four base rules (`:1073, :1093, :1113, :1133`) and the four `:hover` rules (`:1082, :1102, :1122, :1142`). All eight open their `background` shorthand with a bare `var(--bg-mantle) padding-box` layer (`:1076, :1085, :1096, :1105, :1116, :1125, :1136, :1145`). A bare `<color>` is only valid in the `<final-bg-layer>`, so each whole declaration is invalid and dropped and only `border: 1px solid transparent` survives – the audited build measured the border at Δ6 against the fill in light and indistinguishable in dark. Replace each bare colour layer with `linear-gradient(<card-fill>, <card-fill>) padding-box`, where `<card-fill>` is whatever card token TI01 settled, **not** a literal `--bg-mantle`; the `linear-gradient(135deg, …) border-box` layer stays as authored. Consumes TI01/TI02's card plane.
  - **Verify**: `rg -n 'padding-box,' dev/design-system/components.css | rg -v 'gradient\('` returns no matches (the pipeline exits 1) – the eight bare-colour layers listed above are its only matches today. Keep each replacement layer on one source line, or the grep reports a false alarm on the continuation line. On `/health-dashboard` with the service healthy (`health_dashboard.dart:34` applies `card-featured-accent` to the hero card), a pixel sampled on the hero card's border differs from its interior fill by ΔE(oklab) ≥ 0.02 in **both** themes; today the dropped declaration makes the two sample identically.

- [ ] **TI10** Base shell reset styles cover dividers and keyboard skip navigation
  - Hoisted from S12 TI01 per `canon-hoist-manifest.md`; S12 consumes it. `dev/design-system/components.css` § 1 Reset & Base. Six sidebar dividers exist – four static (`templates/sidebar.html:21, :52, :71, :86`) and two injected by `static/controllers/sidebar_sections.js:57, :99` – and **no** rule matching `hr` or `.sidebar-divider` exists in canon or in `app.css` (verified: zero matches in both), so all six render at the UA default `border-style: inset; border-width: 1px`: a beveled 3D groove on chrome that appears on 100% of views. Add the element reset `hr { border: 0; border-top: var(--border); }`, which reaches the JS-injected dividers without touching either file. `.divider` (`:1387`, `height: 1px; border: none`) out-specifies a bare element selector regardless of order, so § 12's gradient dividers are unaffected.
  - Hoisted from S16 TI02 per `canon-hoist-manifest.md`; S16 consumes it. Add `.skip-link` as visually hidden off-screen until `:focus-visible`, then reveal it above the current shell chrome with temporary `z-index: 30`, a readable surface, and the normal focus treatment. S04 TI01 converts that literal to `var(--z-overlay)` when the named stacking ladder exists. S16 inserts `<a class="skip-link" href="#main-content">Skip to content</a>` as `<body>`'s first child and owns focus-target behaviour; this task ships only the reusable canon rule and records the forward handoff to S04.
  - **Verify**: `rg -n '^hr\s*\{' dev/design-system/components.css` returns exactly one match (zero today). On `/sessions/<id>` with the sidebar's Running and Workflows sections populated so the injected dividers are in the DOM, `getComputedStyle` on every `hr.sidebar-divider` reports `borderTopStyle: "solid"` and `borderBottomWidth: "0px"` in both themes (today: `"inset"` / `"1px"`). Regression guard on the gradient dividers: `getComputedStyle` on `showcase.html`'s `hr.divider-fade` and `hr.divider-center` still reports `borderTopWidth: "0px"`. `rg -n '^\.skip-link' dev/design-system/components.css` matches the base and focus rules, and its focus rule contains `z-index: 30`; in the showcase demo it is absent from the visual flow at rest, then keyboard focus reveals it above the current sidebar/topbar chrome. Record in Implementation Observations that S04 TI01 must replace the temporary literal with `var(--z-overlay)`.

- [ ] **TI11** A short chat thread bottom-anchors against its composer
  - Hoisted from S12 TI06 per `canon-hoist-manifest.md`; S12 consumes it. `dev/design-system/components.css#.messages` (`:415`) declares `flex: 1; overflow-y: auto; padding; scroll-behavior` and no `display`, so a short thread stacks from the top and leaves ~62% of the flagship viewport empty. Add the column-flex + auto-top-margin idiom – `.messages { display: flex; flex-direction: column; }` plus `.messages > :first-child { margin-top: auto; }`. Do **not** use `justify-content: flex-end`: it makes overflowed content unreachable above the scroll origin. Also delete the unreachable `.messages:empty::after` (`:422-430`) – dead because `.messages` always receives `emptyStateTemplate()` – which S12's Structural Criteria requires gone from the served copy.
  - Downstream reach, verified in `app.css`: `.task-chat-embed .messages` (`:1856`) **already** declares `display: flex; flex-direction: column` (S12's FIS says it declares no `display`; that is wrong for this one), and `.workflow-step-chat .messages` (`:2613`) declares neither, so it newly inherits the flex display. Both are content-sized under a `max-height` with no free space, so the anchoring is inert on both – validate them for layout regression, not for anchoring. `.msg`'s `margin: 0 auto var(--sp-4)` (`:437`) keeps centring under flex, and `.messages > :first-child` (0,2,0) out-specifies `.msg` (0,1,0) so the auto top margin holds.
  - **Verify**: `rg -n 'messages:empty' dev/design-system/components.css packages/dartclaw_server/lib/src/static/design-system.css` returns no matches (one match in each today, `:422` and `:424`). On `/sessions/<id>` with a two-turn conversation at 1440×900 in both themes, the last `.msg`'s bottom edge sits within one `--sp-4` of the `.input-area` top border (audit baseline: ~558px above it). A session with more messages than fit the viewport still scrolls to its first message with nothing clipped above the scroll origin. The task-detail embedded chat (`task_detail.html:135`) and the workflow step chat (`workflow_step_detail.html:7`) still render their first message unclipped.

- [ ] **TI12** `.data-table` headers read as a band distinct from the body rows
  - Hoisted from S08 D03 per `canon-hoist-manifest.md`; S08 consumes it. `dev/design-system/components.css` § 14 (`:1566-1588`) gives `.data-table th` caption typography and a `border-bottom` but no `thead` fill, so the header samples identically to the body and every table reads as one undifferentiated block. Add a `.data-table thead` background derived from TI01's surface tokens via `color-mix(in oklab, …)` – no raw hex, and no fill that drops `.data-table th`'s `--fg-sub0` label below 4.5:1. Canon-owned selector, so it cannot be authored app-side.
  - Cascade check, verified in `app.css`: no `background` is declared on `thead`, on `.data-table th`, or on any `.data-table` row outside `tr.row-error` (`:642-643`, tbody only), and `.task-status-group .data-table th` (`:1622-1660`) sets only `white-space` and column widths – so nothing shadows the band. The rule reaches every `.data-table` in the app.
  - **Verify**: on `/tasks`, `/scheduling` and `/memory` in both themes at 1440×900, the sampled `<thead>` fill differs from the first body row's fill by ΔE(oklab) ≥ 0.02 – today the two are identical because canon paints no band – and each `.data-table th` label measures ≥ 4.5:1 against the band it now sits on. `rg -n 'data-table thead' dev/design-system/components.css packages/dartclaw_server/lib/src/static/design-system.css` returns a match in **both** files (neither matches today, exit 1), proving the rule is canon-authored and synced rather than only rendered. Secondary guard – true today and required to stay true, so it catches a later app-side re-authoring rather than this task's own work: `rg -n 'thead' packages/dartclaw_server/lib/src/static/app.css` returns no matches.

- [ ] **TI13** DESIGN.md and its frontmatter describe the ladder, depth and rest-state colour that actually ship
  - `dev/design-system/DESIGN.md` `colors:` frontmatter, § Colors, § Surface ladder (7 levels), § Body background, § Elevation & Depth, § Cards, § Composer, § Accessibility – plus the `/* Cards, sidebar, topbar */` role comment on `--bg-mantle` in `tokens.css`. Reflects TI01–TI12's surface and depth contracts; no documented behaviour may lack backing CSS. Four hoisted rules are documented here: the featured-card border grammar in § Cards, the `hr` reset in § Gradient dividers (`:715`), the thread anchoring in § Messages (`:679`), and the header band in a short new § Data tables entry. S16 owns the assembled shell-row and skip-navigation behaviour contracts in DESIGN.md alongside its `.page-content` and layout markup changes. DESIGN.md carries no data-table section today, so the rule S08 consumes would otherwise ship undocumented.
  - **Verify**: `rg -n "Cards, sidebar, topbar" dev/design-system/ packages/dartclaw_server/lib/src/static/tokens.css` returns no matches (exit 1); every `bg-*` value in the DESIGN.md frontmatter equals the corresponding `tokens.css` declaration; `rg -n 'Data tables' dev/design-system/DESIGN.md` returns a match (zero today) and the entry names the header-band contract.

- [ ] **TI14** showcase.html demonstrates the revised ladder, resting colour, shell sizing and skip navigation
  - `dev/design-system/showcase.html` § Surface Ladder swatches, § Card Taxonomy (metric and tint panels), § Composer, and the Full Layout demo. Showcase is the reference for what the system can do, so the rest-state treatments must be visible without hovering. Existing markup already covers three of the six hoisted rules – `.card-featured-accent` / `-error` (`:341, :349, :947`), `hr.divider-*` (`:281, :308, :319, :336, :356, :520, :522`) and a `.messages` block (`:1065`) – so they need no new panel, only re-checking. Extend the Full Layout demo so `.shell` / `.content-area` sizing can be inspected and add a focusable `.skip-link` specimen whose rest and focus states prove TI02. The `.data-table` band has **no** showcase demo because showcase carries no table markup at all; leave it that way and record the gap for S14's doc reconciliation rather than adding a panel here.
  - **Verify**: opening `showcase.html` in both themes shows the ladder stepping monotonically, the metric and tint cards tinted with no pointer over them, each `.card-featured-*` panel's border distinct from its fill, the Full Layout shell resolving its second row through `minmax(0, 1fr)`, and the `.skip-link` appearing only on keyboard focus; `rg -o 'style="' dev/design-system/showcase.html | wc -l` returns ≤ 218, the pre-story occurrence count (`rg -c` counts matching *lines*, 212, and would miss a second `style=` added to an existing line).

- [ ] **TI15** The served CSS and tracked embedded bundle match the final canon
  - `packages/dartclaw_server/lib/src/static/tokens.css` and `design-system.css` each carry the two-line `/* Synced from dev/design-system/<file> on YYYY-MM-DD.` + `   sha256: <hash> */` header followed by the canon file verbatim from line 3. `icons.css` is not part of this story. After the last value re-tuned during TI16 and the final re-sync, run `dart run dev/tools/embed_assets.dart` before objective verification.
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0 and prints no `design-system drift: design-system.css`; `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` passes; `git status --porcelain packages/dartclaw_server/lib/src/static/` lists only `tokens.css` and `design-system.css`; `rg -n '#[0-9a-fA-F]{3,8}\b' dev/design-system/components.css` returns no matches (exit 1) – the pre-story count is zero, so every intermediate surface derives via `color-mix(in oklab, …)`.

- [ ] **TI16** All 23 surfaces are re-validated in both themes at 1440×900 and 768px against the audit baseline
  - `bash dev/testing/profiles/visual/run.sh` (port 3338) is the only profile that renders all 23 surfaces; compare against the audit's 92-screenshot capture. Per VISUAL-VALIDATION-WORKFLOW.md, a screenshot alone is not sufficient evidence for a CSS-driven visual – pair every check with `getComputedStyle`.
  - **Verify**: every surface captured in both themes at 1440×900 and 768px; on every desktop surface where all three planes are present, the sampled chrome, adjacent page ground and card plane are pairwise ΔE(oklab) ≥ 0.02 apart; no text pairing is below 4.5:1 (3:1 for ≥18px bold) and no card-vs-ground pairing is below 1.15:1 in the capture set.

- [ ] **TI17** The `app.css` rules the re-tone displaces are recorded for S05, in the canonical FIS
  - S05 TI05 repoints every `app.css` rule that hard-codes a surface token whose plane role changed here; that hand-off has no artifact unless this story writes one. Enumerate each such rule in this FIS's **Implementation Observations** as a markdown table whose every row *begins* with `| app.css:<line>` – followed by the selector, the token it hard-codes, the plane role that token serves after TI01, and the role the rule intends (chrome / page ground / card / well). The starting set is the 17 `--bg-mantle` references reported by `rg -n 'bg-mantle' packages/dartclaw_server/lib/src/static/app.css` (audited build: lines 341, 560, 591, 616, 643, 951, 1021, 1740, 1853, 1872, 1908, 2029, 2051, 2090, 3116, 3148, 3653); extend it with any `--bg-base` / `--bg-crust` reference whose role also moved, and mark rows where the existing token still serves the intended role so S05 can skip them rather than re-deriving the set. This is a record, not a fix – S05 owns the repointing, and no `app.css` line changes here.
  - Per the plan's `executionNotes`, the record lands in the **canonical private FIS** at `../dartclaw-private/docs/specs/0.22.1/fis/s01-canon-surface-ladder-depth-colour-rest-states.md`, not only in the `dev/bundle/` copy – the bundle is deleted before merge, so a bundle-only record reaches S05 as nothing at all. Nothing in the private repo is auto-committed; the operator commits.
  - **Verify**: `rg -c '^\| ?app\.css:[0-9]+' ../dartclaw-private/docs/specs/0.22.1/fis/s01-canon-surface-ladder-depth-colour-rest-states.md` returns ≥ the count `rg -c 'bg-mantle' packages/dartclaw_server/lib/src/static/app.css` reported at story start (17 in the audited build). Today that grep returns no matches (exit 1) – the Implementation Observations block reads `_No observations recorded yet._` – and the row-anchored pattern cannot be satisfied by the prose line numbers this FIS already carries. Every line number the `app.css` grep reports appears as a row, and every row names both a hard-coded token and an intended plane role.

### Testing Strategy
- No automated test layer covers this story – the workspace has no CSS or visual-regression suite. Verification is pixel sampling plus `getComputedStyle` on the running `visual` profile (`[TI01,TI02,TI03,TI05,TI06,TI07,TI08,TI09,TI10,TI11,TI12,TI16]`), string assertions over the canon files (`[TI06,TI09,TI10,TI11,TI13,TI14]`), the drift fitness check (`[TI15]`), and a grep over this FIS itself (`[TI17]`). CSS present in source does not prove it renders – both halves of every check are required.

### Validation
<!-- Standard exec-spec validation is sufficient; TI16 is the story's own visual gate. -->

### Execution Contract
- TI15 is not a one-shot step: any value re-tuned during TI16's validation loop must be re-synced, then `dart run dev/tools/embed_assets.dart`, the generated parity test and `check_design_system_sync.sh` must be re-run before the story closes. Canon, served CSS and the tracked embedded bundle may not diverge at the story boundary.
- TI15's sync is also a *precondition* of every Verify that samples the running server (TI01–TI12, TI16), not only a trailing gate. The `visual` profile serves `packages/dartclaw_server/lib/src/static/`; it never reads `dev/design-system/`, so a canon-only edit is invisible to the browser until it is copied across. TI15's position in the task list is its final gate, not its only execution.
- The six hoisted canon rules land through TI02 and TI09–TI12 before TI13/TI14 document or demonstrate them and before TI15's sync. TI09 and TI12 additionally consume TI01's settled card and surface tokens, so neither can be authored before the ladder is fixed.
- TI17 writes to this FIS in `dartclaw-private`, which implementation does not otherwise touch. Run it against the canonical path (`../dartclaw-private/docs/specs/0.22.1/fis/`), not the `dev/bundle/` copy, and leave the commit to the operator – the private repo is never auto-committed.


## Final Validation Checklist

<!-- Acceptance Scenarios, Structural Criteria and task Verify lines are the completion gates. -->


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only._

**Required entry (TI17) – `app.css` rules displaced by the surface re-tone, for S05 TI05.** Append a table here whose every row begins `| app.css:<line>`, with columns: line, selector, hard-coded token, the plane role that token serves after TI01, and the plane role the rule intends. Cover every match of `rg -n 'bg-mantle' packages/dartclaw_server/lib/src/static/app.css` (17 in the audited build) plus any `--bg-base` / `--bg-crust` reference whose role moved. This block is the only one S05 and S14 read, and it must exist in **this** canonical file, not only in the `dev/bundle/` export.

**Required forward handoff (TI10) – S04 TI01 replaces `.skip-link`'s temporary `z-index: 30` with `var(--z-overlay)` once the named stacking ladder exists.** Record that the temporary literal was visually proven above the current sidebar/topbar chrome before handoff.

_No observations recorded yet._
