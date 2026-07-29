# FIS: Global sweep — shell behaviour, states and formatting

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
**Story-ID**: S16

> **Split note**: S07 and S16 were one story until it reached 18 tasks. S07 keeps the type, colour and CSS-token work and runs immediately before this story; S16 takes the shared Trellis fragments, shell behaviour, states and data formatting. The two halves share `app.css`, `topbar.html` and `components.html` — see the Execution Contract.

**All shell commands in this file run from the `dartclaw-public` repo root.** A path rooted anywhere else makes `rg` exit 2 and read as a pass.

## Feature Overview and Goal

**Intent**: Six per-surface sweeps execute one at a time after this story, and each one needs a page header, an empty state, a timestamp, an absent value and a failure treatment. If those shapes do not exist first, six stories invent six of each — which is exactly how the audit came to hold six page-header treatments, eight empty-state classes and four timestamp formats. This story builds each shape once, in the shared layer, so the later sweeps adopt rather than re-invent.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor to these):

- [OC01] The shell holds together: a long page scrolls inside it instead of overflowing it, the topbar carries the page `<h1>`, shell pages whose body provides `#main-content` expose a working skip link while login/bare-error pages expose no dead target, and the shared anchor-based controls meet the 48px touch target at 768px.
- [OC02] Shared page scaffolding is one implementation: one `pageHeader` fragment, one `.empty-state` implementation and one shared `metricCard` value binding to S02's `.t-metric`, all rendered from the shared layer so the six surface sweeps adopt rather than re-invent.
- [OC03] Failures and progress are legible: a failed request, a dropped live stream and an in-flight navigation are visible to the operator; navigation mutations carry one queued success toast, while in-place mutations announce success immediately without leaving a stale queued toast.
- [OC04] Data is legible: one timestamp format and one absent-value treatment govern the whole product, and a legitimate `0` still renders as `0`.


## Required Context

### From `plan.json` – sharedDecisions: "Canon-first, and canon closes after P1"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> Only P1 stories S01-S04 author rule families in drift-checked `tokens.css`, `components.css` and `icons.css`. S07's one later exception is deletion-only and token-only for retiring `--text-sm`; it does not reopen a rule family. This story has no exception: a missing canon rule stops and reports for hoisting to S01-S04. `DESIGN.md` and `showcase.html` remain non-drift-checked.

### From `plan.json` – sharedDecisions: "Shared-surface ownership in the sweep phase"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> (1) PAGE TITLE: the topbar owns the page title and is the only `<h1>` on a page; six templates currently carry an in-page `<h1>` (`settings`, `knowledge_hub`, `kg_timeline`, `channel_detail`, `projects`, `login`) and each duplicate is deleted by the story owning that surface — settings by S11, knowledge_hub + kg_timeline + channel_detail by S10, projects by S15; `login` renders no topbar and keeps its `<h1>`. S07 promotes the shared topbar fragment to `<h1>` and asserts only that the fragment emits one and that no NEW duplicate is introduced — it cannot assert one-per-page, because it is barred from editing per-surface templates. Pages carry a subtitle or description head, never a second `<h1>`.

*(The split assigns that topbar promotion to S16, which owns TI02 below. The contract is unchanged: assert the fragment emits one `<h1>` and that no NEW duplicate appears — never one-per-page.)*

### From `plan.json` – sharedDecisions: "Composite type-class vocabulary"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `plan.json` – executionNotes: deferral records need a durable home
<!-- source: docs/specs/0.22.1/plan.json#executionNotes -->
<!-- extracted: e18cf85 -->
> Every deferral is written back to the CANONICAL private FIS at `dartclaw-private/docs/specs/0.22.1/fis/`, not only to the bundle copy, and S14 consolidates them into `dartclaw-private/docs/specs/0.22.1/glitch-ledger.md`. Stories that record deferrals in prose (a `What We're NOT Doing` bullet) must also land them in Implementation Observations – the preferred write-back location. S14's ledger sweep reads the whole canonical FIS (Implementation Observations, `What We're NOT Doing`, and task bodies) as a safety net precisely because that write-back cannot be enforced, but the sweep tolerating a prose-only deferral does not make prose a supported home: land every deferral in Implementation Observations.

### From `prd.md` – FR6 (re-sync + adoption sweep)
<!-- source: docs/specs/0.22.1/prd.md#fr6-re-sync--adoption-sweep -->
<!-- extracted: e18cf85 -->
> **Description**: […] then work the 118 adoption findings. Priority clusters: […] empty/loading/error state coverage (31 findings — em-dash placeholders where an absent-value treatment belongs, undesigned empty states, no skeleton/`.scan-bar` loading treatment).
>
> **Acceptance Criteria**:
> - [ ] Every page has a designed empty state; no bare em-dash stands in for an absent value.

### From `prd.md` – FR7 (glitch sweep)
<!-- source: docs/specs/0.22.1/prd.md#fr7-glitch-sweep -->
<!-- extracted: e18cf85; FR7 gained the durable-backlog criterion after this extraction (uncommitted) -->
> **Description**: Close the 64 distinct defects catalogued in the audit. No design decisions required. Includes a global data-formatting pass — timestamps currently appear in three unrelated formats, never roll over past days, and one page prints raw ISO-8601 with milliseconds.
>
> **Acceptance Criteria**:
> - [ ] All 23 high-severity glitches closed.
> - [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
> - [ ] […elided: every deferral carried into a durable backlog, with its reason and no target milestone — the release-boundary hand-off S14 owns; this story's part is recording the deferral in its own Implementation Observations…]
> - [ ] UI smoke test (TC-01…TC-31) green.

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

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – the `global` block's state-coverage and shared-fragment findings, plus the four multi-surface `global (…)` entries. Read each *Evidence* paragraph for the exact file:line inventory a task must absorb; read *Fix* for the shape the auditor validated.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#b-glitches--visibly-broken-no-design-decision-needed-72` – the `global` (5) block: shell overflow, missing htmx error handler, timestamp formats, broken button classes, unvendored typeface (the last is S13's).
- `docs/specs/0.22.1/canon-hoist-manifest.md` – the authority for which canon rule belongs to which P1 story. It assigns this story's two canon needs — the `.shell` / `.content-area` row sizing (TI01) and `.skip-link` (TI02) — to S01 as chrome; confirm both are present in the served copy before starting either task.
- `docs/specs/0.22.1/fis/s07-global-sweep-type-adoption-formatting.md` – the type half, which runs immediately before this story on the same `app.css`, `topbar.html` and `components.html`. Its Implementation Observations carry the dispositions and hoist requests this story must not re-open.
- `docs/specs/0.22.1/fis/s12-surface-sweep-shell-and-chat.md#implementation-tasks` – the downstream consumer of TI02's title/conditional-skip contract and TI04's optional mascot variant. S12 owns only its session-info back-navigation, showcase proof and chat call-site opt-in; it does not reopen these shared contracts.
- `docs/specs/0.22.1/fis/s03-canon-form-control-tab-state-primitives.md` – the canonical `.empty-state-title`, `.value-absent`, `.list-toolbar` and `.pager` shapes TI04 and TI09 adopt.
- `docs/wireframes/ux-spec-empty-states.md#design-principles` – centred layout for page-level empties, placeholder rows for list/table empties, muted body text, `btn-primary` for the primary action.
- `docs/wireframes/ux-spec-real-time.md` – the live/disconnected/reconnecting states TI05's `data-connection` attribute drives.
- `../dartclaw-public/dev/guidelines/HTMX-GUIDELINES.md#recommended-patterns` – Stimulus owns browser behavior in DOM islands; explicit navigation over `hx-boost`; error handling belongs in a controller, not inline attributes.
- `../dartclaw-public/packages/dartclaw_server/lib/src/static/controllers/CONVENTIONS.md#lifecycle-and-htmx` – controller registration, `connect()`/`disconnect()` listener hygiene, and the htmx swap lifecycle the global listeners must survive.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md` – read before adding the `helpers_test.dart` cases; the suite already exists with `formatUptime` and `formatBytes` groups.
- `../dartclaw-public/dev/testing/UI-SMOKE-TEST.md` – TC-01…TC-31; the navigation and toast cases exercise TI05–TI07, and the touch-target cases exercise TI10.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI02,TI10] The shell holds together at both viewports and by keyboard**
  - **Given** `/memory` in the `visual` profile, whose content is taller than the 900px viewport (the audit captured it at 1440×1333 with unpainted canvas below y=900)
  - **When** the page is loaded, the operator presses Tab once, and the window is then narrowed to 768px
  - **Then** the sidebar, topbar and ground gradient paint the full viewport height and the page content scrolls inside the shell
  - **And** on the shell page the first Tab stop is a visible "Skip to content" link that moves focus to `#main-content`, while login and the bare error fallback render no skip link because neither body supplies that target; the shared topbar fragment renders its page title as an `<h1>` – the six per-surface templates that carry their own in-page `<h1>` are untouched here and no seventh appears
  - **And** at 768px the anchor-based tab and pager controls measure ≥ 48px tall, while a narrow inline chip is no longer stretched to a 48px minimum width

- [ ] **S02 [OC02] [TI03,TI04] One page header and one empty state exist for the six sweeps to adopt**
  - **Given** the six competing page-header treatments and eight bespoke empty-state classes the audit catalogued, and the shared fragments in `templates/components.html`
  - **When** the `pageHeader` fragment is rendered on its own and the default, optional-action and mascot `emptyState` variants are rendered through the Dart `emptyStateTemplate` wrapper
  - **Then** `pageHeader` emits `<header class="pagehead">` with a `.t-page-title` heading, an optional subtitle and a right-aligned action slot, and its action labels read verb+noun with `data-icon="plus"` rather than a literal `"+ "`
  - **And** `emptyState` renders the default hidden decorative icon + `.empty-state-title` + body copy + optional action with the canon accent-glow treatment applying, supports only the minimal optional decorative mascot variant S12 consumes, and leaves no bespoke empty-state class in `app.css`
  - **And** the shared `metricCard` fragment emits its value with `.t-metric`, so health, memory, task detail, session and workflow KPI consumers inherit one 32px metric binding without per-surface reimplementation

- [ ] **S03 [OC03] [TI05] A failed request and a dropped live stream announce themselves**
  - **Given** the sidebar's `hx-get` link to a session that has since been deleted, and an `/api/events` stream that the server closes
  - **When** the operator clicks the stale link, and separately when the stream drops
  - **Then** the 404 surfaces an error toast carrying the server's message instead of the click producing no visible change at all, and one failed archive request produces exactly one toast – the global listener is the sole owner and no archive-local HTMX error listener duplicates it
  - **And** the shell marks itself `data-connection="lost"`, shows a `.banner.banner-warning` naming the disconnection, and stops the `.status-dot--live` pulse and `.scan-bar` sweeps until the next successful `open` clears it – without bypassing the `prefers-reduced-motion` handling already in canon

- [ ] **S04 [OC03] [TI06,TI07] Success is announced and in-flight work is visible**
  - **Given** a navigation mutation handled by `deleteSession`, whose page change would otherwise destroy its toast, and the 28 `hx-get` sites that today carry zero `hx-indicator`
  - **When** the session is removed, and separately when a sidebar navigation is in flight
  - **Then** a success toast is queued before the navigation and shown after the new page connects, so the mutation reports success rather than only changing the page underneath, and a second navigation shows no repeat toast; project mutations are S15's in-place swaps and announce immediately without leaving a queued navigation toast
  - **And** the in-flight navigation shows a `.scan-bar` under the topbar, and a polling fragment shows `.skeleton` placeholders instead of popping in

- [ ] **S05 [OC04] [TI08,TI09] One timestamp format and one absent value — and a real zero stays a zero**
  - **Given** seeded data containing a task created 129 days ago, a session whose `createdAt` renders today as `2026-04-15T10:00:00.000`, a workflow definition with **0** steps, and a task whose `startedAt` is null
  - **When** `/tasks`, `/session-info`, `/workflows` and `/memory` render
  - **Then** the 129-day value renders as an absolute short date, every timestamp carries a `title` attribute with its ISO value, and no surface prints raw ISO-8601 with milliseconds
  - **And** the null `startedAt` renders the canon `.value-absent` treatment while the workflow's step count renders `0` — the helper converts null and empty to the absent treatment and never converts a legitimate `0` or a non-empty string
  - **And** `--`, `N/A`, `unknown` and the bare em dash no longer appear as absent-value renderings in the shared formatting layer


## Structural Criteria

- [ ] `dev/tools/fitness/check_design_system_sync.sh` exits 0 at the story boundary. With `BASE=.agent_temp/0.22.1-s16-entry`, the three drift-checked canon files and their served copies are byte-unchanged; `DESIGN.md` is the only `dev/design-system/` file this story writes, and that one is prose, never synced. A red check means S07's re-sync did not land, not that this story drifted.
- [ ] No canon rule is authored or edited in `tokens.css`, `components.css` or `icons.css`. The two canon rules this story needs (`.shell` / `.content-area` row sizing, and a `.skip-link`) are hoist requests against S01, not edits made here.
- [ ] No new runtime JS dependency and no build step: the new shell behaviours are plain ES-module code in the existing `controllers/` files, registered per `CONVENTIONS.md`.
- [ ] Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` are **introduced** in `lib/src/static/controllers/`. S06 W1 has already removed its owned calls before S16 W3 begins; this story proves its own `dc_shell_controller.js` delta against the W3 entry snapshot.
- [ ] Targeted checks run first: `helpers_test.dart`, `render_test.dart` and `app_js_test.dart` pass for formatting, wrapper-level conditional skip-link/empty-state rendering, and the single-owner HTMX listener contract.
- [ ] After targeted checks and the final template/static change, run `dart run dev/tools/embed_assets.dart`; require `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` green; run the mandatory `dart format --line-length=120 --output=none --set-exit-if-changed .` gate; run workspace-wide `dart analyze --fatal-infos`; then run the full `dart test packages/dartclaw_server` suite. No generated, format, analyze or package-test gate is allowed red.


## Scope & Boundaries

### Outputs the W4–W9 sweeps consume

These are contracts, not internals — S08, S09, S10, S11, S12 and S15 all depend on them, so a defect here propagates six ways. Each is named by the task that ships it:

| Output | Shipped by | Consumed for |
|---|---|---|
| `pageHeader` fragment (`components.html` + `components.dart`) | TI03 | Every non-chat surface replaces its own header treatment with this |
| Shared `metricCard` value emits `.t-metric` | TI03 | Health, memory, task detail, session and workflow KPI cards inherit one metric tier |
| Single `.empty-state` implementation + `emptyState` fragment with title/action slots and one optional decorative-mascot variant | TI04 | Every surface's empty state; S12 alone opts chat into the mascot |
| `helpers.dart#formatRelativeTime` with weeks/months/years rollover and `title="<ISO>"` disclosure | TI08 | Every timestamp on every surface |
| The absent-value helper in `helpers.dart` rendering canon `.value-absent` | TI09 | Every null/empty field rendering |
| `shared.js#queueToast` | TI06 | Navigation mutations whose document change would otherwise destroy their toast |
| Body-level `htmx:responseError` / `htmx:sendError` handlers in `dc_shell_controller.js` | TI05 | All HTMX sites; archive's overlapping local listener is removed |
| The shell's `data-connection` state and its animation gating | TI05 | Any surface rendering `.status-dot--live` or `.scan-bar` |

### Work Areas
- `packages/dartclaw_server/lib/src/static/app.css` — `.page-content` (:598) row sizing, the eight bespoke empty-state classes and the app-local `.empty-state-icon/-title/-text` family (:1808-1810), and the 768px touch-target block (:3755-3795). The `.skip-link` rule is canon-owned by S01.
- Shared Trellis/Dart fragments – `templates/components.html` + `components.dart` (`metricCard` `.t-metric` adoption, `emptyState`, new `pageHeader`), `templates/topbar.html` (the `<h1>` promotion), and `templates/layout.html` + `layout.dart`, `login.dart`, `error_page.dart` (the conditional skip-link contract).
- Shared controller layer — `static/controllers/dc_shell_controller.js` and `controllers/shared.js`: global htmx failure handling, SSE disconnection state, toast handoff across navigation, loading indicators. S15 owns `controllers/dc_projects_controller.js`'s immediate success toasts after in-place project swaps.
- Shared formatting layer — `templates/helpers.dart` (`formatRelativeTime`, new absent-value helper) and the call sites in `templates/*.dart` and `web/pages/*.dart` that today render their own timestamp or absent value.
- Tests – `packages/dartclaw_server/test/templates/helpers_test.dart` for formatting, `test/templates/render_test.dart` for conditional skip-link and empty-state variants rendered through `components.dart#emptyStateTemplate`, and `test/static/app_js_test.dart` for controller-source contracts. Browser interaction still proves keyboard order and the one-toast archive outcome.
- `dev/design-system/DESIGN.md` — the shell-scrolling, page-title and skip-link contracts this story establishes. Not drift-checked, so writing it here is legal; S14 reconciles the whole document at release close.

### What We're NOT Doing
- Defining or changing type tiers, colour and `--z-*` work -- S02 defines the seven `.t-*` classes and their bindings; S07 owns the app-wide migration immediately before this story. This story only applies the existing `.t-metric` class once in its shared `metricCard` fragment. Do not re-migrate a `--text-sm` site, retier an `--fg-overlay` rule, rebase a badge or touch a `z-index`.
- Adding or editing any rule in canon `tokens.css` / `components.css` / `icons.css`. Two rules this story needs are canon chrome and are **hoist requests against S01** (see TI01 and TI02); if S01 has not shipped them, the task stops and reports rather than adding them.
- Per-surface adoption of the `pageHeader` and `emptyState` fragments -- S08–S12 and S15 own each surface's own template edits in serialized waves W4–W9. This story proves a fragment in its own render.
- Deleting the six in-page `<h1>`s that duplicate the promoted topbar title -- each belongs to its surface story (S10, S11, S15), and `login` keeps its own because it renders no topbar.
- `settings.html:52`'s `<option value="">—</option>` -- an em dash in a disabled select's only option. It is an absent-value rendering, but `settings.html` is S11's template and this story's carve-out covers only the `.dart` call sites named in TI08 and TI09. Recorded for S11.
- The restart banner's two buttons missing the base `.btn` class (`restart_banner.html:7,8`) -- the plan assigns the defect whole to S12, and fixing only "Restart Now" here would leave "Dismiss" as UA chrome behind a Verify that reads as closed.
- Self-hosting JetBrains Mono (the fifth `global` glitch) -- FR8 / S13 owns all three CDN assets together, and splitting the font from htmx and marked would leave `layout.html` half-migrated.
- Pagination and page-size caps on the unbounded page handlers -- bounding a list is a new UX capability and needs handler changes; recorded as a deferral against the release glitch ledger.
- Hand-editing `embedded_assets.g.dart` -- this story regenerates it only through `dart run dev/tools/embed_assets.dart` after its final embed-root change, then closes generated parity green.


## Architecture Decision

**Approach**: build every shared shape the six later surface sweeps consume — the page header, the empty state, the timestamp and absent-value helpers, the failure and loading treatments, and the shell's structural and keyboard fixes — in W3 between S07 W2 and the serialized W4–W9 surface sequence.
**Why this over alternatives**: the alternative is each sweep inventing its own, which is precisely what produced the audit's six page-header treatments, eight empty-state classes and four timestamp implementations. W3 settles the shared files before any W4–W9 consumer starts.
**Why separate from S07 rather than one story**: the combined story reached 18 tasks across canon CSS, `app.css`, four shared Trellis fragments, two controllers, `helpers.dart` and Dart tests — past the single-session decomposition marker. The seam is clean: S07 is CSS-only with no runtime behaviour and no Dart; S16 is fragments, controllers and Dart with no type or token work. They overlap only on `app.css`, `topbar.html` and `components.html`, and running serially removes the conflict.


## Technical Overview


## Code Patterns & External References

```
# type | path#anchor or url                                                          | why needed (intent)
file   | packages/dartclaw_server/lib/src/static/controllers/shared.js#showToast       | Toast entry point TI05/TI06 reuse; `queueToast` is added beside it
file   | packages/dartclaw_server/lib/src/static/controllers/shared.js#readHtmxErrorMessage | Existing error-message extraction (:245) the global listener must reuse, not duplicate
file   | packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js#bindHtmxRequestErrors | Archive-only listener (:395) TI05 removes once the body-level pair owns the same failures
file   | packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js#connect | Listener registration (:17) and its `disconnect()` counterpart (:51) every new global listener must pair with
file   | packages/dartclaw_server/lib/src/templates/components.html#infoCard           | The fragment S07 re-shapes; `pageHeader` and the extended `emptyState` sit beside it and match its emit shape
file   | packages/dartclaw_server/lib/src/templates/helpers.dart#formatRelativeTime    | The single relative-time helper (:29) TI08 extends and every call site routes through
file   | packages/dartclaw_server/lib/src/templates/health_dashboard.dart#_relative     | The fourth, private relative-time implementation (:180-188) TI08 deletes in favour of the shared helper
file   | packages/dartclaw_server/lib/src/templates/workflow_detail.html#skeleton-block | The only correct loading exemplar in the app (skeleton + banner-error + Retry) TI07 generalises
file   | packages/dartclaw_server/test/templates/helpers_test.dart                     | The existing suite the new boundary cases join; follow its `group`/`test` shape
file   | dev/design-system/components.css#.value-absent                               | S03's absent-value treatment TI09's helper renders into
file   | dev/design-system/components.css#.empty-state                                | The canon empty state (:1504) TI04 collapses the eight app-local classes onto
tool   | dev/tools/fitness/check_design_system_sync.sh                                 | Must stay green; this story edits no drift-checked file, so a failure means S07's re-sync did not land
```


## Constraints & Gotchas

- **Critical**: canon is closed after P1 for `tokens.css` / `components.css` / `icons.css`. Two rules this story needs live there and are **not** this story's to write: the `.shell` / `.content-area` row sizing (TI01) and a `.skip-link` rule (TI02), both shell chrome and therefore S01's. Each task carries a presence check and stops-and-reports if S01 has not shipped it. Do not work around a missing rule with an app-local override of a canon structural rule — an `app.css` `.shell { grid-template-rows: … }` shadow is exactly the app-local duplicate FR6 exists to remove.
- **Critical**: `.status-dot--live` and `.scan-bar` are animations. Gating them on `data-connection` must not bypass the `prefers-reduced-motion` handling already in canon — the attribute is an additional gate, not a replacement.
- **Critical**: S06 W1 has already removed its native `confirm()` / `alert()` calls before this story executes in W3. TI05 still proves only S16's added lines, but it does so against `.agent_temp/0.22.1-s16-entry`, so the accumulating checkout at story entry is the baseline.
- **Constraint**: `app.css` loads *after* `design-system.css` (`layout.html:16-17`), so equal-specificity app rules win. Deleting an `app.css` declaration exposes the canon rule underneath — confirm what surfaces before assuming a deletion is inert. This matters most in TI04, where removing the app-local `.empty-state-icon/-title/-text` family is the *point*: the canon accent-glow icon rule must become visible.
- **Constraint**: S07 has already edited `topbar.html`, `components.html` and `app.css` when this story starts. `topbar.html`'s two static titles carry an extra `t-page-title` class from S07 TI02, so any assertion about their class attribute must test for a class *in the list*, not for the whole attribute value.
- **Critical**: global HTMX failure handling and archive's existing `bindHtmxRequestErrors` overlap on the same events. Leaving both means one failed archive paints two toasts. TI05 removes the archive-specific listener/helper rather than filtering or deduplicating toasts after the fact.
- **Avoid**: editing a per-surface template to prove a shared fragment works. S08–S12 and S15 own those files in later serialized waves – prove a fragment in its own render, and leave adoption to the owning surface story.
- **Avoid**: converting a legitimate `0`, `'0'` or `false` to the absent treatment. `workflows_page.dart:110` (`totalSteps`) and `:125` (`progressPercent`) are computed zeros and are the guard cases the helper must leave alone, not sites to convert.


## Implementation Plan

### Implementation Tasks

Before TI01, snapshot the protected files exactly as W3 receives them. These comparisons isolate S16's own delta from the accumulated W1–W2 checkout:

```sh
BASE=.agent_temp/0.22.1-s16-entry
rm -rf "$BASE"
mkdir -p "$BASE/dev" "$BASE/packages/dartclaw_server/lib/src/static/controllers" "$BASE/packages/dartclaw_server/lib/src/static" "$BASE/packages/dartclaw_server/lib/src/templates"
cp -R dev/design-system "$BASE/dev/"
cp packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/icons.css "$BASE/packages/dartclaw_server/lib/src/static/"
cp packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js "$BASE/packages/dartclaw_server/lib/src/static/controllers/"
cp packages/dartclaw_server/lib/src/templates/settings.html packages/dartclaw_server/lib/src/templates/restart_banner.html "$BASE/packages/dartclaw_server/lib/src/templates/"
```

- [ ] **TI01** A long page scrolls inside the shell instead of overflowing it
  - `app.css#.page-content` (:598) gains `min-height: 0`. Follow the already-correct canon `#.chat-area { min-height: 0 }` precedent.
  - **Hoist request (S01)**: the structural half is canon chrome and is not written here. Canon `dev/design-system/components.css#.shell` (:85) must change `grid-template-rows: var(--topbar-h) 1fr` to `var(--topbar-h) minmax(0, 1fr)`, and `#.content-area` (:1548) must gain `min-height: 0` and drop the inert `flex: 1`. Both belong to S01 (surfaces and chrome) and are listed in `canon-hoist-manifest.md`.
  - Document the assembled contract in DESIGN.md § Layout: `.shell` supplies the shrinkable row, `.content-area` and app-owned `.page-content` allow the row child to shrink, and page content scrolls inside the `100dvh` shell. S01 owns the canonical CSS; this story owns the app-side half and the cross-layer behaviour contract.
  - **Verify**: `rg -n 'grid-template-rows:\s*var\(--topbar-h\) minmax\(0, 1fr\)' packages/dartclaw_server/lib/src/static/design-system.css` returns the `.shell` rule (it returns no matches today — note that a bare `minmax(0, 1fr)` grep passes vacuously, because `grid-template-columns` already uses it at :89 and :108) — if it returns nothing, S01 has not shipped the hoist and this task stops and reports rather than shadowing the rule from `app.css`; `rg -nU --multiline-dotall '^\.page-content[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg 'min-height:\s*0'` returns the declaration (returns nothing today); DESIGN.md § Layout names the three-rule `100dvh` scrolling contract; a full-page capture of `/memory` in the `visual` profile is exactly 1440×900 (it captures at 1440×1333 today) with the sidebar, its border and the ground gradient painted to the viewport bottom

- [ ] **TI02** The shared topbar carries the page `<h1>`, and skip links never target missing content
  - `templates/topbar.html` promotes its two static titles to `<h1>`, class list unchanged: `pageTopbar`'s `<span class="session-title-static …">` (:38) and `plainTopbar`'s `<span class="session-title …">` (:26). `sessionTopbar` is excluded: its title is an editable `<input class="session-title">` (:5), which cannot be an `<h1>`, and its archive variant (:4) is the read-only twin of that input, not a page title. Document the "topbar owns the page `<h1>`" contract in `DESIGN.md`; S12 later consumes it and owns only its back-navigation/showcase extension.
  - Runtime re-validation finds `layoutTemplate` also wraps login and bare error bodies, neither of which contains `#main-content`. Use the smallest coherent contract: add `showSkipLink` to `layoutTemplate`, defaulting true for the standard shell callers whose templates already supply `#main-content`; `layout.html` renders the body-first `<a class="skip-link" href="#main-content">Skip to content</a>` only when true. `loginPageTemplate` and the current bare `errorPageTemplate` pass false. S12's later shell-wrapped error branch passes true only when it also renders `#main-content`, while its bare fallback remains false. Do not infer the target by parsing the raw body HTML and do not require every existing shell caller to repeat an unchanged target.
  - **Hoist request (S01)**: `.skip-link` does not exist anywhere in canon or the app. It is new shell chrome, so S01 must ship it into `components.css` as visually-hidden-until-focus. This story does not author it – canon is closed after P1.
  - **Ownership**: per the plan's shared-surface decision this task asserts only what it owns – that the shared fragment emits an `<h1>`, no NEW duplicate appears, and the shared layout emits no dead skip link. It cannot assert one-per-page: six templates carry an in-page `<h1>` today (`channel_detail`, `kg_timeline`, `knowledge_hub`, `login`, `projects`, `settings`) and this story is barred from editing per-surface templates. Those deletions belong to S10, S11 and S15; `login` renders no topbar and keeps its `<h1>`.
  - **Verify**: `rg -c 'skip-link' packages/dartclaw_server/lib/src/static/design-system.css` prints `1` or more – otherwise S01 has not shipped the hoist and this task stops. `rg -n '<h1' packages/dartclaw_server/lib/src/templates/topbar.html` returns exactly two promoted static titles, and the baseline `<h1>` inventory gains no seventh page template. On a shell page the first Tab reveals "Skip to content", activating it focuses `#main-content`, and its href resolves. `render_test.dart` exercises all three Dart wrappers: a direct `layoutTemplate(title: 'Test', body: '<main id="main-content"></main>', showSkipLink: true)` case asserts one body-first skip link and its real target; `loginPageTemplate` and the bare `errorPageTemplate` each render through their wrapper and assert that no skip link is emitted. Login reaches its token input without traversing a dead control; the bare error page reaches Back to Home first. S12 later regression-proves that the shell-wrapped 404 renders the link and target together

- [ ] **TI03** Shared page and metric fragments bind the canonical type tiers once
  - `templates/components.html` + `components.dart` gain a `pageHeader` fragment — `<header class="pagehead">` with an optional `<h2 class="t-page-title">`, an optional `--fg-sub0` subtitle and a right-aligned action slot — replacing the six competing treatments (`.pagehead`, `.settings-header`, `.info-title`/`.info-subtitle`, the channel hero, `.section-header`-as-title, and no title at all). Omit the `<h2>` when the title is empty while retaining subtitle and actions; the topbar remains the sole page `<h1>`. Action labels take verb+noun with `data-icon="plus"` rather than a literal `"+ "`. Follow `components.dart#infoCardTemplate` (:65) for the Dart-side signature shape. Per-surface adoption is S08–S12 and S15.
  - In the same shared-fragment owner, add `.t-metric` to `components.html#metricCard`'s value element. S02 defines and showcase-proves the class; this task applies it once so every existing and later `metricCardTemplate` consumer inherits the binding. Do not add a per-surface metric class or re-declare the four type properties.
  - **Verify**: `rg -n 'tl:fragment="pageHeader"' packages/dartclaw_server/lib/src/templates/components.html` returns the fragment and `rg -n '^String pageHeaderTemplate\(' packages/dartclaw_server/lib/src/templates/components.dart` returns the function — both return nothing today, and a comment mentioning `pageHeader` would not satisfy either; rendering it with a title, subtitle and action emits `<header class="pagehead">` containing an `<h2 class="t-page-title">`, then the subtitle, then the action; rendering it with an empty title emits no heading but retains the subtitle and action; rendering `metricCard` emits a value element whose class list contains `metric-value` and `t-metric`, computing to 32px/600 with 1.15 leading

- [ ] **TI04** The empty-state family is one implementation with one bounded visual variant
  - The eight bespoke classes – `.sidebar-placeholder` (:169), `.table-empty-cell` (:1126), `.allowlist-empty` (:1510), `.pairing-empty` (:1556), `.task-artifact-empty` (:1897), `.tl-empty-state` (:2228), `.knowledge-empty-state` (:3176), `.provider-empty-state` (:3673) – collapse onto canon `.empty-state`; `app.css:1808-1810`'s parallel `.empty-state-icon/-title/-text` family stops shadowing the canon accent-glow icon rule; the shared `templates/components.html#emptyState` fragment (:6) gains `.empty-state-title` and an optional action slot per S03's canon shape. The ~14 non-empty-state uses of `.empty-state-text` as a muted-text utility move to `.text-muted`.
  - The generic Dart/Trellis contract accepts required escaped `title` and `body` strings plus the already-required optional server-owned action slot; callers can therefore supply surface-specific content without reopening the fragment. Runtime re-validation finds no existing optional icon/visual parameter, so add only `useMascot = false` to that content contract: false renders the existing canonical icon slot with `aria-hidden="true"`; true renders `<img src="/static/mascot-avatar-512-8bit.png" class="pixel-art" width="64" height="64" alt="">`. The mascot is decorative because title/body carry the state. S12's in-session chat caller is the only generic caller that opts in; later surface callers keep the default icon. The action slot accepts only pre-rendered server-owned control markup, never user content. Do not add a second raw-HTML slot, icon hierarchy, enum, new CSS or canon rule. The distinct `emptyAppStateTemplate` remains its existing caller-owned fragment; S12 updates its broken visual directly.
  - **Boundary**: S07 TI05 retiers `.table-empty-cell` and `.empty-state-text` off `--fg-overlay` immediately before this story folds them into canon. That is not wasted work – S07's gate runs at its own boundary – but do not treat the retiered colours as values to preserve locally; canon `.empty-state` is the source once the shadow is gone.
  - **Wrapper contract is part of the proof.** `render_test.dart` imports and calls `components.dart#emptyStateTemplate` for three cases: default visual without action, default visual with the optional server-owned action, and `useMascot: true`. Direct `engine.renderFileFragment('components', fragment: 'emptyState', …)` coverage may remain as supplemental Trellis proof, but it cannot be the only path for any of those variants – the tests must fail if the Dart wrapper omits or misnames a context key.
  - **Verify**: the eight bespoke class names and the app-local `.empty-state-icon/-title/-text` rules are absent from `app.css`; the default `emptyStateTemplate` call emits the hidden decorative icon, `.empty-state-title` and copy; the action-bearing wrapper call emits the supplied server-owned action; the mascot wrapper call emits exactly one 64px `.pixel-art` image with `alt=""` and no icon. Across those wrapper calls `render_test.dart` pins two distinct title/body callers, both visual branches and the optional-action branch; no other caller opts in and no new `.empty-state-*` rule is added

- [ ] **TI05** Failed htmx requests and dropped SSE streams are announced exactly once
  - `dc_shell_controller.js#connect` (:17) registers one body-level `htmx:responseError` + `htmx:sendError` pair calling `showToast('error', readHtmxErrorMessage(...))`, covering all HTMX requests without template edits, and removes them in `disconnect()` (:51). Runtime re-validation finds archive already binds an overlapping per-button pair through `archiveSession()` → `bindHtmxRequestErrors()` (:351, :395-416). Remove that archive-local binding and the now-unused helper entirely; archive relies on the global pair, so one failed request produces one toast. Keep archive's successful-request sidebar-open restoration; do not replace the deleted local listener with another archive-specific catch/toast path.
  - The `/api/events` `onerror` (:438) sets `data-connection="lost"` on the shell, renders `.banner.banner-warning`, and gates `.status-dot--live` / `.scan-bar` animations on that attribute; a successful `open` clears it. `data-connection` appears zero times in the codebase today. Adds no dialog and no native `confirm`.
  - **Verify**: the global listeners are registered once and removed once; `app_js_test.dart` pins that pair and the absence of `bindHtmxRequestErrors`, and `rg -n 'bindHtmxRequestErrors' packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js` returns no match. Force one archive `htmx:responseError` and one archive `htmx:sendError` separately: each failure appends exactly one toast with the expected message, never two. Separately, a successful archive still restores an open sidebar. A stale `hx-get` 404 also shows one server-message toast. Killing the SSE stream renders the warning banner and stops the sidebar pulse, and restoring it clears both. The W3 controller diff introduces no forbidden native-dialog call

- [ ] **TI06** A success toast survives a navigation
  - `controllers/shared.js` gains `queueToast(type, message)` writing to `sessionStorage` beside `showToast` (:71); `dc_shell_controller.js#connect` drains and shows it, clearing the key in the same read so a second navigation cannot repeat it. `dc_shell_controller.js#deleteSession` owns queueing before its navigation. S15 owns the four project create, update, fetch and remove handlers: they swap `#projects-content` in place, show success immediately after a successful swap, and must not queue a navigation toast; any legacy queued project-mutation toast is cleared before it can surface on a later navigation. `sessionStorage` is used zero times in `controllers/` today.
  - **Verify**: `rg -c 'sessionStorage' packages/dartclaw_server/lib/src/static/controllers/` lists both `shared.js` and `dc_shell_controller.js` (it prints nothing and exits 1 today); deleting a session queues one success toast that appears after navigation and does not repeat on the next navigation; S15's project-mutation validation proves each successful in-place swap announces immediately and cannot leave a stale queued project toast

- [ ] **TI07** In-flight navigation and polling have a visible loading treatment
  - Shell navigation gets an `hx-indicator` target driving canon `.scan-bar` (`components.css:1162`) under the topbar; the polling fragments (health, memory, task timeline) get `.skeleton` (`components.css:1362`) placeholders. Follow `templates/workflow_detail.html`'s skeleton + `banner-error` + Retry block — the app's only correct exemplar. The `hx-indicator` target lives in the shared `topbar.html` / `layout.html` layer so no per-surface template needs editing.
  - **Verify**: `rg -c 'hx-indicator' packages/dartclaw_server/lib/src/templates/*.html` lists at least the shared topbar or layout fragment (it prints nothing and exits 1 today across every template); `rg -c 'skeleton' packages/dartclaw_server/lib/src/templates/health_dashboard.html packages/dartclaw_server/lib/src/templates/memory_dashboard.html packages/dartclaw_server/lib/src/templates/task_timeline.html` lists all three; an in-flight sidebar navigation renders a `.scan-bar` that clears on settle, a polling fragment renders `.skeleton` placeholders before its first payload, and `prefers-reduced-motion: reduce` suppresses the sweep animation

- [ ] **TI08** One timestamp format governs the product
  - `templates/helpers.dart#formatRelativeTime` (:29) uses relative time through 30 elapsed days, then falls back from day 31 to an absolute short date in server-local time: `d MMM` when the date falls in the current local calendar year, otherwise `d MMM yyyy`. Every call site emits the source ISO value as `title="<ISO>"` for hover disclosure. Three off-helper renderings route through it: `session_info.dart:95` (`'createdAt': createdAt ?? '—'` — the raw upstream ISO string, milliseconds included, emitted verbatim), `memory_dashboard.dart:158` (`formatLocalDateTime(…, emptyPlaceholder: 'N/A')`, which renders `2026-03-20 02:00`) and `health_dashboard.dart:180-188` (a fourth, private relative-time implementation with its own `'unknown'` catch, which the audit did not name and which is deleted here). The eight call sites that already route through the helper — `tasks.dart:158`, `task_detail.dart:141/143/144`, `task_timeline.dart:172`, `workflow_detail.dart:254`, `projects.dart:50`, `workflows_page.dart:202` — need only the `title="<ISO>"` disclosure, not a rewrite; the two identical private `_formatRelativeTimeIso` wrappers (`tasks.dart:359`, `task_detail.dart:210`) collapse into one exported helper.
  - **Boundary**: `kg_timeline.html:26`'s `placeholder="2026-01-15T00:00:00Z"` is **not** a rendered timestamp — it is the format hint for the operator-supplied `as_of` filter value, and routing it through a formatter would remove the only cue for what the field accepts. It stays, and the ISO scan below excludes `.html` placeholders. Record the disposition so it does not read as a missed site.
  - **Verify**: `rg -n "'createdAt': createdAt" packages/dartclaw_server/lib/src/templates/session_info.dart` returns no matches (it returns :95 today); `rg -n 'formatLocalDateTime' packages/dartclaw_server/lib/src/templates/` returns no matches (it returns memory_dashboard.dart:1 and :158 today); `rg -n "d ago'" packages/dartclaw_server/lib/src/templates/health_dashboard.dart` returns no matches (it returns :184 today, the private duplicate); `dart test packages/dartclaw_server/test/templates/helpers_test.dart` passes a new `formatRelativeTime` group covering 29, 30, 31 and 400 elapsed days, same-year and cross-year absolute dates, and server-local calendar conversion — each absolute-date case must fail against today's implementation, which returns `Nd ago` at every age, so run them red first; in the browser a 129-day-old task renders an absolute short date, not `129d ago`, and every rendered timestamp carries a `title` attribute holding its ISO value

- [ ] **TI09** One absent-value convention governs the product
  - One helper in `templates/helpers.dart` returns typed view data `({bool isAbsent, Object? value})`: `isAbsent` is true only for null and empty-string inputs, while `value` preserves every non-absent input unchanged. Call sites unpack the result into a boolean plus the original value in their template context. Templates branch on the boolean, emitting static `<span class="value-absent"></span>` markup for absent values and rendering the original value through `tl:text` otherwise; non-empty values never pass through `tl:utext`. Every current rendering in the shared formatting layer routes through it: the em dash (`session_info.dart:62,68,73,77,78,79,95`; `audit_table.dart:120,124,128`; `scheduling.dart:107,111`), `'--'` (`workflow_detail.dart:204,261,269`), `'N/A'` (`memory_dashboard.dart:123,158`) and `'unknown'` (`memory_dashboard.dart:131`, `health_page.dart:50,54`, `settings_page.dart:76,77,142`, `task_timeline.dart:92,94`, `tasks.dart:324`, and `health_dashboard.dart:186` via TI08's deletion).
  - **Guard cases** — the helper must mark these non-absent and preserve the input unchanged, and each is a test case, not a conversion: `workflows_page.dart:110` (`totalSteps`, a computed `0`), `:125` (`progressPercent`, a computed `0`), and any `'0'` or `false`.
  - **Exemption**: `settings_page.dart:139`'s `'binaryStatusLabel': provider.binaryFound ? 'Found' : 'Not found'` stays. "Not found" there is a determinate status — the binary was looked for and is absent — not an unknown field, and rendering it as an em dash would lose the finding. Only the `?? 'unknown'` half of :142 converts. Record the exemption.
  - **Verify**: `rg -n "\?\? 'unknown'|\?\? 'N/A'|return '--'|\?\? '--'|: '--'|emptyPlaceholder: 'N/A'" packages/dartclaw_server/lib/src/web/pages packages/dartclaw_server/lib/src/templates` returns no matches — it returns 14 lines across six files today (`settings_page` 3, `workflow_detail` 3, `health_page` 2, `memory_dashboard` 3, `task_timeline` 2, `tasks` 1), so one missed site fails it; `rg -c 'u2014' packages/dartclaw_server/lib/src/templates/session_info.dart packages/dartclaw_server/lib/src/templates/audit_table.dart packages/dartclaw_server/lib/src/templates/scheduling.dart` prints nothing and exits 1 (it prints 7, 3 and 2 today); `dart test packages/dartclaw_server/test/templates/helpers_test.dart` passes a new absent-value group asserting `isAbsent` for `null` and `''`, non-absence plus unchanged values for `0`, `'0'` and `false`, static absent markup for the absent branch, and escaped literal output for a non-empty `<script>` string

- [ ] **TI10** The shared control glitches are closed
  - `.btn-secondary` (used at `tasks.html:22` and `workflow_detail.html:133`, defined nowhere) resolves to `.btn-ghost`, the existing lower-emphasis variant. In `app.css`'s 768px block, the bare `button, summary, [role="button"] { min-width: 48px; min-height: 48px }` (:3756-3761) drops `min-width`, which today stretches narrow inline chips; the class-name allow-lists at :3763, :3776 and :3785 become one intent-based `:is(...)` selector covering the anchor controls the current lists miss (`a.tab-btn`, `a.pager-link`, `.settings-tab`, `.topbar-back`, `.card-link`).
  - **Boundary**: the restart banner's missing base `.btn` is **not** this story's. Both buttons lack it (`restart_banner.html:7` "Restart Now" and `:8` "Dismiss"), the plan assigns the defect to S12, and fixing one of the two here would leave Dismiss as UA chrome while reading as closed.
  - **Verify**: `rg -n 'btn-secondary' packages/dartclaw_server/lib/src/templates` returns no matches (it returns `tasks.html:22` and `workflow_detail.html:133` today); `rg -n 'a\.tab-btn|a\.pager-link' packages/dartclaw_server/lib/src/static/app.css` returns the new selector (returns nothing today); at 768px the knowledge Hub/Timeline tabs and the pager links measure ≥ 48px tall (≈28px today) while a narrow inline chip is no longer padded to a 48px minimum width; `rg -n 'class="btn-sm' packages/dartclaw_server/lib/src/templates/restart_banner.html` still returns both lines 7 and 8 — this story leaves that file untouched for S12

### Testing Strategy

- `[TI08,TI09]` are the only pure-Dart units in the story and carry real boundary risk. Cover them in the existing `packages/dartclaw_server/test/templates/helpers_test.dart` (which already holds `formatUptime` and `formatBytes` groups), not with visual validation: `formatRelativeTime` at 29/30/31/400 elapsed days plus same-year, cross-year and server-local calendar cases, and the absent-value helper's `null` / `''` / `0` / `'0'` / `false` distinction. Per the Prove-It discipline, run each new case against the unmodified helper first and confirm it fails — today's `formatRelativeTime` returns `Nd ago` at every age, so a 400-day case that passes red is testing the wrong thing.
- `[TI05,TI06,TI07]` are browser-runtime behaviours with no full interaction harness in this codebase; prove them interactively against the `visual` profile by forcing a 404, one archive response failure, one archive send failure, killing the SSE stream and throttling a navigation. For each archive failure, record that the toast count increases by exactly one.
- `[TI01,TI02,TI03,TI04,TI10]` are CSS and markup: the per-task Verify checks prove the change landed, and the visual/keyboard gate below proves it works. TI02's `render_test.dart` cases invoke `layoutTemplate`, `loginPageTemplate` and `errorPageTemplate` directly for the conditional skip-link contract, then keyboard-check a shell page, login and the bare error page. TI04's cases invoke the Dart `emptyStateTemplate` wrapper for default, action-bearing and `useMascot: true` variants; direct Trellis-fragment renders are supplemental only.
- Workspace-wide `dart analyze --fatal-infos` must be clean before the story closes — `helpers.dart` gains two public functions, and an unused import left behind by a deleted private helper is the likely failure.

### Validation

- Validate against the `visual` testing profile (`bash dev/testing/profiles/visual/run.sh`, port 3338 — the only profile rendering all 23 surfaces) in **both** themes at desktop 1440×900 (matching the audit baseline capture) and 768px, comparing against this story's own story-start captures per the plan's visual-baseline protocol.
- Keyboard-validate the conditional skip link and promoted `<h1>` with a screen-reader heading list on at least one `pageTopbar` shell page and one `plainTopbar` shell page: each link appears first and focuses its real `#main-content`; exactly one `<h1>` comes from the topbar on a page whose surface story has deleted its duplicate, and two on the six that have not. On login and the bare error page, assert no skip link exists and keyboard order reaches the page's first real control without a dead jump target. S12 later repeats the error check for its shell-wrapped 404 branch.
- Re-check `prefers-reduced-motion: reduce` after TI05 and TI07: the `data-connection` gate and the `hx-indicator` sweep are both animation paths that must stay suppressed under the media query.

### Execution Contract

- TI01 and TI02 each open with a presence check against a canon rule S01 owns. Run both checks before starting either task. If the rule is absent, the task stops and reports for hoisting — it does not shadow the canon rule from `app.css`, and it does not add the rule to canon, which is closed after P1.
- TI04 must run after TI03: the `emptyState` fragment and the `pageHeader` fragment land in the same two files, and TI03 establishes the fragment signature shape TI04's action slot follows. S12 consumes TI04's `useMascot` option at its chat caller only; S12 must not replace it with a second visual seam.
- TI09 must run after TI08. `health_dashboard.dart:186`'s `'unknown'` disappears with the private relative-time helper TI08 deletes, so running TI09 first leaves a site that TI08 then re-resolves, and TI09's grep would have passed over a rule it did not own.
- This story executes in W3 only after S07 W2 has left `check_design_system_sync.sh` and generated parity green. At S16 close the order is mandatory: targeted checks first; after the final embed-root change run `dart run dev/tools/embed_assets.dart`; then the generated parity test; then `dart format --line-length=120 --output=none --set-exit-if-changed .`; then workspace-wide `dart analyze --fatal-infos`; then the full `dart test packages/dartclaw_server` suite. After remediation that changes an embed root or shared template/controller, restart this ordered sequence at the targeted checks.
- S07 has already edited `app.css`, `topbar.html` and `components.html` when this story starts. Do not revert a `t-page-title` class, a retiered colour or a `--z-*` token found in those files — they are S07's landed work.


## Final Validation Checklist

- [ ] No file outside `packages/dartclaw_server/lib/src/static/` (`app.css` and `controllers/`), `packages/dartclaw_server/lib/src/templates/`, `packages/dartclaw_server/lib/src/web/pages/`, `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart`, `packages/dartclaw_server/test/templates/{helpers_test.dart,render_test.dart}`, `packages/dartclaw_server/test/static/app_js_test.dart` and `dev/design-system/DESIGN.md` is modified – no service, schema, route or API change. The workflow package's generated asset file remains byte-unchanged because S16 edits no workflow embed root.
- [ ] With `BASE=.agent_temp/0.22.1-s16-entry`, `cmp -s` proves `dev/design-system/{tokens.css,components.css,icons.css}` and their served copies unchanged, and `check_design_system_sync.sh` still exits 0.
- [ ] No per-surface template owned by S08–S12 or S15 is edited except the timestamp and absent-value `.dart` call sites TI08 and TI09 name; with `BASE=.agent_temp/0.22.1-s16-entry`, `cmp -s` proves `settings.html` and `restart_banner.html` unchanged.
- [ ] Verification ran in order: targeted focused suites; `dart run dev/tools/embed_assets.dart`; `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart`; `dart format --line-length=120 --output=none --set-exit-if-changed .`; workspace-wide `dart analyze --fatal-infos`; then the full `dart test packages/dartclaw_server` suite. Both generated asset files remain tracked, and the workflow generated asset remains unchanged.
- [ ] The full server package suite passes after parity, not only `helpers_test.dart` or the targeted render/controller checks.
- [ ] The eight outputs in the table above all exist and render, because six downstream surface stories consume them the moment this one closes.
- [ ] Skip-link ownership is coherent: standard shell layouts render it only with a real `#main-content`; login and bare error render none; S12's shell-wrapped error branch is explicitly required to opt in only when it supplies the target.
- [ ] Global HTMX error handling is the sole archive failure owner: `bindHtmxRequestErrors` is absent and one archive failure produces exactly one toast.
- [ ] The three `global` items this story does not close – the unvendored typeface (S13), unbounded list pagination (deferred as a new capability), and `settings.html:52`'s em-dash option (S11) – are recorded in Implementation Observations with their reasons – the preferred write-back location; S14's ledger sweep reads the whole canonical FIS as a safety net, but a prose-only deferral relies on that net rather than the supported path.
- [ ] Any canon rule this story reported rather than wrote (`.shell` / `.content-area` row sizing, `.skip-link`) is recorded in Implementation Observations with S01 named as the owner, whether or not S01 had shipped it in time.


## Implementation Observations

#### DECISION NOTE: s16.absent-value-render-contract

Decision-Key: s16.absent-value-render-contract
Altitude: FIS
Affected surface: Shared absent-value helper and every Dart/Trellis consumer in the formatting sweep
Decision: Return typed absence state plus the original value; templates emit static absent markup or render the preserved value with `tl:text`; non-empty values never use `tl:utext`.
Rationale: Keeps the absent treatment reusable without widening the trusted-HTML boundary or risking user-controlled markup execution.
Evidence: User ratified the recommended preflight option on 2026-07-26.
