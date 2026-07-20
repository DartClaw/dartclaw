# CSS Foundation: Token Rationalization, Verbatim Split, Drift Check

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: Restore the design system as the single, verifiably-synced source of truth for the Web UI — replacing the ~4,500-line hand-drifted CSS copy with a verbatim canonical split plus a loud drift check — so the whole Afterglow restyle lands atomically and future visual regressions are caught mechanically.

**Expected Outcomes**:

- [OC01] The app serves verbatim-synced canonical CSS: `static/design-system.css` equals canonical `components.css` and `static/tokens.css` equals canonical `tokens.css` (modulo a provenance header), with app-only rules isolated in `static/app.css` / `static/app-tokens.css`.
- [OC02] A documented, dependency-free dev drift check exits non-zero (naming the diverging file) on any divergence between synced files and canon, and exits zero after re-sync; it is wired into the dev verification path.
- [OC03] No off-system token remains anywhere in `static/` (grep-clean); provider badges use a canonical provider-brand token group instead of borrowing a semantic state token; the 36 hardcoded `letter-spacing` values use `--tracking-*` tokens.
- [OC04] The big-bang restyle renders unchanged-or-better: the full UI smoke test (TC-01…TC-31) passes and both-theme spot checks hold — ambient ground, glass toasts, micro-lifts, top-lit primary buttons, and the 4-hue logo all arrive with the sync.


## Required Context

### From `prd.md` — "FR1: Synced, drift-checked design-system CSS" (byte-identity)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr1-synced-drift-checked-design-system-css -->
<!-- extracted: 7d948b65 -->
> `design-system.css` is byte-identical to `dartclaw-public/dev/design-system/components.css` (verified by the drift check); `tokens.css` likewise (app-only tokens isolated in `app-tokens.css`).

### From `prd.md` — "FR1: Synced, drift-checked design-system CSS" (drift command)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr1-synced-drift-checked-design-system-css -->
<!-- extracted: 7d948b65 -->
> A documented dev command (wired into the verification path) diffs synced files against canon and exits non-zero on mismatch.

### From `prd.md` — "FR1 acceptance criteria & outputs" (exact file surface)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr1-synced-drift-checked-design-system-css -->
<!-- extracted: 7d948b65 -->
> **Acceptance Criteria**: App-only rules (~450 page-feature classes) live in `app.css`, not interleaved with the synced file. `layout.html` load order updated; all pages render unchanged-or-better after the split.
> **Inputs / Outputs**: Inputs — canonical `dev/design-system/*.css`. Outputs — `static/design-system.css`, `static/app.css`, `static/app-tokens.css` (if needed), a drift-check script, updated `layout.html`.
> **Error Handling**: drift detected → loud failure naming the diverging file; the fix is re-sync (never hand-edit the synced file).

### From `prd.md` — "FR2: Token rationalization & provider-brand canonicalization"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr2-token-rationalization--provider-brand-canonicalization -->
<!-- extracted: 7d948b65 -->
> Remove off-system tokens (`--weight-semibold: 550`, `--radius-sm: 3px`, `--color-peach` [duplicate of `--warning`], unused `--container-wide`, off-scale spacing) and fix their use sites. Canonicalize a documented **provider-brand** token group so Codex's badge no longer borrows semantic `--info` (which collides with the info state in the same views).
> **Acceptance Criteria**: All new canonical tokens available in the app; no off-system token remains (grep-clean). Provider badges use a provider-brand token group (upstreamed to canon); no provider badge uses a semantic state token. 36 hardcoded `letter-spacing` values replaced by `--tracking-*` tokens.

### From `prd.md` — "Assumptions: native-shell accommodations" (FR2 token work)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#assumptions -->
<!-- extracted: 7d948b65 -->
> Two cheap accommodations ride the FR2 token work (upstream-first, to canon before the app): viewport **safe-area inset tokens** (`env(safe-area-inset-*)` wired into the shell/layout paddings) and a reserved **titlebar/drag-region variable** for the desktop shell. No shell-specific UI is built here.

### From `prd.md` — "Constraints: zero-npm / server-first"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### From `prd.md` — "Constraints: mobile parity"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.


## Deeper Context

- `dev/bundle/docs/specs/0.22/audit-design-system-compliance.md#1-css-drift-analysis` — primary technical evidence: missing canonical rules, app-only rules to upstream/rationalize, the sync-model recommendation (split + verbatim + drift check). Read before splitting. **Line numbers are stale** (app `components.css` grew 4,527→5,097 lines); locate rules by selector/class name.
- `dev/bundle/docs/specs/0.22/audit-design-system-compliance.md#2-new-component-adoption-map` — what the verbatim sync delivers app-wide for free (ground, glass toasts, micro-lifts, top-lit primary, 4-hue logo); the "big-bang" surface to spot-check.
- `dev/design-system/DESIGN.md` + `showcase.html` — Afterglow canon reference (token groups, component vocabulary) for reconciling shared-class drift.
- `plan.json#sharedDecisions` — the CSS layering & sync contract, the provider-brand token group (S01 upstreams, S14 documents), and the layout-container-family collapse (canonical `.content-area/.content-inner` arrives with this sync; per-page migration is S04–S10).


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI03,TI04] Verbatim split serves canon**
  - **Given** the Afterglow canon extension is merged into `dev/design-system/` and the CSS is split
  - **When** the drift check compares `static/design-system.css` and `static/tokens.css` against their canonical sources (provenance header excluded)
  - **Then** both bodies are identical to canonical `components.css` / `tokens.css`, and `static/design-system.css` contains no interleaved app-only rules

- [ ] **S02 [OC02] [TI09] Drift check catches divergence and is loud**
  - **Given** the synced files match canon (drift check exits 0)
  - **When** a single character is edited into the body of `static/design-system.css`
  - **Then** the drift check exits non-zero and its output names `design-system.css` as the diverging file; re-syncing from canon restores a zero exit

- [ ] **S03 [OC03] [TI02,TI03,TI05] Off-system tokens gone, provider badges canonicalized**
  - **Given** the split and token rationalization are complete
  - **When** `static/*.css` is grepped for `--weight-semibold`, `--radius-sm`, `--color-peach`, `--container-wide`, `--sp-0`, `--sp-px`, and `--color-claude`
  - **Then** no match remains, and `.provider-badge-codex` resolves its colour from `--brand-codex` (not `var(--info)`) while `.provider-badge-claude` uses `--brand-claude`

- [ ] **S04 [OC03] [TI06] Caps labels use tracking tokens**
  - **Given** the app-only rules live in `static/app.css`
  - **When** `app.css` is grepped for hardcoded `letter-spacing:` values (those not using `var(--tracking-*)`)
  - **Then** zero remain — every uppercase/caps label references `--tracking-caps` or `--tracking-tight`

- [ ] **S05 [OC04] [TI04,TI05,TI11] Big-bang restyle renders unchanged-or-better**
  - **Given** the split is deployed and served (embedded + filesystem)
  - **When** the UI smoke test (TC-01…TC-31) runs in both dark and light themes at desktop and 768px
  - **Then** all cases pass, and the sync-delivered treatments are visibly present — ambient ground, glass toasts, `.btn`/`.card` micro-lifts, top-lit `.btn-primary`, and the 4-hue sidebar logo

- [ ] **S06 [OC02] [TI01,TI07] Icons re-synced after the canon extension**
  - **Given** commit `b8cb03f9` (canon extension, +44 lines to canonical `icons.css`) is merged into canon
  - **When** `static/icons.css` is re-synced from `dev/design-system/icons.css`
  - **Then** `diff dev/design-system/icons.css packages/dartclaw_server/lib/src/static/icons.css` is empty and `design_system_icons_sync_test.dart` passes


## Structural Criteria

- [ ] `layout.html` `<link>` order loads tokens before app-tokens before design-system before app before icons (proved by TI08 Verify).
- [ ] The drift check is invoked from `dev/tools/fitness/run_all.sh` and documented in `KEY_DEVELOPMENT_COMMANDS.md` (proved by TI09 Verify).
- [ ] `embedded_assets.g.dart` is regenerated so `design-system.css`, `app.css`, and `app-tokens.css` are served in embedded mode (proved by TI10 Verify).
- [ ] The drift check adds no build step and no runtime JS dependency — plain POSIX diff/hash or a dependency-free Dart tool (proved by TI09 Verify).
- [ ] The existing `dartclaw_server` test suite stays green after the split (standard exec-spec gate).


## Scope & Boundaries

### Work Areas
- `dev/design-system/` — precondition merge of the canon extension (`b8cb03f9`); upstream the provider-brand token group (`--brand-claude`, `--brand-codex`) into `tokens.css` and extend canonical `.content-inner` in `components.css` with the flex-column + `gap: var(--sp-6)` stack (both before the sync).
- `packages/dartclaw_server/lib/src/static/{tokens.css, app-tokens.css, design-system.css, app.css, icons.css}` — the verbatim split, token rationalization, tracking-token adoption, provider-badge + safe-area wiring, icons re-sync.
- `packages/dartclaw_server/lib/src/templates/layout.html` — CSS `<link>` load order.
- `packages/dartclaw_server/lib/src/templates/signal_pairing.html` — the one off-system-token template use site: inline `var(--radius-sm)` → `var(--radius)` (TI03).
- `dev/tools/fitness/` (new drift-check script, alongside the existing sibling checks) + `dev/tools/fitness/run_all.sh` + `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` — the drift check and its wiring/documentation.
- `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` — regenerated via `dev/tools/embed_assets.dart`.
- `packages/dartclaw_server/test/{static/app_js_test.dart, templates/render_test.dart, templates/source_attribution_test.dart}` — repoint the three tests that hardcode `static/components.css` after the split (otherwise only caught by the blanket green-suite gate): `app_js_test.dart` (`componentsCssPath`) and `render_test.dart` (the `/static/components.css` layout `<link>` assertion) are path renames to the split files; `source_attribution_test.dart` greps `.citation-marker`/`.layer-badge` — app-feature classes that move to `app.css` — so it repoints to `app.css`, not merely a path rename.

### What We're NOT Doing
- Per-page component adoption (glass dialogs, terminal-frame, kbd, metric-value, layout-container migration per page) — S04–S10; this story only makes the primitives available and lands `.content-area/.content-inner` via the sync.
- Ambient-ground stacking/banding tuning and print-in placement on fragment roots — S02; the CSS arrives here, application/tuning is S02.
- Feedback-primitive swaps (meters, claw-loader, skeletons, scan-bar) and deletion of the bespoke bars/spinners — S03; those `.budget-bar`/`.restart-spinner` app rules stay put in `app.css` until S03 removes them.
- Serving the mascot favicon / login CRT hero — S11; `layout.html` keeps its existing favicon here, only the CSS link order changes.
- Completing DESIGN.md documentation of the provider-brand token group and upstreamed icons — S14.


## Architecture Decision

**Approach**: Split the drifted app CSS into a verbatim canonical layer (`design-system.css` ← `components.css`, `tokens.css` ← canonical `tokens.css`) plus an app-only layer (`app.css`, `app-tokens.css`), each synced file topped with a provenance header (source path + sync date + `sha256`). A dependency-free drift check diffs each synced file's body against canon and validates the recorded hash, wired into the fitness gate. Provider-brand and native-shell tokens are upstreamed to canon first, then synced down (upstream-first rule). See PRD Decisions Log.
**Why this over alternatives**: Re-copying on each change is an unmaintainable ~4,500-line manual merge; leaving it drifted compounds divergence — verbatim sync + a loud check restores canon as the single source of truth cheaply.


## Code Patterns & External References

```
# type | path#anchor or ref                                                        | why needed (intent)
file   | packages/dartclaw_server/lib/src/templates/layout.html                    | current CSS <link> order (lines 11-14) + empty favicon (line 5, leave for S11)
file   | packages/dartclaw_server/lib/src/static/components.css#.provider-badge-codex | codex badge borrows var(--info) — the semantic collision to fix with --brand-codex
file   | dev/tools/fitness/run_all.sh                                              | pattern for wiring a new check into the fitness gate (echo + invoke, set -euo pipefail)
file   | packages/dartclaw_server/test/static/design_system_icons_sync_test.dart   | existing strict icons sync guard — must stay green after re-sync
file   | packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart         | checked-in generated output; regen via `dart run dev/tools/embed_assets.dart`
ref    | git b8cb03f9 (branch feat/design-system-afterglow-extension)              | canon extension (design-system files only) to merge before the sync
```


## Constraints & Gotchas

- **Byte-identity vs provenance header**: the synced files carry a leading provenance comment, so they are not literally byte-identical to canon. "Byte-identical" means *modulo the header*: the drift check compares the synced body (header excluded) against canon and validates the header's recorded `sha256` matches the canonical file — resolve this consistently in the check and the header format.
- **Upstream-first / never hand-edit synced files**: any new generic class or token goes to `dev/design-system/` first, then syncs down. The fix for a drift-check failure is always re-sync, never editing `design-system.css` / `tokens.css` / `icons.css` directly.
- **App layer is app-only**: after the split, shared canonical classes (`.btn`, `.card`, `.toast`, `.btn-primary`, layout containers, …) live *only* in `design-system.css`; `app.css` must not redefine them — removing the ~100+ drifted duplicates is the point. Canonical-absent primitives the app needs (`[hidden]` reset, `.form-input`/`.form-select`/`.form-label`, tab bar, pagination, `.table-scroll`) stay in `app.css`.
- **Generated embedded assets**: `embedded_assets.g.dart` is generated — never hand-edit. Run `dart run dev/tools/embed_assets.dart` after the static/template edits or the new split files won't be served in embedded mode (only filesystem/dev mode).
- **Zero-npm drift check**: keep it a plain POSIX `diff`/`sha256sum` shell script or a dependency-free Dart tool. If Dart, run it from a hermetic temp copy to avoid the `dart run` / `native_assets.yaml` race (see LEARNINGS).
- **Stale audit line numbers**: the audit predates ~570 lines of app CSS growth — locate every rule by selector/class name, never by audit line number.
- **Provider token rename**: app `--color-claude` → canonical `--brand-claude`; codex `--info` → `--brand-codex`. The safe-area (`--safe-top/-right/-bottom/-left`) and titlebar (`--titlebar-drag-h`) tokens arrive with the canon-extension merge; this story wires `--safe-*` into the shell/layout paddings in `app.css`.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Canon carries the Afterglow extension (precondition)
  - Merge `feat/design-system-afterglow-extension` (`b8cb03f9`, design-system files only) into `dev/design-system/` on the current branch; the drift-checked sync ships canon→app, so canon must be current first. Brings `.composer`/`.tool-call`/`.approval-card`/`.chip` components, `--syntax-*`, and the `--safe-*` / `--titlebar-drag-h` tokens.
  - **Verify**: `grep -q "\.composer" dev/design-system/components.css && grep -q -- "--safe-top" dev/design-system/tokens.css && grep -q -- "--titlebar-drag-h" dev/design-system/tokens.css`

- [ ] **TI02** Canon defines the provider-brand tokens and extends `.content-inner`
  - Add `--brand-claude` and `--brand-codex` to `dev/design-system/tokens.css` in both the Mocha (default) and Latte theme blocks (full DESIGN.md documentation is S14). `--brand-claude` takes the existing app terracotta value; `--brand-codex` aliases the canonical extended-palette teal (`var(--teal)`) — decorative/identity tier, never a state colour (see DECISION NOTE `codex-brand-color`). Extend canonical `.content-inner` in `dev/design-system/components.css` with `display: flex; flex-direction: column; gap: var(--sp-6)` (matching the retiring `.page-inner`) so migrating pages (S06/S08/S10) inherit section rhythm from the container; this rides the canon-upstream work and syncs down with TI04 (see DECISION NOTE `content-inner-stack-gap`).
  - **Verify**: `grep -c -- "--brand-claude" dev/design-system/tokens.css` ≥ 2 and `grep -c -- "--brand-codex" dev/design-system/tokens.css` ≥ 2 (both theme blocks); each `--brand-codex` aliases teal (`grep -- "--brand-codex" dev/design-system/tokens.css` shows `var(--teal)`); the `.content-inner` rule in `dev/design-system/components.css` carries the stack gap (`grep -A4 "^\.content-inner {" dev/design-system/components.css | grep -q -- "gap: var(--sp-6)"`)

- [ ] **TI03** `static/tokens.css` is verbatim canon; surviving app tokens isolated; off-system tokens gone
  - `static/tokens.css` = verbatim canonical `tokens.css` + provenance header; app-only survivors move to `static/app-tokens.css`. Delete `--weight-semibold`, `--radius-sm`, `--color-peach`, `--container-wide`, `--sp-0`, `--sp-px`, `--color-claude` and fix their use sites (`--weight-semibold`→`--weight-medium`/`--weight-bold`, `--radius-sm`→`--radius`, `--color-peach`→`--warning`) across `static/` **and** the template use site `templates/signal_pairing.html` (inline `border-radius:var(--radius-sm)` → `var(--radius)`).
  - **Verify**: drift check body-diff for `tokens.css` empty; `grep -rE -- "--(weight-semibold|radius-sm|color-peach|container-wide|sp-0|sp-px|color-claude)\b" packages/dartclaw_server/lib/src/static/ packages/dartclaw_server/lib/src/templates/` returns no matches

- [ ] **TI04** `static/design-system.css` is verbatim canonical `components.css`
  - Copy canonical `components.css` verbatim into `static/design-system.css` with a provenance header (source path + sync date + `sha256`). No app-only rule may be interleaved.
  - **Verify**: drift check body-diff for `design-system.css` empty; `grep -q "claw-loader" static/design-system.css && grep -q -- "--ambient" static/design-system.css && grep -q "content-area" static/design-system.css` (Afterglow markers present)

- [ ] **TI05** `static/app.css` holds only app-only rules; provider + safe-area wired
  - Move genuinely app-only rules (~450–540 classes: `workflow-*`, `task-*`, `wa-*`, `guard-*`, `channel-*`, `login-*`, `[hidden]` reset, form-field/tab/pagination primitives) into `app.css`, loaded after `design-system.css`; drop every drifted duplicate of a canonical class. `.provider-badge-claude` uses `--brand-claude`, `.provider-badge-codex` uses `--brand-codex`; wire `--safe-*` into the shell/layout paddings; the titlebar var stays reserved (defined, unused).
  - **Verify**: `.meter`/`.toast`/`.btn-primary` NOT redefined in `app.css` (`grep -E "^\.(meter|toast|btn-primary)\b" static/app.css` empty); `grep -A2 "\.provider-badge-codex" static/app.css` shows `--brand-codex` and no `var(--info)`; `grep -q -- "--safe-" static/app.css`

- [ ] **TI06** No hardcoded letter-spacing in `app.css`
  - Replace the 36 hardcoded `letter-spacing` values (caps/uppercase labels) with `--tracking-caps` (or `--tracking-tight` for display) in `app.css`.
  - **Verify**: `grep "letter-spacing:" static/app.css | grep -vc "var(--tracking"` is `0`

- [ ] **TI07** `static/icons.css` re-synced from canon
  - Re-sync `static/icons.css` from `dev/design-system/icons.css` (now +44 lines post-extension) + provenance header.
  - **Verify**: drift-check body-diff for `icons.css` empty; `dart test packages/dartclaw_server/test/static/design_system_icons_sync_test.dart` passes

- [ ] **TI08** `layout.html` load order updated
  - Update the `<link>` order to: `tokens.css`, `app-tokens.css`, `design-system.css`, `app.css`, `icons.css` (hljs after). Favicon stays `data:,` (S11 owns the mascot favicon).
  - **Verify**: the `<link rel="stylesheet">` lines in `layout.html` appear in that exact order (app-tokens and app after their synced counterparts)

- [ ] **TI09** Drift check exists, is loud, and is wired into verification
  - A dependency-free check (POSIX shell `diff`/`sha256sum` or hermetic Dart) living in `dev/tools/fitness/` alongside the existing sibling checks compares `tokens.css`, `design-system.css`, `icons.css` against their `dev/design-system/` sources (provenance header excluded) and validates each recorded hash; it exits non-zero naming the diverging file on any mismatch. Invoke it from `dev/tools/fitness/run_all.sh` and document the command in `KEY_DEVELOPMENT_COMMANDS.md`.
  - **Verify**: running the check on synced files exits `0`; appending one character to the body of `static/design-system.css` makes it exit non-zero with `design-system.css` in the output; `grep -q "<check-name>" dev/tools/fitness/run_all.sh` and `grep -q "<check-name>" dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`

- [ ] **TI10** Embedded assets serve the split files
  - Regenerate `embedded_assets.g.dart` (`dart run dev/tools/embed_assets.dart`) so `design-system.css`, `app.css`, and `app-tokens.css` are embedded; `layout.html` link order references them.
  - **Verify**: `grep -q "design-system.css" ...generated/embedded_assets.g.dart && grep -q "app-tokens.css" ...generated/embedded_assets.g.dart`; a request to `/static/design-system.css` returns the synced CSS

- [ ] **TI11** Big-bang restyle passes the visual gate
  - After the split, the sync-delivered treatments render app-wide; validate both themes at desktop + 768px per the UI smoke test.
  - **Verify**: UI smoke test TC-01…TC-31 passes in dark and light; spot-check screenshots confirm ambient ground, glass toasts, `.btn`/`.card` micro-lift, top-lit `.btn-primary`, and the 4-hue sidebar logo

### Execution Contract

- TI01 → TI02 must precede all sync tasks (TI03, TI04, TI07) — canon must be current and carry the provider-brand tokens before any canon→app copy.
- TI09's drift check is the authority for TI03/TI04/TI07 body-diff Verifies — implement it early enough to drive those checks, or use an inline `diff` until it lands.
- TI10 (embedded regen) runs after all `static/` edits (TI03–TI08) so the generated map is current.


## Final Validation Checklist

- [ ] Drift check green after full sync; non-zero on an injected one-byte divergence (re-asserts OC02 end-to-end).
- [ ] `grep -rE -- "--(weight-semibold|radius-sm|color-peach|container-wide|sp-0|sp-px|color-claude)\b" packages/dartclaw_server/lib/src/static/ packages/dartclaw_server/lib/src/templates/` returns nothing (grep-clean per FR2, OC03).


## Implementation Observations

#### DECISION NOTE: codex-brand-color

Decision-Key: codex-brand-color
Altitude: spec-local — S01 provider-brand token group, upstreamed to canon `tokens.css` (TI02)
Affected surface: `--brand-codex` / `--brand-claude` in `dev/design-system/tokens.css` (TI02) and their use sites `.provider-badge-codex` / `.provider-badge-claude` in `static/app.css` (TI05)
Decision: `--brand-codex` aliases the canonical extended-palette teal (decorative/identity tier, never a state color); `--brand-claude` keeps the existing app terracotta value.
Rationale: Closes the only unspecified value in the provider-brand token group; the brand tier is decorative/identity, so it never collides with a semantic state token (the `--info` collision FR2 removes).
Evidence: Ratified by owner during 0.22 preflight, 2026-07-20.

#### DECISION NOTE: content-inner-stack-gap

Decision-Key: content-inner-stack-gap
Altitude: spec-local — canonical `.content-inner` extended upstream, riding S01's canon-upstream work and sync (TI01/TI04); consumed by migrating pages S06/S08/S10
Affected surface: `.content-inner` in `dev/design-system/components.css` (canon extension) → synced to `static/design-system.css`; inherited by migrating pages (S06/S08/S10)
Decision: Canonical `.content-inner` is extended upstream in `dev/design-system/components.css` with `display:flex; flex-direction:column; gap: var(--sp-6)` (matching the retiring `.page-inner`), riding this story's canon-upstream work and sync.
Rationale: Migrating pages (S06/S08/S10) inherit vertical section rhythm from the canonical container with no per-page spacing rules — closes the design-system gap without app-layer overrides.
Evidence: Ratified by owner during 0.22 preflight, 2026-07-20; see DECISIONS.md Still Current 'Design-system gap resolution'.
