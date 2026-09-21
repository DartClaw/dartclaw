# UX Spec: Pagination & Data Loading

Patterns for loading and paginating data across DartClaw web UI pages.

## Per-Component Pagination Strategy

| Component | Current Behavior | Pagination | Rationale |
|-----------|-----------------|------------|-----------|
| Sidebar session list | Shows all sessions | None -- limited to N most recent | Session count stays manageable; oldest sessions auto-archive. No infinite scroll needed. |
| Message history (chat) | All messages loaded on page render | None -- intentional design choice | Cursor-based loading delivers all messages. Full history available for in-page search. SSE appends new messages in real time. |
| Audit log (health dashboard) | Static sample data | Planned -- server-side pagination | Large datasets expected in production. Will use offset-based pagination with page controls. |
| Recent runs (scheduling) | Shows last N runs | Planned -- "Load more" pattern | Keeps initial render fast. Collapsible section already limits visual weight. |
| Search results | Not yet implemented | Planned -- cursor-based | Matches the cursor-based pattern used elsewhere in the system. |

## Design Decisions

### Why no message pagination
DartClaw sessions are scoped conversations with a natural size limit. Loading all messages:
- Enables browser-native Ctrl+F search within the conversation
- Avoids complex scroll-position management during streaming
- Simplifies the SSE append model (just append to end)
- Cursor-based crash recovery already handles resume semantics

### Planned pagination UI pattern
For components that will get pagination (audit log, search):
- Use simple **Previous / Next** controls below the table
- Show current page indicator: "Page 1 of 5"
- Use `btn-ghost` style for pagination buttons
- Server renders each page via HTMX `hx-get` with `?page=N` parameter
- No client-side JavaScript pagination state

### Session list trimming
- Sidebar shows the N most recent sessions (configurable, default ~50)
- Older sessions are accessible via search or archive view (planned)
- No "load more" in the sidebar -- keeps navigation fast and focused
