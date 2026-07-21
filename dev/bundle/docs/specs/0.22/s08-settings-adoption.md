# Settings Adoption

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S08

## Feature Overview and Goal

**Intent**: The settings page is the app's largest template and its worst design-system offender — the only template carrying a local `<style>` block, with a bespoke `summary-stat` re-implementation of the canonical metric card — so bringing it to "good" compliance is what finally lets the app claim zero template-local CSS.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] The settings page renders correctly with **no** template-local `<style>` block; its surviving app-specific rules live in `static/app.css`, and no template app-wide carries a `<style>` block.
- [OC02] The provider summary stats (Configured / Healthy / Degraded) render as canonical `.card.card-metric` with `.metric-value`/`.metric-label`, not the bespoke `summary-stat` re-implementation.
- [OC03] Settings CSS uses canonical `--tracking-*` tokens for uppercase-label letter-spacing (no hardcoded `letter-spacing` remains), and its provider icons/badges draw from the provider-brand token group, never semantic `--info`.
- [OC04] The settings page uses the canonical `.content-area`/`.content-inner` layout-container family and renders correctly in both themes at desktop + 768px.


## Required Context

### From `prd.md` — "FR5: Per-page component adoption"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr5-per-page-component-adoption -->
<!-- extracted: 7d948b65 -->
> **Description**: Bring every page to "good" compliance by composing canonical primitives: glass (`.card-glass`) for overlays above live content (toasts, dialogs, composer palettes), `kbd` for shortcut hints, identicons for entity identity (sessions, channels, task agent badges — never state), terminal frames for diff/raw/step-output views, and `metric-value`/`display` type for KPIs/headers. Clear the violations inventory: purge inline styles into classes/utilities, delete the `settings.html` `<style>` block, collapse the three parallel layout-container families into the canonical one, fix non-token hovers, and convert `display:none` toggles to the `hidden` attribute.
>
> **Acceptance Criteria**:
> - Page-by-page compliance table (audit §5) reads "good" for all pages.
> - ≤5 justified inline `style` attributes remain app-wide; no template-local `<style>` block remains.
> - Each page passes visual validation in both themes (desktop + 768px) before its work is considered done.

### From `audit-design-system-compliance.md` — settings findings (§3 template hygiene)
<!-- source: dev/bundle/docs/specs/0.22/audit-design-system-compliance.md#3-violations-inventory -->
<!-- extracted: 7d948b65 -->
> **Template-local `<style>` block**: `settings.html:13-53+` — only template with one; `.summary-stat` inside it re-implements `card-metric` with smaller type (16px vs the 32px metric standard).
>
> `.summary-stat/.summary-value/.summary-label` (`settings.html` `<style>` block) → canonical `.card.card-metric` + `.metric-value/.metric-label`.
>
> Settings compliance = **Poor**. Top fixes: 1. delete `<style>` block; 2. `summary-stat` → `card-metric`; 3. tracking tokens + kbd in help text.

### From `prd.md` — "Constraints" (Binding: NFR-constraints)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### From `prd.md` — "Constraints" (Binding: NFR-constraints)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.

### From `prd.md` — "Constraints" (Binding: NFR-constraints)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.


## Deeper Context

- `plan.json#sharedDecisions` — the **CSS layering & sync contract** (S08 adds/edits app CSS only in `static/app.css`; never touches the synced `design-system.css`/`tokens.css`) and the **layout-container-family collapse** (canonical `.content-area/.content-inner` arrived with the S01 sync; each per-page story migrates its own page; a family's `app.css` rules are deleted only by the story that removes its last consumer).
- `dev/bundle/docs/specs/0.22/s01-css-foundation.md` — S01 established `static/{design-system.css, app.css, app-tokens.css}`, the provider-brand tokens `--brand-claude`/`--brand-codex`, and the drift check. Read for the file layout and token names S08 consumes.
- `dev/design-system/components.css#card-metric` / `#content-area` / `#kbd` — canonical definitions of the primitives S08 adopts (available via the synced `design-system.css`).


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01,TI02,TI07] Settings renders with no template-local `<style>` block**
  - **Given** the settings page after S08, with its surviving provider-section rules relocated into `static/app.css`
  - **When** the settings page is rendered and viewed in the browser
  - **Then** `settings.html` contains no `<style>` element, and the provider section (summary + provider cards) is still fully styled — identical layout/spacing to before — because the rules now load from `app.css`

- [x] **S02 [OC02] [TI03] Provider summary stats are canonical metric cards**
  - **Given** a config with, e.g., 2 configured / 1 healthy / 1 degraded providers
  - **When** the Providers tab renders the summary grid
  - **Then** each stat is a `.card.card-metric` element with a `.metric-value` (the count) and a `.metric-label` (Configured / Healthy / Degraded), carrying the semantic-modifier convention – Configured → `.card-metric--info`, Healthy → `.card-metric--accent`, Degraded → `.card-metric--warning` (per the `metric-color-convention` decision note) – and no `.summary-stat`/`.summary-value`/`.summary-label` markup or CSS remains

- [x] **S03 [OC03] [TI04,TI02] Settings CSS is token-clean**
  - **Given** the relocated settings rules in `static/app.css`
  - **When** `app.css` is grepped for the settings provider rules
  - **Then** every uppercase-label `letter-spacing` uses `var(--tracking-caps)` (no hardcoded `0.04em`/`0.06em` remains), and `.provider-icon-codex` resolves its colour from `--brand-codex` (not `var(--info)`) while `.provider-icon-claude` uses `--brand-claude`

- [x] **S04 [OC04] [TI06] Settings uses the canonical layout container and passes both-theme validation**
  - **Given** the settings page migrated to `.content-area`/`.content-inner`
  - **When** it is visually validated at desktop and 768px in both Mocha (dark) and Latte (light) themes
  - **Then** the main scroll container is `.content-area > .content-inner` (no `.page-content`/`.page-inner` on this page), the provider-summary grid collapses from 3 columns to 1 at ≤768px, vertical spacing between the stacked settings cards is preserved by the upstream `.content-inner` gap (`flex-column` + `gap: var(--sp-6)` from S01's canon work – no settings-local compensating rule is added; per the `content-inner-stack-gap` decision note), and no visual regression is observed in either theme (the visual gate confirms spacing parity in both Mocha and Latte)

- [x] **S05 [OC01] [TI01,TI06] Synced foundation is untouched (sync-contract regression)**
  - **Given** S08's edits are confined to `settings.html` and `static/app.css`
  - **When** the design-system drift check runs after S08
  - **Then** it exits zero (`static/design-system.css` and `static/tokens.css` are byte-unchanged), and the still-shared `.page-content`/`.page-inner` app.css rules remain present for the other pages that still consume them


## Structural Criteria

- [x] No template under `packages/dartclaw_server/lib/src/templates/` contains a `<style>` element after this story (app-wide claim) — proved by TI01 Verify.
- [x] Any keyboard-key reference in settings help/hint copy is wrapped in `<kbd>`/`.kbd`; model shorthands (e.g. `claude/opus`) stay in `<code>` — proved by TI05 Verify.
- [x] `embedded_assets.g.dart` is regenerated so the edited `settings.html` and `static/app.css` are served in embedded mode — proved by TI07 Verify.
- [x] Existing settings behaviour (tab switching, form rendering, provider-summary counts) is unchanged — proved by the template/route test suite passing.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/templates/settings.html` — delete the `<style>` block (lines ~13–360), convert `summary-stat` markup to `card-metric`, migrate `.page-content`/`.page-inner` → `.content-area`/`.content-inner`, apply `<kbd>` where copy references a key.
- `packages/dartclaw_server/lib/src/static/app.css` — receive the surviving provider-section rules (provider-summary grid, provider-card, provider-icon-*, provider-title/subtitle, etc.), retargeted to provider-brand + tracking tokens; delete the `summary-stat` rules (replaced by canonical `card-metric`).
- `packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` — update its two literal `document.querySelector('.page-content')` sites (lines ~27 and ~354) to `.content-area` as part of the container migration; the line-354 lookup gates `attachSettingsListeners()`' entire delegated wiring, so leaving either on the old selector silently breaks Save/Cancel/immediate-apply.
- `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` — regenerated after the template + static-asset edits.
- Visual validation: settings page, both themes, desktop + 768px (the per-story gate).

### What We're NOT Doing
- Inventing keyboard shortcuts for settings -- settings copy has no keyboard-key references today (only `<code>` model shorthands); adding new shortcuts is out of scope (no new UX). The kbd adoption is opportunistic markup of existing key references, of which there are currently none. *(Scope-narrowing note for plan cross-cutting review: kbd adoption is bounded to marking up existing key references, and settings copy has none, so this task adds no markup – no new UX surface is introduced.)*
- Deleting the `.page-content`/`.page-inner` `app.css` rules -- 11 other templates still consume them; per the layout-container shared decision, the last-consumer story removes the family rules, not this one.
- Fixing the shared `.provider-badge-*` CSS-file rules -- S01 already retargeted those to the provider-brand tokens; S08 only handles the settings-template-local `.provider-icon-*` rules it relocates.
- Feedback primitives / meters / skeletons -- settings has no determinate progress or loaders (S03 owns those app-wide); nothing to adopt here.
- Serving/embedding new binary assets or brand marks -- S11/S12 own the mascot/favicon; settings gains none.


## Architecture Decision

**Approach**: Relocate the template-local `<style>` rules into `static/app.css` (app-only layer, loaded after the synced `design-system.css`), replacing the `summary-stat` re-implementation with the canonical `card-metric` primitive and retargeting borrowed tokens (`--info`→`--brand-codex`, hardcoded letter-spacing→`--tracking-caps`); migrate the page's container to the canonical `.content-area/.content-inner`. This honours the S01 CSS layering & sync contract (app edits only in `app.css`, synced files never touched).


## Constraints & Gotchas

- **Constraint**: App CSS edits go only in `static/app.css` -- never edit `static/design-system.css` or `static/tokens.css` (the drift check fails on any divergence). The relocated provider rules and the `card-metric` composition are app-side; `card-metric`/`content-area`/`kbd` themselves already exist in the synced `design-system.css` from S01.
- **Constraint**: `--brand-claude`/`--brand-codex` exist only after S01 (S08 dependsOn S01) -- reference them, do not redefine. The Codex borrow of semantic `--info` inside the settings `<style>` block is a settings-local instance the audit's CSS-file fix (`.provider-badge-codex`) did not cover; retarget it during relocation.
- **Critical**: Any template or static-asset edit requires regenerating `embedded_assets.g.dart` -- run `dart run dev/tools/embed_assets.dart`; never hand-edit the generated file. A stale map serves the old settings page in embedded mode.
- **Avoid**: Deleting `.page-content`/`.page-inner` rules -- other pages still use them (last-consumer rule).


## Code Patterns & External References

```
# type | path#anchor                                                              | why needed (intent)
file   | packages/dartclaw_server/lib/src/templates/settings.html                 | the <style> block (~13-360), summary-stat markup (~694-707), page-content/page-inner (~4-5) to change
file   | dev/design-system/components.css#card-metric                             | canonical metric card — compose .card.card-metric + .metric-value/.metric-label
file   | dev/design-system/components.css#content-area                            | canonical layout container to migrate to
file   | dev/bundle/docs/specs/0.22/s01-css-foundation.md#TI05                     | how S01 relocated app-only rules into app.css + retargeted provider badges to --brand-*
file   | packages/dartclaw_server/lib/src/static/app.css                          | destination for the relocated provider-section rules
```


## Implementation Plan

### Implementation Tasks

- [x] **TI01** `settings.html` carries no `<style>` block; its surviving app-specific rules live in `static/app.css`
  - Move the provider-section rules (`.provider-section`, `.provider-summary` + its `@media`, `.provider-card*`, `.provider-icon*`, `.provider-title/subtitle`, `.provider-section-note`, etc.) into `static/app.css`; delete the `<style>` element. Follow `s01-css-foundation.md#TI05` for the app-only-layer pattern.
  - **Verify**: `grep -c "<style" packages/dartclaw_server/lib/src/templates/settings.html` → `0`; and `grep -rL "<style" packages/dartclaw_server/lib/src/templates/*.html | wc -l` equals the template count (no template has a `<style>` element)

- [x] **TI02** Relocated provider icon rules draw from the provider-brand token group
  - `.provider-icon-codex` uses `--brand-codex` (not `var(--info)`); `.provider-icon-claude` uses `--brand-claude` (from S01). No semantic state token backs a provider colour.
  - **Verify**: `grep -A3 "\.provider-icon-codex" packages/dartclaw_server/lib/src/static/app.css` shows `--brand-codex` and no `var(--info)`; `grep -c "var(--info)" ` on the relocated provider rules → `0`

- [x] **TI03** Provider summary stats render as canonical `card-metric`
  - The three summary tiles become `<div class="card card-metric ...">` with `.metric-value` (count) + `.metric-label` (Configured/Healthy/Degraded), each carrying the semantic-modifier convention (per the `metric-color-convention` decision note): Configured → `card-metric--info`, Healthy → `card-metric--accent`, Degraded → `card-metric--warning`. Delete the `.summary-stat`/`.summary-value`/`.summary-label` rules (they re-implemented `card-metric` at 16px vs the 32px metric standard).
  - **Verify**: rendered Providers tab contains `card-metric` with `metric-value` + `metric-label` for each of Configured/Healthy/Degraded, and the Configured tile carries `card-metric--info`, Healthy `card-metric--accent`, Degraded `card-metric--warning`; `grep -rc "summary-stat\|summary-value\|summary-label" packages/dartclaw_server/lib/src/{templates/settings.html,static/app.css}` → `0`

- [x] **TI04** Settings uppercase-label letter-spacing uses tracking tokens
  - Replace the hardcoded `letter-spacing: 0.04em`/`0.06em` on uppercase labels (former `summary-label`, `provider-icon`, `provider-section-note`) with `var(--tracking-caps)`.
  - **Verify**: `grep -nE "letter-spacing:\s*0\.[0-9]+em" packages/dartclaw_server/lib/src/static/app.css` shows no match among the relocated settings provider rules; those rules use `var(--tracking-caps)`

- [x] **TI05** Settings key-reference copy uses `<kbd>`; model shorthands stay `<code>`
  - Any settings help/hint text that names a keyboard key uses `<kbd>`/`.kbd` (canonical selector from S01). Model shorthands (`claude/opus`, `codex/gpt-5.4`) correctly remain `<code>`. Settings copy currently contains no keyboard-key reference, so this task adds no invented shortcuts (see What We're NOT Doing).
  - **Verify**: `grep -nE "(Cmd|Ctrl|Enter|Esc|Shift|⌘)\b" packages/dartclaw_server/lib/src/templates/settings.html` — every match (if any) sits inside a `<kbd>`; no `<code>` element in `settings.html` wraps a bare keyboard key

- [x] **TI06** Settings uses the canonical `.content-area`/`.content-inner` container
  - The page `<main>`/inner wrapper uses `.content-area`/`.content-inner` (off `.page-content`/`.page-inner`). Update `dc_settings_controller.js`'s two `document.querySelector('.page-content')` sites (~lines 27 and 354) to `.content-area` in the same migration – the line-354 lookup gates `attachSettingsListeners()`' entire delegated wiring, so a stale selector silently breaks Save/Cancel/immediate-apply. Do NOT delete the `.page-content`/`.page-inner` rules — 11 other templates still consume them.
  - **Verify**: `grep -c "page-content\|page-inner" packages/dartclaw_server/lib/src/templates/settings.html` → `0`; `grep -c "page-content" packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js` → `0`; the page renders inside `content-area > content-inner`; `.page-content` rules still present in `app.css`; and the settings save/apply flow (the TC-25 restart-banner path) still functions after the selector migration

- [x] **TI07** `embedded_assets.g.dart` regenerated after the settings edits
  - Run `dart run dev/tools/embed_assets.dart` so the edited `settings.html` + `static/app.css` are embedded; never hand-edit the generated file.
  - **Verify**: `git status` shows `embedded_assets.g.dart` regenerated; the embedded settings entry contains no `<style>` (`grep "<style" ` on the generated settings payload → none)


## Final Validation Checklist
- [x] No `<style>` element remains in any template under `packages/dartclaw_server/lib/src/templates/` (app-wide claim of this story).
- [x] Design-system drift check exits zero (synced `design-system.css`/`tokens.css` unchanged).


## Implementation Observations

- Visual validation passed provider settings in dark/light at desktop and 768px, including responsive metric stacking.
- Relocated `.detail-*` rules were scoped to Settings to avoid colliding with unrelated page conventions.

#### DECISION NOTE: metric-color-convention

Decision-Key: metric-color-convention
Altitude: App-wide UI convention – metric-card color modifiers across all pages.
Affected surface: Metric cards (`.card-metric--*` modifiers) app-wide; applied in S08 to the settings provider-summary stats (Configured / Healthy / Degraded).
Decision: One app-wide rule – stats that encode a state use the matching semantic modifier; pure-quantity stats follow the health-dashboard precedent (accent for the headline stat, info for the rest). S08 application: Configured → `card-metric--info`, Healthy → `card-metric--accent`, Degraded → `card-metric--warning`.
Rationale: Keeps semantic color meaningful (reserved for state-encoding stats) while pure-quantity stats stay visually consistent with the established health-dashboard pattern.
Evidence: Ratified by owner during 0.22 preflight (2026-07-20); the same convention persisted in S10.

#### DECISION NOTE: content-inner-stack-gap

Decision-Key: content-inner-stack-gap
Altitude: App-wide layout-container convention – vertical spacing between stacked children of the canonical `.content-inner`.
Affected surface: Canonical `.content-inner` layout container (synced `design-system.css`); applied in S08 to the settings page's stacked sibling cards.
Decision: The canonical `.content-inner` rule gains `display: flex` / `flex-direction: column` + `gap: var(--sp-6)` upstream via S01's canon work; settings' stacked sibling cards inherit spacing from the synced rule. No settings-local spacing rule is added.
Rationale: Keeps stacked-card spacing owned by the canonical container in the synced layer, so per-page stories add no local spacing rules – honouring the S01 CSS layering & sync contract (S08 edits only `settings.html` + `static/app.css`).
Evidence: Ratified by owner during 0.22 preflight (2026-07-20); the gap lands upstream via S01's `.content-inner` canon work.
