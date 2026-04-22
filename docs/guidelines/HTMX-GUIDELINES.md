# HTMX Guidelines

High-level HTMX guidance. This is a policy document, not a reference manual.

Use official docs for API details, defaults, and examples:
- [HTMX docs](https://htmx.org/docs/)
- [HTMX reference](https://htmx.org/reference/)
- [SSE extension](https://htmx.org/extensions/sse/)


---


## Core Principles

- Prefer server-rendered HTML over client-side JSON rendering when using HTMX
- Prefer explicit behavior on elements over broad global behavior
- Keep dynamic URLs server-generated
- Keep this document short; do not duplicate the HTMX reference here


---


## Recommended Patterns

### Prefer explicit navigation over `hx-boost` for app shells

Use explicit links when you need predictable targets, swaps, and history behavior.

```html
<a href="/page"
   hx-get="/page"
   hx-target="#content"
   hx-select="#content"
   hx-swap="outerHTML"
   hx-push-url="true">
```

Use `hx-boost` only when whole-page or whole-body behavior is actually desired.


### If responses differ for HTMX vs direct navigation, handle that explicitly

Do not key only on `HX-Request` if history restore must return a full page.

Example:

```dart
bool wantsFragment(Request request) {
  final isHx = request.headers['HX-Request'] == 'true';
  final isHistoryRestore = request.headers['HX-History-Restore-Request'] == 'true';
  return isHx && !isHistoryRestore;
}
```

Also send:

```http
Vary: HX-Request
```


### Render full pages, then extract fragments when that keeps routing simple

`hx-select` changes what HTMX swaps. It does not reduce what the server sends.

This pattern is often simpler than maintaining separate fragment-only routes:

```html
<a href="/page"
   hx-get="/page"
   hx-target="#content"
   hx-select="#content">
```


### Use response headers for HTMX redirects, not `3xx`

For HTMX-triggered navigation after POST/DELETE/etc, prefer `HX-Location`.

Do not rely on `HX-*` response headers on `3xx` responses. HTMX ignores them there.


### Use SSE via the extension

For streaming HTML fragments:

```html
<div hx-ext="sse" sse-connect="/events" sse-close="done">
  <div sse-swap="message" hx-swap="beforeend"></div>
</div>
```

Required response headers:

```http
Content-Type: text/event-stream
Cache-Control: no-cache
X-Accel-Buffering: no
```


---


## Asset Rules

- Pin HTMX to an exact version
- Use a real SRI hash for CDN-loaded core assets
- Pin or vendor extensions used at runtime
- Keep version and asset policy documented near the actual asset-loading code
- Do not put package-manager setup instructions here unless the repo actually uses them


---


## Security Rules

- HTMX swaps raw HTML; escape untrusted content on the server
- Do not rely on HTMX to sanitize content
- Avoid `hx-on` unless the behavior is tiny and fully trusted
- Avoid `hx-vals='js:...'` unless needed
- Prefer external JS over inline JS
- Keep requests same-origin unless there is a strong reason not to
- Consider `hx-disable` for untrusted HTML islands


---


## Avoid

- Defaulting to `hx-boost` everywhere
- Returning fragments based only on `HX-Request` when history restore matters
- Omitting `Vary: HX-Request` when responses differ by request type
- Claiming `hx-select` reduces payload size
- Copying placeholder SRI hashes or fake version strings
- Treating this file as a substitute for the official HTMX docs
- Using `htmx.triggerEvent(...)` instead of `htmx.trigger(...)`


---


## Checklist

- [ ] HTMX assets are pinned and use real SRI hashes where applicable
- [ ] Navigation uses explicit HTMX behavior where predictability matters
- [ ] Fragment/full-page routing handles history restore correctly
- [ ] Responses that vary by `HX-Request` send `Vary: HX-Request`
- [ ] SSE endpoints send the required stream headers
- [ ] Untrusted data is not inserted into `hx-on` or `js:` expressions

