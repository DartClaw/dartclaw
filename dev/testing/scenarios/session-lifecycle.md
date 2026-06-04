---
profile: plain
viewport: desktop
port: 3335
# Token from dev/testing/profiles/plain/data/gateway_token
auth_token: devtoken0
---
# Scenario: Session Lifecycle

Validates the core session lifecycle: token bootstrap, new-session creation, messaging with streaming, rename, sidebar persistence, and deletion. Exercises a real user journey through the current web UI contract.

## S1: Bootstrap Auth and Create a New Session

Server should be running: `bash dev/testing/profiles/plain/run.sh`

### Steps

1. Open `http://localhost:3335/?token=devtoken0` in a fresh browser context
2. Run `agent-browser snapshot -i` to capture the authenticated page state
3. Click the `+ New Session` control in the sidebar
4. Observe the URL after navigation completes
5. Run `agent-browser snapshot -i` again to capture the new session state

### Expected

- The app loads without showing a login form
- After clicking `+ New Session`, the browser navigates to a path matching `/sessions/[a-z0-9-]+`
- The new session appears at or near the top of the sidebar session list
- An empty chat state is shown in the main area
- The chat input field is present and enabled


## S2: Send a Message and Observe Streaming Response

Precondition: browser is on the newly created session page from S1.

### Steps

1. Run `agent-browser snapshot -i` to identify interactive elements
2. Fill the chat message input (@ref for input field) with `Hello, what is 2 + 2?`
3. Click the send button (@ref for send button) or press Ctrl+Enter (Cmd+Enter on macOS) to submit
4. Observe the message appearing in the conversation
5. Wait for the response streaming to begin (first tokens appear)
6. Wait for the streaming response to complete (send button re-enables or spinner disappears)
7. Run `agent-browser snapshot -i` to capture final state

### Expected

- The sent message "Hello, what is 2 + 2?" appears in the conversation with user attribution
- A response message appears below the user message
- The response contains text (non-empty, at least one word)
- During streaming: send button is disabled or a loading indicator is visible
- After streaming completes: send button is re-enabled
- No error banner or error message is visible


## S3: Rename the Session

Precondition: browser is on the session page with at least one message exchange from S2.

### Steps

1. Run `agent-browser snapshot -i` to identify interactive elements
2. Locate the session title or rename control (header area or sidebar context menu)
3. Click the rename button or double-click the session title to enter rename mode
4. Clear the existing title and type `Lifecycle Test Session`
5. Confirm the rename (press Enter or click a confirm button)
6. Run `agent-browser snapshot -i` to capture updated state

### Expected

- The session title in the page header reads `Lifecycle Test Session`
- The session entry in the left sidebar also shows the updated name `Lifecycle Test Session`
- No error message is visible
- The URL has not changed (same session ID)


## S4: Reload and Verify Sidebar Persistence

Precondition: session has been renamed to "Lifecycle Test Session" in S3.

### Steps

1. Reload the current session page
2. Wait for the session page to load again
3. Run `agent-browser snapshot -i` to capture the restored state

### Expected

- The page remains on the same `/sessions/<id>` route after reload
- The session title in the topbar still reads `Lifecycle Test Session`
- The sidebar still shows an entry titled `Lifecycle Test Session`
- The previously sent user/assistant messages are still visible
- No error banner is visible


## S5: Delete the Session and Verify Removal

Precondition: the renamed session is still active from S4.

### Steps

1. Run `agent-browser snapshot -i` to identify interactive elements
2. Locate the delete or context-menu control for the active `Lifecycle Test Session`
3. Click the delete button or select `Delete` from the context menu
4. If a confirmation dialog appears, confirm the deletion
5. Wait for the deletion to complete
6. Run `agent-browser snapshot -i` to capture the post-delete page

### Expected

- The entry `Lifecycle Test Session` is NO LONGER present in the sidebar
- No error banner or error message is visible
- The browser is redirected away from the deleted session id
- The app remains on a valid authenticated page after deletion
