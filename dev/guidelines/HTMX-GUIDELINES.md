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

### Use Stimulus for browser behavior owned by DOM islands

Stimulus is DartClaw's adopted browser interaction layer. HTMX keeps owning navigation, requests, swaps, and SSE-delivered fragments; Stimulus owns imperative behavior attached to server-rendered DOM.

- Name controllers with the `dc-*` prefix in markup, matching files under `static/controllers/` (`data-controller="dc-chat"`).
- Put setup and teardown in controller lifecycle methods: `connect()` attaches behavior, `disconnect()` releases timers, observers, and event subscriptions.
- Use targets for owned elements (`data-dc-chat-target="input"`) instead of repeated DOM queries from global page modules.
- Use values for typed configuration passed from Trellis templates (`data-dc-chat-session-id-value="..."`).
- Use Stimulus actions for local event wiring (`data-action="submit->dc-chat#send"`).
- Let HTMX swaps create and remove controllers naturally. `connect()` replaces the old manual `initAfterSwapReinit()` pattern after `htmx:afterSwap` and history restoration.

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


### Server-rendered fragment conventions for CRUD surfaces

The contract every server-rendered mutating surface follows. `/settings` is the
reference implementation (`lib/src/templates/settings_form.html` +
`lib/src/web/settings/`).

1. **One `tl:fragment` per independently swappable surface**, whose root element
   carries the `id` HTMX targets. The page template composes fragments and holds
   no per-item markup.
2. **Mutating routes live under the owning page's path** and take a
   form-encoded body. A dashboard page declares them on itself
   (`DashboardPage.declaredRoutes`, a list of `(method, path)`); the loop in
   `web/web_routes.dart` registers each one through the same page handler and
   the same HTML error wrapping as the page `GET`, and `PageRegistry.register`
   refuses a declaration that hits a reserved pattern or a method-and-path
   another page already claims. `lib/src/web/pages/projects_page.dart` is the
   reference. Task and workflow pages also declare their detail and fragment
   routes on this seam. Routes with no owning page (`POST /login`,
   `POST /pairing/code`) stay hand-registered, as do the remaining legacy
   routes (`POST /settings` and the audit fragments). Those are listed
   in `_reservedRoutePatterns` with the method they occupy, so declaring one is
   refused at registration rather than silently shadowed - `GET /settings` is
   still the settings page's own route,
   only `POST /settings` is taken. Adding a hand-registered route without its
   reserved row is what re-opens the silent shadow: shelf_router answers with
   the first matching handler, so the later declaration never runs.
3. **A mutation answers with the re-rendered fragment at status 200 on both
   success and validation failure.** Field-level errors render inside the
   field's own `.form-error` with `aria-invalid` on the control, from the same
   `ValidationError` list the JSON API returns. 4xx is reserved for auth or
   route-level refusal, where nothing is swapped.
4. **Cross-surface state rides the same response out of band** (`hx-swap-oob`) —
   restart banner, counters, sidebar. Never a second fetch after a mutation.
5. **Static `hx-*` attributes are hardcoded in markup; dynamic URLs come from
   the render context via `tl:attr`.** `hx-select` always pairs with
   `hx-swap="outerHTML"`.
6. **Discard is native** — `<button type="reset">` restores the server-rendered
   control defaults, so no client-side value cache exists to go stale. A section
   with nothing to render uses the shared `emptyState` fragment, never an empty
   container.
7. **A mutation with no form field reports through the toast trigger.** A row
   action (Remove, Fetch) has no control to carry a `.form-error`, so it answers
   200 with the re-rendered list and an `HX-Trigger-After-Swap` carrying a
   `dc:toast` payload (`web_utils.dart#toastTriggerHeader`), which
   `dc_toast_controller.js` raises. It never answers 4xx for a domain refusal:
   HTMX drops a 4xx body, so the message would vanish
   (`api/workflow_routes.dart#_workflowFormError` records the same reason).

For a server-rendered polling surface, put `hx-get` and `hx-trigger="every Ns"`
on the fragment root and render that root only while polling is meaningful.
Removing the fragment stops HTMX polling; keeping it hidden does not.


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
- Vendor HTMX and its extensions under `lib/src/static/` and load them same-origin; DartClaw contacts no CDN at
  runtime, and `dev/tools/fitness/check_no_external_origins.sh` fails the build if one reappears
- Record the upstream URL and published SRI hash in `VENDORS.md` so vendored bytes stay verifiable once `integrity`
  no longer applies (it is meaningless same-origin)
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
