# HTMX Guidelines

High-level HTMX guidance. This is a policy document, not a reference manual.

DartClaw vendors HTMX 4.0.0 and the matching bundled `hx-sse` extension. Use the version-specific upstream docs:

- [HTMX 4 migration guide](https://four.htmx.org/migration-guide-htmx-4)
- [HTMX swap API](https://four.htmx.org/reference/methods/htmx-swap)
- [hx-sse extension](https://four.htmx.org/extensions/hx-sse.md)


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
- Let HTMX swaps create and remove controllers naturally. `connect()` replaces the old manual `initAfterSwapReinit()` pattern after swaps and history restoration.

### Navigation and history

Use explicit links when you need predictable targets, swaps, and history behavior.

```html
<a href="/page"
   hx-get="/page"
   hx-target="#content"
   hx-select="#content"
   hx-swap="outerHTML"
   hx-push-url="true">
```

Use `hx-boost` only when whole-page or whole-body behavior is actually desired. HTMX 4 restores history by
refetching the page. Put `hx-history-elt` on the `.shell` root so the route-dependent `#topbar`, `#sidebar`,
and `#restart-banner-slot` restore together with the single `#main-content`. A main-only boundary leaves stale
page controls and navigation state. Test Back and Forward, including a failed refetch followed by recovery.


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
   route-level refusal. The layout explicitly inherits `hx-status:4xx="swap:none"` and
   `hx-status:5xx="swap:none"`; HTMX 4 would otherwise swap those error bodies.
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
   200 with the re-rendered list and an `HX-Trigger` carrying a `dc:toast` payload
   (`web_utils.dart#toastTriggerHeader`). HTMX 4.0.0 dispatches this header after
   the awaited swap; it does not support `HX-Trigger-After-Swap`. A domain refusal
   also returns a fragment at 200, because the layout suppresses 4xx/5xx swaps.

For a server-rendered polling surface, put `hx-get` and `hx-trigger="every Ns"`
on the fragment root and render that root only while polling is meaningful.
Removing the fragment stops HTMX polling; keeping it hidden does not.


### Use response headers for HTMX redirects, not `3xx`

For HTMX-triggered navigation after POST/DELETE/etc, prefer `HX-Location`.

Do not rely on `HX-*` response headers on `3xx` responses. HTMX ignores them there.


### Request lifecycle and explicit inheritance

HTMX 4 does not implicitly inherit attributes. Use `:inherited` only for an intentional ancestor policy,
for example `hx-indicator:inherited="#nav-progress"` and `hx-status:4xx:inherited="swap:none"` on the layout.
Keep request targets and swaps explicit on their owning elements.

Lifecycle names use colons: `htmx:before:request`, `htmx:after:swap`, `htmx:finally:request`,
`htmx:response:error`, and `htmx:error`. Request state lives in `event.detail.ctx`: `sourceElement`,
`target`, `response.status`, `response.headers` (a `Headers` object), and `text`.

- `after:request` precedes the swap. Use `finally:request` for request cleanup, including cancellation and failure.
  If the original source was replaced, HTMX dispatches `finally:request` on `document`; body listeners do not receive it.
- A normal request's `ctx.status === 'swapped'` does not prove HTTP success; check the response status too.
  Locally cancelled preflight and extension-owned streams do not follow that normal swap status path.
- `after:settle` runs for each insertion before `after:swap`. Capture scroll intent before the swap and consume it
  after the whole swap, including OOB replacements. Resolve the live target before moving focus.
- The `htmx:confirm` adapter reads `ctx.confirm` and must call either `issueRequest()` or `dropRequest()` after
  preventing default behavior. Cancelling a dialog must release the queued request without sending it.
- Identify a history refetch from `ctx.request.headers['HX-History-Restore-Request']` in the swap event.
  Derive forced history scrolling from that request, so unrelated polling cannot consume a pending flag.

### Stream named events through hx-sse

The core and bundled extension must have the same base version. DartClaw carries one recorded hx-sse 4.0.0
cleanup correction: cancel the reader with a handled Promise before aborting the fetch, avoiding an unhandled
AbortError on terminal close. `VENDORS.md` records the original and patched checksums.
The stream root connects and names its terminal event:

```html
<div id="streaming-msg" hx-sse:connect="/events" hx-sse:close="done">
  <div id="streaming-content"></div>
  <div id="tool-container"></div>
</div>
```

Named events dispatch DOM events instead of using the removed `sse-swap` attribute. The chat controller listens to
`htmx:sse:before:message`, reads `detail.message.event`/`data`, and supplies its `htmx.swap({...})` Promise to
`detail.waitUntil(...)`. This keeps delta insertion, tool cards, OOB tool results, and terminal handling ordered.
The existing server event names remain `delta`, `tool_use`, `tool_result`, `turn_cancelled`, `turn_error`, and `done`.

Use `htmx:sse:close`'s `detail.reason`, rather than the old event-detail shape. A refused initial connection may
never enter the SSE lifecycle. If Send already admitted the turn, connection failure is not turn completion:
retain input and observe the matching turn ID through the existing status endpoint, keeping Stop available when
cancellable. Matching terminal status ends that restriction; let the transcript refresh attempt settle before
permitting another send so its swap cannot overwrite the next stream. A failed refresh reports its error and restores
controls. The extension clears HTMX's default 60-second request timer after accepting stream headers; do not add a separate turn timeout here.

Required response headers:

```http
Content-Type: text/event-stream
Cache-Control: no-cache
X-Accel-Buffering: no
```


---


## Asset Rules

- Pin HTMX and its bundled hx-sse extension to the same exact version
- Vendor HTMX and its extensions under `lib/src/static/` and load them same-origin; DartClaw contacts no CDN at
  runtime, and `dev/tools/fitness/check_no_external_origins.sh` fails the build if one reappears
- Record the upstream URL and published SRI hash in `VENDORS.md` so vendored bytes stay verifiable once `integrity`
  is absent from same-origin script tags
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


## Browser verification

After changing this integration, regenerate embedded assets and run the explicit browser proof from the workspace root:

```sh
dart run dev/tools/embed_assets.dart
dart test --reporter=failures-only --run-skipped packages/dartclaw_runtime/test/integration/htmx4_browser_test.dart
```

This uses real HTTP routes and a deterministic harness, with no provider credentials. Chrome or Chromium is required;
set `CHROME_BIN` when it is outside the detected installation paths. An explicit run fails if the browser is missing.
Screenshots default to `.agent_temp/htmx4-browser`; `DARTCLAW_HTMX4_ARTIFACT_DIR` overrides that directory.

## Checklist

- [ ] HTMX assets are pinned and use real SRI hashes where applicable
- [ ] Navigation uses explicit HTMX behavior where predictability matters
- [ ] Fragment/full-page routing handles history restore correctly
- [ ] Responses that vary by `HX-Request` send `Vary: HX-Request`
- [ ] SSE endpoints send the required stream headers
- [ ] Untrusted data is not inserted into `hx-on` or `js:` expressions
