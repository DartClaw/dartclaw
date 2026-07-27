# Canon: form, control, tab and state primitives

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: The design system never shipped the component families its own documentation promises, so the app was forced to invent them privately – 56 bespoke form rules, two divergent tab bars, an ungoverned `.btn-sm` used 58 times – leaving the product's densest surfaces outside the design system entirely; this story gives those families a canonical home so the sweep phase has something to adopt.

**Expected Outcomes**:

- [OC01] A template author can build any form DartClaw already ships (settings, task, scheduling, guard editor, pairing) out of documented canonical classes alone – fields, labels, text inputs, native selects, textareas, errors, hints, checkboxes, radios and toggles all exist in canon, are demonstrated, and carry the § Native selects treatment DESIGN.md has documented without backing since 0.22.
- [OC02] Exactly one tab component exists in the system's vocabulary, and it survives the hardest case the app has – ten tabs at 768px – without clipping or wrapping.
- [OC03] The app's most-used button modifier is governed, and a ghost button at rest reads as a control rather than as prose.
- [OC04] List and card surfaces have canonical search/toolbar, pagination, empty-state, absent-value and header-actions treatments to adopt, instead of each inventing one.


## Required Context

### From `docs/specs/0.22.1/prd.md` – "FR4: Form, tab and dialog primitives in canon"
<!-- source: docs/specs/0.22.1/prd.md#fr4-form-tab-and-dialog-primitives-in-canon -->
<!-- extracted: e18cf85 -->
> **Description**: Add a Forms section to `components.css` (`.form-field` / `-label` / `-input` / `-select` / `-textarea` / `-error`, checkbox, toggle), back the already-documented § Native selects with real CSS, add one `.tabs` / `.tab` component, and add `.dialog` (frame, `::backdrop` scrim, `-header` / `-body` / `-footer` / `-actions`, `--sm|--md` width ladder, `.dialog--confirm` variant). Promote the app's proven private `.task-dialog` recipe rather than inventing a new one. Document all three families in DESIGN.md and showcase.html; then delete the app-local duplicates and fold `.settings-tabs` / `.tab-bar` onto the canonical component.
>
> **Acceptance Criteria**:
> - [ ] `.form-*`, `.tabs`/`.tab`, `.dialog` exist in canon, documented and demonstrated.
> - [ ] No app-local re-implementation of any of the three remains; only one tab bar ships.
>
> **Priority**: Must / P0

_Scope split: the `.dialog` family and the app-local deletions above belong to S04 and S05 respectively. This story owns the form, tab, button-size, toolbar and state primitives._

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

### From `docs/specs/0.22.1/plan.json` – Shared decision: canon-first, and canon closes after P1
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: working tree, 2026-07-25 -->
> A story that changes a canon-owned rule edits `dev/design-system/` (tokens.css / components.css / icons.css / DESIGN.md / showcase.html) first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` — regenerating the two-line `/* Synced from … sha256: … */` provenance header — within the same story. `dev/tools/fitness/check_design_system_sync.sh` must be green at every story boundary. ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes, because the check pins a sha256 on line 2 of each served copy and concurrent edits in the parallel P3 wave conflict on that line by construction. S05 re-syncs nothing new — it verifies the check is green after its purge. A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

_This story is the hoist target for the **form / control / tab / state** family. Three rules the parallel P3 wave would otherwise have authored mid-sweep land here instead — see `docs/specs/0.22.1/canon-hoist-manifest.md`: the field-width scale and the canonical invalid-state hook (both Forms, **TI02**), the `.tabs--sticky` material and overflow-affordance correction (**TI06**), and `.card-header-actions` (**TI10**). Consumers: S11 (settings), S15 (projects), S05 (the invalid-state swap). Each consumer's canon-edit task and re-sync step are dropped on the strength of these three, so a rule omitted here has no second author._

### From `docs/specs/0.22.1/plan.json` – Shared decision: composite type-class vocabulary
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `docs/specs/0.22.1/plan.json` – Shared decision: `--text-sm` retirement protocol
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> Two-step so the app never breaks mid-migration: S02 aliases `--text-sm` to `--text-base` in canon `tokens.css` and stops treating it as a tier in DESIGN.md; S07 migrates every remaining usage in `app.css` and `design-system.css` onto the composite classes and then deletes the alias from canon. No other story introduces a new `--text-sm` usage.


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#a-canon-changes--the-design-system-itself-is-the-defect-40` – the five findings this story closes: `global` form-primitive gap, `global` btn-sm gap, `global` empty-state tier, `settings/global` two divergent tab bars, `knowledge-hub` toolbar/pagination gap, `projects, chat composer` ghost buttons. Read the *Evidence* blocks for the exact app-side inventory each canonical shape must absorb.
- `../dartclaw-public/dev/design-system/DESIGN.md#native-selects` – the three-bullet contract this story must finally back with CSS, including the Safari opened-popover limitation.
- `../dartclaw-public/dev/design-system/DESIGN.md#components` – the container decision flowchart and card sub-element table; new families slot beside these, in the same table-plus-prose style.
- `../dartclaw-public/dev/design-system/DESIGN.md#buttons` – the existing six-item button vocabulary the size tier extends.
- `docs/wireframes/ux-spec-pagination.md#planned-pagination-ui-pattern` – the sanctioned pager shape: Previous/Next, "Page 1 of 5" indicator, `btn-ghost` styling, server-rendered via `hx-get?page=N`, no client-side state.
- `docs/wireframes/ux-spec-empty-states.md#design-principles` – centred layout for page-level empties, placeholder rows for list/table empties, muted body text, `btn-primary` for the primary action.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – server/token setup and the agent-browser snapshot loop used for this story's both-theme validation.
- `docs/specs/0.22.1/canon-hoist-manifest.md` – why three rules the sweep stories discovered land in this story rather than in theirs, and what each consumer expects to find. Read the "Consequences for the P3 stories" section: S11 and S15 lose their canon-edit tasks on the strength of what this story ships, so a rule omitted here has no second author.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md:1054` – the field-width finding verbatim, including the suggested values (`.form-input--num { max-width: 12ch }`, `--short { max-width: 32ch }`) and the surrounding `.well` clustering guidance that S11 owns.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI02,TI03,TI04,TI12] The canonical form family renders a complete DartClaw form from canon alone**
  - **Given** `showcase.html` is opened directly (it links only `tokens.css`, `components.css` and `icons.css` – no `app.css`)
  - **When** the new Forms panel is rendered in dark theme and again after toggling to light
  - **Then** a `.form-field` containing `.form-label` + `.form-input`, a `.form-select`, a `.form-textarea`, a `.form-error`, a `.form-hint`, a checkbox, a radio and a toggle all render as designed controls – inputs carry the input-family surface with `var(--inset-sm)` depth, and the `.form-select` shows the `--icon-chevron-down` mask with no browser-default arrow chrome
  - **And** keyboard-focusing each control shows a visible `:focus-visible` indicator in both themes
  - **And** an `aria-invalid="true"` control renders the invalid treatment *with* its `.form-error` message rendered beside it, so the state is never carried by border colour alone; a `required` control the user has touched and left empty shows the identical treatment through `:user-invalid`, so the ARIA hook and the browser's own validity state cannot diverge – and a control that is merely `:focus-visible` inside an invalid field still shows the invalid boundary rather than having it overwritten by the focus ring
  - **And** a `.form-input--num` field is capped near its content width and a `.form-input--short` field at a short-text width, while an unmodified control in the same `.form-row` still fills its column – the Port field and a directory-path field are visibly different widths

- [ ] **S02 [OC02] [TI05,TI06,TI12] One tab component survives the ten-tab settings case**
  - **Given** the showcase Tabs panel demonstrates a `.tabs` bar with ten `.tab` children (at least one with a two-word label), one carrying `active`, at a 768px viewport – and the bar genuinely overflows there (`scrollWidth > clientWidth`), so the case under test is real – plus a second four-tab bar that fits (`scrollWidth === clientWidth`)
  - **When** the panel is rendered
  - **Then** the bar scrolls horizontally on one line – no wrapping, no clipped final tab – and the active tab is marked by the accent underline plus accent text, not by colour alone
  - **And** the same active treatment applies whether the markup uses `class="tab active"` or `aria-selected="true"`, so ARIA state and visual state cannot diverge
  - **And** the ten-tab bar signals its own overflow without hover and without JavaScript – at `scrollLeft` 0 the right-edge indicator is visible and the tenth tab is not fully in view; scrolled to the end, the tenth tab is fully readable and the indicator is gone – while the four-tab bar shows no indicator at any scroll position, and the bottom border runs unbroken to the right edge of both. The audit's failure mode (ten tabs reading as nine, "Security" unreachable behind an overlay scrollbar) cannot recur
  - **And** a `.tabs--sticky` bar pinned at the top of a scrolled container reads as part of the plane it sits on in both themes, with no hard-edged opaque seam against S01's body gradient at scroll-top

- [ ] **S03 [OC03] [TI07,TI12] A resting ghost button reads as a control**
  - **Given** the showcase Buttons panel shows `.btn.btn-ghost` and `.btn.btn-ghost.btn-sm` with no pointer over them, demonstrated on both planes a ghost button actually sits on after S01 – inside a `.card` and directly on the page ground
  - **When** the resting boundary colour is sampled against each of those two surfaces in both themes
  - **Then** the contrast is ≥3:1 (WCAG 1.4.11 non-text minimum) on both planes, so the control is identifiable without hover – the audit's `projects.png` "Fetch" failure mode cannot recur
  - **And** `.btn-sm` differs from `.btn` by compact padding and a smaller `min-height` only; it declares no `font-size`, so no 12px button labels re-enter the type distribution

- [ ] **S04 [OC04] [TI08,TI09,TI10,TI12] List and card surfaces have canonical toolbar, pager, empty, absent-value and header-actions treatments**
  - **Given** the showcase panels for the list toolbar, pager, empty state and card header
  - **When** they are rendered
  - **Then** a `.list-toolbar` places a `.form-input--search` (leading `.icon-search`) beside its action buttons, a `.pager` renders `btn-ghost` Previous/Next around a `.pager-label`, and the `.empty-state` shows a real `.empty-state-title` above its body copy and action button – with the inline `style="color:var(--fg)"` override the showcase currently patches onto `<strong>No sessions yet</strong>` deleted
  - **And** an empty `<span class="value-absent"></span>` renders the em dash as generated content in `--fg-sub0`, and a `.meter` at 0% carries the `.meter--empty` treatment rather than reading as a solid rule
  - **And** a `.card-header` carrying a trailing `.card-header-actions` slot pushes its buttons to the header's right edge with the title still baseline-aligned and the `border-bottom` running the full width, while a `.card-header` without the slot renders exactly as it does today

- [ ] **S05 [OC01,OC02] [TI01,TI02,TI03,TI04,TI05,TI06,TI13] Live surfaces change only where a canonical name already exists in the app, and change coherently**
  - **Given** no template, controller or `app.css` line is edited by this story, and twelve canonical names already exist in `app.css` and in live markup – `.form-label` (56 uses), `.form-input` (44), `.form-select` (20), `.form-error` (33), `.form-hint` (13), `.form-row` (13), `.form-textarea` (1), `.pager` / `.pager-label` (4/1), `.empty-state-title` (4), `.btn-icon-sm` (5), `.btn-danger-fill` (1) – plus the two canon-owned rules this story rewrites, `.btn-ghost` and `.btn-sm`
  - **And** one *state* joins that interaction set rather than the zero-delta list: `input.form-input:user-invalid` reaches the three live `required` `.form-input`s the moment the served CSS is re-synced – `channel_detail.html:119` (dm-allowlist entry), `:184` (group-allowlist entry) and `workflow_list.html:93` when a definition marks the variable required – each of which today signals nothing when submitted empty
  - **And** fresh story-start captures of `/settings`, `/scheduling`, `/knowledge`, `/projects` and `/chat` were taken before the first canon edit (the audit's 92-shot set is stale as a per-story comparator once S01 re-tones and S02 re-scales – it stays the release-level baseline S14 uses)
  - **When** the `visual` profile (port 3338) renders those surfaces in both themes at 1280px and 768px after the re-sync
  - **Then** every delta against the story-start captures traces to a name in the list above, and each one is the canonical treatment applied *whole* – in particular no `<select>` anywhere shows `appearance: none` without the canonical chevron beside it
  - **And** names with no existing app rule or markup – `.form-field`, `.form-radio`, `.form-toggle`, `.tabs`, `.tab`, `.tabs--sticky`, `.list-toolbar`, `.form-input--search`, `.form-input--num`, `.form-input--short`, `.card-header-actions`, `.value-absent`, `.meter--empty`, and the `[aria-invalid="true"]` hook no markup sets yet – produce zero delta, and `.settings-tab` / `.tab-btn` bars render unchanged


## Structural Criteria

- [ ] `dev/tools/fitness/check_design_system_sync.sh` exits 0 – the served `design-system.css` is byte-identical to canon below its regenerated two-line `sha256:` provenance header.
- [ ] The story's diff introduces zero new `var(--text-sm)` occurrences in `dev/design-system/components.css`.
- [ ] No *unqualified* `input` / `select` / `textarea` / `label` / `fieldset` element selector is added to `components.css`; every new form and control rule is class-bound (element-*qualified* selectors such as `select.form-select` are the intended shape – see Constraints).
- [ ] Every class this story adds has backing CSS, a DESIGN.md entry and a `showcase.html` demonstration – and nothing is documented that has no backing CSS.
- [ ] The only `z-index` literal this story adds is `.tabs--sticky`'s, so `rg -c 'z-index:\s*(1[0-9]|[2-9][0-9]|[0-9]{3,})' dev/design-system/components.css` returns `4`: the three pre-existing canon literals (`20`, `15`, `100`) plus `.tabs--sticky`. That grep is S04 TI01's own Verify, which requires zero matches – so S04 physically cannot close without converting this literal (see Constraints, L3).


## Scope & Boundaries

### Work Areas

- `dev/design-system/components.css` – new Forms, Tabs, and Toolbar/Pager sections; revised Buttons, Cards (the `.card-header-actions` slot beside `#.card-header`) and Empty-state/Meter rules; one named exemption added to the existing § 24 Reduced Motion block for the tab overflow indicator; the numbered category list in the file header.
- `dev/design-system/DESIGN.md` – frontmatter `components:` entries for the new families, plus § Components / § Native selects / § Buttons prose and the § Cards sub-element table.
- `dev/design-system/showcase.html` – demonstration panels for every new class.
- `packages/dartclaw_server/lib/src/static/design-system.css` – the re-synced served copy with a regenerated provenance header.
- The *interaction set* – the twelve canonical names that already exist in `app.css` and live markup, plus `.btn-ghost` / `.btn-sm` and the `:user-invalid` state TI02 adds: these reach live app surfaces the moment the served CSS is re-synced, before S05 adopts anything (enumerated in Scenario S05 and Constraints).
- `dev/design-system/icons.css` – the theme-aware chevron token pair the native `<select>` needs, plus its re-synced served copy.

### What We're NOT Doing

- The `.dialog` frame, `::backdrop` scrim, `--z-*` ladder and the feedback decision-table rewrite -- S04 owns them. Two deliberate exceptions, both because a later story consumes what this one ships: `.btn-danger-fill` joins canon here as the filled destructive variant S04's `.dialog--confirm` and the app's existing `.delete-confirm-bar` both compose (and it is one of the off-vocabulary button classes the audit's btn-sm finding names) -- *without* the app-local copy's `--text-sm`, which S02 retires; and `.tabs--sticky` declares a single `z-index` literal that S04 converts to `var(--z-sticky)` (Constraints, L3). Neither is a second z-index scale or a second button family.
- Any app-side adoption -- no template, controller or `app.css` edit. Deleting `.form-group` / `.settings-tabs` / `.tab-bar` / the app's `.btn-sm` is S05's purge; a swap done here would break the S03/S05 boundary and land untested markup changes in a canon story.
- The `.custom-select` custom-listbox family (22 uses) -- DESIGN.md § Native selects sanctions a custom listbox as the escape hatch precisely where `<select>` cannot be branded; canon backs the *native* control here and the listbox stays app-owned.
- A canonical filter chip -- canon already settles this: chips never carry *outcome* state, and DESIGN.md § Chips sanctions toggle/filter chips (`button.chip` with `aria-pressed`, accent tint) for *selection* state; S10's knowledge sweep adopts that existing rule rather than re-deciding it here.
- Surface tokens, type-scale values and container tiers -- S01 and S02 own them; this story consumes their output and re-tones nothing.


## Architecture Decision

**Approach**: promote the app's already-proven shapes (`app.css` `.form-*`, `.settings-tabs`, `.btn-sm`, `.pager`, `.knowledge-search-strip`) into `dev/design-system/components.css` under canonical names, writing the control rules element-*qualified* (`input.form-input`, `select.form-select`, `textarea.form-textarea`) so that where a name already exists in the app the canonical treatment lands whole rather than half-applied, then re-sync the served copies in the same story.
**Why this over alternatives**: designing fresh would turn S05's swap into a rewrite instead of a class rename – the app's shapes are already validated across 250+ call sites. Element qualification is the specificity fix for the one hazardous collision: `app.css`'s `background` *shorthand* would otherwise erase a canonical chevron while canon's `appearance: none` still applied, leaving live selects with no dropdown affordance for the whole S03→S05 window.
**Overflow affordance — scroll, and which scroll affordance** (the canon-wide call the sweep stories may not make): the bar **scrolls and signals**, it does not wrap. Wrapping is defensible in isolation — `app.css#.tab-bar` does it at ≤768px — but TI05 already fixes scrolling over wrapping for the ten-tab case, and choosing wrap for the affordance would hand the system two tab behaviours again, which is the exact defect OC02 closes. The affordance is a **right-edge indicator whose visibility is driven by `animation-timeline: scroll(self inline)`**: it shows while unscrolled content remains to the right and fades as the bar reaches its end. Three properties decide it — it is conditional on real overflow (a non-overflowing bar drives no timeline, so the indicator holds its hidden base state), it is independent of the surface behind the bar (it darkens rather than covers), and it does not touch the element's box, so `border-bottom` runs unbroken. `scroll-snap-type: inline proximity` rides along so a flicked bar lands on a tab boundary rather than mid-label. Where scroll-driven animations are unsupported the `animation-timeline` declaration is ignored and the indicator stays hidden — today's behaviour exactly, never worse — with the styled scrollbar as the universally-supported baseline signal.
**Why not the three alternatives**: *styling the scrollbar alone* is the mechanism that already failed — `app.css#.settings-tabs:1177-1185` ships `scrollbar-width: thin`, `scrollbar-color`, a 4px `::-webkit-scrollbar` and a thumb, and the audit still recorded the tenth tab as unsignalled, because a 4px `--fg-overlay` thumb is not a legible signal; canon keeps the scrollbar but raises the thumb off `--fg-overlay` rather than relying on it. A *`mask-image` edge fade* masks the element, so it fades the `border-bottom` with it, and it is unconditional — a four-tab bar would carry it. The *`background-attachment: local, scroll` scroll-shadow pair* is genuinely overflow-conditional, but its cover layers must match the surface *behind* the bar, and `.tabs` sits on S01's body gradient with horizontally-varying ambient washes, so the covers would band.
**Why three rules arrive from the sweep stories**: canon closes after P1, so a rule S11 or S15 discovers mid-sweep has nowhere to land – five parallel stories re-syncing the same served files collide on the sha256 provenance line by construction, and authoring canon during adoption inverts the release's own canon-before-adoption decision. The hoist manifest routes each to the P1 story owning its family; all three land here because all three are form, tab or card-header rules. They arrive as first-class tasks (TI02, TI06, TI10), documented and demonstrated like every other family, because the consumer stories drop their canon-edit tasks on the strength of them.


## Technical Overview


## Code Patterns & External References

```
# type | path#anchor or url                                                  | why needed (intent)
file   | packages/dartclaw_server/lib/src/static/app.css#.form-input          | The bespoke form family's core field/input rules (app.css:817-848; the audit's 56-rule count spans the wider family incl. the out-of-scope `.custom-select*`) the canonical shapes must absorb without behaviour changes – copy the surface, focus, disabled and placeholder handling
file   | packages/dartclaw_server/lib/src/static/app.css#.form-input.error    | The bespoke invalid-state shape (app.css:840, `border-color: var(--error)`) the canonical `[aria-invalid="true"]` / `:user-invalid` hook absorbs – it is the whole app-side treatment, so canon adds the pairing rule with `.form-error`, not a new colour
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js | The only consumer of that shape: `classList.add('error')` at :325 and the `.form-input.error` reset sweep at :230. S05 repoints both onto the canonical hook – canon must therefore key the attribute, not the class
file   | packages/dartclaw_server/lib/src/static/app.css#.settings-tabs       | Sticky + horizontally-scrolling tab bar with a thin scrollbar (app.css:1167-1204) – the hard case (10 tabs) the canonical `.tabs` must keep working. Note its `background: var(--bg-base)` and `z-index: 10`: the flat opaque slab is the material defect S11 reported, the literal is what L3 resolves
file   | dev/design-system/components.css#.card-header                        | Flex row with `gap`, `align-items: center` and a `border-bottom` (components.css:803-813) and no right-aligned slot – `.card-header-actions` extends it with the same `margin-left: auto` idiom `app.css#.tab-header-actions` already proves
file   | packages/dartclaw_server/lib/src/static/app.css#.tab-bar             | The second, wrapping tab bar (app.css:1063-1066) being folded onto the same component; note it carries `role="tab"` / `aria-selected` in memory_dashboard.html
file   | packages/dartclaw_server/lib/src/static/app.css#.tab-header-actions  | The trailing actions slot inside the tab bar (app.css:1067-1068), incl. its full-width wrap at ≤768px – the shape `.tabs-actions` must absorb
file   | packages/dartclaw_server/lib/src/static/app.css#.btn-sm              | The ungoverned size modifier (app.css:569) and `.btn-icon-sm` (app.css:788) – 58 + 4 uses
file   | packages/dartclaw_server/lib/src/static/app.css#.knowledge-search-strip | The per-surface search/filter toolbar invention (app.css:3064-3102) the canonical `.list-toolbar` replaces
file   | packages/dartclaw_server/lib/src/static/app.css#.pager               | The per-surface pager invention (app.css:3183-3202) the canonical `.pager` replaces
file   | dev/design-system/components.css#.composer-model                     | The chevron the select must visually match (`::after` + `--icon-chevron-down` mask, components.css:623-631) – match the look, not the mechanism: pseudo-elements do not render on `<select>`
file   | dev/design-system/icons.css#.theme-toggle::before                    | The file's only per-theme override (under `[data-theme="light"]`, icons.css:374) – the pattern the new background-image chevron token pair follows; every other `--icon-*` URI is black-stroked and colour-resolves only via mask + currentColor
file   | dev/design-system/components.css#.btn                                | Existing button base – size tier and ghost rest state must compose with its inset top-edge highlight and hover lift
file   | dev/design-system/components.css#.empty-state                        | The three-rule empty-state canon being expanded; `.meter` / `.meter-fill` live earlier in the file under § Status Indicators (~components.css:1329)
file   | dev/design-system/showcase.html                                      | Panel structure: `<h2>` heading + `.well-content` wrapper; the empty-state panel carries the inline style override to delete
file   | dev/tools/fitness/check_design_system_sync.sh                        | The gate: sha256 on line 2 of the served file must match the canon file, and `tail -n +3` must diff clean
wire   | docs/wireframes/settings-page.html                                   | The settings form surface whose controls the canonical family must be able to express
```


## Constraints & Gotchas

- **Critical**: this story is *not* visually inert on live surfaces. `app.css` loads *after* `design-system.css` (`layout.html:16-17`), so same-specificity app rules win on shared properties – but twelve canonical names already exist in `app.css` and in markup (`.form-label`, `.form-input`, `.form-select`, `.form-textarea`, `.form-error`, `.form-hint`, `.form-row`, `.pager`, `.pager-label`, `.empty-state-title`, `.btn-icon-sm`, `.btn-danger-fill`), and every property canon sets that the app rule does *not* leaks through immediately. Must handle by: writing control rules element-qualified so the canonical treatment applies whole, enumerating the interaction set (Scenario S05), and visually validating those live surfaces in this story rather than deferring them to S05.
- **Critical**: `::after` does not render on a native `<select>`, and a `mask-image` on the control clips the whole element -- Must handle by: painting the chevron with the `background-image` / `-position` / `-repeat` *longhands* (which also survive `app.css`'s `background` shorthand once the rule is element-qualified). The existing `--icon-*` data URIs are black-stroked and only work through `mask-image` + `currentColor`, so a `background-image` chevron needs its own theme-aware token pair in `icons.css` – mirroring the `[data-theme="light"]` override already at `icons.css:374`.
- **Avoid**: *unqualified* element selectors (`input {`, `select {`, `label {` …) in the new Forms section -- Instead: element-qualified, class-bound rules (`input.form-input`). An unqualified selector would re-skin every unadopted template at once, blow the S03/S05 boundary and make S05's diff unreviewable.
- **Constraint**: no new `var(--text-sm)` usages anywhere in this story (S02 aliased the token; S07 deletes it) -- Workaround: where a new rule needs a type tier, the documented markup composes the S02 composite class (`.t-caption` for hints and errors, `.t-label` for labels and tabs); component rules otherwise carry layout, colour and state only. **Carve-out**: form controls do not inherit the document font, so every control rule sets `font: inherit` – that is inheritance, not tier re-derivation, and is what `components.css#.btn` already does.
- **Constraint**: CSS only – no JavaScript. Tabs, toggles, checkboxes and radios must be pure CSS on native elements (zero-npm / no-build-step / no-new-runtime-JS binding constraint) -- Workaround: state comes from `:checked`, `aria-selected` and an `active` class the server or an existing controller sets.
- **Critical**: never edit `packages/dartclaw_server/lib/src/static/design-system.css` as a source file -- Must handle by: editing canon, then regenerating the served copy as `header + canon body` so `sha256` on line 2 matches and `tail -n +3` diffs clean.
- **Constraint**: Safari themes only the *closed* `<select>`; the opened option popover stays system-native (DESIGN.md § Native selects) -- Workaround: style the closed control, keep the existing prohibition prose, and do not over-style options.
- **Critical**: `:user-invalid`, never `:invalid`. `:invalid` matches an empty `required` field on page load, which would paint the three live `required` `.form-input`s (`channel_detail.html:119`, `:184`, `workflow_list.html:93`) red before the user has typed anything – a false error the moment the served CSS is re-synced. `:user-invalid` only matches after the user has interacted and left the field, which is why it is the only validity pseudo-class this story may use -- Must handle by: keying `:user-invalid` alongside `[aria-invalid="true"]`, declaring the three call sites in the interaction set (Scenario S05), and validating `/settings` and a channel-detail allowlist form on the live `visual` profile in this story rather than deferring them to S05.
- **Constraint**: the invalid boundary must survive focus. `.form-input:focus-visible` sets `border-color: var(--accent)` and an accent outline; a focused invalid field that reads as valid is worse than no state at all -- Workaround: order the invalid rules after the focus rules in the section, or key the focus ring's colour off the invalid state (`input.form-input[aria-invalid="true"]:focus-visible`). Either is fine; leaving both at the same specificity and relying on source order alone is what breaks under later edits.
- **Critical**: canon's own § 24 Reduced Motion block breaks the overflow indicator. It sets `animation-duration: 0.01ms !important` on `*, *::before, *::after` under `prefers-reduced-motion: reduce`, and a scroll-driven animation maps progress across its duration — so with reduced motion on, the indicator jumps to its end state at the first pixel of scroll (or sits in it at rest) instead of tracking scroll position. The indicator conveys *state* (there is more content this way), not decoration, so suppressing it removes information rather than motion, which the NFR does not ask for -- Must handle by: adding the indicator's selector to the existing exemption list inside that `@media` block (the block already exempts `.status-dot--live::before` and five siblings by name), so it keeps its scroll timeline while everything else is flattened. Validate with reduced motion **on** as well as off; an indicator that only works with animations enabled fails the accessibility NFR on the exact users who most need a non-motion signal.
- **Constraint (L3 resolution — stacking)**: S04 defines the `--z-*` ladder one wave later, so `var(--z-sticky)` does not exist while this story runs and a fallback (`var(--z-sticky, 10)`) would leave dead syntax in canon that no sweep catches. **Decision: `.tabs--sticky` declares the literal `z-index: 10`** (the value `app.css#.settings-tabs` uses today, below canon's existing 15/20/100) and S04 converts it -- Must handle by: nothing further in this story. The handoff is a gate, not a coordination note: S04 TI01's own Verify is the blanket grep `rg -n 'z-index:\s*(1[0-9]|[2-9][0-9]|[0-9]{3,})' dev/design-system/components.css` returning **no** matches, and `z-index: 10` matches its `1[0-9]` branch, so S04 cannot close while the literal stands. Record it in Implementation Observations at story close so S04's executor reads it rather than rediscovering it.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Canon carries a Forms section covering the field, label, text-input, select, textarea, error and hint shapes the app invented
  - New numbered section in `dev/design-system/components.css`: `.form-field` (column stack), `.form-field--inline` (label left, control trailing – absorbs `app.css#.form-group-toggle`), `.form-field--checkbox` (control first, label after, `--sp-2` gap – absorbs `app.css#.form-group-checkbox`), `.form-row` (multi-field horizontal group – absorbs the app's `.form-row`, 10 rules / 13 uses), plus `.form-label`, `input.form-input`, `select.form-select`, `textarea.form-textarea`, `.form-error`, `.form-hint`. Derive surface, focus, `:focus-visible`, `:disabled` and `::placeholder` handling – plus `.form-error`'s empty/non-empty `min-height` reservation (app.css:841-842) that prevents validation layout shift – from `app.css#.form-input`, but add the `var(--inset-sm)` depth § Native selects requires. Controls set `font: inherit`; no rule declares `font-size`.
  - **Verify**: `rg -n '\.form-(field|label|input|select|textarea|error|hint|row)' dev/design-system/components.css` lists every class above; `rg -n '^(input|select|textarea|label|fieldset)[^.a-zA-Z0-9_-]' dev/design-system/components.css` prints nothing, while `printf 'input[type=checkbox] { margin: 0 }\n' | rg -n '^(input|select|textarea|label|fieldset)[^.a-zA-Z0-9_-]'` prints its line and `printf 'input.form-input { }\n' | <same pattern>` prints nothing – the two piped controls prove the pattern actually fires on an unqualified selector and spares the intended element-qualified one, so the empty result over `components.css` is a finding rather than a broken regex

- [ ] **TI02** The Forms section carries the canonical invalid state and the field-width scale — the two Forms rules hoisted out of the sweep wave
  - **Invalid state** (cross-cutting M5; S05's `dc_settings_controller.js` swap consumes it and no other story ships it): `input.form-input[aria-invalid="true"]`, `select.form-select[aria-invalid="true"]` and `textarea.form-textarea[aria-invalid="true"]`, keyed together with `:user-invalid` on the same three, so the ARIA hook and the browser's own validity state cannot diverge. The shape is `app.css:840`'s (`border-color: var(--error)`) – that is the entire app-side treatment, so absorb it rather than designing a new one. Two additions canon owes it: the state must survive `:focus-visible` (the focus rule sets `border-color: var(--accent)` – see Constraints), and because the NFR bars status conveyed by colour alone, DESIGN.md states the contract that an invalid control is always rendered with its `.form-error` message, which is the non-colour signal. Do **not** use `:invalid` – see the Critical gotcha.
  - **Field-width scale** (cross-cutting M6, hoisted from S11 TI06; the audit's suggestion at `audit-ui-polish-2026-07-25.md:1054`): `.form-input--num { max-width: 12ch }` and `.form-input--short { max-width: 32ch }` as standalone modifiers that compose onto any of the three control classes, so a two-character Port field is not 866px wide. `ch` is exact here because the control family is `var(--font-mono)`. They cap rather than set – the controls keep `width: 100%`, so an unmodified control in the same `.form-row` is untouched, and no specificity fight with `input.form-input` (0,1,1) arises because `max-width` and `width` are different properties.
  - **Verify**: `rg -n 'aria-invalid|:user-invalid' dev/design-system/components.css` lists rules for all three control classes on both hooks (returns nothing today – exit 1); `rg -n ':invalid' dev/design-system/components.css` prints nothing, while `printf 'input.form-input:invalid\n' | rg -n ':invalid'` prints its line and `printf 'input.form-input:user-invalid\n' | rg -n ':invalid'` prints nothing – the two piped controls prove the pattern fires on the banned pseudo-class and does not false-positive on the sanctioned one (`:user-invalid` contains no `:invalid` substring, since the character before `invalid` is a hyphen); `rg -n '\.form-input--(num|short)' dev/design-system/components.css` returns both (nothing today); and in the showcase an `aria-invalid="true"` control keyboard-focused still shows the error boundary, a `.form-input--num` field measures visibly narrower than the unmodified control beside it, and both render correctly in dark *and* light

- [ ] **TI03** Checkbox, radio and toggle controls exist in canon as CSS-only rules on native inputs
  - `.form-checkbox`, `.form-radio` and `.form-toggle` (+ its slider element), promoted from `app.css#.toggle-switch` / `.toggle-slider` and the bare `<input type="checkbox">` / `<input type="radio">` markup in `settings.html` and `scheduling.html`. State comes from `:checked`; `:disabled` is part of each control's contract (settings.html ships disabled controls today); no JavaScript.
  - **Verify**: showcase renders a checked, an unchecked and a disabled instance of each in both themes with a visible `:focus-visible` ring, and `rg -n 'form-checkbox|form-radio|form-toggle' dev/design-system/components.css` returns the rules

- [ ] **TI04** DESIGN.md § Native selects has real backing CSS
  - `select.form-select` from TI01 gains `appearance: none`, extra right padding, the divider before the chevron, and the chevron itself painted with `background-image` / `-position` / `-repeat` longhands. `dev/design-system/components.css#.composer-model`'s `::after` + mask recipe is the *look* to match but not the mechanism – pseudo-elements do not render on `<select>`. Add a theme-aware token pair to `icons.css` (dark stroke `--fg-sub0` #a6adc8, light stroke #62677d) beside the existing `[data-theme="light"]` override at `icons.css:374`, because the shared `--icon-*` URIs are black-stroked and only resolve colour through `mask-image` + `currentColor`. Closed control only; the Safari popover prohibition prose stays.
  - **Verify**: `awk '/select\.form-select/,/}/' dev/design-system/components.css | rg -n 'appearance: none|background-image'` prints both; in the showcase the select renders the DartClaw chevron with no browser-default arrow, in dark *and* light theme (a black-stroked chevron would vanish in dark – that is the failure this checks)

- [ ] **TI05** The system has exactly one tab component
  - `.tabs` (single-line, `overflow-x: auto`, thin scrollbar, bottom border), `.tab` (`white-space: nowrap` – long labels never wrap inside a tab) with the active treatment keyed on both `.active` and `[aria-selected="true"]`, and `.tabs-actions` – the trailing slot `app.css#.tab-header-actions` occupies (margin-left auto; full-width below the tabs at ≤768px). Absorb both `app.css#.settings-tabs` and `app.css#.tab-bar` shapes – scrolling wins over wrapping, because ten settings tabs at 768px is the case that must not break.
  - **Verify**: showcase's ten-tab demo at 768px scrolls on one line with the last tab reachable and none clipped, and a `.tabs-actions` button stays reachable beside it; active tab shows accent text *and* accent underline

- [ ] **TI06** `.tabs` signals its own overflow, and `.tabs--sticky` sits on the ground rather than over it — the tab-family corrections hoisted out of the sweep wave
  - Both halves are cross-cutting M6, hoisted from S11 TI04 (which loses its canon-edit right and its `dev/design-system/` Work Area entirely, so nothing else authors them).
  - **Overflow affordance**: reachable is not discoverable – at 768px the tenth settings tab ("Security") sits off-screen behind an overlay scrollbar with nothing signalling that more tabs exist, so the bar reads as nine tabs. The mechanism is **decided in the Architecture Decision, not here**: a right-edge indicator on `.tabs` gated by `animation-timeline: scroll(self inline)`, plus `scroll-snap-type: inline proximity` with `scroll-snap-align: start` on `.tab`, and the retained scrollbar with its thumb raised off `--fg-overlay` to a legible tone in both themes. Implement that; do not substitute a wrap, a `mask-image` fade or a `background-attachment` scroll-shadow pair – each was considered and rejected there for a stated reason. Constraints that bind the implementation: no JavaScript (binding constraint), no change to the single-line scrolling TI05 settled, `border-bottom` unbroken to the right edge, and nothing visible on a bar that does not overflow. Canon ships no `animation-timeline` or `scroll-snap` today, so both are new to `components.css`. The task also edits § 24 Reduced Motion to exempt the indicator from the blanket `animation-duration: 0.01ms !important` — see the Critical gotcha; without that edit the affordance is broken for every reduced-motion user.
  - **`.tabs--sticky` material**: carries the sticky-header behaviour `app.css#.settings-tabs` needs. Take the background from S01's chrome/ground token, not app.css's hardcoded `--bg-base` – S11 recorded that the flat opaque slab shows a hard-edged seam against S01's body gradient in light theme at scroll-top, which is the defect this corrects, so the fill has to resolve against whatever plane S01 landed on rather than against a fixed hex. Declare the literal `z-index: 10` per the L3 decision in Constraints – not `var(--z-sticky)`, which S04 ships one wave later, and not a `var(…, 10)` fallback.
  - **Verify (rules exist)**: `awk '/^\.tabs--sticky/,/}/' dev/design-system/components.css | rg -n 'position: sticky|z-index: 10'` prints both lines (`rg -n 'tabs--sticky' dev/design-system/components.css` returns nothing today, so the awk range is empty until this task lands); `rg -c 'z-index:\s*(1[0-9]|[2-9][0-9]|[0-9]{3,})' dev/design-system/components.css` returns `4` – the three pre-existing canon literals (`20`, `15`, `100`; their line numbers move under S01/S02, so match on the values, not the positions) plus this one, confirming S04 TI01's Verify will trip on it.
  - **Verify (the tabs actually stop being unreachable — the check that matters)**: rule presence proves nothing here, so validate against a real overflow at a 768px viewport in the showcase, in both themes. **First prove the demo overflows**, or every check below passes vacuously on a bar that fits: evaluate `const t = document.querySelector('.tabs-demo-ten'); [t.scrollWidth, t.clientWidth]` and require `scrollWidth > clientWidth`; the same expression on the four-tab demo must return equal values. Then, on the ten-tab bar at `scrollLeft === 0`: the right-edge indicator is visible, and the last tab's label is *not* fully visible (that is the condition the indicator is signalling). Scroll it to the end (`t.scrollLeft = t.scrollWidth`): the last tab is fully visible and the indicator is gone. On the four-tab bar: no indicator at any scroll position. On both: `getComputedStyle(t).maskImage` is `none` (the rejected mask-fade mechanism would report a gradient here, and it is the only thing that would fade the border), and the screenshot shows the bottom border running to the right edge at full opacity. Then repeat the ten-tab checks with `prefers-reduced-motion: reduce` emulated: the indicator must still appear at `scrollLeft` 0 and still clear at the end, proving the § 24 exemption landed. Record the browser and version, since the indicator is scroll-timeline-driven and an unsupporting engine degrades it to hidden.
  - **Verify (sticky material)**: a `.tabs--sticky` bar pinned over scrolled content shows no hard-edged seam against the body gradient in either theme, at 768px and 1280px

- [ ] **TI07** The button vocabulary covers size and gives ghost buttons a rest-state affordance
  - `.btn-sm` (compact padding + `min-height`, no `font-size` – the audit's 12px label is the defect) and `.btn-icon-sm`; `.btn-ghost` gains a resting boundary reaching ≥3:1 against the surface behind it in both themes; `.btn-danger-fill` joins canon as the filled destructive variant S04's `.dialog--confirm` consumes. Extends `dev/design-system/components.css#.btn` – keep its inset top-edge highlight and hover lift.
  - **Verify**: sampled resting `.btn-ghost` boundary vs adjacent surface is ≥3:1 in dark and light; `rg -n '^\.btn-sm|^\.btn-icon-sm|^\.btn-danger-fill' dev/design-system/components.css` returns all three, and `awk '/^\.btn-sm[ ,{]/,/}/' dev/design-system/components.css | rg -n 'font-size'` prints nothing

- [ ] **TI08** List surfaces have a canonical search toolbar and pager to adopt
  - `.list-toolbar` (search field grows, actions pushed right, wraps at narrow widths) with `.form-input--search` carrying a leading `.icon-search`; `.pager` + `.pager-label` where the controls are plain `.btn.btn-ghost` per `docs/wireframes/ux-spec-pagination.md#planned-pagination-ui-pattern` (Previous / Next around a "Page 1 of 5" indicator). Derived from `app.css#.knowledge-search-strip` and `app.css#.pager`.
  - **Verify**: showcase renders a `.list-toolbar` and a `.pager` whose Previous/Next controls are `class="btn btn-ghost"` with a `.pager-label` between them; `rg -n '^\.list-toolbar|^\.pager|^\.form-input--search' dev/design-system/components.css` returns the rules

- [ ] **TI09** The empty-state family covers title, action and absent-value cases
  - `.empty-state-title`, action-slot spacing on `.empty-state`, a `.value-absent` treatment that renders the em dash as generated content on an empty element in `--fg-sub0`, and `.meter--empty` for the 0% case that currently reads as a solid `--bg-crust` rule. Per `docs/wireframes/ux-spec-empty-states.md#design-principles`: centred for page-level, muted body copy, `btn-primary` for the primary action.
  - **Verify**: an empty `<span class="value-absent"></span>` renders `–` in the showcase; a `.meter` at 0% is visibly distinct from the same meter with no `--empty` modifier; `rg -n 'empty-state-title|value-absent|meter--empty' dev/design-system/components.css` returns the rules

- [ ] **TI10** A card header has a right-aligned actions slot — the Cards rule hoisted out of the sweep wave
  - `.card-header-actions` beside `dev/design-system/components.css#.card-header` in § 6 Cards (cross-cutting M6, hoisted from S15 TI09, which loses its canon-edit right). `.card-header` is a flex row with `gap` and `align-items: center` and no right-aligned slot, so every surface that wants header buttons invents one; the idiom is the `margin-left: auto` + flex + `--sp-2` gap shape `app.css#.tab-header-actions` already proves and `.tabs-actions` (TI05) reuses – write it once here rather than a third time. The slot must not disturb the header's `border-bottom` or the title's baseline, and a `.card-header` without the slot must render byte-for-byte as it does today.
  - **Verify**: `rg -n '^\.card-header-actions' dev/design-system/components.css` returns the rule (nothing today – exit 1); `git diff "$(git merge-base main HEAD)" -- dev/design-system/components.css | rg -n '^-.*card-header\b'` prints nothing, while `git diff "$(git merge-base main HEAD)" -- dev/design-system/components.css | rg -n '^\+.*card-header-actions'` prints the addition – together proving the slot was *added* beside `.card-header` rather than by rewriting it; in the showcase, a card header with the slot and one without render identically apart from the trailing buttons, in both themes

- [ ] **TI11** DESIGN.md documents every family this story adds, and documents nothing without backing CSS
  - Frontmatter `components:` entries in the existing `backgroundColor` / `textColor` / `typography` / `rounded` / `padding` shape for the new families; § Components gains Forms, Tabs and Toolbar/Pager subsections in the table-plus-prose style; § Native selects states the prohibition is now backed; § Buttons gains the size tier and the ghost rest-state rule; the empty-state guidance gains the title/action/absent-value rules. The three hoisted rules are documented like any other, not as footnotes: the Forms subsection states the invalid-state contract (`[aria-invalid="true"]` / `:user-invalid` are equivalent hooks, and an invalid control always renders its `.form-error` message – the non-colour signal the NFR requires) and the field-width scale with its two values and when to reach for each; the Tabs subsection states the sticky material and the overflow contract — that a `.tabs` bar scrolls rather than wraps, signals its own overflow with a right-edge indicator, and degrades to a hidden indicator on engines without scroll-driven animations, so a consumer knows what it is adopting and does not re-invent a wrap; and `.card-header-actions` joins the § Cards *card sub-elements* table beside `.card-header` / `-body` / `-footer`. Depends on the final class names settled in TI01-TI10.
  - **Verify**: every class introduced in TI01-TI10 appears in DESIGN.md, and every class DESIGN.md's new prose names resolves to a rule in `components.css` (cross-grep both directions, zero misses); `rg -n 'card-header-actions|form-input--num|form-input--short|aria-invalid|user-invalid|tabs--sticky' dev/design-system/DESIGN.md` returns all six (nothing today – exit 1), so a hoisted rule cannot ship undocumented and leave its consumer story with no contract to read

- [ ] **TI12** showcase.html demonstrates every new class
  - Panels for Forms (all controls, both states, plus the invalid state and the two width modifiers), Tabs (a ten-tab bar that genuinely overflows at 768px — give the demo bars stable hooks such as `.tabs-demo-ten` / `.tabs-demo-four` so TI06's overflow assertions can address them — a four-tab bar that fits, and a sticky bar over enough scrolled content to pin), the extended Buttons panel, list toolbar + pager, the expanded empty state, and a card header with and without the actions slot – following the existing `<h2>` + `.well-content` panel structure. Delete the `style="color:var(--fg)"` inline override on `<strong>No sessions yet</strong>` that the canon's own showcase currently needs, since `.empty-state-title` from TI09 replaces it.
  - **Verify**: `rg -n 'style="color:var\(--fg\)">No sessions yet' dev/design-system/showcase.html` prints nothing while `rg -c 'No sessions yet' dev/design-system/showcase.html` still returns 1 – the override is gone and the panel is not (the unrelated Approval Gates override at showcase.html:601 stays); `rg -n 'card-header-actions|form-input--num|form-input--short|aria-invalid|tabs--sticky' dev/design-system/showcase.html` returns all five (nothing today – exit 1); and each class from TI01-TI10 appears at least once in `showcase.html`

- [ ] **TI13** The served CSS matches canon and the story adds no `--text-sm` usage
  - Regenerate `packages/dartclaw_server/lib/src/static/design-system.css` as the two-line `/* Synced from dev/design-system/components.css on <date>. sha256: <hash> */` header plus the canon body; re-run after any remediation that touches canon. Run `date +%Y-%m-%d` for the header date. `icons.css` also needs re-syncing because TI04 adds the chevron token pair; `tokens.css` only if a task introduced a token. Do **not** run `dart run dev/tools/embed_assets.dart` – S14 owns the single release-level regeneration of `embedded_assets.g.dart`, and this story neither runs it nor asserts a clean diff on it.
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0; `git diff -U0 "$(git merge-base main HEAD)" -- dev/design-system/components.css | grep '^+' | grep 'var(--text-sm)'` prints nothing, while the same pipeline with `grep 'var(--'` prints many lines – proving the diff is non-empty and the `--text-sm` result is a real absence, not an empty diff (merge-base against the working tree, so both committed and uncommitted story work is covered; `..HEAD` would pass vacuously on an uncommitted run); and `git status --porcelain packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` prints nothing

### Testing Strategy

### Validation

- Visual validation runs against two targets, not one: `showcase.html` opened directly for the new primitives (it links only canon CSS), and the `visual` testing profile on port 3338 for the interaction set on live surfaces – `/settings` and `/scheduling` (forms and selects), `/knowledge` (pager, search field), `/projects` and `/chat` (ghost buttons), plus `/tasks` (small buttons) and a channel-detail allowlist form (the `:user-invalid` delta: submit the required entry field empty after touching it, and confirm the treatment appears only after interaction, never on page load).
- Capture the live surfaces **before the first canon edit**. Those story-start captures are the per-story regression comparator: S01 re-tones every surface and S02 re-scales its type, so the audit's 92-shot set no longer isolates this story's deltas. The audit set remains the release-level baseline the binding constraint names, re-proven by S14.
- Both themes at 1280px and 768px for each target.

### Execution Contract

- TI13 must be the last canon-touching action. If review or remediation edits `components.css` (or `tokens.css` / `icons.css`) after TI13, re-run the re-sync and the drift check before declaring the story done – a stale sha256 header fails CI for every story after this one.
- Ordering within the canon edits: TI01 before TI02 (the invalid and width rules extend selectors TI01 establishes) and before TI04 (`select.form-select` must exist before it gains `appearance: none`); TI05 before TI06 (the affordance and sticky corrections apply to the `.tabs` rules TI05 lands); TI11 and TI12 after TI01-TI10, since both are inventories of the final class names.
- Two records go into `## Implementation Observations` at story close, because they are the only form in which the next story reads them: (1) the `.tabs--sticky` `z-index: 10` literal and the L3 decision behind it, addressed to S04's executor; (2) the overflow indicator's validated behaviour — the browser and version it was proven on, whether it held under `prefers-reduced-motion: reduce`, and any engine where it degraded to hidden — addressed to S11, whose TI04 asserts the tenth settings tab is reachable *and* discoverable against whatever this story shipped. The mechanism itself is decided here (Architecture Decision) and is not an executor choice; what the record carries is evidence, not a decision. Per `plan.json#executionNotes`, records land in the canonical private FIS, not only in the `dev/bundle/` copy.


## Final Validation Checklist


## Implementation Observations

_No observations recorded yet._
