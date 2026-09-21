# Architecture Alignment: Wireframe vs Implementation

Resolutions for identified misalignments between wireframes and the DartClaw implementation.

## 1. Session Info: Panel vs Page

**Resolution: Page wins.**

| Aspect | Wireframe (original) | Implementation | Resolution |
|--------|---------------------|----------------|------------|
| Layout | Slide-out panel overlaying chat | Standalone page at `/session/:id/info` | Wireframe updated to standalone page |
| Navigation | Toggle button in topbar | Link from topbar info button | Topbar has info button linking to page |
| Rationale | — | Simpler server-side rendering, no overlay JS, consistent with settings/health page pattern | Standalone page is the correct pattern |

The `session-info-panel.html` wireframe has been reworked to `session-info.html` as a standalone page with sidebar navigation, matching the implementation's `session_info.dart` template.

## 2. SPA Scope: Partial vs Full

**Resolution: Full SPA wins.**

| Aspect | Wireframe (original) | Implementation | Resolution |
|--------|---------------------|----------------|------------|
| Navigation | Mixed -- some pages full reload, some HTMX | Full SPA via HTMX `hx-boost` on all links | All navigation is SPA |
| Content swap | Inconsistent | `hx-target="#main-content"` on sidebar nav, `hx-swap="outerHTML"` | Consistent fragment-based rendering |
| Rationale | — | Zero page reloads, smooth transitions, maintains sidebar state | Full SPA is simpler and more consistent |

All wireframes now assume SPA navigation. Sidebar links use `hx-get` + `hx-target` to swap the main content area without full page reloads.

## 3. Guard Chain: Multi-Guard Display

**Resolution: Show final verdict, annotate multi-guard chain as design intent.**

| Aspect | Wireframe | Implementation | Resolution |
|--------|-----------|----------------|------------|
| Audit log | Shows individual guard verdicts (command, file, network) | Shows final aggregated verdict per action | Wireframe keeps detailed view as design intent |
| Guard list (settings) | Lists 4 guards with checkmarks | Same pattern | Aligned |
| Rationale | — | Implementation shows simplified view; detailed per-guard breakdown is a future enhancement | Annotated in wireframe |

The health dashboard wireframe's audit log table is annotated: *"DESIGN INTENT: Audit log and tool breakdown -- richer than current impl which only shows services + metrics."* The detailed guard-level audit view is a design target for future implementation.

## 4. Two-Tier Privilege Model

**Resolution: Backend-only enforcement, no UI needed.**

| Aspect | Wireframe | Implementation | Resolution |
|--------|-----------|----------------|------------|
| Privilege visualization | Not shown in any wireframe | Enforced at backend (main group = admin, others = sandboxed) | No UI representation needed |
| Per-group isolation | Not visualized | Container-level + filesystem isolation | Transparent to web UI users |
| Rationale | — | Privilege model is a security boundary, not a user-facing feature. Admin users see full UI; sandboxed users see their scoped view automatically. | No wireframe changes needed |

The two-tier privilege model is an infrastructure concern. The web UI serves the authenticated user's view -- there is no "switch role" or "view as group" feature. Access control is enforced server-side via the auth middleware.

## Summary

| # | Misalignment | Winner | Action Taken |
|---|-------------|--------|--------------|
| 1 | Session info panel vs page | Implementation (page) | Wireframe reworked to standalone page |
| 2 | Partial vs full SPA | Implementation (full SPA) | All wireframes assume SPA navigation |
| 3 | Guard chain detail level | Wireframe (design intent) | Annotated as future enhancement |
| 4 | Two-tier privilege UI | Neither (no UI needed) | Documented as backend-only |
