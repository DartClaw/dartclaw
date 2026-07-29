# Native dialog eradication and one confirmation API

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
**Story-ID**: S06

## Feature Overview and Goal

**Intent**: The app hands its most consequential, irreversible decisions – deleting a chat and its messages, restarting the server, cancelling a running workflow, rejecting an approval, removing a security guard rule – to an unstyled OS box that no theme reaches, no screenshot captures, and no design decision governs; this story moves every one of them into the product's own vocabulary so the confirmation looks like the thing it is guarding.

**Expected Outcomes**:

- [OC01] No native browser dialog appears anywhere in the Web UI – every modal confirmation renders through the canonical in-app dialog, any `hx-confirm` attribute added in future converts automatically without touching JavaScript, and row-scoped destructive actions use the canonical inline `.delete-confirm-bar` instead of a modal.
- [OC02] Every destructive confirmation this story ships names the object it will destroy by the same label the user just read on screen – the chat's title, the project's name, the guard rule's displayed value, and the scheduled task's title. The scheduled-task call site passes only the id today, so this story lands both `data-task-title` and its functional inline `.delete-confirm-bar` before removing the native dialog.
- [OC03] Editing a guard rule uses one atomic form with the same three-option access-level select the Add form six lines away already renders, and deleting a guard rule is confirmed instead of firing on a single click.
- [OC04] Restart failures arrive as toasts in the app's existing feedback vocabulary rather than as blocking alerts stacked on top of the restart overlay.
- [OC05] The two allowlist entry removals that gate who may message the agent are confirmed by name before the `DELETE` fires, instead of deleting on a single click with no undo.


## Required Context

### From `docs/specs/0.22.1/prd.md` – "FR5: Feedback decision-table rewrite + native dialog eradication"
<!-- source: docs/specs/0.22.1/prd.md#fr5-feedback-decision-table-rewrite--native-dialog-eradication -->
<!-- extracted: e18cf85 -->
> Then route all nine call sites through one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js`. For the three `hx-confirm` templates, add a single `htmx:confirm` listener in `dc_shell_controller.js` — zero template edits, and all future `hx-confirm` uses convert automatically.
>
> Call sites: `dc_shell_controller.js:369` (delete chat), `:477` (restart), `:488,489,491` (`alert()` on failure); `dc_scheduling_controller.js:403` (delete scheduled task — passes the **id**, not the title); `dc_projects_controller.js:192` (remove project); `dc_settings_controller.js:569,573` (`window.prompt()` for guard extension value and file-access level).
>
> **Acceptance Criteria**:
> - [ ] Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.
> - [ ] The two `prompt()` config editors are real forms in a `.dialog`, not modal-ised prompts.
> - [ ] The `alert()` failure paths surface through the toast component.
> - [ ] Destructive confirmations name the object (title, not id).

_The DESIGN.md decision-table rewrite and the `.dialog` / `.dialog--confirm` CSS named by FR5 belong to S04; this story owns only the call sites. Line numbers above are from the audited build and move under S05 – locate by call shape._

### From `docs/specs/0.22.1/prd.md` – Binding constraint: FR5 forbidden call forms
<!-- source: docs/specs/0.22.1/prd.md#fr5-feedback-decision-table-rewrite--native-dialog-eradication -->
<!-- extracted: e18cf85 -->
> Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.

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

### From `docs/specs/0.22.1/prd.md` – Binding constraint: NFR accessibility
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone

### From `docs/specs/0.22.1/prd.md` – Binding constraint: NFR visual quality
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline

### From `docs/specs/0.22.1/plan.json` – Shared decision: "One dialog frame and one confirmation API"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: working tree 2026-07-25 -->
> S04 ships the canonical `.dialog` family (promoted from the app's proven private `.task-dialog`) with `.dialog--confirm` and an explicit z-index scale. S05 repoints existing markup at it and deletes the private recipe. S06 ships exactly one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js` plus one `htmx:confirm` listener in `dc_shell_controller.js` — every modal confirmation and every `hx-confirm` gate routes through those two, while row-scoped destructive actions use the canonical inline bar; no story adds a second modal confirmation implementation.
>
> […] Row-scoped destructive actions resolve to the inline `.delete-confirm-bar`, per S04's canon decision table — this covers the scheduled-TASK row delete as well as the scheduled-JOB delete. S06 replaces the scheduled-task native `confirm()` atomically with a functional inline bar that names the task by title; S08 may later unify or restyle the two row-delete call sites, but never owns an unconfirmed interval.

### From `docs/specs/0.22.1/plan.json` – S06 scope: the security-load-bearing deletes
<!-- source: docs/specs/0.22.1/plan.json#stories[id=S06].scope -->
<!-- extracted: working tree 2026-07-25 -->
> Additionally add confirmations to the destructive deletes that currently have none and are security-load-bearing rather than merely polite: the DM-allowlist and group-allowlist entry removals in `dc_settings_controller.js` (both fire `DELETE` immediately on click, no undo, and they gate who may message the agent), and the guard-editor Delete. The audit singles these out as the only bucket where confirmation is load-bearing.

_Binding: all three are this story's, not deferrals. Verified in source — `dc_settings_controller.js:896-941` is a delegated `.allowlist-remove` click handler whose `dm` and `group` branches each go straight to `fetch(…, {method:'DELETE'})`._

### From `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md` – "Guard editor affordances are inverted"
<!-- source: docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#b-glitches--visibly-broken-no-design-decision-needed-72 -->
<!-- extracted: e18cf85 -->
> `dc_settings_controller.js:597-601`: the delete handler goes straight from click to `fetch(..., {method:'DELETE'})` with no `confirm()` — a security guard rule is removed on a single click. Meanwhile the non-destructive edit path (`:569`, `:573`) fires `window.prompt('Guard extension value', …)` and then, for file rules, a **second** `window.prompt('File access level', …)` where the user must free-type one of `no_access` / `read_only` / `no_delete` — even though the Add form six lines away in the same component already renders those exact three values as a proper `<select>` (`settings.html:502-506`).

_Audit evidence for the chained-prompt defects (section C, `settings/security`): "(b) The two prompts are chained, not atomic: cancelling the second silently discards the value typed into the first. (c) Add and Edit are two different UIs for the same record." The story's fix is a `.dialog` form, not the audit's suggested inline row editing – the PRD decides this._


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#a-canon-changes--the-design-system-itself-is-the-defect-40` – the six-`confirm()` finding lists every call site with its consequence, and the z-index finding explains why a toast raised inside an open `<dialog>` is invisible
- `../dartclaw-public/packages/dartclaw_server/lib/src/static/controllers/CONVENTIONS.md` – Stimulus contract: listeners bound in `connect()`, removed in `disconnect()`; no `runPageHook`/`initAfterSwapReinit`
- `../dartclaw-public/dev/guidelines/HTMX-GUIDELINES.md#core-principles` – server-first / no-build constraints the helper must respect
- `../dartclaw-public/dev/testing/UI-SMOKE-TEST.md` – TC covering the scheduling job delete asserts names containing `"` `'` `<` `&` render safely in the confirmation; the new dialog inherits that requirement


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI04] Deleting a chat confirms in the app's own dialog**
  - **Given** a session row in the sidebar with a delete control, on the `visual` profile (port 3338)
  - **When** the delete control is clicked
  - **Then** a `<dialog class="dialog dialog--confirm card card-glass">` is present in the DOM and open, its body names the session's title as shown in the sidebar, the page behind it is dimmed by the canonical scrim, no OS dialog appears, and the JS event loop keeps running (an in-flight SSE update still lands); pressing Escape closes it and issues no `DELETE /api/sessions/…` request

- [ ] **S02 [OC01] [TI02] `hx-confirm` markup routes through the same dialog with the attribute untouched**
  - **Given** `templates/workflow_detail.html` still declaring `hx-confirm="Reject this approval? The workflow will be cancelled."` on the Reject button, byte-identical to before this story
  - **When** Reject is clicked and the dialog's confirm action is chosen
  - **Then** the same `dialog dialog--confirm card card-glass` frame renders the attribute's text as its body with a `btn btn-danger-fill btn-sm` confirm control, and on confirm the original htmx request is issued exactly once with no second confirmation prompt

- [ ] **S03 [OC01] [TI02] An htmx request with no `hx-confirm` is not intercepted**
  - **Given** the sidebar session-list refresh, an `hx-get` with no `hx-confirm` attribute
  - **When** it fires
  - **Then** the request completes and swaps normally, no dialog is created, and no element remains in the DOM afterwards

- [ ] **S04 [OC02] [TI05] The scheduled-task delete swaps atomically from native confirm to the inline bar**
  - **Given** the scheduled task titled `Visual review seed task` with id `visual-review-seed`, as rendered in the Title column
  - **When** its row's delete control is inspected and then clicked
  - **Then** the control carries `data-task-title="Visual review seed task"` alongside its existing `data-task-id="visual-review-seed"`, clicking it raises no OS dialog and creates no `dialog.dialog--confirm`, and a functional in-row `.delete-confirm-bar` names `Visual review seed task`; cancelling issues no `DELETE`, while confirming issues exactly one delete for `visual-review-seed`. With a task titled `Deploy "prod" <now> & wait`, `tl:attr` escapes the attribute and the bar's `textContent` renders that title literally.

- [ ] **S05 [OC03] [TI07] Editing a guard file rule is one atomic form with the level select**
  - **Given** the Guard Extensions panel on `/settings`, on the `file` guard's `extra_rules` list, with an existing rule
  - **When** its Edit control is clicked
  - **Then** one dialog opens containing both the pattern input and a select offering exactly `no_access`, `read_only` and `no_delete` – no free-text level entry, no second prompt – and cancelling it issues no `PUT` and leaves the row unchanged; confirming issues a single `PUT` whose body carries the `pattern` and `level` values chosen in the dialog

- [ ] **S06 [OC03] [TI08] Deleting a guard rule is confirmed and names the rule**
  - **Given** the Guard Extensions panel showing the `file` guard's `extra_rules` list with a pattern rule
  - **When** its Delete control is clicked
  - **Then** the confirm dialog names that rule's field label and the row's displayed value (never `[object Object]`), and no `DELETE /api/config/guards/…` request is issued until it is confirmed

- [ ] **S07 [OC04] [TI03] A failed restart reports through a visible toast**
  - **Given** `/api/system/restart` responding with an error body
  - **When** the restart is confirmed
  - **Then** the confirm dialog is closed before the request is issued, a `toast-error` reading `Restart failed: <message>` is visible on screen and dismissible, and the page remains interactive

- [ ] **S08 [OC05] [TI10] Removing an allowlist entry is confirmed and names the entry**
  - **Given** a channel's detail page with an entry in the Known DM Allowlist and an entry containing `"` and `&` in the Allowed Groups list
  - **When** Remove is clicked on each in turn
  - **Then** each opens the canonical confirm dialog whose body names that exact entry — rendered literally, no HTML entities visible, never `undefined` — and states which of the two lists it is being removed from; no `DELETE /api/config/channels/<type>/dm-allowlist` or `…/group-allowlist` request is issued until the dialog is confirmed (Network panel); cancelling leaves the row and the `.allowlist-count-num` unchanged; and confirming the group entry still raises the channel restart banner and the `Group entry removed (restart required)` toast


## Structural Criteria

- [ ] No forbidden native-dialog call form (`window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(`) remains anywhere under `lib/src/static/controllers/`.
- [ ] The scheduled-task delete has no unconfirmed story boundary: the same TI05 change that removes `window.confirm` makes the inline `.delete-confirm-bar` functional, names the task by title, and gates the existing `DELETE` until explicit confirmation.
- [ ] Exactly one `confirmDialog` definition and exactly one `htmx:confirm` listener exist across `lib/src/static/controllers/` (scoped to `controllers/` because S13 vendors htmx into `lib/src/static/`, and htmx's own source contains the literal `htmx:confirm`) — no second **confirmation API**. TI07's structured-input dialog is not a second implementation: it composes S04's canon `.dialog` + S03's `.form-*` classes directly, per S04's decision-table row, and defines no dialog frame of its own (see Architecture Decision).
- [ ] Every `dialog`-prefixed class name this story emits is one S04 defined: each distinct token from `rg -o "'[^']*dialog[^']*'" packages/dartclaw_server/lib/src/static/controllers/shared.js packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` has a matching rule in `rg -n '^\.dialog' dev/design-system/components.css`. Every emitted frame also carries `card card-glass`; `confirmDialog()` emits exactly `dialog dialog--confirm card card-glass`, and the structured-input frame emits `dialog` + its applicable width modifier + `card card-glass`. Both commands return nothing before this story and S04, so a green result is evidence, not vacuity.
- [ ] No canon-owned CSS is edited app-side: `app.css` gains no `.dialog*` rule, and `dev/tools/fitness/check_design_system_sync.sh` is green.
- [ ] The three `hx-confirm` attributes in `templates/topbar.html` and `templates/workflow_detail.html` are unchanged.
- [ ] The `htmx:confirm` listener is bound in `connect()` and removed in `disconnect()` per the Stimulus controller contract.
- [ ] No backend surface changes: nothing under `lib/src/api/`, `lib/src/security/` or any Dart handler is modified, and no runtime JS dependency is added.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/static/controllers/shared.js` – the single `confirmDialog()` helper
- `packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js` – delete-chat confirm, restart confirm, three `alert()` failure paths, and the global `htmx:confirm` listener
- `packages/dartclaw_server/lib/src/templates/sidebar.html` – `data-session-title` attribute on the session delete control (TI04)
- `packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js` – atomic scheduled-task migration: remove the native `confirm()`, route the row through a functional inline `.delete-confirm-bar`, and preserve the existing delete request behind explicit confirmation
- `packages/dartclaw_server/lib/src/templates/scheduling.html` – `data-task-title` on the scheduled-task delete control so the inline bar names the visible task rather than its id
- `packages/dartclaw_server/lib/src/static/controllers/dc_projects_controller.js` – remove-project confirm
- `packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` – guard-editor edit dialog and delete confirmation, plus the DM- and group-allowlist removal confirmations (`.allowlist-remove` delegated handler)
- `packages/dartclaw_server/test/static/app_js_test.dart` – source-level regression guards for the forbidden call forms and the single-implementation rule

### What We're NOT Doing
- The `.dialog` / `.dialog--confirm` CSS, the z-index scale and the DESIGN.md feedback decision-table rewrite – S04 owns canon; this story only consumes it.
- Replacing the private `.task-dialog` markup in `task_form.dart` / `project_form.dart` – S05's hinge story owns that swap; this story adds no markup to those files.
- Broader scheduling-row consolidation or visual polish – TI05 lands the smallest functional scheduled-task `.delete-confirm-bar` path required for atomic safety. S08 may later unify or restyle the scheduled-task and scheduled-job call sites without changing their confirmation contract.
- Replacing the four `window.location.reload()` calls in `dc_projects_controller.js` with an htmx swap – adjacent to the confirm call site but a separate projects-surface fix, owned by **S15 TI10** (S11 excludes projects entirely).


## Architecture Decision

**Approach**: one promise-returning `confirmDialog()` in `shared.js` renders the canonical `.dialog--confirm` frame and resolves only after the dialog has closed; a single document-level `htmx:confirm` listener in `dc_shell_controller.js` adapts every `hx-confirm` attribute onto it.
**Why this over alternatives**: per-call-site dialogs would re-create exactly the duplication S05 just deleted, and editing the three `hx-confirm` templates would leave every future `hx-confirm` silently falling back to the OS box.

**Boundary of the "one implementation" rule** — read before TI07. `confirmDialog()` is the single **modal confirmation** API: every modal yes/no gate and every `hx-confirm` path goes through it, while row-scoped destructive actions use S04's canonical inline `.delete-confirm-bar`; no story writes a second modal API. It is deliberately not a dialog *framework* — its signature (`{title, body, confirmLabel, danger}`) has no field slot, and widening it into a generic form-builder would trade one small helper for a mini UI library, which the release's no-new-capabilities constraint forbids. So the guard-edit dialog (TI07) is built inline in `dc_settings_controller.js`, composing S04's canonical `dialog` + applicable width modifier + `card card-glass` frame and S03's `.form-*` controls directly. That is **not** a second dialog implementation: it defines no frame, no scrim and no width rule of its own, and it is exactly the mechanism S04's feedback decision table assigns to the *structured input* row (`.dialog` with real form controls). The rule the criteria enforce is therefore: one confirmation API, one canon frame, zero forked frames — not one dialog element in the codebase.


## Technical Overview


## Code Patterns & External References

```
# type | path#anchor or url                                                      | why needed (intent)
file   | lib/src/static/controllers/shared.js#showToast                          | Helper shape in this file – exported function, escaped interpolation, DOM built and appended locally
file   | lib/src/static/controllers/dc_tasks_controller.js#initTaskListControls  | Existing `<dialog>` lifecycle – `showModal()` on open, `dialog.close()` on the close control
file   | lib/src/static/controllers/dc_scheduling_controller.js#confirmDeleteJob  | The app's only styled destructive confirmation today: `btn btn-danger-fill btn-sm` confirm + `btn btn-ghost btn-sm` cancel, message naming the object
file   | lib/src/static/controllers/dc_shell_controller.js#connect                | Where document-level listeners are bound and torn down (`handleAfterSwap` pattern: bind in `connect`, remove in `disconnect`)
file   | lib/src/templates/settings.html:499-507                                  | The Add form the Edit dialog must mirror: `.form-select[data-guard-editor-level]` with the three legal values
file   | lib/src/static/controllers/dc_settings_controller.js#renderGuardEditor   | Read-set: how guard rows, their field labels and `data-index` are produced; the edit/delete handlers hang off this markup
url    | https://htmx.org/events/#htmx:confirm                                    | `htmx:confirm` detail contract – `question`, `issueRequest(skipConfirmation)`
```


## Constraints & Gotchas

- **Critical**: `htmx:confirm` fires on *every* htmx request, not only those carrying `hx-confirm`; `event.detail.question` is null for the rest – Must handle by: returning immediately when `question` is falsy, so unrelated requests are never intercepted or delayed.
- **Critical**: re-issuing with `event.detail.issueRequest()` (no argument) leaves `skipConfirmation` false, so htmx falls through to the original native `window.confirm(question)` box – Must handle by: calling `event.detail.issueRequest(true)` to skip re-confirmation.
- **Critical**: `showModal()` promotes the dialog into the browser top layer, which beats any `z-index`, so a toast raised while a dialog is open is occluded – Must handle by: closing and removing the dialog before the promise resolves, so the caller's own post-resolve toast fires against a dialog-free page (toasts raised concurrently from other async sources while any `showModal()` dialog is open remain occluded).
- **Critical**: converting a blocking `confirm()`/`prompt()` into an awaited `confirmDialog()` opens a DOM-churn window the old calls never had, and `event.currentTarget` is nulled once dispatch completes – Must handle by: capturing the element and reading every needed `dataset` value before the first `await` (applies to TI04, TI06, TI07, TI08 and TI10 — TI05 awaits nothing and is exempt).
- **Critical**: the guard editor re-renders its rows with fresh `data-index` values whenever `refreshGuardEditorState()` runs, so an index captured before the dialog can point at a different rule after it – Must handle by: snapshotting the entry (field + `guardEntryDisplay(entry)`) at click time and, after the dialog resolves, re-resolving the index against the current group state, aborting with an error toast when the entry no longer matches (TI07, TI08).
- **Avoid**: interpolating object names into `innerHTML` – Instead: use `textContent` or the existing `escapeHtml` from `shared.js`; session titles, project names, guard patterns and scheduled-task titles are all user data and the smoke test asserts `"` `'` `<` `&` render literally.
- **Constraint**: canon-first – the `.dialog` rules live in `dev/design-system/components.css`; this story adds no dialog CSS to `app.css` and must leave `check_design_system_sync.sh` green.
- **Avoid**: adding `confirmDialog` to the `window.dartclaw.ui` compatibility namespace – Instead: import it from `./shared.js` in each controller that calls it (`dc_shell_controller.js`, `dc_projects_controller.js`, `dc_settings_controller.js`). `dc_scheduling_controller.js` is **not** one of them: TI05 uses the canonical inline bar rather than a modal, so the file keeps reaching feedback helpers through `this.ui` and gains no import.
- **Critical**: removing `window.confirm` before the scheduled-task inline bar is functional creates an unconfirmed destructive interval – Must handle by: landing the native-call removal, escaped `data-task-title`, first-click bar insertion, cancel restoration and confirm-only `DELETE` path in the same TI05 change. S08 may later consolidate or restyle the scheduled-task and scheduled-job paths, but cannot supply first safety.
- **Critical**: the `.allowlist-remove` handler (TI10) is a *delegated* `page.addEventListener('click', …)` with a synchronous `function (e)` body, not a Stimulus action – Must handle by: making the callback `async` and keeping the existing `btn.dataset.entry` / `section.dataset.allowlist` reads above the first `await`, because `e.target.closest()` results and the button itself can be replaced by `renderAllowlistEntries()` while the dialog is open.
- **Constraint**: the group branch of that handler does more than the DM branch on success — `showChannelRestartBanner()` plus a different toast string – so the confirmation gate sits above the `if (listType === 'dm')` branch and both success paths stay byte-for-byte intact; the two are not interchangeable and must not be merged while adding the gate.


## Implementation Plan

### Implementation Tasks

Before any implementation task, snapshot the protected templates, `app.css` and backend directories exactly as W1 receives them; every later unchanged-surface gate compares against this entry snapshot rather than the dirty checkout:

```sh
BASE=.agent_temp/0.22.1-s06-entry
rm -rf "$BASE"
mkdir -p "$BASE/packages/dartclaw_server/lib/src/templates" "$BASE/packages/dartclaw_server/lib/src/static" "$BASE/packages/dartclaw_server/lib/src"
cp packages/dartclaw_server/lib/src/templates/topbar.html packages/dartclaw_server/lib/src/templates/workflow_detail.html packages/dartclaw_server/lib/src/templates/channel_detail.html "$BASE/packages/dartclaw_server/lib/src/templates/"
cp packages/dartclaw_server/lib/src/static/app.css "$BASE/packages/dartclaw_server/lib/src/static/"
cp -R packages/dartclaw_server/lib/src/api packages/dartclaw_server/lib/src/security "$BASE/packages/dartclaw_server/lib/src/"
```

- [ ] **TI01** `shared.js` exports a single promise-returning `confirmDialog({title, body, confirmLabel, danger})`
  - Builds and appends to `document.body` one `<dialog class="dialog dialog--confirm card card-glass">` — the exact canonical confirm-frame composition S04 ships — mirrors the confirm/cancel button pairing in `dc_scheduling_controller.js#confirmDeleteJob` (`btn btn-danger-fill btn-sm` for a `danger` confirm, `btn btn-ghost btn-sm` for cancel), opens it with `showModal()`, gives Cancel initial focus when `danger` is true, resolves `true` on confirm and `false` on cancel/Escape/backdrop, settling exactly once off the dialog's `close` event, and closes **and removes** the element before resolving. At most one confirmation may be active: a call made while one is open immediately resolves `false`, creates no second dialog and neither queues nor replaces the active call. `title` is optional (omitted from the markup when absent), `confirmLabel` defaults to `'Confirm'`, and `title` / `body` are inserted as text, never HTML.
  - **Verify**: `Test: rg -n "export function confirmDialog" packages/dartclaw_server/lib/src/static/controllers/shared.js` returns exactly one match, and its body contains the exact class string `dialog dialog--confirm card card-glass`, `showModal()` and `.close()`; browser: `await confirmDialog({title:'t', body:'<b>x</b> & "y"', confirmLabel:'Delete', danger:true})` renders `<b>x</b> & "y"` literally, the open frame's `className === 'dialog dialog--confirm card card-glass'`, Escape resolves `false`, and `document.querySelectorAll('dialog.dialog--confirm').length === 0` afterwards; invoking it twice before settling the first leaves exactly one dialog, resolves the second call `false` immediately and leaves the first call active

- [ ] **TI02** Every `hx-confirm` attribute in the app renders as the canonical dialog, with no template edits
  - One `htmx:confirm` listener bound in `dc_shell_controller.js#connect` and removed in `disconnect` (follow the `handleAfterSwap` bind/remove pattern in the same file). Returns immediately when `event.detail.question` is falsy; otherwise `event.preventDefault()`, awaits `confirmDialog()` from TI01 with the question as `body` and `danger: true` (every current `hx-confirm` use is destructive), and on accept calls `event.detail.issueRequest(true)` – unless `event.detail.elt` has left the DOM while the dialog was open (an SSE-driven swap can remove it), in which case it skips `issueRequest` (htmx silently drops requests for detached elements) and reports via `showToast('error', …)`.
  - **Verify**: `Test: rg -n "htmx:confirm" packages/dartclaw_server/lib/src/static/controllers/ | wc -l` is 2 (one add, one remove) and `rg -n "issueRequest\(true\)" packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js` matches; with `BASE=.agent_temp/0.22.1-s06-entry`, `cmp -s "$BASE/packages/dartclaw_server/lib/src/templates/topbar.html" packages/dartclaw_server/lib/src/templates/topbar.html && cmp -s "$BASE/packages/dartclaw_server/lib/src/templates/workflow_detail.html" packages/dartclaw_server/lib/src/templates/workflow_detail.html` exits 0; browser: each of the three `hx-confirm` sites (topbar session reset, workflow Cancel, workflow Reject on `/workflows/<id>`) opens the dialog and confirming issues the request exactly once (Network panel), while an ordinary `hx-get` sidebar refresh creates no dialog

- [ ] **TI03** Restart confirmation and its three failure paths use the app's own feedback vocabulary
  - `confirmRestart()` in `dc_shell_controller.js` awaits `confirmDialog()` instead of `confirm(...)`, and the three `alert(...)` calls become `showToast('error', ...)` carrying the same strings – `'Restart failed: ' + (data.error?.message || 'Unknown error')`, `'Restart failed'`, `'Failed to reach server'`. `showToast` is already imported in this file.
  - **Verify**: `Test: rg -n "alert\(" packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js` prints nothing, and `rg -n "Restart failed: |'Restart failed'|'Failed to reach server'" packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js` shows all three inside `showToast('error', …)` calls; browser: a failing `/api/system/restart` shows a visible `.toast-error` with no dialog left open behind it

- [ ] **TI04** Deleting a chat is confirmed through the canonical dialog
  - `deleteSession()` in `dc_shell_controller.js` awaits `confirmDialog({..., confirmLabel: 'Delete', danger: true})` with the session's title in the body, read from a new `data-session-title` attribute on the sidebar delete control (emit via `tl:attr` alongside the existing `data-session-id` in `templates/sidebar.html`); the existing `showToast('error', …)` failure path is unchanged.
  - **Verify**: `Test: rg -n "confirm\(" packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js` prints nothing and `rg -n "data-session-title" packages/dartclaw_server/lib/src/templates/sidebar.html` matches on the delete control; browser: clicking delete opens `dialog.dialog--confirm` naming the session's title, Escape issues no `DELETE /api/sessions/…` (Network panel), confirming issues exactly one

- [ ] **TI05** The scheduled-task delete swaps atomically from native confirm to the inline bar
  - Land the full safe path in one change. In `templates/scheduling.html`, emit escaped `data-task-title=${task.title}` alongside `data-task-id` on the scheduled-task delete button. In `dc_scheduling_controller.js`, reuse the existing `confirmDeleteJob` row construction through one small internal builder: `confirmDeleteJob` keeps its current job label/action, while `deleteScheduledTask` captures `taskId` + `taskTitle` and inserts the same canonical `.delete-confirm-bar` with a task-specific confirm action. Move the existing scheduled-task `DELETE` body behind that confirm action; cancel restores the original row and issues no request. Only after the inline path is functional, remove `window.confirm`. Add no modal and no `confirmDialog()` import. S08 may later consolidate names or restyle the two row call sites, but TI05 itself closes safety.
  - **Verify**: `rg -n 'window\.confirm|confirmDialog|dialog--confirm' packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js` prints nothing; `rg -n 'data-task-title' packages/dartclaw_server/lib/src/templates/scheduling.html` matches the `dc-scheduling#deleteScheduledTask` button; `rg -c 'delete-confirm-bar' packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js` reports exactly one construction serving both row types. Browser on the `visual` profile: the first click inserts one in-row bar whose visible text contains `Visual review seed task` and not `visual-review-seed`, hides the source row, and issues no request; Cancel restores the row; Confirm issues exactly one `DELETE /api/scheduling/tasks/visual-review-seed`.

- [ ] **TI06** Removing a project is confirmed through the canonical dialog
  - `removeProject()` in `dc_projects_controller.js` awaits `confirmDialog()` with the project name in the body and `danger: true`; the file's four `window.location.reload()` calls all stay as they are (S15 TI10 swaps them).
  - **Verify**: `Test: rg -n "window\.confirm" packages/dartclaw_server/lib/src/static/controllers/dc_projects_controller.js` prints nothing – this task closes the `dc_projects_controller.js` share of the forbidden-call-form criterion; browser: removing a project named `a & <b>` shows that text literally in the dialog

- [ ] **TI07** Editing a guard extension is a single atomic form in a dialog
  - This is the story's one **structured-input** dialog and it is built inline, not through `confirmDialog()` — permitted and bounded by the Architecture Decision's "Boundary of the one-implementation rule": compose the canon frame, never fork it, and add no second confirmation API. The `[data-guard-editor-edit]` handler in `dc_settings_controller.js` opens one `<dialog class="dialog dialog--md card card-glass">` (S04 frame, S03 `.form-field` / `.form-input` / `.form-select` controls) containing the value input pre-filled from the current entry and, for the `file` guard's `extra_rules`, a select offering exactly `no_access`, `read_only` and `no_delete` – mirroring `templates/settings.html:499-507`. The dialog's controls carry their own hooks (not the singleton `data-guard-editor-*` attributes the panel reads via `root.querySelector`) and the dialog lives outside `[data-guard-editor]`. Both values submit together in the existing single `PUT`; cancelling submits nothing. The dialog closes before the request's toast fires.
  - **Verify**: `Test: rg -n "window\.prompt" packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` prints nothing, and the new dialog markup contains `no_access`, `read_only` and `no_delete`; browser on `/settings` security tab: editing a `file` `extra_rules` row shows one dialog with a select (not a text field) for the level, cancel issues no `PUT`, confirm issues one `PUT` whose body carries both `pattern` and `level`

- [ ] **TI08** Deleting a guard extension requires confirmation naming the rule
  - The `[data-guard-editor-delete]` handler in `dc_settings_controller.js` awaits `confirmDialog({..., danger: true})` naming the rule's field label and its displayed value – looked up from the current group's entries and formatted with `guardEntryDisplay` (`file` `extra_rules` entries are objects, never interpolated raw) – before the existing `fetch(..., {method:'DELETE'})`; the success toast path is unchanged.
  - **Verify**: `Test: browser on /settings security tab – clicking Delete on a guard row issues no DELETE /api/config/guards/… until the dialog is confirmed (Network panel), and the dialog body contains the row's displayed value (a file extra_rules pattern, not [object Object])`

- [ ] **TI09** The forbidden call forms, single modal implementation and scheduled-task atomic path are guarded by tests
  - Extend `packages/dartclaw_server/test/static/app_js_test.dart` (follow its existing read-the-source assertion style) with a case that scans every file under `lib/src/static/controllers/` for the six forbidden call forms and asserts exactly one `confirmDialog` definition and one `htmx:confirm` binding pair. Add source-level assertions that the scheduling controller has one `.delete-confirm-bar` construction serving both row types, the scheduled-task first-click handler does not call `fetch`, and its confirm action owns the task `DELETE`; pair that with the rendered-template assertion that the delete button carries escaped `data-task-title`.
  - **Verify**: `Test: dart test packages/dartclaw_server/test/static/app_js_test.dart` passes; the new cases fail when a `window.confirm(` call is re-introduced, `data-task-title` is removed, or the scheduled-task `DELETE` moves back into the first-click handler

- [ ] **TI10** Removing a DM- or group-allowlist entry is confirmed by name
  - The delegated `.allowlist-remove` click handler in `dc_settings_controller.js` (`:896-941`) awaits `confirmDialog({body: …, confirmLabel: 'Remove', danger: true})` and returns early on cancel, before either branch's `fetch(…, {method:'DELETE'})`. `listType` is already resolved above the branch, so one call placed there serves both lists — the body names the captured `entry` verbatim and says which list it leaves. The plan calls these two the security-load-bearing bucket: they gate who may message the agent, they fire on a single click today, and there is no undo. Per the Constraints bullets, make the callback `async`, keep the `entry` / `listType` reads above the `await`, and leave both success paths (including the group branch's `showChannelRestartBanner()` and its distinct toast) untouched. No template edit: `data-entry` is already emitted by both `channel_detail.html` and `renderAllowlistEntries()`.
  - **Verify**: `rg -n -A45 'Allowlist remove handler' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` shows `await confirmDialog(` and its cancel-return between the `entry` capture and the `dm` / `group` branches, and both `fetch(…, {method:'DELETE'})` calls still inside them; `rg -c 'confirmDialog' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` is ≥3 — the `./shared.js` import, TI08's guard-delete call, and the allowlist gate (currently 0, exit 1); `rg -n 'showChannelRestartBanner' packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` still matches inside the group success path; with `BASE=.agent_temp/0.22.1-s06-entry`, `cmp -s "$BASE/packages/dartclaw_server/lib/src/templates/channel_detail.html" packages/dartclaw_server/lib/src/templates/channel_detail.html` exits 0; browser on a channel detail page: Remove on a DM entry and on a group entry each open the dialog naming that entry, cancel issues no `DELETE` and leaves `.allowlist-count-num` unchanged, confirm issues exactly one (Network panel)

### Testing Strategy

### Validation

- Story-start captures per the plan's "Visual-baseline protocol" shared decision: capture the touched surfaces at story start (both themes, desktop + 768px) and validate this story's deltas against those – the audit's 92-shot set stays the release-level baseline (for per-story validation this supersedes the NFR quote's baseline reuse).
- Both themes at desktop (1440×900) and 768px for each new confirmation state, on the `visual` profile (port 3338): chat delete, restart confirm, workflow reject (`hx-confirm` path), project remove, guard edit form, guard delete, both allowlist removals, and the scheduled-task inline `.delete-confirm-bar`. The task row capture must show the title-bearing bar before any `DELETE`, with no native or modal dialog.
- Focus-visible on the dialog's confirm and cancel controls, and `prefers-reduced-motion` honored by the dialog's entrance – both required by the accessibility NFR and neither covered by the source-level test.

### Execution Contract

- TI01 must complete before TI02–TI04, TI06–TI08 and TI10 — every one of those consumes `confirmDialog()` from it. TI05 is independent of TI01 because it uses the inline row pattern, but its own edits are inseparable: title attribute, functional bar, cancel/confirm actions and native-call removal land together. TI09's source-level guard runs last, after every other task has landed, or it fails on call sites not yet converted.
- This story executes in P3/W1 after S05's P2/W1 hinge has landed. The canonical `.dialog` classes must already be in the served CSS, and the call-site line numbers quoted in the PRD will have moved – locate by call shape (`rg -n 'window\.(alert|confirm|prompt)|(^|[^.\w])(alert|confirm|prompt)\('`), not by line.

## Final Validation Checklist

- [ ] `rg -n 'window\.(alert|confirm|prompt)|(^|[^.\w])(alert|confirm|prompt)\(' packages/dartclaw_server/lib/src/static/controllers/` prints nothing (it currently prints the nine call sites).
- [ ] `bash dev/tools/fitness/check_design_system_sync.sh` is green and, with `BASE=.agent_temp/0.22.1-s06-entry`, `git diff --no-index -U0 "$BASE/packages/dartclaw_server/lib/src/static/app.css" packages/dartclaw_server/lib/src/static/app.css | rg '^\+[^+].*\.dialog'` exits with code exactly 1.
- [ ] All three of the plan's security-load-bearing deletes are confirmed, not deferred: the guard-editor Delete (TI08) and both allowlist removals (TI10). On the running `visual` profile, clicking each of the three issues no `DELETE` request until its dialog is confirmed (Network panel).
- [ ] The scheduled-task delete closes atomically in TI05: source contains no native confirm, the first click inserts the title-bearing inline bar without issuing a request, Cancel restores the row, and Confirm issues exactly one `DELETE`. S08 is not required for a safe story boundary.
- [ ] With `BASE=.agent_temp/0.22.1-s06-entry`, `rsync -ainc --delete "$BASE/packages/dartclaw_server/lib/src/api/" packages/dartclaw_server/lib/src/api/` and `rsync -ainc --delete "$BASE/packages/dartclaw_server/lib/src/security/" packages/dartclaw_server/lib/src/security/` both print nothing – proves the protected backend directories are unchanged by this story.
- [ ] After the final embed-root edit, `git ls-files --error-unmatch -- packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` exits 0, `dart run dev/tools/embed_assets.dart` completes, and `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` passes before story close.


## Implementation Observations

#### DECISION NOTE: s06.confirm-dialog.concurrent-invocations

Decision-Key: s06.confirm-dialog.concurrent-invocations
Altitude: FIS
Affected surface: `shared.js#confirmDialog` lifecycle and every destructive confirmation caller
Decision: Permit one active confirmation; calls made while it is open immediately resolve `false`, with no queue, replacement or second dialog.
Rationale: Fails closed without allowing duplicate destructive actions or introducing queue state and stale-action surprises.
Evidence: User ratified the recommended preflight option on 2026-07-26.
