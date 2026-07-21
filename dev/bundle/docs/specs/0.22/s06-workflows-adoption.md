# Workflows Adoption

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S06

## Feature Overview and Goal

**Intent**: Bring the workflow list, detail, and step-detail pages onto the Afterglow canonical primitives so operators reading a workflow run see a coherent, on-brand surface instead of bare step output, a foreground-token hover, and inline `display:none` toggles.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] A workflow step's rendered output (its session transcript) presents inside a framed terminal window (title bar + traffic-light dots + body), not a bare scroll block — plain frame only, never the CRT modifier.
- [OC02] The workflow picker cards (`.workflow-card`, rendered in the New-Task dialog) hover with the canonical accent-mix border instead of the non-token `--fg-overlay` foreground border; no workflow card hover borrows the `--fg-overlay` foreground token.
- [OC03] The step-detail expand and shared-context reveal use the `hidden` attribute (no inline `style="display:none"` remains on the workflow list/detail templates); the collapse/expand behavior is unchanged.
- [OC04] The workflow list and detail pages sit in the canonical `.content-area`/`.content-inner` layout container, off the parallel `.page-content`/`.page-inner` family.


## Required Context

> Load-bearing upstream spans inlined verbatim. Binding constraints flow unchanged from `plan.json#bindingConstraints`.

### From `prd.md` – "FR5: Per-page component adoption"
<!-- source: prd.md#fr5-per-page-component-adoption -->
<!-- extracted: 7d948b65 -->
> **Description**: Bring every page to "good" compliance by composing canonical primitives: glass (`.card-glass`) for overlays above live content (toasts, dialogs, composer palettes), `kbd` for shortcut hints, identicons for entity identity (sessions, channels, task agent badges — never state), terminal frames for diff/raw/step-output views, and `metric-value`/`display` type for KPIs/headers. Clear the violations inventory: purge inline styles into classes/utilities, delete the `settings.html` `<style>` block, collapse the three parallel layout-container families into the canonical one, fix non-token hovers, and convert `display:none` toggles to the `hidden` attribute.
>
> **Acceptance Criteria**:
> - Page-by-page compliance table (audit §5) reads "good" for all pages.
> - ≤5 justified inline `style` attributes remain app-wide; no template-local `<style>` block remains.
> - Glass is used only over live content (never in-flow); identicons encode entity identity only, never state.
> - Each page passes visual validation in both themes (desktop + 768px) before its work is considered done.

### From `prd.md` – "User Stories – US01"
<!-- source: prd.md#user-stories -->
<!-- extracted: 7d948b65 -->
> US01 | As an operator, I want the Web UI to present one coherent, polished visual language so DartClaw feels like a high-quality, trustworthy tool. | Acceptance: Page-by-page compliance (audit §5) reads "good" on every page; no page mixes bespoke and canonical treatments for the same job. | Must / P0

### Binding Constraint – FR1 (CSS layering: byte-identical synced files)
<!-- source: prd.md#fr1-synced-drift-checked-design-system-css -->
<!-- extracted: 7d948b65 -->
> `design-system.css` is byte-identical to `dartclaw-public/dev/design-system/components.css` (verified by the drift check); `tokens.css` likewise (app-only tokens isolated in `app-tokens.css`).

### Binding Constraint – FR1 (drift check exits non-zero on mismatch)
<!-- source: prd.md#fr1-synced-drift-checked-design-system-css -->
<!-- extracted: 7d948b65 -->
> A documented dev command (wired into the verification path) diffs synced files against canon and exits non-zero on mismatch.

### Binding Constraint – NFR (zero-npm / server-first)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### Binding Constraint – NFR (design-system compliance + scarcity doctrine)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.

### Binding Constraint – NFR (mobile parity)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.

### Binding Constraint – NFR (`window.confirm` stays)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **`window.confirm` stays**: currently sanctioned by DESIGN.md; replacing it is out of scope (needs an upstream DESIGN.md decision-table change first).

### From `plan.json` – "sharedDecisions: CSS layering & sync contract"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> S01 establishes static/design-system.css (verbatim canonical components.css, provenance header), static/app.css (app-only rules, loaded after), static/app-tokens.css (surviving app tokens), and the drift check. All later stories add/edit app CSS only in app.css and never touch synced files; new generic classes go upstream-first to dev/design-system/ then sync down.

### From `plan.json` – "sharedDecisions: Layout-container family collapse"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> Canonical .content-area/.content-inner arrives with the S01 sync. Each per-page story migrates its own page off the parallel families (.page-content/.page-inner, .dashboard/.dashboard-inner, .info-content/.info-inner); the app.css rules for a family are deleted by the story that removes its last consumer.

### From `plan.json` – "sharedDecisions: Feedback-primitive ownership"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> S03 owns every meter/claw-loader/skeleton/scan-bar swap app-wide (including deletions of the four bespoke bars and both spinners). Per-page stories S04–S07 and S09 compose the primitives S03 landed and must not re-implement or re-swap loading/progress UI.


## Deeper Context

- `audit-design-system-compliance.md#5-quick-reference--page-by-page-compliance` – Workflows (Partial) row; the non-progress top-3 fixes this story clears. Audit line numbers are stale — locate by selector/content.
- `audit-design-system-compliance.md#2-new-component-adoption-map` – terminal-frame row ("workflow step output `workflow_step_detail.html`") and the layout-container-family notes.
- `audit-design-system-compliance.md#3-violations-inventory` – "Non-token hover" (`.workflow-card:hover` foreground-token border) and the `display:none`-toggle and container-family entries.
- `dev/design-system/components.css` – canon for `.terminal-frame` (bar + dots + body; `--crt` login-only), `.content-area`/`.content-inner`, and `.card:hover` (accent-mix) — all delivered by the S01 sync into `static/design-system.css`.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01] Step output renders as a plain terminal frame**
  - **Given** a workflow step-detail fragment for a step that has a session transcript (`hasSession` true)
  - **When** the step-detail fragment renders
  - **Then** the session output (`.workflow-step-chat` messages) is wrapped in a `.terminal-frame` with a `.terminal-frame-bar` (carrying `.terminal-frame-dots` and the step name as its title) and a `.terminal-frame-body`, and no `terminal-frame--crt` modifier is present (CRT is login-only per scarcity)

- [x] **S02 [OC01] [TI01] A step with no session shows the empty text, not an empty frame**
  - **Given** a step-detail fragment for a step with no session (`hasSession` false)
  - **When** the fragment renders
  - **Then** the "No session yet." empty text (`.workflow-step-no-session`) shows and no empty `.terminal-frame` is emitted (the frame wraps present output only)

- [x] **S03 [OC02] [TI02] Workflow cards hover with the canonical accent-mix border**
  - **Given** the New-Task dialog rendering the workflow picker cards (`.workflow-card`, each carrying the canonical `.card` base)
  - **When** a card is hovered
  - **Then** its hover border derives from the canonical accent-mix (`color-mix(... var(--accent) ...)`) and no workflow card `:hover` rule sets `border-color: var(--fg-overlay)`

- [x] **S04 [OC03] [TI03,TI04] Step-detail and shared-context toggles use the hidden attribute**
  - **Given** the workflow detail page with a collapsed step-detail row and a collapsed shared-context panel
  - **When** the operator expands the step (`data-step-toggle`) and the context (`data-context-toggle`)
  - **Then** each panel starts with the `hidden` attribute (no `style="display:none"`), the controller reveals it by clearing `hidden`, and the chevron flip / lazy `hx-trigger="intersect once"` step-detail load behave exactly as before

- [x] **S05 [OC04] [TI05] Workflow list and detail pages use the canonical layout container**
  - **Given** the workflow list page and the workflow detail page
  - **When** each renders its main content region
  - **Then** the container is `.content-area` with a `.content-inner` child (page-specific `workflow-list-page`/`workflow-detail-page` modifiers preserved) and neither template carries `page-content` or `page-inner`


## Structural Criteria

> Non-behavioral guards, each proved by a task Verify line.

- [x] No `style="display:none"` / `style="display: none;"` remains in `workflow_list.html` or `workflow_detail.html` (proved by TI03).
- [x] No workflow card `:hover` rule in `static/app.css` sets `border-color: var(--fg-overlay)` (proved by TI02).
- [x] `workflow_list.html` and `workflow_detail.html` carry no `page-content`/`page-inner` class; the `.page-content`/`.page-inner` app.css rules are retained (S06 is not their last consumer) (proved by TI05).
- [x] All CSS edits land in `static/app.css`; the synced `design-system.css` / `tokens.css` are untouched and the S01 drift check still exits zero (proved by TI02/TI06).
- [x] `lib/src/generated/embedded_assets.g.dart` is regenerated and `git diff --exit-code` on it is clean after the template/static edits (proved by TI06).
- [x] No new runtime JS dependency, `@import`, or build step is introduced — changes are plain CSS + Trellis + Stimulus only (proved by TI06).


## Scope & Boundaries

### Work Areas
- `templates/workflow_step_detail.html` — the step session output (`.workflow-step-chat` → `.messages`) is wrapped in a plain `.terminal-frame`; the bar carries `.terminal-frame-dots` + the step name as its title. [TI01]
- `templates/workflow_detail.dart` (`workflowStepDetailFragment`) + `web/pages/workflows_page.dart` (`_handleStepDetail`) — thread the step name into the fragment so the bar can title itself; the render path already resolves the definition step (`definition.steps[stepIndex].name`). [TI01]
- `static/app.css` — the workflow card `:hover` rule adopts the canonical accent-mix border (no `--fg-overlay`); no other new CSS. [TI02]
- `templates/workflow_detail.html` — the two inline `display:none` toggles (step-detail wrapper, shared-context body) move to the `hidden` attribute; the page container migrates to `.content-area`/`.content-inner`. [TI03,TI05]
- `templates/workflow_list.html` — the page container migrates to `.content-area`/`.content-inner`. [TI05]
- `static/controllers/dc_workflows_controller.js` — the step-detail and shared-context reveal toggles switch from `.style.display` to the `.hidden` property. [TI04]
- Verification finalization — regenerate `embedded_assets.g.dart`; extend the workflow template-render tests for the new markup. [TI06]

### What We're NOT Doing
- The workflow progress meters (`.workflow-progress-bar`/`-fill` on detail; the run-card `.workflow-run-progress-bar-sm`/`-fill-sm` on the list) -- all determinate progress is S03-owned (feedback primitives); S06 must not re-implement or re-swap progress UI. Leave the progress markup and its dynamic width `tl:attr` alone.
- The workflow picker skeletons and the step-detail "Loading step details…" placeholder (`.workflow-step-detail-loading`) swap to skeleton -- S03; do not touch that inner placeholder or the `dc_workflows_controller` picker loading/empty/form toggles (`workflow-list-loading`, `workflow-form`, `workflow-project-select`).
- The `--crt` terminal modifier -- reserved for the login hero (S11); step output uses the plain `.terminal-frame` only per the scarcity doctrine.
- Identicons, glass surfaces, `kbd`, and empty-state claw-marks on the workflow pages -- not called for by the audit Workflows row; S11–S13 own brand moments.
- Deleting the `.page-content`/`.page-inner` app.css rules -- other pages still consume them; per the container-collapse decision the rules are deleted by the story that removes the last consumer, not S06.


## Architecture Decision

**Approach**: Compose the already-synced canonical primitives (`.terminal-frame`, `.content-area`/`.content-inner`, `.card:hover`) in the workflow templates; keep every CSS edit in `static/app.css` per the S01 sync contract, and convert the two inline visibility toggles to the `hidden` attribute (the `[hidden]{display:none!important}` reset already ships in `app.css`, kept there by the S01 split). No new classes are invented.


## Code Patterns & External References

```
# type | path#anchor                                              | why needed (intent)
file   | dev/design-system/components.css#.terminal-frame         | Frame structure (bar + .terminal-frame-dots + .terminal-frame-body) for step output; NO --crt here
file   | dev/design-system/components.css#.content-area           | Canonical layout container (+ .content-inner) replacing .page-content/.page-inner
file   | dev/design-system/components.css#.card                    | Canonical .card:hover accent-mix border/glow the workflow cards inherit
file   | packages/dartclaw_server/lib/src/templates/task_detail.html | Sibling terminal-frame wrap pattern for diff/raw artifacts (S05) — mirror the bar/dots/body shape and the bar-title convention (S05 titles the bar with the artifact filename; S06 with the step name)
file   | packages/dartclaw_server/lib/src/static/controllers/dc_workflows_controller.js#bindWorkflowDetailToggles | Existing style.display step-detail + context reveal toggles to convert to .hidden
```


## Constraints & Gotchas

- **CSS lives in `app.css` only**: the S01 split makes `design-system.css`/`tokens.css` verbatim-synced; editing them fails the drift check. Every S06 style change goes in `static/app.css`.
- **`[hidden]` reset already exists**: the `[hidden] { display: none !important; }` reset ships in `app.css` (a canonical-absent primitive kept app-side by the S01 split), so the `hidden` attribute suffices — no new app.css rule needed for the toggle. The step-detail lazy `hx-trigger="intersect once"` fires only once the wrapper is revealed; `hidden` (also `display:none`) preserves that timing exactly.
- **Trellis smoke render passes null**: gate any new boolean on a pre-computed context field; use `tl:attr`/`tl:classappend` for dynamic classes/attributes. See LEARNINGS § Trellis Templates.
- **Regenerate embedded assets**: any template or `static/` edit requires `dart run dev/tools/embed_assets.dart`; `embedded_assets.g.dart` is checked-in generated output and CI fails on a stale diff. See `packages/dartclaw_server/AGENTS.md`.
- **Scarcity — no CRT here**: the single `--crt` surface app-wide is the login hero (S11); workflow step output uses the plain `.terminal-frame`.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** Workflow step output renders inside a plain terminal frame
  - In `workflow_step_detail.html`, wrap the step session output (the `.workflow-step-chat` block's `.messages`) in a `.terminal-frame` (`.terminal-frame-bar` with `.terminal-frame-dots` + `.terminal-frame-body`). Plain frame only — no `--crt`. Per the terminal-frame-title convention (see Implementation Observations), the bar carries the `.terminal-frame-dots` followed by a short contextual title — for step output that title is the step name, mirroring S05's artifact frames (which title the bar with the artifact filename). The `stepDetail` fragment context does not yet carry the step name, so thread it in from the step-detail render path (`workflowStepDetailFragment` / `_handleStepDetail`, which already resolves `definition.steps[stepIndex].name`) and bind it into the bar as the title; the frame is emitted only on the `hasSession` branch, so the title is only needed there. Keep the `tl:if="${hasSession}"` guard so the no-session branch (`.workflow-step-no-session`) still shows its empty text with no empty frame. Preserve the `tl:utext="${messagesHtml}"` binding.
  - **Verify**: `Test: rendered stepDetail fragment with hasSession=true contains "terminal-frame" wrapping the messages with "terminal-frame-bar", "terminal-frame-dots" and "terminal-frame-body", the step name renders as the bar title inside "terminal-frame-bar", and no "terminal-frame--crt"; with hasSession=false it contains "workflow-step-no-session" and no "terminal-frame"`

- [x] **TI02** Workflow picker cards hover with the canonical accent-mix border
  - The violating rule is `.workflow-card:hover` in `static/app.css`, which sets `border-color: var(--fg-overlay)`. `.workflow-card` is the workflow *picker* card that `dc_workflows_controller.js` renders into the New-Task dialog's `.workflow-list-cards` (each also carries the canonical `.card` base) — it is not a workflows-page card. The workflows-page run cards (`.workflow-run-card`) are already token-compliant: their `:hover` only sets `background: var(--bg-surface0)` and has no border to fix, so do not go looking for a run-card violation. Change `.workflow-card:hover` to the canonical accent-mix border (e.g. `color-mix(in srgb, var(--accent) 20%, var(--bg-surface0))`), or drop the override so the inherited canonical `.card:hover` accent-mix wins. Keep the edit in `static/app.css`; never touch the synced `design-system.css`. This story owns the picker-card hover rule (the plan assigns the app-CSS fix here); S05 carries the matching hand-off note.
  - **Verify**: `Test: grep static/app.css finds no ".workflow-card:hover" rule setting "border-color: var(--fg-overlay)"; the picker card (.workflow-card) hover border derives from a color-mix of --accent; visual validation confirms the accent hover on the New-Task dialog picker cards in both themes`

- [x] **TI03** Step-detail and shared-context panels toggle via the hidden attribute
  - In `workflow_detail.html`, replace `style="display: none;"` on the step-detail wrapper (`.workflow-step-detail`) and the shared-context body (`.workflow-context-body`) with the `hidden` attribute. Leave the inner `.workflow-step-detail-loading` placeholder and its `hx-trigger="intersect once"` untouched (S03-owned).
  - **Verify**: `Test: grep workflow_detail.html finds no "display: none" / "display:none"; the .workflow-step-detail wrapper and .workflow-context-body carry the "hidden" attribute`

- [x] **TI04** The reveal controller toggles `.hidden` instead of `.style.display`
  - In `dc_workflows_controller.js`, change the step-detail reveal and the shared-context reveal toggles (currently reading/writing `detail.style.display === 'none'` / `body.style.display`) to toggle the `hidden` property (`el.hidden = !el.hidden`), keeping the chevron `icon-chevron-up`/`-down` flip. Do not touch the picker loading/empty/form toggles (S03-owned).
  - **Verify**: `Test: dc_workflows_controller.js step-detail and shared-context toggle handlers set el.hidden (no ".style.display" for those two panels); manual UI check — expand/collapse of a step row and the shared-context panel behaves as before, and an unexpanded step's details lazy-load on first expand`

- [x] **TI05** Workflow list and detail pages use the canonical layout container
  - In `workflow_list.html` and `workflow_detail.html`, change the `<main ... class="page-content">` to `class="content-area"` and the inner `class="page-inner workflow-*-page"` to `class="content-inner workflow-*-page"`. Keep the page-specific modifier classes and the `data-controller`/`data-*` attributes. Canonical `.content-inner` carries the upstream stack gap (flex-column + `gap: var(--sp-6)`, landed by S01 — see the content-inner-stack-gap note in Implementation Observations), so section/card vertical spacing is preserved by the container itself; add no per-page spacing rule. Do not delete the `.page-content`/`.page-inner` rules from `static/app.css` (other pages still consume them).
  - **Verify**: `Test: rendered workflow_list and workflow_detail contain class="content-area" and "content-inner" and neither contains "page-content" or "page-inner"; grep static/app.css still defines .page-content and .page-inner`

- [x] **TI06** Embedded assets and workflow template tests reflect the canonical markup
  - Run `dart run dev/tools/embed_assets.dart` after the template/static edits; extend `test/templates/workflow_detail_template_test.dart` and `test/templates/workflow_list_template_test.dart` with assertions for `content-area`/`content-inner`, the `hidden` toggles, and (via the step-detail render path) the `terminal-frame` wrap.
  - **Verify**: `Test: git diff --exit-code on lib/src/generated/embedded_assets.g.dart is clean after regen; dart test test/templates/workflow_detail_template_test.dart test/templates/workflow_list_template_test.dart passes; the S01 CSS drift check exits zero (synced design-system.css/tokens.css untouched)`

### Testing Strategy
> Level allocation is non-obvious because the two reveal toggles are controller-injected JS.

- Template-embedded markup (terminal-frame wrap, `content-area`/`content-inner`, `hidden` attributes) is assertable in Layer 2/3 template-render tests — extend the two existing `test/templates/workflow_*_template_test.dart` suites.
- The `.hidden` reveal toggles (TI04) and the card hover (TI02) have no Dart render surface — validate via the UI smoke test / `visual` profile (expand/collapse a step and the shared-context panel; hover a workflow picker card via New-Task dialog → Workflow tab in both themes).

### Validation

- Visual validation of the workflow list, detail, and a step-detail with session output in both themes at desktop + 768px per the story gate: step output in a terminal frame whose bar is titled with the step name, accent-mix hover on the New-Task dialog picker cards, working expand/collapse, and the canonical container with section spacing on par with the pre-migration layout (the `.content-inner` stack gap holds the vertical rhythm). Confirm the cancel/reject `hx-confirm` prompts still fire (window.confirm stays).

### Execution Contract

- S06 requires S03 landed (it owns the workflow progress meter, picker skeletons, and the step-detail loading placeholder this story must not touch). Edit `static/app.css` only; never the synced files. Regenerate `embedded_assets.g.dart` before declaring done and keep the drift check green. S06 shares `static/app.css` with the other W2 page stories — edit only the workflow card-hover rule.


## Final Validation Checklist

- [x] App-wide the workflow pages are grep-clean of the S06-scope violations: no `page-content`/`page-inner` on `workflow_list.html`/`workflow_detail.html`, no `style="display:none"` in either template, and no `border-color: var(--fg-overlay)` on a workflow card `:hover` in `static/app.css`.


## Implementation Observations

- Visual validation passed the workflow containers, picker hover, and hidden context in both themes at desktop and 768px.
- Seeded runs had zero steps, so terminal-frame and lazy step-detail live states were verified by render/controller tests rather than live capture.

#### DECISION NOTE: terminal-frame-title

Decision-Key: terminal-frame-title
Altitude: project — app-wide `.terminal-frame` convention shared across stories (S05, S06)
Affected surface: All `.terminal-frame` bars app-wide; for S06 the step-output frames in `workflow_step_detail.html` (TI01), shared with the S05 artifact frames in `task_detail.html`
Decision: Every `.terminal-frame` bar carries a short contextual title after the traffic-light dots. For S06 step-output frames the title label is the step name.
Rationale: Shared app-wide convention with S05, whose artifact frames use the artifact filename; matches canon's showcase examples and DESIGN.md's "title bar" contract.
Evidence: Canon showcase examples and DESIGN.md's "title bar" contract. Ratified by owner during 0.22 preflight, 2026-07-20.

#### DECISION NOTE: content-inner-stack-gap

Decision-Key: content-inner-stack-gap
Altitude: project — canonical `.content-inner` vertical rhythm delivered by the S01 sync, inherited by every page on the container (S06 among them via TI05/OC04)
Affected surface: The canonical `.content-inner` rule (upstream `dev/design-system/components.css`, synced to `static/design-system.css` by S01); for S06 the workflow list/detail pages migrated onto `.content-area`/`.content-inner` (TI05)
Decision: Canonical `.content-inner` gains flex-column + `gap: var(--sp-6)` upstream via S01's canon work; this page inherits vertical section rhythm from the synced rule and adds no per-page spacing rule.
Rationale: Section rhythm belongs on the canonical container so every page on `.content-inner` shares one vertical cadence; a per-page spacing rule would duplicate canon and drift from the S01 sync contract.
Evidence: S01 canon work (upstream `dev/design-system/components.css` → synced `design-system.css`). Ratified by owner during 0.22 preflight, 2026-07-20.
