# Local vendoring of runtime dependencies

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
**Story-ID**: S13

## Feature Overview and Goal

**Intent**: A self-hosted, security-conscious agent runtime currently fetches its interaction layer (htmx), its markdown renderer (marked) and its single deliberate typeface from three external CDNs on every page load – so an air-gapped or offline install silently degrades to a broken UI in system monospace, every page view leaks the operator's IP to Google, and ADR-047's shipped "no network dependency" promise is false.

**Expected Outcomes**:

- [OC01] The Web UI renders and behaves identically with no internet access: JetBrains Mono, HTMX fragment swaps and markdown rendering all work from the binary alone.
- [OC02] A page load contacts no external origin – neither `layout.html` nor the CSP names one, and `font-src` is `'self'`.
- [OC03] A CDN reference cannot be re-introduced silently: an automated check fails on any external subresource in the served surfaces.


## Required Context

### From `docs/specs/0.22.1/prd.md` – "FR8: Local vendoring of runtime dependencies"
<!-- source: docs/specs/0.22.1/prd.md#fr8-local-vendoring-of-runtime-dependencies -->
<!-- extracted: e18cf85 -->
> **Description**: Self-host htmx 2.0.8 (50.0 KB), marked 15 (39.0 KB) and JetBrains Mono 400/500/600 latin + latin-ext woff2 (~30.6 KB each). See [vendoring-analysis.md](vendoring-analysis.md) for the full rationale, cost and mechanics.
>
> **Acceptance Criteria**:
> - [ ] No external origin appears in `layout.html` or the CSP; `font-src 'self'`.
> - [ ] `dev/tools/embed_assets.dart` handles `.woff2` as binary; `embedded_static_handler.dart` serves `font/woff2`.
> - [ ] `VENDORS.md` documents all three with upgrade instructions.
> - [ ] The UI renders identically with all external origins blocked — proven by a new offline smoke check.
>
> **Priority**: Should / P1 *(splits cleanly into its own point release)*

### From `docs/specs/0.22.1/vendoring-analysis.md` – "Mechanics"
<!-- source: docs/specs/0.22.1/vendoring-analysis.md#mechanics--two-code-changes-beyond-dropping-the-files-in -->
<!-- extracted: e18cf85 -->
> Both are easy to miss and would fail silently or confusingly:
>
> 1. **`dev/tools/embed_assets.dart:9`** — `_binaryAssetExtensions` is `{'.png'}`. Without adding `.woff2`, font binaries are embedded as text and corrupted.
> 2. **`packages/dartclaw_server/lib/src/embedded_static_handler.dart:50`** — the `_contentType` switch has no `woff2` case and falls through to `application/octet-stream`; browsers reject the font.
>
> Then:
>
> - Self-hosted `@font-face` rules in `tokens.css` pointing at `/static/`.
> - `<link rel="preload">` for the two weights above the fold (replacing the current `display=swap` + no `preconnect`).
> - `security_headers.dart` CSP tightened: drop `unpkg.com`, `cdn.jsdelivr.net`, `fonts.googleapis.com`; `font-src 'self'`.
> - `VENDORS.md` extended with three entries and their upgrade commands, matching the existing format.

_Deviation, decided here: the `@font-face` rules go in app-owned `app-tokens.css`, not canon `tokens.css` – see Architecture Decision. The `/static/` prefix is likewise replaced by a relative URL – see Constraints & Gotchas._

### From `docs/specs/0.22.1/vendoring-analysis.md` – "Verification gate"
<!-- source: docs/specs/0.22.1/vendoring-analysis.md#verification-gate -->
<!-- extracted: e18cf85 -->
> Run the `visual` profile with all external origins blocked and confirm the UI renders identically to the online case. **This test does not exist today** and should ship with the change — it is the only thing that keeps a future `<link>` to a CDN from silently re-introducing the dependency.

### From `docs/specs/0.22.1/vendoring-analysis.md` – "Font subsetting"
<!-- source: docs/specs/0.22.1/vendoring-analysis.md#font-subsetting -->
<!-- extracted: e18cf85 -->
> Google serves **18 `@font-face` rules** for this request — 6 unicode-ranges × 3 weights. Self-hosting needs only **latin + latin-ext = 6 files**. Swedish `åäö` fall inside the latin range (U+0000–00FF), so 0.23's multi-language work is covered. Cyrillic, Greek and Vietnamese drop to the fallback stack, which is the correct trade for a developer tool.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: canon-first
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: zero-npm / no build step
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `docs/specs/0.22.1/prd.md` – Binding constraint: no backend work
<!-- source: docs/specs/0.22.1/prd.md#constraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: out of scope
<!-- source: docs/specs/0.22.1/prd.md#out-of-scope -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: NFR visual quality
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline


## Deeper Context

- `../dartclaw-public/dev/adrs/047-embedded-binary-assets.md#decision` – the embed pipeline this story extends: checked-in, base64-backed `embeddedServerAssets` text plus `embeddedServerBinaryAssets` bytes (and the workflow package's corresponding maps), with explicit/dev/discovered source-tree assets ahead of the embedded fallback and a CI drift gate; read before touching `embed_assets.dart`.
- `docs/specs/0.22.1/vendoring-analysis.md#rationale-strongest-first` – why all three, not a subset; the htmx-SSE-vendored-but-htmx-core-not incoherence.
- `docs/specs/0.22.1/vendoring-analysis.md#cost` – ~181 KB added to `static/`, ~241 KB base64 in the generated bundle; no fitness gate blocks it (`arch_check.dart` skips `/lib/src/generated/`).
- `../dartclaw-public/dev/testing/profiles/visual/README.md` – starting the `visual` profile on port 3338 and locating its token; the only profile rendering all 23 surfaces.


## Acceptance Scenarios

- [ ] **S01 [OC01,OC02] [TI01,TI02,TI05,TI06,TI09,TI12] The release binary renders and behaves identically with every external origin blocked**
  - **Given** `bash dev/tools/build.sh` has built `build/bin/dartclaw`, the visual seed has been copied into a temporary data directory outside the checkout, and that absolute binary is launched with the temporary directory as both cwd and `--data-dir`, with `serve --port 3338` in its process arguments and no `--dev` or `--source-dir`, forcing the embedded fallback; the browser blocks every request to a non-`localhost` origin (e.g. Chromium started with `--host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost"`)
  - **When** an authenticated operator loads `/`, navigates to `/tasks` through an `hx-get` interaction, and opens the seeded chat session
  - **Then** for each weight 400/500/600, `await document.fonts.load('<weight> 16px "JetBrains Mono"', 'DartClaw 0123')` and the same call with representative latin-ext text `'Pchnąć w tę łódź jeża'` each return a non-empty array whose matching `FontFace` entries report `status === 'loaded'`, `family === 'JetBrains Mono'` and the requested weight; `document.fonts.check(...)` may supplement but cannot replace that proof; the Network panel records successful same-origin `200` loads for `htmx.min.js`, `marked.min.js`, and the latin and latin-ext `font/woff2` file at each weight; the `hx-get` swaps `#main-content` without a full page load, the seeded assistant message renders as HTML rather than literal `**markdown**`, the network log records zero requests to non-`localhost` origins, and the console records zero `error`-level entries

- [ ] **S02 [OC02] [TI07] Every response carries a CSP naming only same-origin sources**
  - **Given** the server is running
  - **When** any response's `Content-Security-Policy` header is read
  - **Then** it contains `font-src 'self'`, `script-src 'self'` plus the inline-theme-script `sha256-` hash, and `style-src 'self' 'unsafe-inline'`, and contains no `https://` substring anywhere

- [ ] **S03 [OC01] [TI03,TI04] A vendored font is served as an intact binary font resource**
  - **Given** the binary is running with `fonts/jetbrains-mono-400-latin.woff2` embedded
  - **When** `GET /static/fonts/jetbrains-mono-400-latin.woff2` is requested
  - **Then** the response is `200` with `Content-Type: font/woff2` and a body byte-identical to the file on disk, beginning with the WOFF2 signature `wOF2` (`0x77 0x4F 0x46 0x32`) – not `application/octet-stream`, and not UTF-8 re-encoded

- [ ] **S04 [OC03] [TI08] Re-introducing a CDN subresource fails the fitness check**
  - **Given** a working tree in which `<script defer="defer" src="https://cdn.jsdelivr.net/npm/marked@15/marked.min.js"></script>` has been pasted back into `layout.html` – once as a single line, and in a second variation with the `src` attribute split across two lines (`src=` ending one line, the quoted URL opening the next)
  - **When** `bash dev/tools/fitness/check_no_external_origins.sh` runs
  - **Then** it exits non-zero and names `layout.html` and the offending line in **both** variations; removing the paste makes it exit `0`

- [ ] **S05 [OC03] [TI08] Legitimate non-subresource URLs are not false positives**
  - **Given** a clean working tree where `signal_pairing.html` still links out via `<a href="https://signalcaptchas.org/registration/generate.html" target="_blank" rel="noopener">`, `icons.css` still carries its `https://lucide.dev` attribution comment, and `VENDORS.md` still carries `https://unpkg.com/...` upgrade commands
  - **When** `bash dev/tools/fitness/check_no_external_origins.sh` runs
  - **Then** it exits `0` – outbound navigation links, comments and upgrade documentation are not subresource loads and must not be flagged


## Structural Criteria

- [ ] `VENDORS.md` documents htmx 2.0.8, marked 15 and JetBrains Mono with version, license, source, file table and an exact upgrade command, in the same per-entry format as the four existing entries; the highlight.js, DOMPurify, htmx-ext-sse and Stimulus entries are unchanged.
- [ ] No canon-owned file (`dev/design-system/tokens.css`, `components.css`, `icons.css`) is edited, and `check_design_system_sync.sh` stays green.
- [ ] No new runtime JS dependency and no build step: the vendored `htmx.min.js` and `marked.min.js` are byte-identical to their upstream releases and nothing in `pubspec.yaml` changes.
- [ ] `dev/tools/fitness/run_all.sh` invokes the new check, so it runs wherever the existing fitness functions run.
- [ ] `dev/architecture/security-architecture.md` no longer describes the CSP as carrying an "explicit CDN allowlist".
- [ ] highlight.js, DOMPurify, Stimulus and `sse.js` keep their current filenames, `/static/` paths and load order.
- [ ] `dev/testing/UI-SMOKE-TEST.md` carries Regression Checks row `R-13` in the table's one-line house style, pointing at a `### R-13 protocol` subsection at the end of the Regression Checks section; together they specify: build then launch `build/bin/dartclaw` from a temporary cwd/data directory with explicit `--port 3338` and no `--dev` / `--source-dir`; block all external origins; prove fonts via `document.fonts.load` plus non-empty matching loaded `FontFace` assertions for weights 400/500/600 and latin/latin-ext text; require successful same-origin WOFF2 and htmx/marked script loads, HTMX and markdown behavior, and zero external requests. The highest `TC-NN` id remains `TC-31`.


## Scope & Boundaries

### Work Areas

- `../dartclaw-public/packages/dartclaw_server/lib/src/static/` – six `fonts/*.woff2` files plus `htmx.min.js` and `marked.min.js`
- `../dartclaw-public/packages/dartclaw_server/lib/src/static/app-tokens.css` – self-hosted `@font-face` rules
- `../dartclaw-public/packages/dartclaw_server/lib/src/templates/layout.html` – same-origin script/style loads and font preloads
- `../dartclaw-public/packages/dartclaw_server/lib/src/auth/security_headers.dart` (+ its test) – CSP with no external origins
- `../dartclaw-public/dev/tools/embed_assets.dart` and `../dartclaw-public/packages/dartclaw_server/lib/src/embedded_static_handler.dart` (+ their tests) – `.woff2` as binary, served as `font/woff2`
- `../dartclaw-public/dev/tools/fitness/check_no_external_origins.sh` + `run_all.sh` – the regression guard
- `../dartclaw-public/packages/dartclaw_server/lib/src/static/VENDORS.md`, `../dartclaw-public/dev/testing/UI-SMOKE-TEST.md`, `../dartclaw-public/dev/architecture/security-architecture.md` – documentation

### What We're NOT Doing

- **`dev/design-system/showcase.html` keeps its Google Fonts `<link>`** -- it is a disk-opened dev artifact, not a served surface; S01–S04 and S14 all edit it, so touching it here buys conflicts for no runtime benefit. The fitness check is scoped to served surfaces accordingly.
- **No hand-edit of `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart`** -- S13 performs the materializing regeneration after all vendored embed-root changes through `dart run dev/tools/embed_assets.dart`, then proves generated parity and source-tree/compiled-binary serving.
- **No `integrity` / `crossorigin` attributes on the now same-origin scripts** -- SRI is meaningless same-origin; provenance moves to git history plus the upstream URL and its published hash recorded in `VENDORS.md`.
- **No Cyrillic, Greek or Vietnamese font subsets** -- they fall back to the system stack, the deliberate trade recorded in the vendoring analysis.
- **No change to how highlight.js, DOMPurify, Stimulus and `sse.js` are served** -- excluded by the story scope; only their `VENDORS.md` neighbours change.


## Architecture Decision

**Approach**: vendor all three under `lib/src/static/` and load them same-origin; the `@font-face` rules live in app-owned `app-tokens.css` rather than canon `tokens.css`, because a font `src` is a server route, not a design token.
**Why this over alternatives**: canon `dev/design-system/` is opened from disk by `showcase.html` and has no `/static/` route, so putting `@font-face` there would either bake a server path into a portable directory or force the six woff2 files to be duplicated into `dev/design-system/fonts/`; keeping canon untouched also leaves the byte-identity drift check alone and keeps this story independent of the P1 canon chain, as its empty `dependsOn` promises.


## Technical Overview

<!-- Self-evident from Architecture Decision + Code Patterns + per-task descriptions. -->


## Code Patterns & External References

```
# type | path#anchor or url                                                                     | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_server/lib/src/templates/layout.html               | the three CDN loads (lines 12/21/25) and the ${assetPrefix} tl:attr shape every same-origin asset already uses
file   | ../dartclaw-public/packages/dartclaw_server/lib/src/templates/layout.dart#layoutTemplate | assetPrefix is '/static/v$dartclawVersion' – why @font-face URLs must be relative
file   | ../dartclaw-public/packages/dartclaw_server/lib/src/embedded_static_handler.dart#_contentType | extension→MIME switch; add woff2 beside the existing png case
file   | ../dartclaw-public/dev/tools/embed_assets.dart#_binaryAssetExtensions                   | binary-vs-text classification; '.png' is the working precedent to copy
file   | ../dartclaw-public/packages/dartclaw_server/test/generated/embedded_assets_test.dart#_collectAssets | test-side duplicate of that classification – hardcodes '.png' and must track the tool
file   | ../dartclaw-public/packages/dartclaw_server/test/static/embedded_static_routes_test.dart | "serves embedded PNG bytes without text encoding" – the exact test shape to copy for woff2
file   | ../dartclaw-public/packages/dartclaw_server/lib/src/auth/security_headers.dart#_csp     | the CSP constant to strip of external origins
file   | ../dartclaw-public/packages/dartclaw_server/test/auth/security_headers_test.dart        | currently asserts the CDN origins are present – those assertions invert
file   | ../dartclaw-public/packages/dartclaw_server/lib/src/static/VENDORS.md                   | per-entry format (Version/License/Source/Files/Upgrading) the three new entries must match
file   | ../dartclaw-public/dev/tools/fitness/check_design_system_sync.sh                        | fitness-script shape: set -euo pipefail, repo-root resolution from BASH_SOURCE, non-zero on failure
file   | ../dartclaw-public/dev/tools/fitness/run_all.sh                                         | registration point for the new check
url    | https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&display=swap   | source of the six latin/latin-ext @font-face rules – copy their unicode-range values verbatim
```


## Constraints & Gotchas

- **Critical**: `@font-face` URLs must be relative (`url('fonts/jetbrains-mono-400-latin.woff2')`), never `/static/...` -- `layout.html` rewrites every stylesheet href through `${assetPrefix}` = `/static/v<version>`, so an absolute path escapes the version-keyed namespace `createVersionedStaticHandler` exists to enforce ("a different version stays a miss so browsers cannot combine assets from two releases"). Relative URLs resolve correctly under both `/static/` and `/static/v<version>/`.
- **Critical**: a `<link rel="preload" as="font">` **must** carry `crossorigin` even same-origin -- fonts are fetched in CORS mode, so a preload without it is a second, separate fetch and the preload is wasted.
- **Avoid**: adding `.woff2` only to `dev/tools/embed_assets.dart#_binaryAssetExtensions` -- `packages/dartclaw_server/test/generated/embedded_assets_test.dart#_collectAssets` hardcodes the same `.png` rule independently; both must change or the test compares a binary asset as text.
- **Constraint**: `font-src` currently has **no** `'self'` (`security_headers.dart` reads `font-src https://fonts.gstatic.com`), so self-hosted fonts are blocked until that directive changes -- the symptom is a silent fallback to system monospace with a CSP console violation, not a broken page.
- **Constraint**: S13 changes the server's static and template embed roots and extends the generator's binary classification, so it must perform the materializing `dart run dev/tools/embed_assets.dart` run after vendoring is final and before objective verification. `test/generated/embedded_assets_test.dart` must be green without narrowing; a stale generated bundle or allowed-red parity test fails the story.
- **Constraint**: the "no backend work" binding constraint bars service, schema and API changes -- it does not bar the two Dart edits FR8 names by file (`embed_assets.dart`, `embedded_static_handler.dart`) or the CSP constant, which are asset-pipeline and response-header changes with no service surface.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Six JetBrains Mono woff2 subsets ship under `lib/src/static/fonts/`
  - Take the `latin` and `latin-ext` `@font-face` rules for weights 400/500/600 from the Google CSS2 response and download the six `fonts.gstatic.com` woff2 files they reference; name them `jetbrains-mono-{400,500,600}-{latin,latin-ext}.woff2`. The CSS2 endpoint is User-Agent-negotiated: fetch it with a woff2-capable browser `User-Agent` header, or a default curl UA receives TTF `@font-face` rules without `unicode-range`. Record the exact fetch command (including that header) for `VENDORS.md` (TI10).
  - **Verify**: `Test: packages/dartclaw_server/lib/src/static/fonts/ contains exactly jetbrains-mono-400-latin.woff2, jetbrains-mono-400-latin-ext.woff2, jetbrains-mono-500-latin.woff2, jetbrains-mono-500-latin-ext.woff2, jetbrains-mono-600-latin.woff2, jetbrains-mono-600-latin-ext.woff2, and every one of the six begins with the bytes 0x77 0x4F 0x46 0x32 ("wOF2")`

- [ ] **TI02** htmx 2.0.8 and marked 15 ship under `lib/src/static/`
  - Vendor as `htmx.min.js` and `marked.min.js`, matching the naming of the already-vendored `stimulus.min.js` / `purify.min.js`. Bytes must be the upstream release files unmodified, so the `integrity` hashes currently in `layout.html` still describe them.
  - **Verify**: `Shell: shasum -b -a 384 packages/dartclaw_server/lib/src/static/htmx.min.js | cut -d' ' -f1 | xxd -r -p | base64 prints /TgkGk7p307TH7EXJDuUlgG3Ce1UVolAOFopFekQkkXihi5u/6OCvVKyz1W+idaz (the current layout.html integrity value minus its sha384- prefix), and the same round-trip on packages/dartclaw_server/lib/src/static/marked.min.js prints 948ahk4ZmxYVYOc+rxN1H2gM1EJ2Duhp7uHtZ4WSLkV4Vtx5MUqnV+l7u9B+jFv+`

- [ ] **TI03** The embed pipeline classifies `.woff2` as a binary asset
  - Extend `dev/tools/embed_assets.dart#_binaryAssetExtensions` and the matching hardcoded rule in `packages/dartclaw_server/test/generated/embedded_assets_test.dart#_collectAssets`; both list `.png` today and must stay in step.
  - **Verify**: `Shell: rg -n "_binaryAssetExtensions" dev/tools/embed_assets.dart shows {'.png', '.woff2'}, and rg -n "woff2" packages/dartclaw_server/test/generated/embedded_assets_test.dart matches the binary branch of _collectAssets`

- [ ] **TI04** The static handler serves `.woff2` as `font/woff2`
  - Add the case to `embedded_static_handler.dart#_contentType` beside `png`; without it the switch falls through to `application/octet-stream` and browsers reject the font. Cover it in `test/static/embedded_static_routes_test.dart` following the existing "serves embedded PNG bytes without text encoding" test.
  - **Verify**: `Test: createEmbeddedStaticHandler serving static/fonts/jetbrains-mono-400-latin.woff2 returns 200 with Content-Type font/woff2 and a body byte-identical to the input bytes (proves S03)`

- [ ] **TI05** `app-tokens.css` carries the self-hosted `@font-face` rules
  - Six rules, one per file from TI01, each with `font-family: 'JetBrains Mono'`, `font-style: normal`, its weight, `font-display: swap`, `src: url('fonts/<file>.woff2') format('woff2')` and the `unicode-range` copied verbatim from the Google CSS2 response. Relative URL is mandatory – see Constraints & Gotchas. Canon `tokens.css` keeps `--font-mono` and is not edited.
  - **Verify**: `Shell: rg -c "@font-face" packages/dartclaw_server/lib/src/static/app-tokens.css prints 6; rg -n "url\(" packages/dartclaw_server/lib/src/static/app-tokens.css shows only relative fonts/ paths and no leading slash; git diff --stat leaves dev/design-system/tokens.css untouched and bash dev/tools/fitness/check_design_system_sync.sh exits 0`

- [ ] **TI06** `layout.html` loads every subresource from the server's own origin
  - Drop the `fonts.googleapis.com` stylesheet link entirely (TI05 replaces it); repoint the htmx and marked `<script>` tags at `/static/htmx.min.js` and `/static/marked.min.js` with the `tl:attr="src=${assetPrefix} + '/…'"` form the sibling scripts use, dropping their now-meaningless `integrity` / `crossorigin` attributes. htmx must keep loading **before** `sse.js` – both are `defer`, so document order is execution order. Add `<link rel="preload" as="font" type="font/woff2" crossorigin>` for the two above-the-fold weights, `fonts/jetbrains-mono-400-latin.woff2` and `fonts/jetbrains-mono-600-latin.woff2`, also via `${assetPrefix}`.
  - **Verify**: `Shell: rg -n '<(link|script|img|iframe|source)[^>]*(src|href)="https?://' packages/dartclaw_server/lib/src/templates/ returns no matches (exit 1); rg -n "preload" packages/dartclaw_server/lib/src/templates/layout.html shows both font links carrying crossorigin; in that file htmx.min.js appears on an earlier line than sse.js`

- [ ] **TI07** The CSP names no external origin and allows same-origin fonts
  - `security_headers.dart#_csp` becomes `script-src 'self' '<hash>'`, `style-src 'self' 'unsafe-inline'`, `font-src 'self'` – `unpkg.com`, `cdn.jsdelivr.net`, `fonts.googleapis.com` and `fonts.gstatic.com` all go. The dartdoc above `_csp` ("explicit CDN allowlist") becomes false with this change – reword it to describe the same-origin-only policy. `security_headers_test.dart` currently asserts those origins are *present*; invert those assertions.
  - **Verify**: `Test: security_headers_test.dart asserts the CSP contains "font-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline'" and a sha256- hash, and asserts isNot(contains('https://')) (proves S02). Shell: rg -n "CDN allowlist" packages/dartclaw_server/lib/src/auth/security_headers.dart returns no matches`

- [ ] **TI08** A fitness check fails on any external subresource in the served surfaces
  - New `dev/tools/fitness/check_no_external_origins.sh`, following the shape of `check_design_system_sync.sh`, asserting three things: no `<link|script|img|iframe|source>` tag under `packages/dartclaw_server/lib/src/templates/` carries an external `src`/`href` – quote- and scheme-tolerant, matching `(src|href)\s*=\s*["']?(https?:)?//` so single-quoted attributes and protocol-relative `//cdn…` forms are caught; no CSS under `packages/dartclaw_server/lib/src/static/` recursively carries an external `@import` or `url(...)`. The `@import` detector must catch double-quoted, single-quoted, unquoted URL-token, protocol-relative and `url(...)` forms: `@import "https://…"`, `@import 'https://…'`, `@import https://…`, `@import //cdn…`, `@import url("https://…")`, `@import url(https://…)` and `@import url(//cdn…)`. The general `url(...)` detector likewise catches quoted/unquoted `http://`, `https://` and `//` forms; no `https://` appears in `packages/dartclaw_server/lib/src/auth/security_headers.dart`. **Every detector is multiline-aware** – run `rg -U` (or equivalent) so `\s*` spans newlines: an attribute split across lines (`src=` at one line's end with the URL on the next, or the attribute name and `=` separated by a line break) and an `@import`/`url(` whose URL lands on the following line are caught exactly like their single-line forms. A plain line-based grep is not an accepted implementation – a formatter or a deliberate re-introduction can legally split any of these across lines. Outbound `<a href>` navigation, code comments and `VENDORS.md` upgrade commands are out of the scan by construction, not by allowlist. Register it in `dev/tools/fitness/run_all.sh` beside the other checks.
  - **Verify**: `Shell: bash dev/tools/fitness/check_no_external_origins.sh exits 0 on the clean tree (proves S05); after pasting <script src="https://cdn.jsdelivr.net/npm/marked@15/marked.min.js"> into layout.html it exits non-zero naming layout.html (proves S04), and the same tag re-pasted with the attribute split across lines — `src=` ending one line, `"https://cdn.jsdelivr.net/npm/marked@15/marked.min.js"` opening the next — also exits non-zero naming layout.html (the split-line falsifier; a line-based grep fails this). In a scratch CSS file, each positive falsifier exits non-zero and names the line: @import "https://cdn.example/a.css"; @import 'http://cdn.example/a.css'; @import https://cdn.example/a.css; @import //cdn.example/a.css; @import url("https://cdn.example/a.css"); @import url(https://cdn.example/a.css); @import url(//cdn.example/a.css); src: url('https://fonts.gstatic.com/x.woff2'); plus two split-line forms — `@import` ending one line with `url("https://cdn.example/a.css");` on the next, and `src: url(` ending one line with `'https://fonts.gstatic.com/x.woff2');` on the next. Each negative falsifier stays green: @import "theme.css"; @import './theme.css'; @import url("theme.css"); @import url(../fonts/local.woff2); background-image: url(data:image/svg+xml;base64,AAAA); and the existing lucide attribution comment. rg -n check_no_external_origins dev/tools/fitness/run_all.sh matches`

- [ ] **TI09** The offline render check is a recorded, repeatable embedded-fallback regression check
  - Add row `R-13` to the Regression Checks table in `dev/testing/UI-SMOKE-TEST.md` in the table's one-line house style — issue name plus a quick-check cell that points at the protocol (`| R-13 | External runtime dependency returns | Embedded fallback serves fully offline — run § R-13 protocol below |`) — and a `### R-13 protocol` subsection at the end of the Regression Checks section carrying the full procedure as a short numbered list. The twelve existing rows are one-line quick checks; a multi-sentence protocol does not belong in a table cell, and R-13 is the section's one deliberate exception in depth, not in row format. Author both at this task position, but defer the runtime **Verify** until TI12 has regenerated the final embed roots and completed its own built-binary proof; then repeat the build and launch from a fresh temporary directory so TI09 independently proves the recorded check. The protocol must first run `bash dev/tools/build.sh`, resolve `BIN="$PWD/build/bin/dartclaw"`, create a temporary directory outside the checkout, copy `dev/testing/profiles/visual/data/.` into it, and launch `(cd "$R13_DATA" && "$BIN" --config "$R13_DATA/dartclaw.yaml" serve --data-dir "$R13_DATA" --port 3338)`; the recorded process arguments must contain port 3338 and contain neither `--dev` nor `--source-dir`, so source-tree assets cannot satisfy the check. Run the browser with all non-`localhost` origins unreachable (e.g. Chromium `--host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost"`) so every future run blocks uniformly rather than improvising a per-domain blocklist. For each weight 400/500/600, call `document.fonts.load` with representative latin (`DartClaw 0123`) and latin-ext (`Pchnąć w tę łódź jeża`) text and require a non-empty matching array whose `FontFace` entries are loaded and match JetBrains Mono plus the requested weight; `document.fonts.check()` may remain supplementary only. Require successful same-origin loads for `htmx.min.js`, `marked.min.js`, and both `font/woff2` subsets at all three weights, an `hx-get` navigation swap, a seeded chat message rendered as HTML, and zero non-`localhost` requests. Use the `R-NN` table rather than a new `TC-NN` so S14's stated `TC-01…TC-31` release gate stays accurate.
  - **Verify**: `Shell: rg -n "R-13" dev/testing/UI-SMOKE-TEST.md matches both the one-line table row and the "### R-13 protocol" subsection heading, and the subsection sits inside the Regression Checks section; together they name build/bin/dartclaw, a temporary cwd/data directory, explicit --port 3338, absence of --dev/--source-dir, the blocking mechanism, document.fonts.load, weights 400/500/600, latin and latin-ext text, non-empty loaded FontFace matches, successful same-origin WOFF2 and htmx/marked script loads, HTMX/markdown behavior and zero external requests; the highest TC id in the document is still TC-31. Runtime after TI12: without any source or generated-file edit, bash dev/tools/build.sh succeeds again, the port-3338 PID is that rebuilt binary launched from a fresh temporary cwd/data directory with the required arguments, and every recorded R-13 browser assertion passes (proves the Structural Criterion on R-13).`

- [ ] **TI10** `VENDORS.md` documents all seven vendored assets
  - Three new entries for htmx 2.0.8 (BSD-2-Clause), marked 15 (MIT) and JetBrains Mono (SIL OFL 1.1), each with Version / License / Source / Files table / Upgrading, matching the existing entries' shape. The htmx and marked upgrade sections record the upstream URL **and** the published SRI hash from TI02, so vendored bytes stay verifiable against the CDN copy after `integrity` leaves `layout.html`. The JetBrains Mono entry records the exact Google CSS2 fetch – including the browser `User-Agent` header TI01 requires, without which the endpoint serves TTF – and which six subsets are kept.
  - **Verify**: `Shell: rg -c "^## " packages/dartclaw_server/lib/src/static/VENDORS.md prints 7; rg -n "sha384-" packages/dartclaw_server/lib/src/static/VENDORS.md matches both the htmx and marked entries; the JetBrains Mono Upgrading command includes a User-Agent header; git diff shows the highlight.js, DOMPurify, htmx-ext-sse and Stimulus sections unchanged`

- [ ] **TI11** The security architecture doc describes the CSP as it now is
  - `dev/architecture/security-architecture.md` § Security headers / CSP currently reads "inline-script hash + explicit CDN allowlist"; the allowlist is gone. Bump the doc's **Current through** marker per the project's doc-sync rule.
  - **Verify**: `Shell: rg -n "CDN allowlist" dev/architecture/security-architecture.md returns no matches; the same bullet names same-origin-only sources`

- [ ] **TI12** Vendored assets are materialized into the tracked bundle and serve from source and the release binary
  - After TI01–TI11 and the final change under `packages/dartclaw_server/lib/src/templates/` or `lib/src/static/`, confirm both generated asset files are tracked, run `dart run dev/tools/embed_assets.dart`, and capture the generated diff. This is S13's materializing regeneration: the server bundle diff must be non-empty because the newly vendored JS, WOFF2 files and updated `static/VENDORS.md` are new embed inputs. Do not hand-edit either generated file. Then run `bash dev/tools/build.sh`, resolve the absolute `build/bin/dartclaw` path, create a temporary cwd/data directory outside the checkout from the visual seed, and launch that binary with `--config <temp>/dartclaw.yaml serve --data-dir <temp> --port 3338`; do not pass `--dev` or `--source-dir`. After TI12's own proof passes, execute TI09's deferred runtime Verify against the unchanged tree by running `bash dev/tools/build.sh` again and launching the rebuilt absolute binary from a fresh temporary cwd/data directory with the same arguments.
  - **Verify**: `git ls-files --error-unmatch -- packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart packages/dartclaw_workflow/lib/src/generated/embedded_assets.g.dart` exits 0; the first generator run produces a non-empty server generated-file diff; `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart packages/dartclaw_server/test/static/embedded_static_routes_test.dart` passes; the source-tree server returns `200` and `font/woff2` with byte-identical bodies for representative 400-latin and 500-latin-ext files and serves `htmx.min.js` / `marked.min.js` same-origin; the built process is the PID listening on 3338, its arguments name `build/bin/dartclaw`, `serve`, the temporary `--data-dir`, and `--port 3338` but neither `--dev` nor `--source-dir`, and it serves the representative fonts plus `htmx.min.js` / `marked.min.js` from the embedded fallback with the same status, content types and bytes. Against that built process, S01's blocked-network browser proof requires same-origin htmx/marked and WOFF2 loads, non-empty loaded 400/500/600 latin and latin-ext `FontFaceSet.load` results, working HTMX swaps and markdown rendering, and zero external requests; TI09 then repeats build → fresh-temp launch → the same browser assertions without any source or generated-file edit between the two proofs; all declared tests are green.

### Testing Strategy

<!-- Per-task Verify lines + scenario tests scaffolded from the Acceptance Scenarios are sufficient. TI12 is the closing generated-parity and source/compiled serving gate. -->

### Validation

- Capture one representative surface (`/tasks`, which mixes table, card and label type) in both themes at desktop and 768px, online and with external origins blocked, and confirm the two captures are pixel-identical – the typeface swap is the only visual delta this story can produce, and it is global. Repeat the offline proof against the source-tree server and the compiled `build/bin/dartclaw` from TI12.

### Execution Contract

- Document order carries the cross-task dependencies: TI01/TI02 produce files TI03–TI06 consume; TI12 runs after TI10's final embed-root edit. TI09 is the one split task: its documentation edit lands in order, but its built-binary runtime Verify runs only after TI12's final regeneration and own build-launch proof, then repeats build-launch from a fresh temporary directory. No provisional regeneration occurs, so TI12 still requires its first generator run to produce the materializing non-empty server diff. Any remediation that changes an embed root reopens TI12 and the deferred TI09 runtime Verify before the story may close.


## Final Validation Checklist

- [ ] TI12's materializing generator run produced a non-empty server generated-file diff; both generated files remain tracked; generated parity and the full declared test set are green.
- [ ] Source-tree serving is green; after final regeneration, TI12 and then TI09 each independently run build → fresh temporary cwd/data launch with `--port 3338` and no `--dev` / `--source-dir`; same-origin htmx/marked and representative latin/latin-ext WOFF2 loads have correct MIME/bytes, all six font faces load through the browser probes, HTMX/markdown behavior works, and no external request occurs.
- [ ] `git status` shows no modification under `dev/design-system/`.


## Implementation Observations

_No observations recorded yet._
