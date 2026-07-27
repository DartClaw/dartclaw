# FIS: Canon – type scale, composite type layer and container tiers

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: DESIGN.md names eight type tiers but the CSS ships only raw size tokens – three of them inside a 2px band that absorbs ~90% of all declarations – and one 900px container serves prose and eight-column tables alike, so every consumer hand-derives four properties, reliably picks the smallest size, and data tables break their headers mid-word; this story gives the canon a hierarchy and a measure that can actually be applied rather than re-derived.

**Expected Outcomes**:

- [OC01] A contributor applies one class per named tier instead of hand-assembling font-size + weight + line-height + letter-spacing – every tier in DESIGN.md § Typography has exactly one backing composite class, demonstrated in `showcase.html`.
- [OC02] Size differences read as hierarchy: 13px is no longer a distinct tier, section headings sit a perceptible step above body (14 → 18 → 20 → 24 → 32), card titles stop rendering below body size, and markdown headings in agent output keep their structure.
- [OC03] Data-dense surfaces have a compliant wider container tier and canon-governed table headers hold one line, while prose keeps the 900px column with a stated reading measure that leaves code and tables at full width – the wide tier is opt-in, never the default.
- [OC04] Nothing regresses mid-migration: every existing `--text-sm` call site still resolves to a real size, both themes still pass WCAG AA text contrast, and the served CSS stays byte-identical to canon.
- [OC05] The three type-and-icon canon rules the P3 sweeps discovered are shipped here, so no sweep story has to open canon: every mask name the task-event code path emits resolves to a glyph instead of a blank square, the collapse toggles have both chevrons, and a server-composed task prompt keeps its line structure.


## Required Context

### From `prd.md` – "FR2: Type scale rationalization + composite type layer"
<!-- source: docs/specs/0.22.1/prd.md#fr2-type-scale-rationalization--composite-type-layer -->
<!-- extracted: e18cf85 -->
> **Description**: Retire `--text-sm` as a distinct tier (alias to `--text-base` during migration, then remove). Move `--text-lg` from 16px to 18px so section headings separate from body. Keep 12 / 20 / 24 / 32. Add one composite class per named DESIGN.md tier — `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric` — each binding font-size + weight + line-height + letter-spacing together, demonstrated in `showcase.html`. Raw `--text-*` tokens remain for one-offs only.
>
> **Acceptance Criteria**:
> - [ ] Zero `--text-sm` usages in `app.css` and `design-system.css`.
> - [ ] Every tier in the DESIGN.md § Typography table has a backing composite class and a showcase panel.
> - [ ] The DESIGN.md table is updated so `body-sm` is no longer a legitimate choice.

### From `prd.md` – "FR3: Second layout container tier"
<!-- source: docs/specs/0.22.1/prd.md#fr3-second-layout-container-tier -->
<!-- extracted: e18cf85 -->
> **Description**: Add `--container-wide: 1280px` and a `.content-inner--wide` / `.page-inner--wide` modifier; document beside `container-max` in DESIGN.md § Layout. Apply to tasks, health, memory, scheduling, workflows, audit. Keep 900px for chat, session-info, knowledge results and settings forms. Add `white-space: nowrap` to `.data-table th`.
>
> **Acceptance Criteria**:
> - [ ] No table header wraps mid-word at any viewport ≥ 1024px.
> - [ ] Prose surfaces retain the 900px measure.

### From `prd.md` – "Key Constraints, Assumptions & Dependencies"
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.
>
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `prd.md` – "Constraints"
<!-- source: docs/specs/0.22.1/prd.md#constraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `prd.md` – "Out of Scope"
<!-- source: docs/specs/0.22.1/prd.md#out-of-scope -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `prd.md` – "Non-Functional Requirements"
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone
>
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline

### From `plan.json` – "Composite type-class vocabulary" + "`--text-sm` retirement protocol"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.
>
> Two-step so the app never breaks mid-migration: S02 aliases `--text-sm` to `--text-base` in canon `tokens.css` and stops treating it as a tier in DESIGN.md; S07 migrates every remaining usage in `app.css` and `design-system.css` onto the composite classes and then deletes the alias from canon. No other story introduces a new `--text-sm` usage.

### From `plan.json` – "Wide-container assignment"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S02 ships `--container-wide` plus the `.content-inner--wide` / `.page-inner--wide` modifiers. Assignment is fixed here so P3 stories do not each re-litigate it: wide applies to tasks, task detail, health (dashboard + audit), memory, scheduling, the workflow list AND workflow detail; the 900px measure stays for chat, session info, knowledge results, settings forms, and projects. The modifier is opt-in, never the default — a surface not on the wide list keeps 900px unless the sweep documents a deviation.

**This quote, not FR3's, is what TI12 writes into DESIGN.md.** FR3's description above predates the plan and is coarser: it says "workflows" where the plan says the workflow list *and* workflow detail, and it omits **projects** from the 900px list. `plan.json#sharedDecisions` is the later, authoritative text — S15's scope confirms both halves ("Apply `--container-wide` to the workflow list and workflow detail (projects keeps 900px)"), and S11's confirms settings. Documenting FR3's shorter list would ship a rule that contradicts two P3 stories.

### From `plan.json` – "Canon-first, and canon closes after P1"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> A story that changes a canon-owned rule edits `dev/design-system/` (tokens.css / components.css / icons.css / DESIGN.md / showcase.html) first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` — regenerating the two-line `/* Synced from … sha256: … */` provenance header — within the same story. `dev/tools/fitness/check_design_system_sync.sh` must be green at every story boundary. ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. […] A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced.

This is why TI08–TI10 exist: three canon rules the P3 sweeps discovered are **type and icons**, so they hoist here. See `docs/specs/0.22.1/canon-hoist-manifest.md` for the full hoist table and what each donor story drops.


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#a-canon-changes--the-design-system-itself-is-the-defect-40` – the `global` typography findings (2px band / 8 tiers no classes / no measure rule / dead `--font-sans`), the `tasks` container-max canon gap, `shell/topbar` title tier, `chat-session` markdown headings, `global (observed on projects/workflows)` card-title tier. Read the specific finding before touching the rule it names – each carries measured evidence and a proposed fix.
- `../dartclaw-public/dev/design-system/DESIGN.md#typography` – the eight-tier table and the frontmatter `typography:` block that repeats it as machine-readable values; both must move together.
- `../dartclaw-public/dev/design-system/DESIGN.md#layout` – § Layout prose, the Migration note declaring `.page-inner` app-only and transitional, and the § Layout primitives table the new tiers join.
- `../dartclaw-public/dev/design-system/DESIGN.md#icons` – § Icons: the two usage patterns (`data-icon` attribute vs `.icon.icon-*` class) and the § Icon vocabulary table (`Semantic | Lucide | CSS property | Context`, DESIGN.md:835 onward). TI09 and TI10 each add their own rows; every icon canon ships must appear there.
- `../dartclaw-public/packages/dartclaw_server/test/static/design_system_icons_sync_test.dart` – the strict-sync guard on `icons.css`: it extracts `--icon-*` definitions, `.icon-*` class mappings and `[data-icon="…"]` mappings from the **served** copy and fails if any is absent from the canon copy. Adding to canon first and re-syncing satisfies it; adding to the served copy alone fails it.
- `../dartclaw-public/packages/dartclaw_server/lib/src/templates/task_event_display.dart` – the single source of the task-event mask names. `eventIconClass` (`:6-20`) plus `_statusChangedIconClass` (`:83-89`) return the `icon-*` names TI10 must back; `compactEventIconClass` (`:48-62`) returns `task-event-icon-*` **colour** classes and is not an icon source at all.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – server setup, viewport table, and the `evaluate_script` recipe for reading computed token values; the per-story visual gate runs against the `visual` profile on port 3338 (`../dartclaw-public/dev/testing/profiles/visual/README.md`), the only profile that renders all 23 surfaces.
- `docs/wireframes/deviations.md` – where an intentional divergence from a wireframe is recorded if the re-scale forces one.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI02,TI13] A named tier is applied as one class, not four declarations**
  - **Given** canon `components.css` carries the composite type layer and `showcase.html` applies `class="t-heading"` to a section-heading specimen with no other typographic declarations (no app template consumes `.t-*` until the P3 surface stories)
  - **When** `showcase.html` is opened directly in the browser
  - **Then** computed style on that element is `font-size: 18px`, `font-weight: 600`, `line-height: 23.4px` (1.3) and `letter-spacing: -0.02em` – all four inherited from the single class

- [ ] **S02 [OC02] [TI01,TI02,TI13] The ladder steps are perceptible**
  - **Given** the revised `tokens.css` and the seven composite classes
  - **When** `.t-caption`, `.t-body`, `.t-heading`, `.t-page-title`, `.t-display` and `.t-metric` are rendered side by side in `showcase.html`
  - **Then** their computed font-sizes are 12px, 14px, 18px, 20px, 24px and 32px – no two adjacent tiers closer than 2px, and no tier resolves to 13px

- [ ] **S03 [OC02,OC04] [TI01] An un-migrated `--text-sm` call site still renders at a real size**
  - **Given** `app.css` still contains 79 `var(--text-sm)` references and canon `components.css` its remaining ones (the card-header rules TI03 re-tiers excepted), none of them otherwise migrated by this story
  - **When** any surface using them renders (e.g. `.data-table` rows, sidebar items, banners)
  - **Then** the computed font-size is 14px (the alias resolving to `--text-base`), text is neither unstyled nor missing, and both themes still pass WCAG AA on those runs

- [ ] **S04 [OC03] [TI06,TI07] A data-dense surface uses the width of the screen and its canon-governed headers hold one line**
  - **Given** the scheduling page inner column carries the `--wide` modifier and the browser is at 1440px – scheduling's `.data-table` is canon-governed, unlike tasks', which `app.css#.task-status-group .data-table th` overrides (see Constraints & Gotchas)
  - **When** the scheduled-task table renders
  - **Then** no column header wraps mid-word, and the inner column computes `max-width: 1280px` and renders wider than 900px – ~1130px at 1440px (1440 − 260px sidebar − 48px content padding); the 1280px ceiling itself only binds at viewports ≥ ~1588px

- [ ] **S05 [OC03] [TI06] The wide tier is opt-in – an unmodified container keeps the 900px measure**
  - **Given** a prose surface whose inner column carries `.content-inner` (or `.page-inner`) with no `--wide` modifier
  - **When** it renders at 1440px
  - **Then** its computed `max-width` is still 900px, running-prose blocks inside `.msg-content` are constrained to `var(--measure)` (~605px at the 14px mono advance) rather than the 868px the audit measured, and `.msg-content pre` / `.msg-content table` still span the full bubble width – a code block that fit without horizontal scrolling before still does

- [ ] **S06 [OC02] [TI04] Generated markdown keeps its heading structure**
  - **Given** an agent message whose rendered markdown contains `h1` through `h6`
  - **When** it renders inside `.msg-content`
  - **Then** `h1` computes to 20px/600, `h2` to 18px/600, `h3` to 14px/600 and `h4`–`h6` to 14px/500 in `--fg-sub1` – three distinct steps instead of one, and no level falls through to the UA default that rendered `h6` at ~9px

- [ ] **S07 [OC02] [TI03,TI05] Card titles and the topbar title sit above body size**
  - **Given** the re-tiered `.card-header` / `.card-header-gradient` rules and the topbar title rules, re-synced to the served CSS
  - **When** the projects surface renders in the `visual` profile
  - **Then** a `.card-header` computes 18px/600 with `line-height` 23.4px (1.3) – no longer 13px – and the topbar page title computes 20px/600, both above the 14px body tier

- [ ] **S08 [OC05] [TI09,TI10] Every mask name the app already emits resolves to a glyph**
  - **Given** canon `icons.css` carries the four added tokens and their `.icon-*` mappings, plus the `[data-icon="check"]` / `[data-icon="circle-x"]` attribute rules, and `showcase.html` demonstrates each new name in its § Icons gallery
  - **When** `showcase.html` is opened directly in the browser (it links canon `icons.css` relatively – no re-sync needed) and each new specimen is inspected
  - **Then** `getComputedStyle(el).maskImage` is a `url(...)` value, not `none`, for `.icon-file-json`, `.icon-file-warning`, `.icon-layers` and `.icon-chevron-up` – today an unmapped `.icon-*` name leaves the base `.icon` rule's `background-color: currentColor` painting a solid 1em square, which is the blank square the audit reports

- [ ] **S09 [OC05] [TI08] A server-composed task prompt keeps its line structure**
  - **Given** canon `components.css` scopes `white-space: pre-wrap` to `.msg-user .msg-content p`, re-synced to the served copy
  - **When** `/tasks/43333333-3333-4333-8333-000000000005` ("code-review — Publish Summary") renders in the `visual` profile – the audit's own evidence case, whose seeded user message is `## Task: code-review — Publish Summary\n\nPublish a concise summary…`
  - **Then** the `## Task:` line and the body sentence occupy separate lines with the blank line between them preserved, instead of running together on one line; the assistant messages in the same thread are unchanged (the selector does not reach `.msg-assistant`), and no free-text chat message is parsed as markdown


## Structural Criteria

- [ ] `bash dev/tools/fitness/check_design_system_sync.sh` exits 0: served `tokens.css`, `design-system.css` **and `icons.css`** are byte-identical to canon `tokens.css` / `components.css` / `icons.css` from line 3 onward, with a regenerated two-line `/* Synced from … sha256: … */` provenance header whose hash matches the source.
- [ ] `dart test packages/dartclaw_server/test/static/design_system_icons_sync_test.dart` passes: every `--icon-*`, `.icon-*` and `[data-icon="…"]` in the served copy is present in canon.
- [ ] DESIGN.md § Typography has exactly seven tier rows, one per shipped composite class, with no `body-sm` row; the frontmatter `typography:` block matches it (no `body-sm` key, `heading-md.fontSize: 18px`, `heading-md.letterSpacing: -0.02em`).
- [ ] DESIGN.md § Layout primitives documents `container-wide` and `measure` beside `container-max`, and states which surface classes take the wide tier and which keep 900px – matching `plan.json#sharedDecisions` "Wide-container assignment" exactly, including workflow **detail** on the wide list and **projects** on the 900px list.
- [ ] DESIGN.md § Icon vocabulary has a row for every `--icon-*` canon defines, including the four TI09/TI10 add, and the `check` / `circle-x` rows name their new `data-icon` semantic instead of `—`.
- [ ] `--font-sans` is settled: zero references remain in canon or served CSS/HTML/JS, and DESIGN.md § Typography states the mono-only decision explicitly.
- [ ] `showcase.html` demonstrates all seven composite classes and both container tiers, and its § Icons gallery carries a specimen for every name TI09/TI10 add; the seven bare inline `font-size:` rows in its type-scale block are gone.
- [ ] No new `var(--text-sm)` reference is introduced by this story, and no new `--text-*` size token is added beyond `--container-wide` / `--measure`.
- [ ] `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` is unmodified – S14 owns the single end-of-release regeneration.
- [ ] WCAG AA text contrast holds in both themes on every surface whose text re-scaled.


## Scope & Boundaries

### Work Areas
- `dev/design-system/tokens.css` – `--text-sm` alias, `--text-lg` 16→18px, `--container-wide`, `--measure`, `--font-sans` removal
- `dev/design-system/components.css` – the `.t-*` composite layer, `.card-header` / `--sm`, `.msg-content` heading split + prose-scoped measure, `.msg-user .msg-content p` line structure, `.topbar` title tier, `.content-inner--wide`, `.data-table th` nowrap
- `dev/design-system/icons.css` – four `--icon-*` tokens with their `.icon-*` mappings, two `[data-icon]` attribute mappings (hoisted per `canon-hoist-manifest.md`)
- `dev/design-system/DESIGN.md` – frontmatter `typography:` block, § Typography table and prose, § Layout primitives table, § Icon vocabulary rows
- `dev/design-system/showcase.html` – type-tier panel rebuilt on the composite classes, container-tier panel added, § Icons gallery specimens for the new names
- `packages/dartclaw_server/lib/src/static/tokens.css` + `design-system.css` + `icons.css` – re-synced copies with regenerated provenance headers
- `packages/dartclaw_server/lib/src/static/app.css` – the `.page-inner--wide` modifier only (mirrors the canonical `.content-inner--wide`)

### What We're NOT Doing
- Migrating `app.css` / `design-system.css` `--text-sm` call sites onto `.t-*` and deleting the alias – story S07 owns migration and removal; the alias is precisely what keeps the app building until then.
- Per-page assignment of `.content-inner--wide` / `.page-inner--wide` – the modifier ships opt-in here; the P3 surface stories apply it per the plan's fixed wide-container assignment.
- Deleting the dead `.session-title-static` block at `app.css:278-287` – an `app.css` call-site change the story excludes, and inert either way since canon's `.topbar .session-title-static` wins on specificity (0,2,0 vs 0,1,0). Belongs to the shell sweep.
- Adding an eighth type tier (a `card-title` row and token) – the seven composite classes are fixed by the plan and 16px has no token after `--text-lg` moves to 18px; `.card-header` adopts the heading tier and `.card-header--sm` covers the dense list case.
- Applying `--measure` to app-local prose surfaces (`.knowledge-result-snippet`, `.page-subtitle`) – per-surface adoption owned by P3. Only canon-owned `.msg-content` prose is constrained here, so the token is not born dead.
- Removing the tasks-table overrides that defeat the canon nowrap rule (`app.css#.task-status-group .data-table th`, plus its `table-layout: fixed` percentage column widths) – an `app.css` per-surface change outside this story's work areas. The P3 tasks story already claims that outcome in its scope ("the nowrap table headers that end the `PROVID/ER` / `CREATE/D` / `TO/KE/NS` mid-word wrapping"); this story ships the canon rule the removal will uncover. **PRD FR3's "no table header wraps mid-word at any viewport ≥ 1024px" therefore closes in P3, not here.**
- Applying `.card-header--sm` to the ~21 template card headers that want the dense tier – a template change P3 owns (settings carries 13 of them). Accepted interim: those headers jump 13→18px with the rest until the P3 surface stories opt them down.
- Any app-side work behind the hoisted icon rules. This story ships the canon glyphs and nothing else: S08 owns making the compact task-event path carry a mask class alongside its existing colour class (`task_event_display.dart`, `tasks.dart`, `tasks.html`, `task_sse_routes.dart`, `dc_tasks_controller.js`), retiring `compactEventIconChar`, and binding `scheduling.html`'s toggle to `check` / `circle-x`; S15 owns whatever the workflows step toggle needs beyond the chevron existing (today `dc_workflows_controller.js` already toggles the class, so no S15 edit is required for it to start painting). Shipping the canon rule is the whole of this story's obligation – **the app-side outcomes those stories claim do not close here.**
- Regenerating `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart`. This story re-syncs three served static files, all of which drift the generated bundle; per `plan.json#executionNotes` S14 regenerates it exactly once at release close, and no other story asserts a clean diff on it.
- Adding a `[data-icon="chevron-up"]` attribute mapping. No consumer uses it (`rg -n 'data-icon="chevron-up"' packages/ dev/` returns nothing today); the two call sites toggle the `.icon-chevron-up` class. The class mapping is what TI09 ships.


## Architecture Decision

**Approach**: Land the whole type-and-layout revision in canon (`tokens.css` / `components.css` / `icons.css` / `DESIGN.md` / `showcase.html`) and re-sync the served copies in the same story; alias `--text-sm` to `--text-base` rather than deleting it, so the 96 remaining call sites keep resolving (TI03 re-tiers the two card-header sites to the heading tier) while story S07 migrates them.
**Why this over alternatives**: a full modular re-scale has a far larger blast radius for marginal gain (12/20/24/32 are already sound steps – only the bottom cluster is the defect), and deleting `--text-sm` now would strand every unmigrated consumer mid-milestone.


## Technical Overview

Two families of change share one story because they are coupled: 900px yields ~103 characters per line at the 14px body tier, ~40% over a comfortable measure, so the container tier and the type tier cannot be settled independently. The type work is three layers – token values (`tokens.css`), the composite `.t-*` classes that bind four properties per tier (`components.css`), and the DESIGN.md table plus its machine-readable frontmatter that declares which tiers exist. All three must agree; the frontmatter is the one most easily forgotten. The layout work splits across an ownership boundary: `.content-inner` is canon, `.page-inner` is app-local and declared transitional by DESIGN.md § Layout, so the canonical modifier ships in `components.css` and its app-local mirror in `app.css`.

Three further canon rules arrive by hoist (TI08–TI10) because canon closes after P1 and the P3 sweeps that found them may not open it. They are small and independent of the type-and-measure work, but they widen the story's canon footprint to a third drift-checked file, `icons.css`, which carries its own strict-sync test on top of the byte-identity check.


## Code Patterns & External References

```
# type | path#anchor or url                                          | why needed (intent)
file   | dev/design-system/components.css#.card-metric .metric-value | The one composite tier canon already ships – copy its four-property binding shape for the new .t-* classes
file   | dev/design-system/components.css#.content-inner             | Canonical container rule the --wide modifier extends
file   | dev/design-system/components.css#.data-table th             | Where white-space: nowrap lands; note it already carries --text-xs + tracking-caps
file   | dev/design-system/components.css#.msg-content h1            | The collapsed h1/h2/h3 rule to split into distinct steps
file   | dev/design-system/components.css#.msg-user                  | components.css:443 — the canon-owned user-message rule TI08's line-structure selector qualifies (its `p` half is :476)
file   | dev/design-system/icons.css#.icon                           | The base rule (:176-190) — it sets no mask-image, so an unmapped .icon-* name paints a solid currentColor square
file   | dev/design-system/icons.css#icon-chevron-down               | Token at :54, class mapping at :226, attribute mapping at :295 — the three-place idiom TI09/TI10 follow
file   | packages/dartclaw_server/lib/src/templates/task_event_display.dart#eventIconClass | The ONLY source of task-event mask names (:6-20 + :83-89); compactEventIconClass at :48-62 returns colour classes, not icons
file   | packages/dartclaw_server/lib/src/static/controllers/dc_workflows_controller.js | :561 and :576 toggle icon-chevron-up — the two consumers of the icon canon lacks
file   | packages/dartclaw_server/test/static/design_system_icons_sync_test.dart | The served-⊆-canon guard on icons.css, on top of the byte-identity drift check
file   | dev/design-system/components.css#.topbar .session-title-static | Topbar title rule to raise to the page-title tier (and its .session-title sibling)
file   | packages/dartclaw_server/lib/src/static/app.css#.page-inner | App-local container family the --wide modifier mirrors (app.css:600)
file   | packages/dartclaw_server/lib/src/static/tokens.css          | First two lines are the provenance header shape to regenerate
file   | dev/tools/fitness/check_design_system_sync.sh#check         | The byte-identity + sha256 contract: hash of source must equal line 2 of served, body starts at line 3
wire   | dev/design-system/showcase.html                             | Type-scale block (lines 208-217) is seven bare inline font-size rows to replace
```


## Constraints & Gotchas

- **Critical**: the alias is a live re-scale, not a no-op – `--text-sm: var(--text-base)` moves the 79 `app.css` and 17 remaining canon `components.css` call sites from 13px to 14px at once (the other two canon sites, `.card-header` / `.card-header-gradient`, are re-tiered to 18px by TI03). Must handle by: re-validating the dense surfaces those sites drive (data tables, sidebar items, banners, card bodies) in both themes at desktop and 768px before declaring done.
- **Critical**: `--text-lg` 16→18px moves every existing consumer with it (5 canon sites plus app consumers). This is the intended blast radius of the story, not a regression – but it lands at the same time as the alias, so a surface can shift on two axes at once.
- **Constraint**: the drift check compares the sha256 recorded in line 2 of each served file *and* diffs the body from line 3. Workaround: regenerate both header lines from the source hash after every canon edit; editing one and not the other fails CI just as hard as a body divergence.
- **Avoid**: putting `.page-inner--wide` in canon `components.css` – that would formalize a family DESIGN.md § Layout explicitly calls transitional. Instead: the canonical modifier is `.content-inner--wide` in `components.css`; `.page-inner--wide` mirrors it in `app.css`, which the drift check does not govern.
- **Avoid**: letting the `--text-sm` alias decide `.card-header`'s size by accident – it would drift to 14px on its own, which is still below the heading tier the story calls for. Instead: set `.card-header` explicitly to the heading tier values.
- **Critical**: a canon-only rule change can be silently dead – `app.css` loads after `design-system.css` and its page-scoped selectors out-specify canon. The proven case: `app.css:1622-1628` `.task-status-group .data-table th, td { white-space: normal; overflow-wrap: anywhere; word-break: break-word }` (0,3,1) beats canon's `.data-table th` (0,1,1), and `.task-status-group .data-table { table-layout: fixed }` with percentage column widths means nowrap could not widen the 5% TOKENS column even if the override fell. Must handle by: dry-running the cascade on the actual surface before asserting a per-surface outcome, and re-targeting the Verify to a surface the canon rule actually governs when it does not.
- **Constraint**: DESIGN.md § Source-of-truth scope (DESIGN.md:311) claims served files may deliberately extend canon with "compatibility aliases in `tokens.css`", which the byte-identity check forbids. This story's alias lives in *canon* `tokens.css`, so the contradiction is not triggered – leave the prose alone; S14 owns resolving it.
- **Critical**: `task-event-icon-*` is **not** an icon name. `compactEventIconClass` (`task_event_display.dart:48-62`) returns `task-event-icon-status` / `-tool` / `-artifact` / … — app-local *colour* classes that live in `app.css`, carry no mask, and must never gain an `--icon-*` token. The mask names come only from `eventIconClass` (`:6-20`) and `_statusChangedIconClass` (`:83-89`). An implementer who reads the audit's "task-event icons" literally and adds tokens named after the colour classes ships nothing usable and reproduces the exact blank square TI10 exists to remove. Must handle by: deriving the required set mechanically from `eventIconClass`'s string literals (the TI10 Verify does this), never from the surface's class names.
- **Constraint**: `icons.css` carries a second gate beyond byte identity — `packages/dartclaw_server/test/static/design_system_icons_sync_test.dart` extracts `--icon-*`, `.icon-*` and `[data-icon="…"]` from the *served* copy and fails if any is missing from canon. Canon-first plus TI14's re-sync satisfies both; editing the served copy first fails the test even while the drift check would still be reconcilable.
- **Avoid**: `rg -h` in a Verify. In ripgrep `-h` is `--help`, not `--no-filename` — `rg -oh <pattern> <paths>` prints the help text and exits 0, so a `comm`/`diff` built on it silently reports "no differences". This was hit while dry-running TI10. Instead: use `rg -o --no-filename` (or `-I`).
- **Avoid**: verifying an icon by grepping for its token *name*. `rg -n 'icon-file-json' icons.css` matches a `var(--icon-file-json)` usage just as happily as a definition, and matches nothing about whether the mask actually resolves. Instead: check the definition form (`--icon-file-json:` with the trailing colon, the same shape the sync test uses) and confirm `getComputedStyle(el).maskImage !== 'none'` in the browser.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** The type scale carries a perceptible ladder and `--text-sm` is no longer a distinct tier
  - `dev/design-system/tokens.css#--text-sm` becomes `var(--text-base)` with a comment marking it a migration alias; `--text-lg` moves from `1rem` to `1.125rem` (18px); `--text-xs` 12px, `--text-base` 14px, `--text-xl` 20px, `--text-2xl` 24px, `--text-3xl` 32px are unchanged.
  - **Verify**: `rg -n "text-sm|text-lg" dev/design-system/tokens.css` shows `--text-sm: var(--text-base)` and `--text-lg: 1.125rem`; in the browser `getComputedStyle(document.documentElement).getPropertyValue('--text-sm').trim()` resolves to the same computed size as `--text-base` (14px), and a `.data-table` cell measures 14px

- [ ] **TI02** Every named tier has exactly one composite class binding all four properties
  - New numbered section in `dev/design-system/components.css`, placed after the existing component sections (so a deliberately applied tier wins equal-specificity ties – TI15's `.t-caption` escape hatch depends on this) and registered in the file's section index (components.css:5-30); follow `#.card-metric .metric-value` for shape. Every font-size references its token, and line-heights use `var(--leading)` (1.6) / `var(--leading-tight)` (1.3) where those tokens apply: `.t-caption` `var(--text-xs)` (12px)/400/`--leading`, `.t-body` `var(--text-base)` (14px)/400/`--leading`, `.t-label` `var(--text-base)` (14px)/500/`--leading-tight`, `.t-heading` `var(--text-lg)` (18px)/600/`--leading-tight`/`--tracking-tight`, `.t-page-title` `var(--text-xl)` (20px)/600/`--leading-tight`, `.t-display` `var(--text-2xl)` (24px)/600/1.2/`--tracking-tight`, `.t-metric` `var(--text-3xl)` (32px)/600/1.15/`--tracking-tight` (1.2 and 1.15 stay literal – no token exists; mirrors `.card-metric .metric-value`). Each declares `letter-spacing` explicitly (`normal` where the tier declares none) – `.t-caption` included: uppercase micro-labels compose `--tracking-caps` on top of the tier rather than getting a variant class, which is what `.data-table th` already does. Depends on TI01's token values.
  - **Verify**: each of `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric` declares `font-size`, `font-weight`, `line-height` and `letter-spacing`, with no literal-px `font-size` in any `.t-*` rule (`rg -A5 "^\.t-" dev/design-system/components.css | rg "font-size:\s*[0-9]"` → no matches); the section index lists the new section; computed font-sizes in showcase are 12/14/14/18/20/24/32px with weights 400/400/500/600/600/600/600

- [ ] **TI03** Card titles sit on the heading tier, with the dense case opt-in
  - `dev/design-system/components.css#.card-header` and its `.card-header-gradient` sibling (the documented higher-emphasis variant – it must not end up smaller than the standard header) move from `var(--text-sm)` to the `.t-heading` values (`var(--text-lg)` / `var(--weight-bold)` / `var(--leading-tight)` / `var(--tracking-tight)`); add `.card-header--sm` at `var(--text-base)` / `var(--weight-bold)` for dense list rows. It ships with no in-story consumer by design – templates opt in during P3 (see What We're NOT Doing). Consumes TI02's tier values.
  - **Verify**: a `.card` header on the projects surface computes to 18px/600, no longer 13px – above the 14px body it sits on; `.card-header-gradient` matches; `.card-header--sm` computes to 14px/600

- [ ] **TI04** Markdown headings in messages render as distinct steps
  - Split `dev/design-system/components.css#.msg-content h1` (the collapsed `h1, h2, h3` rule) into `h1` `--text-xl`/600/`--leading-tight`, `h2` `--text-lg`/600/`--leading-tight`, `h3` `--text-base`/600, and add `h4, h5, h6` at `--text-base`/500/`--fg-sub1` so no level falls through to UA defaults; give each level explicit margins so the steps differ by space as well as size. The h1→h2 step is 2px because no 16px token survives `--text-lg` moving to 18px – accepted here rather than pushing h1 to 24px (the display tier, reserved for hero moments): margin plus the h2→h3 4px step carry the structure.
  - **Verify**: rendered agent markdown computes `h1` 20px, `h2` 18px, `h3` 14px/600, `h6` 14px/500 – `h6` no longer ~9px

- [ ] **TI05** The topbar page title sits on the page-title tier
  - `dev/design-system/components.css#.topbar .session-title-static` and its `.topbar .session-title` sibling move from `var(--text-base)` to `var(--text-xl)` / `var(--weight-bold)`, matching DESIGN.md's `page-title` tier. Leave the dead `app.css:278-287` duplicate alone (canon wins on specificity; see What We're NOT Doing).
  - **Verify**: the "Settings" title in the topbar computes to 20px/600 – larger than the `.sidebar-header .logo` (18px once TI01 moves `--text-lg`) and no longer the smallest of the three titles on screen

- [ ] **TI06** Canon carries a second container tier and a stated reading measure
  - `dev/design-system/tokens.css` gains `--container-wide: 1280px` and `--measure: 72ch` beside `--container-max`; `dev/design-system/components.css` gains `.content-inner--wide { max-width: var(--container-wide); }` next to `#.content-inner`. The measure binds **running prose only** – `.msg-content > :is(p, ul, ol, blockquote, h1, h2, h3, h4, h5, h6) { max-width: var(--measure); }`, left-aligned in the bubble (no auto-centering) – so `.msg-content pre` (`overflow-x: auto`, components.css:481) and `.msg-content table` (`width: 100%`, :484) keep the full bubble width and gain no horizontal scrolling. The wide modifier is opt-in – `.content-inner` itself is untouched.
  - **Verify**: `.content-inner--wide` computes `max-width: 1280px` and renders wider than 900px at 1440px (~1130px – padding-bound; the 1280px ceiling only binds at viewports ≥ ~1588px) while bare `.content-inner` still computes 900px; a `.msg-content` paragraph computes `max-width` ≈ 605px (72ch at the 14px mono advance), down from the 868px the audit measured, while a sibling `pre` and `table` in the same message compute no `max-width` from `--measure` and render at the bubble width

- [ ] **TI07** Data-table headers hold one line and the app-local container family mirrors the canonical modifier
  - `dev/design-system/components.css#.data-table th` gains `white-space: nowrap`; `packages/dartclaw_server/lib/src/static/app.css` gains `.page-inner--wide { max-width: var(--container-wide); }` beside `.page-inner` (app.css:600) – app-local because `.page-inner` is, per DESIGN.md § Layout's Migration note. Consumes TI06's token. The canon rule governs the scheduling and memory-dashboard tables; the tasks table is overridden app-side and is not this story's to fix (see Constraints & Gotchas and What We're NOT Doing).
  - **Verify**: with the modifier applied to the scheduling page at 1440px, no `.data-table` header wraps mid-word and the header row is one line tall; `rg -n "white-space" dev/design-system/components.css` shows the declaration inside the `.data-table th` rule

- [ ] **TI08** A server-composed user message keeps its line structure *(hoisted from S08 TI16 — `canon-hoist-manifest.md`)*
  - Add `white-space: pre-wrap` scoped to `dev/design-system/components.css#.msg-user .msg-content p`, beside the existing `.msg-content p` rule (`components.css:476`). Task-session "user" messages are server-composed markdown rendered as plain text (`chat.html`'s `userMessage` fragment has no `data-markdown`, unlike `assistantMessage`), so their newlines collapse and the literal `##` shows on one run-on line. `pre-wrap` is the minimum correct fix: it restores the line structure without turning free-text chat input into rendered markdown.
  - **This is canon, not `app.css`.** `.msg-user` (`components.css:443`) and `.msg-content p` (`:476`) are both canon-owned and `app.css` defines neither — `rg -n 'msg-user|msg-content' packages/dartclaw_server/lib/src/static/app.css` returns nothing today. Writing the rule app-side would style a canon component from the app, against the plan's canon-first constraint, even though the byte-identity script would not catch it.
  - Keep the selector qualified by `.msg-user`. Applying `pre-wrap` to `.msg-content p` unqualified would reach the markdown-rendered assistant path, where the source newlines inside a `<p>` are formatting artifacts and would become visible breaks. Independent of TI06's `--measure` rule, which sets `max-width` on the same elements and does not conflict.
  - **Verify**: `rg -n 'msg-user .msg-content p' dev/design-system/components.css` shows the rule and its `white-space: pre-wrap` (dry-run today: no match, `rg` exits 1 and prints nothing — read the exit code, an empty result is not a pass here); the same grep over `packages/dartclaw_server/lib/src/static/app.css` still returns nothing; on `/tasks/43333333-3333-4333-8333-000000000005` in the `visual` profile the `## Task: code-review — Publish Summary` line and the body sentence render on separate lines with the blank line between preserved (dry-run today: they run together on one line — this is the audit's own evidence shot); an assistant message in the same thread renders unchanged and gains no visible breaks; a two-line message typed into `/chat` keeps its break

- [ ] **TI09** The chevron pair is complete *(hoisted from S08 TI05's dry-run — `canon-hoist-manifest.md`)*
  - Add `--icon-chevron-up` to `dev/design-system/icons.css` beside `--icon-chevron-down` (`:54`) and its `.icon-chevron-up` mapping beside `.icon-chevron-down` (`:226`), following the file's three-place idiom and the Lucide `chevron-up` 24×24 stroke SVG as an inline data URI — the vertical mirror of the `chevron-down` path already in the file. Add the matching row to DESIGN.md § Icon vocabulary (`| — | chevron-up | --icon-chevron-up | Expand toggle (expanded state) |`); no `[data-icon]` mapping (see What We're NOT Doing).
  - `dc_workflows_controller.js` already toggles `icon-chevron-up` against `icon-chevron-down` at `:561` (the step-detail toggle) and `:576` (the context viewer). Both targets carry the `.icon` base class — `workflow_detail.html:109` is `<span class="workflow-step-expand-icon icon icon-chevron-down">`, and `app.css#.workflow-step-expand-icon` (`:2576`) adds only a transform transition — so on **expand** the element loses its only mask and the base rule's `background-color: currentColor` paints a solid 1em square. No app-side change is needed or in scope: the icon simply has to exist.
  - **Verify**: `rg -c -e '--icon-chevron-up:' -e '^\.icon-chevron-up\s' dev/design-system/icons.css` returns 2 (dry-run today: no match, exit 1 — and note the check is on the *definition* forms, `--icon-chevron-up:` with its colon and the class mapping at line start, because a bare `chevron-up` grep would also match a `var(--icon-chevron-up)` usage); `rg -n '\`--icon-chevron-up\`' dev/design-system/DESIGN.md` matches; in `showcase.html` (canon-linked, no re-sync needed) the `icon-chevron-up` specimen's `getComputedStyle(el).maskImage` is a `url(...)` and renders as the vertical mirror of the `icon-chevron-down` specimen beside it, not a filled square

- [ ] **TI10** Every task-event mask name resolves, and the two attribute mappings the app already calls exist *(hoisted from S08 TI05 — `canon-hoist-manifest.md`)*
  - **Tokens + class mappings** — `--icon-file-json`, `--icon-file-warning`, `--icon-layers` are returned by `task_event_display.dart#eventIconClass` (`:11-18`) and defined nowhere in canon. Add each token plus its `.icon-*` mapping, Lucide `file-json` / `file-warning` / `layers`, same inline-data-URI idiom.
  - **Attribute mappings only** — `--icon-check` (`icons.css:51`) / `.icon-check` (`:225`) and `--icon-circle-x` (`:63`) / `.icon-circle-x` (`:229`) already exist. What is missing is `[data-icon="check"]` and `[data-icon="circle-x"]`, which is why `scheduling.html:195`'s hardcoded `data-icon="check"` paints a blank square today. Add **only** those two attribute rules in the § UI controls block (`:289` onward); do not re-add the tokens or classes.
  - **Do not add anything named `task-event-icon-*`.** Those are app-local *colour* classes from `compactEventIconClass` — see Constraints & Gotchas. The mask names come from `eventIconClass` and `_statusChangedIconClass` only.
  - Expected interim state, not a regression for TI15 to flag: `scheduling.html:195` hardcodes `data-icon="check"` on every row, so once the mapping exists **every** scheduled task shows a check regardless of its enabled state. That is still strictly better than the square it shows today, and S08 owns binding the attribute to `${task.enabled ? 'check' : 'circle-x'}` — which is why `circle-x` ships here alongside `check` even though nothing calls it yet.
  - Add DESIGN.md § Icon vocabulary rows for `file-json`, `file-warning` and `layers`, and change the existing `check` and `circle-x` rows' Semantic column from `—` to `check` / `circle-x` now that both carry attribute mappings.
  - **Verify**: the required set is derived from source, not from the surface's class names —
    ```
    cd ../dartclaw-public
    rg -o --no-filename -e "'icon-[a-z0-9-]+'" packages/dartclaw_server/lib/src/templates/task_event_display.dart | tr -d "'" | sort -u > /tmp/need
    rg -o --no-filename -e '^\.icon-[a-z0-9-]+' dev/design-system/icons.css | sed 's/^\.//' | sort -u > /tmp/have
    comm -23 /tmp/need /tmp/have   # must print nothing
    ```
    Dry-run today prints exactly `icon-file-json`, `icon-file-warning`, `icon-layers` — the known pre-state, so an empty result afterwards is a real pass. Use `--no-filename`, never `-h`: in ripgrep `-h` is `--help`, and `rg -oh …` prints the help text, which makes `comm` report no differences no matter what. Then: `for n in file-json file-warning layers; do rg -q -e "--icon-$n:" dev/design-system/icons.css || echo "MISSING TOKEN $n"; done` prints nothing; `rg -o '\[data-icon="(check|circle-x)"\]' dev/design-system/icons.css | wc -l` prints `2` (today it prints `0`) — count **occurrences**, not matching lines: `rg -c` would return `1` for a correct implementation that puts both selectors in one comma-separated list on one line; while `rg -c -e '--icon-check:' -e '--icon-circle-x:' dev/design-system/icons.css` still returns 2 — the tokens were not duplicated; `rg -n 'task-event-icon' dev/design-system/` returns no match — no colour class leaked into canon; after TI14's re-sync, the enable/disable toggle in the `/scheduling` list renders a check glyph at the size of its `.btn-icon-sm` siblings instead of the filled square it shows today

- [ ] **TI11** The dead `--font-sans` token is settled
  - Delete `--font-sans` from `dev/design-system/tokens.css` (verified zero references anywhere) and state the mono-only decision explicitly in DESIGN.md § Typography, so the widened scale – not a second family – is where hierarchy comes from.
  - **Verify**: `rg -n "font-sans" -g '*.css' -g '*.html' -g '*.js' dev/design-system` exits 1 immediately after the canon edit; the full sweep `rg -n "font-sans" -g '*.css' -g '*.html' -g '*.js' dev/design-system packages/dartclaw_server/lib/src` exits 1 after TI14's re-sync (the served copy carries the token until then; DESIGN.md may name the removed token – the CSS/HTML/JS globs match the `--font-sans` Structural Criterion's scope); DESIGN.md § Typography contains the explicit mono-only statement

- [ ] **TI12** DESIGN.md documents the revised scale, tiers and layout primitives
  - § Typography table becomes seven rows – `caption` / `body-md` / `label-md` / `heading-md` / `page-title` / `display` / `metric-value` – each naming its `.t-*` class, with the `body-sm` row deleted and `heading-md` at "18px / 600, tight tracking" (matching the display/metric row convention); the frontmatter `typography:` block moves with it (drop `body-sm`, set `heading-md.fontSize: 18px`, add `heading-md.letterSpacing: -0.02em` to match `.t-heading`). The remaining `body-sm` references move too: the five frontmatter component blocks referencing `{typography.body-sm}` (card, tool-call, approval-card, run-card, notif-item) re-point to `{typography.body-md}`, and the § Cards table's `.card-body` row moves from `body-sm` to `body-md` – consistent with the alias re-scale. § Typography's Tracking bullet widens to name the heading tier alongside display/metric for `-0.02em`; the `label-md` row's usage note drops "session titles" (TI05 moves the topbar session title to the page-title tier); § Typography notes that `--text-sm` survives in `tokens.css` only as a migration alias of `--text-base` – not a tier, not for new use, removed once migration completes. § Typography states the `--measure` rule – running prose constrains to it; code blocks, tables and other non-prose blocks do not – and states that uppercase micro-labels compose `--tracking-caps` on top of `.t-caption` rather than getting their own tier (the caption row's usage note keeps timestamps and metadata, and names the composition for role labels, pill text and table headers). § Layout primitives gains `container-wide` 1280px and `measure` 72ch rows plus the assignment rule, transcribed from `plan.json#sharedDecisions` "Wide-container assignment" and **not** from PRD FR3's coarser list — wide: tasks, task detail, health dashboard + audit, memory, scheduling, the workflow **list and workflow detail**; 900px: chat, session info, knowledge results, settings forms, **and projects** — with the opt-in rule stated ("a surface not on the wide list keeps 900px unless the sweep documents a deviation"); the frontmatter `spacing:` block gains `container-wide: 1280px` and `measure: 72ch` beside `container-max`. § Icon vocabulary is **not** this task's — TI09 and TI10 each write their own rows.
  - **Verify**: every one of the seven tier rows names both its tier and its backing class — `for t in caption body-md label-md heading-md page-title display metric-value; do rg -q -e "^\| \`$t\`.*\`\.t-" dev/design-system/DESIGN.md || echo "ROW MISSING CLASS: $t"; done` prints nothing (dry-run today prints all seven: the table has no class column at all, so the plain row-count form `rg -c "^\| \`(caption|…)\`"` already returns 7 against the *unmodified* file and proves nothing); `rg -n "body-sm" dev/design-system/DESIGN.md` returns no matches (dry-run today: 8 matching lines — the frontmatter `body-sm:` key, the § Typography table row, the five frontmatter component blocks, the § Cards `.card-body` row); `rg -n "container-wide|measure" dev/design-system/DESIGN.md` shows both rows in the § Layout primitives table; the assignment sentence names `workflow detail` and `projects` — `rg -n "workflow detail" dev/design-system/DESIGN.md` and `rg -n "projects" dev/design-system/DESIGN.md` both match inside the § Layout primitives assignment prose, and a manual diff of that sentence against `plan.json#sharedDecisions` "Wide-container assignment" shows the same surfaces on the same side

- [ ] **TI13** showcase.html demonstrates every tier, both container tiers and the new glyphs
  - Rebuild the type-scale block (`showcase.html:208-217`) on the composite classes instead of seven bare inline `font-size:` spans, one panel per tier labelled with its DESIGN.md tier name; add a panel demonstrating `.content-inner` vs `.content-inner--wide` and the `--measure` constraint on running prose – annotated with the tier widths, stacked or scaled, since the showcase's own 1100px `.showcase` wrap cannot render 1280px at 1:1. Add the four TI09/TI10 names to the § Icons inline gallery (`showcase.html:963` onward) following the one-line `<span class="icon icon-X"></span><span class="text-xs">X</span>` specimen shape, in the gallery's alphabetical order, and correct the gallery's intro count (`showcase.html:960` says "39 Lucide icons" – already stale, the file defines 45 `.icon-*` mappings today; set it to the post-edit value of `rg -c -e '^\.icon-[a-z0-9-]+\s' dev/design-system/icons.css`). `showcase.html` is not drift-checked, so no re-sync follows. Consumes TI02, TI06, TI09 and TI10.
  - **Verify**: showcase renders one labelled specimen per `.t-*` class with no inline `font-size:var(--text-*)` left in the type-scale block; the container panel demonstrates both tiers with labelled 900px / 1280px values (annotated or scaled – not a literal 1:1 side-by-side); the gallery's stated count equals `rg -c -e '^\.icon-[a-z0-9-]+\s' dev/design-system/icons.css` (dry-run today: prose says 39, command says 45 – they must agree afterwards); each of `icon-file-json`, `icon-file-warning`, `icon-layers`, `icon-chevron-up` has a gallery specimen whose `getComputedStyle(el).maskImage` is a `url(...)`, not `none`

- [ ] **TI14** The served CSS is byte-identical to canon with regenerated provenance
  - Copy canon `tokens.css` → `packages/dartclaw_server/lib/src/static/tokens.css`, canon `components.css` → `packages/dartclaw_server/lib/src/static/design-system.css`, and canon `icons.css` → `packages/dartclaw_server/lib/src/static/icons.css`, each prefixed by the regenerated two-line `/* Synced from <source> on <YYYY-MM-DD>.\n   sha256: <sha256 of source> */` header. All three files are in scope – `icons.css` because TI09 and TI10 edit it. Do **not** run `dart run dev/tools/embed_assets.dart`; S14 owns that regeneration exclusively.
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0 (it checks all three pairs; dry-run today exits 0, so re-run it *after* the canon edits and before the copy to confirm it goes red first – a check that was already green proves nothing about the re-sync); `dart test packages/dartclaw_server/test/static/design_system_icons_sync_test.dart` passes; `git status --porcelain packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` prints nothing – the generated bundle was not regenerated here

- [ ] **TI15** Both themes hold at desktop and 768px after the re-scale
  - Validate against the `visual` profile (`bash dev/testing/profiles/visual/run.sh`, port 3338) in both themes at desktop (1440×900 – matching the audit baseline capture; this overrides the visual-validation guideline's 1280px default) and 768px, comparing against the audit's 92-screenshot baseline; re-check WCAG AA text contrast on every text run whose size changed (13→14px alias sites, 16→18px `--text-lg` sites – enumerate the app side with `rg -n "var\(--text-lg\)" packages/dartclaw_server/lib/src/static/app.css`, 12 sites including `.login-input`'s `max(16px, var(--text-lg))` iOS-zoom guard, which becomes a constant 18px (inert; leave to the shell sweep) – card headers, topbar title, markdown headings). Per the PRD's edge-case table, a dense table that overflows at 14px gets its column geometry adjusted or uses `.t-caption` deliberately, recorded as a deviation – never a silent revert to 13px. Both remedies sit outside this story's work areas (column geometry is app-local, `.t-caption` application is a P3 template edit), so when the edge case triggers, this story *records* it and hands it to the owning P3 surface story – TI15's gate is that the overflow is recorded, not resolved here.
  - **Verify**: no surface regresses against the baseline in either theme at either viewport – text-size deltas are the intended change; regression means clipping, overflow, overlap, truncation, contrast loss, or layout break; every re-scaled text run measures ≥ 4.5:1 against its background in both themes; any deliberate `.t-caption` usage or triggered dense-table overflow is recorded in this FIS's Implementation Observations block for orchestrator transfer to `docs/wireframes/deviations.md` (private repo – not writable from the public-repo bundle)

### Testing Strategy

_This story ships no Dart code and no behavioral logic, so the per-task Verify lines plus the visual gate in TI15 are the proof contract. The one existing test in scope is `packages/dartclaw_server/test/static/design_system_icons_sync_test.dart`, which TI09/TI10 bring into play: run it after TI14's re-sync. It is not modified._

### Validation

- TI15 is the story's gate, not optional polish: the plan makes both-theme visual validation at desktop + 768px a per-story requirement, and this story re-scales text on every surface at once.
- The icons work has two independent gates that must both be green: the byte-identity drift check (canon vs served) and the served-⊆-canon sync test. Passing one does not imply the other.

### Execution Contract

- TI01 must complete before TI02–TI07: they all consume the revised token values. TI08–TI10 are independent of the token values and may run at any point before TI14.
- TI14 (re-sync) must run after every canon edit is final – a partial re-sync leaves CI red for every downstream story. It now covers three files, not two: TI09 and TI10 edit `icons.css`.
- TI13 consumes TI09 and TI10 (it adds their specimens to the showcase gallery and restates the icon count), so it runs after both.
- Two browser contexts, two file sets: showcase-based Verifies (S01, S02, S08, TI02, TI09, TI13) open `dev/design-system/showcase.html` directly – it links canon `tokens.css`, `components.css` *and* `icons.css` relatively, so no re-sync is needed. Profile-based Verifies (S09, TI01, TI03–TI08, TI10's toggle check, TI15) read the *served* copies under `packages/dartclaw_server/lib/src/static/` – run TI14's copy step as a scratch re-sync first; the final TI14 pass (regenerated provenance, drift check green) is the authoritative one.


## Final Validation Checklist

- [ ] `git diff HEAD -- dev/design-system packages/dartclaw_server/lib/src/static | rg '^\+.*var\(--text-sm\)'` produces no output (run before the story's commit; diff against the story's base ref afterwards) – no new `var(--text-sm)` usage introduced by this story (existing canon usages remain untouched – story S07 migrates them).
- [ ] No new `--text-*` size token was added; only `--container-wide` and `--measure` are new tokens.
- [ ] `git diff --stat <story-start-commit> -- dev/design-system/` shows exactly five changed canon files – `tokens.css`, `components.css`, `icons.css`, `DESIGN.md`, `showcase.html` – and the `icons.css` diff is additive only: `git diff <story-start-commit> -- dev/design-system/icons.css | rg '^-[^-]'` produces no output. Diff against this story's start commit, not `main`; S01 changes canon earlier in the same branch.
- [ ] The three hoisted rules are present and no more: `components.css` gained the `.msg-user .msg-content p` rule, `icons.css` gained four `--icon-*` tokens with their `.icon-*` mappings and exactly two `[data-icon]` mappings, and nothing else hoisted from another story's list landed here (`canon-hoist-manifest.md` routes surfaces/chrome to S01 and form/control/tab/state to S03).


## Implementation Observations

_No observations recorded yet._
