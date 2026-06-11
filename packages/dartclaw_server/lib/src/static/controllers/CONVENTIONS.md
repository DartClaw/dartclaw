# Stimulus Controller Conventions

This document defines the Stimulus controller contract for Web UI migration stories.

## Naming

- Controller identifier format: `dc-*` kebab-case (example: `dc-health`).
- Controller file format: `dc_*_controller.js` (example: `dc_health_controller.js`).
- Keep one default-exported controller class per file.

## Registration

- Register each controller explicitly in `index.js` via `application.register('dc-name', ControllerClass)`.
- Do not use lazy auto-discovery or filename-based autoloading.
- Keep all registrations in `index.js` so available controllers are auditable in one place.

## Attributes

- Attach controller behavior with `data-controller="dc-name"`.
- Use Stimulus actions as `data-action="event->dc-name#method"`.
- Use targets as `data-dc-name-target="targetName"`.
- Use values as `data-dc-name-*-value="..."`.

## Lifecycle and HTMX

- Controllers must rely on Stimulus `connect()` and `disconnect()` lifecycle hooks.
- Do not rely on legacy `runPageHook(...)` or `initAfterSwapReinit()` hooks for controller lifecycle.
- HTMX swaps and removals are handled by Stimulus mutation observation, so teardown/setup must live in `disconnect`/`connect`.

## Trellis Integration

- Static Stimulus attributes can be written directly in template HTML.
- Dynamic Stimulus attributes must use `tl:attr` for safe emission.
- Prefer precomputed values from Dart context maps over complex template expressions.
