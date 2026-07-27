# Surface sweep: settings

**Plan**: docs/specs/0.22.1/plan.json
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
> […] ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes, because the check pins a sha256 on line 2 of each served copy and concurrent edits in the parallel P3 wave conflict on that line by construction. […] A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

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

### From `plan.json` – shared decision "Visual-baseline protocol — story-start captures, not the audit set"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> Protocol: each story captures its own story-start screenshots of the surfaces it touches, in both themes at desktop and 768px, and validates against those. The audit's 92-shot set stays the release-level baseline that S14 re-proves once. A story that finds a regression outside its own scope reports it rather than absorbing it.

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

- [ ] **S01 [OC01] [TI02] Save reflects whether there is anything to save**
  - **Given** `/settings` is loaded on the `visual` profile and the Agent card's fields hold their persisted values
  - **When** the operator types a new value into Max Turns and then restores the original value
  - **Then** the Save control becomes actionable while the value differs and returns to its non-actionable state once it matches again, and pressing Save on the pristine form is not the way the operator learns there were no changes

- [ ] **S02 [OC01] [TI02] Switching tabs with unsaved edits does not discard them silently**
  - **Given** the Agent card has an edited, unsaved Model value
  - **When** the operator clicks the Providers tab
  - **Then** a dialog titled "Discard unsaved changes?" appears before the Agent card is hidden; cancelling leaves the operator on the Agent tab with the edited Model value still in the field and the form still dirty, and confirming discards the edit and shows Providers – in no path is the card hidden without the operator having seen the warning, and returning to Agent after confirming shows the persisted value with no second warning

- [ ] **S03 [OC01] [TI02] A clean tab switch and the initial page load are not interrupted**
  - **Given** `/settings` is loaded with `#security` in the URL fragment and no field has been edited
  - **When** the page performs its initial tab activation and the operator then clicks Memory
  - **Then** neither transition raises a warning, the Security panel is the one shown at load, and the Memory panel appears on the click without an intervening dialog

- [ ] **S04 [OC02] [TI03,TI04,TI10] Every tab strip on the surface is the one canonical tab component**
  - **Given** `/settings` rendered at 768px in light theme, scrolled to the top, and the Security tab's guard editor loaded
  - **When** an assistive-technology user reaches either strip and a touch user reaches for the tenth section
  - **Then** the page strip announces as a tab list with exactly one selected tab whose panel is identified by `aria-controls`, the inactive panels are `hidden` rather than inline-`display:none`, "Security" is reachable with a visible affordance that content continues past the fold, the sticky strip shows no hard-edged slab seam against the body gradient, and the guard-editor strip renders from the same `.tabs` / `.tab` component with the same arrow-key behaviour rather than its own `.guard-editor-tab` pill recipe

- [ ] **S05 [OC03] [TI08] A failed load leaves a persistent, retryable failure – not a wall of disabled boxes**
  - **Given** `/api/config` is made to reject for the settings page load, and separately `/api/config/guards` is made to reject for the Security tab
  - **When** each page area renders and its fetch fails, and the operator waits 10 seconds
  - **Then** each card body carries a `banner banner-error` with a Retry control that is still on screen after the toast has expired, no field is left stuck reading "Loading...", pressing Retry repopulates with dirty tracking intact rather than reporting a phantom unsaved edit, and the guard editor's Retry actually re-fetches rather than being a no-op left behind by a load-flag set before the request resolved

- [ ] **S06 [OC03] [TI08,TI09] Settings distinguishes "loading", "inherited" and "cannot be set"**
  - **Given** a slow `/api/config` response, and `agent.effort` still declaring no allowed values
  - **When** the Workflows and Agent tabs render in-flight and then populate
  - **Then** in-flight fields render as skeleton blocks rather than disabled boxes reading "Loading...", an unset `workflow.defaults.*` provider or model states the value it inherits from the config payload, the unset Model and Max Turns fields say the field is unset and the server default applies without naming a value the client cannot read, and the Effort control is not presented as an enabled picker whose only option is blank

- [ ] **S07 [OC04] [TI05,TI06,TI07] A settings card reads as a hierarchy, not a stack**
  - **Given** the Workflows tab, whose nine fields are semantically four role pairs (provider + model) plus a workspace directory, and the Agent tab's two-character Max Turns field
  - **When** an operator scans either tab
  - **Then** each role pair reads as one labelled group, "Agent Configuration", "Provider" and the value "claude" render at three distinguishable sizes, Max Turns is visibly narrower than its card rather than spanning it, and the "Changes apply after a server restart" note reads as neutral helper copy on a single divider rather than a warning-toned band


## Structural Criteria

- [ ] Story-start captures of `/settings` – all ten tabs – exist in both themes at 1440px and 768px, and every close-out diff against them traces to a task in this FIS or is reported rather than absorbed.
- [ ] `settings.html`'s tab strip carries `role="tablist"`, each control carries `role="tab"` with `aria-selected` and `aria-controls`, each `[data-tab]` card carries `role="tabpanel"` with a unique `id`, panels toggle the `hidden` attribute rather than inline `style.display`, and no `aria-current="page"` remains on a tab.
- [ ] Both strips on the surface – the page tab strip and the guard-editor strip – render from canon's `.tabs` / `.tab`; `.guard-editor-tab` appears in no template, controller or stylesheet, so the release's "only one tab bar ships" bar holds on this surface.
- [ ] `settings.html` emits no `<h1>`; the topbar is the page's only one.
- [ ] Every `settings.html` field cluster of two or more semantically-related fields sits inside a `.well`, and no short numeric control (Port, Max Turns, Reset Hour) stretches to the container measure.
- [ ] Every class emitted by `settings.html` resolves to a rule in `design-system.css`, `icons.css` or `app.css` (the icon family lives in `icons.css`, which is canon-owned and served alongside the other two).
- [ ] The `app.css` `.guard-editor-*` block declares only genuinely local properties – no border, `text-transform` or cell padding that `design-system.css#.data-table` already provides, and no tab-pill recipe canon's `.tab` already provides.
- [ ] The composite `.t-*` classes carry the type on `/settings`, this story adds no new `--text-sm` usage, declares no font-size on the off-scale badge rules S07 owns, and applies no `--container-wide` / `.content-inner--wide` / `.page-inner--wide` modifier to settings – the plan assigns it the 900px measure.
- [ ] Card-vs-ground contrast is ≥ 1.15:1 and WCAG AA text contrast holds on `/settings` in both themes; no settings state is conveyed by colour alone.
- [ ] This story's canon footprint is zero: `dev/design-system/`'s three drift-checked files and their served copies are byte-unchanged, `dev/tools/fitness/check_design_system_sync.sh` still exits 0, `lib/src/generated/embedded_assets.g.dart` is untouched, and the existing template and JS tests pass with assertions re-pointed at the canonical classes.
- [ ] No `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` appears in `dc_settings_controller.js`.


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
**Why this over alternatives**: an `app.css` width cap or tab-pill recipe on a canonical form or tab class fails the drift check by definition and recreates exactly the two-implementations rot 0.22 produced; and authoring the canon rule here instead would collide on the served copies' `sha256:` line with the four sibling W2 sweeps, which is why the plan hoisted both rules into S03.


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
- **Critical**: canon is CLOSED to this story. The two rules this sweep needs – the short-field width scale and the `.tabs--sticky` material – were hoisted into S03 and arrive with it; this story consumes them and writes nothing under `dev/design-system/`'s three drift-checked files -- Must handle by: if a further canon rule turns out to be missing, stop and report it for hoisting into the owning P1 story rather than adding it. An `app.css` cap or tab recipe on a canonical class fails the drift check, and authoring canon here would collide with four sibling W2 sweeps on the served copies' `sha256:` line. `DESIGN.md` and `showcase.html` are not drift-checked and stay writable for any contract this story documents.
- **Critical**: this story consumes two S06 outputs even though the plan records only `dependsOn: ["S07", "S16"]` -- Must handle by: not starting before P3-W1 closes. `confirmDialog` does not exist in `controllers/shared.js` until S06 adds it, and TI02's zero-native-dialog gate can only pass once S06 has removed the two `window.prompt()` calls at `dc_settings_controller.js:569,573` – those two are S06's to remove, not this story's.
- **Avoid**: fixing a surface complaint by re-declaring a card, chrome or ground tone locally -- Instead: report it against S01's tokens per the surface-token shared decision.
- **Avoid**: reaching for a raw `--text-xs` for the new cluster labels (the audit's own fix text says `--text-xs`) -- Instead: apply `.t-caption`, which binds size, weight, line-height and caps tracking together per the composite type-class decision.
- **Constraint**: this story runs in the same parallel wave as S08–S10 and S15, which also edit `app.css` -- Workaround: confine edits to the `.section-note*`, `.guard-editor-tab*` and `.guard-editor-table` blocks this FIS names; do not reflow unrelated regions of the file. `.guard-editor-tabs` shares its rule head with `.guard-editor-actions`, `.guard-editor-form-row` and `.guard-tester-row` (:3689-3696) – drop only its member from the selector list, not the block.
- **Constraint**: S07 alone normalizes the hard-coded off-scale font sizes (`.provider-badge` and siblings) -- Workaround: apply the `.t-*` classes to settings markup, but never re-declare a size on those rules while editing the same file.
- **Avoid**: regenerating `lib/src/generated/embedded_assets.g.dart` -- Instead: leave it stale; S14 owns the single end-of-release regeneration, and doing it per story conflicts across the P3 waves.
- **Critical**: `test/templates/tasks_s11_test.dart` is pre-existing and belongs to a *previous* milestone's story numbering -- it is not this story's test file and must not be repurposed. New assertions go in `test/static/app_js_test.dart` and `test/web/settings_page_test.dart`.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** This story has its own before-image to validate against
  - Capture `/settings` on the `visual` profile (port 3338, `bash dev/testing/profiles/visual/run.sh`) with each of the ten tabs active, in dark and light at 1440px and 768px, per the plan's visual-baseline shared decision – the audit's 92-shot set predates S01's re-tone and S02's re-scale and cannot isolate this story's deltas.
  - **Verify**: 40 story-start captures exist (10 tabs × 2 themes × 2 viewports) and are the diff target used at story close

- [ ] **TI02** The settings form's dirty state is observable, and a tab switch cannot discard it silently
  - `dc_settings_controller.js#updateFormDirtyState` computes `dirty` and returns without using it (its six call sites already fire on `input`, `change`, submit-failure, post-save and cancel); its result must reach the form and its Save control. `activateSettingsTab` must consult the forms inside the card(s) it is about to hide, on the operator-click path only – not on the init-time activation. No second dialog implementation: the warning routes through the `confirmDialog({title, body, confirmLabel, danger})` helper S06 put in `controllers/shared.js`, called with title `"Discard unsaved changes?"`, `confirmLabel: "Discard"` and `danger: true`, and the panel/strip/`history.replaceState` updates happen only after it resolves. The dialog is a discard confirmation, not a save prompt: cancel returns to the originating tab with the edit and the dirty flag both intact; confirm discards the edit, restores the fields from `settingsInitialConfig` and re-baselines the form, so the same warning cannot fire a second time for an edit the operator already chose to drop. The post-save call already re-baselines `settingsInitialConfig`, so a saved form must come back clean too.
  - **Verify**: `Test: app_js_test.dart asserts updateFormDirtyState assigns its computed dirty result to observable form/button state, that the tab-click path consults it before hiding a card, that the init-time activation path does not, that the confirm branch restores fields from settingsInitialConfig and clears the dirty flag (fails if confirm silently retains the edit), and that the cancel branch neither restores fields nor switches panels (fails if cancel loses the edit) – each assertion fails when its guarded declaration is removed`; live on `/settings`, scenarios S01, S02 and S03 hold, and `rg -n 'window\.(alert|confirm|prompt)|(^|[^.\w])(alert|confirm|prompt)\(' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1

- [ ] **TI03** The settings tab strip is a real tab widget, not ten dead anchors
  - Post-S05 the strip carries the canonical `tabs` / `tab` classes; this task adds the semantics S05 left alone – `role="tablist"` on the strip, `role="tab"` + `aria-selected` + `aria-controls` per control, `role="tabpanel"` + a unique `id` per `[data-tab]` card, the `hidden` attribute in `activateSettingsTab` in place of `card.style.display`, and `aria-current="page"` dropped (it announces "current page" for an in-page panel switch). Multiple cards share one tab id (four carry `data-tab="server"`), so panel ids must be unique and `aria-controls` carries the space-separated list of every panel a control governs. `hidden` genuinely hides a `.settings-card { display: flex }` panel because `app.css:1` declares `[hidden] { display: none !important; }` – no new CSS rule is needed, and none may be added. A role-bearing strip must also honour the keyboard contract those roles announce: Left/Right arrows move between tabs, Home/End jump to first/last, and a roving `tabindex` keeps exactly one tab in the tab order.
  - **Verify**: `rg -n 'role="tablist"|role="tab"|role="tabpanel"|aria-selected|aria-controls' packages/dartclaw_server/lib/src/templates/settings.html` returns all five and `rg -n 'aria-current|card\.style\.display' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1 (scoped to the panel path – `checkRestartBanner`'s `banner.style.display` at :196,:199 belongs to the restart banner this story does not touch); on `/settings` every `aria-controls` value resolves to an element that exists, clicking each of the ten tabs shows exactly one panel group, and from a focused tab the arrow keys move selection while Tab leaves the strip

- [ ] **TI04** All ten sections are reachable at 768px and the sticky strip sits on the ground rather than over it
  - Both halves of this outcome now arrive from canon: S03 carries the `.tabs--sticky` material correction (the flat opaque slab with hard seams over the body gradient in light theme at scroll-top, which S05 recorded as owned here) and the tenth tab's overflow affordance for the ten-tab row that clips at 768px. This task consumes them and proves them on the live surface – it authors no rule. If either is still wrong once S03 has landed, report it against S03 per the visual-baseline protocol rather than absorbing it, and do not reach for `app.css`.
  - **Verify**: `git diff "$(git merge-base main HEAD)" -- packages/dartclaw_server/lib/src/static/app.css | rg -n '^\+.*\.tabs'` exits with code exactly 1 (no app-side tab rule was added); at 768px "Security" is reachable and no label is clipped mid-word, and at scroll-top in light theme the strip shows no hard-edged seam against the gradient

- [ ] **TI05** Related settings fields read as one labelled group
  - `settings.html` has 31 `data-field=` groups, zero `class="well"` and zero `<fieldset>`. Cluster each card's semantically related fields – the four workflow role pairs (provider + model), the four Server sub-cards – in `.well` / `.well-content` (canon's documented container for form field clusters) with a `.t-caption` uppercase cluster label per canon § Wells. A card whose fields are genuinely unrelated keeps its flat stack; this is grouping, not decoration.
  - **Verify**: `rg -c 'class="well[ "]' packages/dartclaw_server/lib/src/templates/settings.html` prints at least 8 (the character class excludes `class="well-content"`, which would otherwise let four clusters satisfy a threshold of eight); on the Workflows tab the four role pairs render as four labelled groups rather than eight identical rows, and no field escapes its card's measure

- [ ] **TI06** A two-character field is not 866px wide
  - `.form-input` / `.form-select` are `width: 100%` with no max-width, so Port, Max Turns and Reset Hour each render ~866px for a 2–4 character value. The field-width scale that caps them was hoisted into S03's Forms section and ships with canon; this task applies S03's control modifier to those three fields in `settings.html` and adds no rule of its own. Depends on TI05 having settled the well structure the capped controls sit in.
  - **Verify**: the width modifier this task applies resolves to a rule already present in `packages/dartclaw_server/lib/src/static/design-system.css` and `git diff "$(git merge-base main HEAD)" -- packages/dartclaw_server/lib/src/static/app.css | rg -n '^\+.*max-width'` exits with code exactly 1; on `/settings` Port, Max Turns and Reset Hour are each visibly narrower than their card, and the text fields beside them are unchanged

- [ ] **TI07** A settings card reads heading → label → value, and the restart note is helper copy
  - Card title, field label and field value all render at 14px today. Apply the composite tiers so three sizes are visible – card title to `.t-heading`, field label to `.t-label`, field value to `.t-body` – and use `.t-caption` for the cluster labels TI05 introduced and any hint text. The always-on "Changes apply after a server restart" note is populated on 7 of 10 tabs unconditionally by `dc_settings_controller.js`, in a `color-mix` of `--warning` and `--fg-overlay` that reads as neither; demote it to plain `--fg-overlay` helper copy on a single divider so the undiluted `--warning` token means the actual pending-restart state, which has its own banner. The demotion is not CSS-only: `updateMutabilitySummaries` (:138-142) injects an `icon icon-triangle-alert` span into the same note, and neutral helper copy carrying a warning triangle is the same defect in another layer – the icon goes with the blend. The page also prints its title twice: `settings.html:10` `<h1>Settings</h1>` duplicates the topbar's, and the plan's shared-surface decision assigns the deletion here – remove it and keep any subtitle as a description head, never a second `<h1>`. Settings keeps the 900px measure – it is not on the plan's wide-container list.
  - **Verify**: `rg -n '<h1' packages/dartclaw_server/lib/src/templates/settings.html` exits with code exactly 1; `awk '/^\.section-note-restart/,/}/' packages/dartclaw_server/lib/src/static/app.css | rg -n 'warning'` exits with code exactly 1 (block-scoped – grepping the selector name alone prints only the `{` line and never the declaration, so it could not fail) and `rg -n 'icon-triangle-alert' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1; `rg -n 'content-inner--wide|page-inner--wide' packages/dartclaw_server/lib/src/templates/settings.html` exits with code exactly 1; `git diff -U0 "$(git merge-base main HEAD)" -- packages/dartclaw_server/lib/src/static/app.css | rg -n '^\+.*var\(--text-sm\)'` exits with code exactly 1 (merge-base against the working tree, so committed and uncommitted story work are both covered – the token itself lives in `app.css`, which S07 owns, so grepping the template for it would be vacuous); on `/settings` "Agent Configuration", "Provider" and the value render at three distinguishable sizes, measured card-vs-ground contrast is ≥ 1.15:1 and every text pairing meets WCAG AA in both themes, and no settings state is carried by colour alone

- [ ] **TI08** Settings has a loading treatment and a failure that outlives a toast
  - The in-flight pass renders `.skeleton` / `.skeleton-text` blocks in place of the 27 fields that currently advertise loading: 22 `placeholder="Loading..."` disabled inputs plus five `<select>` elements whose sole option is `<option value="">Loading...</option>` (:154, :161, :192, :199, :225) – the selects carry the state as option text, not as an attribute, and a fix that greps only for `placeholder` leaves them stuck. The skeleton is a sibling of the control, toggled on populate; the controls stay in the DOM, because `populateSettingsForm` queries `.settings-form [data-field]` and assumes an `input`/`select` inside every group. On populate, `populateSettingsForm` currently clears `placeholder` unconditionally, so nullable fields (Model, Max Turns, Effort) become indistinguishable empty boxes. An unset nullable field's placeholder must say what is actually knowable, and no more: where the config payload already carries the inherited value – the `workflow.defaults.*` provider and model fields, which fall back to `agent.*` – state it; where it does not – `agent.model`, `agent.max_turns`, `agent.effort` – say the field is unset and the server default applies **without naming a value**, because `FieldMeta` exposes no default and inventing one would assert a value the client cannot read (see What We're NOT Doing). On `/api/config` rejection the failure path currently fires only a 4-second toast and leaves every field disabled forever; the card body must carry a persistent `banner banner-error` with a Retry control, following the recipe already in `templates/workflow_detail.html`'s step-detail error slot. The Security tab's second fetch needs the same treatment and one extra correction: `loadGuardEditor` sets `root.dataset.loaded = '1'` *before* the request resolves, so a failure is permanent for the page's lifetime and a Retry would be a no-op – set the flag on success only, and give its failure the same banner and a Retry that genuinely re-fetches. Retry re-runs the whole success pipeline idempotently, not just the fetch: `initSettingsForm`'s `.then` (:726-733) also performs the `settingsInitialConfig` re-baseline, `checkRestartBanner`, `attachSettingsListeners()`, `loadGuardEditor()` and `attachGuardEditorListeners()`, so a repopulate-only Retry yields a form that looks live and has no dirty tracking, no save and no guard editor. TI02's dirty tracking must survive a Retry-driven repopulate without reporting a phantom edit.
  - **Verify**: `rg -n 'Loading\.\.\.' packages/dartclaw_server/lib/src/templates/settings.html` exits with code exactly 1 – all 27 current occurrences are either the `placeholder` attribute or the option text, so one exit-code assertion covers both shapes (`rg -c` prints nothing and exits 1 on no-match, so an exit-code assertion is the only sound form) – and `rg -n 'skeleton|banner banner-error' packages/dartclaw_server/lib/src/templates/settings.html packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` returns both; scenarios S05 and S06 hold with `/api/config` and then `/api/config/guards` forced to fail, each failure state is still on screen after 10 s, after Retry succeeds a typed edit still marks the form dirty and Save still submits, and the absent `FieldMeta` default-value surface is recorded as a deferral in Implementation Observations

- [ ] **TI09** The Effort control never presents an enabled picker whose only choice is blank
  - `agent.effort` declares no `allowedValues` in config metadata and adding them is out of scope here, so the control must not claim to be settable: give the empty option a real label ("Default") rather than an em dash, and leave the control non-actionable while its allowed-value list is empty. The unconditional enable is in `populateSettingsForm`, which clears `disabled` for every field regardless of whether options were injected. Record the `allowedValues` half – and the `agent.provider` mirror defect, an enumerable value rendered as free text for the same reason – as explicit deferrals for the S14 glitch ledger, with the reason.
  - **Verify**: `rg -n '<option value="">—</option>' packages/dartclaw_server/lib/src/templates/settings.html` exits with code exactly 1; on `/settings` the Effort field is not a focusable picker offering a single blank row, every field that *does* have options is still enabled after populate, and both deferrals are recorded in Implementation Observations

- [ ] **TI10** The guard editor renders from canon: one tab component, one open-header table
  - Two app-local recipes, one component. **Tabs**: `renderGuardEditor` (:473-477) emits `class="guard-editor-tab"` pills into `[data-guard-editor-tabs]` (`settings.html:483`) – a third tab implementation on this surface, which the release's "only one tab bar ships" bar does not allow. Emit canon's `tab` class into a `tabs` container instead, keep the `[data-guard-editor-tab]` click hook at :553 working, and give the strip the same `role="tablist"` / `role="tab"` / `aria-selected` semantics and arrow-key contract TI03 applies to the page strip. Delete `.guard-editor-tab` and `.guard-editor-tab.active` from `app.css` and drop `.guard-editor-tabs` from the shared flex selector at :3689 – the other three members stay. **Table**: `settings.html`'s table carries `class="data-table guard-editor-table"`, and the `app.css` rule keeps only the genuinely local parts (its `min-width`, the mono/break-all value cell), deleting the per-cell borders, the bare uppercase `th` and the padding that `dev/design-system/components.css#.data-table` already provides. Presentation only – the edit and delete handlers belong to S06 and are not touched.
  - **Verify**: `rg -n 'guard-editor-tab\b' packages/dartclaw_server/lib/src/static/app.css` exits with code exactly 1 and `rg -n "class='guard-editor-tab|class=\"guard-editor-tab" packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1 (the `[data-guard-editor-tab]` attribute hook is a different string and survives); `rg -n 'class="data-table guard-editor-table"' packages/dartclaw_server/lib/src/templates/settings.html` returns the markup and `awk '/^\.guard-editor-table/,/}/' packages/dartclaw_server/lib/src/static/app.css | rg -n 'border|text-transform|padding'` exits with code exactly 1; on the Security tab the guard strip renders as canon tabs and still switches guard groups on click and on arrow keys, and the table renders with a bottom-rule header at caps tracking and a row hover with the value cell still wrapping

- [ ] **TI11** This story's canon footprint is provably zero, and the test suite guards the new shapes
  - Canon is closed to P3: this task asserts that S11 changed none of the three drift-checked files or their served copies, rather than re-syncing anything. Re-point existing assertions, preserving each assertion's original intent, in every test whose expectation this story invalidates – not only retired class names: `app_js_test.dart` asserts on `dc_settings_controller.js` source shapes TI02 and TI03 rewrite, and `settings_page_test.dart:57` asserts `contains('href="#providers"')`, which TI03's tab-control markup governs. Leave `lib/src/generated/embedded_assets.g.dart` untouched – S14 owns the single release-level regeneration.
  - **Verify**: `git diff --stat "$(git merge-base main HEAD)" -- dev/design-system packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/icons.css` prints nothing (zero canon footprint; `DESIGN.md` and `showcase.html` sit under `dev/design-system/` and this story documents no contract there either); `bash dev/tools/fitness/check_design_system_sync.sh` exits 0; `dart test packages/dartclaw_server/test` passes; `git status --porcelain packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` prints nothing; every class token `settings.html` emits resolves to a rule head in `design-system.css`, `icons.css` or `app.css` (enumerate with `rg -o 'class="[^"]*"' packages/dartclaw_server/lib/src/templates/settings.html`, split on whitespace, and grep each token across the three served stylesheets – no token is unbacked)

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

- [ ] Every deferral and disposition this FIS names – the `allowedValues` half of TI09 plus its `agent.provider` mirror, the absent `FieldMeta` default-value surface behind TI08's placeholder wording, the settings IA regroup, the tab-strip pairing counts, the `restart_banner.html` fix handed to S12, and the custom-select enhancement gap recorded **closed by canon** with its reasoning – is recorded in Implementation Observations, so each counts against the release's glitch ledger rather than vanishing.


## Implementation Observations

_No observations recorded yet._
