# Local vendoring of Web UI runtime dependencies — analysis

> Supporting document for [prd.md](prd.md) FR8. Date: 2026-07-25. Measurements taken against `v0.22.0`.

## Current state

`packages/dartclaw_server/lib/src/templates/layout.html` loads three assets from external CDNs on every page load. Four others are already vendored under `lib/src/static/` and documented in `VENDORS.md`.

| Asset | Served from | Size | SRI |
|---|---|---|---|
| htmx 2.0.8 | `unpkg.com` | 50.0 KB | yes |
| marked 15 | `cdn.jsdelivr.net` | 39.0 KB | yes |
| JetBrains Mono 400/500/600 | `fonts.googleapis.com` → `fonts.gstatic.com` | 30.6 KB × 3 (latin) | **impossible** |
| highlight.js 11.11.1 | `/static/` | 124.5 KB | n/a |
| Stimulus 3.2.1 | `/static/` | 97.2 KB | n/a |
| DOMPurify 3.3.3 | `/static/` | 22.7 KB | n/a |
| htmx-ext-sse 2.2.4 | `/static/` | 8.7 KB | n/a |

## Recommendation: vendor all three

The existing split is arbitrary and, in one case, incoherent: **the htmx SSE extension is vendored while htmx core — which the extension depends on — is not.** No principle separates the two lists.

### Rationale, strongest first

1. **Correctness.** No htmx → the entire fragment-swap interaction model stops working. No marked → chat messages render as raw markdown. No font → the design system's single deliberate typeface silently falls back to system monospace, changing every metric of the type system FR1/FR2 are about to tune. A self-hosted agent runtime that degrades without internet access is a defect, not a trade-off.
2. **It contradicts a shipped promise.** ADR-047 states a bare binary is *"fully self-sufficient — single-file install, no network dependency."* That is currently false for the Web UI.
3. **Privacy.** Every page load sends the user's IP to Google, from a product whose positioning is self-hosted and security-conscious.
4. **CSP posture.** Vendoring collapses the policy to no external origins at all:
   ```
   script-src 'self' '<hash>';  style-src 'self' 'unsafe-inline';  font-src 'self';
   ```
   Note `auth/security_headers.dart:13` is currently `font-src https://fonts.gstatic.com` with **no `'self'`** — self-hosted fonts would be blocked today until that line changes.
5. **Supply chain.** htmx and marked carry SRI `integrity` hashes, so tampering is detected. The Google Fonts stylesheet **cannot** carry SRI — it is generated per-User-Agent — so it is the one `style-src`-trusted origin with no integrity check.

### Cost

~181 KB added to `static/`, a ~72% increase over the ~253 KB already vendored. In `embedded_assets.g.dart` that is roughly 241 KB of base64, growing the checked-in generated file from 1.36 MB to ~1.6 MB.

**No fitness gate blocks this.** `dev/tools/arch_check.dart` has LOC ceilings only for `dartclaw_core` (16500) and `dartclaw_workflow` (30000), and its LOC scan explicitly skips `/lib/src/generated/` (`arch_check.dart:331`).

### Font subsetting

Google serves **18 `@font-face` rules** for this request — 6 unicode-ranges × 3 weights. Self-hosting needs only **latin + latin-ext = 6 files**. Swedish `åäö` fall inside the latin range (U+0000–00FF), so 0.23's multi-language work is covered. Cyrillic, Greek and Vietnamese drop to the fallback stack, which is the correct trade for a developer tool.

## Mechanics — two code changes beyond dropping the files in

Both are easy to miss and would fail silently or confusingly:

1. **`dev/tools/embed_assets.dart:9`** — `_binaryAssetExtensions` is `{'.png'}`. Without adding `.woff2`, font binaries are embedded as text and corrupted.
2. **`packages/dartclaw_server/lib/src/embedded_static_handler.dart:50`** — the `_contentType` switch has no `woff2` case and falls through to `application/octet-stream`; browsers reject the font.

Then:

- Self-hosted `@font-face` rules in `tokens.css` pointing at `/static/`.
- `<link rel="preload">` for the two weights above the fold (replacing the current `display=swap` + no `preconnect`).
- `security_headers.dart` CSP tightened: drop `unpkg.com`, `cdn.jsdelivr.net`, `fonts.googleapis.com`; `font-src 'self'`.
- `VENDORS.md` extended with three entries and their upgrade commands, matching the existing format.

## Verification gate

Run the `visual` profile with all external origins blocked and confirm the UI renders identically to the online case. **This test does not exist today** and should ship with the change — it is the only thing that keeps a future `<link>` to a CDN from silently re-introducing the dependency.
