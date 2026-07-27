# Surface sweep: knowledge and channel surfaces

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S10

## Feature Overview and Goal

**Intent**: The knowledge and channel surfaces were authored outside the 0.22 sweep and are where the product visibly stops being itself – an unstyled browser search box in the middle of the page, KPI counters that read 0 for results the user is looking at, and a wiki drill-down that ejects the reader onto raw `text/plain`; this story brings those paths onto the canon P1 settled so following a search result or opening a channel keeps the user inside the product.

**Expected Outcomes**:

- [OC01] The knowledge hub and KG timeline are assembled from canonical components – tabs, search toolbar, filter chips, KPI cards, result cards, pager and empty states – with no per-surface reinvention and no browser UA chrome left on screen.
- [OC02] Every navigable route on these paths renders inside the app shell: a wiki result opens a rendered, themed document with a way back, and the audit table stops returning a naked fragment to a direct browser navigation — rendered inline so the reader keeps the page they were on.
- [OC03] Channel detail states what is actually true – one control per setting in the accessibility tree, badges and blocks that follow the selected mode, a restart banner where it can be seen, and no control or hint that presumes a channel that is not running.
- [OC04] These surfaces hold at 768px and in both themes: the knowledge grids collapse on the app's own breakpoint, uppercase micro-labels carry the canon caps tracking, and layer identity no longer borrows the selection accent or a semantic state hue.


## Required Context

### From `docs/specs/0.22.1/prd.md` – "FR6: Re-sync + adoption sweep"
<!-- source: docs/specs/0.22.1/prd.md#fr6-re-sync--adoption-sweep -->
<!-- extracted: e18cf85 -->
> **Description**: Re-sync canon into the served CSS with the drift check green, purge app-local duplicates obsoleted by FR4, then work the 118 adoption findings. Priority clusters: health/memory/session-info metric + meter adoption; wide-container application; type-tier migration; empty/loading/error state coverage (31 findings — em-dash placeholders where an absent-value treatment belongs, undesigned empty states, no skeleton/`.scan-bar` loading treatment).
>
> **Acceptance Criteria**:
> - [ ] Drift check green; `design-system.css` byte-identical to canon.
> - [ ] Every page has a designed empty state; no bare em-dash stands in for an absent value.

_Scope split: the metric/meter cluster and the wide-container application belong to S09 and S08. This story owns the knowledge and channel share of the adoption gaps._

### From `docs/specs/0.22.1/prd.md` – "FR7: Glitch sweep"
<!-- source: docs/specs/0.22.1/prd.md#fr7-glitch-sweep -->
<!-- extracted: e18cf85; FR7 gained the durable-backlog criterion after this extraction (uncommitted) -->
> **Description**: Close the 64 distinct defects catalogued in the audit. No design decisions required. Includes a global data-formatting pass — timestamps currently appear in three unrelated formats, never roll over past days, and one page prints raw ISO-8601 with milliseconds.
>
> **Acceptance Criteria**:
> - [ ] All 23 high-severity glitches closed.
> - [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
> - [ ] […elided: every deferral carried into a durable backlog, with its reason and no target milestone — the release-boundary hand-off S14 owns; this story's part is recording the deferral in its own Implementation Observations…]

_Scope split: the global data-formatting pass is S16's. This story owns the `knowledge-hub`, `channel-detail`, `channel-detail/google-chat`, `kg-timeline` and `knowledge-wiki-doc` glitch groups._

### From `docs/specs/0.22.1/prd.md` – Binding constraint: canon-first
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: zero-npm / no build step
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `docs/specs/0.22.1/prd.md` – Binding constraint: no backend work
<!-- source: docs/specs/0.22.1/prd.md#constraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: out of scope
<!-- source: docs/specs/0.22.1/prd.md#out-of-scope -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: FR1 card-vs-ground contrast
<!-- source: docs/specs/0.22.1/prd.md#fr1-surface--depth-revision -->
<!-- extracted: e18cf85 -->
> Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: FR5 no native dialogs
<!-- source: docs/specs/0.22.1/prd.md#fr5-feedback-decision-table-rewrite--native-dialog-eradication -->
<!-- extracted: e18cf85 -->
> Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: NFR accessibility
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone

### From `docs/specs/0.22.1/prd.md` – Binding constraint: NFR visual quality
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline

### From `docs/specs/0.22.1/plan.json` – Shared decision: "Canon-first, and canon closes after P1"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25, working-tree plan.json -->
> […] ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes, because the check pins a sha256 on line 2 of each served copy and concurrent edits in the parallel P3 wave conflict on that line by construction. […] A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

### From `docs/specs/0.22.1/plan.json` – Shared decision: surface token roles
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S01 fixes the structural rule every later story consumes: chrome (`.sidebar`, `.topbar`), page ground and `.card` occupy three mutually distinct planes in BOTH themes, and the body gradient never terminates on the card tone. The token assignment differs per theme and is not fixed here — the PRD's dark remap is chrome→crust / ground→base / card→sub-base, while the light theme gets its own mapping (card white on a tinted ground, chrome at the mantle tier), and exact values in both are an S01 visual-validation outcome. Card hover is not independent: `.card:hover` paints over the same token as card rest, so it re-derives from whatever S01 lands on. No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.

### From `docs/specs/0.22.1/plan.json` – Shared decision: composite type-class vocabulary
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `docs/specs/0.22.1/plan.json` – Shared decision: `--text-sm` retirement protocol
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> Two-step so the app never breaks mid-migration: S02 aliases `--text-sm` to `--text-base` in canon `tokens.css` and stops treating it as a tier in DESIGN.md; S07 migrates every remaining usage in `app.css` and `design-system.css` onto the composite classes and then deletes the alias from canon. No other story introduces a new `--text-sm` usage.

### From `docs/specs/0.22.1/plan.json` – Shared decision: wide-container assignment
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 ships `--container-wide` plus the `.content-inner--wide` / `.page-inner--wide` modifiers. Assignment is fixed here so P3 stories do not each re-litigate it: wide applies to tasks, task detail, health (dashboard + audit), memory, scheduling, the workflow list AND workflow detail; the 900px measure stays for chat, session info, knowledge results, settings forms, and projects. The modifier is opt-in, never the default — a surface not on the wide list keeps 900px unless the sweep documents a deviation.

### From `docs/specs/0.22.1/plan.json` – Shared decision: visual-baseline protocol
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> The PRD's NFR reuses the audit's 92-screenshot capture as the before/after baseline. That works at release level but NOT per story: S01 re-tones every surface and S02 re-scales its type, so from S03 onward every capture differs for reasons outside the story under test and the audit set cannot isolate a story's own deltas. Protocol: each story captures its own story-start screenshots of the surfaces it touches, in both themes at desktop and 768px, and validates against those. The audit's 92-shot set stays the release-level baseline that S14 re-proves once. A story that finds a regression outside its own scope reports it rather than absorbing it.


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#b-glitches--visibly-broken-no-design-decision-needed-72` – the 15 glitches this story closes, under the headings `knowledge-hub` (6), `channel-detail` (6), `channel-detail/google-chat` (1), `kg-timeline` (1), `knowledge-wiki-doc` (1). Read the *Evidence* block before touching the rule or handler it names – each carries measured pixel or line-level proof.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – the 20 adoption gaps, under `knowledge-hub` (8), `channel-detail` (6), `kg-timeline` (3), `channel-whatsapp / channel-signal / channel-gchat` (1), `knowledge/wiki, health/audit` (1), `knowledge/wiki-doc` (1).
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#a-canon-changes--the-design-system-itself-is-the-defect-40` – the `kg-timeline` entry (no time axis, no canonical chronology component) that this story defers rather than closes; read it before writing the deferral reason.
- `docs/wireframes/ux-spec-empty-states.md#design-principles` – centred layout for page-level empties, muted body text, primary action; the shape `.empty-state` instances on these surfaces must take.
- `docs/wireframes/ux-spec-pagination.md#planned-pagination-ui-pattern` – Previous / Next around a "Page 1 of 5" indicator, `btn-ghost` styling, server-rendered.
- `docs/wireframes/knowledge-hub.html`, `docs/wireframes/kg-timeline.html`, `docs/wireframes/google-chat-channel-detail.html` – the intended layouts for the three surfaces.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – server/token setup and the agent-browser loop for this story's both-theme validation.
- `../dartclaw-public/dev/guidelines/TRELLIS-GUIDELINES.md` – `tl:if` / `tl:unless` truthiness rules; the empty-allowlist defect in TI11 is a direct consequence of them.
- `../dartclaw-public/packages/dartclaw_server/lib/src/static/controllers/CONVENTIONS.md` – Stimulus controller conventions for the two controllers this story edits.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI02] The knowledge hub header is built from canonical components and its KPI strip states what it counts**
  - **Given** `/knowledge` on the `visual` profile with one wiki document indexed and the "All" filter active
  - **When** the page is rendered in either theme
  - **Then** the view switcher is a canonical `.tabs` / `.tab` bar with a continuous baseline rule under both tabs, the search field is a `.form-input--search` inside a `.list-toolbar` (palette background, `--border` hairline, accent `:focus-visible` ring – no UA-default fill or hairline) — both inherited from S05, re-checked here as regression guards, not delivered by this story — and the layer filters are `a.chip` inside a `.chip-row` carrying `aria-current="page"` on the active one, with a visible selected treatment that survives the deletion of `.filter-chip--active`
  - **And** the four layer counters render as `.card.card-metric` with `.metric-value` / `.metric-label`, so the count is visibly a larger tier than the result title beside it
  - **And** switching to the KG filter no longer presents the wiki layer's `0` as a corpus total – the strip's visible label and `aria-label` state that it counts the current result set, so a `0` under a non-selected layer is truthful rather than misleading (the corpus-wide recount is deferred – see What We're NOT Doing)

- [ ] **S02 [OC01] [TI03,TI04] Knowledge results, empty state and pager are the canonical ones and the result title is the link**
  - **Given** `/knowledge` with one wiki result, and `/knowledge?layer=memory` with none
  - **When** each is rendered
  - **Then** the result is a `.card` whose `<h2>` title is wrapped in an `<a>` pointing at the item's source href, carries exactly one *visible* layer badge outside `.attribution-popover` (the attribution fragment's inline duplicate at `source_attribution.html:9` suppressed; the popover's own badge at `:12` is retained), and shows a snippet clamped to three lines with a trailing ellipsis rather than a hard mid-word cut
  - **And** the empty view renders the canonical `.empty-state` with `.empty-state-title` above `.empty-state-text` – centred, with an icon – not the left-aligned dashed `.knowledge-empty-state` box
  - **And** with more than one page of results the pager's Previous / Next controls are `class="btn btn-ghost"` around a `.pager-label` reading "Page 1 of 2"

- [ ] **S03 [OC01] [TI05] The KG timeline shares the hub's tab bar and empty state, and its reset control says what it does**
  - **Given** `/knowledge/timeline` with no temporal facts recorded
  - **When** the page is rendered
  - **Then** the tab strip is the same canonical `.tabs` / `.tab` component as the hub, with the active accent underline sitting on the strip's baseline rule rather than floating
  - **And** the empty view is a canonical `.empty-state` with `.empty-state-title` and a link back to `/knowledge`, and the dead `.kg-timeline-empty` / `.kg-timeline-error` class hooks no longer appear in the template
  - **And** the control that clears the form reads "Reset filters" with an `icon-x` mask glyph, no `↺` character remains in the template, and activating it clears both the Category and As-of fields

- [ ] **S04 [OC02] [TI07] Navigable routes render inside the app shell, and a missing document names the path**
  - **Given** a wiki search result linking to `/knowledge/wiki/wiki/README.md` (the route's own guard requires the `wiki/` locator prefix, so the served URL carries the segment twice – see Constraints & Gotchas)
  - **When** it is opened by direct browser navigation, with no `HX-Request` header
  - **Then** the wiki route returns a themed full page containing `<div class="shell">` with sidebar, topbar and a back link to `/knowledge`, and the markdown is rendered through the existing `data-markdown` pipeline – `# Wiki` appears as a heading and backticked spans as code – with no `content-type: text/plain` response remaining in `web_routes.dart`
  - **And** requesting `/knowledge/wiki/wiki/missing.md` – a file absent under a valid `wiki/` prefix – returns a 404 page whose message names the requested path rather than the opaque `Wiki source not found`
  - **And** the three *guard* rejections (prefix/extension, `p.isWithin` containment, symlink escape) keep the existing uniform `Wiki source not found` message, so a traversal probe learns nothing from the difference and `test/web/web_routes_test.dart:128` still passes
  - **And** `/health-dashboard/audit?page=2&verdict=block&guard=file` opened with no `HX-Request` header returns **200 with the full health page rendered inline** – not a redirect – showing the *second* page of audit rows with both filters still applied, while the same URL with `HX-Request: true` still returns the bare `auditTableFragment` so the existing poll is unchanged

- [ ] **S05 [OC03] [TI09,TI10] Channel detail exposes one control per mode setting, and the badge, banner and pairing block follow the selection**
  - **Given** `/settings/channels/whatsapp` with DM mode set to `pairing`
  - **When** a keyboard user tabs through the DM Access panel and then selects the `open` mode card
  - **Then** exactly one control per mode field is reachable and announced – the four mode cards form a `role="radiogroup"` of `role="radio"` elements with `aria-checked`, and the paired `<select class="channel-mode-select">` is out of the tab order and the accessibility tree
  - **And** the `Active` badge moves to the `open` card and leaves the `pairing` card, with no reload and no two cards claiming to be active
  - **And** the restart notice appears in the page's top banner slot beside `${bannerHtml}` – visible without scrolling – and the pairing sub-card hides itself with its 5s poll stopped, matching the hint text that says it appears only while DM mode is `pairing`

- [ ] **S06 [OC03] [TI08,TI11,TI12] A not-running channel says so, an empty allowlist renders identically on both paths, and Google Chat shows no dead CTA**
  - **Given** `/settings/channels/google_chat` reporting status `Not running`, with an empty DM allowlist
  - **When** the page is rendered, and then an allowlist entry is added and removed again over the client path
  - **Then** a `.banner.banner-warning` under the hero states that the channel is not running and that policy changes apply when it starts, the "DM allowlist changes take effect immediately." hint is replaced accordingly, and the DM/group policy panels carry `aria-disabled="true"` with the reduced-opacity treatment so no control presents itself as live on a stopped channel
  - **And** the banner's copy is selected from the `ChannelStatus` enum value, not from the boolean `isConnected` – a `Disabled` or `Reconnecting` channel is not told it "is not running"
  - **And** the "No entries" row renders on the first server render – not only after the client round-trip – because the empty list is passed as null the way `pendingPairings` already is
  - **And** no `Pairing / Registration` anchor is emitted, because `pairingHref` is null for `google_chat`
  - **And** the status badge embeds a `.status-dot--{variant}`, so `Not running`, `Configured` and `Pairing needed` resolve to three *different* canon variants (`--idle`, `--warning`, `--attention`) and are distinguishable without relying on the badge's amber fill, and the hero title starts at the same x-position here as on `/settings/channels/whatsapp` and `/signal`

- [ ] **S07 [OC04] [TI06,TI13] These surfaces hold at 768px and stop conveying state by colour alone**
  - **Given** `/knowledge`, `/knowledge/timeline` and a wiki citation marker at a 768px viewport in both themes
  - **When** each is rendered and a citation marker is hovered and then left
  - **Then** the knowledge search form, summary strip and result rows collapse to one column and the citation marker reaches its 44px touch target – no `@media (max-width: 767px)` block remains in `app.css`
  - **And** the four layer badges resolve to `--chart-3` … `--chart-6` by fixed layer index instead of `--info` / `--accent` / `--warning` — the ramp's first two stops are excluded because canon aliases them straight onto the forbidden hues (`tokens.css:50-51`: `--chart-1: var(--accent)`, `--chart-2: var(--info)`) — each still measuring ≥ 4.5:1 against its badge ground in both themes, and the selected filter is distinguishable from a layer badge of any hue by its `aria-current` chip treatment
  - **And** moving the pointer off the citation marker closes the attribution popover, and Escape closes it when it was opened by hover without focus

- [ ] **S08 [OC01,OC02,OC03,OC04] [TI15] Every finding this story does not close is recorded as an explicit deferral S14 can read**
  - **Given** the story's four deferrals (filtered layer counts, snippet generation, the KG timeline's missing time axis, the absent Start/Connect action) and the two canon-blocked items (`a.chip` selected treatment, the missing `.status-dot--muted` variant)
  - **When** the story reaches its end
  - **Then** all six appear under `## Implementation Observations` in **`../dartclaw-private/docs/specs/0.22.1/fis/s10-sweep-knowledge-and-channel-surfaces.md`** – the canonical private copy, not the transient `dev/bundle/` export – each with a one-line reason
  - **And** each one that is also stated in prose as a "What We're NOT Doing" bullet appears in Implementation Observations too, because that block is the only one S14 reads when it consolidates `../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md`
  - **And** `git -C ../dartclaw-private status --porcelain docs/specs/0.22.1/fis/s10-sweep-knowledge-and-channel-surfaces.md` shows the file modified, proving the record survived the bundle boundary (do **not** commit it – the operator commits in the private repo)

- [ ] **S09 [OC01,OC03] [TI14] Each swept page exposes exactly one `<h1>`, and it comes from the topbar**
  - **Given** `/knowledge`, `/knowledge/timeline` and `/settings/channels/whatsapp` after S16's TI02 has promoted the topbar fragment to `<h1>`
  - **When** each is rendered
  - **Then** each page's DOM contains exactly one `<h1>`, emitted by the topbar, with no in-page duplicate beneath it
  - **And** the channel hero title still renders at its stepped-up tier and is announced as a heading, having changed tag rather than been deleted


## Structural Criteria

- [ ] `dev/tools/fitness/check_design_system_sync.sh` exits 0 at story end; this story edits none of the three closed canon files (`dev/design-system/tokens.css` / `components.css` / `icons.css`) nor their served copies (`design-system.css` / `tokens.css` / `icons.css`). `DESIGN.md` and `showcase.html` are outside the closure and outside the drift check — editing them is permitted and does not breach this criterion.
- [ ] No `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` is introduced in `lib/src/static/controllers/`.
- [ ] No service, schema or API change: `packages/dartclaw_storage/` and `packages/dartclaw_server/lib/src/knowledge/` are unmodified by this story.
- [ ] No new runtime JS dependency and no new external origin in `layout.html` or the CSP.
- [ ] `--container-wide` / `.content-inner--wide` / `.page-inner--wide` is applied to no surface in this story – knowledge results keep the 900px measure and channel detail is not on S02's wide list.
- [ ] No new `var(--text-sm)` usage is introduced (assert on this story's diff, not on `app.css` tree-wide — retiring the 79 existing uses is S07's gate).
- [ ] Each of the 15 glitches and 20 adoption gaps this story claims is closed, or recorded in Implementation Observations as a deferral with a reason. "Listed" means the findings under the audit headings named in Deeper Context; multi-surface findings that merely touch these pages are **not** claimed here, and where one is partly closed (the not-running channel entry's Start/Connect half) the uncovered half is recorded as a deferral rather than dropped.
- [ ] `packages/dartclaw_server/lib/src/web/web_routes.dart` and `web/channel_status.dart` are the only non-template `.dart` files this story edits. Both sit outside `lib/src/templates/`, which the plan overview's "zero backend surface" summary does not anticipate — neither is a service, schema or API change, but the orchestrator should confirm the breach is acceptable rather than discover it at merge.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/templates/knowledge_hub.html` + `knowledge_hub.dart` – tabs, search toolbar, filter chips, KPI strip, result rows, empty state, pager, failed-layer marker.
- `packages/dartclaw_server/lib/src/templates/kg_timeline.html` – tab bar, filter labels, empty state, reset control.
- `packages/dartclaw_server/lib/src/templates/channel_detail.html` + `channel_detail.dart` + `web/channel_status.dart` – hero, status badge, panel treatments, micro-labels, allowlist / pairing / not-running states.
- `packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` and `dc_attribution_controller.js` + `templates/source_attribution.html` – mode-card badge sync, pairing-section visibility, popover dismissal, duplicate badge suppression.
- `packages/dartclaw_server/lib/src/web/web_routes.dart` plus a new wiki-document template pair – `/knowledge/wiki/<path>` rendered in the shell, `/health-dashboard/audit` full page inline on direct navigation (S10's by plan ruling), and whatever `page`-threading that inline render needs at its `web/pages/health_page.dart` seam.
- `packages/dartclaw_server/lib/src/static/app.css` knowledge / kg-timeline / channel blocks – delete the superseded per-surface rules, normalize the three 767px breakpoints, caps tracking, section rhythm.

### What We're NOT Doing
- **Recomputing the knowledge layer counts from an unfiltered corpus query** -- the root cause is `knowledge_hub_service.dart#KnowledgeHubService.search`, a service change the PRD puts out of scope. The in-scope remedy is to label the strip for the result set it actually reports; the corpus-summary behaviour is deferred with a recorded reason.
- **Stripping markdown and snapping snippets to a word boundary** -- `WikiSearchSource._snippet` lives in `packages/dartclaw_storage`, also a service change. The in-scope remedy is the three-line visual clamp with an ellipsis; the generation-side defect is deferred with a recorded reason.
- **A canonical chronology / timeline component and the KG timeline's missing time axis** -- a new canon component family, which P1 closed, and a new capability the release excludes. Deferred with a recorded reason per the plan's glitch-ledger rule.
- **A Start / Connect action for a not-running channel** -- no such endpoint exists; adding one is a new UX capability. This story states the condition, it does not make it actionable.
- **Re-toning `.card`, `.well` or the page ground on these surfaces** -- the audit's "nested wells land on the page background" finding is attributed to `dev/design-system/tokens.css` and belongs to S01's ladder; adopting canon `.card` is how the fix reaches these pages.
- **Loading/skeleton treatments** -- neither `knowledge_hub.html` nor `kg_timeline.html` carries an `hx-get` or `hx-trigger` (search is a plain GET form submit, so the browser owns the transition), and the channel pairing row already renders `.scan-bar` (`app.css#.pairing-status-row`). There is no in-flight state on these surfaces to dress.
- **An `a.chip[aria-current]` selected treatment in canon** -- canon's pressed-chip rule is `button`-qualified (`components.css:1956`) and the layer filters must stay GET-navigation anchors, so the selected state has no canonical rule to adopt. Canon is frozen for this story; deferred with a recorded reason.
- **A `.status-dot--muted` variant** -- `ChannelStatus.disabled` carries `status-badge-muted`, but canon ships only `--live` / `--error` / `--warning` / `--idle` / `--attention` / `--success`. TI08 routes `disabled` onto `--idle` rather than inventing the variant; the gap itself is deferred with a recorded reason.
- **A redirect for `/health-dashboard/audit`** -- the plan ruled this route S10's and the response an *inline* full-page render, precisely because a redirect drops the `page` param. S09's competing redirect is deleted in remediation; do not reinstate it.


## Architecture Decision

**Approach**: adopt only – every fix on these surfaces is a template, view-model, controller or app-local CSS change that consumes the canon S01–S04 settled and S05 wired up; the superseded per-surface rules are deleted rather than left shadowed.
**Why this over alternatives**: the audit's root cause for this cluster is that canon had no answer when these pages were written and none was retrofitted after 0.22; anything short of deleting the local rule leaves two definitions and the next author picks the wrong one.


## Code Patterns & External References

```
# type | path#anchor or url                                                          | why needed (intent)
file   | packages/dartclaw_server/lib/src/templates/memory_dashboard.html            | The reference adoption on a sibling surface – `.card card-metric card-metric--accent` + `.metric-value` / `.metric-label`, and the tab bar that renders correctly today
file   | packages/dartclaw_server/lib/src/templates/tasks.html#empty-state           | The full `.empty-state` pattern already shipping: `.empty-state-icon` > claw-mark + `.empty-state-title` + `.empty-state-text`
file   | packages/dartclaw_server/lib/src/templates/channel_detail.dart              | View-model assembly; `pendingPairings.isNotEmpty ? … : null` is the exact idiom the two allowlists must copy for their `tl:unless` to fire
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#syncModeCards | Where the `.channel-mode-badge` element must be created/removed alongside the `.active` / `aria-pressed` toggle
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#initPairingPolling | The 5s poll that must start and stop with the pairing sub-card's visibility
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#renderAllowlistEntries | The client path that already emits `.allowlist-empty` – the server render must match it
file   | packages/dartclaw_server/lib/src/web/web_routes.dart#wantsFragment           | The project's HTMX content-negotiation helper (defined in `web/web_utils.dart`) – the audit route's full-page branch keys on it
file   | packages/dartclaw_server/lib/src/templates/task_detail.html                 | `data-markdown` usage on a rendered document body; `static/controllers/shared.js` wires marked + DOMPurify for it
file   | packages/dartclaw_server/lib/src/templates/knowledge_hub.dart#knowledgeHubTemplate | Sidebar + `pageTopbarTemplate` assembly to mirror for the wiki-document page
file   | dev/design-system/components.css#.chip                                      | `.chip` (:1930) and `.chip-row` (:1992) the filter chips adopt — note the active treatment at `:1956` is `button.chip[aria-pressed="true"]`, element-qualified, so anchor chips get no pressed state from it
file   | dev/design-system/components.css#.status-dot                                | `.status-dot--{variant}` shapes the channel status badge must embed
wire   | docs/wireframes/knowledge-hub.html                                          | Intended hub layout and section rhythm
```


## Constraints & Gotchas

- **Critical**: canon **rules** are frozen for this story, but the closure covers three files, not the directory. `dev/design-system/tokens.css`, `components.css` and `icons.css` (and their served copies) are closed after P1 and drift-checked for byte identity — a rule change there is not S10's, and is recorded as a deferral instead. `DESIGN.md` and `showcase.html` are **not** closed and **not** drift-checked (`docs/specs/0.22.1/canon-hoist-manifest.md`), so this story may write a documented contract for a rule it owns; S14 reconciles the document at release close. The two canon-blocked deferrals below (`a.chip` selected treatment, `.status-dot--muted`) still stand as deferrals — both need a *rule* in `components.css` — but may additionally be written up as DESIGN.md contract notes so the gap is documented rather than only ledgered.
- **Constraint**: `app.css` loads after `design-system.css` (`layout.html`), so an app-local rule of equal specificity still wins. Adopting a canonical class without deleting the superseded app rule leaves the old treatment in force -- Workaround: delete the local rule in the same task that swaps the markup, and verify the class name is gone from `app.css`.
- **Avoid**: re-litigating the container tier. `--container-wide` assignment is fixed by S02 and neither knowledge nor channel detail is on the wide list -- Instead: leave `.page-inner` / `.content-inner` as they are.
- **Critical**: S07 then S16 run first and rewrite `app.css` globally — S07 the type, colour and stacking layers, S16 the empty-state family, `.page-content` and the 768px touch-target block — including the shared page and card scaffolding these templates inherit. Re-read the knowledge / kg-timeline / channel blocks before editing – the audit's line numbers are from the pre-S05/S07/S16 build and will have moved. Locate by selector, never by line.
- **Constraint**: this story deletes three of the six duplicate in-page `<h1>`s per the plan's shared-surface ownership decision (1) — `knowledge_hub.html:9`, `kg_timeline.html:9` and `channel_detail.html:14`. This is safe **only after S16's TI02**, which promotes `topbar.html`'s `pageTopbar` / `plainTopbar` titles from `<span class="session-title-static">` to `<h1 class="session-title-static">`; the topbar emits no `<h1>` today, so deleting these first would leave three pages with no `<h1>` at all. S10 `dependsOn: ["S07", "S16"]`, so the ordering holds — but verify the topbar actually emits one before deleting. `login.html` is exempt (no topbar); settings→S11 and projects→S15 are not this story's.
- **Avoid**: reading `channel_detail.html:14`'s `<h1>` as a page-title duplicate to simply delete. It is the **hero title**, the identity moment TI08 steps up a tier. The element stays and keeps its prominence — it is demoted from `<h1>` to a non-heading-rank element (the topbar now owns the page's only `<h1>`) -- Instead: change the tag and keep the visual tier, per the shared decision's "Pages carry a subtitle or description head, never a second `<h1>`".
- **Avoid**: giving the four knowledge layers semantic hues. `--accent` is the selection and success colour and `--warning` / `--info` are state colours -- Instead: `--chart-1` … `--chart-4` by fixed layer index, with selection carried by the chip's `aria-pressed` treatment rather than by hue.
- **Constraint**: `tl:unless="${list}"` does not fire for an empty-but-non-null list in Trellis -- Workaround: pass `list.isEmpty ? null : list` from the `.dart` view-model, as `channel_detail.dart` already does for `pendingPairings`.
- **Critical**: `/health-dashboard/audit` is **S10's by plan ruling** (`plan.json` shared decision *Shared-surface ownership in the sweep phase* (3)): "S10 owns the `/health-dashboard/audit` non-fragment behaviour and renders the full page inline (preserving the `page` param, which a redirect would drop); S09 does not touch that handler." S09's competing TI09 redirect is deleted in remediation — do not reinstate it, and do not coordinate with S09 on this file.
- **Critical**: the `page`-preservation that decided that ruling **does not come for free**. `web/pages/health_page.dart#HealthDashboardPage.handler:36-44` reads only `verdict` and `guard` and calls `auditReader.read(verdictFilter:, guardFilter:)` with **no `page:` argument**, so it renders page 1 regardless. Rendering the existing page handler unchanged would drop `page` exactly as the rejected redirect would, silently voiding the ruling's rationale -- Workaround: thread `page` from the query string into the audit read on the non-fragment branch, and assert page 2 specifically in the Verify. `wantsFragment` (`web_utils.dart:8`) is the correct predicate and is already history-restore-aware: it returns false for `HX-History-Restore-Request: true`, so a history restore correctly gets the full page.
- **Critical**: the wiki route's own guard requires the locator prefix — `web_routes.dart:537` rejects anything not matching `decoded.startsWith('wiki/') && decoded.endsWith('.md')`, and `knowledge_hub_service.dart:213` emits `'/knowledge/wiki/$encoded'` where `encoded` *already* begins `wiki/`. The served URL therefore carries the segment twice: `/knowledge/wiki/wiki/README.md`. `test/web/web_routes_test.dart:111,128,144` all use that shape -- Workaround: never write `/knowledge/wiki/<file>.md` in a test or Verify line; it hits the reject branch and passes for the wrong reason.
- **Constraint**: canon's only pressed-chip treatment is element-qualified — `button.chip[aria-pressed="true"]` (`components.css:1956`); `a.chip` gets hover and focus rules only (`:1951-1952`). The knowledge layer filters are GET-navigation anchors (`knowledge_hub.html:29-30`) and must stay anchors, so `aria-pressed` on them is both invalid ARIA and visually inert -- Workaround: use `aria-current="page"`, and record the absent `a.chip` selected treatment as a canon deferral. Adding the rule here would breach the frozen-canon constraint.
- **Avoid**: reading `--chart-1` … `--chart-4` as a neutral categorical family. Canon aliases the first two onto the exact hues this story is trying to escape (`tokens.css:50-55`: `--chart-1: var(--accent)`, `--chart-2: var(--info)`, `--chart-3: var(--mauve)`, `--chart-4: var(--teal)`, `--chart-5: var(--pink)`, `--chart-6: var(--sky)`) -- Instead: assign the four layers to `--chart-3` … `--chart-6`. Re-basing `--chart-1` is a canon edit this story cannot make.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** The knowledge hub header uses the canonical tab, toolbar and chip components
  - **Inherited from S05, not delivered here** — S05's TI02/TI09 (`s05-…:212,220`) already convert `.knowledge-tabs` > `.tab-btn` to canonical `.tabs` / `.tab` and `.knowledge-search-strip` / `-form` to `.list-toolbar` + `.form-input--search`, naming `knowledge_hub.html:20-21,63,65` as "the only consumer". Treat those as preconditions and re-check them as regression guards. **S10's own work in this task** is the filter chips: the `.filter-chip-row` becomes a `.chip-row` of `a.chip` carrying `aria-current="page"` on the active filter (anchors, not buttons — see Constraints & Gotchas), with `className` in `knowledge_hub.dart#layerChips` emitting the canonical names, and `.filter-chip` / `.filter-chip--active` deleted from `app.css`. Because canon has no `a.chip` selected rule, the selected treatment must come from the existing `aria-current` styling the app already applies elsewhere or be recorded as a deferral — do not add a canon rule.
  - **Verify**: `rg -n 'filter-chip' packages/dartclaw_server/lib/src/templates/ packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1); `rg -n 'class="chip-row"' packages/dartclaw_server/lib/src/templates/knowledge_hub.html` matches (the quoted form matters — a bare `chip-row` also matches the `filter-chip-row` being deleted) and the active chip reports `aria-current="page"` with a selected treatment visibly distinct from the inactive chips in both themes; regression guards for S05's output: `rg -n 'knowledge-tabs|knowledge-search-strip|knowledge-search-form' packages/dartclaw_server/lib/src/templates/ packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1) and `rg -n 'class="tabs"|list-toolbar|form-input--search' packages/dartclaw_server/lib/src/templates/knowledge_hub.html` returns all three

- [ ] **TI02** The knowledge layer strip reads as a KPI row and distinguishes a failed layer from an empty one
  - `.knowledge-summary-item` / `-count` / `-label` become `.card.card-metric` > `.metric-value` + `.metric-label`; delete the three rules from `app.css`. `knowledge_hub.dart#layerSummaries` gains a per-layer failed flag from `result.failedLayers` so a failed layer's cell shows an explicit error marker instead of `0`, and the strip's `aria-label` plus its visible label state that it reports the current result set, not the corpus. The `notice notice-warning` hook on the partial-results block has no rule anywhere – it becomes `.banner.banner-warning`.
  - **Verify**: `rg -n 'knowledge-summary-item|knowledge-summary-count|knowledge-summary-label|notice-warning' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1); on `/knowledge` the counter renders at the `.card-metric .metric-value` tier (32px) against a 14px `.metric-label`; and a `knowledge_hub.dart` unit test built from a `KnowledgeHubResult` fixture with a non-empty `failedLayers` asserts that layer's cell renders the error marker rather than `0` — the field already exists at `knowledge_hub_service.dart:59`, so no service change is needed and no fault injection against a live profile is required

- [ ] **TI03** Knowledge results are cards whose title is the link, with one badge and a clamped snippet
  - `.knowledge-result-row` becomes `class="card"` (plain – hue stays on the badge per Constraints); the `<h2 class="knowledge-result-title">` is wrapped in an `<a>` on `item.sourceHref`; `source_attribution.html#sourceAttribution` suppresses its inline `.layer-badge` when the host row already renders one (a flag through `source_attribution.dart`, not a second fragment); `.knowledge-result-snippet` gains a three-line clamp with a trailing ellipsis. Delete the superseded `.knowledge-result-row` background/border/padding declarations from `app.css`.
  - **Verify**: `/knowledge` renders each result inside a `.card` measuring ≥ 1.15:1 against the page ground in both themes; the title is a focusable link resolving to the item's source href; exactly one `.layer-badge` appears per result row; the snippet ends in an ellipsis at three lines rather than mid-word

- [ ] **TI04** The knowledge hub's empty state and pager are the canonical ones
  - **Largely inherited** — **S16 TI04** already collapses `.knowledge-empty-state` onto canon `.empty-state` and stops `app.css:1808-1810`'s `.empty-state-icon` / `-title` / `-text` family shadowing the canon icon rule, and S05 (`s05-…:220`) already converts `.pager-link` to `class="btn btn-ghost"`. Note the family is *not* wholly canonical: canon ships `.empty-state`, `.empty-state .icon` and `.empty-state p`, with only `.empty-state-title` promoted by S03 — `-icon` and `-text` remain app-local, so do not describe them as canon. **S10's own work** is splitting `knowledge_hub.dart#_emptyMessage` into a title and a hint line per `docs/wireframes/ux-spec-empty-states.md#design-principles`, so the empty view has the two-line shape the spec prescribes rather than one sentence.
  - **Verify**: `/knowledge?layer=memory` with no results renders a centred `.empty-state` whose title and hint come from the split `_emptyMessage`, with an icon; regression guards for S05/S16's output: `rg -n 'knowledge-empty-state|pager-link' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1), and with more than one page of results the pager shows `btn btn-ghost` Previous / Next around a `.pager-label` (see Validation — the `visual` profile does not seed enough documents to produce a second page unaided)

- [ ] **TI05** The KG timeline shares the hub's tab bar and empty state, and its controls are honestly labelled
  - `kg_timeline.html` already carries the canonical `.tabs` / `.tab` component from S05 (`s05-…:212`, which names this file explicitly) — re-check it, do not re-adopt it. **S10's own work**: the `.kg-timeline-empty` card becomes an `.empty-state` with an `.empty-state-title` and a link back to `/knowledge`; the dead `.kg-timeline-empty` / `.kg-timeline-error` hooks are dropped from the markup; the `↺ now` anchor becomes "Reset filters" with `<span class="icon icon-x" aria-hidden="true">`, and activating it must clear the As-of field *and* the Category filter it silently resets today.
  - **Verify**: `rg -n 'kg-timeline-empty|kg-timeline-error|↺' packages/dartclaw_server/lib/src/templates/kg_timeline.html` returns no matches (exit 1); `/knowledge/timeline` with no facts renders a centred `.empty-state` with an `.empty-state-title` and a working link to `/knowledge`; the reset control reads "Reset filters" and carries `class="icon icon-x"`, and activating it clears both Category and As-of; regression guard for S05's output: `rg -c 'class="tabs"' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/templates/kg_timeline.html` prints a count line for **both** files (a file with no match is omitted from `rg -c` output entirely, so a missing line is the failure signal), proving both strips share one component

- [ ] **TI06** Knowledge and KG surfaces collapse on the app's breakpoint, carry canon caps tracking, and give layer identity the categorical ramp
  - The three `@media (max-width: 767px)` blocks in `app.css` (citation marker touch target `:3006`, knowledge grids `:3204`, kg-timeline controls `:3393`) move to `max-width: 768px`. **Re-key the `:3204` block's selectors first** — it currently lists `.knowledge-search-form`, `.knowledge-summary-strip` and `.knowledge-result-row`, two of which no longer exist after S05/TI01 (`.knowledge-search-form` → `.list-toolbar`) and TI03 (`.knowledge-result-row` → `.card`); keeping them verbatim both preserves dead selectors and trips TI01's own gate. Point the block at the surviving classes, or delete it where canon's `.list-toolbar` already supplies the wrap. `.layer-badge--wiki` / `-kg` / `-memory` / `-inbox` re-point from `--info` / `--teal` / `--accent` / `--warning` to `--chart-3` / `--chart-4` / `--chart-5` / `--chart-6` by fixed layer index — **not** `--chart-1` / `-2`, which canon aliases onto `--accent` / `--info` (see Constraints & Gotchas) — and `.read-only-marker` moves off `--accent` onto a neutral `.status-badge`; the stacked `margin-bottom` on the knowledge section blocks is dropped so `.page-inner`'s gap owns the rhythm. The caps-tracking pass on `.layer-badge`, `.unverified-flag` and `.kg-timeline-controls .field-label` is **S07 TI03's** — re-check it here, do not redo it.
  - **Verify**: `rg -n 'max-width: 767px' packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1) — all three blocks are S10-owned, and `@media (min-width: 769px)` at `app.css:229` confirms 768/769 is the app's own pair, so the shift introduces no overlap; for each of the four variants `rg -A4 '^\.layer-badge--wiki' packages/dartclaw_server/lib/src/static/app.css` (and `-kg` / `-memory` / `-inbox`) shows its assigned `var(--chart-N)` with N in 3…6 and no `var(--(info|accent|warning|teal))` remaining in that block — assert per variant, not by a global count, since S07 rewrites `.layer-badge--kg`'s declaration shape; each badge measures ≥ 4.5:1 against its ground in both themes (S07 closed this as a WCAG AA finding — do not reopen it); at exactly 768px the knowledge toolbar, summary strip and result cards each render one column and `.citation-marker` measures ≥ 44×44px; every remaining `text-transform: uppercase` rule in the knowledge and kg-timeline blocks declares `var(--tracking-caps)`

- [ ] **TI07** Wiki documents and the audit table render inside the app shell
  - `web_routes.dart` `/knowledge/wiki/<sourcePath|.*>` returns a full shell page – sidebar from `pageContext.sidebar`, `pageTopbarTemplate(backHref: '/knowledge', …)`, body a `.card` with `data-markdown` per `templates/task_detail.html` – instead of `content-type: text/plain` (`:558`, the file's only occurrence). The handler has **six** `_htmlNotFound('Wiki source not found')` call sites, not four: null workspace (`:536`), prefix/extension reject (`:539`), containment reject (`:545`), missing file (`:548`), symlink-escape reject (`:553`) and `FileSystemException` (`:556`). Only the **missing-file** branch names the requested path; the three guard branches keep the uniform message so the 404 does not become a traversal oracle (see Scenario S04). Follow `knowledge_hub.dart#knowledgeHubTemplate` for the sidebar/topbar assembly; no service call changes.
  - In the same file, the `/health-dashboard/audit` handler (`:398-414`, which returns `auditTableFragment` unconditionally today) branches on `wantsFragment(request)`: true → the bare fragment, unchanged, so the existing poll and its `vary: HX-Request` header stay honest; false → the full health page rendered **inline** (not a redirect), with `page`, `verdict` and `guard` all threaded into the audit read. This route is S10's by plan ruling — see Constraints & Gotchas, including the trap that the existing page handler drops `page`.
  - **Verify**: `rg -n "text/plain" packages/dartclaw_server/lib/src/web/web_routes.dart` returns no matches (exit 1); with the `visual` profile's gateway token exported, `curl -s -H "Authorization: Bearer $TOKEN" localhost:3338/knowledge/wiki/wiki/README.md` contains `<div class="shell">`, `data-markdown` **and the document's own rendered heading text** (asserting on `.shell` alone would also pass against an auth redirect); `curl -s -H "Authorization: Bearer $TOKEN" localhost:3338/knowledge/wiki/wiki/missing.md` returns 404 naming `wiki/missing.md`; `curl -s -H "Authorization: Bearer $TOKEN" localhost:3338/knowledge/wiki/wiki/%2E%2E/secret.md` returns the uniform `Wiki source not found` with no path echoed; `curl -si -H "Authorization: Bearer $TOKEN" 'localhost:3338/health-dashboard/audit?page=2&verdict=block&guard=file'` returns **`HTTP/1.1 200`** (not `302` — a redirect is the rejected S09 design) with `<div class="shell">` and the *second* page of audit rows, both filters still applied; the same URL with `-H 'HX-Request: true'` returns the bare fragment with no `<div class="shell">`; adding `-H 'HX-History-Restore-Request: true'` alongside `HX-Request: true` returns the full page, since `wantsFragment` excludes history restores; `dart test test/web/web_routes_test.dart` passes with its three existing wiki cases re-pointed to the new response shape

- [ ] **TI08** Channel detail hero, status badge and panel treatments use the canonical vocabulary
  - `.channel-detail-hero-title` gains `flex: 1 1 auto; min-width: 0` so the identicon-title pair is left-aligned and the badge is the only right-aligned item; the hero identicon and `h1` step up a tier; the `<span class="status-badge">` embeds `.status-dot--{variant}` from `ChannelStatus.badgeVariant`; `panel-accent` / `panel-info` on the two peer configuration panels become plain `.card`; `.channel-panel-kicker` and `.channel-sub-card h3` become `.section-label`; `.channel-sub-card` gets a column flex with `gap: var(--sp-3)`. The `.channel-mode-badge` `0.625rem` → `var(--text-xs)` step is **S07 TI03's** (same selector, `app.css:1415`, named verbatim in that task) — re-check, do not redo.
  - **Re-map the full enum, not just `configured`.** Today `notRunning`, `configured`, `pairingNeeded` *and* `reconnecting` all carry `status-badge-warning` (`web/channel_status.dart:4-9`), so the three states this story must distinguish resolve to one variant. Canon ships exactly six dot variants — `--live`, `--error`, `--warning`, `--idle`, `--attention`, `--success` (`components.css:1189-1240`) — and there is **no `.status-dot--muted`**, though `disabled` maps to `status-badge-muted` (`:3`). Assign: `disabled` → `idle`, `notRunning` → `idle`, `configured` → `warning`, `pairingNeeded` → `attention`, `reconnecting` → `warning`, `connectionError` → `error`, `connected` → `live`. Record the absent `--muted` variant as a canon deferral rather than adding it.
  - **Verify**: `rg -n 'panel-accent|panel-info|channel-panel-kicker' packages/dartclaw_server/lib/src/templates/channel_detail.html packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1); `awk '/^\.channel-mode-badge \{/,/^}/' packages/dartclaw_server/lib/src/static/app.css | rg -c 'font-size: var\(--text-xs\)'` returns `1` and the same range piped to `rg 'font-size: 0\.625rem'` exits with code exactly 1 — assert the **post**-S07 value, not the pre-state: S07 TI03 owns that normalization and this story neither reverts nor re-declares it, so a `0.625rem` still present means S07 has not landed and this task is blocked; `rg -n 'status-dot--|section-label' packages/dartclaw_server/lib/src/templates/channel_detail.html` returns both; the hero title's x-position is identical across `/settings/channels/whatsapp`, `/signal` and `/google_chat`; `rg -no 'status-dot--[a-z]+' packages/dartclaw_server/lib/src/templates/channel_detail.html | sort -u` resolves `Not running`, `Configured` and `Pairing needed` to three different variants, each of which exists in `dev/design-system/components.css`; `dart test test/templates/render_test.dart` passes with its status-badge fixtures (`:74-76`) re-pointed

- [ ] **TI09** The channel mode picker exposes exactly one control per setting to assistive tech
  - The four `<button aria-pressed>` mode cards become a `role="radiogroup"` of `role="radio"` elements with `aria-checked`, and the paired `<select class="channel-mode-select channel-mode-select-hidden">` gains `aria-hidden="true"` + `tabindex="-1"` so it stays the value holder without being announced. Applies to both `dm_access` and `group_access`. Keeps `dc_settings_controller.js`'s existing read/write of the select unchanged.
  - **Verify**: `rg -n 'aria-pressed' packages/dartclaw_server/lib/src/templates/channel_detail.html` returns no matches (exit 1); `rg -n 'role="radiogroup"|role="radio"|aria-checked' packages/dartclaw_server/lib/src/templates/channel_detail.html` returns all three, and each `.channel-mode-select` carries `aria-hidden="true"` and `tabindex="-1"`; tabbing through the DM Access panel reaches one radiogroup and never the select

- [ ] **TI10** The ACTIVE badge, restart banner and pairing block follow the selected mode without a reload
  - `dc_settings_controller.js#syncModeCards` creates and removes the `.channel-mode-badge` element alongside its class / state toggle; `#channel-restart-banner` (today at `channel_detail.html:257`) moves to the top of the content area as an **unconditional sibling** of the `tl:if="${bannerHtml}"` div at `:7` — not inside it: that div is `tl:utext`, so any child markup is overwritten, and its `tl:if` drops the element entirely whenever no shell banner is set, which is the common case and would leave `dc_settings_controller.js:1087`'s `getElementById('channel-restart-banner')` unhiding an element that is not in the DOM. It keeps its `hidden` attribute and its `.banner.banner-warning` classes. If TI12's not-running banner is also present, the two must not stack as identical amber bars — order them and differentiate the copy. The pairing sub-card renders unconditionally with `hidden` and is toggled in the `dm_access` success callback exactly as `.channel-mention-section` already is, with `initPairingPolling` started and stopped with it. Depends on TI09's `aria-checked` state shape.
  - **Verify**: switching DM mode from `pairing` to `open` leaves exactly one `.channel-mode-badge` in the DM panel and it sits on the `open` card; the restart notice becomes visible without scrolling; the pairing block appears when DM mode is set to `pairing` and disappears with its poll stopped when it is not, with no network request to the pairing endpoint after it hides

- [ ] **TI11** An empty allowlist renders the same row on the server and client paths
  - `channel_detail.dart` passes `dmAllowlist.isEmpty ? null : dmAllowlist` and the same for `groupAllowlist`, matching the `pendingPairings` treatment, so the `tl:unless` "No entries" rows fire on first render as `dc_settings_controller.js#renderAllowlistEntries` already does client-side. The two `*AllowlistCount` values stay derived from the original lists.
  - **Verify**: `/settings/channels/google_chat` with an empty DM allowlist renders `.allowlist-empty` "No entries" on first load; adding then removing the only entry returns the identical row, with no visual difference between the server and client renders; "Allowlist (0 entries)" still shows the correct count

- [ ] **TI12** A not-running channel is stated, and Google Chat shows no dead pairing CTA
  - `channel_detail.dart` exposes the **`ChannelStatus` enum value** to the template, not the existing boolean `isConnected` (`:51`, `statusLabel == 'Connected'`) — that boolean is false for `Disabled`, `Configured`, `Pairing needed`, `Reconnecting` and `Connection error` alike, so keying the banner on it would tell a `Disabled` or `Reconnecting` channel that it "is not running". Render the `.banner.banner-warning` under the hero for `notRunning` and `configured` only, with copy matching the actual state, and swap the "DM allowlist changes take effect immediately." hint for one that says the change applies when the channel starts. Per the audit's fix, the DM and group policy panels also take `aria-disabled="true"` plus the reduced-opacity treatment while the channel is not running, so no control presents itself as live. The `Pairing / Registration` anchor is wrapped in `tl:if="${pairingHref}"`, matching the guard already on the Disconnect form. No Start/Connect action is added.
  - **Verify**: `/settings/channels/google_chat` renders no `Pairing / Registration` anchor, one `.banner.banner-warning` naming the not-running state, and DM/group policy panels carrying `aria-disabled="true"`; `/settings/channels/whatsapp` when connected renders the pairing anchor, no such banner, and no `aria-disabled`; a channel reporting `Disabled` or `Reconnecting` gets neither the not-running copy nor the dimming; the "takes effect immediately" string appears only on a connected channel

- [ ] **TI13** The attribution popover dismisses on pointer-out and on Escape
  - `dc_attribution_controller.js` gains a `mouseleave` handler with a short close delay (150ms) so the pointer can travel into the popover. Hold the timer id on the controller instance, cancel it on re-entry (`mouseenter` on either marker or popover), and clear it in both `hide()` and `disconnect()` so a marker-to-marker traversal cannot leave a stale `hide()` pending. The Escape binding moves off the `.citation-marker` button onto `document`, added when the popover opens and **removed in `hide()` and `disconnect()`** — the controller's `disconnect()` currently tears down only the document click listener, so the new listener must be added to the same teardown path or it outlives the HTMX swap. `source_attribution.html` binds the new action.
  - **Verify**: hovering a `[1]` citation marker on `/knowledge` and moving the pointer away closes the popover within 150ms; moving the pointer from marker into the popover keeps it open; traversing marker→marker→marker leaves exactly one popover open and no pending timer; opening by hover and pressing Escape closes it; opening by click and moving the pointer away leaves it open until a click elsewhere; after an HTMX swap of the results list, `getEventListeners(document)` shows no orphaned keydown or click listener from a removed controller

- [ ] **TI14** The topbar owns the only `<h1>` on each of this story's three surfaces
  - Per the plan's shared-surface ownership decision (1), delete the duplicate in-page `<h1>`s this story owns: `knowledge_hub.html:9` (`<h1 class="page-title">Knowledge Hub</h1>`) and `kg_timeline.html:9` (`<h1 class="page-title">KG Timeline</h1>`) go entirely, since the topbar already renders those titles. `channel_detail.html:14`'s `<h1 tl:text="${heroTitle}">` is **not** deleted — it is the hero identity element TI08 steps up a tier; it changes tag so it no longer claims `<h1>` rank while keeping its visual weight. Depends on S16's TI02 having promoted the topbar fragment to `<h1>` (see Constraints & Gotchas) — check that first, or these pages end up with no `<h1>`.
  - **Verify**: `rg -c '<h1' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/templates/kg_timeline.html packages/dartclaw_server/lib/src/templates/channel_detail.html` returns no matches (exit 1 — all three files drop to zero, and `rg -c` omits zero-count files entirely); `rg -n '<h1' packages/dartclaw_server/lib/src/templates/topbar.html` shows the promoted `pageTopbar` / `plainTopbar` titles; each of `/knowledge`, `/knowledge/timeline` and `/settings/channels/whatsapp` exposes **exactly one** `<h1>` in the rendered DOM, supplied by the topbar; the channel hero title still renders at its stepped-up tier and is announced as a heading in the accessibility tree

- [ ] **TI15** The story's deferrals are recorded and the surfaces are validated in both themes
  - Record in the Implementation Observations of the **canonical private FIS** — `../dartclaw-private/docs/specs/0.22.1/fis/s10-sweep-knowledge-and-channel-surfaces.md`, edited directly. A public-repo implementation run must **not** write these into the exported copy under `dev/bundle/`: that tree is transient and removed before merge, so the record would vanish and the metric would fail silently. S14 consolidates every story's Implementation Observations into `../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md`, and that block is the **only** one it reads — a deferral stated solely as a "What We're NOT Doing" prose bullet does not reach the ledger, so every one of them must be repeated here. Do not commit the private repo; the operator commits. Six entries, each with a reason: the knowledge layer counts computed from the filtered result set (`knowledge_hub_service.dart` — service change), snippet markdown-stripping and word-boundary snapping (`packages/dartclaw_storage` — service change), the KG timeline's missing time axis and absent canonical chronology component (canon change plus new capability), the absent Start/Connect action for a not-running channel (new capability), the missing `a.chip` selected-state rule in canon (canon frozen for this story), and the missing `.status-dot--muted` variant that `status-badge-muted` implies (canon frozen). Then validate against the `visual` profile (`bash dev/testing/profiles/visual/run.sh`, port 3338) in both themes at 1440×900 and 768px, comparing against **this story's own story-start captures** of the surfaces it touches — per the plan's visual-baseline protocol, the audit's 92-shot set is the release-level baseline S14 re-proves, and cannot isolate S10's deltas because S01 re-toned and S02 re-scaled every surface first. A regression outside this story's scope is reported, not absorbed. This task also closes the story's structural gates.
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0; `git status --porcelain dev/design-system packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/icons.css packages/dartclaw_server/lib/src/templates/layout.html packages/dartclaw_storage packages/dartclaw_server/lib/src/knowledge` prints nothing; scoped to **this story's own files** — `rg -n 'var\(--text-sm\)|container-wide|content-inner--wide|page-inner--wide' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/templates/kg_timeline.html packages/dartclaw_server/lib/src/templates/channel_detail.html` returns no matches (exit 1), and `git diff -- packages/dartclaw_server/lib/src/static/app.css | rg '^\+' | rg -n 'var\(--text-sm\)|window\.(alert|confirm|prompt)'` returns no matches (exit 1) — do **not** grep those patterns tree-wide: `app.css` carries 79 `var(--text-sm)` uses that S07 retires, and S08/S09 add `page-inner--wide` to their own templates in parallel, so a global assertion fails S10 for a sibling story doing its job correctly; `git -C ../dartclaw-private status --porcelain docs/specs/0.22.1/fis/s10-sweep-knowledge-and-channel-surfaces.md` shows the file modified with all six deferrals present; no surface regresses against this story's own start captures in either theme at either viewport

### Testing Strategy

- The behavioural changes with a server-side seam are TI07's wiki-page render, TI11's view-model null-mapping and TI02's failed-layer flag; each is covered by a `dartclaw_server` test asserting the route/context output (shell page vs. `text/plain`; null vs. empty list; `failedLayers` non-empty → error marker) rather than by visual validation alone. Everything else is template/CSS/controller work proved by the Verify lines and the both-theme visual pass in TI15.
- **Existing suites this story invalidates must be re-pointed, not weakened** — each assertion's intent has to survive the rewrite: `test/web/web_routes_test.dart:91-150` (wiki route response shape and content-type change; `:128`'s traversal case must keep asserting the *uniform* 404 message), `test/templates/render_test.dart:74-76` (channel status-badge fixtures TI08 re-maps), and the knowledge-hub markup assertions in `test/templates/templates_test.dart` and `test/web/pages/knowledge_hub_page_test.dart` that TI01–TI04 rewrite.

### Validation

- The `visual` profile (port 3338) is the only profile that renders all 23 surfaces; `/settings/channels/{whatsapp,signal,google_chat}` must all be captured, since two of this story's findings only appear on the non-WhatsApp channels. Requests carry the profile's gateway token — an unauthenticated `curl` returns a redirect page that also contains `<div class="shell">`, so any shell assertion made without the token passes vacuously.
- Scenario S02's pager clause needs **more than one page of results**, which the profile's single seeded wiki document does not produce. Either seed enough documents to exceed `perPage` before capturing, or prove the pager markup with a template test instead. Note the "Page 1 of N" label is separately known-unstable — `limit = perPage * page + perPage` makes `totalPages` grow as the user pages — and that generation-side defect is deferred with the other service changes.

### Execution Contract

- TI01 settles the chip markup and deletes `.knowledge-search-form`; TI03 retires `.knowledge-result-row`. TI06 re-keys the `app.css:3204` media block that names both, so **TI01 and TI03 run before TI06**.
- TI02 deletes `.knowledge-summary-label`, which S07 TI03's caps-tracking pass targets; re-check that rule after TI02 rather than before.
- TI09's `aria-checked` state shape is what TI10's `syncModeCards` toggles: **TI09 before TI10**.
- TI03 and TI13 both edit `source_attribution.html`; TI08, TI12 and TI14 all edit the `channel_detail.html` hero region. Run them in listed order to avoid clobbering — in particular **TI08 before TI14**, so the hero title is re-tiered before its tag changes and the two edits do not fight over the same element.
- TI05 reuses the canonical tab markup, which S05 already landed — no intra-story dependency on TI01 remains for the tab bar itself.
- TI14 depends on S16's TI02 having promoted the topbar to `<h1>`; it is ordered late for that reason, and TI15 closes the story's gates last.


## Final Validation Checklist

- [ ] None of the three closed canon files (`dev/design-system/tokens.css` / `components.css` / `icons.css`) and none of the served `design-system.css` / `tokens.css` / `icons.css` is modified by this story. Any `DESIGN.md` / `showcase.html` edit is intentional and outside the drift check.


## Implementation Observations

_No observations recorded yet._
