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
