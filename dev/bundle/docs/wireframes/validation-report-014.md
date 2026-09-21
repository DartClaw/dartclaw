# Visual Validation Report — DartClaw 0.14 Wireframes

**Date:** 2026-03-24 (re-validated after fixes)
**Original validation:** 2026-03-23
**Validator:** Visual Validation via Chrome DevTools MCP
**Workflow:** Project-specific (`../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md`)

---

## Summary

- **Overall Status:** PASS
- **Wireframes Validated:** 4
- **Viewports:** Desktop (1280x800), Mobile (375x667)
- **Screenshots:** 8 captured (see `docs/wireframes/screenshots/014-*.png`)
- **Issues Found:** 0 (all 3 original issues resolved)
- **Console Errors:** None across all 4 wireframes

---

## Fixes Applied (2026-03-24)

1. **[P2] Topbar overflow on mobile** (`new-task-project-selector.html`) — Topbar action buttons (Cancel, Save as draft, Start immediately) hidden on mobile via `@media (max-width: 768px)` rule. Form-level action buttons at the bottom remain as the primary mobile affordance.

2. **[P3] `status-badge-info` / `status-badge-running` added to design system** — Added to `../dartclaw-public/dev/design-system/components.css` alongside existing `status-badge-success`, `status-badge-error`, `status-badge-warning`. Uses info-blue tinting (`--info` token).

3. **[P3] Inline patches removed** — Removed local `status-badge-running` CSS patches from `task-detail-coding-timeline.html` and `tasks-dashboard-progress.html`. Both now inherit from the design system.

---

## Detailed Findings (Re-validated)

---

### WF-1: project-management.html

**Status:** PASS
**Screenshots:**
- `screenshots/014-project-management-desktop.png`
- `screenshots/014-project-management-mobile.png`

- Design tokens active: Catppuccin Mocha palette, all semantic colors resolve
- No horizontal overflow at desktop or mobile
- Split grid reflows to single column at mobile
- Status badges: `status-badge-success` (green), `status-badge-error` (red), `status-badge-info` (blue/Cloning) — all render with correct semantic tinting from design system
- Project source badges: `project-source-config` (info tint), `project-source` (neutral)
- Scan-bar animation defined in components.css (`@keyframes scan`) for Cloning state
- Error project card renders correctly with error message and Retry action
- Config-defined projects show Fetch only; runtime projects show Fetch/Edit/Remove
- Toggle switch renders checked state with accent background
- Form inputs, selects, and hint text render correctly
- No console errors

---

### WF-2: new-task-project-selector.html

**Status:** PASS (P2 fixed)
**Screenshots:**
- `screenshots/014-new-task-project-selector-desktop.png`
- `screenshots/014-new-task-project-selector-mobile.png`

- No overflow at desktop or mobile (P2 resolved — topbar action buttons hidden on mobile)
- Project selector: 4 options. Disabled options (cloning/error) non-selectable
- Project status hint renders below selector with inline "ready" pill + metadata
- Type hint ("Project-backed coding task") renders with dashed accent border
- Task Lifecycle step list: 5 steps with numbered circles
- Selected Project card renders project URL in mono font
- Form textareas, acceptance criteria, token budget all render correctly
- Form actions: 3 buttons visible (Start immediately, Save as draft, Cancel) — mobile uses form-level buttons only
- No console errors

---

### WF-3: task-detail-coding-timeline.html

**Status:** PASS (P3 fixed)
**Screenshots:**
- `screenshots/014-task-detail-coding-timeline-desktop.png`
- `screenshots/014-task-detail-coding-timeline-mobile.png`

- "Running" badge in topbar renders with info-blue color from design system (P3 resolved — no inline patch needed)
- Progress bar: 4px height, 37% fill, gradient (`--accent` → `--info`)
- Progress text: "3,724 / 10,000 tokens" with "37%" in accent
- Live activity indicator: pulsing blue dot, "Current: Edit lib/api/users/avatar_handler.dart"
- Metrics row: 4-column desktop, 2-column mobile
- Timeline: 12 events with distinct icon colors (status=accent, tool=info, token=warning)
- Filter chips: "All" active with accent border, others neutral
- Sidebar cards: Task Info, Acceptance Criteria (checklist), Token Summary (input/output/cache/model/provider)
- Split collapses to single column on mobile
- No console errors

---

### WF-4: tasks-dashboard-progress.html

**Status:** PASS (P3 fixed)
**Screenshots:**
- `screenshots/014-tasks-dashboard-progress-desktop.png`
- `screenshots/014-tasks-dashboard-progress-mobile.png`

- "Running" badges render from design system (P3 resolved — inline patch removed)
- Metrics row: 4 KPIs (Draft, Queued, Running, Awaiting review)
- Task progress bars: T-118 determinate at 37%; T-119 and T-120 indeterminate with pulse animation
- Progress gradients: `linear-gradient(90deg, var(--accent), var(--info))` on all bars
- Token consumption text: "3.7K / 10K tokens (37%)", "1.2K tokens (no budget)"
- Project tags: `my-saas-app`, `frontend-v2` with info-tinted badges
- Compact timeline: last 3 events per task with semantic icon colors
- Sidebar: Pool Capacity (2x2 grid), Agents (3 busy), Projects summary with status badges
- Filter section: Status/Type chips wrap correctly, search input renders
- Task count badge ("2") in sidebar nav renders with warning tint
- No console errors

---

## Summary Table

| Wireframe | Desktop | Mobile | Issues |
|-----------|---------|--------|--------|
| project-management.html | PASS | PASS | None |
| new-task-project-selector.html | PASS | PASS | None (P2 fixed) |
| task-detail-coding-timeline.html | PASS | PASS | None (P3 fixed) |
| tasks-dashboard-progress.html | PASS | PASS | None (P3 fixed) |

**All 8 viewport checks pass. Zero open issues.**

---

## Design System Update

Added to `../dartclaw-public/dev/design-system/components.css`:

```css
.status-badge-info,
.status-badge-running {
  color: var(--info);
  background: color-mix(in srgb, var(--info) 10%, var(--bg-base));
  border-color: color-mix(in srgb, var(--info) 22%, var(--bg-surface1));
}
```

This completes the status badge semantic color set: success, error, warning, info/running.
