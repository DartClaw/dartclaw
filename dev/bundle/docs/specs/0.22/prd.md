# Product Requirements Document: Afterglow Design-System Overhaul

> **Context**: ROADMAP entry "Afterglow Design-System Overhaul" (first of two UX milestones; ships first). Date: 2026-06-10. Status: Ready for implementation (preflight converged 2026-07-20; all 14 stories spec-ready).
> **Related Assets** (durable): canonical design system `../../../../design-system/DESIGN.md` (+ `tokens.css`, `components.css`, `showcase.html` — the "Afterglow" revision) · [audit-design-system-compliance.md](audit-design-system-compliance.md) (drift analysis, adoption map, violations inventory, page-by-page compliance, ~18-story breakdown) · [cross-surface UX plan](../../../../../../dartclaw-private/docs/specs/0.next-ui-ux-improvements/cross-surface-ux-plan-2026-06.md) (DS-0 placement + §3a Afterglow component bindings) · wireframes (`../../../../../../dartclaw-private/docs/wireframes/`, `deviations.md`).

## Executive Summary

- **Problem**: DartClaw's canonical design system shipped a major revision ("Afterglow" — brand identity, glass tier, meters, skeletons, identicons, terminal frames, ambient ground, extended palette + chart ramp) that the Web UI has adopted **none of** (0 of 35 new component classes, 0 new tokens). Worse, the app's CSS copies have **structurally drifted**: 540 app-only classes are interleaved into the copied `components.css` (4,527 lines vs canonical 1,654), with no provenance marker and no drift check. Bespoke re-implementations violate current rules (four ad-hoc progress bars, two circular spinners), the brand mascot is entirely absent, and the favicon is empty (`layout.html` `href="data:,"`). The result: an inconsistent, off-brand UI that undercuts DartClaw's "high-quality developer tool" positioning and silently diverges further from canon with every edit.
- **Vision**: The complete Web UI verifiably uses the canonical design system — a synced foundation with a loud drift check, every page composed from canonical primitives, and Afterglow's brand moments (mascot, claw loader, CRT login) landed with the scarcity doctrine intact. A visibly distinctive, coherent surface that every later UX milestone (0.19 knowledge UI, 0.24 authoring UI, the Cross-Surface UX milestone) is built *on*, not migrated to afterward.
- **Target Users**: (1) **Operators** using the Web UI daily — get a coherent, legible, on-brand surface with clear feedback states; (2) **DartClaw developers/contributors** — get a single source of truth (canonical design system) with drift enforced, so visual regressions are caught and new UI composes from sanctioned primitives.
- **Success Metrics**:
  1. Drift check green: app `design-system.css` byte-identical to canonical; **zero** app-side edits to synced files.
  2. All 35 Afterglow component classes available in the app; the violations inventory (audit §3) is **empty** (no circular spinners, no bespoke progress bars, no template-local `<style>` blocks, ≤5 justified inline styles app-wide, no off-system tokens).
  3. Page-by-page compliance (audit §5) reaches **"good"** on every row (chat, tasks, task detail, workflows, memory, settings, sessions, scheduling, canvas/dialogs, health, projects, login, pairing, channel detail, shell).
  4. Mascot served (favicon + login + sanctioned empty states); claw-loader is the **only** agent-thinking indicator; exactly **one** CRT surface app-wide.
  5. Every modified page passes visual validation in **both themes** + the UI smoke test (TC-01…TC-31) passes at each phase boundary; no mobile or reduced-motion regressions.

### Capabilities at a Glance
- **FR1: Synced, drift-checked design-system CSS** _(Must / P0)_ – split app CSS into a verbatim canonical `design-system.css` (provenance header) + an `app.css`, with a dev drift check that fails on divergence.
- **FR2: Token rationalization & provider-brand canonicalization** _(Must / P0)_ – adopt the new tokens; remove off-system ones; canonicalize a provider-brand token group so Codex stops borrowing semantic `--info`.
- **FR3: Atmospheric ground & unified entry motion** _(Must / P0)_ – ambient-glow + film-grain body ground and one `print-in` arrival motion, both reduced-motion aware.
- **FR4: Feedback primitives adoption** _(Must / P0)_ – all bespoke progress bars → `.meter`; spinners retired in favor of `.claw-loader` (agent-thinking), `.scan-bar`, and `.skeleton`.
- **FR5: Per-page component adoption** _(Must / P0)_ – every page composes canonical primitives (glass overlays, `kbd`, identicons, terminal frames, metric/display type); the violations inventory is cleared.
- **FR6: Brand identity surfaced** _(Should / P1)_ – mascot served (favicon + CRT login hero + sanctioned empty states), claw-mark empty states, identicons rollout, honoring the scarcity doctrine.
- **FR7: Documentation & deviation sync** _(Must / P0)_ – update public design-system docs (icon vocabulary, provider-brand tokens) and private wireframe `deviations.md`.

### Scope Highlights
- **In scope**: full Afterglow adoption across the Web UI; CSS sync mechanism + drift check; per-page component adoption; brand moments; doc sync.
- **Out of scope**: new UX *features* (search, notification center, knowledge UI); CLI and chat/channel surfaces; replacing `window.confirm` (currently sanctioned by DESIGN.md).
- **MVP boundary**: Phase 1 (synced/drift-checked CSS foundation + ground + motion) + Phase 2 (per-page primitive adoption). Brand moments (Phase 3) are the value-add that can split into a follow-up wave.

### Key Constraints, Assumptions & Dependencies
- *Dependency:* the Afterglow design-system revision must be **committed as canonical** in `dartclaw-public/dev/design-system/` before implementation starts (currently uncommitted).
- *Constraint:* zero-npm / server-first (plain CSS + Trellis + HTMX + Stimulus; no build step); design-system compliance; scarcity doctrine; mobile parity (768px / 48px / 16px).
- *Assumption:* ~18 stories across 3 phases — at the upper edge of the 10–14-story target; Phase 3 (brand moments) may split into a follow-up wave.

## Problem Definition

### Problem Statement
The app's browser CSS is a hand-copied, **drifted** fork of the canonical design system, and it predates the entire "Afterglow" revision. Two compounding problems: (1) **divergence is silent** — there is no provenance marker and no drift check, so the app and canon drift apart with every edit and "the design system" is no longer a single source of truth; (2) **the new design language is entirely unadopted** — none of Afterglow's brand identity, depth/motion system, or component primitives exist in the app, while bespoke re-implementations actively violate the current rules. If nothing changes, the UI looks increasingly off-brand and inconsistent, new UI keeps composing from non-canonical ad-hoc CSS, and every subsequent UX milestone inherits and must later rework a stale visual foundation.

### Evidence & Context
- App `components.css` is 4,527 lines / 138 KB vs canonical 1,654 / 56 KB; **540 app-only classes** interleaved into the copy; **0** Afterglow markers present (no `--ambient-*`, `--noise`, glass tokens, tracking tokens, extended palette, `--chart-*`, micro-lifts, `steps()` easing). (audit §1)
- **35** new canonical component classes absent from the app; shared classes (`body`, `.btn`, `.btn-primary`, `.card:hover`, `.toast`, logo gradient) diverged in content. (audit §1)
- Four bespoke progress-bar implementations (`budget-bar`, `fill-bar`, `task-progress`, `workflow-progress-bar`) and two circular spinners (`restart-spinner`, `wa-spinner`) violate the no-spinner / use-`.meter` rules; 36 hardcoded `letter-spacing` values; off-system tokens (`--weight-semibold: 550`, `--radius-sm: 3px`, `--color-peach` duplicating `--warning`). (audit §1, §3)
- Mascot assets exist at repo root but are **never served**; favicon is literally empty. `settings.html` carries a template-local `<style>` block; `signal_pairing.html`/`whatsapp_pairing.html` carry 37 inline styles. (audit §2, §3)
- Strategic timing: the [cross-surface UX plan](../../../../../../dartclaw-private/docs/specs/0.next-ui-ux-improvements/cross-surface-ux-plan-2026-06.md) sequences this **first** because visual quality multiplies every later UI item and the 0.19/0.24/Cross-Surface-UX UI work must build on the new system.

## Scope

### In Scope
- A CSS **sync mechanism**: split into verbatim `design-system.css` (provenance header + content hash) + `app.css` (app-only extensions); a dev-verification drift check that fails on divergence; upstream-first rule for new generic classes.
- **Token** adoption + rationalization (extended palette, chart ramp, ambient/noise, tracking, glass, display/metric scale); removal of off-system tokens; a canonical **provider-brand** token group (resolving Codex's borrow of semantic `--info`).
- **Atmospheric ground** (ambient glows + film grain) and a single **`print-in`** arrival motion, reduced-motion aware.
- **Feedback primitive** adoption: `.meter` (all determinate progress), `.claw-loader` (agent-thinking), `.scan-bar`, `.skeleton`; retirement of circular spinners and text-only loaders.
- **Per-page component adoption** across chat, tasks/detail, workflows, health/memory dashboards, settings, channels/pairing, scheduling/projects/sessions: glass overlays (`.card-glass`), `kbd`, identicons, terminal frames, metric/display typography; clearing the violations inventory (inline styles, template-local `<style>`, parallel layout-container families, non-token hovers).
- **Brand moments**: serve the mascot (favicon + login CRT hero + sanctioned empty states), claw-mark empty states, identicons rollout — under the scarcity doctrine (one claw moment per view, CRT hero-only, glass only over live content).
- **Documentation sync**: public design-system docs (icon vocabulary, provider-brand tokens, any deviations) and private wireframe `deviations.md`.

### Out of Scope
- New UX **features** — thinking indicators beyond swapping in the loader, global/Cmd+K search, notification center, knowledge UI. These belong to the 0.18.x quick-win wave / 0.19 / the Cross-Surface UX milestone.
- **CLI and chat/channel** surfaces (no design-system dependency).
- Replacing **`window.confirm`** for destructive confirmation — currently *sanctioned* by DESIGN.md §Banners-and-toasts; changing it requires a DESIGN.md decision-table update first (a separate, upstream change).
- Net-new **charts/sparklines** — only the `--chart-1..6` token wiring lands here so future viz can't hand-pick hues.

### MVP Boundary
The smallest release that solves the core problem is **Phase 1 + Phase 2**: a verbatim-synced, drift-checked CSS foundation (so canon is the single source of truth again) plus per-page adoption of the Afterglow primitives (so the UI is consistent and the violations inventory is cleared). Brand moments (Phase 3) raise it from "consistent" to "distinctive" and may ship as a follow-up wave.

## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As an operator, I want the Web UI to present one coherent, polished visual language so DartClaw feels like a high-quality, trustworthy tool. | Page-by-page compliance (audit §5) reads "good" on every page; no page mixes bespoke and canonical treatments for the same job. | Must / P0 |
| US02 | As a contributor, I want the app's design-system CSS to stay verifiably in sync with canon so the design system is the single source of truth and visual regressions are caught. | `design-system.css` byte-identical to canonical (provenance header present); dev drift check fails on any divergence and passes after sync. | Must / P0 |
| US03 | As an operator, I want clear, consistent feedback while things load or run so I always know what the UI/agent is doing. | All determinate progress uses `.meter`; agent-thinking uses `.claw-loader`; initial loads use `.skeleton`; no circular spinner or bare "Loading…" text remains. | Must / P0 |
| US04 | As an operator on mobile or in light theme, I want every page to render correctly so I can use DartClaw on any device/theme. | Every modified page passes visual validation in dark + light at desktop and 768px; touch targets ≥48px; inputs ≥16px; `prefers-reduced-motion` disables claw-loader/print-in/micro-lifts. | Must / P0 |
| US05 | As an operator, I want DartClaw's brand identity present so the product feels distinctive and finished. | Mascot served as favicon + login hero; sanctioned empty states show the claw-mark/mascot; exactly one CRT surface; scarcity doctrine satisfied (one claw moment per view). | Should / P1 |
| US06 | As a contributor, I want the docs to match the shipped system so future UI work references accurate guidance. | Public design-system docs (icon vocabulary, provider-brand tokens) and wireframe `deviations.md` updated to match the implemented state. | Must / P0 |

### Feature Specifications

#### FR1: Synced, drift-checked design-system CSS
**Description**: Replace the hand-drifted CSS copy with a verbatim canonical `design-system.css` (provenance header: source path + sync date + content hash) plus a separate `app.css` carrying only app-specific extensions, loaded after. Add a dev-verification drift check that fails when `design-system.css` diverges from canon. Establish an upstream-first rule (new generic classes go to canon first, then sync down).

**Acceptance Criteria**:
- [ ] `design-system.css` is byte-identical to `dartclaw-public/dev/design-system/components.css` (verified by the drift check); `tokens.css` likewise (app-only tokens isolated in `app-tokens.css`).
- [ ] App-only rules (~450 page-feature classes) live in `app.css`, not interleaved with the synced file.
- [ ] A documented dev command (wired into the verification path) diffs synced files against canon and exits non-zero on mismatch.
- [ ] `layout.html` load order updated; all pages render unchanged-or-better after the split.

**Inputs / Outputs**: Inputs — canonical `dev/design-system/*.css`. Outputs — `static/design-system.css`, `static/app.css`, `static/app-tokens.css` (if needed), a drift-check script, updated `layout.html`.

**Validation**: drift check is authoritative; any divergence fails CI/dev verification.

**Error Handling**: drift detected → loud failure naming the diverging file; the fix is re-sync (never hand-edit the synced file).

**Priority**: Must / P0

#### FR2: Token rationalization & provider-brand canonicalization
**Description**: Adopt the new canonical tokens (extended palette, `--chart-1..6`, ambient/noise, tracking, glass, `--text-2xl/3xl`). Remove off-system tokens (`--weight-semibold: 550`, `--radius-sm: 3px`, `--color-peach` [duplicate of `--warning`], unused `--container-wide`, off-scale spacing) and fix their use sites. Canonicalize a documented **provider-brand** token group so Codex's badge no longer borrows semantic `--info` (which collides with the info state in the same views). Ratified values (preflight 2026-07-20): `--brand-claude` keeps the existing app terracotta; `--brand-codex` aliases the extended-palette teal.

**Acceptance Criteria**:
- [ ] All new canonical tokens available in the app; no off-system token remains (grep-clean).
- [ ] Provider badges use a provider-brand token group (upstreamed to canon); no provider badge uses a semantic state token.
- [ ] 36 hardcoded `letter-spacing` values replaced by `--tracking-*` tokens.

**Priority**: Must / P0

#### FR3: Atmospheric ground & unified entry motion
**Description**: Apply the canonical body ground (3-stop gradient + ambient glows + film-grain `body::before`) and a single `print-in` arrival motion to message fragments and HTMX-swapped content. All motion respects `prefers-reduced-motion`.

**Acceptance Criteria**:
- [ ] Body ground renders without banding on large viewports; grain layer sits correctly behind content and above the gradient; verified against the shell grid, dialogs, and SSE swaps in both themes.
- [ ] `print-in` is the single arrival treatment (messages, swapped fragments, cards); no competing entry animations.
- [ ] `prefers-reduced-motion` disables ambient/print-in/loader animation and micro-lifts.

**Priority**: Must / P0

#### FR4: Feedback primitives adoption
**Description**: Replace the four bespoke progress bars with `.meter`/`.meter-fill--*`; retire both circular spinners; adopt `.claw-loader` as the branded agent-thinking indicator (restart overlay, chat pre-stream, task live-activity), `.scan-bar` for anonymous in-place sweeps, and `.skeleton` for initial page/fragment loads.

**Acceptance Criteria**:
- [ ] No `.restart-spinner`/`.wa-spinner` or `@keyframes spin` remains; no bare "Loading…" text loader remains.
- [ ] All determinate progress (memory budget, task/workflow progress) uses `.meter` with a visible label/percentage (color never carries the reading alone).
- [ ] `.claw-loader` appears at most once per view (scarcity doctrine).

**Priority**: Must / P0

#### FR5: Per-page component adoption
**Description**: Bring every page to "good" compliance by composing canonical primitives: glass (`.card-glass`) for overlays above live content (toasts, dialogs, composer palettes), `kbd` for shortcut hints, identicons for entity identity (sessions, channels, task agent badges — never state), terminal frames for diff/raw/step-output views, and `metric-value`/`display` type for KPIs/headers. Clear the violations inventory: purge inline styles into classes/utilities, delete the `settings.html` `<style>` block, collapse the three parallel layout-container families into the canonical one, fix non-token hovers, and convert `display:none` toggles to the `hidden` attribute.

**Acceptance Criteria**:
- [ ] Page-by-page compliance table (audit §5) reads "good" for all pages.
- [ ] ≤5 justified inline `style` attributes remain app-wide; no template-local `<style>` block remains.
- [ ] Glass is used only over live content (never in-flow); identicons encode entity identity only, never state.
- [ ] Each page passes visual validation in both themes (desktop + 768px) before its work is considered done.

**Priority**: Must / P0

#### FR6: Brand identity surfaced
**Description**: Serve the 8-bit crab mascot (favicon + login CRT-terminal hero + sanctioned empty states) with `.pixel-art`; replace emoji empty-state icons with the claw-mark where appropriate; roll out identicons. All under the scarcity doctrine.

**Acceptance Criteria**:
- [ ] Favicon is the mascot avatar (crisp at 16/32px); no empty `data:,` favicon.
- [ ] Exactly one CRT surface app-wide (the login hero); mascot never rendered below ~32px or without `.pixel-art`.
- [ ] Empty states use the claw-mark/mascot per the one-mark-per-view rule; the prompt glyph stays where sanctioned.

**Priority**: Should / P1 *(highest-value sub-item — the favicon/mascot — may be pulled earlier; CRT hero + full empty-state rollout may split into a follow-up wave)*

#### FR7: Documentation & deviation sync
**Description**: Update affected documentation as part of the work: public design-system docs (icon vocabulary additions, the new provider-brand token group, any deviations discovered) and the private wireframe `deviations.md`; refresh user-guide screenshots where the visual change is significant.

**Acceptance Criteria**:
- [ ] DESIGN.md reflects the 5 upstreamed icons and the provider-brand token group.
- [ ] `deviations.md` records any intentional divergences; no undocumented deviation remains.

**Priority**: Must / P0

### User Flows
1. **Foundation**: sync tokens + split CSS (drift check live) → ambient ground + print-in land app-wide via the synced file → spot-check all pages, both themes.
2. **Per-page adoption**: consolidate meters + loading states first (they delete shared CSS) → then page-by-page primitive adoption, each gated on visual validation.
3. **Brand moments**: serve mascot/favicon → claw-mark empty states → CRT login hero → identicons → doc sync.

### UI Wireframes
- Canonical reference: `dartclaw-public/dev/design-system/showcase.html` (the Afterglow component reference) and `DESIGN.md`.
- Wireframe inventory + deviations: `../../../../../../dartclaw-private/docs/wireframes/` (`page-inventory.md`, `deviations.md`).

## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Visual quality | Every modified page validated against the design system | Visual validation passes in **both** themes at desktop + 768px per story; UI smoke test (TC-01…TC-31) passes at each phase boundary |
| Maintainability | Synced CSS stays canonical | `design-system.css` byte-identical to canon (drift check green); zero design-system class re-implementations remain |
| Performance | No client-side build; bounded payload | Zero new runtime JS deps; total JS payload growth within governance ceiling; ambient ground/grain are CSS-only |
| Accessibility | Contrast + motion + touch | WCAG AA contrast preserved both themes; `prefers-reduced-motion` disables motion; touch targets ≥48px; inputs ≥16px (iOS no-zoom) |
| Compatibility | Zero-npm / server-first | All changes ship as plain CSS + Trellis templates + Stimulus controllers; no build step |

## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|----------|-------------------|---------------|
| Canonical design system changes upstream after sync | Drift check fails loudly, naming the diverging file | Re-sync `design-system.css` from canon; never hand-edit the synced file |
| Film-grain / ambient ground causes banding or stacking issues on large viewport | Grain sits behind content, above gradient; no banding | Tune `--noise-opacity` per theme; verify `z-index`/`background-attachment` against shell grid, dialogs, SSE swaps |
| Mascot rendered small or scaled by the browser | Always `.pixel-art`, never below ~32px | Use sized variants; keep pixel art crisp |
| `prefers-reduced-motion` user | Claw-loader, print-in, micro-lifts disabled; static fallbacks | n/a (handled by reduced-motion block) |
| Light theme | Ambient glow percentages tuned for Latte (darker hues); contrast preserved | Per-theme token values; validate both themes per story |
| Glass requested for in-flow content | Glass used only over live content; in-flow cards stay opaque | Reviewer/visual-validation catch; revert to `.card` |

## Constraints & Assumptions

### Constraints
- **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.
- **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.
- **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.
- **`window.confirm` stays**: currently sanctioned by DESIGN.md; replacing it is out of scope (needs an upstream DESIGN.md decision-table change first).

### Assumptions
- The Afterglow design-system revision will be **committed as canonical** in `dartclaw-public/dev/design-system/` before implementation starts.
- ~18 stories across 3 phases — at the upper edge of the 10–14-story target; **Phase 3 (brand moments) may split** into a follow-up wave.
- This ships **first** of two UX milestones; the Cross-Surface UX milestone and the 0.19/0.24 UI work build on the new system.
- No raw-hex violations exist in the app CSS today (verified), so token discipline is preserved through the split.
- **Forward compatibility — native shell (Tauriel, 2026-07-04):** the Web UI will later be wrapped in a native webview app ([`0.next-desktop-app`](../../../../../../dartclaw-private/docs/specs/0.next-desktop-app/prd-brief.md) / [`0.next-mobile-app`](../../../../../../dartclaw-private/docs/specs/0.next-mobile-app/prd-brief.md)). Two cheap accommodations ride the FR2 token work (upstream-first, to canon before the app): viewport **safe-area inset tokens** (`env(safe-area-inset-*)` wired into the shell/layout paddings) and a reserved **titlebar/drag-region variable** for the desktop shell. No shell-specific UI is built here.

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| Afterglow revision committed as canonical in `dartclaw-public/dev/design-system/` | Implementation syncs verbatim from it; cannot start until it is canonical |
| Visual testing profile + UI smoke test (TC-01…TC-31) | Every UI story is gated on visual validation in both themes; smoke test at phase boundaries |
| Mascot brand assets (`assets/logo-*-8bit.png`) | Required to serve favicon, login hero, and empty states |

## Decisions Log

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| Split into verbatim `design-system.css` + `app.css` with a drift check | App CSS drifted ~4,500 lines with no provenance; verbatim sync + a loud drift check restores canon as the single source of truth and makes future drift visible | Re-copy on each change (a 4,500-line manual merge — unmaintainable); leave drifted (status quo, divergence compounds) |
| Ship as the **first** UX milestone, before Cross-Surface UX | Visual quality multiplies every later UI item; the 0.19/0.24/Cross-Surface-UX UI must be built on the new system, not migrated after | Fold into Cross-Surface UX (combined = 30+ stories, far too big); incremental as-touched (UI stays inconsistent across several milestones) |
| Keep `window.confirm` for destructive confirmation | DESIGN.md currently sanctions it; treating it as a violation would be wrong | Replace with a glass modal — deferred; requires a DESIGN.md decision-table change first |
| `.claw-loader` for restart overlay + chat pre-stream + task activity | The sanctioned branded agent-thinking indicator; replaces the two non-compliant circular spinners | Keep spinners (violates the no-spinner rule); generic scan-bar everywhere (loses the brand moment) |
| Phase 3 (brand moments) may split into a follow-up wave | ~18 stories exceeds the 10–14-story target; brand moments are the lowest-criticality, highest-polish slice | Ship one oversized milestone (sizing risk) |
| Wire `--chart-1..6` tokens now without building charts | Ensures future sparklines/usage viz can't hand-pick hues; cheap forward-compatibility | Defer token wiring until charts exist (risks ad-hoc hue choices later) |
| `--brand-codex` = extended-palette teal; `--brand-claude` = app terracotta (preflight, 2026-07-20) | Distinct from semantic `--info` and from Claude's warm terracotta in both themes; stays inside the sanctioned decorative palette | Sky (reads as the info state again); custom off-palette hex |
| Canonical `.content-inner` gains the page stack gap (flex-column + `--sp-6`), upstreamed via the foundation story (preflight, 2026-07-20) | The retiring app containers (`.page-inner`/`.info-inner`) provided section rhythm; closing the gap in canon per the upstream-first rule beats duplicating per-page spacing rules | Per-page app.css spacing rules; a separate canonical stack utility |
| `deviations.md` writes resolve the private repo as a sibling of the main public checkout, with a bundle-local staged fallback when it is absent (preflight, 2026-07-20) | Story worktrees nest inside the public repo, so naive `../` resolution breaks; staging keeps FR7 satisfiable with a manual sync step instead of silent loss or a hard failure | Hard-fail the doc-sync story on absence; always stage publicly |
