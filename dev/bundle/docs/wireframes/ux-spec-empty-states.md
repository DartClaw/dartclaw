# UX Spec: Empty States

Catalog of all empty/zero-data states across DartClaw web UI pages.

## Empty State Inventory

| State | Visual Treatment | Heading | Body | CTA | Template/Wireframe |
|-------|-----------------|---------|------|-----|--------------------|
| No sessions (first launch) | Centered content, muted icon | Welcome to DartClaw | Start a new session to begin | **+ New Session** button | `empty-app.html` |
| No messages (new session) | Centered content, prompt suggestions | New Session | How can I help? | Prompt suggestion chips | `new-session.html` |
| No scheduled jobs | Empty table with placeholder row | — | No scheduled jobs configured | Link to docs | `scheduling-status.html` (planned) |
| No search results | Centered content, muted icon | No Results | No messages matched your query | Adjust search terms | planned (`search-ui.html`) |
| No audit entries | Empty table with placeholder row | — | No audit events recorded yet | — | `health-dashboard.html` (planned) |
| No archived sessions | Sidebar section hidden or muted label | — | No archived sessions | — | planned (`archive-session.html`) |
| Session not found (404) | Centered content, search icon | Session Not Found | This session may have been deleted or archived | **Back to Sessions** link | `error-states.html` |

## Design Principles

- **Never show a blank screen.** Every zero-data state should communicate what the user can do next.
- **Use centered layout** for full-page empty states (no sessions, session not found).
- **Use placeholder table rows** for list/table empty states (audit log, scheduled jobs, recent runs).
- **Muted colors** (`--fg-overlay`) for empty state body text; primary action uses `btn-primary`.
- **No illustrations or complex graphics** -- keep consistent with the terminal-inspired design language. Use simple Unicode icons where needed.

## Implementation Notes

- Empty states in Trellis templates use `tl:if` / `tl:unless` conditional rendering.
- The sidebar session list simply renders nothing when empty; the `empty-app.html` pattern handles the main content area.
- Search empty state is planned for the search UI feature.
