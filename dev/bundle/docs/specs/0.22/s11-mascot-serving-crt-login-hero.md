# Mascot Serving & CRT Login Hero

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S11

## Feature Overview and Goal

**Intent**: DartClaw's 8-bit crab mascot is never served today (favicon is empty `data:,`, the login page carries no brand), so the product reads as unfinished — surface the mascot as the favicon and as the app's single CRT login hero so the UI feels distinctive and complete.

**Expected Outcomes**:

- [OC01] The favicon is the served mascot avatar (crisp at 16/32px), replacing the empty `data:,` — served through the embedded static-asset route so it works in a compiled AOT binary, not just a source checkout.
- [OC02] The login page is the app's single CRT surface: the login card sits inside `terminal-frame--crt` with a `.pixel-art` mascot masthead above a display-type wordmark.
- [OC03] The mascot always renders with `.pixel-art` and never below ~32px; the login hero passes visual validation in both themes, at 768px, and under `prefers-reduced-motion`.


## Required Context

### From `prd.md` – FR6 acceptance criteria (mascot/favicon/CRT)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr6-brand-identity-surfaced -->
<!-- extracted: 7d948b65 -->
> **Acceptance Criteria**:
> - Favicon is the mascot avatar (crisp at 16/32px); no empty `data:,` favicon.
> - Exactly one CRT surface app-wide (the login hero); mascot never rendered below ~32px or without `.pixel-art`.
> - Empty states use the claw-mark/mascot per the one-mark-per-view rule; the prompt glyph stays where sanctioned.

_(Empty-state rollout is S12, not this story — see What We're NOT Doing.)_

### From `prd.md` – Constraint: scarcity doctrine (binding)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.

### From `prd.md` – Constraint: zero-npm / server-first (binding)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### From `prd.md` – Constraint: mobile parity (binding)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.


## Deeper Context

- `dev/adrs/047-embedded-binary-assets.md#decision` – the embedded data-as-code pipeline that must carry the mascot PNG into the AOT binary; today it is **text-only** (the generator rejects non-UTF-8 files and the map decodes to `String`), so binary support is a prerequisite this story lands.
- `dev/bundle/docs/specs/0.22/audit-design-system-compliance.md#2-new-component-adoption-map` – Mascot / `terminal-frame (+--crt)` rows: favicon spot (`layout.html`), login masthead, `.pixel-art` discipline, one-CRT-per-app rule.
- `dev/bundle/docs/specs/0.22/plan.json` sharedDecisions "Mascot asset pipeline" – S11 establishes how pixel-art brand assets are served; S12 consumes the same pipeline. "CSS layering & sync contract" – S11 edits `static/app.css` only; never the synced `design-system.css`/`tokens.css`.
- `dev/design-system/DESIGN.md` § Terminal frame – the canonical structure `.terminal-frame` > `.terminal-frame-bar` (`.terminal-frame-dots` + optional contextual title) + `.terminal-frame-body`, with the `--crt` scanline/vignette rendered on `.terminal-frame-body::after` **only**. The login hero must follow this nesting or the CRT overlay silently no-ops. The typography table there defines the display scale (24px / `600` / `-0.02em` tracking); the brand-asset table sets the mascot render rules (`.pixel-art`, never below ~32px, original 512px source scaled down).


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01,TI02,TI03] Favicon served as a real PNG through the embedded route**
  - **Given** a compiled/embedded server (assets served from the generated map, not the dev filesystem)
  - **When** a client requests the mascot favicon asset under `/static/`
  - **Then** the response is `200` with `Content-Type: image/png` and a body whose bytes equal the source mascot PNG (a text-only handler that UTF-8-encodes `String` content would corrupt the bytes and fail this)

- [x] **S02 [OC01] [TI04] Layout head points the favicon at the mascot**
  - **Given** any page rendered through `layoutTemplate` (login and all dashboard pages share it)
  - **When** the `<head>` is inspected
  - **Then** it contains a `<link rel="icon">` whose `href` is the served mascot PNG path and there is no `href="data:,"` anywhere in the head

- [x] **S03 [OC02] [TI05] Login page is the CRT hero**
  - **Given** the login page
  - **When** it is rendered
  - **Then** the login card is wrapped by the canonical terminal-frame structure — `.terminal-frame.terminal-frame--crt` > `.terminal-frame-bar` (with `.terminal-frame-dots` and a short contextual title) + `.terminal-frame-body` around the card content (a flat `terminal-frame--crt` on the card would no-op, since the CRT overlay renders on `.terminal-frame-body::after`) — a `.pixel-art` mascot masthead renders above the wordmark, and the wordmark uses the canonical display type

- [x] **S04 [OC02,OC03] [TI05] Exactly one CRT surface app-wide (scarcity doctrine)**
  - **Given** all server templates and `static/app.css`
  - **When** grepping for `terminal-frame--crt`
  - **Then** exactly one template (login) applies it — no other view introduces a CRT surface

- [x] **S05 [OC03] [TI05] Login hero renders correctly across themes, mobile, and reduced motion**
  - **Given** the login page in dark and light themes, at 768px width, and with `prefers-reduced-motion: reduce`
  - **When** it is visually validated
  - **Then** the mascot stays crisp (`.pixel-art` / `image-rendering: pixelated`) and never smaller than ~32px, the token input font is ≥16px, there is no horizontal overflow at 768px, and no animation regression appears under reduced motion

- [x] **S06 [OC01] [TI01] Binary asset embeds without breaking the text pipeline**
  - **Given** a non-UTF-8 PNG placed under `packages/dartclaw_server/lib/src/static/`
  - **When** `dart run dev/tools/embed_assets.dart` runs
  - **Then** it completes without the `asset is not valid UTF-8` abort, the PNG is embedded as byte-exact binary, and every existing text asset (templates/CSS/JS) still round-trips unchanged through the text map


## Structural Criteria

- [x] The embedded-asset drift gate (`packages/dartclaw_server/test/generated/embedded_assets_test.dart`) is green with the mascot PNG present — the generated map is byte-in-sync with the source tree.


## Scope & Boundaries

### Work Areas
- `dev/tools/embed_assets.dart` + `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` — binary-asset support (route allowlisted extensions like `.png` into a second, bytes-typed generated map) + regenerated maps.
- `packages/dartclaw_server/lib/src/embedded_static_handler.dart` — accept the bytes map as a second parameter and serve binary bytes with an `image/png` content-type (new `.png` case in `_contentType`).
- `packages/dartclaw_server/lib/src/server.dart` — the `_mountStaticRoutes` embedded-handler call site (~:327) passes the new binary (bytes) map alongside `embeddedServerAssets`.
- `packages/dartclaw_server/lib/src/static/` — mascot PNG variant(s) placed here (single source for both dev filesystem serving and embedded generation).
- `packages/dartclaw_server/lib/src/templates/layout.html` — favicon `<link rel="icon">` → served mascot (replaces `href="data:,"`).
- `packages/dartclaw_server/lib/src/templates/login.html` + `static/app.css` login section — `terminal-frame--crt` wrapper, `.pixel-art` mascot masthead, display-type wordmark.
- `packages/dartclaw_server/test/{generated/embedded_assets_test.dart,static/embedded_static_routes_test.dart}` — extend to cover binary/PNG serving.

### What We're NOT Doing
- Empty-state mascot / claw-mark usage — deferred to S12 (consumes this story's pipeline).
- Identicons — S13 owns them; the login hero uses CRT, not identicons.
- Editing the synced `design-system.css` / `tokens.css` — `terminal-frame`, `terminal-frame--crt`, and `.pixel-art` arrive from canon via S01; this story only composes them in app markup + `app.css`.
- A generic mascot placement on the health/about spot mentioned in the audit — out of this story's favicon+login scope; not required by FR6 acceptance criteria.
- Adding a `/favicon.ico` route — an explicit `<link rel="icon">` to the served PNG satisfies the requirement without new routing.


## Architecture Decision

**Approach**: Extend the ADR-047 embed pipeline with a parallel binary channel — the generator routes files by **extension allowlist** (`.png` initially; extending the allowlist is a one-line edit), never by decode-probe, emitting the allowlisted files into a second, bytes-typed generated map while non-allowlisted files must still decode as UTF-8 or the build aborts loudly (preserving the existing mis-encoding safety net). The embedded static handler takes that bytes map as a second parameter alongside the text map and serves its hits with an extension-derived content-type (`image/png`); the existing `Map<String, String>` text contract (consumed by `loader.dart`) stays unchanged, and `server.dart`'s static-mount call site passes both maps. The favicon/mascot ships as a committed pixel-art PNG variant under `lib/src/static/`, produced offline (no build step). See ADR: dev/adrs/047-embedded-binary-assets.md.
**Why this over alternatives**: A parallel bytes map is the smallest change that keeps every text consumer's `String` contract intact; unifying all assets onto a bytes map would ripple through `loader.dart` and every template reader for no benefit.


## Constraints & Gotchas

- **Critical**: The embed generator (`embed_assets.dart#_collectBundle`) currently calls `utf8.decode(bytes)` and throws `asset is not valid UTF-8` on any binary file; the generated map's `operator[]` returns `utf8.decode(base64Decode(...))` (a `String`), and `embedded_static_handler` passes `String` to `Response.ok` (shelf UTF-8-encodes it). All three assume text — must handle byte-exact PNG on every hop, or the favicon silently corrupts in embedded/AOT mode. Dev filesystem serving (`createStaticHandler`) already handles PNG natively; the gap is the embedded path only.
- **Constraint**: Favicon crispness at 16/32px needs a purpose-sized pixel-art variant (the source is 512px); downscaling the 512px source in-browser will not stay crisp. Produce the sized variant with nearest-neighbor and commit it — do not add a runtime/build resize step (zero-npm).
- **Avoid**: Re-running `dart run dev/tools/embed_assets.dart` is mandatory after placing the PNG; forgetting is caught only by the CI drift gate, not at edit time.
- **Note**: Canon exposes no `.display` CSS class — only design tokens. Compose the wordmark's display scale locally in `static/app.css` on the login wordmark selector from tokens: `--text-2xl` (24px) size, `600` weight, `--tracking-tight` (per DESIGN.md's typography table). This is page-local composition, not a canon gap — don't wait on an S01 `.display` class that doesn't exist.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** The embed pipeline carries binary assets byte-exact alongside text assets
  - Add a binary path to `embed_assets.dart` — route files by **extension allowlist** (`.png` initially) into a second, bytes-typed generated map (`Map<String, List<int>>`) in `embedded_assets.g.dart`, while non-allowlisted files keep the existing hard `asset is not valid UTF-8` abort (the mis-encoding safety net stays) — and extend `embedded_assets_test.dart` to assert byte-exact round-trip for the PNG; keep the text `Map<String, String>` contract for templates/CSS/JS unchanged
  - **Verify**: `Test: dart run dev/tools/embed_assets.dart embeds a .png under lib/src/static/ byte-exact without the "asset is not valid UTF-8" abort; a non-UTF-8 file with a non-allowlisted extension still aborts the build; embedded_assets_test.dart passes with byte-exact PNG bytes and every text asset still round-trips`

- [x] **TI02** The embedded static handler serves PNG bytes with the correct type
  - `createEmbeddedStaticHandler` gains a second parameter for the binary (bytes) map from TI01 alongside the existing text map; on a hit in the bytes map it returns the raw bytes with `Content-Type: image/png` (add the `.png` case to `_contentType`), otherwise it serves text as today; update the `server.dart` `_mountStaticRoutes` call site (~:327) to pass `embeddedServerAssets` plus the new bytes map
  - **Verify**: `Test: GET a .png key returns 200, header Content-Type: image/png, and body bytes equal the source (embedded_static_routes_test.dart)`

- [x] **TI03** The mascot favicon variant is served at a stable static path
  - A pixel-art favicon-sized mascot PNG (16/32px) is generated by a one-off **dev-only Dart script under `dev/tools/`** — its own directory with its own `pubspec.yaml` depending on `package:image`, nearest-neighbor resize from `assets/logo-avatar-512-8bit.png` — run once and the variant committed under `lib/src/static/`, reachable via the static route. Document the exact regeneration command in this task (e.g. `cd dev/tools/<resize-script-dir> && dart pub get && dart run bin/<resize>.dart`) so it is repeatable on any machine, including unattended runs (fully offline, zero-npm). Record provenance — source asset path + generating command — in the script header **and** in a note alongside the committed variant; do **not** add it to `VENDORS.md` (that file tracks third-party vendored assets, not first-party generated brand assets)
  - **Verify**: `Test: GET /static/<mascot-favicon>.png returns 200 with Content-Type: image/png`

- [x] **TI04** The layout favicon is the mascot (empty favicon retired)
  - `layout.html` `<link rel="icon">` points at the served mascot PNG; the `href="data:,"` placeholder is gone
  - **Verify**: `Test: rendered layoutTemplate head contains <link rel="icon"> to the mascot png and contains no href="data:,"`

- [x] **TI05** The login page is the single CRT hero with a pixel-art mascot masthead
  - Wrap the login card in the **canonical terminal-frame structure** (classes from the S01 sync): `.terminal-frame.terminal-frame--crt` > `.terminal-frame-bar` (carrying `.terminal-frame-dots` plus a short contextual title after the dots — e.g. the wordmark/host label, implementer's wording latitude, per the app-wide terminal-frame title convention) + `.terminal-frame-body` wrapping the login card content. The CRT scanline/vignette renders only on `.terminal-frame-body::after`, so a flat `terminal-frame--crt` on the login card (without the `-body` wrapper) would silently no-op. Add a `.pixel-art` mascot masthead above the wordmark, using the original 512px `logo-avatar-512-8bit.png` (committed under `lib/src/static/`) scaled down via `.pixel-art` per DESIGN.md's brand-asset table — the small TI03 favicon variant is for the favicon `<link>` only. Compose the wordmark's display scale on the login wordmark selector from tokens (`--text-2xl` / `600` / `--tracking-tight`; canon has no `.display` class — see Constraints & Gotchas). Login-only app.css tweaks go in `static/app.css`; the mascot masthead renders ≥32px
  - **Verify**: `Test: rendered login HTML nests .terminal-frame.terminal-frame--crt > .terminal-frame-bar (with .terminal-frame-dots and a bar title) + .terminal-frame-body wrapping the card, plus a .pixel-art mascot masthead and the display-type wordmark; grep of lib/src/templates + static/app.css shows terminal-frame--crt in exactly one template (login)`

### Validation

- Visual validation of the login hero in both themes, at 768px, and under `prefers-reduced-motion` (S05) — favicon crispness at 16/32px is visual-only and confirmed here, not by a grep.


## Final Validation Checklist

- [x] `rg "data:," packages/dartclaw_server/lib/src/templates/layout.html` returns no match.
- [x] `rg -rc "terminal-frame--crt" packages/dartclaw_server/lib/src/templates/` reports exactly one template.
- [x] `git diff --stat` shows no change to `static/design-system.css` or `static/tokens.css` (S01-synced files); app CSS changes land only in `static/app.css`.
- [x] No new runtime JS dependency and no client-side build step introduced (zero-npm / server-first).


## Implementation Observations

#### DECISION NOTE: binary-detection-allowlist

Decision-Key: binary-detection-allowlist
Altitude: feature (ADR-047 embed pipeline; spans S11 + S12)
Affected surface: dev/tools/embed_assets.dart binary-channel routing + embedded_assets.g.dart generation
Decision: Route files to the binary channel by extension allowlist (.png initially; extending is a one-line edit), never by decode-probe.
Rationale: Non-allowlisted files must still decode as UTF-8 or the build aborts loudly, preserving the existing mis-encoding safety net.
Evidence: Ratified by owner during 0.22 preflight, 2026-07-20.

#### Visual validation

- Fresh direct-source validation passed in dark and light at 768px with reduced motion: the single CRT hero, pixel-art mascot, favicon variants, overflow, and 16px login input floor all rendered correctly. An earlier stale-server result was invalidated by cache-busted source and computed-style checks.

#### DECISION NOTE: favicon-resize-tooling

Decision-Key: favicon-resize-tooling
Altitude: feature (S11 favicon variant tooling)
Affected surface: dev/tools/ dev-only Dart resize script (own pubspec, package:image) + committed sized mascot variants under lib/src/static/
Decision: Sized mascot variants are produced by a one-off dev-only Dart script under dev/tools/ using package:image in its own pubspec (nearest-neighbor resize), run once with the variants committed; the FIS documents the exact command so regeneration is repeatable on any machine including unattended runs.
Rationale: Zero runtime footprint keeps the zero-npm / server-first constraint intact; committing the pre-sized variants avoids any runtime or build-step resize.
Evidence: Ratified by owner during 0.22 preflight, 2026-07-20.
