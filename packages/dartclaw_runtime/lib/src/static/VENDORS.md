# Vendored Third-Party Assets

## highlight.js

- **Version**: 11.11.1
- **License**: BSD-3-Clause
- **Source**: https://highlightjs.org/

### Files

| File | Description |
|------|-------------|
| `hljs.min.js` | highlight.js core + common languages bundle |
| `hljs-dart.min.js` | Dart language grammar (loaded after core) |
| `hljs-catppuccin-mocha.css` | Catppuccin Mocha (dark) theme |
| `hljs-catppuccin-latte.css` | Catppuccin Latte (light) theme |

### Upgrading

Download latest from https://highlightjs.org/download and replace `hljs.min.js`.
Language grammars from https://cdnjs.cloudflare.com/ajax/libs/highlight.js/{version}/languages/{lang}.min.js.
Themes from https://github.com/catppuccin/highlightjs.

## DOMPurify

- **Version**: 3.3.3
- **License**: Apache-2.0 OR MPL-2.0
- **Source**: https://github.com/cure53/DOMPurify

### Files

| File | Description |
|------|-------------|
| `purify.min.js` | DOMPurify minified (source map reference stripped) |

### Upgrading

Download latest from `https://cdn.jsdelivr.net/npm/dompurify@3/dist/purify.min.js` and strip the trailing `//# sourceMappingURL=...` line to avoid CSP console warnings.

## htmx-ext-sse

- **Version**: 2.2.4
- **License**: BSD-2-Clause
- **Source**: https://github.com/bigskysoftware/htmx-extensions/tree/main/src/sse

### Files

| File | Description |
|------|-------------|
| `sse.js` | HTMX SSE extension (declarative EventSource + DOM swapping) |

### Upgrading

Download latest from `https://unpkg.com/htmx-ext-sse@{version}/sse.js`.

## Stimulus

- **Version**: 3.2.1
- **License**: MIT
- **Source**: https://github.com/hotwired/stimulus

### Files

| File | Description |
|------|-------------|
| `stimulus.min.js` | Stimulus browser bundle served from local `/static/` |

### Upgrading

Download from `https://unpkg.com/@hotwired/stimulus@3.2.1/dist/stimulus.umd.js` and vendor as `stimulus.min.js`.

## htmx

- **Version**: 2.0.8
- **License**: BSD-2-Clause
- **Source**: https://github.com/bigskysoftware/htmx
- **SRI**: `sha384-/TgkGk7p307TH7EXJDuUlgG3Ce1UVolAOFopFekQkkXihi5u/6OCvVKyz1W+idaz`

### Files

| File | Description |
|------|-------------|
| `htmx.min.js` | htmx core, minified (must load before `sse.js`) |

### Upgrading

Download from `https://unpkg.com/htmx.org@{version}/dist/htmx.min.js` and vendor as `htmx.min.js`.

The bytes are the upstream release file unmodified. `integrity` left `layout.html` when the load became same-origin,
so verify a replacement against the published SRI hash instead:

```bash
shasum -b -a 384 htmx.min.js | cut -d' ' -f1 | xxd -r -p | base64
# 2.0.8 -> /TgkGk7p307TH7EXJDuUlgG3Ce1UVolAOFopFekQkkXihi5u/6OCvVKyz1W+idaz
```

## marked

- **Version**: 15.0.12
- **License**: MIT
- **Source**: https://github.com/markedjs/marked
- **SRI**: `sha384-948ahk4ZmxYVYOc+rxN1H2gM1EJ2Duhp7uHtZ4WSLkV4Vtx5MUqnV+l7u9B+jFv+`

### Files

| File | Description |
|------|-------------|
| `marked.min.js` | marked markdown parser, minified (output is sanitized by DOMPurify before insertion) |

### Upgrading

Download from `https://cdn.jsdelivr.net/npm/marked@{major}/marked.min.js` and vendor as `marked.min.js`.

The bytes are the upstream release file unmodified. Verify a replacement against the published SRI hash:

```bash
shasum -b -a 384 marked.min.js | cut -d' ' -f1 | xxd -r -p | base64
# 15.0.12 -> 948ahk4ZmxYVYOc+rxN1H2gM1EJ2Duhp7uHtZ4WSLkV4Vtx5MUqnV+l7u9B+jFv+
```

## JetBrains Mono

- **Version**: Google Fonts `jetbrainsmono` v24
- **License**: SIL Open Font License 1.1
- **Source**: https://fonts.google.com/specimen/JetBrains+Mono

### Files

| File | Description |
|------|-------------|
| `fonts/jetbrains-mono-latin.woff2` | latin subset, variable weight axis |
| `fonts/jetbrains-mono-latin-ext.woff2` | latin-ext subset, variable weight axis |

Google serves 18 `@font-face` rules for weights 400/500/600 — 6 unicode-ranges x 3 weights — but only **6 distinct
files**, one per unicode-range. JetBrains Mono is a variable font, so a single file per subset covers the whole weight
axis and the three weights differ only in the `font-weight` each rule instantiates. We keep the latin and latin-ext
subsets; cyrillic, cyrillic-ext, greek and vietnamese fall back to the system stack, which is the deliberate trade
recorded in the release's vendoring analysis. Swedish `åäö` sit inside the latin range (U+0000–00FF).

The `@font-face` rules live in `app-tokens.css`, not canon `tokens.css`, and their `url()`s must stay **relative** —
`layout.html` rewrites stylesheet hrefs through `${assetPrefix}` = `/static/v<version>`.

### Upgrading

The CSS2 endpoint is User-Agent-negotiated: a default curl UA receives TTF `@font-face` rules with no `unicode-range`.
Send a woff2-capable browser UA:

```bash
curl -sS -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' \
  'https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&display=swap'
```

Download the `fonts.gstatic.com` URLs from the `/* latin */` and `/* latin-ext */` rules, vendor them under `fonts/`,
and copy each rule's `unicode-range` verbatim into `app-tokens.css`. Confirm each downloaded file starts with the WOFF2
signature — a corrupted font fails silently to a system fallback:

```bash
xxd -l 4 -p fonts/jetbrains-mono-latin.woff2   # 774f4632 == "wOF2"
```
