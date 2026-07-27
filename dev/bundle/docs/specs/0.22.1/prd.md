# Product Requirements Document: Design-System Refinement & Web UI Polish

> **Context**: ROADMAP entry "0.22.1 — Design-System Refinement & Web UI Polish". Date: 2026-07-25. Status: Draft — not yet planned.
> **Related Assets** (durable): canonical design system `../../../../dartclaw-public/dev/design-system/DESIGN.md` (+ `tokens.css`, `components.css`, `showcase.html`) · [audit-ui-polish-2026-07-25.md](audit-ui-polish-2026-07-25.md) (232 verified findings — the evidence base) · [vendoring-analysis.md](vendoring-analysis.md) (FR8 decision record) · [0.22 PRD](../0.22/prd.md) (what the overhaul did and deliberately deferred) · [0.24 PRD brief](../0.24/prd-brief.md) (the milestone this unblocks).

## Executive Summary

- **Problem**: 0.22 made the Web UI *compliant* with the Afterglow design system. It did not make it *good*. A post-release audit of all 23 web surfaces — 92 screenshots across both themes and two viewports, cross-read against the templates, CSS and canon — produced **232 verified defects**. The root causes are in the canon itself: `.sidebar`, `.topbar`, `.card` and the terminal stop of the body ground gradient are **all `--bg-mantle`**, giving a measured card-vs-ground contrast of **1.07:1** (below just-noticeable-difference); all card colour is `:hover`-gated so **0.50–1.45% of resting content pixels carry any chroma**; three of seven type tiers sit inside a 2px band and absorb ~90% of declarations; and canon ships **no form, tab, or dialog primitives at all** while actively sanctioning `window.confirm()`. The product reads as flat, gray and unfinished — and no amount of page-level adoption can fix a page whose layers are the same colour.
- **Vision**: The design system gains real depth, a usable type hierarchy, and the primitives the app has been forced to invent privately. The Web UI is re-synced onto it, the 64 distinct glitches are closed, and native OS dialogs are gone. DartClaw stops looking like an admin panel and starts looking like the product its positioning claims.
- **Target Users**: (1) **Operators** — get a legible, layered, finished surface; (2) **DartClaw developers** — get canonical form/tab/dialog primitives instead of re-inventing them per page, and a type layer that binds size + weight + leading + tracking so hierarchy stops being hand-derived; (3) **0.24 and every later UI milestone** — build on a refined substrate rather than reworking a shipped one.
- **Success Metrics**:
  1. Card-vs-ground contrast ≥ 1.15:1 in **both** themes, with chrome, page ground and cards on three distinct planes; no page band equals the card fill.
  2. Zero `--text-sm` usages remain; every named DESIGN.md type tier has a backing composite class, demonstrated in `showcase.html`.
  3. Zero `window.alert` / `confirm` / `prompt` call sites in `lib/src/static/controllers/`; DESIGN.md's feedback decision table bans them explicitly.
  4. All 23 surfaces re-validated in both themes at desktop + 768px; UI smoke test (TC-01…TC-31) green; drift check green (`design-system.css` byte-identical to canon).
  5. The 64 distinct glitches from the audit are closed or explicitly deferred with a recorded reason, and every deferral is carried into a durable backlog that outlives this milestone.

### Capabilities at a Glance
- **FR1: Surface & depth revision** _(Must / P0)_ – three distinct planes (chrome / ground / card) in both themes; ground gradient never terminates on a card tone; real light-theme elevation.
- **FR2: Type scale rationalization + composite type layer** _(Must / P0)_ – retire the 13px tier, re-space headings, and ship one class per named tier binding all four properties.
- **FR3: Second layout container tier** _(Must / P0)_ – `--container-wide` for data-dense pages; 900px stays for prose.
- **FR4: Form, tab and dialog primitives in canon** _(Must / P0)_ – the three component families the app was forced to invent privately.
- **FR5: Feedback decision-table rewrite + native dialog eradication** _(Must / P0)_ – ban `alert`/`confirm`/`prompt`; route all nine call sites through one dialog API.
- **FR6: Re-sync + adoption sweep** _(Must / P0)_ – 118 adoption findings; drift check green.
- **FR7: Glitch sweep** _(Must / P0)_ – 64 distinct defects, 23 high-severity.
- **FR8: Local vendoring of runtime dependencies** _(Should / P1)_ – htmx, marked and JetBrains Mono self-hosted; splits cleanly if the release runs long.
- **FR9: Documentation sync** _(Must / P0)_ – DESIGN.md, showcase, `VENDORS.md`, affected user guides.

### Scope Highlights
- **In scope**: canon revision (surfaces, type, layout tier, form/tab/dialog primitives, feedback table); re-sync + adoption; the glitch sweep; native dialog removal; optional vendoring; doc sync.
- **Out of scope**: anything requiring backend work; chat/session *features* (0.24); workflow surfaces (0.25/0.26); CLI and channel parity (Cross-Surface UX); task IA overhaul (OH-9).
- **MVP boundary**: FR1–FR7. FR8 (vendoring) splits cleanly into its own release if needed.

### Key Constraints, Assumptions & Dependencies
- *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.
- *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).
- *Dependency:* **0.24's Phase 0 components already live in canon** (`.composer`, `.tool-call`, `.approval-card`, `.notif-item`, `.palette-item`, `.chip`). FR1/FR2 change them by construction. Running this release **before** 0.24 planning avoids reworking shipped chat components.
- *Assumption:* ~13 stories. Every story is CSS/template/controller work with zero backend surface.

## Problem Definition

### Problem Statement
0.22 delivered exactly what it specified: a verbatim-synced, drift-checked CSS foundation with per-page primitive adoption. Its own acceptance criteria hold — **zero** inline `style=` attributes, **zero** template-local `<style>` blocks, 215 of 220 `font-size` declarations tokenized. But its success criterion was a page-by-page compliance table reading "good", and "new UX features" was an explicit non-goal. A surface can be fully compliant with a design system whose own type scale, surface ladder and component set are thin — and that is what shipped. The perceived quality gap is therefore **not a 0.22 execution failure; it is a canon deficiency that 0.22 faithfully propagated.**

### Evidence & Context

From [audit-ui-polish-2026-07-25.md](audit-ui-polish-2026-07-25.md) — 232 findings confirmed after an adversarial verification pass that killed 19:

- **Four roles share one token.** `.sidebar` (components.css:96), `.topbar` (:283), `.card` (:783) all use `--bg-mantle`, and `body`'s ground gradient (:55) is `linear-gradient(170deg, crust 0%, base 50%, mantle 100%)` — terminating *on* the card fill. Through the upper half of every page the ground (`--bg-base` #1e1e2e) is **lighter** than the cards on it (`--bg-mantle` #181825). Measured contrast **1.07:1**.
- **Colour is hover-gated.** `.card-metric--*` and `.card-tint-*` hold their entire treatment in `:hover`; **0.50%–1.45%** of resting content pixels carry chroma.
- **Type hierarchy collapses.** `--text-xs` 12 / `--text-sm` 13 / `--text-base` 14 are three tiers within 2px, absorbing 103 + 79 of 220 `app.css` declarations. DESIGN.md names **8 tiers** but the CSS ships only raw size tokens plus two utilities, so every consumer hand-derives four properties and reliably picks the smallest.
- **Missing primitives.** Canon has **zero** input/label/checkbox/radio/toggle rules while templates use a bespoke form family 250+ times; § Native selects is documented with **no backing CSS**; there is no dialog/modal frame at all; and the feedback decision table **sanctions `confirm()`**. Settings consequently invented its own controls and **two divergent tab bars**.
- **One container for everything.** `--container-max: 900px` on prose and data alike leaves ~280px of empty gutter at 1440px while tables are crushed — the direct cause of the `PROVID/ER` / `CREATE/D` / `TO/KE/NS` mid-word header wrapping on Tasks.
- **Health dashboard uses neither `.metric-value` nor `.meter`** — five other templates do. The app's dashboard renders every KPI as 13px label/value text.
- **64 distinct glitches**, 23 high-severity, including: wiki documents served as raw `text/plain`; `.project-card-*` classes with zero CSS in any stylesheet; an unstyled search field showing browser UA chrome; sidebar dividers rendering as the browser default beveled `<hr>`; dead dirty-state tracking in settings (Save always enabled, unsaved edits vanish on tab switch); guard-editor Delete firing with no confirmation; **no global htmx error handler** across 28 `hx-get` sites.
- **Runtime is clean.** Console/network sweep across 16 surfaces: zero JS errors, zero failed requests. The problems are visual and structural.

## Scope

### In Scope
1. **Canon revision** in `dartclaw-public/dev/design-system/` — surface ladder, colour rest-states, type scale + composite type layer, wide-container tier, form/tab/dialog primitives, feedback decision table, showcase demonstrations.
2. **Re-sync** of `design-system.css` / `tokens.css` into `packages/dartclaw_server/lib/src/static/` with the drift check green, plus purge of the app-local duplicates the new primitives obsolete.
3. **Adoption sweep** across the 118 adoption findings — metric/meter adoption, wide-container application, type-tier migration, empty/loading/error state coverage.
4. **Glitch sweep** — the 64 distinct defects.
5. **Native dialog eradication** — nine call sites across four controllers.
6. **Local vendoring** (FR8) — htmx, marked, JetBrains Mono.
7. **Documentation sync** — DESIGN.md, showcase.html, `VENDORS.md`, affected user guides, wireframe `deviations.md`.

### Out of Scope
- Anything with a backend dependency. Two audit findings were classified `feature` for exactly this reason and are excluded.
- Chat and session *features* — thinking indicator content, tool-call cards, streaming semantics, sidebar inbox, Cmd+K, notification centre. All 0.24.
- Workflow authoring/run surfaces (0.25/0.26); CLI and channel surfaces, task IA overhaul, run replay, guard-verdict timeline, cost dashboard (Cross-Surface UX).
- New UX capabilities of any kind. This release adds no features; it refines what exists.

### MVP Boundary
**FR1–FR7.** FR8 (vendoring) is independently shippable and splits into a follow-up point release if the milestone runs long. FR9 rides whichever stories touch the documented surface.

## Functional Requirements

### User Stories

| ID | As a… | I want… | So that… |
|----|-------|---------|----------|
| US01 | Operator | pages where cards, chrome and background are visually distinct | I can parse a screen at a glance instead of hunting for 1px borders |
| US02 | Operator | headings, body text and metadata to be visibly different sizes | I can scan a page hierarchically rather than reading everything at 13px |
| US03 | Operator | dashboard numbers presented as numbers | the health and memory pages tell me system state without reading label/value prose |
| US04 | Operator | destructive confirmations that look like the product | I am not thrown into an OS dialog that names a UUID instead of the thing I am deleting |
| US05 | Operator | data tables that use the width of my screen | column headers stop breaking mid-word |
| US06 | Operator | a UI that works offline / air-gapped | the product I self-host does not depend on three third-party CDNs |
| US07 | Contributor | canonical form, tab and dialog primitives | I compose new UI instead of inventing a fourth private variant |
| US08 | Contributor | one class per named type tier | hierarchy is applied, not re-derived from four properties each time |

### Feature Specifications

#### FR1: Surface & depth revision
**Description**: Give chrome, page ground and cards three distinct planes in both themes. Stop the body gradient short of any card tone. Move a fraction of each colour variant's treatment to the rest state. Give the light theme its own surface mapping and a real `--shadow-sm` rather than a mirrored dark ladder.

Proposed dark remap (exact values to be settled by visual validation; the *structure* is the decision):

| Role | Current | Proposed |
|---|---|---|
| Chrome (`.sidebar`, `.topbar`) | `--bg-mantle` #181825 | `--bg-crust` #11111b |
| Page ground (gradient end stop) | `--bg-mantle` #181825 | `--bg-base` #1e1e2e |
| Card rest | `--bg-mantle` #181825 | `--bg-sub-base` |
| Card hover | `--bg-mantle` + accent radial wash | re-derive from the new card rest tone |

> Corrected 2026-07-25 during planning: an earlier draft of this table listed card hover as `--bg-surface0` #313244. It is not — `.card:hover` (components.css:793-800) paints an accent radial gradient over `var(--bg-mantle)`, the *same* token as card rest, and it is one of ~9 hover fills pinned to that token. Moving the card rest token therefore moves hover with it; hover cannot be left "unchanged".

Light theme: card `#ffffff` on a tinted `--bg-base` #eff1f5 ground, chrome `--bg-mantle` #e6e9ef; raise `--shadow-sm` from `0 1px 2px rgba(0,0,0,.06)` to a perceptible elevation.

**Acceptance Criteria**:
- [ ] Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.
- [ ] `.sidebar` / `.topbar` resolve to a token distinct from `.card` in both themes.
- [ ] `.card-metric--*` and `.card-tint-*` carry visible hue at rest; hover amplifies rather than introduces.
- [ ] All 23 surfaces pass visual validation in both themes at desktop + 768px.

**Priority**: Must / P0

#### FR2: Type scale rationalization + composite type layer
**Description**: Retire `--text-sm` as a distinct tier (alias to `--text-base` during migration, then remove). Move `--text-lg` from 16px to 18px so section headings separate from body. Keep 12 / 20 / 24 / 32. Add one composite class per named DESIGN.md tier — `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric` — each binding font-size + weight + line-height + letter-spacing together, demonstrated in `showcase.html`. Raw `--text-*` tokens remain for one-offs only.

**Acceptance Criteria**:
- [ ] Zero `--text-sm` usages in `app.css` and `design-system.css`.
- [ ] Every tier in the DESIGN.md § Typography table has a backing composite class and a showcase panel.
- [ ] The DESIGN.md table is updated so `body-sm` is no longer a legitimate choice.

**Priority**: Must / P0

#### FR3: Second layout container tier
**Description**: Add `--container-wide: 1280px` and a `.content-inner--wide` / `.page-inner--wide` modifier; document beside `container-max` in DESIGN.md § Layout. Apply to tasks, health, memory, scheduling, workflows, audit. Keep 900px for chat, session-info, knowledge results and settings forms. Add `white-space: nowrap` to `.data-table th`.

**Acceptance Criteria**:
- [ ] No table header wraps mid-word at any viewport ≥ 1024px.
- [ ] Prose surfaces retain the 900px measure.

**Priority**: Must / P0

#### FR4: Form, tab and dialog primitives in canon
**Description**: Add a Forms section to `components.css` (`.form-field` / `-label` / `-input` / `-select` / `-textarea` / `-error`, checkbox, toggle), back the already-documented § Native selects with real CSS, add one `.tabs` / `.tab` component, and add `.dialog` (frame, `::backdrop` scrim, `-header` / `-body` / `-footer` / `-actions`, `--sm|--md` width ladder, `.dialog--confirm` variant). Promote the app's proven private `.task-dialog` recipe rather than inventing a new one. Document all three families in DESIGN.md and showcase.html; then delete the app-local duplicates and fold `.settings-tabs` / `.tab-bar` onto the canonical component.

**Acceptance Criteria**:
- [ ] `.form-*`, `.tabs`/`.tab`, `.dialog` exist in canon, documented and demonstrated.
- [ ] No app-local re-implementation of any of the three remains; only one tab bar ships.

**Priority**: Must / P0

#### FR5: Feedback decision-table rewrite + native dialog eradication
**Description**: Rewrite the DESIGN.md feedback decision table to five rows — persistent problem → banner; transient success/error → toast; destructive confirmation → `.dialog--confirm`; row-scoped destructive → the inline `.delete-confirm-bar` the app already ships; needs structured input → `.dialog` with real form controls — and add an explicit **"native `alert()` / `confirm()` / `prompt()` are banned"** line, mirroring the § Native selects prohibition. Then route all nine call sites through one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js`. For the three `hx-confirm` templates, add a single `htmx:confirm` listener in `dc_shell_controller.js` — zero template edits, and all future `hx-confirm` uses convert automatically.

Call sites: `dc_shell_controller.js:369` (delete chat), `:477` (restart), `:488,489,491` (`alert()` on failure); `dc_scheduling_controller.js:403` (delete scheduled task — passes the **id**, not the title); `dc_projects_controller.js:192` (remove project); `dc_settings_controller.js:569,573` (`window.prompt()` for guard extension value and file-access level).

**Acceptance Criteria**:
- [ ] Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.
- [ ] The two `prompt()` config editors are real forms in a `.dialog`, not modal-ised prompts.
- [ ] The `alert()` failure paths surface through the toast component.
- [ ] Destructive confirmations name the object (title, not id).

**Priority**: Must / P0

#### FR6: Re-sync + adoption sweep
**Description**: Re-sync canon into the served CSS with the drift check green, purge app-local duplicates obsoleted by FR4, then work the 118 adoption findings. Priority clusters: health/memory/session-info metric + meter adoption; wide-container application; type-tier migration; empty/loading/error state coverage (31 findings — em-dash placeholders where an absent-value treatment belongs, undesigned empty states, no skeleton/`.scan-bar` loading treatment).

**Acceptance Criteria**:
- [ ] Drift check green; `design-system.css` byte-identical to canon.
- [ ] `health_dashboard.html` uses `.metric-value` and `.meter`.
- [ ] Every page has a designed empty state; no bare em-dash stands in for an absent value.

**Priority**: Must / P0

#### FR7: Glitch sweep
**Description**: Close the 64 distinct defects catalogued in the audit. No design decisions required. Includes a global data-formatting pass — timestamps currently appear in three unrelated formats, never roll over past days, and one page prints raw ISO-8601 with milliseconds.

**Acceptance Criteria**:
- [ ] All 23 high-severity glitches closed.
- [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
- [ ] Every deferral is carried into a durable backlog – with its reason, and without a target milestone – so a later milestone finds it without reading this release's own closing records. Recording a reason inside a milestone-scoped artifact does not satisfy this: that artifact is closed along with the milestone.
- [ ] UI smoke test (TC-01…TC-31) green.

**Priority**: Must / P0

#### FR8: Local vendoring of runtime dependencies
**Description**: Self-host htmx 2.0.8 (50.0 KB), marked 15 (39.0 KB) and JetBrains Mono 400/500/600 latin + latin-ext woff2 (~30.6 KB each). See [vendoring-analysis.md](vendoring-analysis.md) for the full rationale, cost and mechanics.

**Acceptance Criteria**:
- [ ] No external origin appears in `layout.html` or the CSP; `font-src 'self'`.
- [ ] `dev/tools/embed_assets.dart` handles `.woff2` as binary; `embedded_static_handler.dart` serves `font/woff2`.
- [ ] `VENDORS.md` documents all three with upgrade instructions.
- [ ] The UI renders identically with all external origins blocked — proven by a new offline smoke check.

**Priority**: Should / P1 *(splits cleanly into its own point release)*

#### FR9: Documentation sync
**Description**: Update DESIGN.md (typography table, surface ladder, layout tiers, three new component families, rewritten feedback table), `showcase.html` (type tiers, forms, tabs, dialog), `VENDORS.md`, the wireframe `deviations.md`, and any user guide whose screenshots or documented behaviour the change invalidates.

**Acceptance Criteria**:
- [ ] No documented behaviour in DESIGN.md lacks backing CSS (closes the § Native selects gap).
- [ ] `deviations.md` records any intentional divergence.

**Priority**: Must / P0

### User Flows
1. **Canon** — surface ladder + colour rest states → type scale + composite layer → wide container → form/tab/dialog primitives → feedback table rewrite. Each validated in showcase before the app sees it.
2. **Sync** — re-sync served CSS, drift check green, purge obsoleted app-local duplicates. Single hinge story; everything downstream depends on it.
3. **Adoption + glitches** — parallelised by surface, each gated on visual validation in both themes.
4. **Dialogs** — after the feedback-table rewrite; one API, one `htmx:confirm` listener, two real forms.

### UI Wireframes
Canonical reference: `dartclaw-public/dev/design-system/showcase.html` + `DESIGN.md`. New primitives (forms, tabs, dialog, type tiers) must land in showcase as part of their own story — showcase is the reference for what the system can do, and the audit found several documented-but-unbacked entries.

## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Visual quality | Every surface validated against the revised system | Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline |
| Maintainability | Canon stays the single source of truth | Drift check green; zero app-side edits to synced files; zero re-implementations of the new primitives |
| Performance | No client-side build; bounded payload | Zero new runtime JS deps; FR8 *reduces* runtime origins to zero |
| Accessibility | Contrast + motion + focus | WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone |
| Compatibility | Zero-npm / server-first | Plain CSS + Trellis + Stimulus; no build step |

## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|----------|-------------------|---------------|
| Surface remap breaks WCAG AA text contrast on a re-toned card | Caught by the per-story contrast check before merge | Re-tune the card token, not the text token |
| A page relies on `--text-sm` for a dense table that now overflows at 14px | Column geometry adjusted, or the row uses `.t-caption` (12px) deliberately | Documented as a deviation, not a silent revert to 13px |
| `--container-wide` applied to a prose surface by mistake | Line length exceeds the reading measure | Reviewer/visual-validation catch; the modifier is opt-in, not the default |
| The new `.dialog` is used for a non-blocking notice | Glass overlay used where a banner/toast belongs | The rewritten decision table is the arbiter |
| An external origin is re-introduced after FR8 | CSP blocks it; the page silently loses the feature | The offline smoke check fails the build |
| Canon revision lands while a 0.24 planning branch is open | 0.24's Phase 0 components shift under it | Sequencing: this release completes before 0.24 planning starts |

## Constraints & Assumptions

### Constraints
- **Canon-first.** Drift check forbids app-side edits to canon-owned rules; every visual fix starts in `dev/design-system/`.
- **Zero-npm / server-first**; no build step; no new runtime JS dependencies.
- **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.
- **Scarcity doctrine and existing DESIGN.md doctrine remain in force** except where this PRD explicitly revises them (feedback table, type tiers, surface ladder).

### Assumptions
- ~13 stories; FR1–FR5 are canon-side and small, FR6 is the hinge, FR7–FR8 parallelise.
- The 232 audit findings are the complete defect set for the current build; new findings during implementation are folded in, not re-audited.
- Exact colour values are a visual-validation outcome, not a PRD decision; the *structure* (three planes, ground ≠ card) is fixed here.

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| `v0.22.0` shipped | This is a refinement of what it delivered; the drift-check mechanism it built is the enforcement point |
| Visual testing profile (`dev/testing/profiles/visual`, port 3338) + UI smoke test | Every story is gated on both-theme validation; the profile is the only one that renders all surfaces |
| 0.24 planning **not yet started** | FR1/FR2 change 0.24's Phase 0 components; running after 0.24 means reworking shipped chat components |

## Decisions Log

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| Ship as a point release (0.22.1), not as part of 0.24 or Cross-Surface UX | The Cross-Surface UX backlog contains only two relevant items (QW-10, OH-10) and no item at all for type scale, hierarchy, depth or density — this is new work with no existing home. 0.24 is already over its 10–14 story budget; adding this would force cutting Phase C | (a) pull Cross-Surface UX forward — ~60% is CLI/channel parity, irrelevant to the defect, and still would not fix typography or flatness; (b) integrate into 0.24 — busts sizing, forces cutting the flagship's differentiating half |
| Canon revision before app adoption | Four roles share `--bg-mantle`; no page-level fix can make layers distinct while the layers are the same colour. The drift check also forbids app-side-only fixes | Fix per page in `app.css` (fails CI, and would re-drift the fork 0.22 just removed) |
| Retire `--text-sm` rather than re-space all seven tiers | Three tiers inside 2px is the actual defect; 16/20/24/32 are already sound steps. Removing one tier plus adding composite classes is far less ripple than a full modular re-scale | Full modular scale (1.25 ratio from 14px) — larger blast radius for marginal gain |
| Composite `.t-*` classes rather than more tokens | DESIGN.md already names 8 tiers; the gap is that nothing binds size+weight+leading+tracking, so consumers hand-derive and default to the smallest | More granular size tokens (does not address the hand-derivation problem) |
| Promote the app's private `.task-dialog` into canon rather than design a new modal | It is a proven, shipped recipe; promoting it is cheaper and lower-risk than inventing a parallel one | Design a new dialog from scratch |
| Delete the `confirm()` sanction from DESIGN.md | It was the explicit blocker 0.22 recorded for deferring this work; nothing else unblocks the nine call sites | Keep the sanction and modal-ise only the worst cases (leaves the inconsistency and the `prompt()` config editors) |
| Vendoring (FR8) rides this release but splits cleanly | It is a self-contained correctness/privacy fix with an offline test gate; bundling it avoids a second release, but nothing else depends on it | Separate point release (fine); leave as-is (contradicts ADR-047's stated no-network-dependency promise) |
| Exact surface/colour values deferred to visual validation | Perceptual outcomes cannot be settled in a document; the structural rule (three planes, ground ≠ card, ≥1.15:1) is what needs fixing in the PRD | Specify exact hex in the PRD (over-specification; would be re-tuned anyway) |
