# Product Requirements Document and Delivery Record: 0.22.1

> **Context**: ROADMAP entry "0.22.1 – Design-System Refinement & Web UI Polish". Opened: 2026-07-25. Status: Implemented – original 16-story plan completed 2026-07-30; post-plan delivery record reconciled through 2026-08-04; final release validation pending; release not yet tagged.
> **Implementation reference**: canonical design system [`DESIGN.md`](../../../../design-system/DESIGN.md) (+ `tokens.css`, `components.css`, `showcase.html`). The audit evidence, vendoring rationale, canonical private 0.22 PRD, and 0.24 brief were authoring inputs; their release-relevant decisions are preserved here.
>
> **Authority**: This document is the complete release-scope and delivery record for 0.22.1. FR1–FR9 preserve the original planned intent. `Delivery Record` preserves what completed, while `Adjacent & Interlude Work` records every post-plan addition without pretending it was part of the original scope.

## Executive Summary

- **Problem**: 0.22 made the Web UI *compliant* with the Afterglow design system. It did not make it *good*. A post-release audit of all 23 web surfaces — 92 screenshots across both themes and two viewports, cross-read against the templates, CSS and canon — produced **232 verified defects**. The root causes are in the canon itself: `.sidebar`, `.topbar`, `.card` and the terminal stop of the body ground gradient are **all `--bg-mantle`**, giving a measured card-vs-ground contrast of **1.07:1** (below just-noticeable-difference); all card colour is `:hover`-gated so **0.50–1.45% of resting content pixels carry any chroma**; three of seven type tiers sit inside a 2px band and absorb ~90% of declarations; and canon ships **no form, tab, or dialog primitives at all** while actively sanctioning `window.confirm()`. The product reads as flat, gray and unfinished — and no amount of page-level adoption can fix a page whose layers are the same colour.
- **Vision**: The design system gains real depth, a usable type hierarchy, and the primitives the app has been forced to invent privately. The Web UI is re-synced onto it, the 64 distinct glitches are closed, and native OS dialogs are gone. DartClaw stops looking like an admin panel and starts looking like the product its positioning claims.
- **Target Users**: (1) **Operators** — get a legible, layered, finished surface; (2) **DartClaw developers** — get canonical form/tab/dialog primitives instead of re-inventing them per page, and a type layer that binds size + weight + leading + tracking so hierarchy stops being hand-derived; (3) **0.24 and every later UI milestone** — build on a refined substrate rather than reworking a shipped one.
- **Delivery Status**: FR1–FR9 and all 16 implementation stories are complete. Subsequent 0.22.1 work refined the visual direction and session navigation, corrected deployment/onboarding/Signal behavior, added native typing indication for Signal and WhatsApp, and made turn-scoped tool policies enforceable on every runner. Automated gates are green; fresh post-interlude visual evidence and live paired-channel checks remain release-close work. The detailed delivery and verification record is canonical below.
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
- **Original-plan exclusions**: backend work; chat/session features; workflow surfaces; CLI/channel parity; task IA overhaul. Post-plan additions are recorded separately and do not retroactively alter FR1–FR9.
- **Delivered post-plan additions**: Phosphor Aurora refinement; reusable New Chat/session lifecycle; System navigation and turn-status refinement; runtime/deployment/onboarding/Signal corrections; native Signal/WhatsApp typing; turn-scoped tool-policy enforcement.
- **Original MVP boundary**: FR1–FR7. FR8 could split independently but ultimately shipped in 0.22.1; FR9 followed every documented surface.

### Key Constraints, Assumptions & Dependencies
- *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.
- *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).
- *Dependency:* **0.24's Phase 0 components already live in canon** (`.composer`, `.tool-call`, `.approval-card`, `.notif-item`, `.palette-item`, `.chip`). FR1/FR2 change them by construction. Running this release **before** 0.24 planning avoids reworking shipped chat components.
- *Original-plan assumption:* CSS/template/controller work with zero backend surface. Planning resolved to 16 stories. Later user-authorized interludes deliberately expanded the release boundary and are recorded separately below.

## Problem Definition

### Problem Statement
0.22 delivered exactly what it specified: a verbatim-synced, drift-checked CSS foundation with per-page primitive adoption. Its own acceptance criteria hold — **zero** inline `style=` attributes, **zero** template-local `<style>` blocks, 215 of 220 `font-size` declarations tokenized. But its success criterion was a page-by-page compliance table reading "good", and "new UX features" was an explicit non-goal. A surface can be fully compliant with a design system whose own type scale, surface ladder and component set are thin — and that is what shipped. The perceived quality gap is therefore **not a 0.22 execution failure; it is a canon deficiency that 0.22 faithfully propagated.**

### Evidence & Context

The source audit recorded 232 findings confirmed after an adversarial verification pass that killed 19:

- **Four roles share one token.** `.sidebar` (components.css:96), `.topbar` (:283), `.card` (:783) all use `--bg-mantle`, and `body`'s ground gradient (:55) is `linear-gradient(170deg, crust 0%, base 50%, mantle 100%)` — terminating *on* the card fill. Through the upper half of every page the ground (`--bg-base` #1e1e2e) is **lighter** than the cards on it (`--bg-mantle` #181825). Measured contrast **1.07:1**.
- **Colour is hover-gated.** `.card-metric--*` and `.card-tint-*` hold their entire treatment in `:hover`; **0.50%–1.45%** of resting content pixels carry chroma.
- **Type hierarchy collapses.** `--text-xs` 12 / `--text-sm` 13 / `--text-base` 14 are three tiers within 2px, absorbing 103 + 79 of 220 `app.css` declarations. DESIGN.md names **8 tiers** but the CSS ships only raw size tokens plus two utilities, so every consumer hand-derives four properties and reliably picks the smallest.
- **Missing primitives.** Canon has **zero** input/label/checkbox/radio/toggle rules while templates use a bespoke form family 250+ times; § Native selects is documented with **no backing CSS**; there is no dialog/modal frame at all; and the feedback decision table **sanctions `confirm()`**. Settings consequently invented its own controls and **two divergent tab bars**.
- **One container for everything.** `--container-max: 900px` on prose and data alike leaves ~280px of empty gutter at 1440px while tables are crushed — the direct cause of the `PROVID/ER` / `CREATE/D` / `TO/KE/NS` mid-word header wrapping on Tasks.
- **Health dashboard uses neither `.metric-value` nor `.meter`** — five other templates do. The app's dashboard renders every KPI as 13px label/value text.
- **64 distinct glitches**, 23 high-severity, including: wiki documents served as raw `text/plain`; `.project-card-*` classes with zero CSS in any stylesheet; an unstyled search field showing browser UA chrome; sidebar dividers rendering as the browser default beveled `<hr>`; dead dirty-state tracking in settings (Save always enabled, unsaved edits vanish on tab switch); guard-editor Delete firing with no confirmation; **no global htmx error handler** across 28 `hx-get` sites.
- **Runtime is clean.** Console/network sweep across 16 surfaces: zero JS errors, zero failed requests. The problems are visual and structural.

## Scope

### Original Planned Scope
1. **Canon revision** in `dartclaw-public/dev/design-system/` — surface ladder, colour rest-states, type scale + composite type layer, wide-container tier, form/tab/dialog primitives, feedback decision table, showcase demonstrations.
2. **Re-sync** of `design-system.css` / `tokens.css` into `packages/dartclaw_server/lib/src/static/` with the drift check green, plus purge of the app-local duplicates the new primitives obsolete.
3. **Adoption sweep** across the 118 adoption findings — metric/meter adoption, wide-container application, type-tier migration, empty/loading/error state coverage.
4. **Glitch sweep** — the 64 distinct defects.
5. **Native dialog eradication** — nine call sites across four controllers.
6. **Local vendoring** (FR8) — htmx, marked, JetBrains Mono.
7. **Documentation sync** — DESIGN.md, showcase.html, `VENDORS.md`, affected user guides, wireframe `deviations.md`.

### Original Plan Out of Scope

These boundaries governed FR1–FR9 and the 16-story plan. The user-authorized additions under `Adjacent & Interlude Work`
expanded the delivered release after plan completion; they preserve rather than erase this original decision history.

- Anything with a backend dependency. Two audit findings were classified `feature` for exactly this reason and are excluded.
- Chat and session *features* — thinking indicator content, tool-call cards, streaming semantics, sidebar inbox, Cmd+K, notification centre. All 0.24.
- Workflow authoring/run surfaces (0.25/0.26); CLI and channel surfaces, task IA overhaul, run replay, guard-verdict timeline, cost dashboard (Cross-Surface UX).
- New UX capabilities of any kind. The original plan adds no features; user-authorized post-plan capabilities are recorded under `Adjacent & Interlude Work`.

### MVP Boundary
**Original boundary: FR1–FR7.** FR8 was independently shippable but ultimately delivered in 0.22.1. FR9 rode every story that changed a documented surface. Later additions are governed by their adjacent/interlude entries rather than this original MVP boundary.

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
- [x] Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.
- [x] `.sidebar` / `.topbar` resolve to a token distinct from `.card` in both themes.
- [x] `.card-metric--*` and `.card-tint-*` carry visible hue at rest; hover amplifies rather than introduces.
- [x] All 23 surfaces pass visual validation in both themes at desktop + 768px.

**Priority**: Must / P0

#### FR2: Type scale rationalization + composite type layer
**Description**: Retire `--text-sm` as a distinct tier (alias to `--text-base` during migration, then remove). Move `--text-lg` from 16px to 18px so section headings separate from body. Keep 12 / 20 / 24 / 32. Add one composite class per named DESIGN.md tier — `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric` — each binding font-size + weight + line-height + letter-spacing together, demonstrated in `showcase.html`. Raw `--text-*` tokens remain for one-offs only.

**Acceptance Criteria**:
- [x] Zero `--text-sm` usages in `app.css` and `design-system.css`.
- [x] Every tier in the DESIGN.md § Typography table has a backing composite class and a showcase panel.
- [x] The DESIGN.md table is updated so `body-sm` is no longer a legitimate choice.

**Priority**: Must / P0

#### FR3: Second layout container tier
**Description**: Add `--container-wide: 1280px` and a `.content-inner--wide` / `.page-inner--wide` modifier; document beside `container-max` in DESIGN.md § Layout. Apply to tasks, health, memory, scheduling, workflows, audit. Keep 900px for chat, session-info, knowledge results and settings forms. Add `white-space: nowrap` to `.data-table th`.

**Acceptance Criteria**:
- [x] No table header wraps mid-word at any viewport ≥ 1024px.
- [x] Prose surfaces retain the 900px measure.

**Priority**: Must / P0

#### FR4: Form, tab and dialog primitives in canon
**Description**: Add a Forms section to `components.css` (`.form-field` / `-label` / `-input` / `-select` / `-textarea` / `-error`, checkbox, toggle), back the already-documented § Native selects with real CSS, add one `.tabs` / `.tab` component, and add `.dialog` (frame, `::backdrop` scrim, `-header` / `-body` / `-footer` / `-actions`, `--sm|--md` width ladder, `.dialog--confirm` variant). Promote the app's proven private `.task-dialog` recipe rather than inventing a new one. Document all three families in DESIGN.md and showcase.html; then delete the app-local duplicates and fold `.settings-tabs` / `.tab-bar` onto the canonical component.

**Acceptance Criteria**:
- [x] `.form-*`, `.tabs`/`.tab`, `.dialog` exist in canon, documented and demonstrated.
- [x] No app-local re-implementation of any of the three remains; only one tab bar ships.

**Priority**: Must / P0

#### FR5: Feedback decision-table rewrite + native dialog eradication
**Description**: Rewrite the DESIGN.md feedback decision table to five rows — persistent problem → banner; transient success/error → toast; destructive confirmation → `.dialog--confirm`; row-scoped destructive → the inline `.delete-confirm-bar` the app already ships; needs structured input → `.dialog` with real form controls — and add an explicit **"native `alert()` / `confirm()` / `prompt()` are banned"** line, mirroring the § Native selects prohibition. Then route all nine call sites through one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js`. For the three `hx-confirm` templates, add a single `htmx:confirm` listener in `dc_shell_controller.js` — zero template edits, and all future `hx-confirm` uses convert automatically.

Call sites: `dc_shell_controller.js:369` (delete chat), `:477` (restart), `:488,489,491` (`alert()` on failure); `dc_scheduling_controller.js:403` (delete scheduled task — passes the **id**, not the title); `dc_projects_controller.js:192` (remove project); `dc_settings_controller.js:569,573` (`window.prompt()` for guard extension value and file-access level).

**Acceptance Criteria**:
- [x] Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.
- [x] The two `prompt()` config editors are real forms in a `.dialog`, not modal-ised prompts.
- [x] The `alert()` failure paths surface through the toast component.
- [x] Destructive confirmations name the object (title, not id).

**Priority**: Must / P0

#### FR6: Re-sync + adoption sweep
**Description**: Re-sync canon into the served CSS with the drift check green, purge app-local duplicates obsoleted by FR4, then work the 118 adoption findings. Priority clusters: health/memory/session-info metric + meter adoption; wide-container application; type-tier migration; empty/loading/error state coverage (31 findings — em-dash placeholders where an absent-value treatment belongs, undesigned empty states, no skeleton/`.scan-bar` loading treatment).

**Acceptance Criteria**:
- [x] Drift check green; `design-system.css` byte-identical to canon.
- [x] `health_dashboard.html` uses `.metric-value` and `.meter`.
- [x] Every page has a designed empty state; no bare em-dash stands in for an absent value.

**Priority**: Must / P0

#### FR7: Glitch sweep
**Description**: Close the 64 distinct defects catalogued in the audit. No design decisions required. Includes a global data-formatting pass — timestamps currently appear in three unrelated formats, never roll over past days, and one page prints raw ISO-8601 with milliseconds.

**Acceptance Criteria**:
- [x] All 23 high-severity glitches closed.
- [x] Remaining glitches closed or explicitly deferred with a recorded reason.
- [x] Every deferral is carried into a durable backlog – with its reason, and without a target milestone – so a later milestone finds it without reading this release's own closing records. Recording a reason inside a milestone-scoped artifact does not satisfy this: that artifact is closed along with the milestone.
- [x] UI smoke test (TC-01…TC-31) green.

**Priority**: Must / P0

#### FR8: Local vendoring of runtime dependencies
**Description**: Self-host htmx 2.0.8 (50.0 KB), marked 15 (39.0 KB) and the JetBrains Mono latin + latin-ext woff2 subsets covering weights 400/500/600 (30.6 KB + 11.3 KB).

> **Amended 2026-07-30 during implementation** – as-built correction. This description originally implied six per-weight font files. Google Fonts serves JetBrains Mono v24 as a variable font: the CSS2 response for `wght@400;500;600` carries 18 `@font-face` rules but resolves to six distinct URLs, one per Unicode range, and each range's URL is shared across all three weights. The two vendored subset files carry variable-font tables, so duplicating them per weight would waste 83.9 KB on disk and 111.8 KB in the generated bundle. The release ships two subset files backed by six `@font-face` rules and one preload; all three weights were proven to load and render distinctly with external origins blocked.

**Acceptance Criteria**:
- [x] No external origin appears in `layout.html` or the CSP; `font-src 'self'`.
- [x] `dev/tools/embed_assets.dart` handles `.woff2` as binary; `embedded_static_handler.dart` serves `font/woff2`.
- [x] `VENDORS.md` documents all three with upgrade instructions.
- [x] The UI renders identically with all external origins blocked – proven by a new offline smoke check.

**Priority**: Should / P1 *(splits cleanly into its own point release)*

#### FR9: Documentation sync
**Description**: Update DESIGN.md (typography table, surface ladder, layout tiers, three new component families, rewritten feedback table), `showcase.html` (type tiers, forms, tabs, dialog), `VENDORS.md`, the wireframe `deviations.md`, and any user guide whose screenshots or documented behaviour the change invalidates.

**Acceptance Criteria**:
- [x] No documented behaviour in DESIGN.md lacks backing CSS (closes the § Native selects gap).
- [x] `deviations.md` records any intentional divergence.

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
- **Original FR1–FR9 boundary: no backend work.** Post-plan API/runtime changes are explicitly governed by the adjacent/interlude delivery entries below.
- **Scarcity doctrine and existing DESIGN.md doctrine remain in force** except where this PRD explicitly revises them (feedback table, type tiers, surface ladder).

### Assumptions
- Planning resolved to 16 stories. FR1–FR5 are canon-side, FR6 is the hinge, and the adoption/release stories parallelise after it.
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
| Preserve FR1–FR9 as the original plan and record later work as adjacent/interlude delivery | The release expanded after its plan completed. Rewriting the original scope would destroy the decision trail and make later additions look pre-planned | Silently broaden the original scope; rely on changelog bullets alone |
| Reuse one untouched default New Chat draft | Repeated creation accumulated blank sessions and made the command indistinguishable from a destination. Reuse is safe only while the draft has no title, messages, channel key, provider override, or active turn | Always create; delete older blanks automatically |
| Put system destinations behind one persistent disclosure | Runtime/admin destinations should remain reachable without displacing or visually competing with the primary chat list | Keep every system page as a top-level sidebar row; hide system pages based on incidental service wiring |
| Treat typing as bounded, best-effort channel feedback | Typing increases confidence that a turn is active but must never block agent execution or response delivery when a sidecar or network call fails | Make typing mandatory; implement channel-specific queue branches; emit placeholder messages on native-capable channels |
| Refresh Signal receiving after post-start registration | A reachable daemon is not proof that an account is registered or receiving. Linking or verification must make the new account receive-ready without restarting DartClaw | Require a service restart; open a second competing SSE observer |
| Snapshot absolute installer PATH entries into macOS LaunchAgents | launchd does not inherit the interactive shell environment, so binaries verified during setup otherwise disappear at service start | Copy the whole shell environment; require absolute executable paths everywhere; use a fixed Homebrew path |

## Delivery Record

This section is authoritative for what 0.22.1 delivered. The planned requirements above retain their original wording;
post-plan work is recorded separately so the release history remains complete without rewriting intent after the fact.

### Planned Scope Completion

| Evidence | Delivered result |
|---|---|
| Plan | 16/16 stories completed on 2026-07-30 |
| Proof surfaces | 113/113 acceptance scenarios, 132/132 structural criteria, and 72/72 final-validation items completed |
| Glitch ledger | 64/64 catalogued glitches dispositioned; all 23 high-severity glitches closed |
| Durable deferrals | 37 survivors promoted with their reasons: 21 product-backlog capabilities and 16 architecture/decision items |
| Visual validation | 112/112 planned captures passed across both themes and required viewports; all ten 1024px table records fit |
| Smoke validation | TC-01–TC-29, TC-07A, TC-31, R-01–R-12, and the external-cwd/offline R-13 check passed |
| Release gates | Canon/served-design parity, generated-asset parity, formatting, analysis, workspace tests, architecture checks, fitness checks, and whitespace checks passed at plan close |
| Primary delivery commits | `eddc4f76` (canon, hinge, and surface implementation) and `b08941af` (0.22.1 completion) |

#### Delivered Story Inventory

| Story | Delivered outcome | State |
|---|---|---|
| S01 | Canon surface ladder, depth, and colour rest states | Done |
| S02 | Canon type scale, composite type layer, and container tiers | Done |
| S03 | Canon form, control, tab, and state primitives | Done |
| S04 | Canon dialog primitive and feedback decision table | Done |
| S05 | Canon-to-served sync hinge and removal of app-local duplicates | Done |
| S06 | Native dialog eradication and one confirmation API | Done |
| S07 | Global type-tier, cross-cutting adoption, and data-formatting sweep | Done |
| S08 | Tasks, task-detail, and scheduling surface sweep | Done |
| S09 | Health, memory, and session-info surface sweep | Done |
| S10 | Knowledge and channel surface sweep | Done |
| S11 | Settings surface sweep | Done |
| S12 | Shell and chat surface sweep | Done |
| S13 | Local vendoring of runtime dependencies | Done |
| S14 | Documentation sync, glitch ledger, and release validation | Done |
| S15 | Workflow and project surface sweep | Done |
| S16 | Global shell behavior, states, and formatting sweep | Done |

### Adjacent & Interlude Work

#### AI01: Phosphor Aurora visual refinement

**Intent**: The first completed plan met structural contrast and component-adoption requirements but remained too muted.
The final direction needed visible atmosphere and a stronger product identity without sacrificing accessibility or the
surface ladder.

**What shipped**:
- Visible four-wash aurora grounds, deeper ground edges, prismatic card hairlines, phosphor-beam meters, deep-well form controls with eyebrow labels, a secondary orchestration-action tier, and prompt-hero landing states.
- Light-theme and glass contrast refinements, clearer dense-page hierarchy, and responsive form/navigation treatments.
- One prompt hero/brand moment per view; semantic status remains independently encoded. Reduced-motion behavior and the 48px mobile control floor remain binding.
- Long surfaces scroll inside the fixed shell so entry motion cannot create root-scroll layout shifts.

**Acceptance and evidence**:
- [x] Canon, showcase, served CSS, and embedded assets remain synchronized.
- [x] HTML/CSS contract tests, template tests, and the expanded UI smoke cases cover the new primitives and responsive behavior.
- [x] Chrome, ground, and card planes remain distinct in both themes; essential foreground and tinted-card contrast floors remain binding.

**Commits**: `83a28ece`, `54495b54`.

**Verification note**: The original 112-capture matrix predates part of this refinement. No separate durable post-interlude
screenshot/baseline report was found; release close must not represent one as completed without fresh evidence.

#### AI02: Health remains discoverable without optional telemetry

**Intent**: Health is a core operational destination, not an optional navigation item whose existence depends on extra
telemetry wiring.

**What shipped**:
- Health remains present in system navigation and `/health-dashboard` renders when `HealthService` is absent.
- Fallback state is honest: idle/busy is healthy, stopped is unhealthy, crashed/unknown is degraded, and unavailable runtime details remain unknown/zero rather than fabricated.

**Acceptance and evidence**:
- [x] Navigation tests cover development, personal-assistant, and production configurations.
- [x] Dashboard route tests cover degraded fallback and missing-service behavior.

**Commit**: `83a28ece`.

#### AI03: Reusable New Chat draft lifecycle

**Intent**: `New Chat` is a command, not a selected destination, and repeated activation must not accumulate empty
conversations.

**What shipped**:
- `New Chat` reopens the newest eligible untouched default draft; activating it from that draft focuses the composer without a reload.
- Blank destinations are labelled `Untitled draft`, keeping `New Chat` exclusive to the command.
- A draft stops being reusable when it gains a title, message, channel key, provider override, or active turn. Older duplicates are never deleted implicitly.
- Concurrent open requests coalesce. Eligibility is revalidated across rename/send/turn races; failed creation releases busy state and permits retry. Generic session creation remains unconditional.

**Acceptance and evidence**:
- [x] Sequential and concurrent open requests resolve to one eligible draft.
- [x] Titled, keyed, provider-specific, messaged, and active-turn sessions are never reused.
- [x] Rename/send races, overlapping mutations, retry, autofocus, and title synchronization have deterministic tests.

**Commit**: `54495b54`.

#### AI04: Progressive System navigation and truthful turn status

**Intent**: Primary chat navigation must stay legible as operational surfaces grow, and stale terminal state must never
present an action that is no longer valid.

**What shipped**:
- Runtime/admin pages live in a fixed bottom `System` disclosure; its closed label names the active destination and its menu opens without displacing the chat list.
- Timeline remains directly routable but is nested under Knowledge rather than duplicated at the top level. Extension navigation stays separate; dynamic Running, Workflows, and Chats sections preserve their order.
- Only running, waiting, stuck, and cancelling turns render as active. Cached completed/cancelled/failed snapshots remain inert, and `Cancel Turn` appears only when authoritative `can_cancel` is true.
- Workflow, task, memory, knowledge, scheduling, and session surfaces received consistent semantic sections, controls, responsive layouts, and safe title synchronization that never renames the fixed Workspace Agent identity.

**Acceptance and evidence**:
- [x] Sidebar, page-registry, active-state, ordering, touch-target, and navigation tests cover desktop and mobile contracts.
- [x] Turn-status controller/template/route tests cover active, terminal, invalid, expired, and non-cancellable states.
- [x] Workflow and operational surfaces retain labelled controls and the canonical action hierarchy.

**Commit**: `54495b54`.

#### AI05: Signal pairing becomes receive-ready without restart

**Intent**: Successful pairing or verification must make Signal usable immediately. Daemon reachability alone must not be
reported as account readiness.

**What shipped**:
- signal-cli receives on SSE connection. Successful device linking or SMS verification activates registration, refreshes the receive stream, and selects the registered account for replies without restarting DartClaw.
- A registration-triggered reconnect is queued when another reconnect is active rather than being dropped.
- Startup distinguishes registered, unregistered, and indeterminate account states. Indeterminate checks warn without falsely showing an unpaired account as ready or forcing destructive relinking.
- The pairing UI supports linked-device QR pairing. SMS/voice registration is not exposed there, although the manager-level verification path remains supported and tested.
- Signal installation guidance now prefers native builds, distinguishes their no-JVM runtime from the JVM distribution, and documents the current JRE requirement for that alternative.
- User guidance identifies a second SSE subscriber as a competing consumer, not a passive observer.

**Acceptance and evidence**:
- [x] Linked-device and SMS verification paths activate registration and establish a replacement receive stream.
- [x] Linking during an active reconnect still establishes a fresh stream and uses the linked account for replies.
- [x] Startup tests cover registered, unregistered, and indeterminate states.

**Commit**: `a6bab986`.

#### AI06: macOS services preserve executable discovery

**Intent**: Provider and channel binaries verified during installation must remain resolvable when launchd starts the
service outside the interactive shell.

**What shipped**:
- LaunchAgents snapshot absolute entries from the installer shell's `PATH`; relative and empty entries are discarded.
- A safe system PATH is used when no absolute entries remain. Unrelated shell environment variables are not copied.
- Labels, paths, and program arguments are XML-escaped before writing the LaunchAgent plist.
- Reinstall refreshes the loaded definition, while reload/bootstrap failures remain explicit.

**Acceptance and evidence**:
- [x] Service tests cover PATH filtering, fallback, plist output, refresh, and failures.
- [x] Deployment and CLI documentation explain reinstall-based refresh.

**Commit**: `a6bab986`.

#### AI07: Onboarding protects existing behavior files

**Intent**: Running initialization in an established workspace must not overwrite user-authored behavior.

**What shipped**:
- Init selects draft-review mode when either `USER.md` or `SOUL.md` already exists; direct mutation is reserved for a workspace where both stubs were freshly created.
- Exact legacy generated instructions are upgraded while surrounding custom content remains intact.
- Personalization reruns remain draft-only, and fresh SOUL/ONBOARDING policy is internally consistent.

**Acceptance and evidence**:
- [x] Setup tests cover fresh, partial-existing, existing, legacy-upgrade, and rerun cases.
- [x] ADR-018 and workspace/CLI documentation describe the mutation boundary.

**Commit**: `a6bab986`.

#### AI08: Built-in workflow startup is warning-free

**Intent**: Shipped workflow definitions must load cleanly; duplicated producer descriptions must not create benign but
misleading startup warnings.

**What shipped**:
- Both `spec_path` producers publish one lifecycle-consistent output description.
- Built-in contract validation requires zero load errors and zero warnings.

**Acceptance and evidence**:
- [x] Built-in workflow contract tests load all shipped definitions without errors or warnings.

**Commit**: `a6bab986`.

#### AI09: Rounded-window System indicator correction

**Intent**: The active System destination must remain visible in native windows with rounded lower corners.

**What shipped**:
- The active accent indicator is inset from the trigger edges instead of using a border that can be clipped by the window corner.

**Acceptance and evidence**:
- [x] Canon/served CSS parity is preserved and a focused contract test proves the inset indicator geometry.

**Commit**: `3630dc3e`.

#### AI10: Native typing indication for Signal and WhatsApp

**Intent**: A user waiting on a phone channel must be able to see that an accepted agent turn is still active whenever
the underlying integration exposes native typing/presence support.

**What shipped**:
- The channel contract exposes start/stop typing hooks. Integrations without native support inherit bounded no-op behavior; Google Chat retains its existing richer feedback strategy.
- The queue starts typing immediately before dispatching an accepted turn and attempts to stop it in guaranteed cleanup before response delivery, including failures, retries, observer-suppressed sends, and redaction paths.
- Typing failures and timeouts are logged but never prevent the agent turn or response. Queue-level calls are bounded to three seconds; Signal/WhatsApp presence transactions use a one-second transport bound.
- Signal and WhatsApp support DMs and groups. Per-recipient leases coalesce overlapping turns, serialize transitions, permit one recovery start after a failed first start, and stop only after the final lease releases.
- Disconnect rejects new typing leases, drains/settles in-flight updates, makes a best-effort STOP for active recipients, and prevents late refresh/start activity after teardown.
- Signal refreshes START every ten seconds before Signal's roughly 15-second typing expiry. WhatsApp uses GOWA chat presence `start`/`stop` actions and preserves the selected device header.

**Acceptance and evidence**:
- [x] Start precedes dispatch and STOP precedes response delivery on success, failure, retry, and skip-send paths.
- [x] A stalled or failed typing integration cannot stall the turn or response.
- [x] Overlapping turns emit one active typing interval per recipient and one final STOP; failed initial starts can recover once.
- [x] Signal and WhatsApp direct/group transport contracts and disconnect ordering are covered by deterministic tests.
- [x] User guides document typing behavior and paired-device DM/group checks.

**Commit**: `7992cd29`.

**Verification note**: Focused core/Signal/WhatsApp/server coverage passed 149 tests; the full CI-equivalent workspace gate,
architecture checks, and fitness checks passed afterward. Live paired Signal/WhatsApp verification remains a manual
release check because it requires external accounts.

#### AI11: Signal direct/group routing and bounded RPC completion

**Intent**: Direct recipients and group identifiers must use signal-cli's distinct JSON-RPC contracts, and an RPC whose
response body stalls must not occupy the sidecar operation indefinitely.

**What shipped**:
- Direct ownership is limited to valid E.164 numbers and case-insensitive Signal UUIDs. Other outbound Signal identifiers are groups, including base64 group IDs that begin with `+`.
- Direct messages use `recipient`; group replies and group typing use `groupId`.
- The RPC timeout covers connection, headers, and the complete response body. On timeout the client is force-closed before a `TimeoutException` is surfaced.
- Signal's shared E.164/UUID validators are the single classification source used by sender normalization, ownership, sending, and typing.
- Follow-up investigation of `verifySmsCode` found that the production registration activation from AI05 was correct, but its regression test did not start the manager and therefore proved only that verification opened a first SSE connection – not that it replaced an existing receive stream. The test now starts signal-cli, observes the initial SSE connection, verifies the code, and awaits a distinct replacement connection. Device-link coverage likewise waits for the registration callback and subsequent SSE connection instead of polling mutable state or pumping the event queue.

**Acceptance and evidence**:
- [x] E.164 and mixed-case UUID recipients use the direct contract.
- [x] Base64 group IDs, including `+`-prefixed IDs, use `groupId` for replies and typing.
- [x] A daemon that sends headers or a partial body and then stalls times out within the operation bound.
- [x] SMS verification proves an already-running receiver is replaced after registration; device-link tests synchronize on observable registration/SSE transitions rather than event-loop timing guesses.

**Commit**: `7992cd29`.

#### AI12: Turn-scoped tool policies reach the chain the harness evaluates

**Intent**: Per-task `allowedTools`, per-turn read-only, and the knowledge-inbox no-tools turn are accepted and recorded
by the turn layer, but enforcement happens inside the harness, against the guard chain that harness was constructed
with. Three wiring paths held a `TaskToolFilterGuard` that no harness chain evaluated, so those policies were silently
inert — the failure mode looks identical to a policy that passed.

**What shipped**:
- `GuardChain.layered` composes a per-runner chain over a live base chain: the base guard list is read on every evaluation, so a `guards.*` reload reaches every runner chain while that runner's own guards survive the rebuild. Verdict reporting and fail-open posture are inherited from the base.
- The primary interactive harness receives a layered chain carrying its own filter. It previously received the shared base chain, leaving every session and turn tool policy on the interactive path unenforced.
- Task runners moved from a snapshot copy of the base guards to the layered chain. The copy froze the guard list at spawn time, so a `guards.*` reload never reached an already-spawned task runner.
- ACP permission decisions evaluate the primary layered chain, so a delegated permission request is judged by the same policy as an in-turn tool call.
- The server builder no longer fabricates a filter on its non-pool path. It receives an already-constructed harness and cannot retrofit that harness's chain, so the filter is host-supplied, and the composition contract is documented on the field and in the security architecture reference.
- `buildGuardsFromConfig` no longer accepts a tool filter (breaking, SDK). The list it returns is the base list a reload replaces wholesale, so a filter placed there was a trap in the same shape as the defects above.

**Acceptance and evidence**:
- [x] A no-tools turn policy on the primary harness blocks a mid-turn shell call, leaves other sessions on the same chain unaffected, and clears once the turn settles.
- [x] A `guards.*` reload rebuilds base guards live on every runner chain while each runner keeps its own filter instance.
- [x] The same policy holds on the SDK builder path when the host layers its filter into the harness chain, and no filter is invented when the host supplies none.
- [x] Regression coverage lives with each seam: guard-chain layering, CLI runner wiring, and the builder path.
- [x] Formatting, workspace analysis, the affected package suites, and architecture checks passed.

**Commits**: `c0db221b` (runner chains: `GuardChain.layered`, primary + task-runner wiring, ACP decision path); builder-path commit pending — record after committing that work.

## Release-Close Checks

- [ ] Capture durable visual evidence after the `83a28ece`, `54495b54`, and `3630dc3e` refinements.
- [ ] Run the documented paired-device Signal and WhatsApp DM/group typing checks.
- [x] Replace the pending AI10/AI11 commit markers after committing the current work, then rerun the release gate on that exact tree.
- [ ] Replace the pending AI12 commit marker after committing the current work, then rerun the release gate on that exact tree.
