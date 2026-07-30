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

- [x] **S01 [OC01] [TI01,TI02,TI10] The shell holds together at both viewports and by keyboard**
  - **Given** `/memory` in the `visual` profile, whose content is taller than the 900px viewport (the audit captured it at 1440×1333 with unpainted canvas below y=900)
  - **When** the page is loaded, the operator presses Tab once, and the window is then narrowed to 768px
  - **Then** the sidebar, topbar and ground gradient paint the full viewport height and the page content scrolls inside the shell
  - **And** on the shell page the first Tab stop is a visible "Skip to content" link that moves focus to `#main-content`, while login and the bare error fallback render no skip link because neither body supplies that target; the shared topbar fragment renders its page title as an `<h1>` – the six per-surface templates that carry their own in-page `<h1>` are untouched here and no seventh appears
  - **And** at 768px the anchor-based tab and pager controls measure ≥ 48px tall, while a narrow inline chip is no longer stretched to a 48px minimum width

- [x] **S02 [OC02] [TI03,TI04] One page header and one empty state exist for the six sweeps to adopt**
  - **Given** the six competing page-header treatments and eight bespoke empty-state classes the audit catalogued, and the shared fragments in `templates/components.html`
  - **When** the `pageHeader` fragment is rendered on its own and the default, optional-action and mascot `emptyState` variants are rendered through the Dart `emptyStateTemplate` wrapper
  - **Then** `pageHeader` emits `<header class="pagehead">` with a `.t-page-title` heading, an optional subtitle and a right-aligned action slot, and its action labels read verb+noun with `data-icon="plus"` rather than a literal `"+ "`
  - **And** `emptyState` renders the default hidden decorative icon + `.empty-state-title` + body copy + optional action with the canon accent-glow treatment applying, supports only the minimal optional decorative mascot variant S12 consumes, and leaves no bespoke empty-state class in `app.css`
  - **And** the shared `metricCard` fragment emits its value with `.t-metric`, so health, memory, task detail, session and workflow KPI consumers inherit one 32px metric binding without per-surface reimplementation

- [x] **S03 [OC03] [TI05] A failed request and a dropped live stream announce themselves**
  - **Given** the sidebar's `hx-get` link to a session that has since been deleted, and an `/api/events` stream that the server closes
  - **When** the operator clicks the stale link, and separately when the stream drops
  - **Then** the 404 surfaces an error toast carrying the server's message instead of the click producing no visible change at all, and one failed archive request produces exactly one toast – the global listener is the sole owner and no archive-local HTMX error listener duplicates it
  - **And** the shell marks itself `data-connection="lost"`, shows a `.banner.banner-warning` naming the disconnection, and stops the `.status-dot--live` pulse and `.scan-bar` sweeps until the next successful `open` clears it – without bypassing the `prefers-reduced-motion` handling already in canon

- [x] **S04 [OC03] [TI06,TI07] Success is announced and in-flight work is visible**
  - **Given** a navigation mutation handled by `deleteSession`, whose page change would otherwise destroy its toast, and the 28 `hx-get` sites that today carry zero `hx-indicator`
  - **When** the session is removed, and separately when a sidebar navigation is in flight
  - **Then** a success toast is queued before the navigation and shown after the new page connects, so the mutation reports success rather than only changing the page underneath, and a second navigation shows no repeat toast; project mutations are S15's in-place swaps and announce immediately without leaving a queued navigation toast
  - **And** the in-flight navigation shows a `.scan-bar` under the topbar, and a polling fragment shows `.skeleton` placeholders instead of popping in

- [x] **S05 [OC04] [TI08,TI09] One timestamp format and one absent value — and a real zero stays a zero**
  - **Given** seeded data containing a task created 129 days ago, a session whose `createdAt` renders today as `2026-04-15T10:00:00.000`, a workflow definition with **0** steps, and a task whose `startedAt` is null
  - **When** `/tasks`, `/session-info`, `/workflows` and `/memory` render
  - **Then** the 129-day value renders as an absolute short date, every timestamp carries a `title` attribute with its ISO value, and no surface prints raw ISO-8601 with milliseconds
  - **And** the null `startedAt` renders the canon `.value-absent` treatment while the workflow's step count renders `0` — the helper converts null and empty to the absent treatment and never converts a legitimate `0` or a non-empty string
  - **And** `--`, `N/A`, `unknown` and the bare em dash no longer appear as absent-value renderings in the shared formatting layer


## Structural Criteria

- [x] `dev/tools/fitness/check_design_system_sync.sh` exits 0 at the story boundary. With `BASE=.agent_temp/0.22.1-s16-entry`, the three drift-checked canon files and their served copies are byte-unchanged; `DESIGN.md` is the only `dev/design-system/` file this story writes, and that one is prose, never synced. A red check means S07's re-sync did not land, not that this story drifted.
- [x] No canon rule is authored or edited in `tokens.css`, `components.css` or `icons.css`. The two canon rules this story needs (`.shell` / `.content-area` row sizing, and a `.skip-link`) are hoist requests against S01, not edits made here.
- [x] No new runtime JS dependency and no build step: the new shell behaviours are plain ES-module code in the existing `controllers/` files, registered per `CONVENTIONS.md`.
- [x] Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` are **introduced** in `lib/src/static/controllers/`. S06 W1 has already removed its owned calls before S16 W3 begins; this story proves its own `dc_shell_controller.js` delta against the W3 entry snapshot.
- [x] Targeted checks run first: `helpers_test.dart`, `render_test.dart` and `app_js_test.dart` pass for formatting, wrapper-level conditional skip-link/empty-state rendering, and the single-owner HTMX listener contract.
- [x] After targeted checks and the final template/static change, run `dart run dev/tools/embed_assets.dart`; require `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` green; run the mandatory `dart format --line-length=120 --output=none --set-exit-if-changed .` gate; run workspace-wide `dart analyze --fatal-infos`; then run the full `dart test packages/dartclaw_server` suite. No generated, format, analyze or package-test gate is allowed red.


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

- [x] **TI01** A long page scrolls inside the shell instead of overflowing it
  - `app.css#.page-content` (:598) gains `min-height: 0`. Follow the already-correct canon `#.chat-area { min-height: 0 }` precedent.
  - **Hoist request (S01)**: the structural half is canon chrome and is not written here. Canon `dev/design-system/components.css#.shell` (:85) must change `grid-template-rows: var(--topbar-h) 1fr` to `var(--topbar-h) minmax(0, 1fr)`, and `#.content-area` (:1548) must gain `min-height: 0` and drop the inert `flex: 1`. Both belong to S01 (surfaces and chrome) and are listed in `canon-hoist-manifest.md`.
  - Document the assembled contract in DESIGN.md § Layout: `.shell` supplies the shrinkable row, `.content-area` and app-owned `.page-content` allow the row child to shrink, and page content scrolls inside the `100dvh` shell. S01 owns the canonical CSS; this story owns the app-side half and the cross-layer behaviour contract.
  - **Verify**: `rg -n 'grid-template-rows:\s*var\(--topbar-h\) minmax\(0, 1fr\)' packages/dartclaw_server/lib/src/static/design-system.css` returns the `.shell` rule (it returns no matches today — note that a bare `minmax(0, 1fr)` grep passes vacuously, because `grid-template-columns` already uses it at :89 and :108) — if it returns nothing, S01 has not shipped the hoist and this task stops and reports rather than shadowing the rule from `app.css`; `rg -nU --multiline-dotall '^\.page-content[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg 'min-height:\s*0'` returns the declaration (returns nothing today); DESIGN.md § Layout names the three-rule `100dvh` scrolling contract; a full-page capture of `/memory` in the `visual` profile is exactly 1440×900 (it captures at 1440×1333 today) with the sidebar, its border and the ground gradient painted to the viewport bottom

- [x] **TI02** The shared topbar carries the page `<h1>`, and skip links never target missing content
  - `templates/topbar.html` promotes its two static titles to `<h1>`, class list unchanged: `pageTopbar`'s `<span class="session-title-static …">` (:38) and `plainTopbar`'s `<span class="session-title …">` (:26). `sessionTopbar` is excluded: its title is an editable `<input class="session-title">` (:5), which cannot be an `<h1>`, and its archive variant (:4) is the read-only twin of that input, not a page title. Document the "topbar owns the page `<h1>`" contract in `DESIGN.md`; S12 later consumes it and owns only its back-navigation/showcase extension.
  - Runtime re-validation finds `layoutTemplate` also wraps login and bare error bodies, neither of which contains `#main-content`. Use the smallest coherent contract: add `showSkipLink` to `layoutTemplate`, defaulting true for the standard shell callers whose templates already supply `#main-content`; `layout.html` renders the body-first `<a class="skip-link" href="#main-content">Skip to content</a>` only when true. `loginPageTemplate` and the current bare `errorPageTemplate` pass false. S12's later shell-wrapped error branch passes true only when it also renders `#main-content`, while its bare fallback remains false. Do not infer the target by parsing the raw body HTML and do not require every existing shell caller to repeat an unchanged target.
  - **Hoist request (S01)**: `.skip-link` does not exist anywhere in canon or the app. It is new shell chrome, so S01 must ship it into `components.css` as visually-hidden-until-focus. This story does not author it – canon is closed after P1.
  - **Ownership**: per the plan's shared-surface decision this task asserts only what it owns – that the shared fragment emits an `<h1>`, no NEW duplicate appears, and the shared layout emits no dead skip link. It cannot assert one-per-page: six templates carry an in-page `<h1>` today (`channel_detail`, `kg_timeline`, `knowledge_hub`, `login`, `projects`, `settings`) and this story is barred from editing per-surface templates. Those deletions belong to S10, S11 and S15; `login` renders no topbar and keeps its `<h1>`.
  - **Verify**: `rg -c 'skip-link' packages/dartclaw_server/lib/src/static/design-system.css` prints `1` or more – otherwise S01 has not shipped the hoist and this task stops. `rg -n '<h1' packages/dartclaw_server/lib/src/templates/topbar.html` returns exactly two promoted static titles, and the baseline `<h1>` inventory gains no seventh page template. On a shell page the first Tab reveals "Skip to content", activating it focuses `#main-content`, and its href resolves. `render_test.dart` exercises all three Dart wrappers: a direct `layoutTemplate(title: 'Test', body: '<main id="main-content"></main>', showSkipLink: true)` case asserts one body-first skip link and its real target; `loginPageTemplate` and the bare `errorPageTemplate` each render through their wrapper and assert that no skip link is emitted. Login reaches its token input without traversing a dead control; the bare error page reaches Back to Home first. S12 later regression-proves that the shell-wrapped 404 renders the link and target together

- [x] **TI03** Shared page and metric fragments bind the canonical type tiers once
  - `templates/components.html` + `components.dart` gain a `pageHeader` fragment — `<header class="pagehead">` with an optional `<h2 class="t-page-title">`, an optional `--fg-sub0` subtitle and a right-aligned action slot — replacing the six competing treatments (`.pagehead`, `.settings-header`, `.info-title`/`.info-subtitle`, the channel hero, `.section-header`-as-title, and no title at all). Omit the `<h2>` when the title is empty while retaining subtitle and actions; the topbar remains the sole page `<h1>`. Action labels take verb+noun with `data-icon="plus"` rather than a literal `"+ "`. Follow `components.dart#infoCardTemplate` (:65) for the Dart-side signature shape. Per-surface adoption is S08–S12 and S15.
  - In the same shared-fragment owner, add `.t-metric` to `components.html#metricCard`'s value element. S02 defines and showcase-proves the class; this task applies it once so every existing and later `metricCardTemplate` consumer inherits the binding. Do not add a per-surface metric class or re-declare the four type properties.
  - **Verify**: `rg -n 'tl:fragment="pageHeader"' packages/dartclaw_server/lib/src/templates/components.html` returns the fragment and `rg -n '^String pageHeaderTemplate\(' packages/dartclaw_server/lib/src/templates/components.dart` returns the function — both return nothing today, and a comment mentioning `pageHeader` would not satisfy either; rendering it with a title, subtitle and action emits `<header class="pagehead">` containing an `<h2 class="t-page-title">`, then the subtitle, then the action; rendering it with an empty title emits no heading but retains the subtitle and action; rendering `metricCard` emits a value element whose class list contains `metric-value` and `t-metric`, computing to 32px/600 with 1.15 leading

- [x] **TI04** The empty-state family is one implementation with one bounded visual variant
  - The eight bespoke classes – `.sidebar-placeholder` (:169), `.table-empty-cell` (:1126), `.allowlist-empty` (:1510), `.pairing-empty` (:1556), `.task-artifact-empty` (:1897), `.tl-empty-state` (:2228), `.knowledge-empty-state` (:3176), `.provider-empty-state` (:3673) – collapse onto canon `.empty-state`; `app.css:1808-1810`'s parallel `.empty-state-icon/-title/-text` family stops shadowing the canon accent-glow icon rule; the shared `templates/components.html#emptyState` fragment (:6) gains `.empty-state-title` and an optional action slot per S03's canon shape. The ~14 non-empty-state uses of `.empty-state-text` as a muted-text utility move to `.text-muted`.
  - The generic Dart/Trellis contract accepts required escaped `title` and `body` strings plus the already-required optional server-owned action slot; callers can therefore supply surface-specific content without reopening the fragment. Runtime re-validation finds no existing optional icon/visual parameter, so add only `useMascot = false` to that content contract: false renders the existing canonical icon slot with `aria-hidden="true"`; true renders `<img src="/static/mascot-avatar-512-8bit.png" class="pixel-art" width="64" height="64" alt="">`. The mascot is decorative because title/body carry the state. S12's in-session chat caller is the only generic caller that opts in; later surface callers keep the default icon. The action slot accepts only pre-rendered server-owned control markup, never user content. Do not add a second raw-HTML slot, icon hierarchy, enum, new CSS or canon rule. The distinct `emptyAppStateTemplate` remains its existing caller-owned fragment; S12 updates its broken visual directly.
  - **Boundary**: S07 TI05 retiers `.table-empty-cell` and `.empty-state-text` off `--fg-overlay` immediately before this story folds them into canon. That is not wasted work – S07's gate runs at its own boundary – but do not treat the retiered colours as values to preserve locally; canon `.empty-state` is the source once the shadow is gone.
  - **Wrapper contract is part of the proof.** `render_test.dart` imports and calls `components.dart#emptyStateTemplate` for three cases: default visual without action, default visual with the optional server-owned action, and `useMascot: true`. Direct `engine.renderFileFragment('components', fragment: 'emptyState', …)` coverage may remain as supplemental Trellis proof, but it cannot be the only path for any of those variants – the tests must fail if the Dart wrapper omits or misnames a context key.
  - **Verify**: the eight bespoke class names and the app-local `.empty-state-icon/-title/-text` rules are absent from `app.css`; the default `emptyStateTemplate` call emits the hidden decorative icon, `.empty-state-title` and copy; the action-bearing wrapper call emits the supplied server-owned action; the mascot wrapper call emits exactly one 64px `.pixel-art` image with `alt=""` and no icon. Across those wrapper calls `render_test.dart` pins two distinct title/body callers, both visual branches and the optional-action branch; no other caller opts in and no new `.empty-state-*` rule is added

- [x] **TI05** Failed htmx requests and dropped SSE streams are announced exactly once
  - `dc_shell_controller.js#connect` (:17) registers one body-level `htmx:responseError` + `htmx:sendError` pair calling `showToast('error', readHtmxErrorMessage(...))`, covering all HTMX requests without template edits, and removes them in `disconnect()` (:51). Runtime re-validation finds archive already binds an overlapping per-button pair through `archiveSession()` → `bindHtmxRequestErrors()` (:351, :395-416). Remove that archive-local binding and the now-unused helper entirely; archive relies on the global pair, so one failed request produces one toast. Keep archive's successful-request sidebar-open restoration; do not replace the deleted local listener with another archive-specific catch/toast path.
  - The `/api/events` `onerror` (:438) sets `data-connection="lost"` on the shell, renders `.banner.banner-warning`, and gates `.status-dot--live` / `.scan-bar` animations on that attribute; a successful `open` clears it. `data-connection` appears zero times in the codebase today. Adds no dialog and no native `confirm`.
  - **Verify**: the global listeners are registered once and removed once; `app_js_test.dart` pins that pair and the absence of `bindHtmxRequestErrors`, and `rg -n 'bindHtmxRequestErrors' packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js` returns no match. Force one archive `htmx:responseError` and one archive `htmx:sendError` separately: each failure appends exactly one toast with the expected message, never two. Separately, a successful archive still restores an open sidebar. A stale `hx-get` 404 also shows one server-message toast. Killing the SSE stream renders the warning banner and stops the sidebar pulse, and restoring it clears both. The W3 controller diff introduces no forbidden native-dialog call

- [x] **TI06** A success toast survives a navigation
  - `controllers/shared.js` gains `queueToast(type, message)` writing to `sessionStorage` beside `showToast` (:71); `dc_shell_controller.js#connect` drains and shows it, clearing the key in the same read so a second navigation cannot repeat it. `dc_shell_controller.js#deleteSession` owns queueing before its navigation. S15 owns the four project create, update, fetch and remove handlers: they swap `#projects-content` in place, show success immediately after a successful swap, and must not queue a navigation toast; any legacy queued project-mutation toast is cleared before it can surface on a later navigation. `sessionStorage` is used zero times in `controllers/` today.
  - **Verify**: `rg -c 'sessionStorage' packages/dartclaw_server/lib/src/static/controllers/` lists both `shared.js` and `dc_shell_controller.js` (it prints nothing and exits 1 today); deleting a session queues one success toast that appears after navigation and does not repeat on the next navigation; S15's project-mutation validation proves each successful in-place swap announces immediately and cannot leave a stale queued project toast

- [x] **TI07** In-flight navigation and polling have a visible loading treatment
  - Shell navigation gets an `hx-indicator` target driving canon `.scan-bar` (`components.css:1162`) under the topbar; the polling fragments (health, memory, task timeline) get `.skeleton` (`components.css:1362`) placeholders. Follow `templates/workflow_detail.html`'s skeleton + `banner-error` + Retry block — the app's only correct exemplar. The `hx-indicator` target lives in the shared `topbar.html` / `layout.html` layer so no per-surface template needs editing.
  - **Verify**: `rg -c 'hx-indicator' packages/dartclaw_server/lib/src/templates/*.html` lists at least the shared topbar or layout fragment (it prints nothing and exits 1 today across every template); `rg -c 'skeleton' packages/dartclaw_server/lib/src/templates/health_dashboard.html packages/dartclaw_server/lib/src/templates/memory_dashboard.html packages/dartclaw_server/lib/src/templates/task_timeline.html` lists all three; an in-flight sidebar navigation renders a `.scan-bar` that clears on settle, a polling fragment renders `.skeleton` placeholders before its first payload, and `prefers-reduced-motion: reduce` suppresses the sweep animation

- [x] **TI08** One timestamp format governs the product
  - `templates/helpers.dart#formatRelativeTime` (:29) uses relative time through 30 elapsed days, then falls back from day 31 to an absolute short date in server-local time: `d MMM` when the date falls in the current local calendar year, otherwise `d MMM yyyy`. Every call site emits the source ISO value as `title="<ISO>"` for hover disclosure. Three off-helper renderings route through it: `session_info.dart:95` (`'createdAt': createdAt ?? '—'` — the raw upstream ISO string, milliseconds included, emitted verbatim), `memory_dashboard.dart:158` (`formatLocalDateTime(…, emptyPlaceholder: 'N/A')`, which renders `2026-03-20 02:00`) and `health_dashboard.dart:180-188` (a fourth, private relative-time implementation with its own `'unknown'` catch, which the audit did not name and which is deleted here). The eight call sites that already route through the helper — `tasks.dart:158`, `task_detail.dart:141/143/144`, `task_timeline.dart:172`, `workflow_detail.dart:254`, `projects.dart:50`, `workflows_page.dart:202` — need only the `title="<ISO>"` disclosure, not a rewrite; the two identical private `_formatRelativeTimeIso` wrappers (`tasks.dart:359`, `task_detail.dart:210`) collapse into one exported helper.
  - **Boundary**: `kg_timeline.html:26`'s `placeholder="2026-01-15T00:00:00Z"` is **not** a rendered timestamp — it is the format hint for the operator-supplied `as_of` filter value, and routing it through a formatter would remove the only cue for what the field accepts. It stays, and the ISO scan below excludes `.html` placeholders. Record the disposition so it does not read as a missed site.
  - **Verify**: `rg -n "'createdAt': createdAt" packages/dartclaw_server/lib/src/templates/session_info.dart` returns no matches (it returns :95 today); `rg -n 'formatLocalDateTime' packages/dartclaw_server/lib/src/templates/` returns no matches (it returns memory_dashboard.dart:1 and :158 today); `rg -n "d ago'" packages/dartclaw_server/lib/src/templates/health_dashboard.dart` returns no matches (it returns :184 today, the private duplicate); `dart test packages/dartclaw_server/test/templates/helpers_test.dart` passes a new `formatRelativeTime` group covering 29, 30, 31 and 400 elapsed days, same-year and cross-year absolute dates, and server-local calendar conversion — each absolute-date case must fail against today's implementation, which returns `Nd ago` at every age, so run them red first; in the browser a 129-day-old task renders an absolute short date, not `129d ago`, and every rendered timestamp carries a `title` attribute holding its ISO value

- [x] **TI09** One absent-value convention governs the product
  - One helper in `templates/helpers.dart` returns typed view data `({bool isAbsent, Object? value})`: `isAbsent` is true only for null and empty-string inputs, while `value` preserves every non-absent input unchanged. Call sites unpack the result into a boolean plus the original value in their template context. Templates branch on the boolean, emitting static `<span class="value-absent"></span>` markup for absent values and rendering the original value through `tl:text` otherwise; non-empty values never pass through `tl:utext`. Every current rendering in the shared formatting layer routes through it: the em dash (`session_info.dart:62,68,73,77,78,79,95`; `audit_table.dart:120,124,128`; `scheduling.dart:107,111`), `'--'` (`workflow_detail.dart:204,261,269`), `'N/A'` (`memory_dashboard.dart:123,158`) and `'unknown'` (`memory_dashboard.dart:131`, `health_page.dart:50,54`, `settings_page.dart:76,77,142`, `task_timeline.dart:92,94`, `tasks.dart:324`, and `health_dashboard.dart:186` via TI08's deletion).
  - **Guard cases** — the helper must mark these non-absent and preserve the input unchanged, and each is a test case, not a conversion: `workflows_page.dart:110` (`totalSteps`, a computed `0`), `:125` (`progressPercent`, a computed `0`), and any `'0'` or `false`.
  - **Exemption**: `settings_page.dart:139`'s `'binaryStatusLabel': provider.binaryFound ? 'Found' : 'Not found'` stays. "Not found" there is a determinate status — the binary was looked for and is absent — not an unknown field, and rendering it as an em dash would lose the finding. Only the `?? 'unknown'` half of :142 converts. Record the exemption.
  - **Verify**: `rg -n "\?\? 'unknown'|\?\? 'N/A'|return '--'|\?\? '--'|: '--'|emptyPlaceholder: 'N/A'" packages/dartclaw_server/lib/src/web/pages packages/dartclaw_server/lib/src/templates` returns no matches — it returns 14 lines across six files today (`settings_page` 3, `workflow_detail` 3, `health_page` 2, `memory_dashboard` 3, `task_timeline` 2, `tasks` 1), so one missed site fails it; `rg -c 'u2014' packages/dartclaw_server/lib/src/templates/session_info.dart packages/dartclaw_server/lib/src/templates/audit_table.dart packages/dartclaw_server/lib/src/templates/scheduling.dart` prints nothing and exits 1 (it prints 7, 3 and 2 today); `dart test packages/dartclaw_server/test/templates/helpers_test.dart` passes a new absent-value group asserting `isAbsent` for `null` and `''`, non-absence plus unchanged values for `0`, `'0'` and `false`, static absent markup for the absent branch, and escaped literal output for a non-empty `<script>` string

- [x] **TI10** The shared control glitches are closed
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

- [x] No file outside `packages/dartclaw_server/lib/src/static/` (`app.css` and `controllers/`), `packages/dartclaw_server/lib/src/templates/`, `packages/dartclaw_server/lib/src/web/pages/`, `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart`, `packages/dartclaw_server/test/templates/{helpers_test.dart,render_test.dart}`, `packages/dartclaw_server/test/static/app_js_test.dart`, the three test files whose assertions pinned strings this story is chartered to change (`packages/dartclaw_server/test/templates/{scheduling_test.dart,health_dashboard_test.dart,memory_dashboard_test.dart}` — `metric-value` class list per TI03, and the two timestamp formats per TI08) and `dev/design-system/DESIGN.md` is modified – no service, schema, route or API change. The workflow package's generated asset file remains byte-unchanged because S16 edits no workflow embed root.
- [x] With `BASE=.agent_temp/0.22.1-s16-entry`, `cmp -s` proves `dev/design-system/{tokens.css,components.css,icons.css}` and their served copies unchanged, and `check_design_system_sync.sh` still exits 0.
- [x] No per-surface template owned by S08–S12 or S15 is edited except the timestamp and absent-value `.dart` call sites TI08 and TI09 name; with `BASE=.agent_temp/0.22.1-s16-entry`, `cmp -s` proves `settings.html` and `restart_banner.html` unchanged.
- [x] Verification ran in order: targeted focused suites; `dart run dev/tools/embed_assets.dart`; `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart`; `dart format --line-length=120 --output=none --set-exit-if-changed .`; workspace-wide `dart analyze --fatal-infos`; then the full `dart test packages/dartclaw_server` suite. Both generated asset files remain tracked, and the workflow generated asset remains unchanged.
- [x] The full server package suite passes after parity, not only `helpers_test.dart` or the targeted render/controller checks.
- [x] The eight outputs in the table above all exist and render, because six downstream surface stories consume them the moment this one closes.
- [x] Skip-link ownership is coherent: standard shell layouts render it only with a real `#main-content`; login and bare error render none; S12's shell-wrapped error branch is explicitly required to opt in only when it supplies the target.
- [x] Global HTMX error handling is the sole archive failure owner: `bindHtmxRequestErrors` is absent and one archive failure produces exactly one toast.
- [x] The three `global` items this story does not close – the unvendored typeface (S13), unbounded list pagination (deferred as a new capability), and `settings.html:52`'s em-dash option (S11) – are recorded in Implementation Observations with their reasons – the preferred write-back location; S14's ledger sweep reads the whole canonical FIS as a safety net, but a prose-only deferral relies on that net rather than the supported path.
- [x] Any canon rule this story reported rather than wrote (`.shell` / `.content-area` row sizing, `.skip-link`) is recorded in Implementation Observations with S01 named as the owner, whether or not S01 had shipped it in time.


## Implementation Observations

#### DECISION NOTE: s16.absent-value-render-contract

Decision-Key: s16.absent-value-render-contract
Altitude: FIS
Affected surface: Shared absent-value helper and every Dart/Trellis consumer in the formatting sweep
Decision: Return typed absence state plus the original value; templates emit static absent markup or render the preserved value with `tl:text`; non-empty values never use `tl:utext`.
Rationale: Keeps the absent treatment reusable without widening the trusted-HTML boundary or risking user-controlled markup execution.
Evidence: User ratified the recommended preflight option on 2026-07-26.

### Run: 2026-07-30 00:10 UTC – observations

#### HOIST REQUESTS TO S01 (reported, not written — canon is closed after P1)

- **`.shell` / `.content-area` row sizing and `.skip-link` — ALREADY SHIPPED.** Both TI01 and TI02 presence checks passed at story entry: `design-system.css:128` carries `grid-template-rows: var(--topbar-h) minmax(0, 1fr)`, `:1811` carries `.content-area { min-height: 0 }` with no inert `flex: 1`, and `:79-99` carries the focus-revealed `.skip-link` at `var(--z-overlay)`. No hoist outstanding; recorded because the FIS requires the disposition either way.

- **OPEN — sidebar placeholder has no canon home (blocks one eighth of TI04's Verify).** TI04 requires all eight bespoke class names absent from `app.css`. Seven are gone. `.sidebar-placeholder` retains a **one-declaration, geometry-only** rule (`padding: var(--sp-1) var(--sp-4) var(--sp-2)`); its colour, size and italic affectation — the parts that made it a ninth empty-state treatment — are deleted and composed from canon `.text-muted` + `.t-caption` at the two call sites (`sidebar.html:24, :91`).
  Why it could not be collapsed: canon ships exactly one `.empty-state` (page-level, `padding: var(--sp-12) var(--sp-4)`, centred flex). Applying it to a one-line sidebar rail placeholder is visually wrong, and `.text-muted` alone supplies no rail gutter. Measured live at 1440×900: with the rule deleted the placeholder text sits at x=0 while every sibling (`.sidebar-section-label`, `.sidebar-nav-item`) sits at x=16 — a visible 16px misalignment. With the rule restored both measure x=16.
  `docs/wireframes/ux-spec-empty-states.md#design-principles` names two shapes ("centred layout for page-level empties, **placeholder rows for list/table empties**"); canon implements only the first. **Owner: S01 (sidebar chrome).** Shipping the deletion without the canon rule would have traded a duplicate for a visible defect, so the rule was retained and the gap reported per the Execution Contract.

#### DEFERRALS (no target milestone)

- **Unbounded list pagination.** The page handlers render every row with no page-size cap. Bounding a list is a new UX capability and needs handler changes, both barred by the PRD. Deferred to the release glitch ledger.
- **Unvendored JetBrains Mono.** `layout.html:12` still fetches the typeface from Google Fonts. FR8 / **S13** owns all three CDN assets together; splitting the font from htmx and marked would leave `layout.html` half-migrated.
- **`settings.html:52`'s `<option value="">—</option>`.** An em dash in a disabled select's only option — an absent-value rendering, but `settings.html` is **S11**'s template and this story's carve-out covers only the `.dart` call sites TI08 and TI09 name. `settings.html` is byte-unchanged (`cmp -s` against the story-entry snapshot).

#### DISPOSITIONS AND BOUNDARY CROSSINGS

- **`settings.html:424` keeps a now-dead `provider-empty-state` class — for S11.** The `app.css` rule is deleted per TI04, but the markup could not be swapped: Final Validation item 3 and the orchestrator both freeze `settings.html` byte-for-byte for S11. The element also carries `.card`, whose `padding: var(--sp-4)` is byte-identical to what the deleted rule supplied, so the only lost declaration is `color: var(--fg-sub0)`. Unreachable in the seeded profile (renders only when `hasProviders` is false). **S11 swaps the class to `.empty-state`.**
- **`.page-content` gained `position: relative`, which TI01 did not name — and it is the actual fix.** `min-height: 0` alone left `/memory` at a 1340px document on a 900px viewport. Root cause, isolated live: a scroll container only clips absolutely-positioned descendants for which it is the *containing block*. `.page-content` was `position: static`, so every `<caption class="sr-only">` (canon `.sr-only` is `position: absolute`) escaped to the initial containing block and stretched the root scroller. Bisected to `caption.sr-only` at document y=1339; `contain: paint` and `position: relative` both fixed it, `overflow: hidden` did not. All nine surfaces now measure exactly 900.
  **Latent parity gap for S01:** canon `.content-area` (`design-system.css:1811`) is the same shape — `overflow-y: auto`, `position: static` — and carries the identical latent defect. No `.content-area` surface exhibits it today (all four measured 900), so this is recorded as a parity note rather than an active defect. The app-side half was fixed here; the canon half is S01's if it is ever taken.
- **`#nav-progress` is deliberately outside the `data-connection` animation gate.** The gate is scoped to `.shell[data-connection="lost"] …`, and the navigation scan-bar is a sibling of the shell. Verified live: while disconnected, in-shell `.status-dot--live` and `.scan-bar` stop while `#nav-progress` keeps sweeping. That is correct — it reports an HTTP request that really is in flight, not a claim about stream freshness. Documented in the `app.css` comment so it does not read as an oversight.
- **`pageHeader` ships with no caller, by design.** TI03 builds the fragment; per-surface adoption belongs to S08–S12 and S15. It is proven through `components.dart#pageHeaderTemplate` in `render_test.dart`, not through a surface template.
- **`pageHeader`'s action slot is raw server-owned HTML, so the "verb+noun, `data-icon="plus"`" rule is a documented contract, not an enforced emit.** Acceptance Scenario S02 phrases it as though the fragment renders the labels. It cannot: the three real adopters need arbitrary markup (`projects.html` a button with Stimulus attributes, `knowledge_hub.html` a `.read-only-marker` span). A structured label/icon parameter would not express those, and a second slot beside the raw one is the anti-pattern TI04 bans. The contract is written into the `pageHeaderTemplate` dartdoc. The two surviving literal `"+ "` labels are `scheduling.html:32,118` (**S08**) and `components.html#emptyAppState:17` (**S12**) — neither is this story's.
- **`.pagehead-actions` is one new app-local rule** (`display: flex; align-items: center; gap: var(--sp-2)`). Without it a multi-action slot has no spacing. `.pagehead` itself is app-local and pre-existing; no canon rule is shadowed.
- **Eight bespoke empty classes were collapsed onto two canon shapes, not one.** TI04 says "collapse onto canon `.empty-state`", but canon's `.empty-state` is page-level. Panel-level empties took it (`.knowledge-empty-state`, `.tl-empty-state`, `.table-empty-cell`); inline one-line placeholders took canon `.text-muted` (`.allowlist-empty`, `.pairing-empty`, `.task-artifact-empty`), which is the same vocabulary TI04 itself prescribes for the `.empty-state-text` migration. `.empty-state-icon` became canon's `.icon` + `aria-hidden="true"`, which is what exposes the canon accent-glow rule TI04 wanted un-shadowed.
- **`.empty-state-text` → `.text-muted` moved 14 sites across S08/S15 surfaces**, as TI04 names explicitly. `.task-type-guidance .empty-state-text` in `app.css` followed its consumer to `.task-type-guidance .text-muted`.
- **`memory_dashboard.dart`'s `_formatDate` was folded into the shared helper too.** TI08 names only `:158` (`formatLocalDateTime`), but `_formatDate` (`:160`) was a third format (`YYYY-MM-DD`) in the same file. Leaving it would have left OC04's "one timestamp format" false inside a single template.
- **`session_info.dart`'s `inputStr` / `outputStr` / `totalStr` were deleted, not converted.** TI09 lists them as em-dash sites, but no template reads them — only `tokenMetricCardsHtml` renders. Dead context keys carrying a banned rendering; deleted rather than laundered. `render_test.dart` fixtures still pass them harmlessly.
- **`scheduling.dart`'s `intervalDisplay` was deleted for the same reason** — an em-dash context key `scheduling.html` never reads.
- **Two composed labels get a determinate string, not the absent treatment.** `task_timeline.dart:92,94` and `tasks.dart:325` embedded `?? 'unknown'` inside a sentence ("Status → unknown") or a status badge. An empty `.value-absent` inside a badge is meaningless, so a `statusChanged` event with no recorded target now reads **"Status changed"** — true and determinate, the same reasoning as TI09's sanctioned `binaryStatusLabel` "Not found" exemption. Both route through `absentValue`; zero `?? 'unknown'` literals remain.
- **`settings_page.dart:142` renders absence through the existing `versionClass` hook.** `settings.html:390` already carries `tl:classappend="${provider.versionClass}"`, so an unreported provider version emits `class="detail-value value-absent"` with empty content and canon's `:empty::before` supplies the dash — no edit to the frozen template. `:139`'s `binaryStatusLabel` "Not found" stays, per the FIS exemption.
- **`health_page.dart:50,54` and `settings_page.dart:76,77` now default to `''` rather than `'unknown'`.** Both read `worker_state` / `version` from the server's own health map, which the server always populates, so the absent branch is defensive. `health_dashboard.html` branches on it and renders `.value-absent`; `settings.html:461` cannot (frozen) and would render blank in that unreachable case — **recorded for S11**. `settings.dart`'s `workerState` parameter is dead (accepted but never placed in the template context) — **noticed, not touched**, S11's to remove.
- **`kg_timeline.html:26`'s `placeholder="2026-01-15T00:00:00Z"` is untouched**, per TI08's boundary: it is the format hint for the operator-supplied `as_of` filter, not a rendered timestamp.
- **`restart_banner.html` is untouched** (`cmp -s` clean). Both buttons still lack the base `.btn`; the defect is assigned whole to **S12**.

#### NOTICED BUT NOT TOUCHING

- **`.value-absent` loses specificity inside a metric card.** Canon `.value-absent` (0,1,0) is overridden by canon `.card-metric--info .metric-value` (0,2,0), so `/scheduling`'s disabled-heartbeat interval renders the en dash in the metric's accent blue rather than `--fg-sub0`. Legible and unambiguous, but not the muted treatment canon intends. Both rules are canon, so the fix belongs there, not in an `app.css` shadow. Low severity — flagged for **S03/S14**.
- **Container-class swaps left content structure to the owning surface story.** `.tl-empty-state`, `.knowledge-empty-state` and `.table-empty-cell` now render canon `.empty-state`, but their bodies are still a bare muted `<span>` with no `.empty-state-title` and no icon. Canon's layout applies; the title/icon/action content is each surface story's sweep (**S08**, **S10**).
- **SSE could not be exercised in the headless harness.** `EventSource` fired neither `open` nor `error` over 8s in headless Chromium even though the server logged `200 GET /api/events`, so TI05's disconnection path was proven in two halves instead: the listener wiring by source contract (`app_js_test.dart`), and the resulting state — `data-connection` attribute, `.banner.banner-warning`, animation gating, restore, and `prefers-reduced-motion` independence — by driving the DOM to the exact state `setConnectionState('lost')` produces. The htmx failure half was exercised for real (a forced 404 and a bogus archive POST each produced exactly one toast).

#### VERIFY RE-TARGETS (FIS targets were stale on arrival)

- **TI10's named anchor controls no longer exist.** The FIS asks for `a.tab-btn`, `a.pager-link` and `.settings-tab`; S05 folded both tab bars onto canon `.tabs`/`.tab` and canon's pager anchors are plain `.btn.btn-ghost` (`design-system.css:2986`). The `:is()` selector was written against the as-built controls: `:is(.topbar-back, .card-link, .guard-audit-link, .tabs a.tab, .pager a)`. Measured at 768px: tab anchors 48px (were ~28px), pager anchor 48px, and a narrow `<button>` now 24px wide with `min-width: 0`.
- **`app.css` line numbers were stale throughout** (S05/S06/S07 shifted the file). Every target was re-inventoried by selector. `.empty-state-title` needed no deletion — S05 had already removed it; only `.empty-state-icon` and `.empty-state-text` remained of the app-local family.
- **`health_dashboard.dart`'s private relative-time helper is `_formatLastPull`, not the `_relative` at `:180-188`** the FIS names. Same defect (a fourth implementation with its own `'unknown'` catch); deleted.

#### FINAL VALIDATION ITEM 1 — three test files beyond the named list

Item 1 permits `test/templates/{helpers_test.dart,render_test.dart}` and `test/static/app_js_test.dart`. Three further test files were edited because their assertions pinned the exact strings this story is chartered to change; none could stay unedited:

- `test/templates/scheduling_test.dart` — two assertions matched `metric-value">Active</div>` / `">Disabled</div>`. TI03 adds `.t-metric` to the shared `metricCard` value element, so the class attribute is now `metric-value t-metric`.
- `test/templates/health_dashboard_test.dart` — asserted `contains('ago')` for a `2020-01-01` fixture, with the comment "Use a timestamp far in the past so the relative display is 'Xd ago'". TI08 rolls over to an absolute date past 30 days; the assertion is now `1 Jan 2020` plus `isNot(contains('ago'))`, and the test name says so.
- `test/templates/memory_dashboard_test.dart` — asserted `contains('2026-03-01')`, the raw `YYYY-MM-DD` this template printed via its own `_formatDate`. Now `1 Mar` plus `isNot(contains('2026-03-01'))`.

Two assertions inside the permitted `app_js_test.dart` were also re-pointed for the same reason: the bare `button, summary, [role="button"]` min-width rule TI10 removes, and the three anchor allow-lists TI10 merges. A third, `expect(appCss, isNot(contains('.status-dot--live::before')))`, was anchored to `^` — it guards against `app.css` re-declaring canon's live-dot treatment, and TI05's `.shell[data-connection="lost"] .status-dot--live::before` is a state gate over canon's animation, not a second definition of it.

### Run: 2026-07-30 00:22 UTC – observations

#### SPEC AMENDMENT — Final Validation item 1 widened to the verified as-built delta

Opens and closes ledger entry `S16-FINAL-CHECKLIST-TEST-FILES`. Applied identically to the public bundle copy and the private canonical copy.

**Tooling note on the write path.** Applied as a direct edit plus this audit record, *not* through `andthen:ops update-fis … design-change`. That form is scoped to Intent and Acceptance-Scenario text only and explicitly must not edit Structural Criteria, task checkboxes, plan provenance or Implementation Observations; the Final Validation Checklist is outside its writable region, so invoking it here is a guaranteed `BLOCKED: invalid design-change body` no-op. The exact spans are reproduced below so this record carries the auditability the form would have.

**Item 1 — Old:**

```
- [x] No file outside `packages/dartclaw_server/lib/src/static/` (`app.css` and `controllers/`), `packages/dartclaw_server/lib/src/templates/`, `packages/dartclaw_server/lib/src/web/pages/`, `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart`, `packages/dartclaw_server/test/templates/{helpers_test.dart,render_test.dart}`, `packages/dartclaw_server/test/static/app_js_test.dart` and `dev/design-system/DESIGN.md` is modified – no service, schema, route or API change. The workflow package's generated asset file remains byte-unchanged because S16 edits no workflow embed root.
```

**Item 1 — New:**

```
- [x] No file outside `packages/dartclaw_server/lib/src/static/` (`app.css` and `controllers/`), `packages/dartclaw_server/lib/src/templates/`, `packages/dartclaw_server/lib/src/web/pages/`, `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart`, `packages/dartclaw_server/test/templates/{helpers_test.dart,render_test.dart}`, `packages/dartclaw_server/test/static/app_js_test.dart`, the three test files whose assertions pinned strings this story is chartered to change (`packages/dartclaw_server/test/templates/{scheduling_test.dart,health_dashboard_test.dart,memory_dashboard_test.dart}` — `metric-value` class list per TI03, and the two timestamp formats per TI08) and `dev/design-system/DESIGN.md` is modified – no service, schema, route or API change. The workflow package's generated asset file remains byte-unchanged because S16 edits no workflow embed root.
```

**Why the checklist was the stale side, not the implementation.** Each of the three test files asserted on a literal string that a task in this story is required to change, so none could remain unedited while its task closed:

1. `scheduling_test.dart` asserted `contains('metric-value">Active</div>')` and `">Disabled</div>'`. TI03 requires `.t-metric` on the shared `metricCard` value element, making the emitted attribute `class="metric-value t-metric"`. The assertions were re-pointed, not relaxed.
2. `health_dashboard_test.dart` asserted `contains('ago')` against a `2020-01-01` fixture, with the in-test comment "Use a timestamp far in the past so the relative display is 'Xd ago'". TI08 rolls over to an absolute short date past 30 elapsed days, so the old assertion encoded precisely the behaviour TI08 removes. Now `contains('1 Jan 2020')` plus `isNot(contains('ago'))`, with the test renamed to state the new contract.
3. `memory_dashboard_test.dart` asserted `contains('2026-03-01')` — the raw `YYYY-MM-DD` produced by `memory_dashboard.dart`'s private `_formatDate`, a third timestamp format in a file TI08 routes through the shared helper. Now `contains('1 Mar')` plus `isNot(contains('2026-03-01'))`.

**Evidence the as-built delta is minimal.** Each edit is an assertion re-point plus, in two cases, a `isNot(...)` guard that fails if the old format returns. No test was deleted, skipped or weakened, and each remains mutation-sensitive: reverting the corresponding production change turns it red. The full `dart test packages/dartclaw_server` suite passes (3028 passed, 3 skipped).

**No scope was widened.** The amendment records what TI03 and TI08 already required. `settings.html` and `restart_banner.html` remain byte-identical to the story-entry snapshot (`cmp -s` clean), and the three drift-checked canon files and their served copies are unchanged.

### Run: 2026-07-30 00:45 UTC – observations

#### CORRECTION — both hoist requests were GRANTED mid-run; TI04 now closes 8-of-8

The first observations block above records `.sidebar-placeholder` as an **OPEN** hoist request against S01 and the `.content-area` containing-block gap as a latent parity note. **Both were shipped into canon while this story was still executing**, so those two entries are stale. Canon `components.css` now carries:

```
/* Empty-rail row. Canon's .empty-state is the centred page-level shape; a rail
   empty is a row, and its horizontal padding must equal the rail rows' (--sp-4)
   or the text hangs 16px left of every sibling. Colour and type compose from
   .text-muted + .t-caption at the call site. */
.sidebar-placeholder { padding: var(--sp-1) var(--sp-4) var(--sp-2); }
```

and `.content-area` gained `position: relative` with the containing-block rationale.

Consequences applied here:

- The geometry-only `.sidebar-placeholder` rule this story had retained in `app.css` became a genuine duplicate of a canon rule and was **deleted**. TI04's Verify now passes for **all eight** bespoke class names, not seven. Re-measured live at 1440×900: placeholder text and the `Channels` section label both sit at x=16, padding resolves to `4px 16px 8px` from canon, caption size 12px, italic gone.
- `.page-content`'s `position: relative` (app-owned) and canon's `.content-area` are now at parity, so the `.sr-only`-escape defect is closed on both scroll containers rather than only the app-local one.
- **No canon edit was made by this story.** The drift check passes and the served copies match canon; the `dev/design-system/` delta in the working tree is the hoist, authored by its owner.

#### REVIEW REMEDIATION — findings accepted and fixed after the quick-review pass

A fresh-context adversarial review found no CRITICAL issues, one HIGH and several MEDIUM/LOW. Accepted findings routed to Fix were remediated in one pass; the ordered gate sequence was restarted from the targeted checks afterwards and closed green (3031 passed, 3 skipped).

**Fixed:**

- **Five bare em-dash absent renderings survived in the shared formatting layer** — `tasks.dart:98,142,160` (`finalTokenDisplay`, `createdByDisplay`) and `task_detail.dart:144,203` (`createdByDisplay`, `reasonLabel`). Acceptance Scenario S05 bans the bare em dash across that layer, but TI09's two Verify greps were blind to them: the pattern grep matches only `'unknown'` / `'N/A'` / `'--'` forms, and the `u2014` grep is scoped to three files. `task_detail.dart:203` was the byte-identical twin of the `session_info.dart` turn-status site this story *did* convert, so the same field rendered two ways depending on the page. All five now route through `absentValue` with template branches in `tasks.html`, `task_detail.html` and `chat.html`.
- **The SSE disconnection banner was silent on both pairing pages.** The host query was `'.chat-area, .content-area, .page-content'`, which misses `.pairing-main` (`whatsapp_pairing.html:4`, `signal_pairing.html:4`). Both pages render the sidebar, so the global EventSource runs there and the operator would have got no message. Replaced with `document.getElementById('main-content')` — the one hook every shell body already carries, which cannot drift as new surface classes appear.
- **Four rendered timestamps lacked the `title="<ISO>"` disclosure Scenario S05 requires**, and for three of them the source ISO was not even in the template context, so a later sweep could not have added it without re-touching the `.dart` file: `memory_dashboard` `prunerNextRun`, `memoryMdOldest`, `memoryMdNewest` and the pruner-history `date` column. All four now carry `*Iso` context keys and `tl:attr="title=…"`.
- **The archive `htmx.ajax` promise lost its rejection handler.** Removing the archive-local `bindHtmxRequestErrors` also removed `cleanup`, which had been the promise's second `.then` arm; the send-error path TI05's own Verify exercises would have logged an unhandled rejection alongside its toast. Restored as an explicit no-op arm, with failure reporting left to the global listeners.
- **The body-level `hx-indicator` made the navigation scan-bar sweep on the two pairing polls.** `layout.html`'s `hx-indicator="#nav-progress"` is inherited document-wide; the three polls TI07 names override it but the pairing polls (`every 10s`) did not, so the under-topbar bar pulsed every ten seconds asserting a navigation that was not happening. Both polls now carry `hx-indicator="closest .pairing-main"`.
- **The absent-value *render* path had no test at all** — `value-absent` appeared nowhere under `test/`. `helpers_test.dart` proved the record type, but nothing proved the markup half six stories consume: a typo in `components.html`'s `tl:classappend` ternary or a misnamed `valueAbsent` context key would have shipped green. Added a `metricCardTemplate(value: null)` case asserting the emitted class and empty value, plus `0` and `'0'` cases asserting the absent class is *not* applied.
- **`formatRelativeTimeIso` and `isoTitle` had no unit tests**, although every converted call site depends on their null / empty / unparseable contract. Added a group covering all three inputs plus the parseable case.
- **Two story-ID leaks in non-planning files**, both authored by this story and both banned by the vital conventions: an `app.css` comment naming S01 and a `render_test.dart` comment naming S12. Reworded to name the thing, not the story.

**Accepted but NOT fixed — recorded for their owners:**

- **`audit_table.dart:190` renders a fifth private timestamp format** (`"Mar 20 14:05"` — month-name absolute, no relative rollover, no ISO title) in a file this story edited for TI09. OC04's "one timestamp format governs the whole product" therefore closes with residue. Not converted here because an audit log may legitimately want dense absolute times including time-of-day, which `formatRelativeTime` drops — that is a product call, not a mechanical fix. **Owner: S09** (health/audit surfaces), or S14's ledger if S09 declines it.
- **Repeated poll failures now produce a rolling toast per cycle.** The body-level listeners toast unconditionally with no dedup, so during an outage a `hx-trigger="every 30s"` (memory) or `every 10s` (pairing) page stacks an identical "Could not reach the server" toast each cycle, on top of the disconnection banner that already states the condition once. TI05 designed exactly-once for a *single* failure and never considered the repeating-poll path. The mitigation (suppress consecutive duplicates, exempt `every` triggers, or accept the noise) is a design decision, so it is recorded rather than guessed. **Owner: S14 / release ledger.**
- **Poll skeletons cause a periodic layout shift.** `.poll-skeleton` toggles `display` on `.htmx-request` above already-rendered content, so each refresh cycle inserts the placeholder and pushes live content down for the request's duration. TI07 frames skeletons as a first-payload treatment, but these fragments arrive server-rendered, so there is no first-payload gap — only recurring mid-read movement. An overlay/opacity treatment or reserved space would fix it; which one is a design decision. **Owner: S09** (health + memory dashboards).
- **The same-year absolute-date assertion is vacuous for roughly the first five weeks of each year.** `helpers_test.dart`'s year-omission case is guarded by `if (now.difference(sameYear).inDays > 30)`, which no same-year date satisfies before about 4 February, so a regression merged in January would pass CI. The clean fix is an injectable `now` on `formatRelativeTime`, which widens a shared signature six stories consume — deliberately not taken mid-sweep. **Owner: S14.**

#### FINAL VALIDATION ITEM 1 — one further test file beyond the amended list

`packages/dartclaw_server/test/templates/tasks_s11_test.dart` was edited during review remediation, extending the amendment recorded above by one file. Two of its cases asserted `contains('—')` for a task with no token events — the literal em dash the HIGH finding required removing. Both now assert the canon `value-absent` treatment and additionally assert the em dash is gone, so they fail if the old rendering returns. The same reasoning applies as for the other three: the assertion pinned a string this story is chartered to change.

### Run: 2026-07-30 00:52 UTC – observations

#### CORRECTION — the `.content-area` containing-block gap was LIVE, not latent, and the surface count was wrong

The first observations block recorded the canon `.content-area` half of the scroll-containment defect as *"a latent parity gap … No `.content-area` surface exhibits it today (all four measured 900), so this is recorded as a parity note rather than an active defect."* **Both halves of that sentence are wrong**, and S01 caught it while landing the hoist. Corrected for S14's ledger:

- **It was live.** `/settings/channels/whatsapp` stretched the root scroller to **942px on a 900px viewport**. Two `<label class="sr-only">` elements in `channel_detail.html` escaped the scroll clip exactly as the `<caption class="sr-only">` did on `.page-content`. S01's canon rule brings it to 900.
- **Six `.content-area` templates exist, not four**: `channel_detail.html`, `session_info.html`, `workflow_detail.html`, `health_dashboard.html`, `workflow_list.html`, `settings.html`. The earlier note counted *probed surfaces*, not templates, and said "four" for both.
- **Why the original sweep missed it.** The defect only manifests when the scroll container has an absolutely-positioned descendant. Re-measured after the fix: of the six templates, only the two channel-detail surfaces carry `.sr-only` descendants inside `#main-content` (2 each); `workflow_list`, `settings`, `health_dashboard` and `session_info` carry zero. The original nine-surface sweep happened to include only zero-`sr-only` `.content-area` pages, so every one of them measured 900 and the wrong conclusion followed. **A clean measurement on a surface that cannot exhibit a defect is not evidence of absence** — the sweep should have been driven by the precondition (does this scroll container have a positioned descendant?), not by page list.

Post-fix verification, all at 1440×900, `document.documentElement.scrollHeight` vs viewport:

| Surface | Scroller | `position` | `.sr-only` inside | Doc height |
|---|---|---|---|---|
| `/settings/channels/whatsapp` | `.content-area` | `relative` | 2 | 900 |
| `/settings/channels/signal` | `.content-area` | `relative` | 2 | 900 |
| `/workflows` | `.content-area` | `relative` | 0 | 900 |
| `/settings` | `.content-area` | `relative` | 0 | 900 |
| `/health-dashboard` | `.content-area` | `relative` | 0 | 900 |
| `/session-info` | (fragment) | – | 0 | 900 |

#### CONFIRMATION — app-local `.sidebar-placeholder` deleted, alignment re-verified against canon alone

Re-verified at 1440×900 after the `app.css` rule was removed and with canon as the only source: placeholder text renders at **x=16**, identical to the `.sidebar-section-label` above it; padding resolves to `4px 16px 8px` from canon `components.css`; type is 12px `--fg-sub0` via `.text-muted` + `.t-caption`; the italic affectation stays gone. TI04's Verify passes for **all eight** bespoke class names in `app.css`.

#### NOTICED BUT NOT TOUCHING — 2px rail offset between the placeholder and session rows

S01 recorded, and this story confirms: placeholder text sits at x=16 while `.session-item` row text sits at x=18. Measured cause is `.session-item`'s **2px transparent `border-left`** (the reserved active-state accent), which insets its content by 2px relative to rows without one. Both the placeholder and the section labels are consistent with each other at x=16; it is the session rows that are the outlier. Whether the rail should reserve that 2px on every row or none is a rail-design decision. **Owner: S12** (shell/sidebar surface). Not this story's to settle.
