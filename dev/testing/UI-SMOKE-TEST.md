# UI Smoke Test — DartClaw Web UI

Concrete test cases for the DartClaw web UI. Each test has explicit steps and pass/fail criteria.
Run using the `andthen:visual-validation` skill with chrome-devtools MCP.
See `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` for tooling conventions and screenshot/reporting format.

**Scope**: smoke-only — happy path + known failure modes for every shipped page. **Not exhaustive**:
deeper visual/UX validation lives in feature-specific test plans. Channel pairing flows are out of
scope (separate channel-E2E test suite).

**Last refreshed for**: DartClaw 0.24

---

## Setup

### Recommended path — `plain` testing profile

```bash
bash dev/testing/profiles/plain/run.sh
```

| Setting | Value |
|---|---|
| URL | `http://localhost:3335` (profile sets `port: 3335`) |
| Token | `devtoken0` (`dev/testing/profiles/plain/data/gateway_token`) |
| Auto-auth URL | `http://localhost:3335/?token=devtoken0` |
| Pre-seeded | 1 main session (Workspace/Agent), 2 scheduled jobs, workspace memory files, guards on |
| Not seeded | tasks, workflow runs, projects — empty-state versions of those pages are testable; deeper TCs note when seeding is required |
| Channels | all disabled |

### Generic dev server (no profile)

```bash
dart run dartclaw_cli:dartclaw serve --port 3333
```

Default port 3333. Token is logged on startup. Use only when you need a clean install for a TC the
seeded profile can't represent (e.g., truly empty initial state — see TC-04 note).

### Cross-cutting setup

- **Viewports**: desktop 1280px and mobile 375px unless a TC says otherwise.
- **Console errors**: any `error`-level message during a TC fails it, except the expected
  main-document 404 entry in TC-12. Subresource, script, API, and all other errors still fail.
- **Provider badges**: every session/task/channel/workflow surface in the sidebar may render a
  `provider-badge-{claude|codex}` chip after the title — that's expected, not a layout glitch.

---

## Auth & Navigation

### TC-01: Token URL Auto-Authentication
**Steps:**
1. Open `http://localhost:3335/?token=devtoken0` in a fresh browser context (no session cookie)

**Pass:** Redirects to `/sessions/<id>` or empty state; no login form shown
**Fail:** Login form appears requiring manual token entry

---

### TC-02: Login Form Fallback
**Steps:**
1. Open `http://localhost:3335/login`
2. Enter the correct token, click "Sign In ❯"

**Pass:** Redirects to app; session cookie set
**Fail:** "Invalid token" with correct token, or no redirect

---

### TC-03: Login Page Structure
**Steps:**
1. Navigate to `/login`

**Pass:**
- CRT mascot and `DartClaw` wordmark
- Card with visible border/shadow
- Token input (type=password), "Remember this device" checkbox, "Sign In ❯" button
- Footer hint with the `<code>`-styled `dartclaw token show` retrieval command

**Fail:** Missing any of the above; hard-coded colors instead of tokens

---

## Sidebar Anatomy

### TC-04: Sidebar Sections (cross-cutting reference)
**Steps:**
1. Authenticate; observe the sidebar at desktop 1280px

**Pass — sections appear in this order, with sections silently omitted when empty:**
1. **Workspace** (`Workspace` label) — single `Agent` entry linking to the main session
2. **Channels** (only if any channel is enabled) — `DMs` and/or `Groups` subsections
3. **Running** (only if at least one task is active) — task rows with live elapsed badge
4. **Workflows** (only if a workflow run is live) — run rows with `N/M` step progress
5. **Chats** (always) — `New Chat` button, then chat rows; "No chats yet" placeholder when empty
6. **Archived** (collapsible — only if any archived chats exist)
7. **System** disclosure (always — fixed at the rail bottom; see TC-17 for full enumeration)

**Fail:** sections render in wrong order; `New Chat` button labeled `+ New Session` (legacy);
`Workspace` section missing when a main session exists; System disclosure absent or permanently expanded

**Note:** The sidebar's exact content depends on configuration — Channels needs an enabled channel;
Workspace needs a main session. The plain profile shows: Workspace + Chats + System.

---

## Core Pages

### TC-05: Empty Chat Initial State
**Steps:**
1. Plain profile: navigate to `/` and click `Agent` in Workspace (main session has no exchanges yet),
   OR start with a fresh data dir for a true zero-session state

**Pass:**
- Sidebar visible at desktop with sections per TC-04
- Chat area: centered prompt hero with mascot, "Welcome back" heading, and start-conversation subtext
- Input fixed at bottom; Send button disabled while textarea is empty
- Mobile (375px): hamburger visible, sidebar hidden behind it

**Fail:** No system nav in sidebar; prompt hero or mascot missing; sidebar visible at mobile

---

### TC-06: Chat Page — Layout & Topbar
**Steps:**
1. Open Agent in Workspace, then open a user-created chat at `/sessions/<id>`

**Pass:**
- Agent keeps the fixed Workspace identity; the user-created chat has an editable title input
- **ℹ button** in topbar links to `/sessions/<id>/info`
- Theme toggle and (desktop) Reset button in topbar
- Sidebar shows the active session with accent left-border (Workspace/Agent stays highlighted for the main session)
- No console errors

**Fail:** ℹ button missing; no active state on the session; broken topbar

---

### TC-07: Chat Page — Messages
**Steps:**
1. Open a session with at least one user + assistant exchange (send one if needed)

**Pass:**
- User: `.msg-user`, "You" role label
- Assistant: `.msg-assistant`, "Assistant" role label, markdown rendered
- Messages scroll; input fixed at bottom; no horizontal overflow at any viewport
- Send button enabled when textarea has content

**Fail:** Messages unstyled; markdown not rendered; layout broken at mobile

---

### TC-07A: Chat Page — Rich Composer
**Steps:**
1. Open a session at `/sessions/<id>`
2. Focus the composer
3. Type `@`, then dismiss the reference palette
4. Drag or paste a small text file into the composer
5. Start a send, then observe the streaming state

**Pass:**
- Composer renders as the rich shell, not a plain textarea-only form
- Reference palette opens with selectable context rows and dismisses cleanly
- Attachment chip appears with filename/status and can be removed before send
- Send/stop control switches state during streaming without layout shift
- No horizontal overflow or iOS-scale input at mobile width

**Fail:** Palette inaccessible by keyboard; chips missing or stuck; send/stop state ambiguous; composer overflows on mobile

---

### TC-08: Health Dashboard
**Steps:**
1. Navigate to `/health-dashboard`

**Pass:**
- Status hero: status icon + uptime + version
- KPI row: UPTIME, SESSIONS, DB SIZE, TASK ARTIFACTS
- Status panel includes Worker state; the Storage service card reports Database and Sessions storage, with optional Pub/Sub status when configured
- Audit table renders (rows or "no events"); expandable rows for entries with detail
- SYSTEM nav: **Health (active)** highlighted
- No console errors

**Fail:** Missing service card; audit table broken; unstyled badges

---

### TC-09: Settings Page
**Steps:**
1. Navigate to `/settings`

**Pass:**
- Tabbed editor with sections including: Agent, Workflows, Server, Sessions, Memory, Context,
  Scheduling, Channels, Providers, Security
- Channel cards visible for WhatsApp, Signal, Google Chat (each links to `/settings/channels/<type>`)
- Security card lists active guards
- Providers section shows configured harnesses (Claude/Codex) with status
- SYSTEM nav: **Settings (active)**

**Fail:** Missing cards; broken channel-detail links; Providers absent

---

### TC-10: Scheduling Page
**Steps:**
1. Navigate to `/scheduling`
2. At 375px, scroll the jobs table horizontally

**Pass:**
- Heartbeat card: pulse icon (animated green when active; static grey when disabled)
- Status badge: "Active" or "Disabled"
- Jobs table populated (plain profile seeds 2 jobs) or empty-state row
- Mobile: a **visible fade gradient** appears at the right edge of the scroll container — verify
  in browser, not just in CSS source (see VISUAL-VALIDATION-WORKFLOW.md "CSS presence ≠ correct rendering")
- SYSTEM nav: **Scheduling (active)**

**Fail:** No pulse when active; fade gradient invisible at mobile; nav not active

---

### TC-11: Session Info Page
**Steps:**
1. Open a session, click the **ℹ button** in the topbar (verify discoverability — do NOT type the URL)

**Pass:**
- Lands on `/sessions/<id>/info`
- Title and UUID shown; UUID truncated with ellipsis when long
- Token grid: Input / Output / Total (or "—" for sessions with no completed turns)
- Session details: Messages, Created, Session ID
- "← Back to Chat" link in topbar
- No console errors

**Fail:** ℹ button missing; UUID overflows; page unstyled

---

### TC-12: Styled 404 Page
**Steps:**
1. Navigate to `/nonexistent-page`

**Pass:**
- Main-document response status is `404`
- Themed page (NOT plain text "Route not found")
- Large `404` in `--fg-overlay`
- "Page Not Found" heading in `--fg`
- "← Back to Home" navigates to `/`
- Catppuccin tokens active (`--bg-base` matches current theme)

**Fail:** Plain text fallback; no styling; no back link

---

## Interactions

### TC-13: Theme Toggle
**Steps:**
1. Click the theme toggle (top right of topbar)
2. Reload the page
3. Toggle back

**Pass:**
- Switches between Catppuccin Mocha (dark) and Latte (light) immediately
- All surfaces update (sidebar, topbar, messages, inputs)
- **No FOUC on reload** — theme applies before paint
- `<html data-theme="light">` in light mode; `localStorage.getItem('dartclaw-theme') === 'light'`

**Fail:** Flash of dark theme before light applies; theme not persisting; partial surface updates

---

### TC-14: Mobile Sidebar
**Steps:**
1. Resize to 375px
2. Click hamburger (☰)
3. Click × or backdrop

**Pass:**
- Sidebar hidden behind hamburger; opens as full-height overlay with semi-transparent backdrop
- All sidebar sections (per TC-04) render in the overlay
- Visible × in the drawer closes the overlay; backdrop click closes the overlay
- No layout shift in underlying content while overlay is open

**Fail:** Sidebar visible at mobile without opening; overlay missing backdrop; × not working

---

### TC-15: Session Rename
**Steps:**
1. Click session title in topbar; clear it; type "Renamed Session"; press Enter
2. Check sidebar and browser tab
3. Reload

**Pass:**
- Sidebar item updates immediately (no reload)
- Browser tab title updates to `"Renamed Session - DartClaw"` immediately
- After reload: title persists

**Fail:** Sidebar stale; tab title stale; rename not persisting

---

### TC-16: New Chat
**Steps:**
1. From an established chat, activate **`New Chat`** and note the new chat ID and Chats count
2. After navigation settles, activate **`New Chat`** again
3. Return to the established chat, activate **`New Chat`**, and confirm the noted draft reopens
4. Send a message in that draft; after it becomes an established chat, activate **`New Chat`** again
5. Confirm the new draft composer has focus without clicking it; established-chat composers do not autofocus

**Pass:**
- The first activation creates one draft and navigates to `/sessions/<new-id>`
- Sequential activation on that draft does not navigate, reload, or increase the Chats count
- Activation elsewhere reuses the same untouched draft, including across rapid or concurrent activation
- Once the draft contains a message, the next activation creates exactly one fresh draft
- New session at top of `Chats` list
- Empty chat state in main area; topbar input and chat row show "Untitled draft"
- New-chat composer receives focus; established-chat composer does not
- ℹ button present in topbar

**Fail:** Blank chats accumulate; current draft reloads; wrong draft reopens; session missing from sidebar; focus behavior wrong; ℹ button missing on a new session

---

### TC-17: System Navigation (Cross-Page)
**Steps:**
1. From any page, activate the bottom-left **System** disclosure
2. Walk through every System nav link in order, reopening the disclosure after each navigation
3. Confirm each lands on the correct page, its nav item is highlighted, and the collapsed trigger names it
4. Include a chat → dashboard → chat round trip and watch the browser's right edge during each entry transition

**Pass — full SYSTEM nav (registration order, conditional items in italic):**
Health → Settings → *Memory* → Knowledge → *Scheduling* → *Tasks* → *Projects* → *Workflows*

Timeline is nested under Knowledge: Knowledge → `/knowledge`, then its Timeline tab → `/knowledge/timeline`.
It does not render as a separate SYSTEM nav item.

Conditional items appear when:
- Memory — a workspace and an operational feature are configured
- Scheduling — heartbeat, a job, or a scheduled task is configured
- Tasks — a container, scheduled task, or channel task trigger is configured
- Projects — `projectService` is configured (any number of projects)
- Workflows — `workflowService` is configured

Plain profile typically shows all 8. The closed trigger reads `System` on chat pages and `System · <active page>` on a
System page. The popup opens above the footer and does not cover Extensions when that region exists.

The browser root stays exactly viewport-sized throughout the transition: no transient root scrollbar or horizontal
layout jump. Long dashboards continue to scroll inside `#main-content`.

**Fail:** Any link missing when its service is configured; wrong page loads; active state not updated; root scrollbar or
layout-width jump appears during navigation; dashboard content no longer scrolls internally

---

## Error & Edge Cases

### TC-18: Guard Block Message
**Prerequisite:** A session message rendered as a guard block (content begins `[Blocked by guard: …]`).
**Creating test data:** Trigger a blocked shell command, or insert an assistant message with that
content directly (NDJSON file or SQLite).

**Steps:**
1. Open the session

**Pass:**
- Message renders as `.msg-guard-block` (not plain assistant text)
- 🛡 icon, "GUARD BLOCKED" label in red uppercase, reason text below
- Red left-border, amber-tinted background

**Fail:** Renders as plain assistant text

---

### TC-19: Turn Failed Message
**Prerequisite:** A session with content `[Turn failed]` or `[Turn failed: reason]`.
**Creating test data:** Kill the server mid-turn, insert a synthetic assistant message, or use the automated crash-recovery smoke path as the behavioral proof before doing this visual check.

**Steps:**
1. Open the session

**Pass:**
- Renders as `.msg-turn-failed` (not plain assistant text)
- ⚠ icon, "TURN FAILED" label in amber uppercase, optional detail below

**Fail:** Indistinguishable from a successful assistant message

**Automated proof:** `dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/crash_recovery_smoke_test.dart` verifies orphaned turn cleanup across a real restart boundary and asserts the recovered session renders `.msg-turn-failed`.

---

## Tasks & Memory

### TC-20: Tasks List Page
**Steps:**
1. Navigate to `/tasks`

**Pass:**
- Status filter visible; no task-category filter or badge is present
- "New Task" button opens the create-task dialog
- Existing tasks grouped by status with clickable titles (or empty-state card "No tasks yet" when none)
- Execution Capacity / providers section renders without console errors
- SYSTEM nav: **Tasks (active)**

**Fail:** Filters or dialog missing; broken task links; console errors

---

### TC-21: Task Detail Progression *(requires a task to start)*
**Steps:**
1. Plain profile: create a draft task with **Needs worktree** off at `/tasks/<id>`; tasks requesting worktrees require a
   registered, ready Git project, while tasks declared with the `restricted` profile have no workspace mount
2. Click **Start Task** (or equivalent transition); do not manually reload afterwards

**Pass:**
- Draft state shows the start action; queued/running state takes over without reload
- Once a session is attached, the embedded task session shows at least the initial user prompt
- For tasks with `needsWorktree: true`: timeline / diff sections render after the first events
- No console errors

**Fail:** Page stale after start; manual reload required to see new state

---

### TC-22: Memory Dashboard
**Steps:**
1. Navigate to `/memory`
2. Switch between memory file tabs
3. Toggle Raw / Rendered

**Pass:**
- Overview, pruning, search/index, memory files, and daily logs sections render
- File tabs swap content without a full page reload
- Raw/Rendered toggle updates the loaded preview
- SYSTEM nav: **Memory (active)**

**Fail:** Missing sections; broken tab loading; console errors

---

### TC-23: Memory Dashboard — Prune Action
**Steps:**
1. On `/memory`, click "Prune Now"
2. Confirm in the shared confirmation dialog

**Pass:** A toast reports the archived and de-duplicated counts; overview metrics + pruner history refresh
immediately after success (not on the next 30s poll)
**Fail:** No confirmation dialog or outcome toast; metrics stale after a successful prune; control stuck disabled

---

### TC-24: Scheduling — Job CRUD
**Steps:**
1. On `/scheduling`, click "Add Job"; fill name, schedule (`0 9 * * *`), prompt, delivery
2. Save; then Edit, change schedule, Update; then Delete, confirm

**Pass:**
- Cron preview renders human-readable description
- Job appears in table after save (HTMX swap, no full reload)
- Edit pre-populates fields; name field disabled in edit mode
- Delete uses an inline confirmation row
- Job names containing `"` `'` `<` `&` render safely in the confirmation
- A newly written job is marked `Restart to run`, while a job already loaded by the running scheduler is not
- The restart banner appears with the successful mutation response, without a page reload

**Fail:** Form doesn't open; cron preview missing; raw HTML in confirmation; layout breaks on special chars

---

### TC-25: Restart Banner
**Steps:**
1. Change a restart-requiring setting (e.g., server port) on `/settings`
2. Observe the banner; click Dismiss; reload

**Pass:**
- Yellow banner lists changed fields with Restart + Dismiss buttons
- Dismiss hides banner for the current page session only
- Banner reappears after reload while restart is still pending

**Fail:** No banner on restart-pending change; dismiss permanently hides the banner

---

## Workflows, Projects

### TC-26: Workflows List
**Steps:**
1. Navigate to `/workflows`

**Pass:**
- Status filter chips at top of the run list
- Run list: rows with progress bar and step counter, OR empty state "No workflow runs found." when none
- Workflow definition browser: per-card launch form with Run button + variable inputs (validation
  shown inline when a required variable is empty)
- SYSTEM nav: **Workflows (active)**

**Fail:** Definition browser missing; launch form has no validation; nav not active

---

### TC-27: Workflow Run Detail *(requires a launched run)*
**Steps:**
1. Launch any workflow definition with valid inputs (or open an existing run)
2. Open `/workflows/<runId>`

**Pass:**
- Metadata card (run id, definition name, started-at, status)
- Top-level progress bar
- Action buttons reflect run state (Pause/Resume/Cancel; Approve/Reject during an approval hold)
- Vertical step pipeline with connectors; clicking a step lazily loads
  `/workflows/<runId>/steps/<N>` — session messages, artifacts, context I/O, token metrics
- Shared context viewer renders without errors

**Fail:** Step expansion does a full page reload; missing approval controls during hold; broken pipeline

---

### TC-28: Workflow Approval Pause UX *(requires a workflow with an approval step)*
**Steps:**
1. Launch a workflow that hits an approval step; observe the run detail page

**Pass:**
- Approval step row shows "Approval request:" message + optional feedback
- Approve and Reject buttons render; Reject prompts a confirm via `hx-confirm`
- After Approve, run resumes; after Reject, run cancels — both update without a full reload

**Fail:** Approval message missing; buttons absent; reject lacks confirm; manual reload required

---

### TC-29: Projects List
**Steps:**
1. Navigate to `/projects`

**Pass:**
- Projects list with rows showing display name, URL, status badge — OR empty state
  "No projects registered" / "Add a project to run tasks against external repositories."
- Add-project form available
- Per-row actions visible for ready projects
- SYSTEM nav: **Projects (active)**

**Fail:** Empty state shows raw HTML or unstyled; nav not active

---

### TC-30: Retired — Canvas Admin

**N/A:** Canvas Admin was removed in v0.23. The ID remains reserved so later case references stay stable.

---

### TC-31: Channel Detail (Unpaired State)
**Steps:**
1. From `/settings`, click the WhatsApp / Signal / Google Chat channel card

**Pass:**
- Loads `/settings/channels/<type>`
- When channel is disabled in config (plain profile): page renders in unpaired/disabled state with
  a clear pointer to enable + pair (e.g., link to `/pairing` for WhatsApp/Signal)
- Mention/group access sections render with the correct "disabled" visual class
- "← Settings" link in topbar returns to settings (labelled with the destination, not "Back")

**Fail:** Plain HTML stub or 500 error in unpaired state; broken back link

---

## Regression Checks

Previously fixed issues. Flag immediately if any regress.

| ID | Issue | Quick Check |
|----|-------|------------|
| R-01 | Sidebar visible at mobile | At 375px, sidebar hidden behind hamburger |
| R-02 | FOUC on light theme reload | Reload in light mode — no dark flash |
| R-03 | 404 plain text | `/nonexistent` shows the styled page |
| R-04 | Token URL shows login form | `/?token=<valid>` auto-authenticates |
| R-05 | No SYSTEM nav in chat sidebar | Chat-page sidebar carries the SYSTEM nav (TC-17) |
| R-06 | Missing ℹ button | Chat topbar carries the session-info link |
| R-07 | Tab title stale after rename | `document.title` updates immediately on rename |
| R-08 | SYSTEM nav incomplete | Every configured system page appears in nav (TC-17) |
| R-09 | Scheduling table fade missing at mobile | Right-edge fade gradient visually present at 375px |
| R-10 | Sidebar new-chat button mislabelled | Button reads `New Chat`, not legacy `+ New Session` |
| R-11 | Workspace section missing | Main session always rendered under Workspace, not buried in Chats |
| R-12 | Workflow step expansion full-page reload | Step row expansion is HTMX-driven, no full reload |
| R-13 | External runtime dependency returns | Embedded fallback serves fully offline — run § R-13 protocol below |
| R-14 | Workflow run identity truncates | At 320px, a real UUID wraps and remains fully readable without horizontal overflow |

### R-13 protocol

Every runtime dependency (htmx, marked, JetBrains Mono) is vendored and served same-origin. A re-introduced CDN
reference degrades silently — the UI still renders, just in system monospace — so this check runs against the release
binary's embedded fallback with the network cut, not against a dev server.

1. `bash dev/tools/build.sh`, then resolve `BIN="$PWD/build/bin/dartclaw"` as an absolute path.
2. Create a temporary directory outside the checkout and copy the visual seed into it:
   `R13_DATA="$(mktemp -d)" && cp -R dev/testing/profiles/visual/data/. "$R13_DATA"`.
3. Launch `(cd "$R13_DATA" && "$BIN" --config "$R13_DATA/dartclaw.yaml" serve --data-dir "$R13_DATA" --port 3338)`.
   The launched process arguments must contain `--port 3338` and must contain neither `--dev` nor `--source-dir`, so
   source-tree assets cannot satisfy the check. Confirm with `ps -o args= -p <pid>`.
4. Start the browser with every non-`localhost` origin unreachable, e.g. Chromium with
   `--host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost"`. Block uniformly rather than per-domain, so a future
   CDN host nobody predicted is blocked too.
5. Load `/`, navigate to `/tasks` through an `hx-get` interaction, and open the seeded chat session.
6. For each weight 400, 500 and 600, evaluate `document.fonts.load('<weight> 16px "JetBrains Mono"', 'DartClaw 0123')`
   and the same call with latin-ext text `'Pchnąć w tę łódź jeża'`. Each must resolve to a **non-empty** array whose
   matching `FontFace` entries report `status === 'loaded'`, `family === 'JetBrains Mono'` and the requested weight.
   `document.fonts.check(...)` may supplement this but cannot replace it — it returns `true` for a system fallback.
7. Confirm the network log records same-origin `200` loads for `htmx.min.js`, `marked.min.js` and both `font/woff2`
   subsets, that the `hx-get` swapped `#main-content` without a full page load, that the seeded assistant message
   rendered as HTML rather than literal `**markdown**`, that **zero** requests went to a non-`localhost` origin, and
   that the console recorded no `error`-level entries.
8. Confirm the preloaded font is actually consumed: `jetbrains-mono-latin.woff2` appears **once** in the network log,
   and no "preloaded using link preload but not used" warning is logged. A preload missing its `crossorigin`
   attribute fetches the font twice and only warns, so neither a `200` nor a clean error log would catch it.
9. Confirm the weight axis really renders. The subsets are variable fonts, so all three weights come from one file
   and a broken axis would still report three loaded `FontFace`s at the right descriptors. Draw the same glyphs to a
   canvas at weight 400 and at 600 and require materially more ink at 600 (~1.2x opaque pixels); equal ink means the
   weights collapsed. Monospace advance width is weight-invariant, so width comparison cannot substitute.

### R-14 protocol

1. Seed a workflow run whose ID is a real UUID, such as `123e4567-e89b-12d3-a456-426614174000`, and open its detail
   page from the plain profile.
2. Set the viewport to exactly 320px wide.
3. Confirm the identity card displays the complete UUID, the code element wraps to multiple lines, and
   `document.documentElement.scrollWidth <= document.documentElement.clientWidth`.
4. Capture the 320px screenshot and confirm no console errors.

---

## Environment Health Check

Before reporting smoke-test results, confirm the test environment is sound:

- `lsof -ti:3335` returns a PID
- `curl -s http://localhost:3335/health` returns `200`
- The auth token works: `curl -s -L -b /tmp/dc-jar -c /tmp/dc-jar "http://localhost:3335/?token=devtoken0"` returns the app, not the login page (auto-auth sets the `dart_session` cookie; there is no `dartclaw-token` cookie)
- No `error`-level entries in `list_console_messages` immediately after first authenticated load
