# Surface sweep: shell and chat

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S12

## Feature Overview and Goal

**Intent**: The chrome on 100% of views and the product's flagship surface are still the audit's "flat and gray" — the rail's separators are browser-default 3-D bevels, the rail clips instead of scrolling, the chat thread floats 558px above its composer, and a bad URL ejects the user out of the application entirely.

**Expected Outcomes** (2-4 user- or business-observable success conditions, each `[OC<NN>]`-tagged; scenarios anchor to these via `[OC<NN>]`):

- [OC01] The persistent shell reads as one designed surface: nothing falls through to browser-default rendering, the rail scrolls when its content overflows, and no control paints on top of another.
- [OC02] The chat thread sits against its composer, its pre-stream state is the canon's composed "thinking" object, and scrolling up to re-read an earlier message survives a streaming turn.
- [OC03] Empty and error states on these surfaces carry the brand recipe, and a bad URL lands inside the app shell with navigation intact.
- [OC04] The mobile drawer is fully keyboard-operable — Escape dismisses it and focus cannot reach the page behind the scrim.


## Required Context

> Load-bearing upstream spans inlined verbatim from PRD, plan, ADRs, or guidelines.

### From `plan.json` – sharedDecisions: "Canon-first, and canon closes after P1"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25, post-remediation -->
> A story that changes a canon-owned rule edits `dev/design-system/` (tokens.css / components.css / icons.css / DESIGN.md / showcase.html) first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` […] ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes, because the check pins a sha256 on line 2 of each served copy and concurrent edits in the parallel P3 wave conflict on that line by construction. […] A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

**S12 holds no canon-RULE rights, and full DESIGN.md / showcase rights.** Its two former canon CSS edits are hoisted to S01 per `docs/specs/0.22.1/canon-hoist-manifest.md` — the `hr` element reset and `.messages` bottom-anchoring. This story consumes both and re-syncs nothing. The closure covers three files, not the directory: `check_design_system_sync.sh` diffs exactly `tokens.css`, `components.css` and `icons.css` against their served copies and never reads `DESIGN.md` or `showcase.html`, so this story's two documented contracts (TI13's drawer behaviour, TI14's page header) and TI14's showcase demonstration are ordinary in-scope work.

### From `plan.json` – sharedDecisions: "Shared-surface ownership in the sweep phase"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25, post-remediation -->
> (1) PAGE TITLE: the topbar owns the page title and is the only `<h1>` on a page; six templates currently carry an in-page `<h1>` (`settings`, `knowledge_hub`, `kg_timeline`, `channel_detail`, `projects`, `login`) and each duplicate is deleted by the story owning that surface — settings by S11, knowledge_hub + kg_timeline + channel_detail by S10, projects by S15; `login` renders no topbar and keeps its `<h1>`. S16 promotes the shared topbar fragment to `<h1>` […]. (2) OFF-SCALE FONT SIZES: S07 alone normalizes every hard-coded off-scale font-size (`.provider-badge`, `.channel-mode-badge`, `.workflow-artifact-badge` and siblings); sweep stories keep only their own semantic edits to those rules and must not re-declare the size.

### From `plan.json` – sharedDecisions: "Surface token roles — three distinct planes"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S01 fixes the structural rule every later story consumes: chrome (`.sidebar`, `.topbar`), page ground and `.card` occupy three mutually distinct planes in BOTH themes, and the body gradient never terminates on the card tone. […] Card hover is not independent: `.card:hover` paints over the same token as card rest, so it re-derives from whatever S01 lands on. No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.

### From `plan.json` – sharedDecisions: "Composite type-class vocabulary"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `plan.json` – sharedDecisions: "Wide-container assignment"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 ships `--container-wide` plus the `.content-inner--wide` / `.page-inner--wide` modifiers. Assignment is fixed here so P3 stories do not each re-litigate it: wide applies to tasks, task detail, health (dashboard + audit), memory, scheduling, workflows; the 900px measure stays for chat, session info, knowledge results and settings forms. The modifier is opt-in, never the default.

### From `plan.json` – sharedDecisions: "Visual-baseline protocol — story-start captures, not the audit set"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> […] Protocol: each story captures its own story-start screenshots of the surfaces it touches, in both themes at desktop and 768px, and validates against those. The audit's 92-shot set stays the release-level baseline that S14 re-proves once. A story that finds a regression outside its own scope reports it rather than absorbing it.

### From `prd.md` – FR6 (re-sync + adoption sweep)
<!-- source: docs/specs/0.22.1/prd.md#fr6-re-sync--adoption-sweep -->
<!-- extracted: e18cf85 -->
> **Description**: Re-sync canon into the served CSS with the drift check green, purge app-local duplicates obsoleted by FR4, then work the 118 adoption findings. Priority clusters: […] empty/loading/error state coverage (31 findings — em-dash placeholders where an absent-value treatment belongs, undesigned empty states, no skeleton/`.scan-bar` loading treatment).
>
> - [ ] Drift check green; `design-system.css` byte-identical to canon.
> - [ ] Every page has a designed empty state; no bare em-dash stands in for an absent value.

### From `prd.md` – FR7 (glitch sweep)
<!-- source: docs/specs/0.22.1/prd.md#fr7-glitch-sweep -->
<!-- extracted: e18cf85; FR7 gained the durable-backlog criterion after this extraction (uncommitted) -->
> **Description**: Close the 64 distinct defects catalogued in the audit. No design decisions required. […]
>
> - [ ] All 23 high-severity glitches closed.
> - [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
> - [ ] […elided: every deferral carried into a durable backlog, with its reason and no target milestone — the release-boundary hand-off S14 owns; this story's part is recording the deferral in its own Implementation Observations…]
> - [ ] UI smoke test (TC-01…TC-31) green.

### From `prd.md` – Binding constraint: canon-first
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.

### From `prd.md` – Binding constraint: zero-npm / server-first
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `prd.md` – Binding constraint: no backend work
<!-- source: docs/specs/0.22.1/prd.md#constraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `prd.md` – Binding constraint: out of scope
<!-- source: docs/specs/0.22.1/prd.md#out-of-scope -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `prd.md` – Binding constraint: FR5 native dialogs
<!-- source: docs/specs/0.22.1/prd.md#fr5-feedback-decision-table-rewrite--native-dialog-eradication -->
<!-- extracted: e18cf85 -->
> Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.

### From `prd.md` – Binding constraint: NFR Accessibility
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone

### From `prd.md` – Binding constraint: NFR Visual quality
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#b-glitches--visibly-broken-no-design-decision-needed-72` – the `shell/sidebar` (4), `shell/restart-banner` (1), `global (mobile shell)` (1), `chat-session` (1) and `chat, task-detail, kg-timeline` (1) blocks: pixel evidence and per-finding fixes this story closes.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – the `shell/sidebar` (4), `shell/topbar` (2), `chat` (2), `chat-session` (5), `404` (2) and `notfound` (1) blocks; read before deciding whether a finding is adoption or a deferred capability.
- `docs/specs/0.22.1/fis/s16-global-sweep-shell-behaviour-states-formatting.md#implementation-tasks` – the `pageHeader` fragment shape (S16 TI03), the `emptyState` fragment's `.empty-state-title` + optional action slot (S16 TI04) and `formatRelativeTime` (S16 TI08) this story consumes rather than re-invents. S16 TI08 keeps `formatRelativeTime` **past-only** (relative through 30 elapsed days, then an absolute server-local short date from day 31); it does not gain future/remaining handling — see TI10.
- `docs/specs/0.22.1/fis/s07-global-sweep-type-adoption-formatting.md#implementation-tasks` – the type and colour half of the global sweep, which runs before S16. Relevant here: TI03 owns `.provider-badge`'s `font-size`, which this story must not touch.
- `../dartclaw-public/dev/guidelines/TRELLIS-GUIDELINES.md` – fragment and escaping rules for every `templates/*.html` edit here.
- `docs/wireframes/deviations.md` – where the `empty-app.html` wireframe deviation this story creates gets recorded.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI05] Shell chrome renders nothing at browser defaults**
  - **Given** the `visual` testing profile at 1440×900 in dark theme, with the restart banner shown
  - **When** the sidebar and the banner render at rest
  - **Then** each `.sidebar-divider` paints as a 1px line at `--bg-surface0` (`rgb(49,50,68)` in dark) with no `rgb(238,238,238)` bevel highlight on the row below it, and both banner buttons render in the app's monospace face with the `.btn` border and radius rather than the UA's proportional-font control

- [ ] **S02 [OC01] [TI02,TI03,TI04] The rail scrolls when it overflows and its active row is legible**
  - **Given** the `visual` profile's seeded sidebar with "Composer Smoke E…" selected, at 1440×900
  - **When** the "ARCHIVED 13" disclosure is expanded, adding 13 rows to the rail
  - **Then** the Workspace/Channels/Running/Chats/Archived block scrolls within `.session-list` and every SYSTEM nav item stays reachable, and the active row's archive button no longer overpaints its provider badge — the badge reads "CLAUDE" in full or is absent, never "CLAU▣E"

- [ ] **S03 [OC02] [TI06] A short conversation sits against its composer**
  - **Given** the `visual` profile's `chat-session` surface at 1440×900 with a two-turn conversation whose last message previously ended at y≈222
  - **When** the thread renders
  - **Then** the last message sits directly above the `.input-area` top border with no unbroken ground band between them, and a conversation long enough to overflow still scrolls normally with its first message at the top

- [ ] **S04 [OC02] [TI07] Reading back during a streaming turn is not interrupted**
  - **Given** a chat session streaming a response, with the user scrolled up ~400px to re-read an earlier message
  - **When** further `delta`, `tool_use` and `tool_result` SSE frames arrive and the turn finalizes
  - **Then** the scroll position stays where the user left it for every frame, and a session already scrolled to the bottom still tracks new content; the existing `[data-load-earlier]` exemption in `dc_shell_controller.js` continues to suppress auto-scroll

- [ ] **S05 [OC02] [TI08] The pre-stream state is the canon's composed thinking object**
  - **Given** a chat session where a turn has been submitted but no `delta` frame has arrived
  - **When** the assistant message renders its waiting state
  - **Then** it emits `.msg-thinking` containing the `.claw-loader` and a visible `.msg-thinking-label`, the blinking `.streaming` block cursor is absent until the first delta, and under `prefers-reduced-motion: reduce` the label text remains readable with both animations suppressed

- [ ] **S06 [OC03] [TI09,TI12] Empty and error states carry the brand recipe**
  - **Given** a session with no messages, an install with no chats, and a request to a nonexistent path such as `/no-such-page`
  - **When** each renders
  - **Then** none shows a solid accent square in place of an icon, each uses the canonical `.empty-state` recipe with `/static/mascot-avatar-512-8bit.png` at `.pixel-art` 64px, the two that already carry an action keep it (empty-install `+ New Chat`, 404 `Back to Home`) while the in-session empty thread gains none, and the 404 renders inside the app shell with the sidebar nav and topbar present and its `404` heading no longer painted in `--fg-overlay`

- [ ] **S07 [OC04] [TI13] The mobile drawer is keyboard-operable**
  - **Given** a 768px-wide viewport with the off-canvas sidebar opened from `.menu-toggle`
  - **When** the user presses Escape, and separately when the user Tabs repeatedly from the drawer
  - **Then** Escape closes the drawer and returns focus to `.menu-toggle`, and while open, Tab never reaches `#main-content` or `.topbar` behind the scrim

- [ ] **S08 [OC02] [TI10,TI11] The chat surface's dense text reads as information, not decoration**
  - **Given** a chat session with a stalled turn showing the turn-status panel, and a composer carrying its three quick prompts
  - **When** both render at 1440×900
  - **Then** each turn-status time is preceded by its own caption label — "waiting since", "stuck since", "times out" — with empty slots omitted rather than rendered as blank grid cells, and the three quick prompts render as `.chip--ref` controls visibly distinct from the static `.composer-hints` text beside them


## Structural Criteria

- [ ] This story's diff touches none of the three closed canon files (`dev/design-system/tokens.css` / `components.css` / `icons.css`) and no served copy under `lib/src/static/` other than `app.css` — canon *rules* are closed after P1 and S12 holds none. `dev/tools/fitness/check_design_system_sync.sh` is green at the story boundary because nothing here moved it. `dev/design-system/DESIGN.md` and `showcase.html` are outside the closure and outside the drift check; TI13 and TI14 edit both, and doing so does not breach this criterion.
- [ ] No `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` is introduced by this story in `lib/src/static/controllers/`.
- [ ] No new `var(--text-sm)` reference is introduced, and no card, chrome or ground tone is re-declared locally.
- [ ] Neither chat, chat-session nor the error page acquires `.content-inner--wide` or `.page-inner--wide` — the 900px measure is retained per the plan's fixed assignment.
- [ ] The unreachable `.messages:empty::after` rule is gone from the served `design-system.css` (S01 removes it in canon), and no bespoke empty-state class is added to `app.css`.
- [ ] The dead `.session-title-static` block at `app.css:277-287` is gone, and no new dead app-side duplicate of a canon rule is introduced.
- [ ] This story adds no in-page `<h1>` to any surface and deletes none (the six duplicates are assigned to S10/S11/S15).
- [ ] Both contracts this story establishes are documented where the executor can find them: DESIGN.md § Mobile sidebar contract states the drawer's focus/Escape/`inert` behaviour (TI13) and DESIGN.md § Layout states the page-header contract with a `showcase.html` panel demonstrating it (TI14). Every class either contract names in backticks already has a rule in `components.css` or `icons.css`, so S14 TI01's forward class sweep stays clean.


## Scope & Boundaries

### Work Areas
- `dev/design-system/` CSS (`tokens.css`, `components.css`, `icons.css`) — **not a work area.** The `hr` reset, `.messages` anchoring and the `.messages:empty::after` removal are S01's per `canon-hoist-manifest.md`; this story consumes them and re-syncs nothing.
- `dev/design-system/DESIGN.md` + `showcase.html` — **in scope.** Neither is drift-checked or synced, so the closure does not reach them. TI13 writes the drawer's behaviour contract into § Mobile sidebar contract (`DESIGN.md:427-448`, markup-only today); TI14 writes the page-header contract into § Layout and adds the demonstrating panel beside the Full Layout demo (`showcase.html:1042-1084`).
- Sidebar — `templates/sidebar.html`, `templates/sidebar.dart`, `static/controllers/sidebar_sections.js`, and the `.session-item` / `.btn-new-session` / `.sidebar-archive-toggle` rules in `static/app.css`. `.provider-badge`'s own rule is S07's (font-size) and S08's (margin-left); this story changes only whether the badge is *rendered*.
- Shell chrome — `templates/topbar.html`, `templates/restart_banner.html`, and the dead `.session-title-static` block at `static/app.css:277-287`.
- Mobile shell — `static/controllers/dc_shell_controller.js` (`setSidebarOpen`, `handleDocumentKeydown`, `applyTimelineAutoScroll`) and `static/controllers/shared.js` (`scrollToBottom`).
- Chat surfaces — `templates/chat.html`, `templates/components.html` + `components.dart` (`emptyState`, `emptyAppState`), `templates/session_info.dart#sessionTurnStatusView`, `static/controllers/dc_chat_controller.js`.
- Error page — `templates/error_page.html` + `error_page.dart`, its call sites at `web/web_routes.dart:631,634` and `server.dart:743`, and the `.error-*` rules in `static/app.css`.

### What We're NOT Doing
- Composer model / guard indicators (`.composer-model`, a guard `.status-badge`) -- which agent, model and permission mode will answer is information the chat page renders nowhere today, and the picker the canon anatomy opens is a 0.24 chat feature. Recorded as a ledger deferral for S14.
- Per-message timestamps in the chat thread -- `ClassifiedMessage` (`templates/chat.dart:15`) has no time field, so this adds temporal information the surface does not carry, and sourcing it risks a data-layer dependency the release excludes. Ledger deferral.
- Re-classing the composer's slash-command palette onto canonical `.palette-section` / `.palette-item` -- deferred. This is the one place where `plan.json#stories[S12].scope` overrides this story's own adoption-vs-feature rule: by that rule the five palette classes (zero references today, audit `:1250-1253`) would read as adoption, but the plan's exclusion list names "command palette" verbatim and the plan is binding. Recorded as a ledger deferral for S14; the audit rates it low.
- The three `alert()` calls in `dc_shell_controller.js#confirmRestart` -- S06 owns native-dialog eradication and the single confirmation API; a second treatment here would be exactly the duplication this release exists to remove.
- Sidebar text tiering, the topbar page-title tier, and the `.msg-content` h1–h3 collapse -- all three are canon-owned and claimed upstream: S01 TI07 re-tiers `.sidebar-section-label` / `.session-item` / `.sidebar-nav-item`, S02 TI05 raises `.topbar .session-title-static`, S02 TI04 splits the collapsed `.msg-content h1, h2, h3` rule and adds h4–h6. This story verifies all three on its surfaces and re-tones nothing locally. (`.sidebar-archive-toggle` is *not* in S01's set — no story but this one touches it, so TI04 owns it.)
- Deleting the six duplicate in-page `<h1>`s -- assigned by the plan's shared-surface ownership decision: settings→S11, knowledge_hub + kg_timeline + channel_detail→S10, projects→S15, `login` exempt. S09 owns none. This story applies the contract to the topbar fragment only, and does not promote it to `<h1>` (S16 TI02's).
- Hoisting the restart banner out of its 14 per-page `${bannerHtml}` includes into the shell -- the banner is opted into at three different nesting depths across templates S08–S11 are editing in this same parallel wave, so the move would conflict on every one of them. The button-class defect is closed here; the inconsistent width and top offset it leaves is a ledger deferral, best taken with the embedded-asset regeneration in S14 or a follow-up.


## Architecture Decision

**Approach**: fix every defect at its lowest owning layer, and where that layer is a canon *rule*, **consume rather than author**. The two canon-owned rules this story depends on (`.messages` anchoring, the missing `hr` reset) are S01's per the hoist manifest; `app.css` carries the app-owned rules; templates and controllers carry markup and behaviour. This story re-syncs nothing and leaves the drift check untouched. The two behaviours it *defines* rather than consumes — the drawer's keyboard contract and the page-header contract — are documented in `DESIGN.md` and demonstrated in `showcase.html` in this story, because those two files are neither synced nor drift-checked and a contract recorded nowhere is one the next surface silently re-invents.
**Why this over alternatives**: an app-side override of `.messages` or a local `hr` rule would fail `check_design_system_sync.sh` outright *and* violate the canon closure; a local re-tone would break the plan's single-owner rule for surface tokens; and authoring the canon rule here would collide on the served files' sha256 line with the four other parallel W2 sweeps — the exact failure the closure exists to prevent. Deferring the two prose contracts to S14 instead was rejected: S14 reconciles documentation against what shipped, so it can only discover a contract the code already states, and neither the `inert` treatment nor the title-ownership rule is legible from the diff alone.


## Technical Overview


## Code Patterns & External References

```
# type | path#anchor or url                                                            | why needed (intent)
file   | dev/design-system/components.css#.messages                                    | canon chat-thread rule (:415) TI06 bottom-anchors; the dead `.messages:empty::after` sits at :422
file   | dev/design-system/components.css#.msg-thinking                                | canonical pre-stream object (:492) + `.msg-thinking-label` (:497) TI08 emits — already in canon, zero consumers
file   | dev/design-system/components.css#.session-list                                | canon scroll region (:177) TI02 wraps the rail's rows in; showcase.html:1046 is the reference shell
file   | dev/design-system/components.css#.empty-state                                 | canon container (:1504); `.empty-state .icon` (:1515) is the rule the bare `class="icon"` glyph collides with
file   | dev/design-system/showcase.html:904-909                                       | the empty-state recipe (64px .pixel-art mascot > bold line > body line > .btn-primary) TI09/TI12 adopt
file   | packages/dartclaw_server/lib/src/templates/login.html:10                      | the app's only correct mascot usage — served path is `/static/mascot-avatar-512-8bit.png` (canon names it `logo-avatar-512-8bit.png`)
file   | packages/dartclaw_server/lib/src/static/controllers/shared.js#scrollToBottom   | the unconditional scroll (:225) TI07 gates; called from three controllers
file   | packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js#setSidebarOpen | drawer open/close (:221) TI13 extends with focus move + inert
file   | packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js#handleDocumentKeydown | keydown handler (:121) TI13 adds the Escape branch to, beside the existing custom-select close
file   | packages/dartclaw_server/lib/src/static/controllers/sidebar_sections.js       | injects `<hr class="sidebar-divider …">` at :57 and :99 — TI01's fix must cover dynamically inserted dividers
file   | packages/dartclaw_server/lib/src/templates/components.dart#emptyStateTemplate  | chat's empty-thread fragment (:15); `emptyAppStateTemplate` (:26) is the empty-install twin
file   | packages/dartclaw_server/lib/src/templates/helpers.dart#formatRelativeTime     | S16 TI08's single relative-time helper TI10's turn-status labels route through
file   | packages/dartclaw_server/lib/src/templates/error_page.dart#errorPageTemplate   | bare-layout render (:5), no shell params — TI12 adds optional sidebar/topbar HTML; call sites web/web_routes.dart:631,634 and server.dart:743
file   | packages/dartclaw_server/lib/src/templates/sidebar.dart#buildSidebar           | the rail builder ({sidebarData, navItems, appName}) TI12's caller composes; in-scope uses at web_routes.dart:229,259
file   | packages/dartclaw_server/lib/src/server.dart:738-746                           | the Cascade 404 fallback that serves /no-such-page — TI12's real target; its enclosing scope holds the sidebar helper + _pageRegistry.navItems
file   | dev/design-system/components.css#.chip                                        | base rule (:1930) TI11's buttons need alongside `.chip--ref` (:1964, icon-only); hover/focus live on `button.chip` (:1946); `.chip-row` at :1992
tool   | dev/tools/fitness/check_design_system_sync.sh                                  | the byte-identity + sha256 gate; it diffs exactly three pairs (tokens/components/icons) and never reads DESIGN.md or showcase.html — this story only proves it unmoved
file   | dev/design-system/DESIGN.md:427-448                                           | § Mobile sidebar contract — markup-only today; TI13 adds the focus/Escape/`inert` half
file   | dev/design-system/DESIGN.md:394-401                                           | § Layout — calls `.topbar` "the page header" (:399) without naming a title owner; TI14 records the contract here
file   | dev/design-system/showcase.html:1042-1084                                     | the Full Layout demo TI14's page-header panel sits beside; its `.session-title` input (:1061) is the *session* topbar and stays an input
wire   | docs/wireframes/error-states.html:130-137                                      | 404 as a centred empty state with a `.btn-primary` route back
```


## Constraints & Gotchas

- **Critical**: canon *rules* are closed after P1 — S12 edits none of `dev/design-system/tokens.css`, `components.css`, `icons.css` and re-syncs nothing. `design-system.css` is a *generated copy* carrying a two-line sha256 provenance header; editing it directly fails `check_design_system_sync.sh`, and editing canon here would additionally collide with the four sibling W2 sweeps on that same header line. Both rules this story needs (`hr` reset, `.messages` anchoring) arrive from S01. If either is missing at story start, stop and report for hoisting — never work around it in `app.css`.
- **Constraint**: the closure covers three files, not the directory — read `check_design_system_sync.sh` before assuming otherwise. It runs `check` exactly three times (`tokens.css`, `components.css`, `icons.css`) and never opens `DESIGN.md` or `showcase.html`, so the sha256-collision rationale cannot reach them. TI13 and TI14 write both. Two constraints travel with that right: (a) any class named in backticks in new DESIGN.md prose must already have a rule in `components.css` or `icons.css`, or S14 TI01's forward sweep will report it as documentation without backing — every class the two contracts name (`.sidebar-close`, `.menu-toggle`, `.sidebar-scrim`, `.session-title-static`) is backed today; (b) sibling W2 stories may also touch these two files (S10 records canon-blocked gaps as contract notes, S11 may document a tab-overflow affordance), so keep edits inside the section being changed — the risk is mechanical merge, not semantics.
- **Constraint**: `app.css` loads *after* `design-system.css` (`layout.html:16-17`), so equal-specificity app rules win. Deleting an `app.css` declaration exposes the canon rule underneath — confirm what surfaces before assuming a deletion is inert.
- **Avoid**: fixing a colour complaint by re-tuning a token. Surface, chrome and card tones are S01's; the rail's text tiering is S01's; the topbar title tier and the `.msg-content` heading split are S02's. This story's sanctioned colour moves are applying `.t-*` classes and retiering an app-owned class off `--fg-overlay`.
- **Critical**: `shared.js#scrollToBottom` has **seven** call sites, not six: `dc_chat_controller.js:36,330,371` and `dc_shell_controller.js:47,139,150,158`; `applyTimelineAutoScroll` (`dc_shell_controller.js:427-430`) is bound document-wide at `:37`. The guard belongs inside both helpers so every caller inherits it — which means the fix also reaches task-detail and kg-timeline, surfaces S08 and S10 own. Those stories inherit it and must not re-implement it. The two `connect()` sites (`dc_chat_controller.js:36`, `dc_shell_controller.js:47`) must bypass the guard — see TI07.
- **Critical**: `sessionTurnStatusView` (`templates/session_info.dart:106-123`) feeds both `chat.html:45-49` and `session_info.html:43-47`. This story owns the view-model change; S09 (session-info) must not duplicate it. S09 runs in the same parallel wave.
- **Critical**: `.provider-badge` (`app.css:1775-1787`) is claimed by three stories and S12 owns **none of its declarations**. S07 TI03 owns the `font-size` (`0.625rem` → `--text-xs`, `:1782` named verbatim in it); S08 TI14 owns dropping the baked-in `margin-left`; S12 owns only whether the badge *renders at all*, which is a `sidebar.html` / `sidebar.dart` change, not a CSS one. Touching that rule here would duplicate S07's task and break the plan's off-scale-font-size ownership decision.
- **Constraint**: none of the three error-page call sites has shell data today — `web_routes.dart:631/:634` are top-level helpers outside the router closure that owns `sidebarData`, and `server.dart:743` is a `Cascade()` fallback closure. The shell-wrapped error page must degrade to the current bare layout at any site that cannot supply it, rather than throw from inside an error handler. `/no-such-page` is served by the `server.dart:743` cascade, so that is the site TI12's acceptance actually depends on.
- **Avoid**: adding to the chat surface. The 0.24 boundary reading this story applies: emitting a canon class that already exists with zero consumers is *adoption*; rendering information the surface does not render today is a *feature* and is deferred.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** No `<hr>` anywhere in the app renders at browser defaults — **consume only**
  - The `hr` element reset (`hr { border: 0; border-top: var(--border); }`) is **S01's**, hoisted per `canon-hoist-manifest.md`. It covers the four static dividers in `sidebar.html:21,52,71,86` *and* the two `sidebar_sections.js` injects at `:57,:99` without touching either file, so this story writes no CSS for it — it verifies the reset landed and reaches the rail. Neither `app.css` nor `design-system.css` declares any competing `hr` or `.sidebar-divider` rule today (grep confirms zero matches in both), so nothing here can shadow it.
  - If S01 has not landed the reset when this story starts, **stop and report** — do not add a local `.sidebar-divider` rule as a workaround.
  - **Verify**: `rg -n '^hr[ ,{]' packages/dartclaw_server/lib/src/static/design-system.css` resolves (exit 0) *before* this story's own work begins; a fresh desktop-dark `/tasks` capture sampled at x=130 across each divider y-band reads `rgb(49,50,68)` with no `rgb(238,238,238)` row beneath it, and desktop-light shows the light `--bg-surface0` value rather than the same `#EEEEEE`; the two dynamically injected dividers render identically to the four static ones

- [ ] **TI02** The sidebar rail scrolls instead of clipping when its content overflows
  - The Workspace/Channels/Running/Chats/Archived block in `sidebar.html:8-129` is wrapped in canon's `.session-list` scroll region (`dev/design-system/components.css#.session-list`, showcase.html:1046 is the reference shell), leaving `.sidebar-header` and the `.sidebar-section` nav outside it as fixed regions. `sidebar_sections.js`'s injection targets must still resolve inside the new wrapper. The wrapper closes before `<nav class="sidebar-section">` (`sidebar.html:131-146`) so the SYSTEM / Extensions nav stays a fixed bottom region outside the scroll area, and `.sidebar-header` (`:2-6`) stays a fixed top region.
  - **Verify**: at 1440×900 with "ARCHIVED 13" expanded, the rail scrolls within `.session-list` and every SYSTEM nav item is reachable by scrolling; the running-task and workflow sections still appear and disappear correctly as `sidebar_sections.js` injects and removes them

- [ ] **TI03** The active session row's provider badge is never overpainted
  - The badge-hiding selector at `static/app.css:238` keys on `:is(:hover, :focus-within, .active)`, matching the action-reveal trigger already set at `app.css:147-149`. This closes three duplicate audit findings that share one root cause.
  - **Verify**: a desktop capture of `chat-session` with "Composer Smoke E…" active shows the archive button with no badge glyph beneath it (no "CLAU▣E"), while inactive rows still render their badge; hovering an inactive row still hides that row's badge

- [ ] **TI04** The rail's app-owned text and controls sit on the canon vocabulary
  - In `static/app.css`: `.sidebar-archive-toggle` (:186) moves off `--fg-overlay` onto `--fg-sub0` — a colour retier, this story's own semantic edit. `.provider-badge`'s hardcoded `0.625rem` is **not** touched here: S07 TI03 alone normalizes every off-scale font-size (`app.css:1782` named verbatim in it, with a Verify asserting the CLAUDE badge renders at 12px), per the plan's shared-surface ownership decision. This story keeps only the badge's *visibility* semantics, below. In `sidebar.html` + `sidebar.dart`: the badge is suppressed when every visible session shares one provider (a single `providersAreUniform` context flag gating the existing `tl:if`), `.btn-new-session` left-aligns to the 16px rail baseline and drops `.btn-ghost`, and `.sidebar-header` gains the showcase lockup `<span class="claw-mark" aria-hidden="true"></span>` before `.logo`. Colour tiering of `.session-item` / `.sidebar-nav-item` / `.sidebar-section-label` is S01's and is not touched here.
  - **Verify**: this story's diff contains no `font-size` declaration inside the `.provider-badge` rule (`app.css:1775-1787`) — S07 TI03 owns that line; with the seeded profile (all sessions CLAUDE) zero `.provider-badge` elements render, and with a mixed-provider fixture they render (at whatever size S07 has landed); "New Chat" starts at the same 16px x-offset as every nav row; exactly one `.claw-mark` renders in the shell chrome (`tasks.html:106` and `projects.html:53` each render a second one inside their own empty state — those are S08's and S15's surfaces and are not changed here; the scarcity doctrine's "logo lockups, empty states, and at most one hero moment per view" permits the lockup plus an empty state)

- [ ] **TI05** The restart banner's buttons render as design-system buttons
  - **Both** buttons are broken, and this story owns both. Today `restart_banner.html:7` is `class="btn-sm btn-primary"` and `:8` is `class="btn-sm btn-ghost dismiss"` — neither carries the base `.btn`. They become `class="btn btn-sm btn-primary"` and `class="btn btn-sm btn-ghost dismiss"`. `.btn-sm` supplies only font-size and padding, so without `.btn` every structural property (inline-flex, gap, radius, border, `font: inherit`) is missing and the banner paints as a UA control in a proportional font. `dc-shell#confirmRestart` / `#dismissRestartBanner` bindings and the `#restart-banner` / `#restart-banner-fields` ids are unchanged.
  - **Sole owner, and the file is uncontested.** The pre-split global-sweep story once fixed line 7 only — leaving Dismiss as UA chrome while reading as closed — and that clause is gone: S16 TI10 now carves the banner out explicitly, and its Verify asserts `restart_banner.html` still carries both `class="btn-sm` lines when S16 finishes. S07 leaves the file untouched too (its Final Validation Checklist). No other story in the wave edits this file.
  - **This one edit closes two audit entries.** The defect is filed twice against the same `file:line` — `settings/restart-banner` (low, audit `:718-723`) and `shell/restart-banner` (med, audit `:732-737`) — per `plan.json#executionNotes` ("filed twice and must be fixed once … S12 owns it; S11 excludes it"). Record **both** ids as closed by this task (TI16), so S14's ledger retires the pair instead of showing one as unaddressed. Hoisting the banner out of its 14 per-page includes is deferred (see What We're NOT Doing).
  - **Verify**: `rg -n 'class="btn ' packages/dartclaw_server/lib/src/templates/restart_banner.html` returns exactly two lines, `:7` and `:8` (exit 1 with no matches today — dry-run confirmed, so this cannot pass vacuously), and `rg -n 'class="btn-sm' packages/dartclaw_server/lib/src/templates/restart_banner.html` returns no match, exit 1 (both lines today), proving neither button was left half-fixed; with the banner shown, **both** render in the app's monospace face with the `.btn` border and `var(--radius)` corners rather than UA defaults; Restart Now and Dismiss both still fire

- [ ] **TI06** A short chat thread sits against its composer — **consume only**
  - `.messages` bottom-anchoring is **S01's**, hoisted per `canon-hoist-manifest.md`, together with deleting the unreachable `.messages:empty::after` rule (`components.css:422-430`, dead because `.messages` always receives `emptyStateTemplate()`). This story writes no CSS for either and adds no `app.css` override.
  - Two constraints this story carries into S01's hoist, because they were established here and are not obvious from the audit finding alone: (a) the anchoring must use `display:flex; flex-direction:column;` plus `margin-top:auto` on the first child, **not** `justify-content: flex-end` — on a scrolling flex column the latter is the idiom that can make start-side overflow unreachable, which is exactly the second half of scenario S03; (b) the change reaches two further surfaces, below.
  - Downstream reach: the two app-scoped descendants of this rule — `.task-chat-embed .messages` (`app.css:1856`, S08's surface) and `.workflow-step-chat .messages` (`app.css:2613`, S15's) — declare neither `display` nor the first-child margin, so both inherit the anchoring. S08 TI07 touches `.task-chat-embed` for surface/`.card` only and S15 explicitly keeps the `.workflow-step-chat` rules; neither story validates this. Check both surfaces here and report (do not absorb) any regression.
  - **Verify**: on a two-turn session at 1440×900 the last message's bottom edge sits within one `--sp-4` of the `.input-area` top border (previously ~558px above it); a session long enough to overflow still scrolls with its first message reachable at the top; `rg -n 'messages:empty' packages/dartclaw_server/lib/src/static/design-system.css` returns no match (exit 1) — checked against the **served** copy, since that is what the browser reads; the task-detail embedded chat and the workflow step chat still render their threads without clipping the first message. If S01's anchoring has not landed, stop and report rather than overriding in `app.css`.

- [ ] **TI07** Auto-scroll respects where the user has scrolled
  - `shared.js#scrollToBottom` (:225-230) gains an `isAtBottom(el, threshold = 32)` check and no-ops when the user has scrolled away; `dc_shell_controller.js#applyTimelineAutoScroll` (:427-430) gains the same guard. The guard lives in the helpers so all seven call sites inherit it, and `dc_shell_controller.js:135-139`'s `[data-load-earlier]` exemption stays intact. Consumed by S08 (task-detail) and S10 (kg-timeline) — they do not re-implement it.
  - **The two connect-time sites must bypass the guard.** `scrollToBottom` is called on controller connect at `dc_chat_controller.js:36` and `dc_shell_controller.js:47`, when the freshly-rendered thread is at `scrollTop === 0`. An unconditional guard reads that as "the user scrolled away" and suppresses the initial anchoring, so any session whose history overflows would open at the *top*. Give the helper an explicit opt-out (`scrollToBottom(root, {force = false})`) and pass `force: true` from those two sites only; the five event-driven sites (`dc_chat_controller.js:330,371`, `dc_shell_controller.js:139,150,158`) keep the guard.
  - **Verify**: opening a session with more history than fits the viewport lands at the newest message, not the oldest (both from a cold load and from an HTMX navigation); scrolled up ~400px mid-stream, position holds across `delta`, `tool_use` and `tool_result` frames and across turn finalize; scrolled to the bottom, new content still tracks; loading earlier messages still does not jump to the bottom; the same holds for the task-detail and kg-timeline timelines on `htmx:afterSettle`

- [ ] **TI08** The pre-stream chat state is the canon's `.msg-thinking` object
  - `chat.html:110-113` emits `<div class="msg-thinking"><span class="claw-loader"><span></span><span></span><span></span></span><span class="msg-thinking-label">thinking</span></div>` as a sibling of `#streaming-content`, per `dev/design-system/components.css#.msg-thinking` (:492-507). The loader keeps exactly the three child `<span>`s it has today (`chat.html:112`) — canon paints its strokes through `.claw-loader span:nth-child(1..3)` (`components.css:1739-1741`), so a loader without them renders empty — and drops its now-redundant `aria-label`, since `.msg-thinking-label` is a visible text cue. The label's animated ellipsis comes from canon's `.msg-thinking-label::after` (`:502`); do not add one in markup. `dc_chat_controller.js:328` swaps it out and applies `.streaming` to `#streaming-content` only on the first delta, so the claw and the block cursor never coexist. Label text is the canon's static word — the indicator's *content* (tool names, reasoning) stays 0.24.
  - **Verify**: before the first delta, `.msg-thinking` and `.msg-thinking-label` are present and `#streaming-content` carries no `.streaming` class; after the first delta `.msg-thinking` is gone and `.streaming` is applied; under `prefers-reduced-motion: reduce` the word "thinking" is still legible with both animations suppressed

- [ ] **TI09** Chat's empty states use the canonical brand recipe
  - The `emptyState` and `emptyAppState` fragments in `templates/components.html:6-19` drop the bare `<div class="icon">&#10095;_</div>` — which collides with `.empty-state .icon`'s `background-color: currentColor` and paints a solid accent square — for the showcase recipe (`showcase.html:904-909`): `/static/mascot-avatar-512-8bit.png` at `class="pixel-art" width="64" height="64"`, the bold line and the body line. The recipe's primary action is filled only where one already exists: `emptyAppState` (`components.html:12-19`) keeps its shipped `+ New Chat` button, and `emptyState` (`:6-10`) — the in-session empty thread, which has no button today — gets none, because the composer directly beneath it *is* the action and inventing a new one is barred by the PRD's "New UX capabilities of any kind". Fill S16's reshaped fragment slots (S16 TI04 adds `.empty-state-title` plus an *optional* action slot); add no bespoke empty-state class. `empty-app.html`'s wireframe carries the same defect — record the supersession for `docs/wireframes/deviations.md`.
  - **Verify**: `rg -n 'class="icon"' packages/dartclaw_server/lib/src/templates/components.html` returns no match, exit 1 (two matches today, at `:7` and `:14`); a session with no messages and an install with no chats each render the 64px mascot with no solid accent square, and the empty-install state still offers its `+ New Chat`; no new `.empty-state-*` rule is added to `app.css`; the wireframe deviation is recorded in this FIS's Implementation Observations for orchestrator transfer

- [ ] **TI10** The turn-status panel says what its three times mean
  - `session_info.dart#sessionTurnStatusView` (:106-123) labels each slot inline at the caption tier — "waiting since", "stuck since", "times out" — formats the values instead of passing raw `toString()`, and omits empty slots rather than rendering blank grid cells. Both consumers (`chat.html:45-49`, `session_info.html:43-47`) inherit it; S09 does not duplicate this.
  - **Two directions, two formatters.** The incoming values are strings (`status['waiting_since']?.toString() ?? ''`, `:117-119`), so each is parsed with `DateTime.tryParse` and any slot that is empty or unparseable is omitted — the panel never renders a raw ISO string or an error. The two *past* slots (`waiting_since`, `stuck_since`) format through S16 TI08's `helpers.dart#formatRelativeTime`. The *future* slot (`global_timeout_at`) must **not**: that helper is past-only (`helpers.dart:29-35` takes `DateTime.now().difference(dateTime)` and every branch requires a positive duration, so any future instant falls through to `'just now'`), and S16 TI08 does not change that. Render "times out" as a remaining duration computed in the opposite direction (`dateTime.difference(DateTime.now())`, e.g. "in 4m"), falling back to omission once the timeout is in the past.
  - **Verify**: a `dart test` case feeding `sessionTurnStatusView` a status with all three times returns labelled values with no ISO string in the context; a case with `global_timeout_at` five minutes in the future returns a remaining-time string, **not** `'just now'`; a case with a null `stuck_since` returns two slots, not three; a case with an unparseable `waiting_since` omits that slot rather than emitting the raw text; on the rendered chat and session-info surfaces the panel shows "waiting since"/"stuck since"/"times out" beside each value in both themes

- [ ] **TI11** The composer toolbar distinguishes its actions from its hints
  - The three quick-prompt buttons in `chat.html:81-86` render as **`class="chip chip--ref"`** — the base class is load-bearing, exactly as in TI05: canon ships no standalone `.chip--ref` rule, only `.chip--ref > .icon { color: var(--accent-dim) }` (`components.css:1964`); the border, fill and type come from `.chip` (:1930) and the hover/focus states from `button.chip` (:1946-1951), so `.chip--ref` alone yields an unstyled button. They move **out of** `.composer-hints` (`chat.html:78-87`) into a sibling `.chip-row` (:1992) inside `.composer-toolbar`, so the static hint text they must be distinguishable from remains beside them rather than around them.
  - The literal `"/"` text glyph in the `btn-icon` at `chat.html:76-77` is **removed**, leaving the adjacent `<kbd>/</kbd> commands` hint to carry the affordance (the audit's own alternative). Do not substitute a new `data-icon` name: icons.css maps no `command` or `slash` glyph, an unmapped name paints a solid 1em square (`icons.css:195-211`), and adding a mask would be a third canon edit, which the Execution Contract forbids. If a glyph is judged necessary during execution, the only sanctioned name is the already-mapped `terminal` (`icons.css:134`, `:283`). `dc-chat#applySuggestion` bindings are unchanged. Removing the button removes the only binding of `dc-chat#openCommandPalette` (`dc_chat_controller.js:418`); the typed-`/` path runs through `maybeOpenCommandPalette` (`:423-428`) and is untouched, so the palette still opens. Leave the now-unreferenced `openCommandPalette` method in place and record it as an orphan for S14's ledger — the palette itself is 0.24's, and deleting a public Stimulus action here would pre-empt that story.
  - **Verify**: the three suggestions render with the `.chip` border and the `button.chip` hover fill, visibly distinct from the static `.composer-hints` text beside them, and none of them renders as a borderless run of text; only one `/` glyph appears in the toolbar; clicking a suggestion still fills the composer and typing `/` still opens the palette

- [ ] **TI12** A bad URL lands inside the app shell on the brand recipe
  - `error_page.html` is rebuilt on `.empty-state` with the 64px `.pixel-art` mascot above the code/title/detail lines and the existing `.btn-primary` route back. `.error-code` (`app.css:310-315`) leaves `--fg-overlay` and the off-scale `4rem` for the `.t-display` tier with `.text-gradient` — the sanctioned once-per-view brand moment. No `--container-wide` here.
  - **The shell wrap needs plumbing this task must add.** `errorPageTemplate` (`templates/error_page.dart:5`) is a top-level function taking `(int, String, String, {appName})` — it has no shell data and no access to any page object, and `dashboard_page.dart:60` is a constructor-injected `buildNavItems` *callback field*, not a callable free function, so it cannot supply the rail from here. Give `errorPageTemplate` optional pre-rendered `sidebarHtml` / `topbarHtml` parameters (composed by the caller from `buildSidebar(...)` and `pageTopbarTemplate(title: ...)`) and fall back to today's bare `layoutTemplate` body whenever either is null. All three call sites pass what they can:
    - `server.dart:743` — the `Cascade()` fallback that actually serves scenario S06's `/no-such-page`, and the one with the least in scope. Its enclosing `_buildHandler` scope does hold the sidebar-HTML helper and `_pageRegistry.navItems(activePage: '')`; build the rail from **nav items only**, with an empty session list, so the error path never reads the session store and cannot throw from inside an error handler.
    - `web/web_routes.dart:631` (`_htmlNotFound`) and `:634` (`_htmlError`) — top-level helpers outside the router closure that owns `sidebarData` / `systemNav` (used at `:229`, `:259`). Leave them on the bare fallback unless an existing caller already has shell data; do not thread new shell state through these helpers. The 500 path stays bare by default.
  - **Verify**: `/no-such-page` (served by the `server.dart:743` cascade, *not* by `web_routes.dart:631`) renders with a working sidebar rail and topbar; `rg -n -A5 '^\.error-code' packages/dartclaw_server/lib/src/static/app.css` shows neither `4rem` nor `var(--fg-overlay)` (both present today at `app.css:310-315`); the "404" reads brighter than the "Page Not Found" line beneath it in both themes; forcing the 500 path with shell data unavailable returns the bare page rather than throwing; no error path calls into the session store

- [ ] **TI13** The mobile drawer is keyboard-operable and contains focus
  - `dc_shell_controller.js#setSidebarOpen` (:221) focuses `.sidebar-close` and sets `inert` on `#main-content` and `.topbar` on open; on close it removes `inert` and returns focus to `.menu-toggle`. `handleDocumentKeydown` (:121) gains an Escape branch that closes an open drawer, beside the existing `closeAllCustomSelects()` handling so neither shadows the other.
  - **The contract is documented here, in DESIGN.md.** § Mobile sidebar contract (`DESIGN.md:427-448`) stops at a markup sample today and says nothing about behaviour, so the next surface that builds a drawer re-invents it. Extend that section with the behavioural half this task ships: on open, focus moves to `.sidebar-close` and `#main-content` + `.topbar` become `inert`; on close (Escape, scrim click, or `.sidebar-close`), `inert` is removed and focus returns to `.menu-toggle`; `aria-expanded` on `.menu-toggle` tracks the state. Prose plus the existing markup sample — add no CSS rule and name no class that `components.css` does not already define (`.sidebar-close`, `.menu-toggle`, `.sidebar-scrim` are all backed). This is permitted: `DESIGN.md` is neither synced nor drift-checked, so the canon closure does not reach it, and S14 reconciles the document at release close.
  - **Verify**: at 768px with the drawer open, Escape closes it and focus lands on `.menu-toggle`; Tab from the drawer never reaches `#main-content` or `.topbar`; Escape with the drawer closed still closes an open custom select; the scrim click and `.sidebar-close` paths still close and restore focus; `rg -n 'inert' dev/design-system/DESIGN.md` matches inside § Mobile sidebar contract (no match today, exit 1); `git diff --stat -- dev/design-system/DESIGN.md` shows the change confined to that section, and `bash dev/tools/fitness/check_design_system_sync.sh` still exits 0 — proving the edit is outside the drift check

- [ ] **TI14** The shell gives one answer to where the page title lives
  - `topbar.html`'s `pageTopbar` fragment (:32-42) conforms to the page-header contract, using its existing unused `backHref` slot (`:35`) where a page has a parent. Promoting the shared topbar fragment to `<h1>` is **S16 TI02's**, and the title's type tier is **S02's** (with S07 TI02 applying the `.t-page-title` class); this story neither promotes nor retiers.
  - Per the plan's shared-surface ownership decision, the six in-page `<h1>` duplicates are deleted by the story owning each surface — `settings.html:10` by **S11**; `knowledge_hub.html:9`, `kg_timeline.html:9` and `channel_detail.html:14` by **S10**; `projects.html:10` by **S15**; `login.html:11` is exempt (it renders no topbar). S09 owns none of them. This story deletes no `<h1>` and adds none.
  - The dead `.session-title-static` block in `app.css:277-287` (the rule plus its `/* === STATIC TOPBAR TITLE === */` comment) is deleted here. It is unreachable — canon's `.topbar .session-title-static` out-specifies it 0,2,0 to 0,1,0 — and S02 explicitly declines it and hands it to this story ("Deleting the dead `.session-title-static` block at `app.css:278-287` … Belongs to the shell sweep"). No other FIS in the bundle claims it. Delete only after S02's TI05 has landed the canon tier, so the removal is provably inert.
  - **The contract is written down here, in DESIGN.md + showcase.html.** § Layout describes `.topbar` as "the page header" (`DESIGN.md:399`) without saying who owns the title, which is how six templates grew their own `<h1>`. Record the rule beside that bullet: the topbar owns the page title and carries the page's only `<h1>`; a page body carries a subtitle or description head and never a second `<h1>`; the optional `backHref` slot renders where a page has a parent. Then demonstrate it in `showcase.html` as a short panel beside the Full Layout demo (`:1042-1084`) showing the `pageTopbar` shape — `.topbar` > `.menu-toggle` + `<h1 class="session-title-static">` + `.topbar-actions`. Do **not** convert the Full Layout demo's own `<input class="session-title">` (`:1061`): that demo is the *session* topbar, which S16 TI02 deliberately excludes from the `<h1>` promotion because its title is editable. Add no CSS; `.session-title-static` is already backed in `components.css`. Both files are outside the drift check, so this does not breach the canon closure.
  - **Verify**: the topbar renders the title on every swept surface; no in-page `<h1>` is added or deleted by this story; `rg -n 'session-title-static' packages/dartclaw_server/lib/src/static/app.css` returns no match, exit 1 (one match today, at `:278`), and the topbar title renders unchanged before and after the deletion in both themes; `rg -n 'session-title-static' dev/design-system/showcase.html` matches (no match today, exit 1) and the new panel renders the title as an `<h1>` while the Full Layout demo still renders its editable `session-title` input; `rg -n 'topbar owns the page title' dev/design-system/DESIGN.md` matches inside § Layout (no match today, exit 1 — dry-run confirmed); `bash dev/tools/fitness/check_design_system_sync.sh` still exits 0 after both edits

- [ ] **TI15** The swept surfaces hold in both themes and the story leaves canon CSS untouched
  - Story-start captures of sidebar, topbar, mobile shell, restart banner, 404, chat and chat-session — both themes, 1440×900 and 768px, `visual` profile on port 3338 — are the comparison baseline, per the plan's visual-baseline protocol; the audit's 92-shot set is S14's. A regression outside this story's scope is reported, not absorbed. Regenerating `embedded_assets.g.dart` is S14's and is deliberately not done here.
  - **Verify**: `git diff --name-only` for this story lists none of `dev/design-system/tokens.css`, `components.css`, `icons.css` (only `DESIGN.md` and `showcase.html` may appear under that directory, from TI13/TI14) and nothing under `lib/src/static/` except `app.css`; `dev/tools/fitness/check_design_system_sync.sh` exits 0 (unchanged by this story); no swept surface regresses against its story-start capture in either theme at either viewport (regression = clipping, overflow, overlap, truncation, contrast loss or layout break); the `.msg-thinking` label and the 12px `.provider-badge` each measure ≥ 4.5:1 against their background in both themes, and the retiered `.error-code` — display-size, so WCAG's 3:1 large-text threshold applies, and a `.text-gradient` fill has no single ratio — is sampled at both gradient stops and clears 3:1 at each; the story's diff introduces no `alert(` / `confirm(` / `prompt(` under `lib/src/static/controllers/`, no new `var(--text-sm)` reference, no re-declared card/chrome/ground tone, and no `.content-inner--wide` or `.page-inner--wide` on chat, chat-session or the error page

- [ ] **TI16** Every deferral this story makes reaches the release ledger
  - `plan.json#executionNotes` ("DEFERRAL RECORDS NEED A DURABLE HOME") rules that S14 assembles the glitch ledger from the `## Implementation Observations` block **and reads nothing else** — a deferral stated only as a *What We're NOT Doing* prose bullet never reaches it, and success metric 5 fails silently. This story defers in prose in five places, so at story close each is repeated as an Implementation Observations entry with a one-line reason: (1) composer model / guard indicators — 0.24 chat feature, information the surface renders nowhere today; (2) per-message timestamps — `ClassifiedMessage` (`templates/chat.dart:15`) carries no time field and sourcing it needs a data-layer change the release excludes; (3) the slash-command palette re-class onto `.palette-section` / `.palette-item` — `plan.json#stories[S12].scope` names "command palette" in the 0.24 exclusion list and overrides this story's own adoption heuristic; (4) the restart banner's inconsistent width and top offset, left by declining to hoist it out of its 14 per-page `${bannerHtml}` includes — the move would conflict with every template S08–S11 edit in this same wave; (5) TI11's now-unreferenced `dc-chat#openCommandPalette` method, recorded as an orphan rather than deleted because 0.24 owns the palette. Also record TI09's `empty-app.html` wireframe supersession for transfer to `docs/wireframes/deviations.md`, and TI05's **two** closed audit ids (`settings/restart-banner`, `shell/restart-banner`) so the ledger retires the pair.
  - **Written to the canonical private FIS** — `../dartclaw-private/docs/specs/0.22.1/fis/s12-surface-sweep-shell-and-chat.md`, edited directly. A public-repo implementation run must **not** write these only into the exported copy under `dev/bundle/`: that tree is transient and deleted before merge, so the record would vanish. Do not commit the private repo; the operator commits.
  - Handoffs are **not** deferrals and are not recorded here — the three `alert()` calls (S06), the sidebar/topbar/`.msg-content` type tiers (S01, S02), the `.provider-badge` font-size (S07) and the six in-page `<h1>` deletions (S10, S11, S15) each have a named owner in this release and are closed by that story, not carried.
  - **Verify**: the `## Implementation Observations` block of the canonical private FIS contains one entry per item above — five deferrals each with a reason, the wireframe deviation, and the two restart-banner audit ids marked closed; every deferral named in *What We're NOT Doing* also appears under *Implementation Observations* (walk the two lists item by item — a bullet present only in the prose section is invisible to S14); no entry describes work this FIS assigns to another story

### Testing Strategy

- `[TI07]` is the only pure-logic unit in this story and carries real boundary risk — cover `isAtBottom` at the threshold boundary (exactly 32px from the bottom, 33px, and a container shorter than its viewport where `scrollHeight === clientHeight`) rather than proving it only by eye.
- `[TI04,TI10]` change Dart view-model output — assert the `providersAreUniform` gate and the turn-status label/omission shape with `dart test` cases in `packages/dartclaw_server/test/`, not visually.

### Validation

- `[TI13]` needs keyboard-only validation, not screenshots: drive Tab and Escape through the 768px drawer and confirm the focus ring's location at each step.

### Execution Contract

- This story makes **zero** canon CSS edits. TI01's `hr` reset and TI06's `.messages` anchoring must already be live in the served `design-system.css` (S01's, per `canon-hoist-manifest.md`) before those tasks can be validated; if either is absent, stop and report rather than working around it in `app.css`.
- The two DESIGN.md contracts and the `showcase.html` panel (TI13, TI14) are **this story's**, not deferrals — `DESIGN.md` and `showcase.html` are neither synced nor drift-checked, so the closure does not reach them. They ship with the behaviour that makes them true; S14 reconciles the document at release close.
- TI07's guard must land in `shared.js` / `dc_shell_controller.js` before S08 or S10 touch their timelines; if those stories have already landed a local guard, reconcile onto the shared helper rather than adding a second.
- TI16 runs last and writes to the **canonical private FIS**, not the `dev/bundle/` export. Nothing in the private repo is auto-committed — the operator commits.


## Final Validation Checklist

- [ ] No finding this story deferred (composer model/guard indicators, per-message timestamps, the slash-palette re-class, the restart-banner hoist, the orphaned `openCommandPalette`) was partially implemented — each is either fully absent or fully done, so S14's glitch ledger records an unambiguous state.
- [ ] All five are recorded in the canonical private FIS's `## Implementation Observations` per TI16, not only in the *What We're NOT Doing* prose — that block is the sole input to S14's ledger.
- [ ] The two contracts TI13 and TI14 establish are in `DESIGN.md`, TI14's panel is in `showcase.html`, and neither edit moved `check_design_system_sync.sh` off green.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see [`data-contract.md`](${CLAUDE_PLUGIN_ROOT}/references/data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](${CLAUDE_PLUGIN_ROOT}/references/automation-mode.md). Spec authors: leave this section empty._

_No observations recorded yet._
