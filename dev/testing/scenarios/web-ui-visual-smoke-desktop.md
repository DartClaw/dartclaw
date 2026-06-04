---
profile: visual
viewport: desktop
port: 3338
# Token from dev/testing/profiles/visual/data/gateway_token
auth_token: devtoken0
---
# Scenario: Web UI Visual Smoke (Desktop)

Validates the major DartClaw web UI surfaces at desktop width using the dedicated `visual` testing profile. This is the primary visual smoke path for spotting obvious functional regressions, broken information architecture, and design issues across the main authenticated pages.

Server should be running: `bash dev/testing/profiles/visual/run.sh`

## S1: Bootstrap Auth, Login Surface, And Desktop Shell

This sub-scenario checks both auth entry points and the first authenticated render.

### Steps

1. Open `http://localhost:3338/login` in a fresh browser context
2. Run `agent-browser snapshot -i` to capture the login page
3. Open `http://localhost:3338/?token=devtoken0`
4. Wait for authenticated navigation to complete
5. Run `agent-browser snapshot -i` again to capture the initial authenticated desktop state
6. Observe the left sidebar, topbar, and main content without interacting yet

### Expected

- The `/login` page renders as a styled login surface rather than a raw fallback form
- The login page includes a token input and sign-in action
- The app loads without showing the login form
- The desktop layout shows a persistent left sidebar rather than a hidden overlay-only navigation pattern
- The sidebar includes a visible `New Chat` control for starting a new session
- The sidebar includes the major `SYSTEM` navigation links for `Health`, `Settings`, `Memory`, `Scheduling`, `Tasks`, `Projects`, `Workflows`, and `Canvas`
- The topbar and main content render as a coherent desktop shell without obvious clipping, overlap, or unreadable text


## S2: Verify Chat And Session Info Pages

This sub-scenario checks the core session surface and its linked info page using stable seeded data.

### Steps

1. Navigate to `http://localhost:3338/sessions/f59ce127-1705-43d6-97c7-2a03fd711bab`
2. Run `agent-browser snapshot -i` to capture the seeded chat session
3. Identify the session title, messages, composer, and topbar info control
4. Click the session info control if it is present; if discovery fails, navigate to `http://localhost:3338/sessions/f59ce127-1705-43d6-97c7-2a03fd711bab/info`
5. Wait for navigation to complete
6. Run `agent-browser snapshot -i` again to capture the session info page

### Expected

- The seeded session page renders a recognizable chat layout with a title, message history, and composer area
- Existing seeded messages are visible so the page is not just an empty shell
- The session info route loads successfully and remains styled as part of the app shell
- The session info page shows session metadata and token or usage summary cells
- Both the chat page and the session info page remain readable on desktop without broken spacing or clipped text


## S3: Verify Health And Settings

This sub-scenario checks the two broad operational dashboards with the highest information density.

### Steps

1. Navigate to `http://localhost:3338/health-dashboard`
2. Run `agent-browser snapshot -i` to capture the health dashboard
3. Navigate to `http://localhost:3338/settings`
4. Run `agent-browser snapshot -i` again to capture the settings page
5. Identify the main settings sections, cards, and channel/provider areas in the current viewport

### Expected

- The health dashboard renders a status summary and service-level sections rather than a sparse placeholder
- The `Health` nav entry is visible and can be identified as active on that page
- The settings page renders as a structured dashboard rather than a plain ungrouped form
- Channel-related cards or sections are visible on the settings page (deeper channel coverage lives in `S7`)
- The settings layout remains readable on desktop, with no collapsed card content, broken columns, or obvious overflow


## S4: Verify Memory And Scheduling

This sub-scenario checks the two system pages that depend most on seeded operational data.

### Steps

1. Navigate to `http://localhost:3338/memory`
2. Run `agent-browser snapshot -i` to capture the memory dashboard
3. Identify the memory file tabs or equivalent section-switching controls
4. Click a non-default memory file tab
5. Run `agent-browser snapshot -i` again to capture the updated memory state
6. Navigate to `http://localhost:3338/scheduling`
7. Run `agent-browser snapshot -i` a third time to capture the scheduling page
8. Observe the jobs table or empty-state row plus the status/heartbeat area

### Expected

- The memory dashboard renders an overview plus deeper memory-related content rather than a blank or fragmented page
- Switching memory tabs updates the visible content without leaving `/memory`
- The `Memory` nav entry is visible and can be recognized as active on that page
- The scheduling page shows a clear status area and a bounded jobs table or empty-state container
- The scheduling content fits the desktop layout without requiring the whole page to scroll horizontally
- The `Scheduling` nav entry is visible and can be recognized as active on that page


## S5: Verify Tasks List And Seeded Task Detail

This sub-scenario checks the task-management surface using a seeded task detail route.

### Steps

1. Navigate to `http://localhost:3338/tasks`
2. Run `agent-browser snapshot -i` to capture the tasks list page
3. Identify the filter controls, grouped task areas, and the `New Task` action if visible
4. Navigate to `http://localhost:3338/tasks/8e7eeab8-8e32-4f14-8687-0378f4591b2e`
5. Run `agent-browser snapshot -i` again to capture the seeded task detail page

### Expected

- The tasks page loads successfully and remains fully authenticated
- Filter controls or grouped task areas are visible near the top of the page
- The `Tasks` nav entry is visible and can be recognized as active
- The seeded task detail route renders a full task page rather than a missing-state fallback
- The detail page shows task metadata, progress or timeline information, and related content in a desktop-friendly layout


## S6: Verify Projects, Workflows, And Canvas

This sub-scenario checks the remaining major dashboard pages that are often omitted from simpler UI smoke passes.

### Steps

1. Navigate to `http://localhost:3338/projects`
2. Run `agent-browser snapshot -i` to capture the projects page
3. Navigate to `http://localhost:3338/workflows`
4. Run `agent-browser snapshot -i` again to capture the workflows page
5. Navigate to `http://localhost:3338/canvas-admin`
6. Run `agent-browser snapshot -i` a third time to capture the canvas admin page

### Expected

- The projects page renders at least one seeded project row or card so the page is not just an empty configuration placeholder
- The `Projects` nav entry is visible and can be recognized as active on that page
- The workflows page renders the workflow management surface with definition cards, run list content, or both
- The `Workflows` nav entry is visible and can be recognized as active on that page
- The canvas admin page renders as a deliberate dashboard page rather than a 404 or raw placeholder
- The `Canvas` nav entry is visible and can be recognized as active on that page


## S7: Verify Channel UI Surfaces In Disconnected State

This sub-scenario checks that the channel-related pages render correctly when channels are enabled in config but not paired. The `visual` profile enables WhatsApp, Signal, and Google Chat with placeholder/unavailable backends so all channel surfaces render their unconfigured/disconnected look without depending on real hardware. Hardware-driven pairing flows belong to the `channels` profile and are out of scope here.

### Steps

1. Navigate to `http://localhost:3338/settings`
2. Run `agent-browser snapshot -i` to capture the settings page channel area
3. Identify the WhatsApp, Signal, and Google Chat sections
4. Navigate to `http://localhost:3338/settings/channels/whatsapp`
5. Run `agent-browser snapshot -i` to capture the WhatsApp channel detail page
6. Navigate to `http://localhost:3338/settings/channels/signal`
7. Run `agent-browser snapshot -i` to capture the Signal channel detail page
8. Navigate to `http://localhost:3338/settings/channels/google_chat`
9. Run `agent-browser snapshot -i` to capture the Google Chat channel detail page
10. Navigate to `http://localhost:3338/whatsapp/pairing`
11. Run `agent-browser snapshot -i` to capture the WhatsApp pairing page
12. Navigate to `http://localhost:3338/signal/pairing`
13. Run `agent-browser snapshot -i` to capture the Signal pairing page

### Expected

- The `/settings` page renders distinct WhatsApp, Signal, and Google Chat sections rather than a single generic "channels" placeholder
- Each channel section on `/settings` exposes its disconnected/not-connected status (e.g. a `Not configured`, `Disconnected`, or equivalent badge) - none of them claim to be connected
- The `/settings/channels/whatsapp` detail page renders the WhatsApp configuration view with DM access mode, group access mode, mention settings, and a status indicator reflecting the unpaired state
- The `/settings/channels/signal` detail page renders the Signal configuration view with the same field shape and an unpaired status indicator
- The `/settings/channels/google_chat` detail page renders the Google Chat configuration view and shows a status indicating it is enabled in config but not connected
- The `/whatsapp/pairing` page renders a pairing surface (e.g. a QR code area, connect/start control, or equivalent unpaired-state UI) rather than a 404 or unstyled error page
- The `/signal/pairing` page renders a pairing surface (e.g. a phone-number/link-device prompt, connect control, or equivalent unpaired-state UI) rather than a 404 or unstyled error page
- No channel page surfaces an unhandled error, raw stack trace, or backend-unreachable message that is not the intended disconnected-state UI
- The `Settings` nav entry is visible and can be recognized as active on the settings and channel detail pages
- The desktop layout on every channel page stays readable without broken columns, collapsed cards, or obvious overflow


## S8: Verify The Styled 404 Experience

This sub-scenario checks that missing routes still render a themed, user-facing error page instead of a plain fallback.

### Steps

1. Navigate to `http://localhost:3338/nonexistent-page`
2. Run `agent-browser snapshot -i` to capture the 404 page
3. Click the `Back to Home` control if present
4. Wait for navigation to complete
5. Run `agent-browser snapshot -i` again to capture the recovery state

### Expected

- The missing route renders a styled `404` page rather than plain unformatted text
- The page includes a `Page Not Found` heading and a visible recovery action such as `Back to Home`
- The 404 page uses the same themed visual language as the rest of the app rather than a browser-default error surface
- Activating the recovery action returns the browser to a valid authenticated page
- The desktop layout of the 404 page is deliberate and readable rather than sparse, broken, or obviously unstyled


## S9: Verify The Rich Chat Composer

This sub-scenario checks the rich composer shell (command palette, reference palette, attachment chips, send/stop) on a seeded chat session. It uses the dedicated active `user`-type session `c0117005-0000-4000-8000-000000000009` ("Composer Smoke E2E") rather than the `main` session used in `S2`: keyed `main`/`channel`/`cron` sessions are rotated to archive by the daily reset, so the seeded `main` session (`f59ce127…`) renders read-only with no composer, while the rotated active `main` session has a non-deterministic id. The seeded `user` session is exempt from rotation and from age pruning (default `sessions.maintenance.mode: warn`), so it reliably exposes the composer at a stable id.

### Steps

1. Navigate to `http://localhost:3338/sessions/c0117005-0000-4000-8000-000000000009`
2. Run `agent-browser snapshot -i` to capture the composer
3. Focus the composer input and type `/`
4. Run `agent-browser snapshot -i` to capture the command palette, then press `Escape` to dismiss it
5. Type `@` in the composer
6. Run `agent-browser snapshot -i` to capture the reference palette, then press `Escape` to dismiss it

### Expected

- The composer renders as the rich shell (toolbar/affordances around the input), not a bare textarea-only form
- Typing `/` opens a command palette with keyboard-selectable command rows; `Escape` dismisses it cleanly with focus returned to the input
- Typing `@` opens a reference palette with selectable context rows; `Escape` dismisses it cleanly
- No palette leaves an orphaned overlay, and the composer does not overflow or break the desktop chat layout
- No error banner or raw stack trace appears while opening or dismissing the palettes


## S10: Verify The Settings Guard Editor

This sub-scenario checks the guard editor on the Settings page. The `visual` profile authenticates via token; DartClaw grants every authenticated session admin access (there is no separate non-admin web-UI role), so the editable controls and tester are expected to be present. The runtime-only read-only guard view is not reachable from the web UI and is not exercised here.

### Steps

1. Navigate to `http://localhost:3338/settings`
2. Run `agent-browser snapshot -i` to capture the settings page
3. Scroll to locate the guard editor / security guard section
4. Run `agent-browser snapshot -i` to capture the guard editor surface
5. Locate the guard tester input, enter a clearly dangerous command such as `rm -rf /`, and submit it to the tester
6. Run `agent-browser snapshot -i` to capture the tester verdict

### Expected

- The settings page renders a guard editor section grouping the command, file, network, and input-sanitizer guards
- Built-in default rules are shown as read-only context, visually distinct from editable extension entries
- Editable extension affordances are present for an admin session — add/edit/delete controls on the extension fields and a guard tester panel
- Submitting a sample through the tester returns a structured verdict (an allowed/blocked result with a guard family and reason), not an error; a clearly dangerous command surfaces a blocked verdict
- Running the tester does not mutate the persisted guard config or require a restart
- No error banner, raw stack trace, or unstyled fallback appears in the guard editor or tester area
