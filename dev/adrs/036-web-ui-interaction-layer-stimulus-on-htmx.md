# ADR-036: Web UI Interaction Layer — Stimulus on HTMX

## Status

Accepted — 2026-05-31 (implemented in 0.16.6; recorded retroactively during an ADR-gap review of 0.16.4–0.16.6)

**Related:** Supersedes the page-global IIFE (`dartclaw.pages.*`) + `initAfterSwapReinit()` interaction model. Interacts with the project's strict CSP (`security_headers.dart`) and the zero-Node toolchain principle.

**Superseded in part (2026-06-09):** the canvas surface referenced in the Decision (the "Narrow exception" bullet) and in Consequences was removed from core — see the `remove-canvas-feature` FIS. The decision text below is preserved as the historical record; the standalone canvas surface no longer exists, the inline rationale it cited in `controllers/index.js` is gone, and the interaction model is now uniform (no remaining Stimulus exception). Canvas may return later as an opt-in add-on package rather than a core surface.

## Context

The browser interaction layer was a set of page-global IIFE modules (`dartclaw.pages.*`) re-initialized after HTMX swaps via a manual `initAfterSwapReinit()` / `runPageHook` path. This had no lifecycle contract, produced recurring re-initialization bugs, and was hard to audit (no single inventory of what JS owned which surface). Any replacement had to honor three hard constraints: the **zero-Node toolchain** (no npm / `node_modules` / bundler), **server-rendered Trellis + HTMX** as the rendering model, and a **strict CSP** with no `unsafe-eval` and no new origins. 0.16.6 technical research compared the options against these constraints.

## Decision

Adopt **Stimulus 3.2.1** as the browser interaction layer:

- **One controller per surface** — 14 `dc-*` controllers covering every page with JS behavior; `connect()` / `disconnect()` is the lifecycle, so HTMX swap re-initialization is an implicit consequence of controller connection rather than a manual global hook.
- **Vendoring policy** — Stimulus 3.2.1 is consumed as a single vendored UMD file at `packages/dartclaw_server/lib/src/static/stimulus.min.js` (loaded `defer` from `layout.html`); no npm, `node_modules`, or build step. `static/VENDORS.md` documents the version and re-vendor procedure. The zero-Node toolchain is preserved.
- **Explicit registration** — `controllers/index.js` calls `Application.start()` once and explicitly `application.register('dc-name', …)` for every controller, so the available controllers are auditable in one file (no lazy autoloader).
- **Authoring contract** — `controllers/CONVENTIONS.md` locks the `dc-*` identifier prefix, `dc_*_controller.js` filename pattern, the template attribute family (`data-controller`, `data-action="event->dc-name#method"`, targets, values), the lifecycle, and Trellis (`tl:attr`) integration.
- **CSP unchanged** — `security_headers.dart` `script-src` was not relaxed; the vendored bundle works under the existing policy (verified by an empty diff on that file).
- **Narrow exception** — the standalone canvas surface stays outside Stimulus (it is an independent document with its own nonce-based CSP and does not share `layout.html`'s bootstrap); the rationale is recorded inline in `controllers/index.js`. _(Removed 2026-06-09: canvas was removed from core, so this exception no longer exists — see the Status note. May return as an opt-in add-on.)_

## Consequences

### Positive

- A real lifecycle contract for DOM islands; HTMX-driven create/remove maps naturally onto `connect()` / `disconnect()`, eliminating the manual re-init bug class.
- The controller inventory is auditable in one file.
- CSP is unchanged and the zero-Node toolchain is preserved — Stimulus is a single vendored file with no `unsafe-eval`.

### Negative

- A new front-end dependency to track and upgrade (mitigated by `VENDORS.md`).
- Broad, hard-to-reverse migration: 14 controllers across ~66 changed files; the legacy page-global scripts and `app.js` shell path were removed.
- The canvas exception means the interaction model is not 100% uniform. _(Obsolete 2026-06-09: the canvas exception was removed; the interaction model is now uniform — see the Status note.)_

## Alternatives Considered

1. **Keep the IIFE + `initAfterSwapReinit()` status quo** — rejected: no lifecycle contract; the re-init bug class persists; not auditable.
2. **Alpine.js** — rejected: in-HTML expression evaluation strains the strict no-`unsafe-eval` CSP and pushes behavior into templates.
3. **Web Components / Lit** — rejected: heavier model and more boilerplate than needed for HTMX-rendered islands.
4. **htmx + _hyperscript only** — rejected: insufficient for the stateful per-surface behavior the app needs.
5. **A build-step framework (npm / bundler)** — rejected: violates the zero-Node toolchain principle.

## Implementation Notes

- `dev/guidelines/HTMX-GUIDELINES.md` gained a "Use Stimulus for browser behavior owned by DOM islands" section; `dev/architecture/system-architecture.md` and `dev/design-system/DESIGN.md` were updated; stale `dartclaw.pages.*` / `loadScript()` references removed.
- The `dc-*` controller conventions are currently enforced by review, not by a fitness function — a candidate future check under [ADR-033](033-architectural-governance-via-fitness-functions.md).

## References

- 0.16.6 PRD, plan, technical research, and FIS files.
- `packages/dartclaw_server/lib/src/static/` — `stimulus.min.js`, `controllers/index.js`, `controllers/CONVENTIONS.md`, `VENDORS.md`; `lib/src/auth/security_headers.dart` (unchanged)
- CHANGELOG `[0.16.6]`; release commit `bf180de1`
