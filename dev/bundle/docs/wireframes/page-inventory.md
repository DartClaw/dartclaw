# Wireframe Page Inventory

## 0.8 Task Orchestrator and Google Chat

### Pages to Wireframe
1. `tasks-dashboard.html` - `/tasks` dashboard with filters, running task cards, task table, and embedded agent overview
2. `tasks-empty.html` - `/tasks` empty state when no tasks exist yet
3. `review-queue.html` - `/tasks?status=review` triage inbox with review-only task list
4. `new-task.html` - task creation form with conditional type-specific fields
5. `task-detail-writing.html` - `/tasks/<id>` detail view for writing and research artifacts
6. `task-detail-coding.html` - `/tasks/<id>` detail view for coding diffs, worktree metadata, and merge review
7. `scheduling-task-jobs.html` - `/scheduling` state showing scheduled job type `task`
8. `google-chat-channel-detail.html` - `/settings/channels/google_chat` channel detail page for Google Chat config

## Total: 8 wireframes required

### Completion
- [x] `tasks-dashboard.html`
- [x] `tasks-empty.html`
- [x] `review-queue.html`
- [x] `new-task.html`
- [x] `task-detail-writing.html`
- [x] `task-detail-coding.html`
- [x] `scheduling-task-jobs.html`
- [x] `google-chat-channel-detail.html`

Unified inventory of all DartClaw wireframes. Replaces per-version inventories.

| Filename | Version | Route(s) | Coverage | Last Validated | Known Gaps | Status |
|----------|---------|----------|----------|----------------|------------|--------|
| auth-login.html | 0.2 | `/login` | ~95% | 2026-02-25 | None | IMPLEMENTED |
| main-chat.html | MVP | `/sessions/<id>` | ~95% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| empty-app.html | MVP | `/` (no sessions) | ~95% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| new-session.html | MVP | `/sessions/<id>` (new) | ~95% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| streaming.html | MVP | `/sessions/<id>` (streaming) | ~95% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| session-rename.html | MVP | `/sessions/<id>` (rename) | ~95% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| error-states.html | MVP | `/sessions/<id>` (errors) | ~85% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| light-theme.html | MVP | any page (light theme) | ~95% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| responsive-mobile.html | MVP | any page (<768px) | ~90% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| responsive-sidebar.html | MVP | any page (sidebar open) | ~90% | 2026-03-06 | Dual-x ambiguity (P3) | IMPLEMENTED |
| guard-block-chat.html | 0.5 | `/sessions/<id>` (guard blocks) | ~95% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| search-agent-chat.html | 0.2 | `/sessions/<id>` (search delegation) | ~90% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| session-info-panel.html | 0.5 | `/sessions/<id>/info` | ~85% | 2026-03-06 | Standalone page, not overlay | IMPLEMENTED |
| health-dashboard.html | 0.6 | `/health-dashboard` | ~95% | 2026-03-05 | Guard audit detail moved into expandable rows | IMPLEMENTED |
| scheduling-status.html | 0.6 | `/scheduling` | ~95% | 2026-03-06 | Unified sidebar now canonical | IMPLEMENTED |
| scheduling-task-jobs.html | 0.8 | `/scheduling` (task job state) | NEW | 2026-03-09 | Static data only; focuses on job type `task` extension | IMPLEMENTED |
| settings-page.html | 0.6 | `/settings` | ~95% | 2026-03-09 | Static mock shows connected-state Configure links; live channel detail pages now surface pairing-needed state instead of redirecting away | IMPLEMENTED |
| memory-dashboard.html | 0.6 | `/memory` | ~95% | 2026-03-06 | Unified sidebar now canonical | IMPLEMENTED |
| whatsapp-pairing.html | 0.2 | `/whatsapp/pairing` (channel enabled) | ~90% | 2026-03-09 | Pairing page narrowed to connection/setup; policy moved to channel detail page | IMPLEMENTED |
| whatsapp-channel-detail.html | 0.7 | `/settings/channels/whatsapp` | NEW | 2026-03-09 | Connected-state config page only; unpaired flow belongs on pairing page | IMPLEMENTED |
| signal-pairing.html | 0.4 | `/signal/pairing` (channel enabled) | ~90% | 2026-03-09 | SMS/captcha path removed in 0.25; QR device linking is the only pairing flow | IMPLEMENTED |
| signal-channel-detail.html | 0.7 | `/settings/channels/signal` | NEW | 2026-03-09 | Connected-state config page only; unpaired flow belongs on pairing page | IMPLEMENTED |
| google-chat-channel-detail.html | 0.8 | `/settings/channels/google_chat` | NEW | 2026-03-09 | Connected-state config only; no pairing flow for Google Chat | IMPLEMENTED |
| archive-session.html | 0.4 | `/sessions/<id>` (archived) | ~90% | 2026-03-06 | Archived row has a delete action (`DELETE /api/sessions/<id>`) | IMPLEMENTED |
| toast-notifications.html | 0.4 | any page (toast overlay) | ~90% | 2026-03-06 | Sidebar labels aligned to `Workspace` / `Agent` | IMPLEMENTED |
| state-transitions.html | 0.4 | cross-cutting (spec) | NEW | -- | Spec document | PLANNED |
| loading-skeleton.html | 0.4 | cross-cutting (loading) | ~90% | 2026-03-06 | None | IMPLEMENTED |
| search-ui.html | 0.6+ | `/search` | ~85% | 2026-03-09 | Future feature; live route still absent | PLANNED |
| reflection-session.html | 0.5 | `/sessions/<cron-id>` | NEW | 2026-03-09 | Future feature; no cron-specific session page implementation yet | PLANNED |
| tasks-dashboard.html | 0.8 | `/tasks` | NEW | 2026-03-09 | F26 covered as section on this page rather than separate `/agents` route | IMPLEMENTED |
| tasks-empty.html | 0.8 | `/tasks` (empty) | NEW | 2026-03-09 | Empty-first-run state only | IMPLEMENTED |
| review-queue.html | 0.8 | `/tasks?status=review` | NEW | 2026-03-09 | Review actions deferred to task detail page to reduce accidental approvals | IMPLEMENTED |
| new-task.html | 0.8 | `/tasks` (new task flow) | NEW | 2026-03-09 | Route/modal shape TBD; wireframe captures form layout and fields | IMPLEMENTED |
| task-detail-writing.html | 0.8 | `/tasks/<id>` (document artifact) | NEW | 2026-03-09 | Covers writing and research detail variant | IMPLEMENTED |
| task-detail-coding.html | 0.8 | `/tasks/<id>` (diff artifact) | NEW | 2026-03-09 | Conflict notice represented inline rather than separate screen | IMPLEMENTED |
| settings-page-providers.html | 0.13 | `/settings` (providers section) | NEW | 2026-03-23 | Provider status display, read-only | IMPLEMENTED |
| provider-indicators.html | 0.13 | cross-cutting (provider badges) | NEW | 2026-03-23 | Badges in sidebar, task list, task detail | IMPLEMENTED |
| project-management.html | 0.14 | `/projects` | NEW | 2026-04-10 | Project list, status badges, add project form, per-project actions. Shows ready/cloning/error states | IMPLEMENTED |
| new-task-project-selector.html | 0.14 | `/tasks` (new task flow) | NEW | 2026-04-10 | Extends new-task.html with project selector dropdown, project info sidebar card, updated type hint for project-backed tasks | IMPLEMENTED |
| task-detail-coding-timeline.html | 0.14 | `/tasks/<id>` (running, with timeline) | NEW | 2026-04-10 | Running task state with progress bar, live activity indicator, event timeline with filtering, token summary sidebar card | IMPLEMENTED |
| tasks-dashboard-progress.html | 0.14 | `/tasks` (with progress) | NEW | 2026-04-10 | Extends tasks-dashboard.html with per-task progress bars, token consumption, compact timeline (last 3 events), project tags, projects sidebar card | IMPLEMENTED |
| canvas-standalone.html | 0.14.2 | `/canvas/<shareToken>` | NEW | 2026-04-10 | Public zero-auth canvas view. Full viewport, no shell. Dark/light theme, nickname dialog, permission chip (interact/view), connection status indicator, SSE-driven content | WIREFRAMED |
| canvas-admin.html | 0.14.2 | `/canvas-admin` | NEW | 2026-04-10 | Canvas admin dashboard. Two-card grid: live iframe preview + share link management with generate/copy/QR/revoke controls | WIREFRAMED |
| workflow-list.html | 0.15/0.16.3 | `/workflows` | NEW | 2026-04-11 | Workflow management page. Status filters, run list with progress bars, definition browser with per-card launch form (Run button, variable inputs, validation errors), chat notification card previews (success + error) | WIREFRAMED |
| workflow-detail.html | 0.15 | `/workflows/<runId>` | NEW | 2026-04-10 | Workflow run detail. Metadata card, progress bar, action buttons (pause/resume/cancel), vertical step pipeline with connectors, shared context viewer | WIREFRAMED |
| workflow-step-detail.html | 0.15 | `/workflows/<runId>/steps/<N>` (fragment) | NEW | 2026-04-10 | HTMX lazy-loaded fragment. Session messages, artifacts list, context inputs/outputs, token metrics. Shown inside expanded pipeline step | WIREFRAMED |
| guard-editor.html | 0.17 | `/settings/guards` | NEW | 2026-04-10 | Guard config editor (planned). Per-guard-type tabs, rule table with add/edit/delete, inline edit form, pattern tester panel, recent audit events | PLANNED |
| chat-composer.html | 0.16.2+ | `/sessions/<id>` (composer) | NEW | 2026-04-10 | **Proposal 1** (historical; superseded by the canonical `.composer` in the design system, 2026-07-04 — page uses scoped `p-composer*` classes): Composable input container with context bar (connection dot, session name, token budget), circular icon send button with scale animation, input toolbar (commands, attach, char count), keyboard hint, scan bar during streaming, stop button morph. 3 states: idle, streaming, new session | WIREFRAMED |
| chat-command-palette.html | 0.next-chat-and-sessions | `/sessions/<id>` (composer `/` palette) | NEW | 2026-08-07 | Reworked 2026-08-07 for the Chat & Session command surface (replaces the historical 0.17 Proposal 2; its quick-action/suggestion-chip states were dropped — steer/queue is its own Phase A surface). Sectioned catalog (Session verbs / Model / Skills / Workflows / Help) on canonical `.palette-section`/`.palette-item` rows in a `.card-glass` popover above the canonical `.composer`. 4 states: full admin catalog (gated rows carry a shield), filtered-as-you-type with keyboard cursor, non-admin catalog (capability-filtered absence), harness passthrough (`/compact`). Same catalog feeds `command-palette-global.html` (Cmd+K renderer) | WIREFRAMED |
| chat-rich-composer.html | 0.16.2+ | `/sessions/<id>` (rich input) | NEW | 2026-04-10 | **Proposal 3** (historical; composer part superseded by canonical `.composer` + `.chip` family, 2026-07-04 — scoped `p-composer*` classes): Drag-and-drop file attachment (dashed border + green tint overlay), file pills (green accent, with dismiss), image pills (with thumbnail), @-mention context reference chips (blue/info accent), @-mention palette popover, toolbar metadata summary. Builds on Proposals 1+2. 4 states: drop active, files+refs attached, @-mention palette, full streaming with everything | WIREFRAMED |
| knowledge-hub.html | 0.19 | `/knowledge` | NEW | 2026-06-12 | Read-only unified knowledge hub over wiki/KG/memory/inbox (FR6); layer filter chips, layer summary strip, attribution lines, per-layer empty states, pagination. Low-fi / design-system-agnostic pending Afterglow (see deviations #13) | WIREFRAMED |
| kg-timeline.html | 0.19 | `/knowledge/timeline` | NEW | 2026-06-12 | Category-first temporal-KG timeline (FR7); `valid_from`/`valid_to` windows, superseded/contradicting facts rendered distinctly, as-of view, contradiction cluster, empty state. Low-fi / agnostic pending Afterglow (deviations #13) | WIREFRAMED |
| source-attribution.html | 0.19 | `/knowledge/research` | NEW | 2026-06-12 | `context_research` packet view + shared cross-layer attribution component (FR8/FR5); inline citations, layer-badged sources, attributed/unverified/popover states, reuse demo across hub+timeline. Low-fi / agnostic pending Afterglow (deviations #13) | WIREFRAMED |
| chat-conversation-cards.html | 0.next-chat-and-sessions | `/sessions/<id>` (structured turn) | NEW | 2026-07-04 | Conversation with canonical Afterglow-extension components: tool-call card stack (success collapsed+expanded, pending scan, guard-blocked), approval-card `--waiting` with actions, `.msg-thinking` claw slot, composer chip-row (file + @-ref chips). Hi-fi, links canonical CSS directly | WIREFRAMED |
| session-sidebar-control-plane.html | 0.next-chat-and-sessions | any page (sidebar) | NEW | 2026-08-07 | Session sidebar as inbox-model control plane (Chat & Session Phase B rework): flat statically-ordered active list — no project grouping, no activity-driven reordering, colour reserved for waiting-on-you/failed rows only; per-row project identicon (keyed on project.id) + status/project scope chips incl. "Waiting on you"; manual + bulk settle (Select-mode toggle, mobile-safe) into a paginated, slim-row settled tail with per-row Restore; ambient status dots with damped running rows + elapsed timers; draft indicator; fork lineage; drag-resizable sidebar (min/max clamp, persisted, dblclick reset) | WIREFRAMED |
| notification-center.html | 0.next-chat-and-sessions | any page (attention center) | NEW | 2026-07-04 | Topbar bell with count badge; glass panel with Needs input / Unblocked / Finished groups, unread/read notif-items, Mark-all-read footer | WIREFRAMED |
| command-palette-global.html | 0.next-chat-and-sessions | any page (Cmd+K) | NEW | 2026-07-04 | Global Cmd+K palette (distinct from composer slash palette): centered glass modal, search input, Actions/Sessions/Workflows/Knowledge sections, palette-item rows with kbd shortcuts, shortcut-teaching hint row | WIREFRAMED |
| workflow-run-board.html | 0.next-workflow-studio | `/workflows` (run board) | NEW | 2026-07-04 | Live run board: pinned "Needs you" run-card `--attention`, Running grid (meters, current-step indicators), Recent row, expanded run panel with 5-state pipeline spine | WIREFRAMED |

**Totals**: 56 wireframes -- 36 IMPLEMENTED, 4 PLANNED, 16 WIREFRAMED (0.14.2, 0.15, 0.16.2+, 0.19, 0.next)
