# S24 — SidebarDataBuilder Extraction

**Plan**: ../plan.md
**Story-ID**: S24

## Feature Overview and Goal

Lift the top-level `buildSidebarData(...)` helper in `packages/dartclaw_server/lib/src/web/web_routes.dart` (and its 6 verbose call sites that each pass 7-10 named parameters) into a dedicated `SidebarDataBuilder` class constructed once per request-handling context and exposed via `PageContext.sidebar`. Each call site then collapses to a single `pageContext.sidebar.build(activeSessionId: id)` invocation. Pure structural extraction: zero behaviour change, no new deps, HTMX/Trellis output byte-stable.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S24 — SidebarDataBuilder Extraction" entry under per-story File Map)_

## Required Context

### From `prd.md` — "FR8: Housekeeping Sweep + Tech-Debt Mop-Up"
<!-- source: ../prd.md#fr8-housekeeping-sweep--tech-debt-mop-up -->
<!-- extracted: e670c47 -->
> - [ ] `SidebarDataBuilder` extracted; 6 call sites collapsed

### From `plan.md` — "S24: SidebarDataBuilder Extraction"
<!-- source: ../plan.md#s24-sidebardatabuilder-extraction -->
<!-- extracted: e670c47 -->
> **Scope**: Extract a `SidebarDataBuilder` class in `packages/dartclaw_server/lib/src/web/web_routes.dart`. Construct once per-request context, expose `Future<SidebarData> build({String? activeSessionId})`. Inject via `PageContext`. Collapse the 6 existing call sites (each currently passes 7-10 similar named parameters) to `pageContext.sidebar.build(activeSessionId: id)`.
>
> **Acceptance Criteria**:
> - [ ] `SidebarDataBuilder` exists as a dedicated class (must-be-TRUE)
> - [ ] All 6 `buildSidebarData(...)` call sites collapsed to the builder invocation (must-be-TRUE)
> - [ ] `dart test packages/dartclaw_server/test/web` passes

### From `.technical-research.md` — "Binding PRD Constraints" (S24-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #2 (Constraint): "No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`." — Applies to all stories; this story adds no deps.
> #71 (NFR Reliability): "Behavioural regressions post-decomposition: Zero — every existing test remains green." — Applies to S15, S16, S17, S18, S22, S33 _and_ this story (purely structural extraction).
> #75 (FR8): "`SidebarDataBuilder` extracted; 6 call sites collapsed." — This story.

## Deeper Context

- `packages/dartclaw_server/CLAUDE.md` § "Conventions" — page-side rendering goes through `PageContext`; `dashboard_page.dart` already exposes a `buildSidebarData()` accessor on `PageContext` that this story replaces with a richer `sidebar` handle.
- `packages/dartclaw_server/lib/src/web/dashboard_page.dart:36-86` — current `PageContext` shape, including the existing `_buildSidebarData` arg-less closure injected by `web_routes.dart` and `server.dart`. The new builder replaces both.
- `packages/dartclaw_server/lib/src/templates/sidebar.dart:26-36` — `SidebarData` typedef. The story extends it with `String? activeSessionId` so the rendered template can read the active id from the bundle instead of receiving it as a separate top-level parameter; this is the seam that lets each call site collapse to one line.
- `dev/state/UBIQUITOUS_LANGUAGE.md` — `PageContext`, `SidebarData`, `DashboardPage` are canonical terms; preserve naming.

## Success Criteria (Must Be TRUE)

- [ ] `SidebarDataBuilder` exists as a dedicated class in `packages/dartclaw_server/lib/src/web/sidebar_data_builder.dart` with a `Future<SidebarData> build({String? activeSessionId})` method (proof: TI01 Verify line + scenario "Builder produces identical SidebarData payload")
- [ ] `PageContext` exposes the builder via a `final SidebarDataBuilder sidebar;` field (or equivalent getter) replacing the existing `_buildSidebarData` closure handle (proof: TI02 Verify line)
- [ ] All 6 rich call sites of the top-level `buildSidebarData(...)` helper — 5 in `packages/dartclaw_server/lib/src/web/web_routes.dart` (currently at lines 149, 221, 262, 404, 459) and 1 in `packages/dartclaw_server/lib/src/server.dart` (currently at line 963) — collapse to `pageContext.sidebar.build(activeSessionId: …)` or, where no `pageContext` is in scope (the `server.dart` `SessionRouter` wiring), to a closure that delegates to the same single builder instance (proof: TI03 Verify line + scenario "Sidebar renders identically across the 6 routes")
- [ ] The top-level `Future<SidebarData> buildSidebarData(...)` helper (currently at `web_routes.dart:721`) is removed; the body lives inside `SidebarDataBuilder.build` (proof: TI03 Verify line — `rg "^Future<SidebarData> buildSidebarData\\(" packages/dartclaw_server/lib` returns zero hits)
- [ ] `SidebarData` typedef gains `String? activeSessionId`; `sidebarTemplate` reads it from the bundle rather than receiving it as a separate `activeSessionId:` top-level argument (proof: TI04 Verify line)
- [ ] `dart test packages/dartclaw_server/test/web` passes
- [ ] `dart test packages/dartclaw_server` passes (broader regression net — pairing-route tests, session-route tests, settings-page tests all touch the sidebar surface)
- [ ] `dart analyze` workspace-wide: 0 warnings, 0 errors

### Health Metrics (Must NOT Regress)

- [ ] HTMX/Trellis HTML output for the 6 affected routes is byte-stable. Capture rendered bodies before and after; diff is empty (proof: scenario "Sidebar renders identically across the 6 routes")
- [ ] `PageContext` API remains additive: existing `pageContext.buildSidebarData()` callers in `lib/src/web/pages/*.dart` and tests continue to compile, either by retaining `buildSidebarData()` as a thin shim that delegates to `sidebar.build()` or by mechanically updating those call sites in this story. Pick the smaller diff
- [ ] Test fakes in `packages/dartclaw_server/test/api/session_routes_test.dart`, `test/web/settings_page_test.dart`, `test/web/pages/{tasks_page_test,task_detail_test,workflows_page_test}.dart` keep working — they currently inject `buildSidebarData: () async => emptySidebarData`; either the new `sidebar` field accepts a builder fake or the existing closure injection point survives as a back-compat shim
- [ ] JSON wire formats (REST envelopes, SSE event payloads) unchanged — Constraint #1; sidebar surface is HTML-only so no wire-format risk, but state explicitly
- [ ] Pairing-route call sites in `whatsapp_pairing_routes.dart:28,119` and `signal_pairing_routes.dart:27,90` (each currently calls `buildSidebarData(sessions, tasksEnabled: tasksEnabled)` with sparse args) continue to compile and behave identically. They are out of the "6 rich call sites" bucket; they may either route through the new builder via a shared factory or retain a 2-arg helper — pick whichever is the smaller diff and document the choice

## Scenarios

### Builder produces identical SidebarData payload
- **Given** the same `SessionService`, `KvService`, `defaultProvider`, `showChannels`, `tasksEnabled`, `TaskService`, and `WorkflowService` inputs that the legacy `buildSidebarData(...)` top-level function received
- **When** `SidebarDataBuilder(...).build(activeSessionId: id)` is invoked
- **Then** the returned `SidebarData` carries the same `main`, `dmChannels`, `groupChannels`, `activeEntries`, `archivedEntries`, `activeTasks`, `activeWorkflows`, `showChannels`, `tasksEnabled` values as the legacy helper would have produced for the same inputs (asserted by a Layer-2 test that runs both the legacy code path on a snapshot of the pre-change source — or simply asserts against a fixture — and the new builder on the same fixture)

### Sidebar renders identically across the 6 routes
- **Given** an in-memory `DartclawServer` test harness with seeded sessions, tasks, and workflows covering main / DM / group channel / user / archive types
- **When** each of the 6 routes whose call site collapses (`/`, `/sessions/<id>`, `/sessions/<id>/info`, `/settings/channels/<type>`, plus the sidebar lambda passed into `PageContext` from `web_routes.dart` line 149, plus the sidebar lambda passed into `sessionRoutes(...)` from `server.dart` line 963 — exercised via the routes that use them) is hit before and after the extraction
- **Then** the rendered HTML body is byte-identical between the two runs (modulo runtime-variable fields like timestamps, which the test fixes deterministically)

### New consumer obeys the one-line idiom
- **Given** a future route handler in `lib/src/web/` that needs sidebar data
- **When** the handler reaches for sidebar context
- **Then** the canonical pattern is `final sidebarData = await pageContext.sidebar.build(activeSessionId: id);` — no helper-call with 7+ named parameters survives in `lib/src/web/`

### Empty / null active-session case
- **Given** a request with no active session (e.g. `GET /` fallback path that has no session to redirect to)
- **When** `pageContext.sidebar.build()` is called with no `activeSessionId` argument (or `activeSessionId: null`)
- **Then** the resulting `SidebarData.activeSessionId` is `null`, the rendered sidebar shows no entries marked `active: true`, and no error is thrown

### Workflow / task disabled paths still work
- **Given** a `PageContext` constructed with `tasksEnabled: false` (e.g. test harness or a deployment without `taskService` + `eventBus` wired)
- **When** `pageContext.sidebar.build(activeSessionId: id)` is invoked
- **Then** the returned `SidebarData.activeTasks` and `SidebarData.activeWorkflows` are empty lists, and no calls are made to `buildActiveSidebarTasks` / `buildActiveSidebarWorkflows`

## Scope & Boundaries

### In Scope

- New `SidebarDataBuilder` class at `packages/dartclaw_server/lib/src/web/sidebar_data_builder.dart` carrying the seven inputs once (sessions, kvService, defaultProvider, showChannels, tasksEnabled, taskService, workflowService) and exposing `Future<SidebarData> build({String? activeSessionId})` _(covered by TI01)_
- `PageContext` extension: replace the `_buildSidebarData` closure handle with a `SidebarDataBuilder sidebar` field (or getter); migrate / shim existing `pageContext.buildSidebarData()` callers _(covered by TI02)_
- Collapse 5 rich call sites in `web_routes.dart` (lines 149, 221, 262, 404, 459) and 1 in `server.dart` (line 963) to single-line builder invocations; remove the top-level `buildSidebarData(...)` helper _(covered by TI03)_
- Extend `SidebarData` typedef with `String? activeSessionId`; update `sidebarTemplate` to read it from the bundle so each call site no longer needs a separate `activeSessionId:` template arg _(covered by TI04)_
- Verification: `dart test packages/dartclaw_server/test/web` plus broader `dart test packages/dartclaw_server` plus `dart analyze` workspace-wide _(covered by TI05)_
- Byte-stable rendered-HTML diff across the 6 routes (proof scenario "Sidebar renders identically") _(covered by TI06)_

### What We're NOT Doing

- **Refactoring `sidebar.html` / Trellis sidebar templates.** Out of scope — the goal is structural-only at the data-builder seam; template rendering stays put
- **Redesigning `PageContext` shape beyond the sidebar seam.** Out of scope — the 16 other fields stay as-is; this story extends, never reshapes
- **Decomposing the wider `web_routes.dart` god-method.** Out of scope and tracked separately under the broader Block E/G hygiene effort; only the 5 sidebar call sites in this file change here
- **Changing route signatures or the public shelf-router surface.** Out of scope; route-handler bodies change internally only
- **Migrating the 4 sparse pairing-route call sites** (`whatsapp_pairing_routes.dart:28,119`, `signal_pairing_routes.dart:27,90`) **into the builder unless trivially cheap.** The plan AC counts "6 call sites" referring to the rich (7-10 arg) sites; pairing routes pass only `(sessions, tasksEnabled: …)` and may keep a 2-arg helper or route through the builder — pick the smaller diff. Document the choice in TI03

### Agent Decision Authority

- **Autonomous**: whether `pageContext.buildSidebarData()` is retained as a back-compat shim or its callers (`pages/settings_page.dart`, `pages/tasks_page.dart`, `pages/projects_page.dart`, `pages/canvas_admin_page.dart`, `pages/workflows_page.dart`) are mechanically migrated to `pageContext.sidebar.build()` in this story (pick the smaller diff); whether pairing-route call sites route through the builder or keep a sparse helper
- **Escalate**: any change that alters rendered HTML for any of the 6 routes — Health Metric "byte-stable" forbids it without explicit user sign-off

## Architecture Decision

**We will**: introduce `SidebarDataBuilder` as a dedicated class constructed once per request-handling context and exposed via `PageContext.sidebar`. — each call site currently passes 7-10 similar named parameters; the builder collapses to a single per-request instance handle and a one-line `build(activeSessionId: id)` invocation per route. (over a kept-as-helper-with-defaults alternative — rejected because it doesn't address the call-site verbosity that the plan AC explicitly calls out.)

This is a Low-risk single-class extraction; the compact rationale is sufficient per plan guidance.

## Technical Overview

### Data Models

`SidebarData` typedef gains one optional field:
- `String? activeSessionId` — propagated from the call site through the builder so `sidebarTemplate` reads it from the bundle. Existing fields unchanged.

### Integration Points

- **`PageContext`** (`lib/src/web/dashboard_page.dart`): replace `_buildSidebarData` closure with a `final SidebarDataBuilder sidebar;` field. Optionally retain `Future<SidebarData> buildSidebarData()` as a `@Deprecated`-tagged shim that calls `sidebar.build()` for back-compat with the 6+ existing `context.buildSidebarData()` callers in `lib/src/web/pages/*.dart`, OR migrate those call sites in the same story.
- **`web_routes.dart`** construction site (line 132): `PageContext(...)` constructor call passes `sidebar: SidebarDataBuilder(...)` instead of `buildSidebarData: () => buildSidebarData(...)`.
- **`server.dart`** (`_mountSessionRoutes`, line 963): the lambda that previously built sidebar data for `sessionRoutes(...)` now closes over a single shared `SidebarDataBuilder` instance — or the route signature accepts a `SidebarDataBuilder` directly. Pick whichever is the smaller diff.
- **Pairing routes** (`signal_pairing_routes.dart`, `whatsapp_pairing_routes.dart`): no `PageContext` available; either accept a `SidebarDataBuilder` via their existing function signatures or keep a small `buildSidebarDataMinimal(sessions, {required bool tasksEnabled})` helper. Document the choice in TI03.

## Code Patterns & External References

```
# type | path/url | why needed
file | packages/dartclaw_server/lib/src/web/web_routes.dart:721-778      | Body to lift verbatim into SidebarDataBuilder.build
file | packages/dartclaw_server/lib/src/web/web_routes.dart:132-160      | PageContext construction — the seam where the builder is wired
file | packages/dartclaw_server/lib/src/web/web_routes.dart:149,221,262,404,459 | The 5 rich call sites in this file
file | packages/dartclaw_server/lib/src/server.dart:963-969               | The 6th rich call site (SessionRouter wiring)
file | packages/dartclaw_server/lib/src/web/dashboard_page.dart:36-86    | Existing PageContext shape — extend, do not reshape
file | packages/dartclaw_server/lib/src/templates/sidebar.dart:26-36     | SidebarData typedef to extend with activeSessionId
file | packages/dartclaw_server/lib/src/templates/sidebar.dart:49-110    | sidebarTemplate signature to update to read activeSessionId from bundle
file | packages/dartclaw_server/lib/src/web/whatsapp_pairing_routes.dart:9,28,119 | Sparse-arg call sites; out of "6" bucket
file | packages/dartclaw_server/lib/src/web/signal_pairing_routes.dart:9,27,90    | Sparse-arg call sites; out of "6" bucket
file | packages/dartclaw_server/test/api/session_routes_test.dart:352,377 | Test fakes injecting buildSidebarData closure
file | packages/dartclaw_server/test/web/pages/tasks_page_test.dart:60,108 | Test fakes
file | packages/dartclaw_server/test/web/settings_page_test.dart:81      | Test fakes
file | packages/dartclaw_server/test/web/pages/workflows_page_test.dart:62 | Test fakes
file | packages/dartclaw_server/test/web/pages/task_detail_test.dart:63  | Test fakes
```

## Constraints & Gotchas

- **Constraint**: No new dependencies (Binding Constraint #2). `SidebarDataBuilder` uses only the already-injected services; no new imports outside this package.
- **Constraint**: Zero behaviour change (Binding Constraint #71). Rendered HTML for all 6 routes must be byte-stable; the builder is a pure mechanical lift.
- **Constraint**: `PageContext` API is additive only. If existing `pageContext.buildSidebarData()` callers stay, the shim must call `sidebar.build()` and not duplicate logic.
- **Avoid**: introducing a stateful builder that caches `SidebarData` between calls — the legacy helper queries `sessions.listSessions()` fresh on every invocation, and that semantics must be preserved (some routes hit it twice per request via the lambda + a direct call). Instead: builder holds only the input services; `build()` runs the query each time.
- **Critical**: tests in `dartclaw_server/test/api/session_routes_test.dart`, `test/web/**` inject a fake `buildSidebarData: () async => …` closure into `PageContext`. The new `sidebar` field must accept a fake-able shape — either `SidebarDataBuilder` is an abstract-able base or the `PageContext` constructor still accepts a builder-or-closure injection point for tests. Pick the smaller diff; document.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** `SidebarDataBuilder` class exists at `packages/dartclaw_server/lib/src/web/sidebar_data_builder.dart` carrying `SessionService sessions`, `KvService? kvService`, `String defaultProvider`, `bool showChannels`, `bool tasksEnabled`, `TaskService? taskService`, `WorkflowService? workflowService` as final fields (constructor injects all) and exposing `Future<SidebarData> build({String? activeSessionId})`. Body is lifted verbatim from the legacy helper at `web_routes.dart:721-778`, plus the new `activeSessionId` is propagated into the returned `SidebarData`.
  - Class lives under `lib/src/web/` per package convention; no new package dependencies; helpers `_resolveSidebarProvider` / `_isGroupChannel` move with it (made private members of the class) or stay file-private at the new file
  - **Verify**: `rg "class SidebarDataBuilder" packages/dartclaw_server/lib/src/web/sidebar_data_builder.dart` returns one hit; the file imports nothing outside the package's existing dependency set; `dart analyze packages/dartclaw_server` is clean

- [ ] **TI02** `PageContext` (`lib/src/web/dashboard_page.dart`) exposes the builder via `final SidebarDataBuilder sidebar;` (or equivalent fake-able shape). Existing `pageContext.buildSidebarData()` callers either (a) continue to compile via a thin `Future<SidebarData> buildSidebarData() => sidebar.build();` shim, or (b) are mechanically migrated to `pageContext.sidebar.build()` in this same task. Pick the smaller diff and note the choice.
  - Test fakes in `test/api/session_routes_test.dart`, `test/web/**` keep compiling — either by accepting a `SidebarDataBuilder` fake or by retaining the closure-injection seam under a renamed parameter that wraps a builder
  - **Verify**: `pageContext.sidebar` accessor exists and is non-null in the production wiring; `dart test packages/dartclaw_server/test/web` and `dart test packages/dartclaw_server/test/api/session_routes_test.dart` both pass

- [ ] **TI03** All 6 rich call sites collapse: 5 in `web_routes.dart` (lines 149, 221, 262, 404, 459) and 1 in `server.dart` (line 963) become either `pageContext.sidebar.build(activeSessionId: id)` (in route handlers with a `pageContext` in scope) or a closure delegating to a single shared `SidebarDataBuilder` instance (for the `server.dart`/`SessionRouter` wiring that has no `pageContext`). The top-level `Future<SidebarData> buildSidebarData(...)` helper in `web_routes.dart:721-778` is removed. Pairing-route call sites (sparse-arg, in `whatsapp_pairing_routes.dart` + `signal_pairing_routes.dart`) keep working; document whether they route through the builder or retain a small 2-arg helper.
  - The `_resolveSidebarProvider` and `_isGroupChannel` private helpers move with the body; no orphaned private functions left in `web_routes.dart`
  - **Verify**: `rg "^Future<SidebarData> buildSidebarData\\(" packages/dartclaw_server/lib` returns zero hits; `rg "buildSidebarData\\(" packages/dartclaw_server/lib/src/web/web_routes.dart` returns zero hits; `rg "buildSidebarData\\(" packages/dartclaw_server/lib/src/server.dart` returns zero hits; pairing-route call-site behaviour documented in commit message or task notes

- [ ] **TI04** `SidebarData` typedef in `lib/src/templates/sidebar.dart:26-36` gains `String? activeSessionId`. `sidebarTemplate` signature drops the separate `activeSessionId:` named parameter (or keeps it as a back-compat shim that defaults from `sidebarData.activeSessionId`). Update the 5 call sites of `sidebarTemplate(...)` in `web_routes.dart` and any other `sidebarTemplate` callers to match.
  - **Verify**: `rg "typedef SidebarData" packages/dartclaw_server/lib/src/templates/sidebar.dart` shows the new field; `dart analyze packages/dartclaw_server` is clean

- [ ] **TI05** Test suite passes: `dart test packages/dartclaw_server/test/web` (the plan-named gate) plus broader `dart test packages/dartclaw_server` plus `dart analyze` workspace-wide.
  - **Verify**: all three commands exit 0

- [ ] **TI06** Rendered-HTML byte-stability spot-check across the 6 affected routes. Using a deterministic test harness (seeded sessions covering main/DM/group/user/archive types; fixed clocks; deterministic id generation), capture the rendered HTML body for `/`, `/sessions/<id>`, `/sessions/<id>/info`, `/settings/channels/whatsapp`, `/settings/channels/signal`, `/settings/channels/google_chat` before and after the extraction, and assert the diff is empty (modulo any timestamp fields, which the test fixture pins). Either add a dedicated Layer-2 test or document the spot-check in the commit message with both rendered bodies stashed under `.agent_temp/` for the reviewer.
  - **Verify**: byte-equal bodies (or diff limited to known-deterministic-input fields)

### Testing Strategy

- [TI01] Scenario "Builder produces identical SidebarData payload" → Layer 2 test: construct `SidebarDataBuilder` with a seeded `SessionService` + fakes; assert returned `SidebarData` matches expected fixture for both `activeSessionId: null` and `activeSessionId: '<seeded-id>'`
- [TI03,TI06] Scenario "Sidebar renders identically across the 6 routes" → Layer 3 test: hit each of the 6 routes against an in-memory `DartclawServer`, capture body, diff against pre-extraction snapshot
- [TI03] Scenario "New consumer obeys the one-line idiom" → static check via `rg`: `rg "buildSidebarData\\(" packages/dartclaw_server/lib/src/web/` returns zero hits (top-level helper gone)
- [TI01] Scenario "Empty / null active-session case" → unit test: `build()` with no `activeSessionId` returns `SidebarData` with `activeSessionId: null` and zero `active` flags downstream
- [TI01] Scenario "Workflow / task disabled paths still work" → unit test with `tasksEnabled: false`; assert `activeTasks` + `activeWorkflows` are empty

### Validation

Standard validation handled by exec-spec. Feature-specific:
- Visual smoke is **not** required (this is structural-only); the byte-stability spot-check in TI06 is the proof-of-no-regression.

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding.
- Prescriptive details (file paths, class name `SidebarDataBuilder`, method signature `Future<SidebarData> build({String? activeSessionId})`, target file `packages/dartclaw_server/lib/src/web/sidebar_data_builder.dart`) are exact.
- After all tasks: `dart format packages/dartclaw_server`, `dart analyze --fatal-warnings --fatal-infos`, `dart test packages/dartclaw_server`, and `rg "TODO|FIXME|placeholder|not.implemented" packages/dartclaw_server/lib/src/web/sidebar_data_builder.dart packages/dartclaw_server/lib/src/web/web_routes.dart packages/dartclaw_server/lib/src/web/dashboard_page.dart packages/dartclaw_server/lib/src/templates/sidebar.dart packages/dartclaw_server/lib/src/server.dart` clean.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] **All success criteria** met
- [ ] **All tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** or breaking changes introduced (HTMX/Trellis output byte-stable)
- [ ] **`dart test packages/dartclaw_server/test/web`** green (the plan-named gate)
- [ ] **`dart analyze` workspace-wide** clean

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
