# Menu, popover and palette interaction

**Plan**: dev/bundle/docs/specs/0.27-menu-palette-fixes/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: The web UI's dropdown menus, composer context popovers and command palettes misreport state under the pointer and keyboard (invisible or double highlights, a menu cut off by the viewport, focus escaping to the page container, a separate Apply step), so the owner cannot trust what is selected or what the next turn will run.

**Expected Outcomes**:

- [OC01] In every open dropdown menu and command palette exactly one row reads as highlighted, and floating surfaces stay still under the pointer.
- [OC02] An opened dropdown menu is always fully visible: it opens upward, or shrinks and scrolls, when there is no room below its trigger.
- [OC03] Changing provider, model, effort, project or directory in the composer popovers takes effect for the next turn with no Apply button, and a rejected change says why without leaving a control showing a value that was not applied.
- [OC04] Keyboard navigation in the slash, `@` reference and Cmd+K palettes keeps focus in the palette's text input; no page container gains a focus outline.


## Required Context

- `dev/design-system/DESIGN.md#selects` – the enhanced select's contract (the `<select>` stays the value authority, keyboard map, close on outside pointerdown and focus loss); every clause must still hold after this story.
- `dev/design-system/DESIGN.md#command-palette` – row states; its sentence "hover is the same fill without the label lift" is the rule scenario S04 retires.
- `docs/guide/web-ui-and-api.md#features` – the **Effective context** bullet describes the Apply buttons and the continuity notice that scenarios S09–S14 change.


## Acceptance Scenarios

- **S01 [OC01] [runtime] A hovered option in an enhanced-select menu is visibly highlighted**
  - **Given** an open enhanced-select menu (`.pop.card.card-elevated.custom-select-menu`, surface `--bg-surface0`) in either theme
  - **When** the pointer moves over an enabled option
  - **Then** that option's fill resolves to a token different from the menu surface's, and no other option carries a fill or a focus ring

- **S02 [OC01] Pointer and keyboard share one cursor in a select menu**
  - **Given** a menu opened by keyboard with the cursor on `low`
  - **When** the pointer moves over `high`, then ArrowDown is pressed
  - **Then** after the move only `high` is highlighted, and after ArrowDown only the option after `high` is; moving over a disabled option leaves the cursor where it was

- **S03 [OC01] [runtime] Floating surfaces do not react to hover**
  - **Given** any `.pop` surface – an enhanced-select menu, the Project and Model popovers, the steer menu, the topbar overflow menu, the rail scope and view menus
  - **When** the pointer enters it
  - **Then** its `translate`, border colours, box-shadow and background equal its resting values

- **S04 [OC01] Pointer movement moves the palette cursor**
  - **Given** the slash palette open with the keyboard cursor on `/status`
  - **When** the pointer moves over `/fork`
  - **Then** `/fork` alone carries `palette-item--active` and `aria-selected="true"`, `/status` carries neither, and Enter chooses `/fork`; the Cmd+K dialog's results and the `@` reference palette (`.composer-palette-option`) behave the same

- **S05 [OC01] A resting pointer does not take the cursor back**
  - **Given** the pointer rests, unmoved, over a palette row
  - **When** ArrowDown moves the cursor and scrolls the list under the resting pointer
  - **Then** the cursor stays on the row the key moved to

- **S06 [OC02] [runtime] A menu without room below opens upward**
  - **Given** the Effort select at the foot of the Model popover, with less room between trigger and viewport bottom than the menu's height and more room above
  - **When** the menu opens
  - **Then** it renders above the trigger and its whole box lies inside the viewport

- **S07 [OC02] [runtime] A menu that fits neither side is clamped**
  - **Given** a trigger with too little room for the full menu both above and below
  - **When** the menu opens
  - **Then** it takes the side with more room, its height is capped to that room, and its rows scroll inside it

- **S08 [OC02] A menu with room below still opens below**
  - **Given** a select with room below its trigger for the full menu
  - **When** it opens
  - **Then** it renders below the trigger at the trigger's width, as today, and still emits exactly one bubbling native `change` per commit
  - **Proof**: `packages/dartclaw_runtime/test/static/app_js_test.dart#enhanced selects emit one bubbling native change` – green – parity/regression

- **S09 [OC03] Picking a model applies it**
  - **Given** the Model popover open and no Apply button in either popover
  - **When** the user picks a model from the Model select
  - **Then** one `PATCH /api/sessions/<id>/context` request is sent carrying that model and the displayed conversation revision, and on success the composer pill and the popover controls reconcile from the response; picking **Provider default** sends `model: null`

- **S10 [OC03] A provider change applies once, over the new provider's catalogue**
  - **Given** the Model popover open on provider `claude`
  - **When** the user picks another provider
  - **Then** the Model and Effort selects are rebuilt from that provider's catalogue first, and exactly one context request is sent

- **S11 [OC03] The directory applies on commit, not per keystroke**
  - **Given** the Project popover open
  - **When** the user types in Directory
  - **Then** no request is sent until the field commits (Enter or leaving the field), which sends one request; picking a project applies on change like the other selects

- **S12 [OC03] Changes made in quick succession both land**
  - **Given** a context request in flight
  - **When** the user changes a second field before it returns
  - **Then** the second request is sent after the first reconciles, carrying the revision the first returned; the final context is the second change's and no rejection message appears

- **S13 [OC03] A rejected change says why and shows what is applied**
  - **Given** the server rejects a context change (non-2xx with `error.message`)
  - **When** the response arrives
  - **Then** the popover's `.pop-validation` alert shows that message, every select shows the last applied value again, and Directory keeps the typed text marked `aria-invalid="true"` until the next successful apply clears it

- **S14 [OC03] The continuity notice tracks the provider the conversation last ran on**
  - **Given** a conversation whose last turn ran on `claude`
  - **When** the next-turn provider is applied as `codex`
  - **Then** the continuity notice shows, on the client after the apply and on a fresh page render alike; it is hidden when the next-turn provider equals the last-run provider, and before the conversation's first turn

- **S15 [OC04] [runtime] A click inside a palette keeps focus in its input**
  - **Given** the slash palette open with focus in `#message-input`
  - **When** the user presses the pointer on the palette header, its padding or a row
  - **Then** focus stays in `#message-input`, `#main-content` never becomes the active element, the next ArrowUp/Down moves the palette cursor, and a completed click on a row still chooses it; the `@` reference palette keeps focus in `#message-input` and the Cmd+K dialog in its query input the same way


## Structural Criteria

- **SC01** Surface and row fixes live in canon `dev/design-system/components.css` (the served `design-system.css` is regenerated by `dev/tools/embed_assets.dart`); `app.css` gains no `.pop`, `.palette-item` or `.custom-select` hover or translate override.
- **SC02** No "Apply to next turn" control, submit button or `#effective-context-apply` / `#effective-context-project-apply` id remains in runtime templates or static assets, and no test asserts one exists.
- **SC03** `DESIGN.md` § Selects and § Command palette, the guide's **Effective context** bullet, and `dev/bundle/docs/wireframes/deviations.md` row 36 state the behaviour this story ships.


## Scope & Boundaries

### Work Areas
- `dev/design-system/components.css` – `.pop` hover neutralisation, row hover/cursor fill inside `.pop`, custom-select menu upward placement
- `packages/dartclaw_runtime/lib/src/static/controllers/shared.js` – `enhanceCustomSelect` cursor and placement
- `packages/dartclaw_runtime/lib/src/static/controllers/dc_conversation_command_controller.js` – slash palette and Cmd+K dialog cursor and focus retention
- `packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js` – reference palette cursor and focus retention; apply-on-change, serialised apply, rejection handling, continuity notice
- `packages/dartclaw_runtime/lib/src/static/app.css` – `.composer-palette-option` highlight rule
- `packages/dartclaw_runtime/lib/src/templates/chat.html` – popover footers without Apply, notice first paint
- `packages/dartclaw_runtime/lib/src/api/session_routes_support.dart` – `effectiveContextView` exposes the last-run provider
- Tests under `packages/dartclaw_runtime/test/static/`, `test/templates/`, `test/api/`; docs per SC03

### What We're NOT Doing
- Model catalogue contents, human-readable model names and the composer pill's model label – a separate FIS, pending the catalogue design.
- Placement of the Project and Model popovers themselves – only the select menus inside them move.
- `dev/testing/profiles/conversation-loop/run.sh` cases `q9-effective-context` / `e11-effective-context` – they already target ids removed by the earlier popover split (`#effective-context-form`, `#effective-context-dialog`, `#effective-context-summary`); repairing them is its own change.
- The no-JS native select – unchanged.


## Architecture Decision

**Approach**: Fix each defect in the seam that owns it – canon CSS for surfaces and row fills, `enhanceCustomSelect` for the menu cursor and placement, each palette controller for its cursor and focus, and the existing `applyContext` path driven by `change` events instead of form submit. No new component.


## Code Patterns & External References

```
# type | path#anchor                                                                  | why needed (intent)
file   | dev/design-system/components.css#.card-glass:hover                           | the existing overlay hover neutralisation to extend to .pop
file   | packages/dartclaw_runtime/lib/src/static/controllers/shared.js#enhanceCustomSelect | cursor (row focus) and open path the placement hooks into
file   | packages/dartclaw_runtime/lib/src/static/controllers/dc_conversation_command_controller.js#markActive | single writer of the palette cursor for slash + Cmd+K
file   | packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js#handlePaletteKey | reference palette cursor (activeReferenceIndex)
file   | packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js#applyContext | the one apply path; reconcileContext / updateContinuityWarning follow it
file   | packages/dartclaw_runtime/lib/src/api/session_routes_support.dart#effectiveContextView | view projection; `_contextOptions` stays paired with renderContextOptions
file   | packages/dartclaw_runtime/test/static/app_js_test.dart#_customSelectHarness    | Node harness pattern for driving shared.js with a fake DOM
```


## Constraints & Gotchas

- **Constraint**: a programmatic write to a `select.form-select` leaves its enhanced trigger stale – every revert or rebuild in S10/S13 goes through `setSelectValue` / `syncCustomSelect`.
- **Constraint**: `mouseover`/`pointerenter` fire when a list scrolls under a stationary pointer, which breaks S05 – drive the cursor from pointer *movement* only.
- **Constraint**: preventing the default of `pointerdown` alone does not stop focus moving in every engine – use `mousedown` (or both) for S15, and leave `click` untouched so rows still choose.
- **Constraint**: template comments ship in rendered pages and whole-page tests ban `—` – keep new `chat.html` comments free of em dashes.
- **Constraint**: `.dart` code compiles into a running serve VM and static assets are served from a versioned path – validate in a fresh server on a free port with a hard reload.


## Implementation Plan

### Implementation Tasks

- **TI01** Floating `.pop` surfaces keep their resting look under hover, and rows inside `.pop` show hover and cursor on a fill distinct from `--bg-surface0` in both themes (canon only; regenerate with `dart run dev/tools/embed_assets.dart`)
  - Pattern: `.card-glass:hover` restates the resting values; the row fill must separate from both `--bg-surface0` (elevated menus) and the glass palettes.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/design_system_contract_test.dart --name "floating surfaces"` – asserts `.pop` hover restates rest values (no translate) and the in-`.pop` row hover/cursor fill token differs from the `.card-elevated` background token
  - **SATISFIES**: S01, S03, SC01

- **TI02** An enhanced-select menu has one cursor: pointer movement over an enabled option focuses it without scrolling, disabled options are ignored, and the focused option carries the row fill
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/app_js_test.dart --name "enhanced select option cursor"` – Node harness: a move over `high` focuses it, ArrowDown then focuses the next option, a move over a disabled option leaves focus unchanged
  - **SATISFIES**: S01, S02

- **TI03** An enhanced-select menu opens below when it fits, otherwise on the side with more room with its height capped to that room, recomputed on every open
  - Measure against the viewport and any clipping scroll ancestor (dialogs have scrolling bodies). Upward placement is a canon modifier on `.custom-select-menu`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/app_js_test.dart --name "enhanced select menu placement"` – harness with stubbed rects covers fits-below (no modifier), flips-up, and clamped (capped max-height on the larger side)
  - **SATISFIES**: S06, S07, S08

- **TI04** In the slash palette, the Cmd+K dialog and the `@` reference palette, pointer movement over a row makes it the single active row; a resting pointer never does
  - Slash and Cmd+K route through `markActive`; the reference palette through `activeReferenceIndex`. `.composer-palette-option` stops painting `:hover` separately from `[aria-selected="true"]`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/conversation_search_command_controller_test.dart --name "pointer movement moves the palette cursor" && dart test --reporter=failures-only packages/dartclaw_runtime/test/static/chat_composer_controller_test.dart --name "pointer movement moves the palette cursor"` – for slash, Cmd+K and the `@` reference palette (harnessed in `chat_composer_controller_test.dart`): a move over a second row leaves one `palette-item--active`/`aria-selected="true"` row, and a scroll without a move keeps the keyboard row
  - **SATISFIES**: S04, S05

- **TI05** A mouse press anywhere inside the slash palette, the reference palette or the Cmd+K results leaves focus in that palette's input, while row clicks still choose
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/conversation_search_command_controller_test.dart --name "palette press keeps input focus" && dart test --reporter=failures-only packages/dartclaw_runtime/test/static/chat_composer_controller_test.dart --name "palette press keeps input focus"` – asserts the `mousedown` default is prevented on the slash palette and Cmd+K results (first file) and the reference palette (second file), and the click handler still chooses the row
  - **SATISFIES**: S15

- **TI06** Both composer popovers apply on commit with no Apply button: selects on `change`, Directory on its `change`, provider changes after the catalogue rebuild, one request at a time with a queued follow-up carrying the returned revision
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/effective_context_controller_test.dart --name "context applies on change"` – covers one request per commit, provider rebuild before the single request, serialised follow-up with the new revision, and no submit button
  - **SATISFIES**: S09, S10, S11, S12, SC02

- **TI07** A rejected apply shows the server's message, restores every select to the last applied context, and keeps Directory's typed text with `aria-invalid="true"` until the next success
  - Depends on TI06's apply path.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/effective_context_controller_test.dart --name "a rejected apply restores the applied context"` – asserts message shown, selects synced back, directory text kept and marked invalid, and cleared on the next success
  - **SATISFIES**: S13

- **TI08** The continuity notice is keyed on the last-run provider: `effectiveContextView` exposes it, `chat.html` renders the notice's first paint from it, and the controller compares the applied next-turn provider against it
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/effective_context_view_test.dart --name "continuity notice" && dart test --reporter=failures-only packages/dartclaw_runtime/test/static/effective_context_controller_test.dart --name "continuity notice"` – view marks the notice shown for next `codex` over current `claude`, hidden when equal and when there is no current context; the controller test pins the same comparison after a client apply
  - **SATISFIES**: S14

- **TI09** Tests and templates no longer pin the Apply buttons, and the docs state the shipped behaviour
  - `effective_context_template_test.dart` currently asserts two "Apply to next turn" matches.
  - **Verify**: `cmd: bash -c '! rg -q "Apply to next turn|effective-context-apply|effective-context-project-apply" packages/dartclaw_runtime/lib docs/guide/web-ui-and-api.md && ! rg -q "either Apply commits both" dev/bundle/docs/wireframes/deviations.md && ! rg -q "hover is the same fill without the label lift" dev/design-system/DESIGN.md'` – fails on the pre-change tree; exits 0 only once no Apply control, id or doc statement of the old behaviour remains
  - **SATISFIES**: SC02, SC03

### Validation

- In a fresh server (`bash examples/run.sh dev --port <free port>`) at 800×600, dark and light: hover rows in the Model popover's selects and in the slash palette (one highlight, no jump); open Effort in the Model popover (fully visible); click the slash palette header then press ArrowDown (no outline on `#main-content`, cursor moves); pick a model (pill updates, no Apply button). Screenshots under `.agent_temp/`.


## Discovered Requirements

> _Managed by exec-spec during implementation – append-only, one bullet per requirement in the shape fis-mutability.md states. Spec authors: leave this section empty._

_No requirements discovered yet._


## Implementation Observations

> _Append-only: Preflight records a deferred decision here while authoring, exec-spec its observations post-implementation. Nothing else is written here._

- TI08 / S14: `effectiveContextView` exposes the decision (`continuityHidden`), not the raw last-run provider, and dc-chat reads it from every applied snapshot instead of re-comparing providers client-side. One authority per concern (ADR-054): first paint and client apply cannot disagree. Outcome of S14 unchanged; no `lastRunProvider` key ships because nothing would read it.
- S12: when a follow-up commit is queued, the first response only records the applied snapshot and absorbs its revision; the controls are reconciled from the final response. Reconciling them from the first would revert the waiting change before it is sent.
- S13: Directory is marked `aria-invalid` only when its typed text differs from the applied directory. While marked, other commits carry the applied directory, so an unrelated pick can succeed ("until the next successful apply clears it"); committing Directory again sends the typed text.
- S13: the rejection message is written to both popovers' `.pop-validation` (one is ever open), since a queued commit may come from either.
- Placement: `.custom-select-menu--up` plus an inline `max-height` only when clamped; bounds are the viewport intersected with every ancestor whose `overflow-y` is not `visible`.
- Canon: the global `.palette-item:hover` fill is removed. Every non-palette `.palette-item` sits inside a `.pop`, which now fills rows with `--bg-surface1` on hover; the slash/Cmd+K palettes paint only the cursor.
- Browser (800x600, dark and light): only one provider (`claude`) is configured in `examples/dev.yaml`, so S10/S14 provider switching was covered by the Node harnesses only. Pre-existing and out of scope: opening a context popover focuses the hidden native `<select>` (`openContextPopoverFrom` queries `form select`), and `POST /api/inbox/<id>/read` answers 409 on page load.
- Review follow-up: while a commit is in flight or waiting, a conversation-state refresh records its snapshot as the applied context but leaves the controls alone, and a commit's answer yields to a newer refreshed snapshot. A provider change keeps a model/effort only if the new provider lists it (else Provider default); an off-catalogue value survives only on the server-authoritative reconcile. The applied context is seeded at connect from the server-rendered controls. A refusal arriving after its popover closed is also shown as an error toast.
