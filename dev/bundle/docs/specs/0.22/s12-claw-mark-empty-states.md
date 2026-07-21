# Claw-mark Empty States

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S12

## Feature Overview and Goal

**Intent**: Empty states are the app's quietest brand real estate — branding their icons with the pixel claw-mark lets the 8-bit crab identity peek through exactly where a user hits a dead-end, without spending more than the one claw moment each view is allowed.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] The Tasks-list and Projects-list empty states show the pixel `.claw-mark` (green→teal→blue gradient, pixel-crisp, theme-aware) in place of their emoji glyph, in both themes.
- [OC02] No off-list emoji (📂 `&#128194;`, 🗃 `&#128451;`) remains in any empty state; the sanctioned prompt glyph (`❯_`, `&#10095;`) on the app-level/chat empty states and the sanctioned decorative `💬` (`&#128172;`) on the task-detail session-not-started state are left unchanged.
- [OC03] Every affected view honors one-claw-moment scarcity: task detail carries no empty-state claw-mark (its single claw moment is the S03 activity-row loader), so no view ever renders more than one claw element at once.


## Required Context

> Load-bearing upstream spans inlined verbatim. Binding constraints flow unchanged from `plan.json#bindingConstraints`.

### From `prd.md` – "FR6: Brand identity surfaced"
<!-- source: prd.md#fr6-brand-identity-surfaced -->
<!-- extracted: 7d948b65 -->
> **Description**: Serve the 8-bit crab mascot (favicon + login CRT-terminal hero + sanctioned empty states) with `.pixel-art`; replace emoji empty-state icons with the claw-mark where appropriate; roll out identicons. All under the scarcity doctrine.
>
> **Acceptance Criteria**:
> - Favicon is the mascot avatar (crisp at 16/32px); no empty `data:,` favicon.
> - Exactly one CRT surface app-wide (the login hero); mascot never rendered below ~32px or without `.pixel-art`.
> - Empty states use the claw-mark/mascot per the one-mark-per-view rule; the prompt glyph stays where sanctioned.

### Binding Constraint – NFR (design-system compliance + scarcity doctrine)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.

### Binding Constraint – NFR (zero-npm / server-first)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### Binding Constraint – NFR (mobile parity)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.


## Deeper Context

- `audit-design-system-compliance.md#2-new-component-adoption-map` – the `.claw-mark` row (empty-state split: tasks/projects/task_detail candidates, "give the mark to at most one" on task detail, `components.html` keeps `❯_`) and the mascot row. Audit line numbers are stale — locate by selector/content.
- `audit-design-system-compliance.md#3-violations-inventory` – "Emoji empty-state icons" bullet: `projects.html` (📂) and `task_detail.html` (🗃) are off-list; `💬`/`☐` are sanctioned decorative glyphs.
- `dev/design-system/DESIGN.md#identity` – "The ownable elements" (mascot vs `.claw-mark` vs prompt glyph), the scarcity doctrine ("One claw moment per view … If the mark appears in three places on one screen, it's wallpaper"), and "Unicode exceptions" (💬, 📋, ☐ sanctioned decorative; `❯` brand identity).
- `dev/design-system/components.css#.claw-mark` – the mark is a markup-free CSS element (`<span class="claw-mark"></span>`, pseudo-element box-shadow grid); theme-aware, scales with `font-size`; needs no image asset.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01] Tasks-list empty state shows the claw-mark**
  - **Given** the Tasks page rendered with no tasks (`hasTasks` false → the `.empty-state` block shows)
  - **When** the empty-state icon renders
  - **Then** the icon is the pixel `.claw-mark` (`<span class="claw-mark">`) and the previous `&#9744;` (☐) glyph is gone

- [x] **S02 [OC01] [TI02] Projects-list empty state shows the claw-mark (off-list 📂 eliminated)**
  - **Given** the Projects page rendered with no projects (`hasProjects` false → the `.empty-state` block shows)
  - **When** the empty-state icon renders
  - **Then** the icon is the `.claw-mark` and no `&#128194;` (📂) remains anywhere in `projects.html`

- [x] **S03 [OC02,OC03] [TI03] Task-detail artifacts empty state drops off-list 🗃 without gaining a mark**
  - **Given** a task-detail page whose artifact column is empty (`hasArtifacts` false → the "No artifacts yet" `.empty-state` shows)
  - **When** the artifacts empty state renders
  - **Then** the off-list `&#128451;` (🗃) glyph is gone and the empty state carries **no** `.claw-mark` — because task detail's single claw moment is the S03 activity-row loader

- [x] **S04 [OC02] [TI03,TI04] Sanctioned glyphs are preserved**
  - **Given** the app-level/chat empty states (`components.html` `emptyState` + `emptyAppState`) and the task-detail session-not-started state
  - **When** those empty states render
  - **Then** the `❯_` prompt glyph (`&#10095;`) on both `components.html` states and the `&#128172;` (💬) on `task_detail.html` session-not-started remain unchanged, and no `.claw-mark` or mascot image is introduced on them

- [x] **S05 [OC03] [TI03] Per-view scarcity holds under co-occurrence**
  - **Given** a running task-detail whose artifacts are still empty (the activity-row `.claw-loader` from S03 is visible **and** the "No artifacts yet" empty state shows in the same render)
  - **When** the page renders
  - **Then** exactly one claw element is present app-wide on that view — the `.claw-loader` — and zero `.claw-mark` elements appear in `task_detail.html` (a naive substitute that branded either empty state would double the claw moment and fail here)


## Structural Criteria

> Non-behavioral guards, each proved by a task Verify line.

- [x] No off-list emoji codepoint (`&#128194;` / 📂, `&#128451;` / 🗃) remains in any template after this story.
- [x] All CSS edits (if any) land in `static/app.css`; the synced `design-system.css` / `tokens.css` are untouched (drift check stays green).
- [x] No new runtime JS dependency, `@import`, or build step is introduced — changes are plain Trellis templates (+ optional `app.css`) only (zero-npm constraint).


## Scope & Boundaries

### Work Areas
- `templates/tasks.html` — the "No tasks yet" `.empty-state-icon` becomes the `.claw-mark` (`&#9744;` removed).
- `templates/projects.html` — the "No projects registered" `.empty-state-icon` becomes the `.claw-mark` (off-list `&#128194;` removed).
- `templates/task_detail.html` — the "No artifacts yet" `.empty-state-icon` drops the off-list `&#128451;` and gets **no** mark; the "Session not started" state keeps its sanctioned `&#128172;`.
- `templates/components.html` — the `emptyState` / `emptyAppState` fragments are verified unchanged (`❯_` stays; no mark/mascot added) — verification only, no edit expected.
- `static/app.css` — only if the `.claw-mark` needs a sizing tweak inside `.empty-state-icon` (existing `font-size: 2.5rem` already scales it; likely no change).

### What We're NOT Doing
- Applying the **mascot image** to any empty state / consuming the S11 mascot-serving route -- the app's only app-level empty states (`components.html`) keep the sanctioned `❯_` prompt glyph per the story scope, audit §2, and DESIGN.md, so the "mascot (app-level empty states)" branch has no in-scope application; the S11 dependency is ordering/insurance only. (Surfaced as a scope note.)
- Changing the task-detail **session-not-started `💬`** -- it is a sanctioned decorative glyph (DESIGN.md "Unicode exceptions"); the scope only mandates eliminating the *off-list* 📂/🗃.
- Adding, moving, or restyling the **S03 activity-row claw-loader** -- S03-owned; S12 only refrains from adding a competing mark on that view.
- The `❯_` prompt glyph on `components.html`, `login.html`, `sidebar.html` -- sanctioned Unicode identity; stays.
- Identicons, meters, glass, terminal-frames, or any non-empty-state adoption -- owned by S03/S05/S13 and the per-page stories.


## Architecture Decision

**Approach**: Swap the emoji glyph inside the existing `.empty-state-icon` wrapper for a markup-free `<span class="claw-mark"></span>` on the two list empty states; the mark is pure canonical CSS (synced by S01), theme-aware, and sizes from the wrapper's `font-size`, so no image asset and (almost certainly) no CSS change are needed. Task detail is deliberately left mark-free because its one claw moment is already spent on the S03 loader.


## Code Patterns & External References

```
# type | path#anchor                                                      | why needed (intent)
file   | dev/design-system/components.css#.claw-mark                       | The mark is markup-free CSS (span + box-shadow grid), scales with font-size — no image, no mascot pipeline
wire   | dev/design-system/showcase.html                                  | `<span class="claw-mark">` element + font-size scaling ("Pixel Claw Mark"/"App Lockup" cards; showcase's own empty-state exemplar uses the mascot image, not the mark)
file   | packages/dartclaw_server/lib/src/templates/tasks.html            | The `.empty-state-icon` markup to brand (`&#9744;` → claw-mark)
file   | packages/dartclaw_server/lib/src/templates/task_detail.html      | The two empty states (session-not-started 💬 stays; artifacts 🗃 out, no mark)
file   | packages/dartclaw_server/lib/src/templates/components.html        | emptyState/emptyAppState fragments that keep `❯_` (verify unchanged)
```


## Constraints & Gotchas

- **Scarcity + the S03 loader own task detail's claw moment**: a running task with empty artifacts renders the activity-row `.claw-loader` *and* the "No artifacts yet" empty state at the same time — so branding either task-detail empty state would put two claw elements on one view. Task detail gets no empty-state mark; the off-list 🗃 is simply removed (icon-less empty state), the sanctioned 💬 stays.
- **The claw-mark is CSS-only, not the mascot**: `.claw-mark` is a `<span>` with a CSS box-shadow pixel grid (synced via S01's `design-system.css`) — it needs no served asset, so it does not depend on S11's mascot route despite the plan's `dependsOn`.
- **Sync contract (S01)**: `design-system.css` / `tokens.css` are verbatim-synced and drift-checked — any CSS edit goes in `static/app.css` only. The `.empty-state-icon` `font-size: 2.5rem` already sizes the mark (~70×40px, above the ~32px legibility floor), so a CSS change is unlikely.
- **Trellis smoke render passes null**: the claw-mark is static markup with no `${}` bindings, so it is safe under null-variable smoke render (see LEARNINGS § Trellis Templates).


## Implementation Plan

### Implementation Tasks

- [x] **TI01** The Tasks-list empty state icon is the pixel claw-mark
  - In `tasks.html`, the `.empty-state-icon` for "No tasks yet" contains `<span class="claw-mark"></span>` instead of `&#9744;`. Static markup; the wrapper's `font-size` sizes the mark. Pattern: the "Pixel Claw Mark" card in `dev/design-system/showcase.html` (`<span class="claw-mark">` scaling with `font-size`).
  - **Verify**: `Test: rendered tasks.html empty state contains class token "claw-mark" and no "&#9744;"`

- [x] **TI02** The Projects-list empty state icon is the pixel claw-mark
  - In `projects.html`, the `.empty-state-icon` for "No projects registered" contains `<span class="claw-mark"></span>` instead of `&#128194;`. Off-list emoji eliminated.
  - **Verify**: `Test: rendered projects.html empty state contains class token "claw-mark"; grep projects.html contains no "&#128194;"`

- [x] **TI03** Task-detail artifacts empty state is off-list-emoji-free with no claw-mark; session-not-started keeps 💬
  - In `task_detail.html`, remove the `&#128451;` (🗃) from the "No artifacts yet" `.empty-state-icon` and add **no** `.claw-mark` (the S03 activity-row loader is this view's single claw moment). Leave the "Session not started" `&#128172;` (💬) untouched.
  - **Verify**: `Test: grep task_detail.html contains no "&#128451;" and no "claw-mark"; still contains "&#128172;"`

- [x] **TI04** App-level and chat empty states keep the prompt glyph (no mark/mascot)
  - Confirm `components.html` `emptyState` and `emptyAppState` fragments still render the `❯_` (`&#10095;`) glyph and gain no `.claw-mark` or mascot image. Verification-only — no edit expected.
  - **Verify**: `Test: grep components.html contains "&#10095;" in both empty-state fragments and contains no "claw-mark"`

### Validation
- Visual validation of the Tasks and Projects empty states in both themes at desktop + 768px per the story gate: the claw-mark renders pixel-crisp with the green→teal→blue gradient, centered in the empty state, one per view. Spot-check task detail (running task with empty artifacts) to confirm only the activity-row loader shows — no second claw element.


## Final Validation Checklist
- [x] Per-view scarcity check: for each affected view (tasks list, projects list, task detail in running/not-started/review states) exactly one claw element (`.claw-mark` or `.claw-loader`) renders at most.


## Implementation Observations

- Dark/light 768px validation passed for the live Tasks empty state and controlled current-source Projects/task-detail fixtures. Tasks and Projects render one centered claw-mark with no overflow; task detail renders one activity claw-loader, zero claw-marks, and preserves the sanctioned session-not-started glyph.
