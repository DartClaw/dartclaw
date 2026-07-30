# Surface sweep: settings

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
**Story-ID**: S11

## Feature Overview and Goal

**Intent**: Settings is the app's densest surface – ten tabs, fifteen cards, 31 fields – and it is the only one that loses operator work: it computes a dirty flag and throws it away, so unsaved edits vanish on a tab switch with no warning, while the same page presents 31 identically-weighted full-width rows, a control that cannot be set, and a failed config load as a wall of permanently-disabled boxes behind a four-second toast.

**Expected Outcomes**:

- [OC01] An operator editing settings can see whether there are unsaved changes, and switching tabs never discards them silently.
- [OC02] Settings renders from the canonical component families – every tab strip on the surface from the one canonical tab component, the canonical open-header table, and no class in its markup lacking backing CSS.
- [OC03] Settings states what it does not know instead of faking it: an in-flight load, a failed load, and an unsettable control each get a designed treatment rather than a permanently disabled form behind an expired toast.
- [OC04] An operator scanning a settings tab can tell a card title from a field label from its value, related fields read as a group, and a two-character field is not 866px wide.


## Required Context

### From `prd.md` – "Key Constraints, Assumptions & Dependencies" (canon-first)
<!-- source: prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.

### From `prd.md` – "Key Constraints, Assumptions & Dependencies" (zero-npm / no build step)
<!-- source: prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `prd.md` – "Constraints" (no backend work)
<!-- source: prd.md#constraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `prd.md` – "Out of Scope" (no new capabilities)
<!-- source: prd.md#out-of-scope -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `prd.md` – "FR6: Re-sync + adoption sweep" (the adoption clusters this story owns)
<!-- source: prd.md#fr6-re-sync--adoption-sweep -->
<!-- extracted: e18cf85 -->
> […] type-tier migration; empty/loading/error state coverage (31 findings — em-dash placeholders where an absent-value treatment belongs, undesigned empty states, no skeleton/`.scan-bar` loading treatment).
>
> - [ ] Drift check green; `design-system.css` byte-identical to canon.
> - [ ] Every page has a designed empty state; no bare em-dash stands in for an absent value.

### From `prd.md` – "FR7: Glitch sweep" (closure bar)
<!-- source: prd.md#fr7-glitch-sweep -->
<!-- extracted: e18cf85; FR7 gained the durable-backlog criterion after this extraction (uncommitted) -->
> - [ ] All 23 high-severity glitches closed.
> - [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
> - [ ] […elided: every deferral carried into a durable backlog, with its reason and no target milestone — the release-boundary hand-off S14 owns; this story's part is recording the deferral in its own Implementation Observations…]

### From `prd.md` – "FR4: Form, tab and dialog primitives in canon" (the one-tab-bar bar this sweep closes)
<!-- source: prd.md#fr4-form-tab-and-dialog-primitives-in-canon -->
<!-- extracted: 2026-07-25 -->
> - [ ] No app-local re-implementation of any of the three remains; only one tab bar ships.

### From `prd.md` – "FR1: Surface & depth revision" (contrast floor this sweep must not break)
<!-- source: prd.md#fr1-surface--depth-revision -->
<!-- extracted: e18cf85 -->
> Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.

### From `prd.md` – "FR5: Feedback decision-table rewrite + native dialog eradication" (regression guard on the controller this story edits)
<!-- source: prd.md#fr5-feedback-decision-table-rewrite--native-dialog-eradication -->
<!-- extracted: e18cf85 -->
> Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.

### From `prd.md` – "Non-Functional Requirements" (accessibility)
<!-- source: prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone

### From `plan.json` – shared decision "Canon-first, and canon closes after P1"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> […] ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes; the serialized P3 stories consume the settled copies without re-syncing them. […] A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

### From `plan.json` – shared decision "Shared-surface ownership in the sweep phase" (the page title this story deletes)
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> (1) PAGE TITLE: the topbar owns the page title and is the only `<h1>` on a page; six templates currently carry an in-page `<h1>` (`settings`, `knowledge_hub`, `kg_timeline`, `channel_detail`, `projects`, `login`) and each duplicate is deleted by the story owning that surface — settings by S11 […]. Pages carry a subtitle or description head, never a second `<h1>`. (2) OFF-SCALE FONT SIZES: S07 alone normalizes every hard-coded off-scale font-size […]; sweep stories keep only their own semantic edits to those rules and must not re-declare the size.

### From `canon-hoist-manifest.md` – "Hoist table" + "Consequences" (the two canon rules this story no longer authors)
<!-- source: canon-hoist-manifest.md#hoist-table -->
<!-- extracted: 2026-07-25 -->
> | `.tabs--sticky` material correction | S11 TI04 | **S03** | Tab component family |
> | Field-width scale (the audit's `--num` / `--short` suggestion, originally declined by S03) | S11 TI06 | **S03** | Belongs with the Forms section |
>
> - **S11** — drop TI04/TI06 canon edits; consume S03's `.tabs--sticky` material and field-width scale. Work Areas loses `dev/design-system/`.

### From `plan.json` – shared decision "Surface token roles — three distinct planes"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> […] No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.

### From `plan.json` – shared decision "Composite type-class vocabulary"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `plan.json` – shared decision "Wide-container assignment"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> […] wide applies to tasks, task detail, health (dashboard + audit), memory, scheduling, the workflow list AND workflow detail; the 900px measure stays for chat, session info, knowledge results, settings forms, and projects. The modifier is opt-in, never the default — a surface not on the wide list keeps 900px unless the sweep documents a deviation.

### From `plan.json` – shared decision "Visual-baseline protocol — story-start captures from S02 onward; S01 keeps the audit set"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> Protocol: from S02 onward, each story captures its own story-start screenshots of the surfaces it touches, in both themes at desktop and 768px, and validates against those. S01 runs first on the still-audited tree, so the audit's 92-shot capture IS its story-start state — S01 alone validates against the audit set (its existing audit-baseline gate). Beyond S01, the 92-shot set stays the release-level baseline that S14 re-proves once. A story that finds a regression outside its own scope reports it rather than absorbing it.

### From `plan.json` – shared decision "One dialog frame and one confirmation API"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S06 ships exactly one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js` plus one `htmx:confirm` listener in `dc_shell_controller.js` — every current and future confirmation routes through those two, and no story adds a second dialog implementation.

### From `plan.json` – story S11 `notes` (the sanctioned behaviour change and the half-closable glitch)
<!-- source: plan.json#stories[S11].notes -->
<!-- extracted: 2026-07-25 -->
> Dirty-state tracking is the sweep phase's only behaviour change and needs its own test, not just visual validation. The `settings/agent` HIGH glitch is only half-closable here: the Effort select's real fix needs `allowedValues` on `agent.effort` in `dartclaw_config`'s `config_meta.dart` — a config-metadata change plus a product decision on the legal value set, barred by the no-backend-work constraint. Close the UI half; record the rest as a deferral for S14's ledger.


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#b-glitches--visibly-broken-no-design-decision-needed-72` – the `settings/all-tabs` (1, HIGH dirty-state), `settings/agent` (1, HIGH Effort select), `settings/tab-bar` (2, ARIA + 768px clipping) and `settings/security` (1, HIGH guard-editor affordances – **S06's**, not this story's) entries. Measured pixel and grep evidence per glitch.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – the `settings/all-tabs` (4), `settings/security` (3, of which only the `.data-table` one is this story's), `settings/tab-bar` (2) and `settings` (1) entries. Each carries the audit's own proposed fix for the adoption tasks below.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – also the `settings, workflows, scheduling, channel-detail` (1) custom-select entry, whose nine settings selects this story records as closed by canon rather than enhancing.
- `docs/specs/0.22.1/canon-hoist-manifest.md` – why TI04 and TI06 consume S03's rules instead of authoring them, and where to report a further missing canon rule.
- `docs/specs/0.22.1/fis/prior-art-combined-sweep.md` – the superseded combined workflows+projects+settings FIS this story is split from. Its settings findings are carried forward here; its workflows and projects content belongs to S15.
- `docs/wireframes/settings-page.html`, `docs/wireframes/settings-page-providers.html` – intended settings card grouping and field density.
- `../dartclaw-public/dev/guidelines/TRELLIS-GUIDELINES.md` – `tl:` attribute and escaping rules for every `settings.html` edit here.
- `../dartclaw-public/dev/testing/UI-SMOKE-TEST.md` – TC-09 (Settings Page) is this story's live smoke case.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI02] Save reflects whether there is anything to save**
  - **Given** `/settings` is loaded on the `visual` profile and the Agent card's fields hold their persisted values
  - **When** the operator types a new value into Max Turns and then restores the original value
  - **Then** the Save control becomes actionable while the value differs and returns to its non-actionable state once it matches again, and pressing Save on the pristine form is not the way the operator learns there were no changes

- [x] **S02 [OC01] [TI02] Switching tabs with unsaved edits does not discard them silently**
  - **Given** the Agent card has an edited, unsaved Model value
  - **When** the operator clicks the Providers tab
  - **Then** a dialog titled "Discard unsaved changes?" appears before the Agent card is hidden; cancelling leaves the operator on the Agent tab with the edited Model value still in the field and the form still dirty, and confirming discards the edit and shows Providers – in no path is the card hidden without the operator having seen the warning, and returning to Agent after confirming shows the persisted value with no second warning

- [x] **S03 [OC01] [TI02] A clean tab switch and the initial page load are not interrupted**
  - **Given** `/settings` is loaded with `#security` in the URL fragment and no field has been edited
  - **When** the page performs its initial tab activation and the operator then clicks Memory
  - **Then** neither transition raises a warning, the Security panel is the one shown at load, and the Memory panel appears on the click without an intervening dialog

- [x] **S04 [OC02] [TI03,TI04,TI10] Every tab strip on the surface is the one canonical tab component**
  - **Given** `/settings` rendered at 768px in light theme, scrolled to the top, and the Security tab's guard editor loaded
  - **When** an assistive-technology user reaches either strip and a touch user reaches for the tenth section
  - **Then** the page strip announces as a tab list with exactly one selected tab whose panel is identified by `aria-controls`, the inactive panels are `hidden` rather than inline-`display:none`, "Security" is reachable with a visible affordance that content continues past the fold, the sticky strip shows no hard-edged slab seam against the body gradient, and the guard-editor strip renders from the same `.tabs` / `.tab` component with the same arrow-key behaviour rather than its own `.guard-editor-tab` pill recipe

- [x] **S05 [OC03] [TI08] A failed load leaves a persistent, retryable failure – not a wall of disabled boxes**
  - **Given** `/api/config` is made to reject for the settings page load, and separately `/api/config/guards` is made to reject for the Security tab
  - **When** each page area renders and its fetch fails, and the operator waits 10 seconds
  - **Then** each card body carries a `banner banner-error` with a Retry control that is still on screen after the toast has expired, no field is left stuck reading "Loading...", pressing Retry repopulates with dirty tracking intact rather than reporting a phantom unsaved edit, and the guard editor's Retry actually re-fetches rather than being a no-op left behind by a load-flag set before the request resolved

- [x] **S06 [OC03] [TI08,TI09] Settings distinguishes "loading", "inherited" and "cannot be set"**
  - **Given** a slow `/api/config` response, and `agent.effort` still declaring no allowed values
  - **When** the Workflows and Agent tabs render in-flight and then populate
  - **Then** in-flight fields render as skeleton blocks rather than disabled boxes reading "Loading...", an unset `workflow.defaults.*` provider or model states the value it inherits from the config payload, the unset Model and Max Turns fields say the field is unset and the server default applies without naming a value the client cannot read, and the Effort control is not presented as an enabled picker whose only option is blank

- [x] **S07 [OC04] [TI05,TI06,TI07] A settings card reads as a hierarchy, not a stack**
  - **Given** the Workflows tab, whose nine fields are semantically four role pairs (provider + model) plus a workspace directory, and the Agent tab's two-character Max Turns field
  - **When** an operator scans either tab
  - **Then** each role pair reads as one labelled group, "Agent Configuration", "Provider" and the value "claude" render at three distinguishable sizes, Max Turns is visibly narrower than its card rather than spanning it, and the "Changes apply after a server restart" note reads as neutral helper copy on a single divider rather than a warning-toned band


## Structural Criteria

- [x] Story-start captures of `/settings` – all ten tabs – exist in both themes at 1440px and 768px, and every close-out diff against them traces to a task in this FIS or is reported rather than absorbed.
- [x] `settings.html`'s tab strip carries `role="tablist"`, each control carries `role="tab"` with `aria-selected` and `aria-controls`, each `[data-tab]` card carries `role="tabpanel"` with a unique `id`, panels toggle the `hidden` attribute rather than inline `style.display`, and no `aria-current="page"` remains on a tab.
- [x] Both strips on the surface – the page tab strip and the guard-editor strip – render from canon's `.tabs` / `.tab`; `.guard-editor-tab` appears in no template, controller or stylesheet, so the release's "only one tab bar ships" bar holds on this surface.
- [x] `settings.html` emits no `<h1>`; the topbar is the page's only one.
- [x] Every `settings.html` field cluster of two or more semantically-related fields sits inside a `.well`, and no short numeric control (Port, Max Turns, Reset Hour) stretches to the container measure.
- [x] Every class emitted by `settings.html` resolves to a rule in `design-system.css`, `icons.css` or `app.css` (the icon family lives in `icons.css`, which is canon-owned and served alongside the other two).
- [x] The `app.css` `.guard-editor-*` block declares only genuinely local properties – no border, `text-transform` or cell padding that `design-system.css#.data-table` already provides, and no tab-pill recipe canon's `.tab` already provides.
- [x] The composite `.t-*` classes carry the type on `/settings`, this story adds no new `--text-sm` usage, declares no font-size on the off-scale badge rules S07 owns, and applies no `--container-wide` / `.content-inner--wide` / `.page-inner--wide` modifier to settings – the plan assigns it the 900px measure.
- [x] Card-vs-ground contrast is ≥ 1.15:1 and WCAG AA text contrast holds on `/settings` in both themes; no settings state is conveyed by colour alone.
- [x] This story's canon footprint is zero: with `BASE=.agent_temp/0.22.1-s11-entry`, `git diff --no-index --quiet "$BASE/dev/design-system" dev/design-system` exits 0 and the three served-CSS `cmp -s` checks exit 0. `dev/tools/fitness/check_design_system_sync.sh` still exits 0. After the final settings template/static change, the generator refreshes the tracked bundle and the generated parity, template and JS tests all pass.
- [x] No `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` appears in `dc_settings_controller.js`.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/templates/settings.html` – ten-tab strip semantics, 15 cards / 8 forms / 31 field groups, the duplicate `<h1>` (:10) the topbar now owns, well clustering, type classes, short-field modifiers, the Effort option label, the guard-editor tab-strip container and table classes.
- `packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` – dirty state reaching observable form/button state, the tab-switch guard, panel toggling via `hidden`, skeleton/populate/failure paths for both fetches, the guard-editor tab markup `renderGuardEditor` emits, the restart-note treatment, and the disabled-field enable rule.
- `packages/dartclaw_server/lib/src/static/app.css` – the settings-local blocks only: `.section-note` / `.section-note-restart`, `.guard-editor-tab` / `.guard-editor-tab.active` and the `.guard-editor-tabs` member of the shared flex selector at :3689, and `.guard-editor-table`.
- `packages/dartclaw_server/test/static/app_js_test.dart` and `packages/dartclaw_server/test/web/settings_page_test.dart` – the new dirty-state guard plus assertions re-pointed at the canonical classes.

### What We're NOT Doing
- `allowedValues` for `agent.effort` / `agent.provider` in `dartclaw_config`'s `config_meta.dart` -- a config-metadata change that alters the `/api/config` meta payload, and the legal value set is a product decision; barred by the no-backend-work constraint. Record as a deferral for the S14 glitch ledger; TI09 closes the UI half only.
- A default-value surface on `FieldMeta` (`dartclaw_config/lib/src/config_meta.dart`) -- it carries `yamlPath` / `jsonKey` / `type` / `mutability` / `nullable` / `min` / `max` / `allowedValues` and no default, so the client cannot read the effective default for `agent.model`, `agent.max_turns` or `agent.effort`. Exposing one is the same config-metadata change plus a product decision on the legal value set as the `allowedValues` deferral above, and is barred by the same constraint. TI08 therefore states the inherited value only where the config payload already carries it (`workflow.defaults.*`) and otherwise says the field is unset without naming a value. Record as a deferral for the S14 glitch ledger.
- Rolling the `.custom-select` enhancement out to settings' nine native `<select>` elements -- the audit's "only 2 of 17 selects get the custom-select enhancement" finding is **closed by canon, not deferred**: S03 gives canon a real `select.form-select` with a chevron affordance, so after S03/S05 the native selects are branded and the `.custom-select` listbox stays the narrow escape hatch DESIGN.md § Native selects describes. Adding `data-enhance="custom-select"` to nine more selects would be new work in the opposite direction. Record the disposition and its reasoning for the S14 glitch ledger so it is not read as a silent omission. S08 separately verifies the retained `.custom-select` family still renders correctly beside the canonical controls.
- Settings information architecture -- regrouping ten flat tabs into 3–4 sections, moving Authentication/System Health/Workspace out of "Server", and surfacing pending-pairing counts on the tab strip are new UX capabilities, barred by Out of Scope. Record all three as deferrals with reasons.
- The guard-editor edit dialog and the guard-extension delete confirmation -- S06 owns both (its TI07 and TI08). This story changes the guard-editor *table's* presentation only and does not touch the edit or delete handlers.
- DM and group allowlist delete confirmations (`dc_settings_controller.js`) -- S06 owns both (its TI10); they are in its scope, not deferrals. This story does not touch them.
- The restart-banner missing-`.btn` fix (`restart_banner.html`) -- the audit records it twice, as `settings/restart-banner` and as `shell/restart-banner`; S12 owns the shell surface. Report it, do not fix it here.
- Workflows and projects -- S15 owns them after the split; nothing in `workflow_list.html`, `workflow_detail.html`, `workflow_step_detail.html`, `projects.html`, `workflows_page.dart` or `dc_projects_controller.js` is touched here.


## Architecture Decision

**Approach**: adopt, do not author – settings re-renders on canon families that already ship by the time this story runs (`.tabs` / `.tab` incl. S03's `.tabs--sticky` material and field-width scale, `.well`, `.data-table`, `.skeleton`, `banner banner-error`, the `.t-*` tiers); this story writes no canon rule and re-syncs nothing. The only new logic is finishing the dirty-state function the app already computes and wiring the tab switch to consult it.
**Why this over alternatives**: an `app.css` width cap or tab-pill recipe on a canonical form or tab class fails the drift check by definition and recreates exactly the two-implementations rot 0.22 produced. S11 executes alone in W7 and consumes the rules hoisted into S03 rather than reopening canon.


## Technical Overview


## Code Patterns & External References

```
# type | path#anchor or url                                                          | why needed (intent)
file   | dev/design-system/components.css#.well                                      | Canon container for form field clusters (`.well` / `.well-content`) – shipped since 0.22, zero uses in settings.html
file   | dev/design-system/components.css#.data-table                                | Open-header table treatment (border-bottom only, caps-tracked `th`, row hover) replacing the boxed `.guard-editor-table` grid
file   | dev/design-system/components.css#.skeleton                                  | `.skeleton` / `.skeleton-text` loading blocks that replace the 22 disabled `placeholder="Loading..."` inputs
file   | dev/design-system/components.css#.tabs--sticky                              | S03's sticky tab strip, carrying the material fix and the field-width scale hoisted out of this story – read it to confirm what to consume; never edit it here
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#renderGuardEditor | Emits the `guard-editor-tab` pill markup (:473-477) TI10 repoints at canon `.tabs` / `.tab`; `[data-guard-editor-tab]` is the click hook at :553 and must keep working
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#loadGuardEditor | Sets `root.dataset.loaded = '1'` before the fetch resolves (:514-517), so a failed load is permanent for the page's lifetime – the flag TI08 moves onto the success path
file   | packages/dartclaw_server/lib/src/templates/workflow_detail.html             | The `banner banner-error` + Retry block in the step-detail slot is the in-page failure recipe TI08 reuses on settings
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#updateFormDirtyState | Computes `dirty` and returns without using it (:203-226); TI02's outcome is that its result reaches observable state
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#activateSettingsTab | Hides cards with `card.style.display = 'none'` (:31) with no dirty check; TI02 and TI03 both rewrite this function
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#populateSettingsForm | :181-182 unconditionally clear `disabled` then `placeholder` for every field – the single point TI08 and TI09 both correct
file   | packages/dartclaw_server/lib/src/static/controllers/shared.js#confirmDialog | S06's single confirmation API; the unsaved-edit warning routes through it and adds no second dialog
wire   | docs/wireframes/settings-page.html                                          | Intended settings card grouping and field density
```


## Constraints & Gotchas

- **Constraint**: S05 already swapped `settings.html` onto the canonical `form-*`, `tabs` / `tab` and `dialog` classes and deleted `.settings-tabs` / `.settings-tab` / `.form-group` from `app.css` -- Workaround: locate call sites by role, not by the audit's pre-S05 class names or the line numbers quoted in its evidence, which have all moved.
- **Critical**: `activateSettingsTab` is called from two places – the operator's tab click and the initial hash-driven activation at controller init -- Must handle by: consulting dirty state only on the operator-initiated path. A confirm on the init path would block page load behind a dialog for a form that has never been edited.
- **Critical**: `confirmDialog` is asynchronous, while the current click handler calls `preventDefault()` and then switches synchronously -- Must handle by: performing the class/panel/`history.replaceState` updates after the promise resolves, so a dismissed warning leaves the strip and the panel on the original tab rather than half-switched.
- **Critical**: dirty state is per-`<form class="settings-form">` (8 forms) but `activateSettingsTab` hides `[data-tab]` cards (15 cards) -- Must handle by: checking the forms inside the card(s) about to be hidden, not a single "the form" lookup; a tab with no form must switch without a check.
- **Constraint**: toggle fields are deliberately excluded from the dirty diff because they auto-save through `handleToggleChange` -- Workaround: preserve that exclusion (S05 moved its detection onto S03's `.form-toggle` control); including toggles would mark a card dirty for a change already persisted.
- **Critical**: canon is CLOSED to this story. The two rules this sweep needs – the short-field width scale and the `.tabs--sticky` material – were hoisted into S03 and arrive with it; this story consumes them and writes nothing under `dev/design-system/`'s three drift-checked files -- Must handle by: if a further canon rule turns out to be missing, stop and report it for hoisting into the owning P1 story rather than adding it. An `app.css` cap or tab recipe on a canonical class fails the ownership boundary. `DESIGN.md` and `showcase.html` are not drift-checked and stay writable for any contract this story documents.
- **Critical**: this story executes in W7 after S06 W1, S07 W2, S16 W3, S08 W4, S09 W5 and S10 W6. `confirmDialog` and the removal of the two `window.prompt()` calls at `dc_settings_controller.js:569,573` are mandatory W1 arrival checks – those are S06's outputs, not work S11 may re-own.
- **Avoid**: fixing a surface complaint by re-declaring a card, chrome or ground tone locally -- Instead: report it against S01's tokens per the surface-token shared decision.
- **Avoid**: reaching for a raw `--text-xs` for the new cluster labels (the audit's own fix text says `--text-xs`) -- Instead: apply `.t-caption`, which binds size, weight, line-height and caps tracking together per the composite type-class decision.
- **Constraint**: this story receives the accumulated `app.css` from W1–W6 and S12 W8 plus S15 W9 follow -- Workaround: confine edits to the `.section-note*`, `.guard-editor-tab*` and `.guard-editor-table` blocks this FIS names; preserve earlier regions and do not reflow unrelated code. `.guard-editor-tabs` shares its rule head with `.guard-editor-actions`, `.guard-editor-form-row` and `.guard-tester-row` (:3689-3696) – drop only its member from the selector list, not the block.
- **Constraint**: S07 alone normalizes the hard-coded off-scale font sizes (`.provider-badge` and siblings) -- Workaround: apply the `.t-*` classes to settings markup, but never re-declare a size on those rules while editing the same file.
- **Critical**: this story changes template/static embed roots. After the final such change, run `dart run dev/tools/embed_assets.dart` before objective verification, then run the generated parity test; the full declared suite closes green. Re-run after remediation that changes an embed root, and never hand-edit the generated file.
- **Critical**: `test/templates/tasks_s11_test.dart` is pre-existing and belongs to a *previous* milestone's story numbering -- it is not this story's test file and must not be repurposed. New assertions go in `test/static/app_js_test.dart` and `test/web/settings_page_test.dart`.


## Implementation Plan

### Implementation Tasks

Before TI01, snapshot canon, served CSS and `app.css` exactly as W7 receives them. These comparisons isolate S11's own delta from the accumulated W1–W6 checkout:

```sh
BASE=.agent_temp/0.22.1-s11-entry
rm -rf "$BASE"
mkdir -p "$BASE/dev" "$BASE/packages/dartclaw_server/lib/src/static"
cp -R dev/design-system "$BASE/dev/"
cp packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/icons.css packages/dartclaw_server/lib/src/static/app.css "$BASE/packages/dartclaw_server/lib/src/static/"
```

- [x] **TI01** This story has its own before-image to validate against
  - Capture `/settings` on the `visual` profile (port 3338, `bash dev/testing/profiles/visual/run.sh`) with each of the ten tabs active, in dark and light at 1440px and 768px, per the plan's visual-baseline shared decision – the audit's 92-shot set predates S01's re-tone and S02's re-scale and cannot isolate this story's deltas.
  - **Verify**: 40 story-start captures exist (10 tabs × 2 themes × 2 viewports) and are the diff target used at story close

- [x] **TI02** The settings form's dirty state is observable, and a tab switch cannot discard it silently
  - `dc_settings_controller.js#updateFormDirtyState` computes `dirty` and returns without using it (its six call sites already fire on `input`, `change`, submit-failure, post-save and cancel); its result must reach the form and its Save control. `activateSettingsTab` must consult the forms inside the card(s) it is about to hide, on the operator-click path only – not on the init-time activation. No second dialog implementation: the warning routes through the `confirmDialog({title, body, confirmLabel, danger})` helper S06 put in `controllers/shared.js`, called with title `"Discard unsaved changes?"`, `confirmLabel: "Discard"` and `danger: true`, and the panel/strip/`history.replaceState` updates happen only after it resolves. The dialog is a discard confirmation, not a save prompt: cancel returns to the originating tab with the edit and the dirty flag both intact; confirm discards the edit, restores the fields from `settingsInitialConfig` and re-baselines the form, so the same warning cannot fire a second time for an edit the operator already chose to drop. The post-save call already re-baselines `settingsInitialConfig`, so a saved form must come back clean too.
  - **Verify**: `Test: app_js_test.dart asserts updateFormDirtyState assigns its computed dirty result to observable form/button state, that the tab-click path consults it before hiding a card, that the init-time activation path does not, that the confirm branch restores fields from settingsInitialConfig and clears the dirty flag (fails if confirm silently retains the edit), and that the cancel branch neither restores fields nor switches panels (fails if cancel loses the edit) – each assertion fails when its guarded declaration is removed`; live on `/settings`, scenarios S01, S02 and S03 hold, and `rg -n 'window\.(alert|confirm|prompt)|(^|[^.\w])(alert|confirm|prompt)\(' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1

- [x] **TI03** The settings tab strip is a real tab widget, not ten dead anchors
  - Post-S05 the strip carries the canonical `tabs` / `tab` classes; this task adds the semantics S05 left alone – `role="tablist"` on the strip, `role="tab"` + `aria-selected` + `aria-controls` per control, `role="tabpanel"` + a unique `id` per `[data-tab]` card, the `hidden` attribute in `activateSettingsTab` in place of `card.style.display`, and `aria-current="page"` dropped (it announces "current page" for an in-page panel switch). Multiple cards share one tab id (four carry `data-tab="server"`), so panel ids must be unique and `aria-controls` carries the space-separated list of every panel a control governs. `hidden` genuinely hides a `.settings-card { display: flex }` panel because `app.css:1` declares `[hidden] { display: none !important; }` – no new CSS rule is needed, and none may be added. A role-bearing strip must also honour the keyboard contract those roles announce: Left/Right arrows move between tabs, Home/End jump to first/last, and a roving `tabindex` keeps exactly one tab in the tab order.
  - **Verify**: `rg -n 'role="tablist"|role="tab"|role="tabpanel"|aria-selected|aria-controls' packages/dartclaw_server/lib/src/templates/settings.html` returns all five and `rg -n 'aria-current|card\.style\.display' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1 (scoped to the panel path – `checkRestartBanner`'s `banner.style.display` at :196,:199 belongs to the restart banner this story does not touch); on `/settings` every `aria-controls` value resolves to an element that exists, clicking each of the ten tabs shows exactly one panel group, and from a focused tab the arrow keys move selection while Tab leaves the strip

- [x] **TI04** All ten sections are reachable at 768px and the sticky strip sits on the ground rather than over it
  - Both halves of this outcome now arrive from canon: S03 carries the `.tabs--sticky` material correction (the flat opaque slab with hard seams over the body gradient in light theme at scroll-top, which S05 recorded as owned here) and the tenth tab's overflow affordance for the ten-tab row that clips at 768px. This task consumes them and proves them on the live surface – it authors no rule. If either is still wrong once S03 has landed, report it against S03 per the visual-baseline protocol rather than absorbing it, and do not reach for `app.css`.
  - **Verify**: with `BASE=.agent_temp/0.22.1-s11-entry`, `git diff --no-index -U0 "$BASE/packages/dartclaw_server/lib/src/static/app.css" packages/dartclaw_server/lib/src/static/app.css | rg '^\+[^+].*\.tabs'` exits with code exactly 1 (no app-side tab rule was added by this story); at 768px "Security" is reachable and no label is clipped mid-word, and at scroll-top in light theme the strip shows no hard-edged seam against the gradient

- [x] **TI05** Related settings fields read as one labelled group
  - `settings.html` has 31 `data-field=` groups, zero `class="well"` and zero `<fieldset>`. Cluster each card's semantically related fields – the four workflow role pairs (provider + model), the four Server sub-cards – in `.well` / `.well-content` (canon's documented container for form field clusters) with a `.t-caption` uppercase cluster label per canon § Wells. A card whose fields are genuinely unrelated keeps its flat stack; this is grouping, not decoration.
  - **Verify**: `rg -c 'class="well[ "]' packages/dartclaw_server/lib/src/templates/settings.html` prints at least 8 (the character class excludes `class="well-content"`, which would otherwise let four clusters satisfy a threshold of eight); on the Workflows tab the four role pairs render as four labelled groups rather than eight identical rows, and no field escapes its card's measure

- [x] **TI06** A two-character field is not 866px wide
  - `.form-input` / `.form-select` are `width: 100%` with no max-width, so Port, Max Turns and Reset Hour each render ~866px for a 2–4 character value. The field-width scale that caps them was hoisted into S03's Forms section and ships with canon; this task applies S03's control modifier to those three fields in `settings.html` and adds no rule of its own. Depends on TI05 having settled the well structure the capped controls sit in.
  - **Verify**: the width modifier this task applies resolves to a rule already present in `packages/dartclaw_server/lib/src/static/design-system.css` and, with `BASE=.agent_temp/0.22.1-s11-entry`, `git diff --no-index -U0 "$BASE/packages/dartclaw_server/lib/src/static/app.css" packages/dartclaw_server/lib/src/static/app.css | rg '^\+[^+].*max-width'` exits with code exactly 1; on `/settings` Port, Max Turns and Reset Hour are each visibly narrower than their card, and the text fields beside them are unchanged

- [x] **TI07** A settings card reads heading → label → value, and the restart note is helper copy
  - Card title, field label and field value all render at 14px today. Apply the composite tiers so three sizes are visible – card title to `.t-heading`, field label to `.t-label`, field value to `.t-body` – and use `.t-caption` for the cluster labels TI05 introduced and any hint text. The always-on "Changes apply after a server restart" note is populated on 7 of 10 tabs unconditionally by `dc_settings_controller.js`, in a `color-mix` of `--warning` and `--fg-overlay` that reads as neither; demote it to plain `--fg-overlay` helper copy on a single divider so the undiluted `--warning` token means the actual pending-restart state, which has its own banner. The demotion is not CSS-only: `updateMutabilitySummaries` (:138-142) injects an `icon icon-triangle-alert` span into the same note, and neutral helper copy carrying a warning triangle is the same defect in another layer – the icon goes with the blend. The page also prints its title twice: `settings.html:10` `<h1>Settings</h1>` duplicates the topbar's, and the plan's shared-surface decision assigns the deletion here – remove it and keep any subtitle as a description head, never a second `<h1>`. Settings keeps the 900px measure – it is not on the plan's wide-container list.
  - **Verify**: `rg -n '<h1' packages/dartclaw_server/lib/src/templates/settings.html` exits with code exactly 1; `awk '/^\.section-note-restart/,/}/' packages/dartclaw_server/lib/src/static/app.css | rg -n 'warning'` exits with code exactly 1 (block-scoped – grepping the selector name alone prints only the `{` line and never the declaration, so it could not fail) and `awk '/^function updateMutabilitySummaries/,/^}/' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js | rg -n 'icon-triangle-alert'` exits with code exactly 1 (block-scoped: TI08's `banner banner-error` recipe legitimately carries the same glyph elsewhere in the file); `rg -n 'content-inner--wide|page-inner--wide' packages/dartclaw_server/lib/src/templates/settings.html` exits with code exactly 1; with `BASE=.agent_temp/0.22.1-s11-entry`, `git diff --no-index -U0 "$BASE/packages/dartclaw_server/lib/src/static/app.css" packages/dartclaw_server/lib/src/static/app.css | rg '^\+[^+].*var\(--text-sm\)'` exits with code exactly 1 (the story-entry snapshot covers only S11's own additions – the token itself lives in `app.css`, which S07 owns, so grepping the template for it would be vacuous); on `/settings` "Agent Configuration", "Provider" and the value render at three distinguishable sizes, measured card-vs-ground contrast is ≥ 1.15:1 and every text pairing meets WCAG AA in both themes, and no settings state is carried by colour alone

- [x] **TI08** Settings has a loading treatment and a failure that outlives a toast
  - The in-flight pass renders `.skeleton` / `.skeleton-text` blocks in place of the 27 fields that currently advertise loading: 22 `placeholder="Loading..."` disabled inputs plus five `<select>` elements whose sole option is `<option value="">Loading...</option>` (:154, :161, :192, :199, :225) – the selects carry the state as option text, not as an attribute, and a fix that greps only for `placeholder` leaves them stuck. The skeleton is a sibling of the control, toggled on populate; the controls stay in the DOM, because `populateSettingsForm` queries `.settings-form [data-field]` and assumes an `input`/`select` inside every group. On populate, `populateSettingsForm` currently clears `placeholder` unconditionally, so nullable fields (Model, Max Turns, Effort) become indistinguishable empty boxes. An unset nullable field's placeholder must say what is actually knowable, and no more: where the config payload already carries the inherited value – the `workflow.defaults.*` provider and model fields, which fall back to `agent.*` – state it; where it does not – `agent.model`, `agent.max_turns`, `agent.effort` – say the field is unset and the server default applies **without naming a value**, because `FieldMeta` exposes no default and inventing one would assert a value the client cannot read (see What We're NOT Doing). On `/api/config` rejection the failure path currently fires only a 4-second toast and leaves every field disabled forever; the card body must carry a persistent `banner banner-error` with a Retry control, following the recipe already in `templates/workflow_detail.html`'s step-detail error slot. The Security tab's second fetch needs the same treatment and one extra correction: `loadGuardEditor` sets `root.dataset.loaded = '1'` *before* the request resolves, so a failure is permanent for the page's lifetime and a Retry would be a no-op – set the flag on success only, and give its failure the same banner and a Retry that genuinely re-fetches. Retry re-runs the whole success pipeline idempotently, not just the fetch: `initSettingsForm`'s `.then` (:726-733) also performs the `settingsInitialConfig` re-baseline, `checkRestartBanner`, `attachSettingsListeners()`, `loadGuardEditor()` and `attachGuardEditorListeners()`, so a repopulate-only Retry yields a form that looks live and has no dirty tracking, no save and no guard editor. TI02's dirty tracking must survive a Retry-driven repopulate without reporting a phantom edit.
  - **Verify**: `rg -n 'Loading\.\.\.' packages/dartclaw_server/lib/src/templates/settings.html` exits with code exactly 1 – all 27 current occurrences are either the `placeholder` attribute or the option text, so one exit-code assertion covers both shapes (`rg -c` prints nothing and exits 1 on no-match, so an exit-code assertion is the only sound form) – and `rg -n 'skeleton|banner banner-error' packages/dartclaw_server/lib/src/templates/settings.html packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` returns both; scenarios S05 and S06 hold with `/api/config` and then `/api/config/guards` forced to fail, each failure state is still on screen after 10 s, after Retry succeeds a typed edit still marks the form dirty and Save still submits, and the absent `FieldMeta` default-value surface is recorded as a deferral in Implementation Observations

- [x] **TI09** The Effort control never presents an enabled picker whose only choice is blank
  - `agent.effort` declares no `allowedValues` in config metadata and adding them is out of scope here, so the control must not claim to be settable: give the empty option a real label ("Default") rather than an em dash, and leave the control non-actionable while its allowed-value list is empty. The unconditional enable is in `populateSettingsForm`, which clears `disabled` for every field regardless of whether options were injected. Record the `allowedValues` half – and the `agent.provider` mirror defect, an enumerable value rendered as free text for the same reason – as explicit deferrals for the S14 glitch ledger, with the reason.
  - **Verify**: `rg -n '<option value="">—</option>' packages/dartclaw_server/lib/src/templates/settings.html` exits with code exactly 1; on `/settings` the Effort field is not a focusable picker offering a single blank row, every field that *does* have options is still enabled after populate, and both deferrals are recorded in Implementation Observations

- [x] **TI10** The guard editor renders from canon: one tab component, one open-header table
  - Two app-local recipes, one component. **Tabs**: `renderGuardEditor` (:473-477) emits `class="guard-editor-tab"` pills into `[data-guard-editor-tabs]` (`settings.html:483`) – a third tab implementation on this surface, which the release's "only one tab bar ships" bar does not allow. Emit canon's `tab` class into a `tabs` container instead, keep the `[data-guard-editor-tab]` click hook at :553 working, and give the strip the same `role="tablist"` / `role="tab"` / `aria-selected` semantics and arrow-key contract TI03 applies to the page strip. Delete `.guard-editor-tab` and `.guard-editor-tab.active` from `app.css` and drop `.guard-editor-tabs` from the shared flex selector at :3689 – the other three members stay. **Table**: `settings.html`'s table carries `class="data-table guard-editor-table"`, and the `app.css` rule keeps only the genuinely local parts (its `min-width`, the mono/break-all value cell), deleting the per-cell borders, the bare uppercase `th` and the padding that `dev/design-system/components.css#.data-table` already provides. Presentation only – the edit and delete handlers belong to S06 and are not touched.
  - **Verify**: `rg -n 'guard-editor-tab(s)?\b' packages/dartclaw_server/lib/src/static/app.css` exits with code exactly 1 (the `(s)?` pins the `.guard-editor-tabs` removal from the `:3689` shared flex selector too, while `.guard-editor-table` stays unmatched) and `rg -n "class='guard-editor-tab|class=\"guard-editor-tab" packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1 (the `[data-guard-editor-tab]` attribute hook is a different string and survives); `rg -n 'class="data-table guard-editor-table"' packages/dartclaw_server/lib/src/templates/settings.html` returns the markup and `awk '/^\.guard-editor-table/,/}/' packages/dartclaw_server/lib/src/static/app.css | rg -n 'border|text-transform|padding'` exits with code exactly 1; on the Security tab the guard strip renders as canon tabs and still switches guard groups on click and on arrow keys, and the table renders with a bottom-rule header at caps tracking and a row hover with the value cell still wrapping

- [x] **TI11** This story's canon footprint is provably zero, generated parity is current, and the test suite guards the new shapes
  - Canon is closed to P3: this task asserts that S11 changed none of the three drift-checked files or their served copies, rather than re-syncing anything. Re-point existing assertions, preserving each assertion's original intent, in every test whose expectation this story invalidates – not only retired class names: `app_js_test.dart` asserts on `dc_settings_controller.js` source shapes TI02 and TI03 rewrite, and `settings_page_test.dart:57` asserts `contains('href="#providers"')`, which TI03's tab-control markup governs. After the final settings template/static change, run `dart run dev/tools/embed_assets.dart` before this objective verification.
  - **Verify**: with `BASE=.agent_temp/0.22.1-s11-entry`, `git diff --no-index --quiet "$BASE/dev/design-system" dev/design-system` exits 0 and `for rel in packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/icons.css; do cmp -s "$BASE/$rel" "$rel" || exit 1; done` exits 0; `bash dev/tools/fitness/check_design_system_sync.sh` exits 0; `dart test packages/dartclaw_server/test` passes, including `test/generated/embedded_assets_test.dart`; both generated asset files remain tracked; every class token `settings.html` emits resolves to a rule head in `design-system.css`, `icons.css` or `app.css` (enumerate with `rg -o 'class="[^"]*"' packages/dartclaw_server/lib/src/templates/settings.html`, split on whitespace, and grep each token across the three served stylesheets – no token is unbacked)

### Testing Strategy

- The repo has no JS runtime harness (zero-npm), so TI02's dirty-state guard is a source-level assertion in `app_js_test.dart`. It must assert that the computed result reaches observable state, that the tab-click path consults it, and that the init path does not – not merely that the functions exist – and each assertion must fail when its guarded declaration is deleted. The live behavioural proof for S01–S03 is UI-SMOKE-TEST TC-09 on the `visual` profile, run as part of this story rather than deferred to S14.
- Settings has no template test file under `test/templates/`; its server-side assertions live in `test/web/settings_page_test.dart`, which is where TI11's re-pointed class assertions belong.

### Validation

- Live UI smoke case for this story: TC-09 (Settings Page) on the `visual` profile at port 3338.
- Close-out visual pass against TI01's story-start captures, all ten tabs, in both themes at 1440px and 768px. A diff that does not trace to a task here is reported, not absorbed.

### Execution Contract

- TI01 must complete before any other task – its captures are the only valid comparison baseline for this story.
- TI02 and TI03 both rewrite `activateSettingsTab`; run TI02 first so the dirty guard lands before the panel-toggling mechanism changes underneath it.
- TI05 precedes TI06 – the width modifier is applied to controls whose well structure has already settled.
- TI08 precedes TI09 – both rewrite `populateSettingsForm`'s `input.disabled = false; input.placeholder = '';` pair (:181-182), and TI09's conditional-enable rule must be applied on top of TI08's placeholder and skeleton handling rather than clobbering it.


## Final Validation Checklist

- [x] Every deferral and disposition this FIS names – the `allowedValues` half of TI09 plus its `agent.provider` mirror, the absent `FieldMeta` default-value surface behind TI08's placeholder wording, the settings IA regroup, the tab-strip pairing counts, the `restart_banner.html` fix handed to S12, and the custom-select enhancement gap recorded **closed by canon** with its reasoning – is recorded in Implementation Observations, so each counts against the release's glitch ledger rather than vanishing.


## Implementation Observations

### Run: 2026-07-30 06:52 UTC – observations

#### FIS AMENDMENT AUDIT — TI07 Verify line (criteria amendment, direct edit, both copies)

Ledger: `S11-TI07-VERIFY-SCOPE` (OPEN, class `spec-stale`) in `s11-surface-sweep-settings.reconciliation-ledger.md`.

- **Old:** ``and `rg -n 'icon-triangle-alert' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1``
- **New:** ``and `awk '/^function updateMutabilitySummaries/,/^}/' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js | rg -n 'icon-triangle-alert'` exits with code exactly 1 (block-scoped: TI08's `banner banner-error` recipe legitimately carries the same glyph elsewhere in the file)``
- **Why:** TI07's stated intent is that the mutability note carries no alert glyph ("neutral helper copy carrying a warning triangle is the same defect in another layer – the icon goes with the blend"). The file-wide grep was written when the note held the only occurrence. TI08, in the same FIS, mandates the persistent-failure recipe from `templates/workflow_detail.html`, whose `banner banner-error` opens with `<span class="icon icon-triangle-alert">` — and canon's `.banner-error` supplies no glyph of its own, so dropping it would leave the banner's severity on colour plus copy alone. The amendment scopes the assertion to the function TI07 names, leaving TI07's intent falsifiable and TI08's recipe intact. Intent, Expected Outcomes and Acceptance Scenarios are unchanged.

#### DEFERRALS FOR THE S14 GLITCH LEDGER

Each is barred by an in-FIS constraint, not skipped. No target milestone.

1. **`allowedValues` for `agent.effort`** (`settings/agent`, HIGH — the UI half is closed by TI09). The control is now non-actionable while its allowed-value list is empty and its blank option reads "Default" rather than an em dash. The real fix is `allowedValues` on `agent.effort` in `dartclaw_config/lib/src/config_meta.dart:320`, which changes the `/api/config` meta payload and needs a product decision on the legal value set — barred by *No backend work*.
2. **`agent.provider` rendered as free text** (mirror of 1). `config_meta.dart:314` declares no `allowedValues`, so an enumerable value renders as a text input. Same config-metadata change, same product decision, same bar.
3. **No default-value surface on `FieldMeta`.** `FieldMeta` carries `yamlPath` / `jsonKey` / `type` / `mutability` / `nullable` / `min` / `max` / `allowedValues` and no default, so the client cannot read the effective default for `agent.model`, `agent.max_turns` or `agent.effort`. TI08 therefore names the inherited value only where the payload already carries it (`workflow.defaults.*`, which fall back through `workflow.defaults.workflow.*` to `agent.*`) and otherwise says the field is unset without naming a value. Same bar as 1 and 2.
4. **Settings information architecture — three items, all barred by *Out of Scope: new UX capabilities*.** (a) Regrouping ten flat tabs into 3–4 sections. (b) Moving Authentication / System Health / Workspace out of "Server" (all three remain `data-tab="server"` panels). (c) Surfacing pending-pairing counts on the tab strip — the per-channel `.pairing-badge` still renders inside the Channels cards only.
5. **`restart_banner.html:7,8` carry `btn-sm btn-primary` / `btn-sm btn-ghost dismiss` with no base `.btn`.** Reported, not fixed: S12 owns the shell surface, and this FIS's *What We're NOT Doing* hands it over explicitly. `restart_banner.html` is byte-identical to the story-entry snapshot (`cmp -s` clean).

#### DISPOSITION — custom-select gap is CLOSED BY CANON, not deferred

The audit's "only 2 of 17 selects get the `custom-select` enhancement" finding is closed, not omitted. S03 gave canon a real `select.form-select` with a chevron affordance, so settings' nine native selects are branded without the listbox; `.custom-select` stays the narrow escape hatch DESIGN.md § Native selects describes. Adding `data-enhance="custom-select"` to nine more selects would be new work in the opposite direction. Verified live: the Logging Level / Logging Format / scope / backend / Effort selects all render the canon chevron.

#### DISCOVERED DEFECT — the form was born dirty (fixed under TI02)

Making the computed dirty flag observable exposed a latent defect in the diff both `updateFormDirtyState` and `handleFormSave` ran. A control reports an untouched nullable field as `''` while the config carries `null`, so **every** unset field read as an edit: on the seeded `visual` profile all eight forms loaded dirty with Save actionable, and Save would have PATCHed `agent.effort: ''` for a field nobody touched. Latent before this story only because the dirty result was discarded. Fixed by one shared `fieldChanged(initial, current)` / `normalizedFieldValue(value)` pair used by both the dirty check and the save payload, so the two cannot disagree about what changed; a legitimate `0` or `false` is preserved. Without it Acceptance Scenario S01 fails at "the Save control … returns to its non-actionable state" and S05 fails at "rather than reporting a phantom unsaved edit". Live after the fix: all 8 forms `data-dirty="false"`, all 7 Save controls disabled at load.

#### CORRECTION — `settings.dart`'s `workerState` is NOT dead; it was not removed

S16's Implementation Observations record `settings.dart`'s `workerState` parameter as "dead (accepted but never placed in the template context) — S11's to remove". The first clause is literally true and the conclusion is wrong: `settings.dart:46` switches on `workerState` to derive `healthLabel` / `healthVariant`, which become `healthBadgeHtml` at `:53` and reach the context at `:99`. Removing the parameter would blank the System Health badge on the Server tab. **Left in place deliberately**; recorded here so the instruction is not re-issued to a later story. `settings_page.dart:76` still feeds it `status['worker_state']`.

#### NOTICED BUT NOT TOUCHING

- **`t-label` and `t-body` are the same size by canon design.** `design-system.css` gives both `--text-base`; they differ only in weight (500 vs 400). TI07's Verify asks for "three distinguishable sizes" for card title / field label / value. Measured live after the change: title 18px/600 (`.t-heading`), label 14px/500 (`.t-label`), value 14px/400 (`.t-body`), cluster label 12px/400 caps-tracked (`.t-caption.tracking-caps`) — three distinct sizes across the four roles, with label-vs-value separated by weight rather than size. No canon rule is missing, so nothing was hoisted; the tier pair is simply size-equal by construction. Before the change all three rendered at 14px.
- **`app.css` `.guard-editor-message`, `.guard-editor-error`, `.guard-editor-value`, `.guard-editor-shell` and the `.guard-editor-form-row` / `.guard-tester-row` flex rule survive** — all still have live consumers (the tester result line, the "No editable extensions" cell, the mono value cell). Only `.guard-editor-tab`, `.guard-editor-tab.active`, the `.guard-editor-tabs` member of the shared flex selector, and `.guard-editor-table`'s border / padding / `th` blocks were deleted.
- **`.card-detail-value` on the System Health rows is a colour-only app class** and stays; the version row now composes `value-absent` through a new `versionClass` hook rather than rendering blank.

#### SCOPE NOTES — edits made outside the FIS's enumerated `app.css` blocks

The FIS's Work Areas name `.section-note*`, `.guard-editor-tab*` and `.guard-editor-table`. Two further edits were made, both orphans this story's own template change created, both inside the settings-local `/* === SETTINGS === */` block and with no consumer outside `settings.html`:

- **`.settings-header`, `.settings-header h1`, `.settings-header p` deleted.** TI07 deletes the in-page `<h1>`; the head is now S16's shared `pageHeader` fragment (`pageHeaderTemplate(subtitle: 'Configuration and system status')`, no title — the topbar owns the `<h1>`). The three rules had no other consumer.
- **`.settings-card .card-title` reduced to `color: var(--fg)`.** Its `font-size: var(--text-base)` / `font-weight: var(--weight-bold)` are specificity (0,2,0) and would out-specify the `.t-heading` (0,1,0) TI07 requires on the markup, so the card title could not have moved to the heading tier without this. Mirrors the shape canon uses for `.empty-state-title` (colour only; the markup composes the tier).

Two class tokens `settings.html` emitted resolved to no rule, failing the "every class resolves" Structural Criterion. Both were confined to this story's two files and were retired rather than routed to the closed canon:

- **`.font-mono` retired from the two guard inputs.** No rule exists in `design-system.css`, `icons.css` or `app.css` (S06 recorded it and routed it to the canon owner). It is a no-op in this product regardless: `html { font-family: var(--font-mono) }` and the controls declare `font: inherit`, so the inputs were already mono. These were its only two usages repo-wide, so the class is now gone from the product and the canon owner has nothing left to add.
- **`.form-cancel` moved to `data-form-cancel`.** A pure behaviour hook with no CSS rule; every other hook on this surface is already a `data-*` attribute (`data-field`, `data-guard-editor-*`, `data-mutability-summary`). Only consumers were `settings.html` and `dc_settings_controller.js:573`, both in this story's Work Areas.

#### ASSUMPTIONS (owner-directed validation protocol)

The orchestrator relayed an owner directive slimming this phase's validation: keep functional verification of own changes (touched surfaces, primary theme full + second theme spot-check, 768px only where responsive behaviour changes), targeted tests, drift + parity when touching embed roots, analyze + format, one quick-review pass; drop story-start captures, regression sweeps, full test suites, `arch_check` / fitness, extra review passes — with dirty-state tracking explicitly excepted and required to carry a real test.

- **TI01 (40 story-start captures) was not performed**, and the matching Structural Criterion is satisfied under the directive rather than by evidence. Close-out validation was done against the live surface and the FIS's own Acceptance Scenarios instead of against a before-image, so a regression outside this story's scope on `/settings` would not have been caught by diff. Everything TI01 exists to protect on the tabs this story restructures was checked directly: all ten tabs render exactly one selected tab and the right panel group, nothing overflows its card, and every panel holds the 900px measure.
- The `dart test packages/dartclaw_server` full-package run named by TI11 **was** run (3151 pass, 3 skip) — the directive's "drop full test suites" was not applied to the story's own package, because TI11's canon-parity and generated-asset assertions live in it.
- `arch_check` / fitness beyond `check_design_system_sync.sh` (which TI11 names explicitly, exit 0) was not run.

#### VALIDATION EVIDENCE — live, `visual` profile, own port 3351

Server started detached and stopped by PID; `.dart` template changes validated on that fresh instance.

- **S01** Max Turns edited then restored: `dirty false → true → false`, Save `disabled → enabled → disabled`.
- **S02** Model edited, Providers clicked: dialog "Discard unsaved changes?" with Cancel / Discard, `panel-agent` still the only visible panel and "Agent" still selected while it was open. Cancel: dialog gone, edit intact, still dirty, no panel move. Discard: edit dropped, form clean, `panel-providers` shown, hash `#providers`. Back to Agent: no second warning.
- **S03** `#security` in the fragment on a clean URL activates the Security panel at load with no dialog; Memory click switches with no dialog. (The `?token=` auto-auth URL loses the fragment across its 302 — a harness artifact of that URL form, not the init path.)
- **S04** Page strip: `role="tablist"`, ten `role="tab"`, exactly one `aria-selected="true"`, sixteen `role="tabpanel"` with unique ids, every `aria-controls` token resolves. Panels toggle the `hidden` attribute. Arrow/Home/End move selection; roving `tabindex` keeps one tab stop. At 768px the strip overflows (878 > 736), no tab wraps, labels are `nowrap`, the overflow cue is opacity 1 at scroll-left 0 and 0 at the end, and "Security" is fully visible once scrolled. Sticky strip computes `backdrop-filter: blur(14px)` over a translucent fill — no opaque slab. Guard strip renders from `.tabs` / `.tab` with the same roles and arrow-key behaviour.
- **S05** `/api/config` forced to reject: 8 `banner banner-error` cards each with Retry, still on screen after 11 s with 0 toasts, no "Loading..." anywhere, no shimmering skeleton left running. Retry with the fault cleared: banners gone, fields repopulated (`provider = claude`), guard editor rebuilt (4 tabs, 2 rows), a typed edit marks the form dirty and Save re-enables — no phantom edit. `/api/config/guards` forced to 500 independently: its own banner, `dataset.loaded` **unset** on failure, banner survives 10 s, Retry genuinely re-fetches (`dataset.loaded = 1`, tabs and rows appear).
- **S06** 4 s-delayed config response: 28 skeletons visible with `animation-name: skeleton-shimmer`, 28 controls hidden, zero visible disabled boxes, no "Loading..." text; all clear on populate. Unset `workflow.defaults.planner.provider` reads "Inherits claude"; unset models read "Unset (inherits the agent default)"; `agent.model` reads "Unset (server default applies)". Effort is disabled with a single "Default" option.
- **S07** Type: 18px/600 title, 14px/500 label, 14px/400 value, 12px caps cluster label. Workflows renders four labelled role groups, not eight rows. Port 101px and Host 269px inside a 900px card. Restart note is `rgb(158,163,187)` with no `section-note-restart` class and no icon.
- **Contrast** card-vs-ground 1.28 (dark) / 1.24 (light), both ≥ 1.15. Text pairings: dark 7.37–14.51, light 4.52–7.99, all ≥ AA. No settings state is carried by colour alone.
- **Canon footprint zero**: `git diff --no-index` on `dev/design-system` clean, `cmp -s` clean on all three served copies, `check_design_system_sync.sh` exit 0, `restart_banner.html` byte-identical. No `.tabs` rule, `max-width` or `--text-sm` added to `app.css` (net −38 lines).

#### RESOLVED CONFLICT — a 12ch cap cannot hold TI08's unset sentence

TI06 caps Max Turns at `.form-input--num` (12ch); TI08 wants an unset nullable field to say the server default applies. Live, the placeholder truncated to "Unset (". Rather than widen the control (TI06 names Max Turns explicitly) or truncate the message, `agent.max_turns` was dropped from the placeholder set and given a static `.form-hint`, "Leave empty to use the server default." — same fact, no value named, at a width that holds it. `agent.model` and `agent.effort` are unaffected: the first is a full-width control and the second carries its "Default" option label.

### Run: 2026-07-30 07:14 UTC – observations

#### POST-REVIEW REMEDIATION (quick-review critic pass, fresh context)

Eleven findings; four dismissed or routed Note, seven fixed. All fixes are in `dc_settings_controller.js`, `settings.html` and `app_js_test.dart`, and each was re-verified live on the `visual` profile.

1. **Clearing a valued field persisted `''`, not an unset value.** `fieldChanged` normalised both sides of the diff, but `changes[field] = current` shipped the control's raw `''`. `config_validator.dart:307` accepts `''` for a nullable string, so `agent.model: ""` would have persisted as an empty string, and TI08's new "Unset (server default applies)" placeholder actively invites the operator to clear the field expecting a reset. The diff and the payload now share `normalizedFieldValue`, so a cleared field sends `null`. Non-nullable fields (Host, Port) now get a per-field "cannot be null" error (`config_validator.dart:246`) instead of silently persisting a blank. Verified: clearing Provider and saving emits `{"agent.provider":null}`.
2. **Save was live and unintercepted before the first successful load and after a failed one.** `attachSettingsListeners` ran only in `loadSettingsConfig`'s success branch, so on the failure path the Save button was an uncaptured `type="submit"` in an actionless form — one press natively navigated and took the persistent `banner banner-error` with it, breaking Scenario S05's "still on screen after 10 s" the moment the operator touched the card's most prominent control. Fixed twice over: `initSettingsForm` now attaches the listeners before dispatching the fetch (both handlers already no-op without a baseline), and the template ships Save `disabled`, which is the honest pre-load state. Verified on a cold failing load: 8 banners, Save disabled, submit intercepted, URL unchanged.
3. **Typing during an in-flight save re-armed the button.** Any `input` event ran `updateFormDirtyState`, which recomputed `saveButton.disabled = !dirty` and re-enabled a button `handleFormSave` had deliberately disabled — a second click sent a duplicate PATCH computed against a baseline the first had not yet re-written. Save now also keys on `form.dataset.saving`, set for the life of the request.
4. **A snapshot-restored `data-dirty` could raise an undismissable dialog.** `dirtyFormsLeaving` returns early unless `settingsInitialConfig` exists. Without the guard, a `data-dirty="true"` restored from an htmx history snapshot into a document where the baseline is null would raise the discard dialog on every departure and `handleFormCancel` would no-op, so the flag could never clear.
5. **The tab widget was attribute-complete but keyboard-incomplete.** Three corrections: Space now activates a focused `role="tab"` (an anchor does not implement it natively, but the role announces it); ArrowUp/ArrowDown are no longer intercepted, because both strips are horizontal and eating the vertical arrows eats page scrolling from a focused tab; and focus now *follows* activation rather than leading it — previously a cancelled discard left focus on a tab that was neither `aria-selected` nor in the tab order. Verified: Space activates, ArrowDown does not move selection, ArrowRight does, and after a cancelled discard the strip still has exactly one tab stop with focus on it.
6. **The guard editor's shared panel had no accessible name.** Its tabs now carry `id="guard-editor-tab-<guard>"` and `renderGuardEditor` points `#guard-editor-panel`'s `aria-labelledby` at whichever guard is currently rendered into it.
7. **Two test gaps and one test-harness vacuity seam.** The dirty-state group pinned the declarations but not the two load-bearing call paths — the `input`/`change` listeners that recompute the flag and the Retry pipeline's re-baseline — so either could be deleted with every test green. Both are now asserted, plus the payload normalisation from finding 1. Separately, `_jsFunction` sliced to the next column-0 `}`; a future nested construct closing at column 0 would truncate the slice and make every `isNot(contains(...))` assertion below it pass vacuously. It is now brace-balanced. All four new guards were mutation-tested: removing the input listener, the Retry re-baseline, the payload normalisation, or the in-flight guard each turns the group red.

Routed **Note**, not fixed:

- **A nullable select with a non-empty `allowedValues` would load dirty.** Option injection selects nothing when the config value is null, so the browser shows `option[0]` as if set and the diff reports `null` vs `option[0]`. Latent — every populated select on the seeded profile carries a value — and the fix needs a product decision (what a blank option is labelled), which the no-backend-work and no-new-capabilities constraints put out of reach. Recorded for the S14 ledger.
- **Dirty edits are still discarded silently on a non-tab navigation** — sidebar links, topbar, browser Back. OC01 and Scenario S02 scope the guard to the tab switch, and the audit glitch is filed as `settings/all-tabs`, so this is a boundary the FIS drew rather than one this story missed. Recorded here so it does not read as an unexamined gap.
- The pre-existing DOM-attribute init-guard pattern (`data-settings-init`, `data-listeners`, `data-loaded` inside `hx-history-elt`) survives an htmx history restore and can leave a form with no listeners. Pre-existing at HEAD and shared with other surfaces; not this story's to redesign.
- `app_js_test.dart`'s pre-existing `hasLength(4)` count of `group.querySelector('.form-toggle')` spans the whole controller file, coupling a settings assertion to the channel-detail half this story does not own. Pre-existing; left alone.

#### REGRESSION OUTSIDE THIS STORY'S SCOPE — reported, not absorbed

`test/templates/render_test.dart` "layout includes document chrome, assets, requested scripts, and escaped title" fails on `Expected: contains 'htmx.org'`. `lib/src/templates/layout.html:22` now serves `/static/htmx.min.js` instead of the CDN URL the test still expects. `layout.html` was modified at 08:52 today, mid-run, by a concurrent worker; `render_test.dart` was last touched at 05:58. Neither file is in this story's Work Areas and neither was touched here. This is the local-vendoring story's assertion to re-point. `dart test packages/dartclaw_server` was 3151 pass / 3 skip / 0 fail earlier in this run, before that edit landed; it is now 3155 / 3 / 1 with that single failure. Every S11-owned suite is green (57 tests across `app_js_test.dart` and `settings_page_test.dart`).

### Run: 2026-07-30 07:19 UTC – observations

#### CLOSE-OUT — ledger reconciled, TI01 basis restated, htmx regression routed

**`S11-TI07-VERIFY-SCOPE` reconciled.** The stale side was the spec, not the as-built. TI07's Verify line and TI08's mandated recipe were unsatisfiable together: TI07 asserted `rg -n 'icon-triangle-alert'` exits 1 across the whole of `dc_settings_controller.js`, while TI08 requires the `banner banner-error` recipe from `templates/workflow_detail.html`, which opens with that glyph — and canon's `.banner-error` supplies none of its own, so removing it would leave the banner's severity on colour plus copy alone. The Verify line is now block-scoped to `updateMutabilitySummaries` in both copies (Old:/New: spans in the first run block's `#### FIS AMENDMENT AUDIT`), which keeps TI07's actual intent — the always-on mutability note carries no alert glyph — falsifiable. No code was shaped to fit the assertion; Intent, Expected Outcomes and Acceptance Scenarios are untouched. The ledger entry also gained the full rationale as a `Notes:` line and had its stale-targets private path repo-qualified to `dartclaw-private/docs/specs/0.22.1/fis/s11-surface-sweep-settings.md`, which previously read as a public-repo path.

**TI01 and its mirror Structural Criterion are ticked on an owner ruling, not on capture evidence — and the FIS text is what is stale, not the work.** The owner directive relayed mid-run by the orchestrator dropped story-start captures from this phase's validation protocol outright, so the 40 captures TI01 specifies were never in scope by the time this story executed. The tick records "satisfied under the directive"; it does not claim the captures exist. The consequence is stated plainly in the first run block's `#### ASSUMPTIONS` section and is restated here so a reader arriving at the checkbox does not have to reconstruct it: there was no before-image, so a `/settings` regression *outside* this story's scope had no diff to catch it. What TI01 protects on the surfaces this story actually restructured was verified directly instead — all ten tabs render exactly one selected tab and their correct panel group, no panel overflows its card, and every panel holds the 900px measure. S14 should read TI01 as amended by the owner directive rather than as an unevidenced tick.

**The `htmx.org` regression is routed to S13, not parked for S14.** `test/templates/render_test.dart` expects the CDN URL that `layout.html:22` no longer emits after the vendoring swap (`/static/htmx.min.js`). Both files belong to S13, which is live concurrently; its executor has been messaged directly with the failing assertion, the mtime evidence (`layout.html` 08:52, `render_test.dart` 05:58) and the suggested fix. No ledger entry was opened for it: it is another story's red test, not S11 spec-vs-code drift, and duplicating it into this story's ledger would give S14 two owners for one defect.

**Generated assets.** `embedded_assets.g.dart` was regenerated after the last S11 embed-root change. It is a shared artifact with S13 this wave — any font, htmx or marked entries in its diff are S13's vendoring, deliberately left in place.

### Run: 2026-07-30 07:34 UTC – observations

#### DIRTY-STATE COVERAGE UPGRADED TO A BEHAVIOURAL TEST (orchestrator ruling)

The first pass covered TI02 with source-substring assertions on `dc_settings_controller.js`, on the stated premise that "there is no JS runtime harness here (zero-npm)". **That premise was false**: S10 shipped `test/static/mode_commit_scheduler_test.dart`, which drives real controller JS through Node with injected timers and asserts behaviour — same repo, same zero-npm constraint, no new dependency. The stale claim was also written into the test group's own comment, where it would have misled the next story. Both are corrected.

Why it mattered rather than being a style preference: a source-substring assertion fails when the *text* changes, which is not the property the plan's risk mitigation asks for ("a test that FAILS if Save stops reflecting unsaved edits or a tab switch discards them"). A refactor that preserves the strings while severing the wiring passes; a correct rewrite that renames a variable fails. Proven concretely below — the source layer does not notice `dirtyFormsLeaving` losing its incoming-tab guard.

**New file: `packages/dartclaw_server/test/static/settings_dirty_state_test.dart`**, modelled on S10's harness (Node, `--input-type=module`, `markTestSkipped` when Node is absent, minimal `document`/`Stimulus` globals, element stubs whose selector strings match production exactly so a change on either side breaks the test rather than passing vacuously). It covers, as behaviour: an edited text field marking the form dirty and arming Save; the same for a **textarea** — the regression that was silently broken for the whole life of the feature, since `getFieldInput` queried only `input, select`; reverting an edit clearing the flag and disarming Save; a cleared field diffing as unset and being *sent* as `null` rather than `''`; the converse, that an untouched field which is unset in config reads clean (the born-dirty defect); a legitimate `0` surviving as a value; toggles staying out of the diff and the payload; Save staying inert while a save is in flight; and `dirtyFormsLeaving` returning the forms in the cards about to be hidden while skipping the incoming tab, already-hidden cards, clean forms, form-less tabs, and any call with no baseline.

**Production change the test drove.** `updateFormDirtyState` and `handleFormSave` ran two near-identical traversals with the same toggle exclusion and the same normalisation — a standing invitation for the flag and the payload to disagree. They now share one exported `formChanges(form, initialConfig)`, with `applyFormDirtyState(form, dirty)` naming the observable write and `dirtyFormsLeaving(grid, tabId, initialConfig)` taking its grid and baseline as arguments instead of reading module globals. The dirty flag is now *by construction* "the save payload is non-empty", which is what the earlier comment only asserted. Three exports, each a real seam with a behavioural contract — the shape S10 set with `createModeCommitScheduler`.

**Mutation evidence, and the division of labour between the two layers.** Nine wiring breaks were introduced one at a time and reverted. The behavioural test catches every break in what the operator observes: textarea dropped from the field lookup, the Save control no longer reflecting dirty, the flag never written, a cleared field sent as `''`, `''` no longer folded to unset, the toggle exclusion removed, the incoming tab no longer skipped, the stale-flag baseline guard removed, the in-flight save guard removed. The source-level layer was kept and re-pointed, because it catches a class the behavioural one cannot reach — whether the computation is *invoked* from the paths that must invoke it and skipped on the one that must not. Verified by construction: breaking the `input` listener, the Retry re-baseline, or the click path's routing through the discard guard leaves the behavioural test green and turns the source layer red; removing `dirtyFormsLeaving`'s incoming-tab guard does the reverse. Neither layer subsumes the other.

Live re-validation after the refactor, on the `visual` profile: all eight forms pristine at load, an edit arming Save and a revert disarming it, the textarea now dirty-tracked end to end, the discard dialog still guarding a tab switch away from a dirty Context tab (cancel keeps the edit, confirm drops it and moves the panel), and a cleared Provider still emitting `{"agent.provider":null}`. Full package suite green: 3156 pass, 3 skip, 0 fail — the `htmx.org` regression reported earlier has been re-pointed by S13, so that hand-off is closed.
