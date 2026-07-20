# Design System Compliance Audit — Afterglow Adoption (2026-06-09)

Audit of the DartClaw Web UI (`packages/dartclaw_server/`) against the updated canonical design system (`dev/design-system/`, "Afterglow" revision, uncommitted as of 2026-06-09). Scope: app CSS copies, all 23 templates, 14 Stimulus controllers.

**Paths** (all under `/Users/tobias/Repos/Libs/dartclaw/dartclaw-public/`):

- Canonical: `dev/design-system/{DESIGN.md,tokens.css,components.css,icons.css,assets/}`
- App copies: `packages/dartclaw_server/lib/src/static/{tokens.css,components.css,icons.css}`
- Templates: `packages/dartclaw_server/lib/src/templates/`
- Controllers: `packages/dartclaw_server/lib/src/static/controllers/`

---

## 1. CSS Drift Analysis

### Headline numbers

| File | Canonical | App copy | Drift |
|---|---|---|---|
| `tokens.css` | 7.1 KB (182 lines) | 5.0 KB (144 lines) | App is pre-Afterglow (last touched May 4); ~9 token groups missing, 8 app-only tokens |
| `components.css` | 56.6 KB (1,654 lines, 147 classes) | 138.1 KB (4,527 lines, 652 classes) | 35 canonical classes missing from app; 540 app-only classes; shared classes diverge in content |
| `icons.css` | 22.7 KB | 26.6 KB | App superset: +5 icons (`file-text`, `folder-git`, `gauge`, `workflow`, `wrench`) — upstream candidates |

The app has **zero** Afterglow markers: no `--ambient-*`, no `--noise`, no `translate: 0 -1px` lifts, no `--tracking-*`, no `--glass-bg`, no `steps()` easing, no `@starting-style`, no extended palette, no `--chart-*` (verified by grep across `static/components.css`).

### (a) Canonical rules missing from the app

**Tokens** (`static/tokens.css`):

- Extended palette: `--mauve`, `--teal`, `--sky`, `--pink`, `--lavender` (+ Latte variants)
- Chart ramp: `--chart-1`…`--chart-6`
- Ambient ground: `--ambient-a/-b/-c`, `--noise`, `--noise-opacity`
- Type scale top end: `--text-2xl` (24px display), `--text-3xl` (32px metric)
- Tracking: `--tracking-tight`, `--tracking-caps`
- Glass tier: `--glass-bg`, `--glass-blur`
- Motion: `--transition-spring`

**Component classes** (all 35 absent from `static/components.css`):

`claw-mark`, `claw-loader`, `identicon` + `--1..--6`, `print-in`, `skeleton`, `skeleton-text`, `meter`, `meter-fill` + `--info/--warning/--error`, `terminal-frame` + `-bar/-body/-dots/--crt`, `card-glass`, `kbd`, `pixel-art`, `text-gradient`, `text-error/-warning/-info/-overlay`, `btn-full`, `content-area`, `content-inner`, `section-title`, `session-list`.

**Shared classes whose *content* drifted** (selector exists in both, app body is stale):

| Class | Canonical (Afterglow) | App copy |
|---|---|---|
| `body` | Ambient 3-glow radials + gradient + fixed `body::before` film grain (canonical `components.css:42-63`) | Flat 3-stop gradient only (app `components.css:16-21`) |
| `.btn:hover` | Lighter mix bg + `translate: 0 -1px` + inset top-edge + `shadow-sm` (canonical `:348-355`) | bg/border swap only, no lift, no inset highlight (app `:402-407`) |
| `.btn-primary` | Top-lit vertical gradient + glow on hover (canonical `:357-371`) | Flat accent fill |
| `.card:hover` | Adds `translate: 0 -1px` micro-lift (canonical `:665-672`) | Glow only, no lift (app `:1207-1213`) |
| `.toast` | Glass: `--glass-bg` + `backdrop-filter: blur(...) saturate(1.4)` (canonical `:1305-1322`) | Opaque `--bg-mantle` (app `:1026-1038`) |
| `.sidebar-header .logo` | 4-hue gradient (accent→teal→info→mauve→accent) (canonical `:145-153`) | 2-hue (accent→info→accent) (app `:102-110`) |
| Caps labels | `letter-spacing: var(--tracking-caps)` everywhere | 36 hardcoded values ranging 0.03–0.1em (app `:231,270,511,726,1100,2089,2095…`) |
| `.card-sunken:hover`, `.card-glass:hover` | Explicit `translate: none` (recessed/anchored surfaces never lift) | N/A — no lift system at all |
| Layout containers | `.content-area`/`.content-inner` single family (canonical `:1399-1412`) | Three parallel families: `.page-content`/`.page-inner` (app `:2079-2081`), `.dashboard`/`.dashboard-inner` (`:2019-2020`), `.info-content`/`.info-inner` (`:1910+`) |
| Reduced-motion | Also disables `claw-loader span` | Pre-Afterglow block |

### (b) App-only rules that should be upstreamed or rationalized

**Upstream into canonical** (generic, reusable):

- The 5 extra icons in app `icons.css` (`file-text`, `folder-git`, `gauge`, `workflow`, `wrench`) — already used by nav; canonical icon vocabulary table in DESIGN.md is missing them.
- `--color-claude` brand token (app `tokens.css:40`, used by `.provider-badge-claude` at app `components.css:3360-3363`) — multi-harness provider branding is a real system need; canonicalize as a documented provider-brand token group (e.g. `--brand-claude`, `--brand-codex`) rather than a stray app token. Codex currently borrows `--info`, which collides with semantic info — a provider-brand ramp fixes both.
- `[hidden] { display: none !important; }` reset (app `components.css:7`) — generally useful, canonical lacks it; templates rely on it (`chat.html:61-66`).
- Tab bar, form field family (`.form-input/.form-select/.form-label`), pagination, `.table-scroll` variants — generic primitives the canonical system doesn't define but every dashboard page needs. Decide: promote a curated subset to canonical, or explicitly document them as app-layer.

**Rationalize away** (re-implementations of canonical primitives):

| App rule | Location | Should be |
|---|---|---|
| `.budget-bar`/`.budget-bar-fill` (8px, radius 4px) | app `components.css:2543-2547` | `.meter`/`.meter-fill` (+ `--warning` variant for `.warn`) |
| `.fill-bar`/`.fill-bar-inner` (4px) | app `components.css:2588-2589` | `.meter`/`.meter-fill` |
| `.task-progress`/`.task-progress-fill` | app `components.css:3784-3792` | `.meter`/`.meter-fill` |
| `.workflow-progress-bar`/`-fill` | app `components.css` (workflow section) | `.meter`/`.meter-fill` |
| `.restart-spinner` (circular border-spin) | app `components.css:917-929`, injected by `dc_shell_controller.js:486` | `.claw-loader` (restart overlay = a brand moment) |
| `.wa-spinner` (circular border-spin) | app `components.css:2164-2169` | `.scan-bar` (anonymous in-place sweep) or small `.claw-loader` |
| `.wa-pre` | app `components.css:2170-2173` | `.well-deep` |
| `.summary-stat/.summary-value/.summary-label` | `settings.html:13-53` `<style>` block | `.card.card-metric` + `.metric-value/.metric-label` |
| `.heartbeat-status-badge` | app `components.css:2090-2091` | `.status-badge-success` / `.status-badge` |
| `--weight-semibold: 550` | app `tokens.css:58` (3 uses) | Violates "three weights only" — collapse to 500 or 600 |
| `--radius-sm: 3px` | app `tokens.css:87` (1 use) | Violates two-radius rule — collapse to `--radius` |
| `--color-peach` | app `tokens.css:37` (4 uses) | Alias of `--warning` (identical hex `#fab387`) — delete |
| `--container-wide: 1120px` | app `tokens.css:79` | **Unused** (0 references) — delete or canonicalize deliberately |
| `--sp-0`, `--sp-px` | app `tokens.css:62,64` | Off-scale; inline `0`/`2px` or drop |

**Genuinely app-specific — fine to keep app-side** (~450 of the 540 app-only classes): page feature CSS — `workflow-*` (82 classes), `task-*` (57), `wa-*` (29, shared by WhatsApp + Signal pairing), `guard-*` (24), `channel-*` (24), `tl-*` timeline (17), `composer-*` (11), `login-*` (11), plus scheduling, allowlist, heartbeat, settings groups. These compose canonical primitives and belong with the app — but they should live in a **separate file**, not interleaved with the canonical copy (see sync model below).

### (c) Sync model problem and recommendation

Current model: hand-copied files, **no provenance marker** (app `components.css` header still claims "All values reference design tokens" with no source/date), independently edited on both sides since (app last modified Jun 7; canonical tokens.css May 4 baseline → Jun 9 Afterglow). Drift is structural, not incidental: app-specific rules were appended *into* the copy, so a re-copy now means a 4,500-line manual merge.

**Recommendation — split + verbatim sync:**

1. Split app CSS into `static/design-system.css` (verbatim canonical `components.css`) and `static/app.css` (app-only extensions, loaded after). Same for tokens if app-only tokens survive rationalization (`app-tokens.css`).
2. Provenance header in each synced file: canonical path + sync date + content hash.
3. A `dev` check (shell or Dart, wired into KEY_DEVELOPMENT_COMMANDS verification): `diff` the synced files against canonical and fail on mismatch. Copying stays manual and deliberate (the design system is versioned with the app), but drift becomes loud instead of silent.
4. Upstream-first rule: any new generic class goes to `dev/design-system/` first, then syncs down.

---

## 2. New-Component Adoption Map

Scarcity doctrine applied: one claw moment per view; CRT hero-only; glass only over live content; one entry motion.

| Afterglow element | Where to apply (template + spot) |
|---|---|
| **Mascot assets** (`logo-avatar-512-8bit.png`, exists at repo root `assets/` but **never served by the app**) | `layout.html:5` — favicon is literally empty (`href="data:,"`); serve the avatar. Login card masthead (`login.html:3-6`) above the `❯ DartClaw` wordmark. Empty states (see claw-mark row for split). About/version spot on health dashboard. Always with `.pixel-art`, never below ~32px. |
| **`.claw-mark`** | Empty states currently using emoji codepoints: `tasks.html:104` (`&#9744;`), `projects.html:53` (`&#128194;`), `task_detail.html:183` (`&#128451;`). One mark per view — task detail has two empty states (`:139`, `:183`); give the mark to at most one. `components.html:7,14` empty states keep the `❯_` prompt glyph (sanctioned Unicode identity). |
| **`.claw-loader`** | The "agent thinking" slots: (1) restart overlay — replace `.restart-spinner` markup injected at `dc_shell_controller.js:486`; (2) chat pre-stream wait — `chat.html:97-111` streaming msg before first `delta` arrives; (3) task detail live-activity row `task_detail.html:216-219` next to `task-activity-text` while running. One per view — on task detail pick the activity row, not also the timeline. |
| **`.print-in`** | Message fragments `chat.html:1,7,92,97` (user/assistant msg roots); HTMX-swapped page content `#main-content` swaps (sidebar nav at `sidebar.html:9-10` targets); task cards `tasks.html:37`; workflow run cards `workflow_list.html:39`; toast already has its own slide — leave it. Apply via the shared fragment roots, not per-page. |
| **`.skeleton` / `.skeleton-text`** | Workflow picker list while loading — replace text-only `.workflow-list-loading` (`dc_workflows_controller.js:69-99`, app css `:3900`) with 3 card-shaped skeletons; memory file preview — replace `preview.textContent = 'Loading...'` (`dc_memory_controller.js:124`) with `.skeleton-text` rows; chat "Load earlier" fetch (`chat.html:31-36`). |
| **`.meter` / `.meter-fill--*`** | Consolidate all four bespoke bars: memory budget bar `memory_dashboard.html:19-31` (`budget-bar`, `fill-bar` at `:38-52`); task progress `tasks.html:47-50` and `task_detail.html:221-234`; workflow progress `workflow_detail.html:34-41`. Use `--warning`/`--error` variants for the existing `.warn` budget state. |
| **Glass (`.card-glass`, glass toasts)** | Toasts (`shared.js` toast factory + app css `:1026`) — adopt canonical glass recipe verbatim. `<dialog class="task-dialog">` (`task_form.dart:46`, `project_form.dart:7`; css `:3523-3534`) floats over live content → glass surface + keep `::backdrop`. Composer command/reference palettes `chat.html:62-69` float over the thread → glass. Nothing in-flow gets glass. |
| **`kbd` / `.kbd`** | Composer suggestions/commands area `chat.html:70-77` (e.g. `/` to open commands, Enter-to-send hint); session title rename affordance `topbar.html:4-6`; settings help text. Element selector also upgrades `<kbd>` in rendered markdown for free. |
| **`.identicon--1..6`** | Sidebar session rows `sidebar.html:89-100` (hash session id); channel rows `sidebar.html:25-46` and channel hero `channel_detail.html:10-16` (hash channel id); task agent badge `tasks.html:40` (`task-agent-badge` → identicon + label). Entity identity only — provider stays a badge. |
| **`.terminal-frame` (+`--crt`)** | Plain frame: task artifact diff/data views `task_detail.html:171-175` (`pre.diff-view`, `task-artifact-raw`); workflow step output `workflow_step_detail.html`. CRT modifier: exactly one hero — the login page (`login.html`) is the natural candidate (token paste inside a CRT terminal window = the mascot's screen), or alternatively the chat empty state (`components.html:12-19`). Pick one surface app-wide; routine inline output stays `.well-deep`. |
| **`--chart-1..6` ramp** | No charts exist yet; health `metrics-grid` (`health_dashboard.html:33-35`) and memory overview (`memory_dashboard.html:14-56`) are the first consumers when sparklines/usage breakdowns land. Wire the tokens now so nothing hand-picks hues later. |
| **`display` / `metric-value` type + tracking** | `metric-value` (32px tight): health metric cards (`components.html:25-29` metricCard fragment), memory KPIs `memory_dashboard.html:17,36,46`, session token stats `session_info.html:15-27` (`token-stat-value`), error page code `error_page.html:2`. `display` (24px): empty-state titles, login wordmark. Both need `--text-2xl/3xl` + `--tracking-tight` synced first. |
| **Micro-lifts + `--transition-spring`** | Free with components.css sync: `.btn`, `.card`, task cards, workflow run cards. Verify recessed app surfaces (`.wa-pre`→well, `task-dialog`) don't inherit lifts. |
| **Ambient ground + film grain** | Free with sync (`body` + `body::before`). Verify against `.shell` full-viewport grid — sidebar/topbar are opaque mantle, so the ground shows only in `.messages`/content scroll areas; check banding and the `z-index: -1` grain layer with the app's stacking contexts. |
| **Top-lit `btn-primary`** | Free with sync; highest-traffic spots: Send (`chat.html:83`), New Task (`tasks.html:18`), Sign In (`login.html:20`). |

---

## 3. Violations Inventory

Ordered by severity.

### Loading/feedback patterns (against §Status indicators + Identity)

- **Circular border spinners** — the design system has no spinner; indeterminate = claw-loader / scan-bar / skeleton.
  - `static/components.css:917-929` `.restart-spinner` + `@keyframes spin`; injected markup `dc_shell_controller.js:486`.
  - `static/components.css:2164-2169` `.wa-spinner` + `wa-spin`; used in `whatsapp_pairing.html:38`, `signal_pairing.html:38,124`.
- **Text-only loading** — `dc_memory_controller.js:124` (`'Loading...'`), `.workflow-list-loading` (`workflow list…` text, css `:3900-3904`, toggled `dc_workflows_controller.js:69-99`) → skeletons.
- **Bespoke progress bars** (4 implementations, 3 heights, 2 radii) instead of `.meter`: app css `:2543-2547` (`budget-bar`, 8px/r4), `:2588-2589` (`fill-bar`, 4px/r2), `:3784-3792` (`task-progress`), workflow section (`workflow-progress-bar`). Also `tl:attr="style='width:...'"` inline widths (`tasks.html:49`, `task_detail.html:228`, `memory_dashboard.html:25,40,50`, `workflow_detail.html:36`) — acceptable for dynamic width but should target `.meter-fill`.

### Token/identity violations

- **Raw color**: `static/components.css:3532` `.task-dialog::backdrop { background: rgba(0,0,0,0.5) }` — the only raw color in the file; should derive from `--bg-pit`/`--bg-crust` mix (theme-aware).
- **Hardcoded letter-spacing** ×36 (0.03–0.1em): e.g. app css `:231, :270, :511, :726, :1100, :1374, :2089` (0.1em!), `:2095` — all should be `--tracking-caps` (0.08em).
- **Off-system tokens**: `--weight-semibold: 550` (app `tokens.css:58`; 3 uses) breaks the three-weight rule; `--radius-sm: 3px` (app `tokens.css:87`) breaks the two-radius rule; `--color-peach` duplicates `--warning` exactly.
- **Semantic-color borrowing for brand**: `.provider-badge-codex` uses `--info` (app css `:3364-3367`) — blue simultaneously means "info state" and "Codex" in the same views (e.g. task tables show both status badges and provider badges). Needs a provider-brand token group.
- **Non-token hover**: `.workflow-card:hover { border-color: var(--fg-overlay); ... }` (app css `:3906-3911`) — foreground token as border; canonical card hover uses accent-mix.

### Template hygiene

- **Inline style attributes** — 47 across templates, worst: `signal_pairing.html` ×25 (`:17,21,34,38-40,50,54,60-67,70,78,83,90,103-105,112-114,124,131,142`), `whatsapp_pairing.html` ×12 (`:17,21,34,38-40,77,89,94,105-106,113`). Mostly typography/color that existing utilities cover (`.text-muted`, `.text-xs`; `.text-overlay` arrives with sync). `display:none` toggles (`sidebar.html:109`, `scheduling.html:42,128`, `chat.html:109`, `workflow_detail.html:103,132`, `task_detail.html:194`) should use `hidden` attr (app reset already supports it, `components.css:7`). `scheduling.html:123` inline `margin-top`; `:189` inline `opacity/font-size`.
- **Template-local `<style>` block**: `settings.html:13-53+` — only template with one; `.summary-stat` inside it re-implements `card-metric` with smaller type (16px vs the 32px metric standard).
- **Emoji empty-state icons**: `projects.html:53` (📂), `task_detail.html:139` (💬), `:183` (🗃), `tasks.html:104` (☐). DESIGN.md sanctions 💬/📋/☐ as decorative glyphs, but 📂/🗃 are off-list, and all four are the prime claw-mark/mascot slots (§2).
- **No `.pixel-art` anywhere** — vacuously true today (no pixel assets served), becomes a real rule the moment the mascot ships. Favicon empty at `layout.html:5`.
- **Entry motion**: zero `.print-in`/entry animation for messages or swapped fragments (only toasts animate in). Not the "multiple competing animations" failure mode — the opposite gap: no unified arrival motion.

### Structure/containers

- **Wells unused**: zero `.well*` usage in any template despite being one of the two container families. Ad-hoc substitutes: `.wa-pre` (css `:2170`), `pre.diff-view`, form clusters in scheduling/settings.
- **Three layout-container families** for the same job (violates one-system rule): `.page-content/.page-inner`, `.dashboard/.dashboard-inner`, `.info-content/.info-inner` vs canonical `.content-area/.content-inner`.
- **Status hero / heartbeat one-offs**: `health_dashboard.html:15-25` `.status-hero` and `scheduling.html:8-35` `.heartbeat-card` are custom card-like blocks that predate `card-featured-*` / `card-metric` and re-implement badges (`.heartbeat-status-badge`, css `:2090`).

### Explicitly NOT violations (counter to the brief's assumptions)

- **`window.confirm`** (`dc_projects_controller.js:192`, `dc_shell_controller.js:346,454`, `dc_scheduling_controller.js:403`, `hx-confirm` in `topbar.html:13`) — DESIGN.md §Banners and toasts sanctions `confirm()` for destructive confirmation. Compliant as specced. If a glass modal should replace it, that's a DESIGN.md change first, then an app story.
- **Raw hex in app components.css**: zero (verified) — token discipline in the copy itself is good.
- **Prompt glyph usage** (`components.html:7,14` `❯_`, `login.html:4`, `sidebar.html:3`) — sanctioned Unicode identity.
- **Hover on wells**: no instances found (wells aren't used at all).

---

## 4. Overhaul Story Breakdown (PRD-ready)

All UI-touching stories carry a **visual-validation requirement**: screenshots via the `visual` testing profile, both themes, mobile + desktop, compared per VISUAL-VALIDATION-WORKFLOW; regression pass via UI smoke test (TC-01…TC-31) at phase end.

### Phase 1 — Foundation (sync, ground, motion)

| # | Story | Scope | Affected files | Effort | Visual validation |
|---|---|---|---|---|---|
| 1.1 | **Token sync + rationalization** | Replace app `tokens.css` with canonical; re-add surviving app tokens (provider-brand group) to a small `app-tokens.css`; delete `--color-peach`, `--weight-semibold`, `--radius-sm`, `--sp-0/--sp-px`, `--container-wide` and fix their ~10 use sites | `static/tokens.css`, `static/components.css` (use sites), canonical `tokens.css` (provider-brand upstream) | S | Spot-check all pages, both themes |
| 1.2 | **CSS split + sync mechanism** | Extract app-only rules from `static/components.css` into `static/app.css`; make `static/design-system.css` a verbatim canonical copy with provenance header; add drift-check script to dev verification; update `layout.html` link order; upstream the 5 app icons into canonical `icons.css` + DESIGN.md vocabulary table | `static/components.css` → split, `templates/layout.html:11-13`, new check script, `dev/design-system/icons.css`, `DESIGN.md` | L | Full smoke test — this is the big-bang restyle (ground, glass toasts, lifts, top-lit primary, 4-hue logo all arrive here) |
| 1.3 | **Ambient ground & stacking verification** | Verify film grain `z-index:-1` + `background-attachment: fixed` against `.shell` grid, dialogs, SSE swaps; tune `--noise-opacity` per theme; check banding on large viewport | `static/app.css` adjustments only | S | Dedicated: large-viewport banding, light theme, mobile drawer over ground |
| 1.4 | **Print-in motion** | Add `.print-in` to message fragments and HTMX swap roots; confirm one entry treatment app-wide; reduced-motion pass | `chat.html:1,7,92,97`, `tasks.html:37`, `workflow_list.html:39`, shared fragment roots | S | Chat send/stream, page nav swaps, prefers-reduced-motion |

### Phase 2 — Component adoption per page

| # | Story | Scope | Affected files | Effort | Visual validation |
|---|---|---|---|---|---|
| 2.1 | **Meter consolidation** | Replace `budget-bar`, `fill-bar`, `task-progress`, `workflow-progress-bar` with `.meter`/`.meter-fill--*`; delete the four implementations; keep labels (color never carries the reading alone) | `memory_dashboard.html:19-52`, `tasks.html:47-50`, `task_detail.html:221-234`, `workflow_detail.html:34-41`, `static/app.css`, `dc_tasks_controller.js`/`dc_workflows_controller.js` (width updates) | M | All four bars, warn/error states, indeterminate task progress |
| 2.2 | **Loading states: claw-loader + skeletons** | Restart overlay → claw-loader (`dc_shell_controller.js:486`); chat pre-stream → claw-loader; workflow picker + memory preview → skeletons; retire `.restart-spinner`, `.wa-spinner` → scan-bar | `dc_shell_controller.js`, `dc_workflows_controller.js:69-99`, `dc_memory_controller.js:118-135`, `chat.html`, pairing templates `:38`, `static/app.css` | M | Restart flow, slow-network workflow list, memory preview, one-claw-per-view check |
| 2.3 | **Chat page** | kbd hints in composer; glass command/reference palettes; verify msg tints, streaming cursor, input focus ring against canonical | `chat.html:59-87`, `static/app.css` composer section | M | Composer interactions, palette over scrolling thread |
| 2.4 | **Tasks + task detail** | Identicons for agent badges; meters (from 2.1); `card-tint-*` semantics on status groups; dialog → glass; review-bar buttons to canonical variants (`btn-accept/-reject/-pushback` audit) | `tasks.html`, `task_detail.html`, `task_form.dart:46`, `static/app.css:3523-3534` | M | Running task cards, review flow, dialog over live list |
| 2.5 | **Workflows** | Skeleton loads, meter, terminal-frame for step output, run-card hover fix (`:3906`) | `workflow_list.html`, `workflow_detail.html`, `workflow_step_detail.html`, `static/app.css` | M | Run list, step detail with output |
| 2.6 | **Health + memory dashboards** | `metric-value`/`display` type scale + tracking; chart-ramp wiring for future viz; `status-hero` → `card-featured-*`; collapse `.dashboard` container family → `.content-area` | `health_dashboard.html`, `memory_dashboard.html`, `components.html:25-29`, `static/app.css:2018-2077` | M | KPI rows both themes, status hero states (ok/warn/error) |
| 2.7 | **Settings** | Delete `<style>` block; `summary-stat` → `card-metric`; tracking tokens; kbd in help text | `settings.html:13-53` + body (930 lines, biggest single template) | M | All settings sections, provider summary grid |
| 2.8 | **Channels + pairing** | Purge 37 inline styles (`signal_pairing.html`, `whatsapp_pairing.html`) into classes/utilities; `.wa-pre` → `.well-deep`; wells for form/step sections; rename `wa-*` shared classes to channel-neutral | `signal_pairing.html`, `whatsapp_pairing.html`, `channel_detail.html`, `static/app.css:2129+` | M | Pairing flows (manual hardware steps per channel-e2e-manual), QR frames |
| 2.9 | **Scheduling + projects + session info** | `display:none` → `hidden`; inline margins → classes; heartbeat-card → card-metric/status-badge primitives; token-stat → metric type; container family collapse (`.info-*` → `.content-*`) | `scheduling.html`, `projects.html`, `session_info.html`, `static/app.css` | M | Job/task forms toggle, heartbeat states, session info grid |

### Phase 3 — Brand moments

| # | Story | Scope | Affected files | Effort | Visual validation |
|---|---|---|---|---|---|
| 3.1 | **Serve mascot + favicon** | Ship `logo-avatar-512-8bit.png` as static asset + favicon (sized variants), `.pixel-art` everywhere it renders; replace empty `data:,` favicon | `layout.html:5`, static asset pipeline, `VENDORS.md`-adjacent provenance note | S | Favicon both themes, crisp at 16/32px |
| 3.2 | **Empty states with claw-mark / mascot** | Replace emoji icons with claw-mark (lists) and mascot (app-level empty states); one mark per view; keep `❯_` where sanctioned | `tasks.html:103-107`, `projects.html:52-56`, `task_detail.html:137-145,182-186`, `components.html:6-19` | M | Every empty state, scarcity check per view |
| 3.3 | **Login hero: CRT terminal frame** | Login card inside `terminal-frame--crt` with mascot masthead + `display` type — the app's single CRT moment | `login.html`, `static/app.css:1806-1909` | S | Login both themes, mobile, reduced motion |
| 3.4 | **Identicons rollout** | Sidebar sessions/channels + channel hero; hash util in `shared.js`; entity-not-state discipline check | `sidebar.html`, `channel_detail.html:10-16`, `static/controllers/shared.js` | M | Sidebar density, color collision sanity across 6 variants |
| 3.5 | **Docs + deviation sync** | Update `dev/design-system/DESIGN.md` (icon vocabulary, provider-brand tokens, any deviations found), wireframes `deviations.md`, user-guide screenshots, architecture doc "Current through" markers | private `docs/wireframes/deviations.md`, public `dev/design-system/`, `docs/guide/` | S | n/a (doc story) |

Sequencing notes: 1.1 → 1.2 are strictly ordered and gate everything else; 2.1/2.2 before per-page stories (they delete shared CSS); 3.x after Phase 2 so brand moments land on compliant pages. Phase boundaries are natural release/squash-merge points.

---

## 5. Quick Reference — Page-by-Page Compliance

"Good" = composes canonical primitives correctly, needs only synced-CSS pickup; "partial" = mixes canonical + bespoke; "poor" = mostly bespoke or hygiene violations.

| Page | Template | Compliance | Top 3 fixes |
|---|---|---|---|
| Chat | `chat.html` | **Good** | 1. claw-loader pre-stream + print-in on messages; 2. glass command/reference palettes + kbd hints; 3. `style="display:none"` → `hidden` (`:109`) |
| Tasks | `tasks.html` | **Partial** | 1. `task-progress` → `.meter`; 2. identicon for agent badge (`:40`); 3. claw-mark empty state (`:104`) |
| Task detail | `task_detail.html` | **Partial** | 1. `budget-bar` → `.meter` (`:221-234`); 2. terminal-frame for diff/raw artifacts (`:171-175`); 3. one claw moment — activity row loader (`:216`), emoji empty states out (`:139,183`) |
| Workflows (list+detail) | `workflow_list.html`, `workflow_detail.html` | **Partial** | 1. skeleton load (controller `:69-99`); 2. `workflow-progress-bar` → `.meter`; 3. fix non-token card hover (css `:3906`) |
| Memory | `memory_dashboard.html` | **Partial** | 1. `fill-bar`/`budget-bar` → `.meter`; 2. `metric-value` 32px scale + tracking; 3. skeleton for preview loads (controller `:124`) |
| Settings | `settings.html` | **Poor** | 1. delete `<style>` block (`:13-53`); 2. `summary-stat` → `card-metric`; 3. tracking tokens + kbd in help text |
| Sessions (info) | `session_info.html` | **Partial** | 1. `token-stat-value` → metric type; 2. collapse `.info-*` containers → `.content-*`; 3. wells for stat groupings |
| Scheduling | `scheduling.html` | **Poor** | 1. inline styles (`:123,189`) + `display:none` toggles → `hidden`; 2. heartbeat-card → canonical card/badge primitives; 3. forms into `.well-content` |
| Canvas/dialogs (task/project forms) | `task_form.dart`, `project_form.dart` | **Partial** | 1. dialog → `card-glass` treatment; 2. `::backdrop` raw rgba (css `:3532`) → token mix; 3. workflow-picker cards to canonical hover |
| Health | `health_dashboard.html` | **Good** | 1. `status-hero` → `card-featured-{color}`; 2. metric type scale; 3. chart-ramp wiring for metrics |
| Projects | `projects.html` | **Good** | 1. claw-mark empty state (`:53`); 2. print-in on cards; 3. confirm dialog stays (sanctioned) — just glass the add-project dialog |
| Login | `login.html` | **Partial** | 1. CRT terminal-frame hero + mascot; 2. `display` type for wordmark; 3. btn-primary top-lit (free with sync) |
| Pairing (WhatsApp/Signal) | `whatsapp_pairing.html`, `signal_pairing.html` | **Poor** | 1. purge 37 inline styles; 2. `wa-spinner` → scan-bar; 3. `.wa-pre` → `.well-deep`, channel-neutral class names |
| Channel detail | `channel_detail.html` | **Good** | 1. identicon in hero (`:10-16`); 2. inline `style="display: none"` (`:256`) → `hidden`; 3. wells for panel sub-groups |
| Shell (sidebar/topbar/layout) | `sidebar.html`, `topbar.html`, `layout.html` | **Good** | 1. favicon + mascot (`layout.html:5`); 2. 4-hue logo gradient (free with sync); 3. identicons on session rows; archive list `display:none` (`sidebar.html:109`) → `hidden` |
