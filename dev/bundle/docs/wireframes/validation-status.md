# Wireframe Validation Status

Consolidated validation results. Replaces `validation-report.md` (MVP) and `0.2-validation-report.md`.

See full reports in git history for detailed findings.

## Results

| Filename | Last Validated | Result | Outstanding Issues |
|----------|---------------|--------|-------------------|
| main-chat.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels (renamed from `Main`) |
| empty-app.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels |
| new-session.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels |
| streaming.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels + streaming controls intact |
| session-rename.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels + rename controls intact |
| error-states.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels + error state coverage intact |
| light-theme.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels |
| responsive-mobile.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels |
| responsive-sidebar.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels; P3 remains: dual-x button ambiguity |
| auth-login.html | 2026-02-25 | PASS | -- |
| session-info-panel.html | 2026-03-06 | PASS | Standalone page layout; Recent Turns section added |
| health-dashboard.html | 2026-03-05 | PASS | Unified sidebar; guard audit HOOK column removed (moved to expandable detail) |
| whatsapp-pairing.html | 2026-03-10 | PASS | Connected-state setup page live-validated in `channels` profile; mobile layout and console clean |
| whatsapp-channel-detail.html | 2026-03-10 | PASS | Live-validated in `channels` profile after GOWA external-service adoption fix; status renders `Connected` |
| guard-block-chat.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels + guard-block states intact |
| scheduling-status.html | 2026-03-06 | PASS | Unified sidebar (Scheduling active) |
| search-agent-chat.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels + search delegation UI intact |
| settings-page.html | 2026-03-06 | PASS | Unified sidebar; sticky in-page tab nav; per-field RESTART badges → card footer notes |
| signal-pairing.html | 2026-03-10 | PASS | Connected-state setup page live-validated in `channels` profile; console clean |
| signal-channel-detail.html | 2026-03-10 | PASS | Live-validated in `channels` profile; connected status and policy controls render correctly |
| tasks-dashboard.html | 2026-03-10 | PASS | Agent pool, grouped task sections, and Tasks nav validated against live seeded data |
| tasks-empty.html | 2026-03-10 | PASS | True empty-first-run state live-validated in isolated runtime with no `tasks.db` |
| review-queue.html | 2026-03-10 | PASS | `status=review` filter renders triage inbox against live seeded review task |
| new-task.html | 2026-03-10 | PASS | Validated as modal flow on `/tasks`; all core fields visible and operable |
| task-detail-writing.html | 2026-03-10 | PASS | Research/detail variant validated with rendered markdown artifact and review actions |
| task-detail-coding.html | 2026-03-10 | PASS | Draft → queued → running progression validated without manual reload |
| archive-session.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels; archived row has a delete button (`DELETE /api/sessions/<id>`; shipped after this validation) |
| toast-notifications.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels + toast examples intact |
| state-transitions.html | -- | -- | Spec document (no validation needed) |
| loading-skeleton.html | 2026-03-06 | PASS | Sidebar: `Workspace`/`Agent` labels |
| project-management.html | 2026-04-10 | PASS | 0.14 shipped; wireframe matches implementation (ProjectsPage with project cards, status badges, add form, PR config) |
| new-task-project-selector.html | 2026-04-10 | PASS | 0.14 shipped; project selector dropdown, project info card, project-backed type hint all present in implementation |
| task-detail-coding-timeline.html | 2026-04-10 | PASS | 0.14 shipped; progress bar, live activity indicator, event timeline with filters, token summary card all match implementation |
| tasks-dashboard-progress.html | 0.14 | PASS | 0.14 shipped; per-task progress bars, token display, compact timeline, project tags, projects sidebar card all present |
| canvas-standalone.html | 2026-04-10 | -- | New wireframe; 0.14.2 shipped but wireframe created post-implementation |
| canvas-admin.html | 2026-04-10 | -- | New wireframe; 0.14.2 shipped but wireframe created post-implementation |
| workflow-list.html | 2026-04-10 | -- | New wireframe; 0.15 shipped but wireframe created post-implementation |
| workflow-detail.html | 2026-04-10 | -- | New wireframe; 0.15 shipped but wireframe created post-implementation |
| workflow-step-detail.html | 2026-04-10 | -- | New wireframe; HTMX fragment, 0.15 shipped but wireframe created post-implementation |
| guard-editor.html | 2026-04-10 | -- | Planned for 0.17; no implementation to validate yet |
| search-ui.html | 2026-03-09 | -- | Planned feature; `/search` returned 404 in live app review |
| reflection-session.html | 2026-03-09 | -- | Future feature; cron sessions still use generic session page |
| memory-dashboard.html | 2026-03-06 | PASS | Unified sidebar (Memory active) |

## Summary

| Result | Count |
|--------|-------|
| PASS | 34 |
| REVIEWED | 0 |
| FAIL | 0 |
| WARN | 0 |
| Not validated | 9 (`state-transitions.html`, `search-ui.html`, `reflection-session.html`, 5 new wireframes created post-implementation, 1 planned for 0.17) |

## Cross-Page Issues

Cross-page issues resolved or narrowed:
- ~~P1: `components.css` media query source-order bug~~ — fixed in prior pass
- ~~P3: Delete icon inconsistency~~ — fixed: all use `<button class="delete-btn">`
- ~~P3: Logo glyph inconsistency~~ — fixed: session-rename.html updated to `&#10095;`
- ~~P1: SYSTEM nav inconsistency~~ — fixed: all wireframes now include Health/Settings/Memory/Scheduling
- ~~P3: Delete buttons too small~~ — fixed 2026-03-04: min 28x28px hit area, semi-visible (opacity 0.35), error highlight on hover
- Pairing wireframes now match the implementation split: setup/status on pairing pages, policy/config on channel detail pages
- Signal pairing now follows the same QR-first structure as WhatsApp pairing
- Task dashboard, review queue, new-task modal, both task detail variants, the true empty-task first-run variant, and all WhatsApp/Signal channel pages were live-validated on 2026-03-10
- 0.14 wireframes (project-management, new-task-project-selector, task-detail-coding-timeline, tasks-dashboard-progress) validated against implementation code on 2026-04-10 — all PASS
- New wireframes created 2026-04-10 for 0.14.2 (canvas-standalone, canvas-admin), 0.15 (workflow-list, workflow-detail, workflow-step-detail), and 0.17 (guard-editor) — post-implementation wireframes for shipped features + forward-looking design for 0.17
