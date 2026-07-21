# Identicons rollout

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S13

## Feature Overview and Goal

**Intent**: Give every session, channel, and task-agent a glanceable, always-consistent visual fingerprint so operators can tell entities apart at a glance in dense lists — without the color ever implying status.

**Expected Outcomes**:

- [OC01] Every sidebar session row and sidebar channel row shows a deterministic dual-hue `.identicon` whose variant is derived from the entity's stable id; the same entity renders the same variant on every initial load and every HTMX/OOB sidebar swap.
- [OC02] The channel-detail hero carries an identicon for the channel it configures, and each task agent badge renders an identicon beside its existing text label (the provider badge stays a separate badge).
- [OC03] Identicon variant is a pure function of entity identity — never of state — computed by a single dependency-free hash utility in `shared.js` that drives both server-rendered rows and any client-injected rows.


## Required Context

### From `plan.json` – "bindingConstraints: FR5 – glass & identicons"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr5-per-page-component-adoption -->
<!-- extracted: 7d948b65 -->
> Glass is used only over live content (never in-flow); identicons encode entity identity only, never state.

### From `plan.json` – "bindingConstraints: NFR – zero-npm / server-first"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### From `plan.json` – "bindingConstraints: NFR – mobile parity"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.

### From `plan.json` – "sharedDecisions: Identicon ownership"
<!-- source: dev/bundle/docs/specs/0.22/plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> S13 solely owns the identicon rollout — hash utility in shared.js, sidebar session/channel rows, channel hero, and task agent badges. S05 and S09 explicitly exclude identicons even where the audit adoption map mentions them for their pages.

### From `dev/design-system/DESIGN.md` – identicon contract
<!-- source: dev/design-system/DESIGN.md#identicons -->
<!-- extracted: 7d948b65 -->
> `.identicon` + `.identicon--1`…`--6` — deterministic dual-hue gradient avatars for agents, sessions, and channels. Pick the variant as `hash(entityId) % 6 + 1` so the same entity always renders the same colors; content is 1–2 initials. Sized via `font-size` on the element. Identicons are the sanctioned place where the extended palette appears as a fill — they identify *which* entity, never *what state* it's in.


## Deeper Context

- `dev/bundle/docs/specs/0.22/audit-design-system-compliance.md#2-new-component-adoption-map` – the `.identicon--1..6` row: exact target spots (sidebar session/channel rows, channel-detail hero, `task-agent-badge`). Audit line numbers are stale — locate by selector/class.
- `plan.json#sharedDecisions` "CSS layering & sync contract" – S13 adds/edits app CSS only in `static/app.css`; never touch synced `design-system.css`/`tokens.css`. The `.identicon` classes already arrive with the S01 canon sync; S13 needs no new identicon CSS.
- `packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js` – `connect()` + the `htmx:afterSwap` handler already re-run `renderMarkdown()` / `initCustomSelects(document)`; this is the progressive-enhancement seam identicon application follows, extended to the `handleHistoryRestore` / `handleHistoryCacheMissLoad` history entry points so browser back/forward restores re-enhance identicon mounts too.


## Acceptance Scenarios

- [x] **S01 [OC01,OC03] [TI01,TI02,TI03] Sidebar session rows get deterministic per-entity identicons**
  - **Given** the shell is loaded with two chat sessions whose ids hash to different variants
  - **When** the sidebar renders and enhancement runs
  - **Then** each session row contains a `.identicon` element carrying exactly one `.identicon--N` class where `N == hash(sessionId) % 6 + 1` (an integer in 1..6) and 1–2 initials from the session title, and the two rows show different variants
  - **And** reloading the page renders each session's identicon with the identical variant

- [x] **S02 [OC01] [TI02,TI03] Channel-row identicon survives an OOB sidebar swap unchanged**
  - **Given** a channel session row showing identicon variant `N`
  - **When** the operator navigates and the sidebar is replaced via `hx-select-oob="#sidebar"`
  - **Then** the same channel row re-renders with the same `.identicon--N` variant (stable across swaps)
  - **And** the same row still carries `.identicon--N` after an htmx history restore (browser back/forward through the history cache – `handleHistoryRestore` / `handleHistoryCacheMissLoad`)

- [x] **S03 [OC02] [TI04] Channel-detail hero shows the channel's identicon**
  - **Given** the WhatsApp channel-detail configuration page
  - **When** it renders
  - **Then** the `.channel-detail-hero` contains a `.identicon` element whose variant derives from the channel identity (`channelType`), and the Signal channel-detail hero carries a distinct `data-identicon-id` (the hash input differs per channel; the resolved variant may collide across the 6 variants and that is acceptable)

- [x] **S04 [OC02,OC03] [TI05] Task agent badge is identicon + label, provider stays a separate badge**
  - **Given** a running task with `agentLabel` "Agent #1" and provider `codex`
  - **When** the tasks page renders
  - **Then** the `.task-agent-badge` contains a `.identicon` element plus the "Agent #1" text, and a separate `.provider-badge.provider-badge-codex` element still renders alongside it

- [x] **S05 [OC03] [TI01,TI03] Identicon encodes identity, not state**
  - **Given** a session rendered with identicon variant `N`
  - **When** the same session (same id) is later re-rendered after its state changed (active → archived)
  - **Then** its identicon variant is still `N` — the variant is a function of id alone, unchanged by the state transition

- [x] **S06 [OC03] [TI01] Missing display name still yields a valid identicon**
  - **Given** an entity with a non-empty id but an empty/absent title or label
  - **When** its identicon is computed
  - **Then** `identiconVariant(id)` returns an integer in 1..6 (never `0`, `7`, or `NaN`) and a fallback glyph is shown as initials — no row is left without an identicon and no `.identicon--0`/`.identicon--7` is emitted


## Structural Criteria

- [x] Exactly one identicon hash implementation exists — in `static/controllers/shared.js`; no parallel hash in Dart or another controller (proved by grep).
- [x] The hash utility adds no import and no new runtime dependency — plain JS (zero-npm constraint).
- [x] `identiconVariant` output is bounded to 1..6 for arbitrary and empty-string input (no `identicon--0`/`--7`/`NaN`).
- [x] `.provider-badge` markup and the `provider-badge-<provider>` class binding are unchanged on sidebar rows and task cards (provider stays a badge, per scope).
- [x] Existing sidebar / tasks / channel-detail Layer 2/3 render tests still pass (identicon markup is additive).
- [x] No `style="display"` remains in `sidebar.html` — the archive-list visibility toggle uses the `hidden` attribute (proved by TI06).
- [x] The new `shared.js` identicon utility is the milestone's only net-new runtime JS and adds zero dependencies — it stays trivially within the governance JS-payload ceiling (proved by TI01's no-import Verify).


## Scope & Boundaries

### Work Areas
- `static/controllers/shared.js` — new `identiconVariant(id)` (deterministic `hash(id) % 6 + 1`, empty-safe) and `applyIdenticons(root)` enhancer that fills identicon mount points with the variant class + initials; idempotent (re-run safe on partial swaps).
- `static/controllers/dc_shell_controller.js` — invoke `applyIdenticons(root)` on `connect()`, inside the existing `htmx:afterSwap` handler (alongside `renderMarkdown()` / `initCustomSelects(document)`), and in the `handleHistoryRestore` / `handleHistoryCacheMissLoad` htmx history entry points so browser back/forward restores re-enhance identicon mounts; also retarget the `initArchiveCollapse` visibility writes to `list.hidden` (TI06).
- `templates/sidebar.html` + `templates/sidebar.dart` — identicon mount on session rows (`activeEntries`, `archivedEntries`) and channel rows (`dmChannels`, `groupChannels`), carrying the entity id (`entry.id` / `ch.id`) and initials source; the identicon **replaces** the leading `data-icon` scope glyph – the `data-icon` attribute is removed from those session/channel row links (only those rows; nav rows, archive chevron, new-session button, and archive/delete controls keep theirs), with scope type now conveyed by the sidebar's section grouping. The `.sidebar-archive-list` `display:none` toggle moves to the `hidden` attribute (TI06).
- `templates/channel_detail.html` + `templates/channel_detail.dart` — identicon mount in `.channel-detail-hero`, keyed on the channel identity (`channelType`).
- `templates/tasks.html` — identicon mount inside `.task-agent-badge` (hashes the `agentLabel` string, initials from the same label; keeps the text label); provider badge untouched.
- `static/app.css` — only if identicon sizing within a row/badge needs an app-only tweak; the `.identicon` classes themselves are synced from canon (do not edit `design-system.css`).

### What We're NOT Doing
- Server-side (Dart) variant computation -- the single hash lives in `shared.js` per the plan's identicon-ownership decision; SSR templates emit only the entity id + initials, JS assigns the variant. Accepts that identicons are JS-enhanced (decorative, space reserved to avoid layout shift).
- Any other S05/S09 page-adoption work (glass dialogs, wells, container-family collapse, inline-style purge) -- owned by those stories; S05/S09 deliberately excluded identicons.
- New identicon CSS or palette tokens -- `.identicon--1..6` and the extended palette arrive with the S01 canon sync.
- Identicons for the sidebar Running/Workflow rows or provider badges -- out of the audit's identicon target set; provider stays a badge.
- A `kbd` hint on the topbar rename affordance -- dropped: there is no existing key-reference copy to mark up, so adding one would be inventing new UX (same vacuous-copy reasoning as S08's kbd non-adoption). Recorded here for S14's deviation sweep. *(Scope-narrowing note for plan cross-cutting review.)*


## Architecture Decision

**Approach**: Progressive enhancement — SSR templates emit a sized `.identicon` mount element carrying the entity id (and initials source); one dependency-free `shared.js` hash assigns the `.identicon--N` variant on load and after every HTMX swap, reusing the existing `dc_shell_controller` enhancement seam.
**Why this over alternatives**: A single JS hash honors the plan's "hash utility in shared.js" decision and avoids a Dart↔JS parity burden; the `htmx:afterSwap` seam already re-enhances swapped content, so it covers SSR rows, OOB sidebar swaps, and client-injected rows uniformly.


## Code Patterns & External References

```
# type | path#anchor                                                   | why needed (intent)
file   | static/controllers/shared.js#sanitizeClassToken               | Existing shared-util export shape — add identicon helpers the same way
file   | static/controllers/dc_shell_controller.js#handleAfterSwap     | Enhancement seam — mirror renderMarkdown()/initCustomSelects re-run on swap
file   | templates/sidebar.dart#mapChannel                             | Context-record shape carrying entry/channel `id` to surface as the hash input
file   | templates/tasks.html#task-agent-badge                         | Badge span that gains an identicon mount while keeping its text label
wire   | dev/design-system/showcase.html                               | Canonical `.identicon .identicon--N` markup + initials content (identicon section)
```


## Constraints & Gotchas

- **Constraint**: `.identicon` classes are synced from canon into `static/design-system.css` -- do not hand-edit synced files; any app-only need goes in `static/app.css` (CSS layering contract).
- **Avoid**: deriving the variant from any status/state field (session active/archived, task status, channel connected) -- Instead: hash the stable entity id only (binding constraint: identity, never state).
- **Critical**: `applyIdenticons` runs on both initial load and every partial `htmx:afterSwap` -- Must be idempotent (skip already-enhanced mounts) so re-fired swaps don't double-render.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** `shared.js` exposes a deterministic, dependency-free identicon variant function and an enhancer
  - `identiconVariant(id)` returns `hash(id) % 6 + 1` (integer 1..6, empty-safe); `applyIdenticons(root)` fills each `.identicon` mount from its `data-identicon-id` with the `.identicon--N` class and 1–2 initials; no new imports. Follow `shared.js#sanitizeClassToken` for export style
  - **Verify**: `Test: identiconVariant('abc') is stable across calls and in 1..6; identiconVariant('') in 1..6 (never 0/7/NaN); two distinct ids can yield different variants; grep shows no import added to shared.js and no other hash-to-variant implementation outside shared.js`

- [x] **TI02** The shell applies identicons on load, after every swap, and on htmx history restores
  - Call `applyIdenticons` in `dc_shell_controller.connect()`, in the `htmx:afterSwap` handler beside `renderMarkdown()`, and in the two htmx history entry points – `handleHistoryRestore` and `handleHistoryCacheMissLoad` – so browser back/forward through the htmx history cache re-enhances identicon mounts; enhancement is idempotent
  - **Verify**: `Test: after an OOB sidebar swap, session/channel rows carry a .identicon--N class (1..6); after an htmx history restore and a history cache-miss load, the restored sidebar rows still carry .identicon--N; re-firing afterSwap does not add a second identicon element`

- [x] **TI03** Sidebar session and channel rows render an identicon mount for their entity (identicon replaces the scope glyph)
  - `sidebar.html` session rows (`activeEntries`, `archivedEntries`) and channel rows (`dmChannels`, `groupChannels`) emit a `.identicon` mount carrying `data-identicon-id` = the entity id and an initials source from the title; thread the id through `sidebar.dart` records (`mapChannel`, active/archive maps). The identicon **replaces** the leading `data-icon` scope glyph on those rows: remove the `data-icon` attribute from the session/channel row links (only those rows – nav rows, archive chevron, new-session button, and archive/delete controls keep their `data-icon`); scope type is conveyed by the sidebar's section grouping
  - **Verify**: `Test: rendered sidebar HTML has one .identicon mount per session and channel row with data-identicon-id equal to the session id, and those rows carry no data-icon attribute; provider-badge markup unchanged`

- [x] **TI04** Channel-detail hero renders an identicon for the channel
  - `channel_detail.html` `.channel-detail-hero` emits a `.identicon` mount keyed on `channelType`; thread `channelType` (already in context) as the hash id
  - **Verify**: `Test: channel_detail render for whatsapp includes a hero .identicon mount with data-identicon-id="whatsapp"; signal render carries data-identicon-id="signal"; google_chat render carries data-identicon-id="google_chat" (distinct hash input per channelType, not necessarily a distinct variant)`

- [x] **TI05** Task agent badge renders an identicon beside its label; provider badge unchanged
  - `tasks.html` `.task-agent-badge` gains a `.identicon` mount whose `data-identicon-id` is the `agentLabel` string (`Agent #1` / `Primary (#1)`), with initials derived from that same label, and keeps the `agentLabel` text; hashing the label keeps the identicon's color in agreement with the visible label beside it (pool-slot recycling accepted). The sibling `.provider-badge.provider-badge-<provider>` is untouched
  - **Verify**: `Test: tasks render shows .task-agent-badge containing a .identicon mount whose data-identicon-id equals the agentLabel string plus the agentLabel text, with a separate .provider-badge element still present`

- [x] **TI06** Sidebar archive-list visibility uses the `hidden` attribute (shell hygiene, rides the sidebar/controller edits)
  - In `sidebar.html`, change the `.sidebar-archive-list` `style="display: none;"` to the `hidden` attribute; in `dc_shell_controller.js#initArchiveCollapse`, replace the two `list.style.display = … ? 'none' : ''` writes with `list.hidden = …` (collapsed→`true`, expanded→`false`). Behavior (collapsed by default, toggled by the archive button, `force-expanded` override) is unchanged; the `[hidden]` reset already ships app-side (S01).
  - **Verify**: `Test: grep sidebar.html finds no style="display" (the archive list uses hidden); dc_shell_controller.js initArchiveCollapse sets list.hidden and no longer sets list.style.display; toggling archived collapse still shows/hides the list`


### Validation

- Visual validation in both themes at desktop + 768px: sidebar density with identicons (touch targets ≥48px on mobile), color-collision sanity across the 6 variants, channel-detail hero, and task cards — per the story's visual gate and mobile-parity constraint.
- Sidebar glyph-removal gate: because the identicon replaces the `data-icon` scope glyph on session/channel rows, the visual gate explicitly evaluates sidebar density and row legibility in **both themes**; if the change reads as a UI/UX degradation, revisit via an upstream design-system fix, not an ad-hoc local tweak.


## Final Validation Checklist

- [x] No identicon variant/class is bound to a state field anywhere (grep the touched templates/controllers for status/active/state-driven `identicon--` assignment) — identity-only.


## Implementation Observations

- Dark/light desktop and 768px controlled current-source validation covered sidebar session/channel rows, channel hero, and task-agent badge. All six variants rendered, identity stayed stable through swap/history re-enhancement, scope glyphs stayed removed, provider badges remained separate, and no overflow occurred. Clean headless Chrome measured mobile session links and delete controls at exactly 48×48px in both themes.

#### DECISION NOTE: sidebar-identicon-replaces-glyph

Decision-Key: sidebar-identicon-replaces-glyph
Altitude: story-scope
Affected surface: Sidebar session rows and channel rows (templates/sidebar.html + templates/sidebar.dart)
Decision: The identicon becomes the SOLE leading marker on sidebar session and channel rows: the data-icon scope glyph comes off those rows; scope type remains conveyed by the sidebar's section grouping.
Rationale: Guard – the visual gate explicitly evaluates sidebar density and row legibility in both themes; if the change reads as a UI/UX degradation, revisit via an upstream design-system fix, not an ad-hoc local tweak.
Evidence: Ratified by owner during 0.22 preflight, 2026-07-20.

#### DECISION NOTE: agent-badge-hash-input

Decision-Key: agent-badge-hash-input
Altitude: story-scope
Affected surface: Task agent badges (templates/tasks.html .task-agent-badge)
Decision: Task agent-badge identicons hash the agentLabel STRING ('Agent #1' / 'Primary (#1)'); initials derive from the same label. Pool-slot recycling semantics are accepted.
Rationale: The identicon's color always agrees with the visible label beside it, matching the plan's identicon+label pairing; accepting pool-slot recycling is consistent with labeling by slot.
Evidence: Ratified by owner during 0.22 preflight, 2026-07-20.
