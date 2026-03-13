# UI Smoke Test — DartClaw Web UI

Concrete test cases for the DartClaw web UI. Each test has explicit steps and pass/fail criteria.
Run using the `cc-workflows:visual-validation-specialist` agent with chrome-devtools MCP.
See `docs/guidelines/VISUAL-VALIDATION-WORKFLOW.md` for server setup and tooling conventions.

**Scope**: core user flows and all implemented pages. Not exhaustive — covers happy path + known failure modes.

---

## Auth & Navigation

### TC-01: Token URL Auto-Authentication
**Steps:**
1. Open `http://localhost:3333/?token=<TOKEN>` in a fresh browser context (no existing session cookie)

**Pass:** Redirects to `/sessions/<id>` or empty state — app loads, no login form shown
**Fail:** Login form appears requiring manual token entry

---

### TC-02: Login Form Fallback
**Steps:**
1. Open `http://localhost:3333/login` directly
2. Enter the correct token in the input field
3. Click "Sign In ❯"

**Pass:** Redirects to app; session cookie set
**Fail:** "Invalid token" error with correct token, or no redirect

---

### TC-03: Login Page Structure
**Steps:**
1. Navigate to `/login`

**Pass:**
- `❯ DartClaw` logo in accent color (`--accent`)
- Card with visible border/shadow
- Token input (type=password)
- "Remember this device" checkbox
- "Sign In ❯" button
- Footer hint text with `<code>` styled token path

**Fail:** Missing any of the above, or unstyled (hard-coded colors instead of CSS tokens)

---

## Core Pages

### TC-04: Empty State
**Steps:**
1. Navigate to `/` with no sessions (or delete all sessions)

**Pass:**
- Sidebar visible at desktop with `+ New Session` button
- Sidebar has **SYSTEM nav section** with Health, Settings, Memory, Scheduling, and Tasks links
- Chat area: empty state illustration, "No messages yet" heading, subtext
- Mobile (375px): hamburger visible, sidebar hidden

**Fail:** No system nav in sidebar; empty state missing; sidebar visible at mobile

---

### TC-05: Chat Page — Layout & Navigation
**Steps:**
1. Open a session at `/sessions/<id>`
2. Check topbar, sidebar, and system nav

**Pass:**
- Editable title input in topbar
- **ℹ button** in topbar (links to `/sessions/<id>/info`)
- Reset button visible (hidden at mobile)
- Sidebar shows active session with accent left-border
- Sidebar has **SYSTEM nav section**: Health, Settings, Memory, Scheduling, Tasks
- No console errors

**Fail:** Missing ℹ button, missing system nav, no active state on session

---

### TC-06: Chat Page — Messages
**Steps:**
1. Open a session with at least one exchange (user + assistant message)

**Pass:**
- User message: `.msg-user` class, "You" role label
- Assistant message: `.msg-assistant` class, "Assistant" role label, markdown rendered
- Messages scroll; input fixed at bottom
- Send button disabled when textarea empty
- No horizontal overflow at any viewport

**Fail:** Messages unstyled, markdown not rendered, layout broken

---

### TC-07: Health Dashboard
**Steps:**
1. Navigate to `/health-dashboard`

**Pass:**
- Status hero card: icon (✓/⚠/✗), status text, uptime, version
- Services section: WORKER, DATABASE, SESSIONS, STORAGE cards with colored badges
- Sidebar SYSTEM nav: **Health (active)**, Settings, Memory, Scheduling, Tasks — all visible
- "← Back" in topbar
- No console errors

**Fail:** Missing any service card, Scheduling absent from nav, unstyled badges

---

### TC-08: Settings Page
**Steps:**
1. Navigate to `/settings`

**Pass:**
- Tabbed editor visible with sections: Agent, Server, Sessions, Memory, Scheduling, Channels, Security
- Channel cards visible for WhatsApp, Signal, and Google Chat
- Security card shows active guard names (Command-Guard, File-Guard, Network-Guard)
- Scheduling card links navigate correctly
- Sidebar SYSTEM nav: Health, **Settings (active)**, Memory, Scheduling, Tasks — all visible

**Fail:** Missing cards, broken links, Scheduling missing from nav

---

### TC-09: Scheduling Page
**Steps:**
1. Navigate to `/scheduling`
2. At 375px viewport, scroll the jobs table horizontally

**Pass:**
- Heartbeat card with pulse icon (animated green if active; static grey if disabled)
- Status badge: "Active" or "Disabled"
- Jobs table: empty state row if no jobs configured
- Mobile: table scrolls horizontally; a **visible fade gradient** appears at the right edge of the table container (verify in browser — CSS may be present in source but not render if `position` is wrong)
- Sidebar SYSTEM nav: Health, Settings, Memory, **Scheduling (active)**, Tasks

**Fail:** Pulse animation missing when active, no empty state, Scheduling not marked active in nav, fade gradient not visually present at mobile (check `getComputedStyle` on `.table-wrap::after` if uncertain)

---

### TC-10: Session Info Page
**Steps:**
1. Open a session, click the **ℹ button** in the topbar (verify discoverability — do not type URL directly)

**Pass:**
- Navigates to `/sessions/<id>/info`
- Session title and UUID shown; UUID truncated with ellipsis if long
- Token grid: Input / Output / Total cells (values or "—" if no completed turns)
- Session Details: Messages, Created, Session ID
- "← Back to Chat" link in topbar
- No console errors

**Fail:** ℹ button missing or broken link; UUID overflows; page unstyled

---

### TC-11: Styled 404 Page
**Steps:**
1. Navigate to `/nonexistent-page`

**Pass:**
- Full themed page (NOT plain text "Route not found")
- Large `404` code in `--fg-overlay` color
- "Page Not Found" heading in `--fg`
- "← Back to Home" button navigates to `/`
- Catppuccin tokens active (check `--bg-base` is correct for current theme)

**Fail:** Plain text "Route not found", no styling, no back link

---

## Interactions

### TC-12: Theme Toggle
**Steps:**
1. Click the theme toggle button (top right of topbar)
2. Reload the page
3. Click toggle again to switch back

**Pass:**
- Toggle switches between Catppuccin Mocha (dark) and Latte (light) immediately
- All surfaces update (sidebar, topbar, messages, inputs)
- **No FOUC** on reload — theme applies before any paint (check via slow connection simulation or repeated reload)
- `data-theme="light"` set on `<html>` in light mode
- `localStorage.getItem('dartclaw-theme')` returns `'light'` in light mode

**Fail:** Flash of dark theme before light applies on reload; theme not persisting; partial surface updates

---

### TC-13: Mobile Sidebar
**Steps:**
1. Resize to 375px
2. Click hamburger (☰)
3. Click × or backdrop

**Pass:**
- Hamburger visible; sidebar hidden at 375px
- Sidebar opens as full-height overlay with semi-transparent backdrop
- SYSTEM nav links visible in sidebar overlay
- × closes overlay; backdrop click closes overlay
- No layout shift in underlying content when overlay opens

**Fail:** Sidebar visible at mobile without opening, overlay missing backdrop, × not working

---

### TC-14: Session Rename
**Steps:**
1. Click session title in topbar to focus the input
2. Clear it, type "Renamed Session", press Enter
3. Check sidebar and browser tab
4. Reload page

**Pass:**
- Sidebar item title updates immediately (no reload)
- Browser tab title updates to `"Renamed Session - DartClaw"` immediately (no reload)
- After reload: title persists as "Renamed Session"

**Fail:** Title not updating in sidebar, tab title stale without reload, rename not persisting

---

### TC-15: New Session
**Steps:**
1. Click `+ New Session` in the sidebar

**Pass:**
- New session created, browser navigates to `/sessions/<new-id>`
- New session at top of sidebar list
- Empty chat state shown in main area
- Title shows "New Session" in topbar input
- ℹ button present in topbar

**Fail:** No navigation, session not in sidebar, ℹ button missing on new session

---

### TC-16: System Navigation (Cross-Page)
**Steps:**
1. From any chat page, click "Health" in sidebar SYSTEM nav
2. From health dashboard, click "Settings"
3. From settings, click "Scheduling"
4. From scheduling, click "Health"

**Pass:** Each navigation lands on the correct page; active nav item highlighted; the System nav consistently includes Health, Settings, Memory, Scheduling, and Tasks

**Fail:** Any link missing, wrong page loads, active state not updated

---

## Error & Edge Cases

### TC-17: Guard Block Message (if available)
**Prerequisite:** Requires a session where a guard blocked a message (content: `[Blocked by guard: reason]`)

**Creating test data:** Send a message that triggers a guard (e.g. a blocked shell command). Alternatively, insert a message directly via the API or SQLite with content `[Blocked by guard: test reason]` in an assistant message row.

**Steps:**
1. Open the session containing a guard block message

**Pass:**
- Message renders as `.msg-guard-block` card (not as plain assistant text)
- 🛡 icon visible
- "GUARD BLOCKED" label in red uppercase
- Reason text below
- Red left-border, amber-tinted background

**Fail:** Renders as plain text assistant message

---

### TC-18: Turn Failed Message (if available)
**Prerequisite:** Requires a session where a turn failed (content: `[Turn failed]` or `[Turn failed: reason]`)

**Creating test data:** Kill the server mid-turn to force a crash, then reload. Alternatively, insert an assistant message with content `[Turn failed: test error]` directly in the session's NDJSON file or via SQLite.

**Steps:**
1. Open the session containing a failed turn

**Pass:**
- Message renders as `.msg-turn-failed` card (not as plain assistant text)
- ⚠ icon visible
- "TURN FAILED" label in amber uppercase
- Optional detail text below

**Fail:** Renders as plain text assistant message indistinguishable from success

---

## Extended Surface

### TC-19: Tasks List Page
**Steps:**
1. Navigate to `/tasks`
2. Verify filters, task groups, and agent pool summary

**Pass:**
- Status and type filters are visible
- "New Task" button opens the create-task dialog
- Agent pool section renders without console errors
- Existing tasks are grouped by status with clickable task titles
- Sidebar SYSTEM nav includes **Tasks (active)** plus Health, Settings, Memory, Scheduling

**Fail:** Missing filters/dialog, broken task links, stale nav state, or console errors

---

### TC-20: Task Detail Progression
**Steps:**
1. Open a draft task at `/tasks/<id>`
2. Click **Start Task**
3. Observe the detail page without manually reloading

**Pass:**
- Draft task shows **Start Task** action
- After start, page transitions away from draft state
- Queued/running state is visible on the same page without requiring manual reload
- Once session exists, the embedded task session shows at least the initial user prompt
- No console errors

**Fail:** Page remains stale after start, still shows draft/start UI, or requires manual reload to reveal task session/status

---

### TC-21: Memory Dashboard
**Steps:**
1. Navigate to `/memory`
2. Switch between memory file tabs
3. Toggle Raw / Rendered mode

**Pass:**
- Overview, pruning, search/index, memory files, and daily logs sections render
- Sidebar SYSTEM nav includes **Memory (active)** plus Health, Settings, Scheduling, Tasks
- File tab content loads without full page reload
- Raw / Rendered toggle updates already-loaded previews
- No console errors

**Fail:** Missing sections, broken tab loading, broken nav state, or console errors

---

### TC-22: Memory Dashboard — Prune Action
**Steps:**
1. Navigate to `/memory`
2. Click "Prune Now"
3. Click "Confirm Prune?" within 4 seconds

**Pass:**
- First click changes button to "Confirm Prune?" (amber)
- Confirm click changes to "Pruning..." (disabled)
- On success: "Done!" (green), then resets to "Prune Now" after 2s
- Overview metrics and pruner history refresh immediately after prune (not after 30s poll)

**Fail:** No confirmation step; metrics stale after prune; button stuck in disabled state

---

### TC-23: Scheduling — Job CRUD
**Steps:**
1. Navigate to `/scheduling`
2. Click "Add Job" to open the form
3. Fill in name, schedule (`0 9 * * *`), prompt, delivery
4. Click "Save Job"
5. Click "Edit" on the new job, change schedule, click "Update Job"
6. Click "Delete" on the job, confirm

**Pass:**
- Form opens/closes with "Add Job" toggle
- Cron preview shows human-readable description (e.g., "Daily at 9:00 AM")
- Job appears in table after save; page refreshes via HTMX
- Edit pre-populates fields; name field disabled during edit
- Delete shows confirmation row with "Confirm Delete" / "Cancel"
- Job names with special characters (`"`, `'`, `<`, `&`) render safely in confirmation

**Fail:** Form doesn't open; cron preview missing; delete confirmation shows raw HTML; special characters break layout

---

### TC-24: Restart Banner
**Steps:**
1. Change a restart-requiring setting (e.g., server port) on `/settings`
2. Observe restart banner appearance
3. Click dismiss
4. Reload page

**Pass:**
- Yellow restart banner appears listing changed fields
- "Restart" and "Dismiss" buttons functional
- Dismiss hides banner for current page session
- Banner reappears after page reload (if restart still pending)

**Fail:** No banner on restart-pending config change; dismiss permanently hides banner

---

## Regression Checks

These are previously fixed issues. Flag immediately if any regress.

| ID | Issue | Quick Check |
|----|-------|------------|
| R-01 | Sidebar visible at mobile | At 375px, sidebar must be hidden behind hamburger |
| R-02 | FOUC on light theme reload | Reload in light mode — no dark flash |
| R-03 | 404 plain text | `/nonexistent` must show styled page |
| R-04 | Token URL shows login form | `/?token=<valid>` must auto-authenticate |
| R-05 | No system nav in chat sidebar | Chat page sidebar must have Health/Settings/Scheduling |
| R-06 | Missing ℹ button | Chat topbar must have session info link |
| R-07 | Tab title stale after rename | `document.title` must update immediately on rename |
| R-08 | Scheduling missing from system nav | All 3 system pages must show all 3 nav links |
| R-09 | Scheduling table fade not visible at mobile | At 375px, right-edge fade gradient must be visually present (not just in CSS source) |
