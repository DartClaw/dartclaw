# Surface sweep: knowledge and channel surfaces

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
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
> […] ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes; the serialized P3 stories consume the settled copies without re-syncing them. […] A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

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
> The PRD's NFR reuses the audit's 92-screenshot capture as the before/after baseline. That works at release level but NOT per story: S01 re-tones every surface before S02 re-scales its type, and each later story accumulates further intended deltas, so from S02 onward the audit set cannot isolate one story's work. Protocol: from S02 onward, each story captures its own story-start screenshots of the surfaces it touches, in both themes at desktop and 768px, and validates against those. S01 runs first on the still-audited tree, so the audit's 92-shot capture IS its story-start state — S01 alone validates against the audit set (its existing audit-baseline gate). Beyond S01, the 92-shot set stays the release-level baseline that S14 re-proves once. A story that finds a regression outside its own scope reports it rather than absorbing it.


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
  - **Then** the view switcher is a canonical `.tabs` / `.tab` bar with a continuous baseline rule under both tabs, the search field is a `.form-input--search` inside a `.list-toolbar` (palette background, `--border` hairline, accent `:focus-visible` ring – no UA-default fill or hairline) — both inherited from S05, re-checked here as regression guards, not delivered by this story — and the layer filters are `a.chip` inside a `.chip-row` carrying `aria-current="page"` on the active one with canonical focus treatment; the selected visual treatment is deferred to canon, so this story adds no page-local selected styling
  - **And** the four layer counters render as `.card.card-metric` with `.metric-value` / `.metric-label`, so the count is visibly a larger tier than the result title beside it
  - **And** switching to the KG filter no longer presents the wiki layer's `0` as a corpus total – the strip's visible label and `aria-label` state that it counts the current result set, so a `0` under a non-selected layer is truthful rather than misleading (the corpus-wide recount is deferred – see What We're NOT Doing)

- [ ] **S02 [OC01] [TI03,TI04] Knowledge results, empty state and pager are the canonical ones and the result title is the link**
  - **Given** `/knowledge` with one wiki result, and `/knowledge?layer=memory` with none
  - **When** each is rendered
  - **Then** the result is a `.card` whose `<h2>` title is wrapped in an `<a>` pointing at the item's source href, carries exactly one *visible* layer badge outside `.attribution-popover` (the attribution fragment's inline duplicate at `source_attribution.html:9` suppressed; the popover's own badge at `:12` is retained), and shows a snippet clamped to three lines with a trailing ellipsis rather than a hard mid-word cut
  - **And** the empty view is composed through S16's Dart `emptyStateTemplate` wrapper and renders the canonical `.empty-state` with `.empty-state-title` above its body copy – centred, with the hidden decorative icon – not hand-authored markup or the left-aligned dashed `.knowledge-empty-state` box
  - **And** with more than one page of results the pager's Previous / Next controls are `class="btn btn-ghost"` around a `.pager-label` reading "Page 1 of 2"

- [ ] **S03 [OC01] [TI05] The KG timeline shares the hub's tab bar and empty state, and its reset control says what it does**
  - **Given** `/knowledge/timeline` with no temporal facts recorded
  - **When** the page is rendered
  - **Then** the tab strip is the same canonical `.tabs` / `.tab` component as the hub, with the active accent underline sitting on the strip's baseline rule rather than floating
  - **And** the empty view is composed through S16's Dart `emptyStateTemplate` wrapper with `.empty-state-title`, body copy and a server-owned link back to `/knowledge`, and the dead `.kg-timeline-empty` / `.kg-timeline-error` class hooks no longer appear in the template
  - **And** the control that clears the form reads "Reset filters" with an `icon-x` mask glyph, no `↺` character remains in the template, and activating it clears both the Category and As-of fields

- [ ] **S04 [OC02] [TI07] Navigable routes render inside the app shell without turning wiki failures into an oracle**
  - **Given** a wiki search result linking to `/knowledge/wiki/wiki/README.md` (the route's own guard requires the `wiki/` locator prefix, so the served URL carries the segment twice – see Constraints & Gotchas)
  - **When** it is opened by direct browser navigation, with no `HX-Request` header
  - **Then** the wiki route returns a themed full page containing `<div class="shell">` with sidebar, topbar and a back link to `/knowledge`, and the markdown is rendered through the existing `data-markdown` pipeline – `# Wiki` appears as a heading and backticked spans as code – with no `content-type: text/plain` response remaining in `web_routes.dart`
  - **And** missing workspace, malformed locator prefix, non-`.md` locator, missing file, traversal, symlink escape and `FileSystemException` cases all return the same opaque 404 response `Wiki source not found`, with no requested path, canonical path or exception detail exposed
  - **And** focused route tests exercise all seven rejection paths separately – including malformed prefix versus valid-prefix/non-md – and assert status, content type and body equality so no branch becomes distinguishable
  - **And** `/health-dashboard/audit?page=2&verdict=block&guard=file` opened with no `HX-Request` header returns **200 with the full health page rendered inline** – not a redirect – showing the *second* page of audit rows with both filters still applied, while the same URL with `HX-Request: true` still returns the bare `auditTableFragment` so the existing poll is unchanged

- [ ] **S05 [OC03] [TI09,TI10] Channel detail exposes one control per mode setting, and the badge, banner and pairing block follow the selection**
  - **Given** `/settings/channels/whatsapp` with DM mode set to `pairing`
  - **When** a keyboard user tabs through the DM Access panel and then selects the `open` mode card
  - **Then** exactly one control per mode field is reachable and announced – the four mode cards form a `role="radiogroup"` of `role="radio"` elements with exactly one `aria-checked="true"`, and the paired `<select class="channel-mode-select">` is out of the tab order and the accessibility tree
  - **And** Arrow keys move focus and selection within the radiogroup, while Space selects the focused option and updates the paired select through the existing save path
  - **And** the `Active` badge moves to the `open` card and leaves the `pairing` card, with no reload and no two cards claiming to be active
  - **And** the restart notice appears in the page's top banner slot beside `${bannerHtml}` – visible without scrolling – and the pairing sub-card hides itself with its 5s poll stopped, matching the hint text that says it appears only while DM mode is `pairing`

- [ ] **S06 [OC03] [TI08,TI11,TI12] A not-running channel says so, an empty allowlist renders identically on both paths, and Google Chat shows no dead CTA**
  - **Given** `/settings/channels/google_chat` reporting status `Not running`, with an empty DM allowlist
  - **When** the page is rendered, and then an allowlist entry is added and removed again over the client path
  - **Then** a `.banner.banner-warning` under the hero states that the channel is not running and that policy changes apply when it starts, the "DM allowlist changes take effect immediately." hint is replaced accordingly, and the editable DM/group policy panels remain enabled and undimmed, while the banner and hint make clear that changes apply when the channel starts
  - **And** the badge, dot, state banner, policy hint and connected-only actions all come from the same exhaustive typed `ChannelStatus` presentation record, never from `statusLabel` string comparison, `badgeVariant`, `isConnected` or a second switch – including null WhatsApp and Signal injections, which resolve through `ChannelStatus.disabled.presentation` rather than ad-hoc `Not configured` / `warn` fallbacks; `Disabled`, `Reconnecting` and `Connection error` are not told they are merely "not running", while `Connected` alone gets the immediate-change hint and connected-only action
  - **And** the "No entries" row renders on the first server render – not only after the client round-trip – because the empty list is passed as null the way `pendingPairings` already is
  - **And** no `Pairing / Registration` anchor is emitted, because `pairingHref` is null for `google_chat`
  - **And** the status badge preserves its existing `status-badge-*` class while embedding a separately mapped `.status-dot--{variant}`; disabled consumes S03's neutral `status-badge-muted` with the independently decided `--idle` dot, while `Not running`, `Configured` and `Pairing needed` resolve to `--idle`, `--warning` and `--attention` without ever producing `status-badge-live`, `status-badge-idle` or `status-badge-attention`; the hero title starts at the same x-position here as on `/settings/channels/whatsapp` and `/signal`

- [ ] **S07 [OC04] [TI06,TI13] These surfaces hold at 768px and stop conveying state by colour alone**
  - **Given** `/knowledge`, `/knowledge/timeline` and a wiki citation marker at a 768px viewport in both themes
  - **When** each is rendered and a citation marker is hovered and then left
  - **Then** the knowledge search form, summary strip and result rows collapse to one column and the citation marker reaches its 44px touch target – no `@media (max-width: 767px)` block remains in `app.css`
  - **And** the four layer badges resolve to `--chart-3` … `--chart-6` by fixed layer index instead of `--info` / `--accent` / `--warning` — the ramp's first two stops are excluded because canon aliases them straight onto the forbidden hues (`tokens.css:50-51`: `--chart-1: var(--accent)`, `--chart-2: var(--info)`) — each still measuring ≥ 4.5:1 against its badge ground in both themes, and the selected filter exposes `aria-current="page"` and canonical focus treatment; its visual selected treatment remains a canon deferral, with no page-local styling added
  - **And** moving the pointer off the citation marker closes the attribution popover, and Escape closes it when it was opened by hover without focus

- [ ] **S08 [OC01,OC02,OC03,OC04] [TI15] Every finding this story does not close is recorded as an explicit deferral S14 can read**
  - **Given** the story's four capability/service deferrals (filtered layer counts, snippet generation, the KG timeline's missing time axis, the absent Start/Connect action) and the one canon-blocked item (`a.chip` selected treatment); S03's shipped `status-badge-muted` plus independent idle-dot contract is consumed, not deferred
  - **When** the story reaches its end
  - **Then** all five appear under `## Implementation Observations` in **`../dartclaw-private/docs/specs/0.22.1/fis/s10-sweep-knowledge-and-channel-surfaces.md`** – the canonical private copy, not the transient `dev/bundle/` export – each with a one-line reason
  - **And** each one that is also stated in prose as a "What We're NOT Doing" bullet appears in Implementation Observations too — the preferred write-back location S14 consolidates into `../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md`; its sweep reads the whole canonical FIS as a safety net, but a prose-only deferral relies on that net rather than the supported path
  - **And** `git -C ../dartclaw-private status --porcelain docs/specs/0.22.1/fis/s10-sweep-knowledge-and-channel-surfaces.md` shows the file modified, proving the record survived the bundle boundary (do **not** commit it – the operator commits in the private repo)

- [ ] **S09 [OC01,OC03] [TI14] Each swept page exposes exactly one `<h1>`, and it comes from the topbar**
  - **Given** `/knowledge`, `/knowledge/timeline` and `/settings/channels/whatsapp` after S16's TI02 has promoted the topbar fragment to `<h1>`
  - **When** each is rendered
  - **Then** each page's DOM contains exactly one `<h1>`, emitted by the topbar, with no in-page duplicate beneath it
  - **And** the channel hero title still renders at its stepped-up tier and is announced as a heading, having changed tag rather than been deleted


## Structural Criteria

- [ ] `dev/tools/fitness/check_design_system_sync.sh` exits 0 at story end; with `BASE=.agent_temp/0.22.1-s10-entry`, the three canon and three served-CSS `cmp -s` checks exit 0. This story edits none of the closed canon or served CSS files.
- [ ] No `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` is introduced in `lib/src/static/controllers/`.
- [ ] No service, schema or API change: with `BASE=.agent_temp/0.22.1-s10-entry`, the `rsync -ainc --delete` comparisons for `packages/dartclaw_storage/` and `packages/dartclaw_server/lib/src/knowledge/` print nothing.
- [ ] No new runtime JS dependency and no new external origin in `layout.html` or the CSP; with `BASE=.agent_temp/0.22.1-s10-entry`, the `layout.html` `cmp -s` check exits 0.
- [ ] `--container-wide` / `.content-inner--wide` / `.page-inner--wide` is applied to no surface in this story – knowledge results keep the 900px measure and channel detail is not on S02's wide list.
- [ ] No new `var(--text-sm)` usage is introduced (assert on this story's diff, not on `app.css` tree-wide — retiring the 79 existing uses is S07's gate).
- [ ] Each of the 15 glitches and 20 adoption gaps this story claims is closed, or recorded in Implementation Observations as a deferral with a reason. "Listed" means the findings under the audit headings named in Deeper Context; multi-surface findings that merely touch these pages are **not** claimed here, and where one is partly closed (the not-running channel entry's Start/Connect half) the uncovered half is recorded as a deferral rather than dropped.
- [ ] `packages/dartclaw_server/lib/src/web/web_routes.dart`, `web/channel_status.dart`, `web/pages/health_page.dart` and `templates/loader.dart` are the only non-page-template `.dart` files this story edits. `health_page.dart` threads the requested audit page into the inline full-page render; `loader.dart` adds the wiki template basename to `expectedTemplates`; none is a service, schema or API change.
- [ ] The new wiki page pair uses basename `wiki_document`; a Dart assertion counts exactly one equal entry in `loader.dart#expectedTemplates`, and the route succeeds through non-dev filesystem initialization (`initTemplates(..., devMode: false)`) as well as the real embedded bundle.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/templates/knowledge_hub.html` + `knowledge_hub.dart` – tabs, search toolbar, filter chips, KPI strip, result rows, `emptyStateTemplate` composition, pager, failed-layer marker.
- `packages/dartclaw_server/lib/src/templates/kg_timeline.html` + `kg_timeline.dart` – tab bar, filter labels, `emptyStateTemplate` composition, reset control.
- `packages/dartclaw_server/lib/src/templates/channel_detail.html` + `channel_detail.dart` + `web/channel_status.dart` – hero, status badge, panel treatments, micro-labels, allowlist / pairing / not-running states.
- `packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` and `dc_attribution_controller.js` + `templates/source_attribution.html` – mode-card badge sync, pairing-section visibility, popover dismissal, duplicate badge suppression.
- `packages/dartclaw_server/lib/src/web/web_routes.dart`, `templates/wiki_document.html` + `wiki_document.dart`, and `templates/loader.dart` – `/knowledge/wiki/<path>` rendered in the shell, the basename registered in `expectedTemplates` for filesystem/dev and embedded parity, `/health-dashboard/audit` full page inline on direct navigation (S10's by plan ruling), and whatever `page`-threading that inline render needs at its `web/pages/health_page.dart` seam.
- `packages/dartclaw_server/lib/src/static/app.css` knowledge / kg-timeline / channel blocks – delete the superseded per-surface rules, normalize the three 767px breakpoints, caps tracking, section rhythm.

### What We're NOT Doing
- **Recomputing the knowledge layer counts from an unfiltered corpus query** -- the root cause is `knowledge_hub_service.dart#KnowledgeHubService.search`, a service change the PRD puts out of scope. The in-scope remedy is to label the strip for the result set it actually reports; the corpus-summary behaviour is deferred with a recorded reason.
- **Stripping markdown and snapping snippets to a word boundary** -- `WikiSearchSource._snippet` lives in `packages/dartclaw_storage`, also a service change. The in-scope remedy is the three-line visual clamp with an ellipsis; the generation-side defect is deferred with a recorded reason.
- **A canonical chronology / timeline component and the KG timeline's missing time axis** -- a new canon component family, which P1 closed, and a new capability the release excludes. Deferred with a recorded reason per the plan's glitch-ledger rule.
- **A Start / Connect action for a not-running channel** -- no such endpoint exists; adding one is a new UX capability. This story states the condition, it does not make it actionable.
- **Re-toning `.card`, `.well` or the page ground on these surfaces** -- the audit's "nested wells land on the page background" finding is attributed to `dev/design-system/tokens.css` and belongs to S01's ladder; adopting canon `.card` is how the fix reaches these pages.
- **Loading/skeleton treatments** -- neither `knowledge_hub.html` nor `kg_timeline.html` carries an `hx-get` or `hx-trigger` (search is a plain GET form submit, so the browser owns the transition), and the channel pairing row already renders `.scan-bar` (`app.css#.pairing-status-row`). There is no in-flight state on these surfaces to dress.
- **An `a.chip[aria-current]` selected treatment in canon** -- canon's pressed-chip rule is `button`-qualified (`components.css:1956`) and the layer filters must stay GET-navigation anchors, so the selected state has no canonical visual rule to adopt. Canon is frozen for this story; preserve `aria-current="page"` and canonical focus only, add no page-local selected styling, and record the deferral.
- **A `.status-dot--muted` variant** -- S03 explicitly ships the neutral `.status-badge-muted` treatment and explicitly keeps disabled's independent dot suffix at `idle`; S10 consumes that complete contract. There is no missing rule and no deferral to record.
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
file   | packages/dartclaw_server/lib/src/templates/loader.dart#expectedTemplates      | Filesystem/dev loading is manifest-driven while embedded loading discovers assets; the new `wiki_document` basename must be registered so both modes agree
file   | dev/design-system/components.css#.chip                                      | `.chip` (:1930) and `.chip-row` (:1992) the filter chips adopt — note the active treatment at `:1956` is `button.chip[aria-pressed="true"]`, element-qualified, so anchor chips get no pressed state from it
file   | dev/design-system/components.css#.status-dot                                | `.status-dot--{variant}` shapes the channel status badge must embed
wire   | docs/wireframes/knowledge-hub.html                                          | Intended hub layout and section rhythm
```


## Constraints & Gotchas

- **Critical**: canon **rules** are frozen for this story, but the closure covers three files, not the directory. `dev/design-system/tokens.css`, `components.css` and `icons.css` (and their served copies) are closed after P1 and drift-checked for byte identity — a rule change there is not S10's, and is recorded as a deferral instead. `DESIGN.md` and `showcase.html` are **not** closed and **not** drift-checked (`docs/specs/0.22.1/canon-hoist-manifest.md`), so this story may write a documented contract for a rule it owns; S14 reconciles the document at release close. The sole canon-blocked deferral is the `a.chip` selected treatment. S03 already ships `.status-badge-muted` and deliberately pairs disabled with the independent `idle` dot, so S10 has an arrival gate to consume rather than a second canon gap.
- **Constraint**: `app.css` loads after `design-system.css` (`layout.html`), so an app-local rule of equal specificity still wins. Adopting a canonical class without deleting the superseded app rule leaves the old treatment in force -- Workaround: delete the local rule in the same task that swaps the markup, and verify the class name is gone from `app.css`.
- **Avoid**: re-litigating the container tier. `--container-wide` assignment is fixed by S02 and neither knowledge nor channel detail is on the wide list -- Instead: leave `.page-inner` / `.content-inner` as they are.
- **Critical**: this story executes alone in W6 after S07 W2, S16 W3, S08 W4 and S09 W5 have accumulated changes in `app.css`; S11 W7, S12 W8 and S15 W9 follow. Re-read the knowledge / kg-timeline / channel blocks before editing – the audit's line numbers are from the pre-S05/S07/S16 build and will have moved. Locate by selector, never by line.
- **Constraint**: this story deletes three of the six duplicate in-page `<h1>`s per the plan's shared-surface ownership decision (1) — `knowledge_hub.html:9`, `kg_timeline.html:9` and `channel_detail.html:14`. This is safe **only after S16's TI02**, which promotes `topbar.html`'s `pageTopbar` / `plainTopbar` titles from `<span class="session-title-static">` to `<h1 class="session-title-static">`; the topbar emits no `<h1>` today, so deleting these first would leave three pages with no `<h1>` at all. S10 `dependsOn: ["S07", "S16"]`, so the ordering holds — but verify the topbar actually emits one before deleting. `login.html` is exempt (no topbar); settings→S11 and projects→S15 are not this story's.
- **Avoid**: reading `channel_detail.html:14`'s `<h1>` as a page-title duplicate to simply delete. It is the **hero title**, the identity moment TI08 steps up a tier. The element stays and keeps its prominence — it is demoted from `<h1>` to a non-heading-rank element (the topbar now owns the page's only `<h1>`) -- Instead: change the tag and keep the visual tier, per the shared decision's "Pages carry a subtitle or description head, never a second `<h1>`".
- **Avoid**: giving the four knowledge layers semantic hues. `--accent` is the selection and success colour and `--warning` / `--info` are state colours -- Instead: `--chart-1` … `--chart-4` by fixed layer index, with selection conveyed semantically by `aria-current="page"`; its visual treatment remains deferred rather than locally invented.
- **Constraint**: `tl:unless="${list}"` does not fire for an empty-but-non-null list in Trellis -- Workaround: pass `list.isEmpty ? null : list` from the `.dart` view-model, as `channel_detail.dart` already does for `pendingPairings`.
- **Critical**: `/health-dashboard/audit` is **S10's by plan ruling** (`plan.json` shared decision *Shared-surface ownership in the sweep phase* (3)): "S10 owns the `/health-dashboard/audit` non-fragment behaviour and renders the full page inline (preserving the `page` param, which a redirect would drop); S09 does not touch that handler." S09's competing TI09 redirect is deleted in remediation — do not reinstate it, and do not coordinate with S09 on this file.
- **Critical**: the `page`-preservation that decided that ruling **does not come for free**. `web/pages/health_page.dart#HealthDashboardPage.handler:36-44` reads only `verdict` and `guard` and calls `auditReader.read(verdictFilter:, guardFilter:)` with **no `page:` argument**, so it renders page 1 regardless. Rendering the existing page handler unchanged would drop `page` exactly as the rejected redirect would, silently voiding the ruling's rationale -- Workaround: thread `page` from the query string into the audit read on the non-fragment branch, and assert page 2 specifically in the Verify. `wantsFragment` (`web_utils.dart:8`) is the correct predicate and is already history-restore-aware: it returns false for `HX-History-Restore-Request: true`, so a history restore correctly gets the full page.
- **Critical**: the wiki route's own guard requires the locator prefix — `web_routes.dart:537` rejects anything not matching `decoded.startsWith('wiki/') && decoded.endsWith('.md')`, and `knowledge_hub_service.dart:213` emits `'/knowledge/wiki/$encoded'` where `encoded` *already* begins `wiki/`. The served URL therefore carries the segment twice: `/knowledge/wiki/wiki/README.md`. `test/web/web_routes_test.dart:111,128,144` all use that shape -- Workaround: never write `/knowledge/wiki/<file>.md` in a test or Verify line; it hits the reject branch and passes for the wrong reason.
- **Constraint**: canon's only pressed-chip treatment is element-qualified — `button.chip[aria-pressed="true"]` (`components.css:1956`); `a.chip` gets hover and focus rules only (`:1951-1952`). The knowledge layer filters are GET-navigation anchors (`knowledge_hub.html:29-30`) and must stay anchors, so `aria-pressed` on them is both invalid ARIA and visually inert -- Workaround: use `aria-current="page"` and retain canonical focus behaviour only; record the absent `a.chip` selected treatment as a canon deferral rather than adding page-local styling. Adding the rule here would breach the frozen-canon constraint.
- **Avoid**: reading `--chart-1` … `--chart-4` as a neutral categorical family. Canon aliases the first two onto the exact hues this story is trying to escape (`tokens.css:50-55`: `--chart-1: var(--accent)`, `--chart-2: var(--info)`, `--chart-3: var(--mauve)`, `--chart-4: var(--teal)`, `--chart-5: var(--pink)`, `--chart-6: var(--sky)`) -- Instead: assign the four layers to `--chart-3` … `--chart-6`. Re-basing `--chart-1` is a canon edit this story cannot make.


## Implementation Plan

### Implementation Tasks

Before TI01, snapshot every protected path and `app.css` exactly as W6 receives them. These comparisons isolate S10's delta from the accumulated W1–W5 checkout:

```sh
BASE=.agent_temp/0.22.1-s10-entry
rm -rf "$BASE"
mkdir -p "$BASE/dev/design-system" "$BASE/packages/dartclaw_server/lib/src/static" "$BASE/packages/dartclaw_server/lib/src/templates" "$BASE/packages/dartclaw_server/lib/src"
cp dev/design-system/tokens.css dev/design-system/components.css dev/design-system/icons.css "$BASE/dev/design-system/"
cp packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/icons.css packages/dartclaw_server/lib/src/static/app.css "$BASE/packages/dartclaw_server/lib/src/static/"
cp packages/dartclaw_server/lib/src/templates/layout.html "$BASE/packages/dartclaw_server/lib/src/templates/"
rsync -a --exclude='.dart_tool/' --exclude='.DS_Store' packages/dartclaw_storage/ "$BASE/packages/dartclaw_storage/"
cp -R packages/dartclaw_server/lib/src/knowledge "$BASE/packages/dartclaw_server/lib/src/"
```

- [ ] **TI01** The knowledge hub header uses the canonical tab, toolbar and chip components
  - **Inherited from S05, not delivered here** — S05's TI02/TI09 (`s05-…:226,220`) already convert `.knowledge-tabs` > `.tab-btn` to canonical `.tabs` / `.tab` and `.knowledge-search-strip` / `-form` to `.list-toolbar` + `.form-input--search`, naming `knowledge_hub.html:20-21,63,65` as "the only consumer". Treat those as preconditions and re-check them as regression guards. **S10's own work in this task** is the filter chips: the `.filter-chip-row` becomes a `.chip-row` of `a.chip` carrying `aria-current="page"` on the active filter (anchors, not buttons — see Constraints & Gotchas), with `className` in `knowledge_hub.dart#layerChips` emitting the canonical names, and `.filter-chip` / `.filter-chip--active` deleted from `app.css`. Because canon has no `a.chip` selected rule, preserve `aria-current="page"` and canonical focus behaviour only; record the visual selected treatment as a deferral and add no page-local or canon rule.
  - **Verify**: `rg -n 'filter-chip' packages/dartclaw_server/lib/src/templates/ packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1); `rg -n 'class="chip-row"' packages/dartclaw_server/lib/src/templates/knowledge_hub.html` matches (the quoted form matters — a bare `chip-row` also matches the `filter-chip-row` being deleted) and the active chip reports `aria-current="page"` with canonical focus behaviour; no page-local selected-style selector is introduced; regression guards for S05's output: `rg -n 'knowledge-tabs|knowledge-search-strip|knowledge-search-form' packages/dartclaw_server/lib/src/templates/ packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1) and `rg -n 'class="tabs"|list-toolbar|form-input--search' packages/dartclaw_server/lib/src/templates/knowledge_hub.html` returns all three

- [ ] **TI02** The knowledge layer strip reads as a KPI row and distinguishes a failed layer from an empty one
  - S07 already gives `.knowledge-summary-item` the baseline `.card` class and deletes its clone surface declarations. Replace that baseline row semantically with `.card.card-metric` > `.metric-value` + `.metric-label`; then remove the obsolete `.knowledge-summary-item` / `-count` / `-label` selectors and class tokens as this story's semantic-replacement cleanup. `knowledge_hub.dart#layerSummaries` gains a per-layer failed flag from `result.failedLayers` so a failed layer's cell shows an explicit error marker instead of `0`, and the strip's `aria-label` plus its visible label state that it reports the current result set, not the corpus. The `notice notice-warning` hook on the partial-results block has no rule anywhere – it becomes `.banner.banner-warning`.
  - **Verify**: `rg -n 'knowledge-summary-item|knowledge-summary-count|knowledge-summary-label|notice-warning' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1); on `/knowledge` the counter renders at the `.card-metric .metric-value` tier (32px) against a 14px `.metric-label`; and a `knowledge_hub.dart` unit test built from a `KnowledgeHubResult` fixture with a non-empty `failedLayers` asserts that layer's cell renders the error marker rather than `0` — the field already exists at `knowledge_hub_service.dart:59`, so no service change is needed and no fault injection against a live profile is required

- [ ] **TI03** Knowledge results are cards whose title is the link, with one badge and a clamped snippet
  - S07 already gives `.knowledge-result-row` the baseline `.card` class and deletes its clone surface declarations. Replace its semantic row markup with `class="card"` (plain – hue stays on the badge per Constraints), then remove the obsolete `.knowledge-result-row` selector/class as this story's cleanup. The `<h2 class="knowledge-result-title">` is wrapped in an `<a>` on `item.sourceHref`; `source_attribution.html#sourceAttribution` suppresses its inline `.layer-badge` when the host row already renders one (a flag through `source_attribution.dart`, not a second fragment); `.knowledge-result-snippet` gains a three-line clamp with a trailing ellipsis.
  - **Verify**: `/knowledge` renders each result inside a `.card` measuring ≥ 1.15:1 against the page ground in both themes; the title is a focusable link resolving to the item's source href; exactly one `.layer-badge` appears per result row; the snippet ends in an ellipsis at three lines rather than mid-word

- [ ] **TI04** The knowledge hub's empty state and pager are the canonical ones
  - **Largely inherited** — **S16 TI04** deletes `.knowledge-empty-state` and the app-local `.empty-state-icon/-title/-text` shadow family, and S05 (`s05-…:234`) already converts `.pager-link` to `class="btn btn-ghost"`. **S10's own work** is splitting `knowledge_hub.dart#_emptyMessage` into title and body copy, composing that state through `components.dart#emptyStateTemplate`, and passing the returned server-owned HTML through one template-owned `tl:utext` slot; do not hand-author the fragment or render the Trellis fragment directly. The wrapper must be the exercised seam so a missing/misnamed context key fails coverage.
  - **Verify**: a rendered-template test invokes `knowledgeHubTemplate` with no results and proves its output contains the default `emptyStateTemplate` anatomy – hidden decorative icon, `.empty-state-title`, split body copy and no bespoke class – so direct hand-authored markup cannot satisfy the test. Regression guards for S05/S16's output: `rg -n 'knowledge-empty-state|pager-link' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1), and with more than one page of results the pager shows `btn btn-ghost` Previous / Next around a `.pager-label` (see Validation — the `visual` profile does not seed enough documents to produce a second page unaided)

- [ ] **TI05** The KG timeline shares the hub's tab bar and empty state, and its controls are honestly labelled
  - `kg_timeline.html` already carries the canonical `.tabs` / `.tab` component from S05 (`s05-…:226`, which names this file explicitly) — re-check it, do not re-adopt it. **S10's own work**: `kg_timeline.dart` composes the empty case through `components.dart#emptyStateTemplate`, including the server-owned link back to `/knowledge`; the dead `.kg-timeline-empty` / `.kg-timeline-error` hooks are dropped from the markup; the `↺ now` anchor becomes "Reset filters" with `<span class="icon icon-x" aria-hidden="true">`, and activating it must clear the As-of field *and* the Category filter it silently resets today.
  - **Verify**: `rg -n 'kg-timeline-empty|kg-timeline-error|↺' packages/dartclaw_server/lib/src/templates/kg_timeline.html` returns no matches (exit 1); a rendered-template test invokes `kgTimelineTemplate` with no facts and proves the default `emptyStateTemplate` anatomy plus the working `/knowledge` action are present, so direct hand-authored markup cannot satisfy the test; the reset control reads "Reset filters" and carries `class="icon icon-x"`, and activating it clears both Category and As-of; regression guard for S05's output: `rg -c 'class="tabs"' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/templates/kg_timeline.html` prints a count line for **both** files (a file with no match is omitted from `rg -c` output entirely, so a missing line is the failure signal), proving both strips share one component

- [ ] **TI06** Knowledge and KG surfaces collapse on the app's breakpoint, carry canon caps tracking, and give layer identity the categorical ramp
  - The three `@media (max-width: 767px)` blocks in `app.css` (citation marker touch target `:3006`, knowledge grids `:3204`, kg-timeline controls `:3393`) move to `max-width: 768px`. **Re-key the `:3204` block's selectors first** — it currently lists `.knowledge-search-form`, `.knowledge-summary-strip` and `.knowledge-result-row`, two of which no longer exist after S05/TI01 (`.knowledge-search-form` → `.list-toolbar`) and TI03 (`.knowledge-result-row` → `.card`); keeping them verbatim both preserves dead selectors and trips TI01's own gate. Point the block at the surviving classes, or delete it where canon's `.list-toolbar` already supplies the wrap. `.layer-badge--wiki` / `-kg` / `-memory` / `-inbox` re-point from `--info` / `--teal` / `--accent` / `--warning` to `--chart-3` / `--chart-4` / `--chart-5` / `--chart-6` by fixed layer index — **not** `--chart-1` / `-2`, which canon aliases onto `--accent` / `--info` (see Constraints & Gotchas) — and `.read-only-marker` moves off `--accent` onto a neutral `.status-badge`; the stacked `margin-bottom` on the knowledge section blocks is dropped so `.page-inner`'s gap owns the rhythm. The caps-tracking pass on `.layer-badge`, `.unverified-flag` and `.kg-timeline-controls .field-label` is **S07 TI03's** — re-check it here, do not redo it.
  - **Verify**: `rg -n 'max-width: 767px' packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1) — all three blocks are S10-owned, and `@media (min-width: 769px)` at `app.css:229` confirms 768/769 is the app's own pair, so the shift introduces no overlap; for each of the four variants `rg -A4 '^\.layer-badge--wiki' packages/dartclaw_server/lib/src/static/app.css` (and `-kg` / `-memory` / `-inbox`) shows its assigned `var(--chart-N)` with N in 3…6 and no `var(--(info|accent|warning|teal))` remaining in that block — assert per variant, not by a global count, since S07 rewrites `.layer-badge--kg`'s declaration shape; each badge measures ≥ 4.5:1 against its ground in both themes (S07 closed this as a WCAG AA finding — do not reopen it); at exactly 768px the knowledge toolbar, summary strip and result cards each render one column and `.citation-marker` measures ≥ 44×44px; every remaining `text-transform: uppercase` rule in the knowledge and kg-timeline blocks declares `var(--tracking-caps)`

- [ ] **TI07** Wiki documents and the audit table render inside the app shell in filesystem and embedded modes
  - Add `templates/wiki_document.html` + `wiki_document.dart` and register the basename `wiki_document` exactly once in `templates/loader.dart#expectedTemplates`. Prove membership in Dart (`expectedTemplates.where((name) => name == 'wiki_document').length == 1`), not with a source-text count that can match comments or unrelated literals. This is load-bearing: filesystem loading iterates that manifest, while embedded loading discovers generated assets, so generated parity alone cannot prove the source-tree path.
  - `web_routes.dart` `/knowledge/wiki/<sourcePath|.*>` returns the `wiki_document` full shell page – sidebar from `pageContext.sidebar`, `pageTopbarTemplate(backHref: '/knowledge', …)`, body a `.card` with `data-markdown` per `templates/task_detail.html` – instead of `content-type: text/plain`. Every rejection path is opaque and identical: missing workspace, malformed `wiki/` prefix, non-`.md` locator, missing file, `p.isWithin` traversal rejection, symlink escape and `FileSystemException` all return 404 `Wiki source not found` without echoing the locator, resolved path or exception. Follow `knowledge_hub.dart#knowledgeHubTemplate` for assembly; no service call changes.
  - In the same file, `/health-dashboard/audit` branches on `wantsFragment(request)`: true → the bare fragment, unchanged; false → the full health page rendered **inline** (not a redirect), with `page`, `verdict` and `guard` all threaded into the audit read. This route is S10's by plan ruling.
  - **Verify, in order**: (1) a Dart test asserts `expectedTemplates.where((name) => name == 'wiki_document').length == 1`, resets templates, calls `initTemplates(resolveTemplatesDir(), devMode: false)` and serves the real wiki route – non-dev filesystem mode is mandatory, while `devMode: true` may be supplemental; (2) focused route tests separately cover missing workspace, malformed prefix, non-md, missing file, traversal, symlink escape and a deterministic `FileSystemException` fixture, asserting the same opaque 404 status/content-type/body for all seven; (3) run `dart run dev/tools/embed_assets.dart`; (4) generated parity passes; (5) reset templates and run the same wiki route through default `initEmbeddedTemplates()` backed by the real `embeddedServerAssets`, asserting the shell, `data-markdown` and document heading; (6) audit direct/HTMX/history-restore cases prove inline page 2 with filters versus fragment output; (7) run the full `dart test packages/dartclaw_server/test` suite. The synthetic-map `embedded_loader_test.dart` may retain its loader-unit coverage but is not evidence that the generated bundle contains `wiki_document`, and generated/full-suite ordering must not be reversed.

- [ ] **TI08** One exhaustive typed `ChannelStatus` presentation record drives every status consumer
  - `.channel-detail-hero-title` gains `flex: 1 1 auto; min-width: 0` so the identicon-title pair is left-aligned and the badge is the only right-aligned item; the hero identicon and title step up a tier; `panel-accent` / `panel-info` become plain `.card`; `.channel-panel-kicker` and `.channel-sub-card h3` become `.section-label`; `.channel-sub-card` gets a column flex with `gap: var(--sp-3)`. The `.channel-mode-badge` type normalization remains S07's.
  - Replace the enum's split constructor fields plus any page-local status decisions with one typed presentation record returned by an exhaustive `switch (this)` over `ChannelStatus`, with one arm per value and no wildcard/default. Its fields are independent – `label`, `badgeClass`, `dotVariant`, nullable `stateBannerVariant`, nullable `stateBannerText`, nullable `dmPolicyHint`, and `connected` – so no dot, banner, hint or connected-only action is inferred from a badge suffix, label string or boolean assembled elsewhere. Exact contract:

    | Status | Label | Badge class | Dot suffix | State banner | DM policy hint | Connected |
    |---|---|---|---|---|---|---|
    | `disabled` | Disabled | `status-badge-muted` | `idle` | none | none | false |
    | `notRunning` | Not running | `status-badge-warning` | `idle` | `warning`: “Channel is not running. Policy changes apply when it starts.” | “DM allowlist changes apply when the channel starts.” | false |
    | `configured` | Configured | `status-badge-warning` | `warning` | `warning`: “Channel is configured but not running. Policy changes apply when it starts.” | “DM allowlist changes apply when the channel starts.” | false |
    | `pairingNeeded` | Pairing needed | `status-badge-warning` | `attention` | none | none | false |
    | `connectionError` | Connection error | `status-badge-error` | `error` | none | none | false |
    | `connected` | Connected | `status-badge-success` | `live` | none | “DM allowlist changes take effect immediately.” | true |
    | `reconnecting` | Reconnecting | `status-badge-warning` | `warning` | none | none | false |

  - The settings channel summary badges and every `web_routes.dart` channel-detail branch consume this same record. Null WhatsApp and Signal injections map to `ChannelStatus.disabled.presentation`; delete their ad-hoc `status?.label ?? 'Not configured'` and `status?.badgeClass ?? 'warn'` fallbacks. Thread badge class, dot suffix, banner variant/text, policy hint and connected flag as distinct template context values; the template composes `status-badge-*`, an empty `.status-dot status-dot--*`, optional `.banner.banner-*`, optional hint and connected-only action without a second status switch. Never feed dot-only suffixes `live`, `idle` or `attention` into `status-badge-*`; disabled consumes S03's `status-badge-muted` plus the independent `idle` dot, with no `.status-dot--muted` rule or deferral.
  - **Verify**: arrival gate first: served `design-system.css` contains the exact S03 selector `.status-badge-muted` and contains no `.status-dot--muted`. One table-driven test iterates `ChannelStatus.values` and asserts exact equality of every field in the seven-row contract – including explicit `connectionError` and `connected` cases – while a source assertion scoped to the presentation getter rejects `_ =>` and `default`; settings and channel-detail rendering tests prove both consumers use the record rather than independent maps or `statusLabel == 'Connected'`. Route tests with null WhatsApp and null Signal dependencies assert the disabled presentation exactly (`Disabled`, `status-badge-muted`, idle dot, no banner/hint/action) and reject `Not configured` / `warn`. For every distinct emitted suffix, the test reads served `design-system.css` and requires the exact selector: each `status-badge-{muted|warning|error|success}`, each `status-dot--{idle|warning|attention|error|live}`, and `banner-warning`; checking that a suffix token appears somewhere is insufficient. `Not running`, `Configured` and `Pairing needed` render different dots while retaining their warning badges; `Connection error` renders error badge + error dot with no not-running banner or immediate hint; `Connected` renders success badge + live dot, the immediate hint and connected-only action.

- [ ] **TI09** The channel mode picker exposes exactly one control per setting to assistive tech
  - The four `<button aria-pressed>` mode cards become a `role="radiogroup"` of `role="radio"` elements with `aria-checked`, and the paired `<select class="channel-mode-select channel-mode-select-hidden">` gains `aria-hidden="true"` + `tabindex="-1"` so it stays the value holder without being announced. Each `dm_access` and `group_access` radiogroup has exactly one `aria-checked="true"`; Arrow keys move focus and selection among its radios, and Space selects the focused radio, updates the paired select and follows the existing save path.
  - **Verify**: `rg -n 'aria-pressed' packages/dartclaw_server/lib/src/templates/channel_detail.html` returns no matches (exit 1); `rg -n 'role="radiogroup"|role="radio"|aria-checked' packages/dartclaw_server/lib/src/templates/channel_detail.html` returns all three, and each `.channel-mode-select` carries `aria-hidden="true"` and `tabindex="-1"`; each group has exactly one checked radio; tabbing through the DM Access panel reaches one radiogroup and never the select; Arrow keys move focus and selection, and Space selects the focused option and updates the paired select

- [ ] **TI10** The ACTIVE badge, restart banner and pairing block follow the selected mode without a reload
  - `dc_settings_controller.js#syncModeCards` creates and removes the `.channel-mode-badge` element alongside its class / state toggle; `#channel-restart-banner` (today at `channel_detail.html:257`) moves to the top of the content area as an **unconditional sibling** of the `tl:if="${bannerHtml}"` div at `:7` — not inside it: that div is `tl:utext`, so any child markup is overwritten, and its `tl:if` drops the element entirely whenever no shell banner is set, which is the common case and would leave `dc_settings_controller.js:1087`'s `getElementById('channel-restart-banner')` unhiding an element that is not in the DOM. It keeps its `hidden` attribute and its `.banner.banner-warning` classes. If TI12's not-running banner is also present, the two must not stack as identical amber bars — order them and differentiate the copy. The pairing sub-card renders unconditionally with `hidden` and is toggled in the `dm_access` success callback exactly as `.channel-mention-section` already is, with `initPairingPolling` started and stopped with it. Depends on TI09's `aria-checked` state shape.
  - **Verify**: switching DM mode from `pairing` to `open` leaves exactly one `.channel-mode-badge` in the DM panel and it sits on the `open` card; the restart notice becomes visible without scrolling; the pairing block appears when DM mode is set to `pairing` and disappears with its poll stopped when it is not, with no network request to the pairing endpoint after it hides

- [ ] **TI11** An empty allowlist renders the same row on the server and client paths
  - `channel_detail.dart` passes `dmAllowlist.isEmpty ? null : dmAllowlist` and the same for `groupAllowlist`, matching the `pendingPairings` treatment, so the `tl:unless` "No entries" rows fire on first render as `dc_settings_controller.js#renderAllowlistEntries` already does client-side. The two `*AllowlistCount` values stay derived from the original lists.
  - **Verify**: `/settings/channels/google_chat` with an empty DM allowlist renders `.allowlist-empty` "No entries" on first load; adding then removing the only entry returns the identical row, with no visual difference between the server and client renders; "Allowlist (0 entries)" still shows the correct count

- [ ] **TI12** The shared status presentation states not-running truthfully, and Google Chat shows no dead pairing CTA
  - Consume TI08's record fields directly: render the optional state banner only when `stateBannerVariant` / `stateBannerText` are non-null, render the optional DM policy hint exactly as supplied, and derive the Disconnect action only from the record's `connected` field plus a non-null pairing href. Delete `statusLabel == 'Connected'`, `isConnected`, and any local `ChannelStatus` switch/condition from `channel_detail.dart`; banner, hint and action are presentation-record concerns, not template inference. The DM and group policy panels remain editable: do not add `aria-disabled` or reduced-opacity treatment. The `Pairing / Registration` anchor is wrapped in `tl:if="${pairingHref}"`, matching the guard already on the Disconnect form. No Start/Connect action is added.
  - **Verify**: `/settings/channels/google_chat` in `notRunning` renders no `Pairing / Registration` anchor, one `.banner.banner-warning` with the record's exact not-running copy and the apply-when-started hint, while DM/group policy panels remain editable; `configured` gets its distinct exact banner copy; `connectionError` gets error badge + dot but no not-running banner and no immediate hint; connected WhatsApp gets no state banner, does get the immediate hint and may render Disconnect; `disabled`, `pairingNeeded` and `reconnecting` get neither not-running copy nor the immediate hint. A source assertion rejects `statusLabel == 'Connected'`, `isConnected` and a second status switch in `channel_detail.dart`.

- [ ] **TI13** The attribution popover dismisses on pointer-out and on Escape
  - `dc_attribution_controller.js` gains a `mouseleave` handler with a short close delay (150ms) so the pointer can travel into the popover. Hold the timer id on the controller instance, cancel it on re-entry (`mouseenter` on either marker or popover), and clear it in both `hide()` and `disconnect()` so a marker-to-marker traversal cannot leave a stale `hide()` pending. The Escape binding moves off the `.citation-marker` button onto `document`, added when the popover opens and **removed in `hide()` and `disconnect()`** — the controller's `disconnect()` currently tears down only the document click listener, so the new listener must be added to the same teardown path or it outlives the HTMX swap. `source_attribution.html` binds the new action.
  - **Verify**: hovering a `[1]` citation marker on `/knowledge` and moving the pointer away closes the popover within 150ms; moving the pointer from marker into the popover keeps it open; traversing marker→marker→marker leaves exactly one popover open and no pending timer; opening by hover and pressing Escape closes it; opening by click and moving the pointer away leaves it open until a click elsewhere; after an HTMX swap of the results list, `getEventListeners(document)` shows no orphaned keydown or click listener from a removed controller

- [ ] **TI14** The topbar owns the only `<h1>` on each of this story's three surfaces
  - Per the plan's shared-surface ownership decision (1), delete the duplicate in-page `<h1>`s this story owns: `knowledge_hub.html:9` (`<h1 class="page-title">Knowledge Hub</h1>`) and `kg_timeline.html:9` (`<h1 class="page-title">KG Timeline</h1>`) go entirely, since the topbar already renders those titles. `channel_detail.html:14`'s `<h1 tl:text="${heroTitle}">` is **not** deleted — it is the hero identity element TI08 steps up a tier; it changes tag so it no longer claims `<h1>` rank while keeping its visual weight. Depends on S16's TI02 having promoted the topbar fragment to `<h1>` (see Constraints & Gotchas) — check that first, or these pages end up with no `<h1>`.
  - **Verify**: `rg -c '<h1' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/templates/kg_timeline.html packages/dartclaw_server/lib/src/templates/channel_detail.html` returns no matches (exit 1 — all three files drop to zero, and `rg -c` omits zero-count files entirely); `rg -n '<h1' packages/dartclaw_server/lib/src/templates/topbar.html` shows the promoted `pageTopbar` / `plainTopbar` titles; each of `/knowledge`, `/knowledge/timeline` and `/settings/channels/whatsapp` exposes **exactly one** `<h1>` in the rendered DOM, supplied by the topbar; the channel hero title still renders at its stepped-up tier and is announced as a heading in the accessibility tree

- [ ] **TI15** The story's deferrals are recorded and the surfaces are validated in both themes
  - Record in the Implementation Observations of the **canonical private FIS** — `../dartclaw-private/docs/specs/0.22.1/fis/s10-sweep-knowledge-and-channel-surfaces.md`, edited directly. A public-repo implementation run must **not** write these into the exported copy under `dev/bundle/`: that tree is transient and removed before merge, so the record would vanish and the metric would fail silently. S14 consolidates every story's Implementation Observations into `../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md`, and that block is the preferred write-back location — S14's sweep reads the whole canonical FIS (both blocks and task bodies) as a safety net, but a deferral stated solely as a "What We're NOT Doing" prose bullet relies on that net rather than the supported path, so every one of them is repeated here. Do not commit the private repo; the operator commits. Five entries, each with a reason: the knowledge layer counts computed from the filtered result set (`knowledge_hub_service.dart` — service change), snippet markdown-stripping and word-boundary snapping (`packages/dartclaw_storage` — service change), the KG timeline's missing time axis and absent canonical chronology component (canon change plus new capability), the absent Start/Connect action for a not-running channel (new capability), and the missing `a.chip` selected-state rule in canon (canon frozen for this story). S03's `status-badge-muted` plus independent idle-dot contract is an arrival gate consumed by TI08, not a sixth deferral. Then validate against the `visual` profile (`bash dev/testing/profiles/visual/run.sh`, port 3338) in both themes at 1440×900 and 768px, comparing against **this story's own story-start captures** of the surfaces it touches — per the plan's visual-baseline protocol, the audit's 92-shot set is the release-level baseline S14 re-proves, and cannot isolate S10's deltas because S01 re-toned and S02 re-scaled every surface first. A regression outside this story's scope is reported, not absorbed. This task also closes the story's structural gates.
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0; with `BASE=.agent_temp/0.22.1-s10-entry`, `for rel in dev/design-system/tokens.css dev/design-system/components.css dev/design-system/icons.css packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/icons.css packages/dartclaw_server/lib/src/templates/layout.html; do cmp -s "$BASE/$rel" "$rel" || exit 1; done` exits 0, and `rsync -ainc --delete --exclude='.dart_tool/' --exclude='.DS_Store' "$BASE/packages/dartclaw_storage/" packages/dartclaw_storage/` plus `rsync -ainc --delete "$BASE/packages/dartclaw_server/lib/src/knowledge/" packages/dartclaw_server/lib/src/knowledge/` print nothing; scoped to **this story's own files** — `rg -n 'var\(--text-sm\)|container-wide|content-inner--wide|page-inner--wide' packages/dartclaw_server/lib/src/templates/knowledge_hub.html packages/dartclaw_server/lib/src/templates/kg_timeline.html packages/dartclaw_server/lib/src/templates/channel_detail.html` returns no matches (exit 1), and `git diff --no-index -U0 "$BASE/packages/dartclaw_server/lib/src/static/app.css" packages/dartclaw_server/lib/src/static/app.css | rg '^\+[^+]' | rg -n 'var\(--text-sm\)|window\.(alert|confirm|prompt)'` returns no matches (exit 1); `git -C ../dartclaw-private status --porcelain docs/specs/0.22.1/fis/s10-sweep-knowledge-and-channel-surfaces.md` shows the file modified with all five deferrals present; no surface regresses against this story's own start captures in either theme at either viewport

### Testing Strategy

- Behavioural coverage includes TI04/TI05 wrapper-level `emptyStateTemplate` rendering for knowledge and KG; TI07's exact Dart manifest count, non-dev filesystem route, seven opaque wiki rejection fixtures and real embedded route; TI08/TI12's exhaustive seven-value `ChannelStatus` presentation record, null WhatsApp/Signal route fallbacks, settings/detail consumer parity and exact emitted-selector existence; TI11's view-model null-mapping; and TI02's failed-layer flag. Use repo-root paths under `packages/dartclaw_server/test/...` for every command.
- **Existing suites this story invalidates must be re-pointed, not weakened** — preserve the intent in `packages/dartclaw_server/test/web/web_routes_test.dart`, `packages/dartclaw_server/test/templates/embedded_loader_test.dart`, `packages/dartclaw_server/test/templates/render_test.dart`, `packages/dartclaw_server/test/templates/templates_test.dart` and `packages/dartclaw_server/test/web/pages/knowledge_hub_page_test.dart`.
- Run source-tree targeted checks first; regenerate embedded assets and pass generated parity; then run the real embedded wiki-route case against default `embeddedServerAssets`; finally require the full `dart test packages/dartclaw_server/test` suite.

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
- [ ] Dart counts exactly one `wiki_document` entry in `loader.dart#expectedTemplates`; the route passes under non-dev filesystem and real embedded initialization; all seven wiki rejection paths return one opaque response.
- [ ] One no-default typed `ChannelStatus` presentation record covers all seven values and is the sole source for settings/detail label, badge, dot, banner, policy hint and connected-only action fields; null WhatsApp/Signal routes consume `ChannelStatus.disabled.presentation`; S03's `status-badge-muted` is present and used; every field is table-tested for every value, including `connectionError` and `connected`, and every emitted badge/dot/banner suffix has an exact served-CSS selector.
- [ ] After source-tree targeted checks, run `dart run dev/tools/embed_assets.dart`, require `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` green, run the real embedded wiki-route regression through default `initEmbeddedTemplates()`, then run the full `dart test packages/dartclaw_server/test` suite. The story closes only with every stage green.


## Implementation Observations

_No observations recorded yet._
