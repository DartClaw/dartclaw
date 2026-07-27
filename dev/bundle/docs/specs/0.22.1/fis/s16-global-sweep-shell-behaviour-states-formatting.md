# FIS: Global sweep — shell behaviour, states and formatting

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S16

> **Split note**: S07 and S16 were one story until it reached 18 tasks. S07 keeps the type, colour and CSS-token work and runs immediately before this story; S16 takes the shared Trellis fragments, shell behaviour, states and data formatting. The two halves share `app.css`, `topbar.html` and `components.html` — see the Execution Contract.

**All shell commands in this file run from the `dartclaw-public` repo root.** A path rooted anywhere else makes `rg` exit 2 and read as a pass.

## Feature Overview and Goal

**Intent**: Six per-surface sweeps run in parallel immediately after this story, and each one needs a page header, an empty state, a timestamp, an absent value and a failure treatment. If those shapes do not exist first, six stories invent six of each — which is exactly how the audit came to hold six page-header treatments, eight empty-state classes and four timestamp formats. This story builds each shape once, in the shared layer, so the sweeps adopt rather than re-invent.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor to these):

- [OC01] The shell holds together: a long page scrolls inside it instead of overflowing it, the topbar carries the page `<h1>`, the first Tab stop is a working skip link, and the shared anchor-based controls meet the 48px touch target at 768px.
- [OC02] Shared page scaffolding is one implementation: one `pageHeader` fragment and one `.empty-state` implementation, both rendered from the shared layer, so the six parallel surface sweeps adopt rather than re-invent.
- [OC03] Failures and progress are legible: a failed request, a dropped live stream and an in-flight navigation are visible to the operator, and a success toast survives the navigation that follows it.
- [OC04] Data is legible: one timestamp format and one absent-value treatment govern the whole product, and a legitimate `0` still renders as `0`.


## Required Context

### From `plan.json` – sharedDecisions: "Canon-first, and canon closes after P1"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes, because the check pins a sha256 on line 2 of each served copy and concurrent edits in the parallel P3 wave conflict on that line by construction. […] A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked.

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
> Every deferral is written back to the CANONICAL private FIS at `dartclaw-private/docs/specs/0.22.1/fis/`, not only to the bundle copy, and S14 consolidates them into `dartclaw-private/docs/specs/0.22.1/glitch-ledger.md`. Stories that record deferrals in prose (a `What We're NOT Doing` bullet) must also land them in Implementation Observations, because that is the only block S14 reads.

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
- `docs/specs/0.22.1/canon-hoist-manifest.md` – the authority for which canon rule belongs to which P1 story. This story's two hoist requests — the `.shell` / `.content-area` row sizing (TI01) and `.skip-link` (TI02), both to S01 as chrome — belong in its table; neither is listed there yet, so confirm before starting either task.
- `docs/specs/0.22.1/fis/s07-global-sweep-type-adoption-formatting.md` – the type half, which runs immediately before this story on the same `app.css`, `topbar.html` and `components.html`. Its Implementation Observations carry the dispositions and hoist requests this story must not re-open.
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
  - **And** the first Tab stop is a visible "Skip to content" link that moves focus to `#main-content`, and the shared topbar fragment renders its page title as an `<h1>` — the six per-surface templates that carry their own in-page `<h1>` are untouched here and no seventh appears
  - **And** at 768px the anchor-based tab and pager controls measure ≥ 48px tall, while a narrow inline chip is no longer stretched to a 48px minimum width

- [ ] **S02 [OC02] [TI03,TI04] One page header and one empty state exist for the six sweeps to adopt**
  - **Given** the six competing page-header treatments and eight bespoke empty-state classes the audit catalogued, and the shared fragments in `templates/components.html`
  - **When** the `pageHeader` and `emptyState` fragments are rendered on their own
  - **Then** `pageHeader` emits `<header class="pagehead">` with a `.t-page-title` heading, an optional subtitle and a right-aligned action slot, and its action labels read verb+noun with `data-icon="plus"` rather than a literal `"+ "`
  - **And** `emptyState` renders icon + `.empty-state-title` + body copy + optional action with the canon accent-glow icon treatment applying, and no bespoke empty-state class is left in `app.css`

- [ ] **S03 [OC03] [TI05] A failed request and a dropped live stream announce themselves**
  - **Given** the sidebar's `hx-get` link to a session that has since been deleted, and an `/api/events` stream that the server closes
  - **When** the operator clicks the stale link, and separately when the stream drops
  - **Then** the 404 surfaces an error toast carrying the server's message instead of the click producing no visible change at all
  - **And** the shell marks itself `data-connection="lost"`, shows a `.banner.banner-warning` naming the disconnection, and stops the `.status-dot--live` pulse and `.scan-bar` sweeps until the next successful `open` clears it — without bypassing the `prefers-reduced-motion` handling already in canon

- [ ] **S04 [OC03] [TI06,TI07] Success is announced and in-flight work is visible**
  - **Given** the projects page, whose create/update/remove handlers currently reload the page and destroy any toast, and the 28 `hx-get` sites that today carry zero `hx-indicator`
  - **When** a project is removed, and separately when a sidebar navigation is in flight
  - **Then** a success toast is queued before the navigation and shown after the new page connects, so the mutation reports success rather than only changing the page underneath, and a second navigation shows no repeat toast
  - **And** the in-flight navigation shows a `.scan-bar` under the topbar, and a polling fragment shows `.skeleton` placeholders instead of popping in

- [ ] **S05 [OC04] [TI08,TI09] One timestamp format and one absent value — and a real zero stays a zero**
  - **Given** seeded data containing a task created 129 days ago, a session whose `createdAt` renders today as `2026-04-15T10:00:00.000`, a workflow definition with **0** steps, and a task whose `startedAt` is null
  - **When** `/tasks`, `/session-info`, `/workflows` and `/memory` render
  - **Then** the 129-day value renders as an absolute short date, every timestamp carries a `title` attribute with its ISO value, and no surface prints raw ISO-8601 with milliseconds
  - **And** the null `startedAt` renders the canon `.value-absent` treatment while the workflow's step count renders `0` — the helper converts null and empty to the absent treatment and never converts a legitimate `0` or a non-empty string
  - **And** `--`, `N/A`, `unknown` and the bare em dash no longer appear as absent-value renderings in the shared formatting layer


## Structural Criteria

- [ ] `dev/tools/fitness/check_design_system_sync.sh` exits 0 at the story boundary. This story edits no drift-checked canon file — `DESIGN.md` is the only `dev/design-system/` file it writes, and that one is prose, never synced — so the check must be green exactly as S07 left it. A red check means S07's re-sync did not land, not that this story drifted.
- [ ] No canon rule is authored or edited in `tokens.css`, `components.css` or `icons.css`. The two canon rules this story needs (`.shell` / `.content-area` row sizing, and a `.skip-link`) are hoist requests against S01, not edits made here.
- [ ] No new runtime JS dependency and no build step: the new shell behaviours are plain ES-module code in the existing `controllers/` files, registered per `CONVENTIONS.md`.
- [ ] Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` are **introduced** in `lib/src/static/controllers/`. The five that exist today are S06's to remove, and S06 runs in parallel — this story asserts only on its own added lines.
- [ ] `embedded_assets.g.dart` is not regenerated: `dart run dev/tools/embed_assets.dart` is S14's single run and is not executed here.
- [ ] `dart analyze` is clean and `dart test packages/dartclaw_server/test/templates/helpers_test.dart` passes for the new `formatRelativeTime` and absent-value groups.


## Scope & Boundaries

### Outputs the six W2 sweeps consume

These are contracts, not internals — S08, S09, S10, S11, S12 and S15 all depend on them, so a defect here propagates six ways. Each is named by the task that ships it:

| Output | Shipped by | Consumed for |
|---|---|---|
| `pageHeader` fragment (`components.html` + `components.dart`) | TI03 | Every non-chat surface replaces its own header treatment with this |
| Single `.empty-state` implementation + `emptyState` fragment with title and action slots | TI04 | Every surface's empty state |
| `helpers.dart#formatRelativeTime` with weeks/months/years rollover and `title="<ISO>"` disclosure | TI08 | Every timestamp on every surface |
| The absent-value helper in `helpers.dart` rendering canon `.value-absent` | TI09 | Every null/empty field rendering |
| `shared.js#queueToast` | TI06 | Any sweep whose mutation navigates or reloads |
| Body-level `htmx:responseError` / `htmx:sendError` handlers in `dc_shell_controller.js` | TI05 | All 28 `hx-get` sites, with no per-template wiring |
| The shell's `data-connection` state and its animation gating | TI05 | Any surface rendering `.status-dot--live` or `.scan-bar` |

### Work Areas
- `packages/dartclaw_server/lib/src/static/app.css` — `.page-content` (:598) row sizing, the eight bespoke empty-state classes and the app-local `.empty-state-icon/-title/-text` family (:1808-1810), the `.skip-link` rule, and the 768px touch-target block (:3755-3795).
- Shared Trellis/Dart fragments — `templates/components.html` + `components.dart` (`emptyState`, new `pageHeader`), `templates/topbar.html` (the `<h1>` promotion), `templates/layout.html` (the skip-link anchor).
- Shared controller layer — `static/controllers/dc_shell_controller.js`, `controllers/dc_projects_controller.js` and `controllers/shared.js`: global htmx failure handling, SSE disconnection state, toast handoff across navigation, loading indicators.
- Shared formatting layer — `templates/helpers.dart` (`formatRelativeTime`, new absent-value helper) and the call sites in `templates/*.dart` and `web/pages/*.dart` that today render their own timestamp or absent value.
- Tests — `packages/dartclaw_server/test/templates/helpers_test.dart` (an existing suite with `formatUptime` and `formatBytes` groups; the new cases join it rather than starting a new file).
- `dev/design-system/DESIGN.md` — the page-title and skip-link contracts this story establishes. Not drift-checked, so writing it here is legal; S14 reconciles the whole document at release close.

### What We're NOT Doing
- The type, colour and `--z-*` work -- S07 owns it and runs immediately before this story. Do not re-migrate a `--text-sm` site, retier an `--fg-overlay` rule, rebase a badge or touch a `z-index`.
- Adding or editing any rule in canon `tokens.css` / `components.css` / `icons.css`. Two rules this story needs are canon chrome and are **hoist requests against S01** (see TI01 and TI02); if S01 has not shipped them, the task stops and reports rather than adding them.
- Per-surface adoption of the `pageHeader` and `emptyState` fragments -- S08–S12 and S15 own each surface's own template edits, and the six run in parallel on those files. This story proves a fragment in its own render.
- Deleting the six in-page `<h1>`s that duplicate the promoted topbar title -- each belongs to its surface story (S10, S11, S15), and `login` keeps its own because it renders no topbar.
- `settings.html:52`'s `<option value="">—</option>` -- an em dash in a disabled select's only option. It is an absent-value rendering, but `settings.html` is S11's template and this story's carve-out covers only the `.dart` call sites named in TI08 and TI09. Recorded for S11.
- The restart banner's two buttons missing the base `.btn` class (`restart_banner.html:7,8`) -- the plan assigns the defect whole to S12, and fixing only "Restart Now" here would leave "Dismiss" as UA chrome behind a Verify that reads as closed.
- Self-hosting JetBrains Mono (the fifth `global` glitch) -- FR8 / S13 owns all three CDN assets together, and splitting the font from htmx and marked would leave `layout.html` half-migrated.
- Pagination and page-size caps on the unbounded page handlers -- bounding a list is a new UX capability and needs handler changes; recorded as a deferral against the release glitch ledger.
- Regenerating `embedded_assets.g.dart` -- S14 runs `dev/tools/embed_assets.dart` exactly once for the whole release.


## Architecture Decision

**Approach**: build every shared shape the six parallel surface sweeps consume — the page header, the empty state, the timestamp and absent-value helpers, the failure and loading treatments, and the shell's structural and keyboard fixes — in one serial pass between the type sweep and the surface fan-out.
**Why this over alternatives**: the alternative is each sweep inventing its own, which is precisely what produced the audit's six page-header treatments, eight empty-state classes and four timestamp implementations. Running this beside the sweeps rather than before them would put six parallel stories on `components.html`, `helpers.dart` and `app.css` at once.
**Why separate from S07 rather than one story**: the combined story reached 18 tasks across canon CSS, `app.css`, four shared Trellis fragments, two controllers, `helpers.dart` and Dart tests — past the single-session decomposition marker. The seam is clean: S07 is CSS-only with no runtime behaviour and no Dart; S16 is fragments, controllers and Dart with no type or token work. They overlap only on `app.css`, `topbar.html` and `components.html`, and running serially removes the conflict.


## Technical Overview


## Code Patterns & External References

```
# type | path#anchor or url                                                          | why needed (intent)
file   | packages/dartclaw_server/lib/src/static/controllers/shared.js#showToast       | Toast entry point TI05/TI06 reuse; `queueToast` is added beside it
file   | packages/dartclaw_server/lib/src/static/controllers/shared.js#readHtmxErrorMessage | Existing error-message extraction (:245) the global listener must reuse, not duplicate
file   | packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js#bindHtmxRequestErrors | The per-button listener pattern (:395) TI05 generalises to one body-level pair in `connect()`
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
- **Critical**: S06 runs in parallel in W1 and is removing the five native `confirm()` / `alert()` calls from `dc_shell_controller.js` (:369, :477, :488, :489, :491). A whole-file grep for those calls therefore cannot be evaluated deterministically at this story's boundary — it passes or fails on S06's timing, not on this story's work. TI05's Verify asserts on **added lines only**, against a pinned story-start commit.
- **Constraint**: `app.css` loads *after* `design-system.css` (`layout.html:16-17`), so equal-specificity app rules win. Deleting an `app.css` declaration exposes the canon rule underneath — confirm what surfaces before assuming a deletion is inert. This matters most in TI04, where removing the app-local `.empty-state-icon/-title/-text` family is the *point*: the canon accent-glow icon rule must become visible.
- **Constraint**: S07 has already edited `topbar.html`, `components.html` and `app.css` when this story starts. `topbar.html`'s two static titles carry an extra `t-page-title` class from S07 TI02, so any assertion about their class attribute must test for a class *in the list*, not for the whole attribute value.
- **Avoid**: editing a per-surface template to prove a shared fragment works. S08–S12 and S15 run in parallel on those files — prove a fragment in its own render, and leave adoption to the owning surface story.
- **Avoid**: converting a legitimate `0`, `'0'` or `false` to the absent treatment. `workflows_page.dart:110` (`totalSteps`) and `:125` (`progressPercent`) are computed zeros and are the guard cases the helper must leave alone, not sites to convert.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** A long page scrolls inside the shell instead of overflowing it
  - `app.css#.page-content` (:598) gains `min-height: 0`. Follow the already-correct canon `#.chat-area { min-height: 0 }` precedent.
  - **Hoist request (S01)**: the structural half is canon chrome and is not written here. Canon `dev/design-system/components.css#.shell` (:85) must change `grid-template-rows: var(--topbar-h) 1fr` to `var(--topbar-h) minmax(0, 1fr)`, and `#.content-area` (:1548) must gain `min-height: 0` and drop the inert `flex: 1`. Both belong to S01 (surfaces and chrome). Neither exists today.
  - **Verify**: `rg -n 'grid-template-rows:\s*var\(--topbar-h\) minmax\(0, 1fr\)' packages/dartclaw_server/lib/src/static/design-system.css` returns the `.shell` rule (it returns no matches today — note that a bare `minmax(0, 1fr)` grep passes vacuously, because `grid-template-columns` already uses it at :89 and :108) — if it returns nothing, S01 has not shipped the hoist and this task stops and reports rather than shadowing the rule from `app.css`; `rg -nU --multiline-dotall '^\.page-content[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg 'min-height:\s*0'` returns the declaration (returns nothing today); a full-page capture of `/memory` in the `visual` profile is exactly 1440×900 (it captures at 1440×1333 today) with the sidebar, its border and the ground gradient painted to the viewport bottom

- [ ] **TI02** The shared topbar fragment carries the page `<h1>`, and the shell has a working skip link
  - `templates/topbar.html` promotes its two static titles to `<h1>`, class list unchanged: `pageTopbar`'s `<span class="session-title-static …">` (:38) and `plainTopbar`'s `<span class="session-title …">` (:26). `sessionTopbar` is excluded: its title is an editable `<input class="session-title">` (:5), which cannot be an `<h1>`, and its archive variant (:4) is the read-only twin of that input, not a page title. `templates/layout.html` renders `<a class="skip-link" href="#main-content">Skip to content</a>` as `<body>`'s first child, before the `${body}` block (:36). Document the "topbar owns the page `<h1>`" contract in `DESIGN.md`, which is not drift-checked.
  - **Hoist request (S01)**: `.skip-link` does not exist anywhere in canon or the app. It is new shell chrome, so S01 must ship it into `components.css` as visually-hidden-until-focus. This story does not author it — canon is closed after P1.
  - **Ownership**: per the plan's `Shared-surface ownership in the sweep phase` decision this task asserts only what it owns — that the shared fragment emits an `<h1>` and that no NEW duplicate appears. It cannot assert one-per-page: six templates carry an in-page `<h1>` today (`channel_detail`, `kg_timeline`, `knowledge_hub`, `login`, `projects`, `settings`) and this story is barred from editing per-surface templates. Those deletions belong to S10 (`knowledge_hub`, `kg_timeline`, `channel_detail`), S11 (`settings`) and S15 (`projects`); `login` renders no topbar and keeps its `<h1>`.
  - **Verify**: `rg -c 'skip-link' packages/dartclaw_server/lib/src/static/design-system.css` prints `1` or more (it prints nothing and exits 1 today) — if it does not, S01 has not shipped the hoist and this task stops and reports; `rg -n '<h1' packages/dartclaw_server/lib/src/templates/topbar.html` returns exactly two lines, one whose class list contains `session-title-static` and one whose class list contains `session-title`, and returns nothing today; `rg -n '<span class="session-title' packages/dartclaw_server/lib/src/templates/topbar.html` returns no matches (it returns :26 and :38 today — `sessionTopbar`'s archive span at :4 is not matched, its `class` is not the first attribute), proving the two spans were promoted rather than duplicated; `rg -c '<h1' packages/dartclaw_server/lib/src/templates/*.html` lists `topbar.html` at 2 plus exactly the same six page templates at count 1 that it lists today and no seventh — a new in-page duplicate would raise one of the six to 2 or add a file; pressing Tab on page load reveals a focused "Skip to content" control that moves focus to `#main-content`

- [ ] **TI03** One shared `pageHeader` fragment exists for every non-chat surface
  - `templates/components.html` + `components.dart` gain a `pageHeader` fragment — `<header class="pagehead">` with an optional `<h2 class="t-page-title">`, an optional `--fg-sub0` subtitle and a right-aligned action slot — replacing the six competing treatments (`.pagehead`, `.settings-header`, `.info-title`/`.info-subtitle`, the channel hero, `.section-header`-as-title, and no title at all). Omit the `<h2>` when the title is empty while retaining subtitle and actions; the topbar remains the sole page `<h1>`. Action labels take verb+noun with `data-icon="plus"` rather than a literal `"+ "`. Follow `components.dart#infoCardTemplate` (:65) for the Dart-side signature shape. Per-surface adoption is S08–S12 and S15.
  - **Verify**: `rg -n 'tl:fragment="pageHeader"' packages/dartclaw_server/lib/src/templates/components.html` returns the fragment and `rg -n '^String pageHeaderTemplate\(' packages/dartclaw_server/lib/src/templates/components.dart` returns the function — both return nothing today, and a comment mentioning `pageHeader` would not satisfy either; rendering it with a title, subtitle and action emits `<header class="pagehead">` containing an `<h2 class="t-page-title">`, then the subtitle, then the action; rendering it with an empty title emits no heading but retains the subtitle and action

- [ ] **TI04** The empty-state family is one implementation
  - The eight bespoke classes — `.sidebar-placeholder` (:169), `.table-empty-cell` (:1126), `.allowlist-empty` (:1510), `.pairing-empty` (:1556), `.task-artifact-empty` (:1897), `.tl-empty-state` (:2228), `.knowledge-empty-state` (:3176), `.provider-empty-state` (:3673) — collapse onto canon `.empty-state`; `app.css:1808-1810`'s parallel `.empty-state-icon/-title/-text` family stops shadowing the canon accent-glow icon rule; the shared `templates/components.html#emptyState` fragment (:6) gains `.empty-state-title` and an optional action slot per S03's canon shape. The ~14 non-empty-state uses of `.empty-state-text` as a muted-text utility move to `.text-muted`.
  - **Boundary**: S07 TI05 retiers `.table-empty-cell` and `.empty-state-text` off `--fg-overlay` immediately before this story folds them into canon. That is not wasted work — S07's gate runs at its own boundary — but do not treat the retiered colours as values to preserve locally; canon `.empty-state` is the source once the shadow is gone.
  - **Verify**: `rg -n 'sidebar-placeholder|table-empty-cell|allowlist-empty|pairing-empty|task-artifact-empty|tl-empty-state|knowledge-empty-state|provider-empty-state' packages/dartclaw_server/lib/src/static/app.css` returns no matches (it returns the eight lines above today, so one missed class fails it); `rg -nU --multiline-dotall '^\.empty-state-(icon|title|text)[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css` returns no matches (it returns lines 1808-1810 today); rendering `emptyState` emits icon + `.empty-state-title` + copy + optional action, and the canon accent-glow icon treatment is visible on the rendered page

- [ ] **TI05** Failed htmx requests and dropped SSE streams are announced
  - `dc_shell_controller.js#connect` (:17) registers one body-level `htmx:responseError` + `htmx:sendError` pair calling `showToast('error', readHtmxErrorMessage(...))`, generalising the per-button `bindHtmxRequestErrors` (:395) so all 28 `hx-get` sites are covered without template edits, and removes them in `disconnect()` (:51). The `/api/events` `onerror` (:438) sets `data-connection="lost"` on the shell, renders `.banner.banner-warning`, and gates `.status-dot--live` / `.scan-bar` animations on that attribute; a successful `open` clears it. `data-connection` appears zero times in the codebase today. Adds no dialog and no native `confirm`.
  - **Verify**: `rg -c 'data-connection' packages/dartclaw_server/lib/src/static/controllers/ packages/dartclaw_server/lib/src/static/app.css` lists both the controller and the CSS (it prints nothing and exits 1 today); with `BASE` set to the commit recorded at story open, `git diff "$BASE" -- packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js | rg '^\+[^+]' | rg 'window\.(alert|confirm|prompt)|[^.\w](alert|confirm|prompt)\('` returns no matches **and** `git diff "$BASE" -- packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js | rg -c '^\+[^+]'` prints a non-zero count — the second command is what stops the first from passing vacuously on an empty diff or a stale pathspec; clicking an `hx-get` link that returns 404 shows an error toast carrying the server message (today it produces no visible change); killing the SSE stream renders the warning banner and stops the sidebar pulse, and restoring it clears both

- [ ] **TI06** A success toast survives a navigation
  - `controllers/shared.js` gains `queueToast(type, message)` writing to `sessionStorage` beside `showToast` (:71); `dc_shell_controller.js#connect` drains and shows it, clearing the key in the same read so a second navigation cannot repeat it. The handlers that reload queue before navigating: `dc_shell_controller.js:386` (session delete) and `dc_projects_controller.js:133 / 155 / 175 / 196` (project create, update, archive and remove — four handlers, not three). `sessionStorage` is used zero times in `controllers/` today.
  - **Verify**: `rg -c 'sessionStorage' packages/dartclaw_server/lib/src/static/controllers/` lists both `shared.js` and `dc_shell_controller.js` (it prints nothing and exits 1 today); `rg -c 'queueToast' packages/dartclaw_server/lib/src/static/controllers/dc_projects_controller.js` prints `4` — one per reload handler, so a missed handler fails it; removing a project shows a success toast *after* the reload completes (today only failures are announced), and reloading that page again shows no repeat toast

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
- `[TI05,TI06,TI07]` are browser-runtime behaviours with no test harness in this codebase; prove them interactively against the `visual` profile by forcing a 404, killing the SSE stream and throttling a navigation, and record the observations.
- `[TI01,TI02,TI03,TI04,TI10]` are CSS and markup: the per-task Verify greps prove the change landed, and the visual gate below proves it looks right.
- `dart analyze` must be clean across the workspace before the story closes — `helpers.dart` gains two public functions, and an unused import left behind by a deleted private helper is the likely failure.

### Validation

- Validate against the `visual` testing profile (`bash dev/testing/profiles/visual/run.sh`, port 3338 — the only profile rendering all 23 surfaces) in **both** themes at desktop 1440×900 (matching the audit baseline capture) and 768px, comparing against this story's own story-start captures per the plan's visual-baseline protocol.
- Keyboard-validate the skip link and the promoted `<h1>` with a screen-reader heading list on at least one `pageTopbar` page and one `plainTopbar` page: exactly one `<h1>` from the topbar on a page whose surface story has already deleted its duplicate, and two on the six that have not — the second is expected here and closes in S10, S11 and S15.
- Re-check `prefers-reduced-motion: reduce` after TI05 and TI07: the `data-connection` gate and the `hx-indicator` sweep are both animation paths that must stay suppressed under the media query.

### Execution Contract

- TI01 and TI02 each open with a presence check against a canon rule S01 owns. Run both checks before starting either task. If the rule is absent, the task stops and reports for hoisting — it does not shadow the canon rule from `app.css`, and it does not add the rule to canon, which is closed after P1.
- TI04 must run after TI03: the `emptyState` fragment and the `pageHeader` fragment land in the same two files, and TI03 establishes the fragment signature shape TI04's action slot follows.
- TI09 must run after TI08. `health_dashboard.dart:186`'s `'unknown'` disappears with the private relative-time helper TI08 deletes, so running TI09 first leaves a site that TI08 then re-resolves, and TI09's grep would have passed over a rule it did not own.
- This story starts only after S07 has left `check_design_system_sync.sh` green. S07 re-syncs all three served copies; a divergent served copy at the handoff makes every canon-dependent presence check in TI01 and TI02 read the wrong file.
- S07 has already edited `app.css`, `topbar.html` and `components.html` when this story starts. Do not revert a `t-page-title` class, a retiered colour or a `--z-*` token found in those files — they are S07's landed work.


## Final Validation Checklist

- [ ] No file outside `packages/dartclaw_server/lib/src/static/` (`app.css` and `controllers/`), `packages/dartclaw_server/lib/src/templates/`, `packages/dartclaw_server/lib/src/web/pages/`, `packages/dartclaw_server/test/templates/helpers_test.dart` and `dev/design-system/DESIGN.md` is modified — no service, schema, route or API change.
- [ ] No drift-checked canon file (`tokens.css`, `components.css`, `icons.css`, or any of their served copies) is modified, and `check_design_system_sync.sh` still exits 0.
- [ ] No per-surface template owned by S08–S12 or S15 is edited except the timestamp and absent-value `.dart` call sites TI08 and TI09 name; `settings.html` and `restart_banner.html` are left untouched.
- [ ] `dart run dev/tools/embed_assets.dart` was not executed and `embedded_assets.g.dart` is unchanged — S14 owns the single regeneration.
- [ ] `dart analyze` is clean and the full `packages/dartclaw_server/test/` suite passes, not just `helpers_test.dart`.
- [ ] The seven outputs in the table above all exist and render, because six parallel stories consume them the moment this one closes.
- [ ] The three `global` items this story does not close — the unvendored typeface (S13), unbounded list pagination (deferred as a new capability), and `settings.html:52`'s em-dash option (S11) — are recorded in Implementation Observations with their reasons, which is the only block S14's glitch ledger reads.
- [ ] Any canon rule this story reported rather than wrote (`.shell` / `.content-area` row sizing, `.skip-link`) is recorded in Implementation Observations with S01 named as the owner, whether or not S01 had shipped it in time.


## Implementation Observations

#### DECISION NOTE: s16.absent-value-render-contract

Decision-Key: s16.absent-value-render-contract
Altitude: FIS
Affected surface: Shared absent-value helper and every Dart/Trellis consumer in the formatting sweep
Decision: Return typed absence state plus the original value; templates emit static absent markup or render the preserved value with `tl:text`; non-empty values never use `tl:utext`.
Rationale: Keeps the absent treatment reusable without widening the trusted-HTML boundary or risking user-controlled markup execution.
Evidence: User ratified the recommended preflight option on 2026-07-26.
