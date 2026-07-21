# Channels & pairing adoption

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S09

## Feature Overview and Goal

**Intent**: Bring the channel-detail and pairing surfaces — the app's worst template-hygiene offenders — up to "good" design-system compliance so the Web UI reads as one coherent, on-brand system instead of a hand-styled corner.

**Expected Outcomes**:

- [OC01] `signal_pairing.html`, `whatsapp_pairing.html`, and `channel_detail.html` carry zero inline `style` attributes — former typographic/color inlines use canonical text utilities and the few layout/QR-frame inlines move into classes in `static/app.css`.
- [OC02] The bespoke `wa-*` pairing class family is gone: shared pairing classes are renamed channel-neutral (`pairing-*`), the `.wa-pre` config blocks render as canonical `.well-deep`, and the pairing form/step sections plus the channel-detail panel sub-groups render as canonical wells.
- [OC03] Channel-detail hygiene lands: static `display:none` toggles use the `hidden` attribute (with the toggling controller updated to match) and the page uses the canonical `.content-area`/`.content-inner` layout family.
- [OC04] Channel detail and both pairing pages read "good" on the audit §5 compliance table and pass visual validation in both themes at desktop + 768px (QR frames legible), without re-implementing the S03 scan-bar/loader work or the S13 channel-hero identicon.


## Required Context

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

### From `prd.md` – "Constraints" (binding)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.
>
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.
>
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.

### From `prd.md` – "FR1: Synced, drift-checked design-system CSS" (binding)
<!-- source: prd.md#fr1-synced-drift-checked-design-system-css -->
<!-- extracted: 7d948b65 -->
> `design-system.css` is byte-identical to `dartclaw-public/dev/design-system/components.css` (verified by the drift check); `tokens.css` likewise (app-only tokens isolated in `app-tokens.css`).
>
> A documented dev command (wired into the verification path) diffs synced files against canon and exits non-zero on mismatch.

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

### From `plan.json` – "sharedDecisions: Identicon ownership"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> S13 solely owns the identicon rollout — hash utility in shared.js, sidebar session/channel rows, channel hero, and task agent badges. S05 and S09 explicitly exclude identicons even where the audit adoption map mentions them for their pages.


## Deeper Context

- `audit-design-system-compliance.md#3-violations-inventory` – "Template hygiene" (the 37 inline styles: signal ×25, whatsapp ×12; `display:none` toggles → `hidden`), "Structure/containers" (Wells unused; `.wa-pre` ad-hoc substitute). **Line numbers are stale; locate by selector/content.**
- `audit-design-system-compliance.md#5-quick-reference--page-by-page-compliance` – the Pairing row ("purge 37 inline styles; `.wa-pre` → `.well-deep`, channel-neutral class names") and Channel-detail row ("inline `style="display: none"` → `hidden`; wells for panel sub-groups"). The `wa-spinner` → scan-bar item on the pairing row is S03's, not this story's.
- `audit-design-system-compliance.md#1-css-drift-analysis` – §(b) names `wa-*` (29 classes, shared by WhatsApp + Signal pairing) as genuinely app-specific but requiring channel-neutral names; `.wa-pre` → `.well-deep` in the rationalize-away table.
- `dev/design-system/components.css` – canonical `.well`/`.well-deep`/`.well-content`, `.content-area`/`.content-inner`, and the `.text-muted`/`.text-sm`/`.text-xs`/`.text-overlay`/`.text-success`/`.text-warning` utilities this story composes (all delivered by the S01 sync into `static/design-system.css`).
- `packages/dartclaw_server/AGENTS.md` – Trellis template pairing, Stimulus controller contract, and the `embedded_assets.g.dart` regeneration rule.


## Acceptance Scenarios

- [x] **S01 [OC01,OC02] [TI01,TI02] Signal pairing renders inline-style-free with channel-neutral wells**
  - **Given** the Signal pairing page in the link-device state
  - **When** the page renders
  - **Then** the HTML contains no `style="` attribute and no `wa-` class token; the `signal-cli` config block renders inside a `.well-deep`; the QR frame uses a `.pairing-qr-frame` class (white background carried by the class, not inline); former `color:var(--fg-sub0)` / `font-size:var(--text-sm)` inlines are now `.text-muted` / `.text-sm` utilities

- [x] **S02 [OC01,OC02] [TI01,TI03] WhatsApp pairing renders inline-style-free with a `hidden` expired state**
  - **Given** the WhatsApp pairing page in the QR state
  - **When** the page renders
  - **Then** the HTML contains no `style="` attribute and no `wa-` class token; the QR-expired block uses the `hidden` attribute instead of `style="display:none"`; the GOWA config block renders inside a `.well-deep`

- [x] **S03 [OC02] [TI04] Pairing CSS drops the bespoke `wa-*` family**
  - **Given** the built `static/app.css` after the story
  - **When** it is grepped for pairing selectors
  - **Then** it contains zero `.wa-` selectors (no `.wa-pre`, `.wa-section`, `.wa-main`, `.wa-spinner`), the pairing form/step sections resolve to canonical `.well`/`.well-content`, and the surviving pairing-specific rules use the `pairing-` prefix

- [x] **S04 [OC03] [TI05,TI06] Channel-detail hygiene: `hidden` toggle + canonical layout family**
  - **Given** the channel-detail page and its restart-banner toggle
  - **When** the page renders and `dc_settings_controller.showChannelRestartBanner()` runs
  - **Then** `#channel-restart-banner` carries the `hidden` attribute (no `style="display: none"`), the controller clears it via `.hidden = false` (not `.style.display`), the page main/inner use `.content-area`/`.content-inner`, and the panel sub-groups render as canonical wells

- [x] **S05 [OC04] [TI01,TI03] The S03 scan-bar survives the pairing rename**
  - **Given** the Signal or WhatsApp pairing page in a waiting/reconnecting state (where S03 already replaced `wa-spinner` with `.scan-bar`)
  - **When** the page renders after this story's rename
  - **Then** a `.scan-bar` still renders in the wait row and no `wa-spinner` (or `@keyframes wa-spin`) reappears — this story neither re-swaps nor re-implements the loader

- [x] **S06 [OC01] [TI01] A layout-only inline with no utility match becomes an app.css class**
  - **Given** the Signal captcha step list (`<ol>` with an inline `display:flex;flex-direction:column;gap`) that no text utility covers
  - **When** the page renders
  - **Then** the list uses a purpose class defined in `static/app.css` (not an inline style and not dropped), and still renders as a gap-spaced vertical column

- [x] **S07 [OC04] [TI01,TI04,TI05] Both pairing pages and channel detail pass the visual gate in both themes**
  - **Given** the `visual` testing profile at desktop and 768px in dark and light
  - **When** channel detail, WhatsApp pairing, and Signal pairing are captured (manual hardware pairing per `channel-e2e-manual`)
  - **Then** each page reads "good" against the design system, the QR frame's white background renders legibly in both themes, and no layout/contrast regression appears versus the pre-story baseline


## Structural Criteria

- [x] `grep -c 'style="'` on `signal_pairing.html`, `whatsapp_pairing.html`, and `channel_detail.html` is `0` (proved by TI01/TI02/TI05).
- [x] `grep -c 'wa-'` on both pairing templates is `0`, and `static/app.css` has no `.wa-` selector (proved by TI01/TI02/TI04).
- [x] The synced `static/design-system.css` and `static/tokens.css` are untouched and the S01 drift check still exits zero (proved by TI07).
- [x] `lib/src/generated/embedded_assets.g.dart` is regenerated and `git diff --exit-code` on it is clean after the template/static/controller edits (proved by TI07).
- [x] Existing pairing route tests (`test/web/signal_pairing_routes_test.dart`, `test/web/whatsapp_pairing_routes_test.dart`) are updated to the renamed markup and pass (proved by TI07).


## Scope & Boundaries

### Work Areas

- `signal_pairing.html` — purge 25 inline styles (pre-S01 snapshot count – S01 and S03 each remove one inline before this story runs, so the governing target is `grep -c 'style="'` == 0, not the literal count) into text utilities / classes; `wa-*` → `pairing-*`; `.wa-pre` → `.well-deep`; consolidate the inline QR frame/img into `.pairing-qr-frame`/`.pairing-qr-img`; form/step sections → wells. [TI01]
- `whatsapp_pairing.html` — purge 12 inline styles (pre-S01 snapshot count; same == 0 governing target); `wa-*` → `pairing-*`; `.wa-pre` → `.well-deep`; QR-expired `style="display:none"` → `hidden`; form/step sections → wells. [TI02]
- `dc_whatsapp_controller.js` — update the `wa-qr-placeholder` class reference and the active/expired target toggle to drive the `hidden` attribute instead of `.style.display`. [TI03]
- `static/app.css` — rename the `wa-*` rule blocks to `pairing-*`; delete `.wa-pre`/`.wa-section` (folded into canonical wells) and `.wa-qr-*` bespoke rules where a `pairing-*` equivalent or canonical well/utility replaces them; add `.pairing-qr-frame` (white bg) and the few layout utility classes the purged inline layout styles need. No edits to synced files. [TI04]
- `channel_detail.html` — restart banner `style="display: none"` → `hidden`; panel sub-groups (`.channel-sub-card`) render as wells; `.page-content`/`.page-inner` → `.content-area`/`.content-inner`. [TI05]
- `dc_settings_controller.js` — `showChannelRestartBanner()` clears the `hidden` attribute instead of setting `.style.display`. [TI06]
- Verification finalization — regenerate `embedded_assets.g.dart`; update the two pairing route tests. [TI07]

### What We're NOT Doing

- The `wa-spinner` → `.scan-bar` swap and `@keyframes wa-spin` deletion -- owned by S03; this story only renames the surrounding containers and must preserve the scan-bar S03 placed.
- The channel-hero identicon (`channel_detail.html` hero) -- owned by S13; excluded here per the identicon-ownership shared decision even though audit §5 lists it on the channel-detail row.
- Deleting the `.page-content`/`.page-inner` app.css rule -- channel detail is not its last consumer (11 other templates, including the out-of-scope knowledge UI, still use it); this story migrates channel detail off it but leaves the shared rule for whoever removes the last consumer.
- Any meter/claw-loader/skeleton work on these pages -- owned by S03; this story composes what S03 landed and never re-swaps loading/progress UI.
- Replacing `window.confirm` / disconnect confirmation flows -- sanctioned by DESIGN.md; out of scope for the milestone.


## Architecture Decision

**Approach**: Markup + CSS-rename only — purge the pairing/channel inline styles onto the canonical text utilities and wells that S01 synced, rename the app-only `wa-*` family to channel-neutral `pairing-*` in `static/app.css`, and convert static `display:none` toggles to the `hidden` attribute (updating the two controllers that drive them). No new primitives, no build step, no JS dependency.
**Why this over alternatives**: The `wa-*` family is genuinely app-specific (per audit §1b) so it stays app-side rather than upstreaming to canon; renaming in place (vs folding pairing onto `.content-area`) preserves the intentional narrow pairing column while still clearing the hygiene violations the audit flags.


## Code Patterns & External References

```
# type | path#anchor                                                              | why needed (intent)
file   | dev/design-system/components.css#.well-deep                             | Canonical config-block well the .wa-pre blocks migrate to
file   | dev/design-system/components.css#.well                                  | Canonical form/step-section + panel-sub-group well
file   | packages/dartclaw_server/lib/src/templates/whatsapp_pairing.html         | Existing .wa-qr-frame/.wa-qr-img class shape TI01 follows when consolidating Signal's QR frame
file   | packages/dartclaw_server/lib/src/static/controllers/dc_whatsapp_controller.js | activeTarget/expiredTarget style.display toggle (TI03 converts to hidden)
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#showChannelRestartBanner | style.display toggle (TI06 converts to hidden)
file   | packages/dartclaw_server/test/web/signal_pairing_routes_test.dart        | Existing route-test seam TI07 extends
file   | packages/dartclaw_server/test/web/whatsapp_pairing_routes_test.dart      | Existing route-test seam TI07 extends
```


## Constraints & Gotchas

- **Depends on S01 and S03.** The canonical wells/utilities and the `design-system.css`/`app.css` split come from S01; the `wa-*` rule blocks this story renames live in `static/app.css` post-split. S03 must have already swapped `wa-spinner` → `.scan-bar` in both pairing templates — do not re-do or undo that swap. Never edit the synced `design-system.css`/`tokens.css`; the drift check must stay green.
- **`display:none` → `hidden` is a two-file change when a controller drives it.** The channel restart banner is toggled by `dc_settings_controller.showChannelRestartBanner()` (`.style.display = ''`) and the WhatsApp QR-expired state by `dc_whatsapp_controller` active/expired targets (`.style.display`). Converting the template to `hidden` without updating the toggling JS leaves the element permanently hidden. Purely-static `display:none` (no JS toggle) is a one-line template change.
- **QR frames need a theme-independent white background.** The Signal QR endpoint can return a transparent PNG, so `.pairing-qr-frame` must carry an explicit white background (as a class, not inline) for scannability in both themes — this is part of the visual gate.
- **Regenerate embedded assets.** Any template, `static/`, or controller edit requires `dart run dev/tools/embed_assets.dart`; `embedded_assets.g.dart` is checked-in generated output and CI fails on a stale diff.
- **`grep 'wa-'` is safe on these templates.** `whatsapp` / `dc-whatsapp` contain no literal `wa-` substring, so a zero `wa-` count reliably proves the class rename is complete.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** Signal pairing template is inline-style-free and composed from channel-neutral wells and utilities
  - Move every `style="…"` in `signal_pairing.html` to canonical utilities (`color:var(--fg-sub0)`→`.text-muted`, `font-size:var(--text-sm)`→`.text-sm`, `--text-xs`→`.text-xs`, `--fg-overlay`→`.text-overlay`, `--success`→`.text-success`, `--warning`→`.text-warning`) or, for inline properties with no canonical utility, a shared channel-neutral app.css class – the captcha `<ol>` flex list and form stacks, the check/warning step-icon `--text-xl` sizing (a shared step-icon class), the link-URI `<code>`'s `--accent`/`word-break`/`display:block` treatment (a shared link-URI class), and the QR frame/img. These app.css class names are the implementer's choice but MUST be identical across both pairing templates wherever the same treatment recurs. Rename all `wa-*` classes to `pairing-*`; render the `signal-cli` config `<pre>` as `.well-deep`; make each pairing form/step section a canonical `.well`/`.well-content` plus a shared `pairing-`-prefixed section layout class that carries the internal flex-column + gap the old `.wa-section` provided (well internals are app-specific composition, not a canon gap). The scan-bar S03 placed in the wait row stays.
  - Follow `whatsapp_pairing.html`'s QR **markup/class structure** – a frame element wrapping an img element, under the shared `pairing-qr-*` class family – when consolidating Signal's inline QR frame; do NOT copy WhatsApp's background treatment. Background ownership follows TI04's contract: `.pairing-qr-frame` carries the white background + padding (Signal's existing frame architecture – theme-independent QR scannability in both themes) and `.pairing-qr-img` is the bare image. WhatsApp's current img-level `bg-surface0` + dashed-border placeholder treatment on `.wa-qr-img` is dropped, not carried onto `.pairing-qr-img`.
  - **Verify**: `Test: rendered signal_pairing HTML has grep -c 'style="' == 0 and grep -c 'wa-' == 0; the config block carries class="well-deep"; the QR frame carries class="pairing-qr-frame" (white background) and the QR <img> carries class="pairing-qr-img" (bare, no background); each form/step section carries class="well" with a "well-content" body plus the shared pairing-section layout class; the check/warning step icons carry the shared step-icon class (not an inline --text-xl) and the link-URI code carries the shared link-URI class (not an inline --accent); former --text-xs/--fg-overlay/--success/--warning inlines are now .text-xs/.text-overlay/.text-success/.text-warning utilities; a .scan-bar still renders in the reconnect row; section-internal spacing is visually confirmed in both themes per the S07 gate`

- [x] **TI02** WhatsApp pairing template is inline-style-free with a `hidden` expired state
  - Move the `style="…"` inlines (12 in the pre-S01 snapshot) in `whatsapp_pairing.html` to the same utilities/classes as TI01 – including the shared step-icon class for the check/warning `--text-xl` sizing; rename `wa-*` → `pairing-*`; render the GOWA config `<pre>` as `.well-deep`; convert the QR-expired block's `style="display:none"` to the `hidden` attribute; make each form/step section a `.well`/`.well-content` plus the shared pairing-section layout class carrying the internal column gap. Class names MUST match those chosen in TI01 (shared pairing family).
  - **Verify**: `Test: rendered whatsapp_pairing HTML has grep -c 'style="' == 0 and grep -c 'wa-' == 0; the expired block uses the hidden attribute and no style="display:none"; the config block carries class="well-deep"; each form/step section carries class="well" with a "well-content" body plus the shared pairing-section layout class; the check/warning step icons carry the shared step-icon class (not an inline --text-xl); section-internal spacing is visually confirmed in both themes per the S07 gate`

- [x] **TI03** `dc_whatsapp_controller` toggles the QR-expired state via `hidden`
  - Update the `wa-qr-placeholder` class reference to its `pairing-` rename and change the active/expired target toggle to set `expiredTarget.hidden`/`activeTarget.hidden` instead of `.style.display`; keep the countdown/onerror behavior otherwise unchanged.
  - **Verify**: `Test: when the countdown expires, the active target gains hidden and the expired target loses it (no reliance on style.display); the placeholder-fallback path still fires on QR image error`

- [x] **TI04** `static/app.css` carries no `wa-*` selector and the pairing family is channel-neutral
  - Rename the `wa-*` rule blocks to `pairing-*`; delete `.wa-pre` and `.wa-section` (config blocks now use canonical `.well-deep`; sections use `.well`/`.well-content` plus a shared `pairing-`-prefixed section layout class that carries the internal flex-column + gap the old `.wa-section` provided – well internals are app-specific composition, not a canon gap); add `.pairing-qr-frame` (explicit white background + padding; the img stays bare – no img-level background/border), the shared step-icon and link-URI classes the purged `--text-xl`/`--accent` inlines need, and any other layout utility classes the purged TI01/TI02 inline layout styles need. Edit `static/app.css` only – never the synced files.
  - **Verify**: `Test: grep -c '\.wa-' static/app.css == 0; a .pairing-qr-frame rule with a white background + padding exists while .pairing-qr-img carries no background or border (bare image); a shared pairing-section layout class exists with flex column + gap; grep for '.wa-pre' and '.wa-section' in static/app.css returns nothing`

- [x] **TI05** Channel-detail template uses the `hidden` attribute, canonical wells, and the canonical layout family
  - In `channel_detail.html`: convert `#channel-restart-banner`'s `style="display: none"` to the `hidden` attribute; render the `.channel-sub-card` panel sub-groups as canonical wells – **keep** the `.channel-sub-card` class token (it is the hook for its own `h3` styling and for the sibling semantic classes, and `.channel-mention-section` is queried by `dc_settings_controller.js` and must survive) but add `.well`/`.well-content` to each sub-group and **strip** `.channel-sub-card`'s own box-model rules from `static/app.css` (the two duplicate blocks – the shared `border-radius` rule and the flex-column/gap/padding/`bg-mantle`/border block) so the well owns the box; the surviving `.channel-sub-card` app.css remnant covers only the `h3`/semantic bits. Migrate `.page-content`/`.page-inner` to `.content-area`/`.content-inner` (leave the shared app.css rule in place – not the last consumer). Do not add the hero identicon (S13).
  - **Verify**: `Test: rendered channel_detail HTML uses hidden on #channel-restart-banner (no style="display: none"), uses class="content-area"/"content-inner" (no page-content/page-inner), renders each panel sub-group with class="well"/"well-content" while retaining the channel-sub-card token (with .channel-mention-section still present for the controller query), and contains no identicon; static/app.css has no .channel-sub-card box-model rule (no bg-mantle/padding/flex-column block) – only the h3/semantic remnant survives`

- [x] **TI06** `dc_settings_controller.showChannelRestartBanner` drives the `hidden` attribute
  - Change `showChannelRestartBanner()` to set `banner.hidden = false` instead of `banner.style.display = ''`, matching the TI05 template change.
  - **Verify**: `Test: invoking showChannelRestartBanner() removes the hidden attribute from #channel-restart-banner (asserted against banner.hidden === false), not a style.display write`

- [x] **TI07** Embedded assets and pairing route tests reflect the renamed markup
  - Run `dart run dev/tools/embed_assets.dart` after the template/static/controller edits; update `test/web/signal_pairing_routes_test.dart` and `test/web/whatsapp_pairing_routes_test.dart` for the `pairing-*` class names / `well-deep` / `hidden` assertions.
  - **Verify**: `Test: git diff --exit-code on lib/src/generated/embedded_assets.g.dart is clean after regen; dart test test/web/signal_pairing_routes_test.dart test/web/whatsapp_pairing_routes_test.dart passes; the S01 drift check exits 0`

### Testing Strategy
> Level allocation is non-obvious because two of the toggles are controller-driven, not template-rendered.

- Template markup (inline-style-free HTML, `pairing-*` classes, `.well-deep`, `.content-area`, `hidden` attributes) is assertable in the Layer 3 pairing route tests against rendered output strings — extend `test/web/signal_pairing_routes_test.dart` and `test/web/whatsapp_pairing_routes_test.dart`.
- Controller behavior (WhatsApp active/expired `hidden` toggle, `showChannelRestartBanner`) has no Dart render surface — validate via the `visual` profile / UI smoke test per the plan's S09 risk mitigation.

### Validation

- Manual hardware validation of the WhatsApp and Signal pairing flows per `channel-e2e-manual`; QR-frame screenshots in both themes at desktop + 768px (US04 gate). QR-frame rendering is an explicit part of the visual gate.


## Final Validation Checklist

- [x] App-wide grep confirms the pairing/channel hygiene is clear: `grep -rc 'wa-'` on both pairing templates and `grep -c '\.wa-'` on `static/app.css` are `0`; `grep -c 'style="'` on the three touched templates is `0`.
- [x] The S03 scan-bar and loader work on the pairing pages is intact (no `wa-spinner`/`@keyframes wa-spin` reintroduced, `.scan-bar` still present).


## Implementation Observations

- Critic review caught missing `.well-content` composition and duplicate channel-sub-card layout; all six subgroups now rely on the canonical well/content pair.
- Hardware pairing was unavailable; dark/light desktop/768 QR, waiting, scan-bar, channel-well, and hidden-banner states were validated with controlled current-source probes. External device pairing remains a P3 evidence gap.
