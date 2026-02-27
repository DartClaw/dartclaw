# Visual Validation Workflow — DartClaw

Project-specific conventions for running visual validation of the DartClaw web UI.
Use this alongside `docs/testing/UI-SMOKE-TEST.md` which defines the actual test cases.

---

## Server Setup

```bash
# Check if server is running
lsof -ti:3333

# Start if not running (from repo root)
dart run dartclaw_cli:dartclaw serve --port 3333 > .agent_temp/visual-validation/server.log 2>&1 &

# Get auth token
grep "token=" .agent_temp/visual-validation/server.log | tail -1
```

Default port is 3333. Token is persistent across restarts (stored in data dir).

## Authentication

The server uses token-based auth with a session cookie.

**To authenticate**: navigate to `http://localhost:3333/?token=<TOKEN>`
Expected: auto-redirects to the app — no login form interaction required.

**If login form appears**: the token URL failed. Common cause: spaces embedded in the token
from copy-paste line-wrapping (`%20` in the logged URL). Strip any whitespace from the token
and retry. The server strips whitespace server-side, but browser URL bars may encode it oddly.

**Login form fallback**: if the form appears, it should be pre-filled with the token from the
URL — just click Sign In without retyping.

## Tools

Use **chrome-devtools MCP** exclusively for browser interaction. Do not use Playwright or
other tools unless chrome-devtools is unavailable.

Key chrome-devtools operations used in validation:
- `navigate_page` — open URLs
- `take_screenshot` — capture visual state
- `resize_page` / `emulate` — test responsive layouts
- `evaluate_script` — inspect DOM state, computed styles, localStorage
- `get_console_message` / `list_console_messages` — check for JS errors
- `click`, `fill`, `type_text` — drive interactions

## Viewports

Always test at two viewports unless the test case specifies otherwise:

| Name    | Width | Notes |
|---------|-------|-------|
| Desktop | 1280px | Default; sidebar visible |
| Mobile  | 375px | Sidebar hidden behind hamburger |

## Screenshots

Save to `.agent_temp/visual-validation/screenshots/` using the naming scheme:
`<NN>-<page>-<viewport>[-<state>].png`

Examples: `01-login-desktop.png`, `04-chat-mobile-sidebar-open.png`, `08-404-desktop.png`

## Checking Design Tokens

The UI uses Catppuccin Mocha (dark) and Latte (light) via CSS custom properties.
To verify tokens are active (not hard-coded values), use `evaluate_script`:

```js
getComputedStyle(document.documentElement).getPropertyValue('--bg-base').trim()
// Dark: '#1e1e2e'  |  Light: '#eff1f5'
```

If the value is empty or wrong, the design token system is broken for that page.

## CSS Presence ≠ Correct Rendering

CSS found in source does not guarantee it renders as expected. Always verify visually in the browser. Known gotchas:

- `position: sticky; float: right` on a `::after` pseudo-element — browsers ignore it; the element doesn't render. Use `position: absolute` instead.
- `overflow: hidden` on an ancestor may clip absolutely-positioned pseudo-elements — verify the stacking context.
- `getComputedStyle` can return a value for a rule that is syntactically valid but has no visual effect (e.g. a gradient on a zero-height element).

When a test requires verifying a CSS-driven visual (gradient, animation, overlay), always take a screenshot **and** check `getComputedStyle` — neither alone is sufficient.

## Console Error Check

Run after loading each page:

```js
// No errors expected — any error is a FAIL
```

Use `list_console_messages` and flag any `error`-level entries as P2 issues minimum.

## Report Format

Write findings to `.agent_temp/visual-validation/findings-<YYYY-MM-DD>.md`.

Structure each entry as:

```
### TC-<ID>: <Test Name> — PASS | PARTIAL | FAIL
**Viewport:** desktop / mobile / both
**Issues:**
- [P1/P2/P3] Specific issue description
**Notes:** What is working correctly
**Screenshots:** list of files captured
```

Finish with a summary table:

| Priority | Count | Items |
|----------|-------|-------|
| P1 | N | ... |
| P2 | N | ... |
| P3 | N | ... |
| PASS | N | ... |

## Severity Guide

| Level | Meaning |
|-------|---------|
| P1 | Broken — feature unusable, data loss risk, or security issue |
| P2 | Major UX gap — discoverability broken, flow dead-ends, unstyled error states |
| P3 | Polish — minor visual inconsistency, stale data, minor UX friction |
