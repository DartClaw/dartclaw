---
profile: visual
viewport: mobile
port: 3338
# Token from dev/testing/profiles/visual/data/gateway_token
auth_token: devtoken0
---
# Scenario: Web UI Visual Smoke (Mobile Companion)

Validates a thin but high-signal slice of the DartClaw web UI at mobile width. This companion scenario supplements the primary desktop visual smoke path and focuses on responsive UX failures that still have concrete pass/fail criteria.

Server should be running: `bash dev/testing/profiles/visual/run.sh`

## S1: Bootstrap Auth And Verify The Mobile App Shell

This sub-scenario checks the first authenticated render and the mobile sidebar overlay contract.

### Steps

1. Open `http://localhost:3338/?token=devtoken0` in a fresh browser context
2. Run `agent-browser snapshot -i` to capture the initial authenticated mobile state
3. Identify the hamburger or primary navigation toggle in the topbar
4. Click the hamburger or navigation toggle to open the mobile sidebar
5. Run `agent-browser snapshot -i` again to capture the open sidebar overlay state
6. Click the close control (`×`) or the backdrop to dismiss the sidebar overlay
7. Run `agent-browser snapshot -i` a third time to capture the restored content state

### Expected

- The app loads without showing the login form
- At mobile width, the sidebar is hidden until the hamburger or navigation toggle is opened
- Opening the mobile navigation reveals a full-height overlay or drawer rather than shifting the entire page layout
- The sidebar overlay includes the `SYSTEM` navigation links for `Health`, `Settings`, `Memory`, `Scheduling`, and `Tasks`
- Closing the overlay removes the backdrop and returns the main content to a readable state
- No major overlap, clipped controls, or unreadable text is visible in either the closed or open mobile state


## S2: Verify Responsive Scheduling Page Chrome

This sub-scenario targets a page with cards, tables, and known overflow-risk UI at narrow widths.

### Steps

1. Navigate to `http://localhost:3338/scheduling`
2. Run `agent-browser snapshot -i` to capture the default scheduling page state
3. If the jobs table is horizontally clipped, scroll the table container horizontally to inspect the right edge affordance
4. Open the mobile sidebar if needed to verify the active navigation state for this page
5. Run `agent-browser snapshot -i` again after any interaction that changes the visible state

### Expected

- The scheduling page loads successfully and remains fully authenticated
- A heartbeat/status card is visible near the top of the page
- The jobs table or its empty-state row is visible inside a bounded container rather than overflowing the page width
- The mobile layout communicates horizontal overflow clearly; a visible fade, crop affordance, or equivalent cue is present at the right edge when table content extends off-screen
- The `Scheduling` entry is visible in the `SYSTEM` navigation and is marked active when the sidebar is open
- The page remains readable on mobile without controls colliding or running off-screen


## S3: Exercise The Memory Dashboard Surface

This sub-scenario checks a denser system page with tabbed content and mixed controls.

### Steps

1. Navigate to `http://localhost:3338/memory`
2. Run `agent-browser snapshot -i` to capture the default memory dashboard state
3. Identify the memory file tabs or equivalent section-switching controls
4. Click a non-default memory file tab
5. If a `Raw` / `Rendered` toggle is visible, switch modes once
6. Run `agent-browser snapshot -i` again to capture the updated content state

### Expected

- The memory dashboard renders an overview area plus at least one deeper content section for memory files, pruning, or search/index status
- Switching to another memory file tab updates the visible content without navigating away from `/memory`
- If present, the `Raw` / `Rendered` control updates the preview state without breaking layout
- The `Memory` entry is present in the `SYSTEM` navigation and can be identified as the active page
- The mobile layout remains usable, with tabs and controls still reachable and text not truncated beyond recognition


## S4: Verify Channel Settings Are Reachable On Mobile

This sub-scenario checks that the channel UI surfaces remain navigable and readable at mobile width when channels are enabled but unpaired. The `visual` profile enables WhatsApp, Signal, and Google Chat with placeholder backends so this exercise focuses on responsive layout rather than connected-channel behavior - hardware-driven pairing belongs to the `channels` profile.

### Steps

1. Navigate to `http://localhost:3338/settings`
2. Run `agent-browser snapshot -i` to capture the settings page channel area at mobile width
3. Scroll to locate the WhatsApp, Signal, and Google Chat sections
4. Navigate to `http://localhost:3338/settings/channels/whatsapp`
5. Run `agent-browser snapshot -i` to capture the WhatsApp channel detail page
6. Navigate to `http://localhost:3338/whatsapp/pairing`
7. Run `agent-browser snapshot -i` to capture the WhatsApp pairing surface

### Expected

- The `/settings` page renders WhatsApp, Signal, and Google Chat sections stacked vertically without overlapping cards or text running off the right edge
- Each channel section exposes a disconnected/not-connected status badge - none of them claim to be connected
- The `/settings/channels/whatsapp` detail page renders the channel configuration view in a single-column mobile layout without controls colliding or text being clipped beyond recognition
- The `/whatsapp/pairing` page renders a pairing surface (QR area, connect control, or equivalent unpaired UI) rather than a 404 or unstyled error
- No channel page surfaces an unhandled error or raw stack trace
- The `Settings` entry is present in the `SYSTEM` navigation overlay and can be identified as active on the channel pages


## S5: Verify The Styled 404 Experience

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
- The mobile layout of the 404 page is readable and visually deliberate rather than cramped or broken
