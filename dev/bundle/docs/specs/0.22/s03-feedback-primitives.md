# Feedback primitives: meters, claw-loader, skeletons, scan-bar

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: Give operators one consistent, legible read on "what is loading or running" by replacing the app's hand-rolled progress bars, circular spinners, and bare "Loading…" text with the canonical Afterglow feedback primitives.

**Expected Outcomes**:

- [OC01] Every determinate progress reading (memory budget, task progress, workflow-detail progress, workflow-run list progress) renders as a canonical `.meter`/`.meter-fill--*` that keeps its visible numeric label/percentage; the five bespoke bars and their CSS are gone.
- [OC02] Both circular spinners are retired — restart overlay and chat pre-stream show a `.claw-loader`, pairing waits show a `.scan-bar`, and no `.restart-spinner`, `.wa-spinner`, `@keyframes spin`, or `@keyframes wa-spin` remains.
- [OC03] Initial/lazy loads (workflow picker, workflow step-detail, memory file preview, chat load-earlier) show shimmer skeletons instead of spinner/text loaders.
- [OC04] The scarcity doctrine holds: at most one `.claw-loader` per view (chat, task detail, restart overlay each show exactly one branded loader, never two).


## Required Context

### From `prd.md` – "FR4: Feedback primitives adoption"
<!-- source: prd.md#fr4-feedback-primitives-adoption -->
<!-- extracted: 7d948b65 -->
> **Description**: Replace the four bespoke progress bars with `.meter`/`.meter-fill--*`; retire both circular spinners; adopt `.claw-loader` as the branded agent-thinking indicator (restart overlay, chat pre-stream, task live-activity), `.scan-bar` for anonymous in-place sweeps, and `.skeleton` for initial page/fragment loads.
>
> **Acceptance Criteria**:
> - No `.restart-spinner`/`.wa-spinner` or `@keyframes spin` remains; no bare "Loading…" text loader remains.
> - All determinate progress (memory budget, task/workflow progress) uses `.meter` with a visible label/percentage (color never carries the reading alone).
> - `.claw-loader` appears at most once per view (scarcity doctrine).

### From `prd.md` – "User Stories – US03"
<!-- source: prd.md#user-stories -->
<!-- extracted: 7d948b65 -->
> US03 | As an operator, I want clear, consistent feedback while things load or run so I always know what the UI/agent is doing. | Acceptance: All determinate progress uses `.meter`; agent-thinking uses `.claw-loader`; initial loads use `.skeleton`; no circular spinner or bare "Loading…" text remains. | Must / P0

### From `prd.md` – "Constraints" (binding)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.
>
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.
>
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.

### From `prd.md` – "FR1: Synced, drift-checked design-system CSS" (binding)
<!-- source: prd.md#fr1-synced-drift-checked-design-system-css -->
<!-- extracted: 7d948b65 -->
> `design-system.css` is byte-identical to `dartclaw-public/dev/design-system/components.css` (verified by the drift check); `tokens.css` likewise (app-only tokens isolated in `app-tokens.css`).
>
> A documented dev command (wired into the verification path) diffs synced files against canon and exits non-zero on mismatch.

### From `plan.json` – "sharedDecisions: Feedback-primitive ownership"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> S03 owns every meter/claw-loader/skeleton/scan-bar swap app-wide (including deletions of the four bespoke bars and both spinners). Per-page stories S04–S07 and S09 compose the primitives S03 landed and must not re-implement or re-swap loading/progress UI.

### From `plan.json` – "sharedDecisions: CSS layering & sync contract"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> S01 establishes static/design-system.css (verbatim canonical components.css, provenance header), static/app.css (app-only rules, loaded after), static/app-tokens.css (surviving app tokens), and the drift check. All later stories add/edit app CSS only in app.css and never touch synced files; new generic classes go upstream-first to dev/design-system/ then sync down.


## Deeper Context

- `audit-design-system-compliance.md#2-new-component-adoption-map` – the claw-loader / meter / skeleton adoption rows naming each template + controller spot. **Line numbers are stale; locate by selector/content.**
- `audit-design-system-compliance.md#3-violations-inventory` – "Loading/feedback patterns" section: the circular spinners, text-only loaders, and four bespoke bar implementations being retired.
- `dev/design-system/components.css` – canonical `.meter`/`.meter-fill--*`, `.claw-loader` (3 spans), `.skeleton`/`.skeleton-text`, `.scan-bar` definitions and the `prefers-reduced-motion` block that disables them (all delivered by the S01 sync into `static/design-system.css`).
- `packages/dartclaw_server/AGENTS.md` – Trellis template pairing, Stimulus controller contract, and the `embedded_assets.g.dart` regeneration rule.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01,TI02] Determinate progress renders as labeled meters**
  - **Given** the memory dashboard with a budget at 60% (warn state), a running task/workflow with a token budget, and the workflow-run list showing a run's step progress
  - **When** the pages render and a `task_progress` event updates the task bar
  - **Then** each reading shows a `.meter` wrapping a `.meter-fill` at the correct width with its numeric label/percentage still visible (the workflow-run row keeps its "N/M steps" label), the warn budget uses `.meter-fill--warning`, and the DOM contains no `budget-bar`, `fill-bar`, `task-progress-fill`, `workflow-progress-fill`, or `workflow-run-progress-bar`/`-fill`

- [x] **S02 [OC01] [TI02] Unknown-budget task progress shows a scan-bar, not a fabricated meter**
  - **Given** a running task with no token budget (indeterminate progress)
  - **When** a `task_progress` event fires
  - **Then** the progress area shows a `.scan-bar` and no `.meter-fill` width is set (color/width never fabricate a determinate reading), and both indeterminate-state classes are absent – the dashboard's `task-progress-indeterminate` and the task-detail page's `.indeterminate` – with `.scan-bar` in their place

- [x] **S03 [OC02,OC04] [TI03] Restart overlay shows a single claw-loader**
  - **Given** the client receives a `server_restart` SSE event
  - **When** `dc_shell_controller` injects the restart overlay
  - **Then** the overlay contains exactly one `.claw-loader` (three `<span>` children) and zero `.restart-spinner`

- [x] **S04 [OC02,OC04] [TI04] Chat pre-stream wait shows one claw-loader that clears on first delta**
  - **Given** a chat turn has started (`#streaming-msg` present, no `delta` received yet)
  - **When** the first `delta` SSE message arrives
  - **Then** before the delta the streaming content shows exactly one `.claw-loader`, and after the delta the loader is gone and the streamed text is shown

- [x] **S05 [OC04] [TI05] Task detail keeps its one claw moment on the activity row**
  - **Given** a task-detail page for a running task (live-activity row + timeline both present)
  - **When** the page renders
  - **Then** exactly one `.claw-loader` renders, inside `.task-activity-indicator`, and the timeline shows no second claw-loader

- [x] **S06 [OC02] [TI06] Pairing wait shows a scan-bar with no circular spinner**
  - **Given** the WhatsApp or Signal pairing page in a waiting/connecting state
  - **When** the page renders
  - **Then** a `.scan-bar` renders in place of the former `.wa-spinner`, and the template contains no `wa-spinner`

- [x] **S07 [OC03] [TI07,TI08,TI09] Initial and lazy loads show skeletons instead of text/spinner loaders**
  - **Given** the workflow picker opening, a workflow step-detail scrolling into view, an unloaded memory preview being clicked, and chat "Load earlier" being activated
  - **When** each fetch is in flight
  - **Then** shimmer `.skeleton`/`.skeleton-text` placeholders appear (no `spinner-sm`, no "Loading workflows…"/"Loading step details…"/"Loading…" text), and each is replaced by real content on success

- [x] **S08 [OC03] [TI08] A failed memory preview fetch surfaces the error, not a stuck skeleton**
  - **Given** an unloaded memory preview whose content fetch fails
  - **When** `loadPreview` rejects
  - **Then** the `.skeleton-text` placeholder is replaced by the existing failure message (the skeleton is never a terminal state)


## Structural Criteria

- [x] No `.restart-spinner`, `.wa-spinner`, `@keyframes spin`, or `@keyframes wa-spin` rule remains anywhere under `static/` (proved by TI03/TI06).
- [x] No `.budget-bar*`, `.fill-bar*`, determinate `.task-progress`/`.task-progress-fill`, `.workflow-progress-bar`/`-fill`, or `.workflow-run-progress-bar-sm`/`-fill-sm` rule remains in `static/app.css` (proved by TI01).
- [x] No bare text/spinner loader state (`spinner-sm`, "Loading workflows…", "Loading step details…", memory "Loading…") remains in templates/controllers; settings disabled-input `placeholder="Loading..."` values are excluded (S08) (proved by TI07/TI08).
- [x] The four workflow-tab visibility toggles in `task_form.dart` (`workflow-list-loading`, `workflow-list-empty`, `#workflow-form`, `#workflow-project-select`) use the `hidden` attribute, not `style="display: none"`, and their `dc_workflows_controller.js` writes use `.hidden` (proved by TI07).
- [x] The synced `static/design-system.css` and `static/tokens.css` are untouched and the S01 drift check still exits zero (proved by TI10).
- [x] `lib/src/generated/embedded_assets.g.dart` is regenerated and `git diff --exit-code` on it is clean after the template/static edits (proved by TI10).
- [x] Existing template-render tests (`memory_dashboard_test.dart`, `tasks_s11_test.dart`) are updated to the canonical markup and pass (proved by TI10).


## Scope & Boundaries

### Work Areas

- `static/app.css` — delete the four bespoke bar rule groups and both spinner groups (`.restart-spinner`+`@keyframes spin`, `.wa-spinner`+`@keyframes wa-spin`); keep `.restart-overlay`/`-content`. No new CSS (primitives come from synced `design-system.css`). [TI01,TI03,TI06]
- Determinate-progress templates — `memory_dashboard.html`, `tasks.html`, `task_detail.html`, `workflow_detail.html`, `workflow_list.html`: bar markup → `.meter`/`.meter-fill--*`, labels + `role="progressbar"`/aria preserved. [TI01]
- `dc_tasks_controller.js` — retarget width writes to `.meter-fill`; route no-budget (indeterminate) progress to `.scan-bar`. [TI02]
- Claw-loader slots — `dc_shell_controller.js` restart overlay, `chat.html` streaming pre-stream (+ `dc_chat_controller.js`), `task_detail.html` activity row. [TI03,TI04,TI05]
- Scan-bar swaps — `whatsapp_pairing.html`, `signal_pairing.html` wait indicators. [TI06]
- Skeleton loads — `task_form.dart` workflow picker (+ `dc_workflows_controller.js`), `workflow_detail.html` step-detail placeholder, `dc_memory_controller.js` preview, `chat.html` + `dc_chat_controller.js` load-earlier. [TI07,TI08,TI09]
- Verification finalization — regenerate `embedded_assets.g.dart`; update the two template-render tests. [TI10]

### What We're NOT Doing

- Page-level layout/typography adoption (container-family collapse, card tints, terminal-frame, kbd, glass) — S04–S10; S03 changes only feedback indicators.
- Print-in entry motion and per-theme reduced-motion tuning — S02; reduced-motion disabling of these loaders is already delivered by the synced canonical CSS.
- Defining or editing the canonical primitives / CSS split / drift check — S01; S03 consumes them and edits `static/app.css` only.
- Identicons, mascot, and claw-mark empty states — S11/S12/S13.
- Settings `placeholder="Loading..."` disabled inputs — these are form-field placeholders, not loader indicators; settings hygiene is S08.


## Architecture Decision

**Approach**: Consume the canonical feedback primitives that S01 synced into `static/design-system.css` (`.meter`/`.meter-fill--*`, `.claw-loader`, `.skeleton`/`.skeleton-text`, `.scan-bar`); swap each bespoke bar/spinner/text-loader at its template or controller-injection site and delete the app-only bar/spinner CSS from `static/app.css`. Markup + controller retargeting only — no new CSS or JS dependency.
**Why this over alternatives**: Centralizing every loader/meter deletion here (before the per-page W2 stories) removes the shared CSS S04–S09 would otherwise contend over, and it keeps every determinate reading label-backed while every indeterminate state is either the anonymous scan-bar or the single branded claw moment per view.


## Code Patterns & External References

```
# type | path#anchor or url                                              | why needed (intent)
file   | dev/design-system/components.css#.claw-loader                   | Canonical claw-loader = one .claw-loader element with three <span> children; copy that markup shape
file   | dev/design-system/components.css#.meter                         | .meter wraps .meter-fill; width set on the fill; --info/--warning/--error fill variants
file   | dev/design-system/components.css#.skeleton                      | .skeleton / .skeleton-text shimmer placeholders sized to the eventual content
static | packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js#showRestartOverlay | Injected overlay markup carrying `.restart-spinner` to swap
static | packages/dartclaw_server/lib/src/static/controllers/dc_tasks_controller.js#updateTaskProgress    | Task-detail width write: sets `#task-progress-fill-<id>` width → retarget to `.meter-fill`
static | packages/dartclaw_server/lib/src/static/controllers/dc_tasks_controller.js#updateDashboardProgress | Dashboard width write: sets `.task-progress-fill` width + toggles `task-progress-indeterminate` → retarget to `.meter-fill` / route no-budget to `.scan-bar`
static | packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js#loadPreview | `preview.textContent = 'Loading...'` → skeleton-text; failure branch preserved
static | packages/dartclaw_server/lib/src/static/controllers/dc_chat_controller.js#handleSseMessage | First-delta hook to remove the pre-stream claw-loader; `handleLoadEarlierClick` for the load-earlier skeleton
file   | packages/dartclaw_server/lib/src/templates/task_form.dart#L152    | `.workflow-list-loading` (spinner-sm + "Loading workflows…") → skeleton cards
```


## Constraints & Gotchas

- **Depends on S01.** The canonical primitives and the `design-system.css`/`app.css` split must be in place; the bespoke bar/spinner rules this story deletes live in `static/app.css` post-split. Never edit the synced `design-system.css`/`tokens.css` — new CSS goes only in `app.css`, and the drift check must stay green.
- **Regenerate embedded assets.** Any template or `static/` edit requires `dart run dev/tools/embed_assets.dart`; `embedded_assets.g.dart` is checked-in generated output and CI fails on a stale diff.
- **Controller-injected markup isn't covered by Dart render tests.** Restart overlay, memory preview, load-earlier, and task-progress width are produced by Stimulus JS — validate them via the UI smoke test / visual profile, not Layer 2/3 template tests.
- **Scarcity is per view, not per app.** Chat, task detail, and the restart overlay may each carry one claw-loader; a single view must never show two (task detail: activity row gets it, the timeline does not).


## Technical Overview

_Leave empty — the Work Areas + Architecture Decision + per-task descriptions make the picture clear._


## Implementation Plan

### Implementation Tasks

- [x] **TI01** Determinate progress across memory, tasks, and workflows reads through a canonical `.meter`, with the five bespoke bar CSS groups gone
  - Swap `budget-bar`/`fill-bar` (`memory_dashboard.html`), `task-progress` (`tasks.html`, `task_detail.html`), `workflow-progress-bar` (`workflow_detail.html`), and `workflow-run-progress-bar-sm`/`-fill-sm` (`workflow_list.html`, width driven by `run.progressPercent`) markup to `.meter` wrapping `.meter-fill`; keep each existing label/percentage (the workflow-run row's adjacent "N/M steps" `.workflow-run-progress` span is the retained label — color never carries the reading alone), the `role="progressbar"`+aria on the task-detail fill, the `.meter-fill--warning` variant for the budget `.warn` state, and the dynamic `tl:attr="style='width:…'"` retargeted onto the `.meter-fill`. Delete `.budget-bar*`, `.fill-bar*`, determinate `.task-progress`/`.task-progress-fill`, `.workflow-progress-bar`/`-fill`, and `.workflow-run-progress-bar-sm`/`-fill-sm` from `static/app.css`. For the task-detail SSR path, the no-budget case must render an initial `.scan-bar`, not a `.budget-bar-fill` carrying a dead class: at `task_detail.dart:95-96` the `initialProgressFillClass = 'indeterminate'` branch – appended onto `task_detail.html`'s `budget-bar-fill` via `tl:classappend` – emits the initial `.scan-bar` when the task has no token budget, so no `.budget-bar-fill.indeterminate` markup survives.
  - **Verify**: `Test: rendered memory_dashboard/tasks/task_detail/workflow_detail/workflow_list HTML contains class="meter" with a meter-fill child and its label, the warn-state budget fill carries meter-fill--warning, and none of budget-bar, fill-bar, task-progress-fill, workflow-progress-fill, workflow-run-progress-bar; grep -c of static/app.css for those selectors is 0`

- [x] **TI02** `dc_tasks_controller` drives the `.meter-fill` width and routes no-budget progress to a `.scan-bar`
  - Retarget the width writes (`#task-progress-fill-<id>` and `.task-progress-fill`) to the `.meter-fill`; where progress is indeterminate (no token budget), show a `.scan-bar` instead of toggling an indeterminate fill animation (canonical `.meter` has no indeterminate variant; `.scan-bar` is the anonymous sweep per FR4). Retire the class toggle on both controller paths – `updateDashboardProgress`'s `task-progress-indeterminate` and `updateTaskProgress`'s `.indeterminate` (the task-DETAIL page path, distinct from `updateDashboardProgress`) – routing no-budget updates to `.scan-bar` on each, so no `.indeterminate` usage survives.
  - **Verify**: `Test: with a token budget the task's meter-fill width updates on task_progress; with no budget the section shows a .scan-bar and sets no meter-fill width, with no task-progress-indeterminate class present`

- [x] **TI03** Restart overlay shows a `.claw-loader`, and the circular restart spinner is gone
  - In `dc_shell_controller.js#showRestartOverlay`, replace the injected `<div class="restart-spinner"></div>` with the canonical claw-loader markup (`.claw-loader` + three `<span>`); delete `.restart-spinner` and `@keyframes spin` from `static/app.css` (keep `.restart-overlay`/`-content`).
  - **Verify**: `Test: the injected restart overlay contains one class="claw-loader" with three <span> and no restart-spinner; grep -c of static/app.css for "restart-spinner" and "@keyframes spin" is 0`

- [x] **TI04** Chat pre-stream wait shows a single `.claw-loader` that clears when streaming begins
  - Add a `.claw-loader` placeholder inside `#streaming-content` in `chat.html`; in `dc_chat_controller.js#handleSseMessage` remove it on the first `delta` message so streamed text replaces it (one claw per chat view).
  - **Verify**: `Test: streaming-msg renders one .claw-loader before any delta; after a delta sseMessage the loader is removed and streamed content is shown`

- [x] **TI05** Task detail's live-activity row carries the view's single `.claw-loader`
  - Add a `.claw-loader` to `.task-activity-indicator` in `task_detail.html`; ensure no second claw-loader is placed on the timeline (scarcity). The budget→meter swap here comes from TI01.
  - **Verify**: `Test: rendered task_detail contains exactly one .claw-loader, within .task-activity-indicator, and none in the timeline region`

- [x] **TI06** Pairing wait indicators are `.scan-bar`, and the circular pairing spinner is gone
  - Swap `wa-spinner` for `.scan-bar` in `whatsapp_pairing.html` and `signal_pairing.html` (both spots each), dropping the inline `border-top-color` hack; delete `.wa-spinner` and `@keyframes wa-spin` from `static/app.css`.
  - **Verify**: `Test: both pairing templates contain .scan-bar and no wa-spinner; grep -c of static/app.css for "wa-spinner" and "wa-spin" is 0`

- [x] **TI07** Workflow loaders show skeletons instead of spinner/text, and the workflow-tab toggles use the `hidden` attribute
  - Replace the `.workflow-list-loading` block in `task_form.dart` (`spinner-sm` + "Loading workflows…") with three `.skeleton` card placeholders; replace the `workflow-step-detail-loading` "Loading step details…" placeholder in `workflow_detail.html` with `.skeleton-text` rows (its `hx-trigger` lazy load is preserved). Convert the four inline `style="display: none;"` toggles in `task_form.dart` (`workflow-list-loading`, `workflow-list-empty`, `#workflow-form`, `#workflow-project-select`) to the `hidden` attribute, and retarget the matching `dc_workflows_controller.js` show/hide writes for those four elements from `.style.display = 'none'|''` to the `.hidden` property (behavior unchanged; `[hidden]` reset ships app-side). The unrelated agent-badge and step/panel detail toggles in that controller are out of scope.
  - **Verify**: `Test: task_form render shows .skeleton cards and no spinner-sm/"Loading workflows"; grep task_form.dart shows no style="display: none" on those four elements (uses hidden); workflow_detail render shows .skeleton-text in the step-detail placeholder and no "Loading step details" text; the loading/empty/form/project writes in dc_workflows_controller.js use .hidden, not .style.display`

- [x] **TI08** Memory file preview shows `.skeleton-text` while fetching, with the failure path intact
  - In `dc_memory_controller.js#loadPreview`, set `.skeleton-text` markup (via innerHTML) instead of `textContent = 'Loading...'`, cleared when content loads; leave the empty/failure text branches unchanged.
  - **Verify**: `Test: clicking an unloaded .memory-preview shows .skeleton-text during the fetch, content replaces it on success, and a failed fetch shows the existing failure text (no stuck skeleton)`

- [x] **TI09** Chat "Load earlier" fetch shows a `.skeleton-text` placeholder while in flight
  - In `dc_chat_controller.js#handleLoadEarlierClick`, show a `.skeleton-text` placeholder (e.g. at the top of `#messages`) during the `htmx.ajax` fetch and remove it when the earlier messages swap in; the button already disables.
  - **Verify**: `Test: activating load-earlier shows .skeleton-text while fetching and it is gone after earlier messages prepend`

- [x] **TI10** Embedded assets and template-render tests reflect the canonical primitives
  - Run `dart run dev/tools/embed_assets.dart` after the template/static edits; update `test/templates/memory_dashboard_test.dart` (`budget-bar-fill warn` → `meter-fill--warning`), `test/templates/tasks_s11_test.dart` (the dashboard's indeterminate/determinate assertions → `.scan-bar`/`.meter`, no `task-progress-indeterminate`), and `test/templates/task_detail_template_test.dart` (the task-detail SSR no-budget render asserts an initial `.scan-bar` with no `.budget-bar-fill.indeterminate`).
  - **Verify**: `Test: git diff --exit-code on lib/src/generated/embedded_assets.g.dart is clean after regen; dart test test/templates/memory_dashboard_test.dart test/templates/tasks_s11_test.dart test/templates/task_detail_template_test.dart passes`

### Testing Strategy
> Level allocation is non-obvious because half the swaps are controller-injected JS.

- Template-embedded markup (meters in the four dashboards, chat pre-stream claw-loader, task-detail activity claw-loader, pairing scan-bars, workflow picker/step-detail skeletons) is assertable in Layer 2/3 template-render tests — extend the existing `test/templates/*` suites.
- Controller-injected markup (restart overlay, memory preview, load-earlier, task-progress width/indeterminate) has no Dart render surface — validate via the UI smoke test / `visual` profile per the plan's S03 risk mitigation (restart flow, slow-network workflow list, memory preview, one-claw-per-view check).

### Validation

- Visual validation in both themes at desktop + 768px for every affected view (US04 gate); explicit one-claw-per-view check on chat, task detail, and the restart overlay.

### Execution Contract

- S03 requires S01 landed (canonical primitives + `design-system.css`/`app.css` split). Edit `static/app.css` only; never the synced files. Regenerate `embedded_assets.g.dart` before declaring done and keep the drift check green.


## Final Validation Checklist

- [x] App-wide grep is clean of the retired loaders: `restart-spinner`, `wa-spinner`, `@keyframes spin`, `wa-spin`, `spinner-sm`, `budget-bar`, `fill-bar`, `task-progress-fill`, `workflow-progress-bar`, `workflow-run-progress-bar`, and the "Loading workflows…"/"Loading step details…"/memory "Loading…" loader text (settings input placeholders excluded).
- [x] One-claw-per-view confirmed on chat, task detail, and the restart overlay via visual check.


## Implementation Observations

- Runtime review caught and fixed stale workflow SSE meter wiring, `hidden` precedence, zero-width feedback elements, and non-delta chat auto-scroll.
- Visual validation passed across both themes and desktop/768px; pairing wait, active workflow SSE, and chat non-delta states were source/test-verified because seeded live states were unavailable.
- Note: `#workflow-project-select` can retain `hidden=false` after deselection, but its hidden parent `#workflow-form` prevents a visible or interactive leak.
