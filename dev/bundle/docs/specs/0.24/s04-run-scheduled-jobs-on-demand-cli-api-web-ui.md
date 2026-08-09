# FIS: Run Scheduled Jobs On Demand (CLI + API + Web UI)

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S04

> Milestone: **0.24** (do **not** implement on `feat/0.23` – release prep). All code paths below are
> relative to the `dartclaw-public` checkout. Source: field feedback §3 + operator Web UI addition (2026-08-05).

## Feature Overview and Goal

**Intent**: Operators authoring or debugging a scheduled job currently must edit its cron, restart, wait, observe,
revert, and restart again – an immediate manual trigger lets them verify a job's prompt and delivery (e.g. that an
`announce` actually reaches its channel) in seconds.

**Expected Outcomes**:

- [OC01] An operator can execute a configured job immediately with `dartclaw jobs run <name>` against a running
  server, and it behaves exactly like a scheduled fire: same isolated cron session, configured retry policy, and
  configured delivery mode.
- [OC02] The HTTP API exposes `POST /api/scheduling/jobs/<name>/run` with correct semantics – `202` started,
  `404` unknown-to-the-live-scheduler, `409` already running – behind the same auth as sibling scheduling routes.
- [OC03] The Web UI Scheduling page offers a Run action per prompt-type job – user-defined or built-in (owner decision 2026-08-05) – with toast feedback; callback SYSTEM rows stay action-less.
- [OC04] A manual run never disturbs the schedule: pending timers, interval cadence, pause state, and one-time-job
  semantics are unaffected. Corollary of the shared `_running` guard: a scheduled fire landing while a manual run
  is in flight is skipped and the schedule continues at the next fire – accepted parity behavior, documented in
  user docs (TI06). `once` caveat: outside that window a manual run neither consumes nor cancels the pending
  fire; a `once` fire landing during an in-flight manual run is skipped and – having no next fire – lost.

## Required Context

### From field feedback – "`dartclaw jobs` has no way to run a job on demand"
<!-- source: /Users/tobias/Repos/SecondBrain/system/dartclaw-feedback/open.md#2-add-dartclaw-jobs-run-id -->
<!-- extracted: 2026-08-05 -->
> `dartclaw jobs` offers `create`/`delete`/`list`/`show`. There is no `run`/`trigger`, and no equivalent HTTP route.
>
> Testing a scheduled job therefore means: edit its cron to a couple of minutes out → restart the service → wait →
> observe → revert → restart again. For jobs that legitimately run at 06:45 or 22:00, that is the only way to see
> whether the prompt works at all.
>
> Suggested: `dartclaw jobs run <id>` executing the job immediately, with its configured delivery. Useful for
> authoring prompts, and for verifying an `announce` job actually reaches its channel before trusting it.

### From operator (conversation, 2026-08-05) – Web UI addition
<!-- source: operator request, session 2026-08-05 -->
<!-- extracted: 2026-08-05 -->
> I also would like to add the possibility to run jobs directly in the WebUI.

## Deeper Context

- `docs/guide/scheduling.md#cron-jobs` – user-facing job model (schedule types, prompts) the new section extends.
- `docs/guide/scheduling.md#delivery-modes` – `announce`/`webhook`/`none` semantics a manual run must honor.
- `docs/guide/web-ui-and-api.md#scheduling` – existing scheduling endpoint documentation the run route joins.
- `dev/architecture/observability-operations-architecture.md#scheduleservice` – canonical ScheduleService
  architecture notes; update if the new public seam changes a documented fact.

## Acceptance Scenarios

- [x] **S01 [OC01,OC02] [TI01,TI02] Happy path – API run executes with configured delivery**
  - **Given** a running server with configured job `daily-summary` (delivery `announce`, schedule `0 8 * * *`)
    that is not currently executing
  - **When** `POST /api/scheduling/jobs/daily-summary/run` is called
  - **Then** the response is `202` with body `{"name": "daily-summary", "status": "started"}`, and the job executes
    through the same pipeline as a scheduled fire: an agent turn in the isolated `cron` session for
    `daily-summary`, followed by `DeliveryService.deliver` with mode `announce` carrying the turn's result text

- [x] **S02 [OC01] [TI03] CLI run command**
  - **Given** a running server with job `daily-summary` configured
  - **When** the operator runs `dartclaw jobs run daily-summary`
  - **Then** the command exits 0 and prints a confirmation naming `daily-summary` and stating the job was started
    and where to observe the outcome – the job's configured delivery (if any) and the server logs; with `--json`
    it prints the API response JSON instead

- [x] **S03 [OC03] [TI04,TI05] Web UI Run action**
  - **Given** the Scheduling page renders user job `daily-summary`, a prompt-type SYSTEM job row (e.g.
    `memory-journal`), and a callback SYSTEM job row (e.g. the memory pruner's)
  - **When** the operator clicks the Run button on the `daily-summary` row
  - **Then** the controller POSTs `/api/scheduling/jobs/daily-summary/run` and shows a success toast naming the
    job; the prompt-type SYSTEM row renders a Run button (and no Edit/Delete); the callback SYSTEM row renders no
    action buttons (owner decision 2026-08-05: prompt-type jobs are runnable on demand regardless of origin)

- [x] **S04 [OC02,OC04] [TI01,TI02] Already running – rejected, not queued**
  - **Given** job `daily-summary` is currently executing (scheduled fire or a prior manual run)
  - **When** `POST /api/scheduling/jobs/daily-summary/run` is called
  - **Then** the response is `409` with error code `CONFLICT`, and no second concurrent execution of the job
    starts; conversely, a scheduled fire landing during an in-flight manual run is skipped by the same guard and
    the schedule continues at the next fire (OC04)

- [x] **S05 [OC02] [TI02] Unknown or restart-pending job – 404**
  - **Given** `nightly-review` was just created via `POST /api/scheduling/jobs` (written to YAML, restart pending)
    and is absent from the live scheduler's job list
  - **When** `POST /api/scheduling/jobs/nightly-review/run` is called
  - **Then** the response is `404` with error code `NOT_FOUND` and a message noting the job is not present in the
    running scheduler or not runnable on demand (newly created or edited jobs require a restart; otherwise check
    server logs for config errors); a completely unknown name yields the same `404` response and message

- [x] **S06 [OC04] [TI01] Paused job runs manually and stays paused**
  - **Given** job `daily-summary` was paused via the existing toggle endpoint
  - **When** a manual run is triggered
  - **Then** the job executes once, remains paused afterwards, and no next-fire timer is scheduled for it

- [x] **S07 [OC01,OC04] [TI01] Failure parity – configured retries and alert, no delivery**
  - **Given** job `flaky-job` with `retry.attempts: 1` whose agent turn fails on both attempts
  - **When** a manual run is triggered
  - **Then** exactly two attempts execute, `DeliveryService.deliver` is never called, and a `ScheduledJobFailedEvent`
    fires – identical to a failing scheduled fire

## Structural Criteria

- [x] Existing scheduling behavior is unchanged: job CRUD routes, the toggle route, and pause/resume semantics
  keep their current contracts – existing `config_routes`, `config_api_routes`, and `schedule_service` tests pass
  unmodified (proved by the TI01/TI02 Verify "existing cases unmodified" clauses + the standard full-suite gate).
- [x] A manual run leaves timer state untouched: it never cancels or reschedules pending cron/interval/once timers
  (proved by TI01 Verify).
- [x] The run route is registered inside the existing authed API pipeline only – no addition to any public-path
  allowlist in the auth middleware (proved by TI02 Verify).
- [x] Design-system canon and served assets stay in strict sync for icons, and `embedded_assets.g.dart` is
  regenerated via the tool, never hand-edited (proved by TI04/TI05 Verify).
- [x] User docs describe on-demand runs everywhere the feature surfaces – `scheduling.md`, `cli-reference.md`,
  `web-ui-and-api.md` (proved by TI06 Verify).

## Scope & Boundaries

### Work Areas

- `packages/dartclaw_server/lib/src/scheduling/schedule_service.dart` – new public on-demand run seam.
- `packages/dartclaw_server/lib/src/api/config_routes.dart` – `POST /api/scheduling/jobs/<name>/run` route.
- `apps/dartclaw_cli/lib/src/commands/jobs/` – new `run` subcommand + registration in `JobsCommand`.
- Web UI: `packages/dartclaw_server/lib/src/templates/scheduling.html` + `.dart`,
  `packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js`, icon canon
  (`dev/design-system/icons.css` → `packages/dartclaw_server/lib/src/static/icons.css`), embedded assets regen.
- User docs: `docs/guide/scheduling.md`, `docs/guide/cli-reference.md`, `docs/guide/web-ui-and-api.md`.

### What We're NOT Doing

- **No synchronous wait / result payload from the run route** (and no CLI `--wait`) – job turns are unbounded
  (minutes); the HTTP handler must not block. Outcome is observable via configured delivery, server logs, and the
  existing `ScheduledJobFailedEvent` alert path.
- **No running restart-pending (YAML-only) jobs** – the live scheduler's job set stays startup-bound, matching the
  existing restart model for all scheduling changes. No config hot-reload is introduced.
- **No per-run overrides** (delivery, model, prompt) – exact parity with a scheduled fire is the point of the
  feature; overrides would test a different job than the one configured.
- **No on-demand trigger for Scheduled Tasks** (`type: task` entries) – run-now for them means "create a task", a
  different seam (`ScheduledTaskRunner` owns them). Note they are NOT absent from `ScheduleService`: the wiring
  filters user task-type entries but re-registers each enabled definition as a live `auto-task-<defId>` callback
  job (`apps/dartclaw_cli/lib/src/commands/wiring/scheduling_wiring.dart` → `ScheduledTaskRunner.buildJobs()`),
  so TI01 must exclude callback jobs explicitly. Defer until requested.
- **No run history / last-run status in the UI** – requires persistence; out of scope.

## Architecture Decision

**Approach**: One new public seam on `ScheduleService` (e.g. `runJobNow(String id)`) that reuses the private
execution pipeline (`_running` guard + `_executeWithRetry`, so delivery/retry/consolidation/alerting are inherited)
while bypassing the pause skip and never touching timers; fronted by a `202`-async POST route in `config_routes.dart`
(the live-state router where the toggle already lives); CLI and Web UI are thin clients of that route.
**Why this over alternatives**: reusing `_executeJob` verbatim would skip paused jobs and reschedule timers
(cadence drift for interval jobs); a synchronous route would hold HTTP connections open for multi-minute turns.

## Technical Overview

## Code Patterns & External References

```
# type | path#anchor                                                                          | why needed (intent)
file   | packages/dartclaw_server/lib/src/scheduling/schedule_service.dart#ScheduleService     | Execution pipeline to reuse: `_running` guard, `_executeWithRetry`, pause/timer semantics to leave intact
file   | packages/dartclaw_server/lib/src/api/config_routes.dart                               | Route home + shape: toggle route's 404/`NOT_AVAILABLE` guards, `errorResponse`/`jsonResponse` envelope
file   | apps/dartclaw_cli/lib/src/commands/jobs/jobs_delete_command.dart#JobsDeleteCommand    | ConnectedCommand shape to copy: DI ctor, `runConnected`, `requirePositionalArg`, `--json` flag
file   | apps/dartclaw_cli/lib/src/commands/tasks/tasks_start_command.dart                     | `apiClient.postObject('/api/.../start')` action-command pattern
file   | packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js#deleteJob | Action-request pattern to copy for runJob: fetch + encodeURIComponent + this.apiQs + showToast/error-envelope handling
file   | packages/dartclaw_server/lib/src/templates/scheduling.html                            | Jobs-table `action-btns` cell (`hasActions` gating) where the Run button joins Edit/Delete
file   | packages/dartclaw_server/test/delivery_test_support.dart#RecordingDeliveryService     | Capture-only DeliveryService for TI01 delivery assertions
file   | packages/dartclaw_server/test/api/api_test_helpers.dart#ApiRouteTestClient            | Route-contract test client for TI02
file   | apps/dartclaw_cli/test/helpers/fake_api_transport.dart#FakeApiTransport               | CLI test transport for TI03
```

## Constraints & Gotchas

- **Restart-pending jobs are invisible to run-now**: CRUD writes YAML + `writeRestartPending`; neither the live
  `ScheduleService` job list nor the startup `schedulingDisplay.jobs` snapshot contains them. The `404` message must
  say restart is required so operators aren't confused by "I just created it" (S05). Applies to TI01–TI03 (TI03:
  the CLI client's generic 404 rewrite would otherwise bury this message – see TI03).
- **Router split is deliberate**: live-state control (toggle, run) lives in `config_routes.dart`; YAML-writing CRUD
  lives in `config_api_routes.dart`. Do not put the run route in the CRUD router.
- **Fire-and-forget discipline**: the HTTP handler must not await job completion – the execution future is spawned
  inside the service (TI01), wrapped in `unawaited()` with a caught-and-logged error handler
  (`dev/state/LEARNINGS.md` § Concurrency / Async). `_executeWithRetry` consumes per-attempt errors and never
  rethrows, so failures surface via its logging + `ScheduledJobFailedEvent`, not via the spawn-site handler.
- **Canon-first icons**: no play icon exists in the icon set today. Add it to `dev/design-system/icons.css` first,
  then sync to `packages/dartclaw_server/lib/src/static/icons.css` – icons are the one strict-synced design-system
  asset (fitness-checked); a served-only addition fails the gate.
- **Embedded assets**: any template/static/controller edit requires `dart run dev/tools/embed_assets.dart`;
  never hand-edit `embedded_assets.g.dart`.
- **Green tests can mask unwired routes/commands**: prove the route through the mounted `configRoutes` router and
  the CLI subcommand through its registration in `JobsCommand` plus a `CommandRunner`-driven invocation (the
  sibling `jobs_commands_test.dart` pattern – `JobsCommand()` has no transport DI seam, so `DartclawRunner.run`
  cannot carry a fake transport), not by direct method calls (`dev/state/LEARNINGS.md` § Package Architecture).

## Implementation Plan

### Implementation Tasks

- [x] **TI01** `ScheduleService` exposes an on-demand run seam with parity semantics
  - Public method (e.g. `runJobNow(String id)`) returning a discriminated result (started / alreadyRunning /
    notFound), decided synchronously: job lookup + `_running` check-and-add complete before the first suspension
    point; the execution future is spawned inside the service, `unawaited()` with a caught-and-logged handler
    (`_executeWithRetry` consumes per-attempt errors and never rethrows). Reuses the `_running` guard and
    `_executeWithRetry` (configured delivery, retries, consolidator, failure alert); executes even when paused;
    never calls `_reschedule` or touches `_timers` – a pending `once` job's timer therefore still fires later
    (manual runs never consume or cancel the one-time fire; the double execution is accepted parity; OC04 caveat:
    a `once` fire landing during the in-flight window is skipped and lost). Prompt-type jobs are runnable
    regardless of origin – user-defined or built-in (e.g. `memory-journal`; owner decision 2026-08-05):
    `onExecute != null` callback jobs (built-in system callback jobs, `auto-task-*` scheduled-task jobs – see
    Non-Goals) resolve to notFound, as does a not-started service (`stop()` clears `_running`; without the
    gate a post-stop run could overlap a draining execution).
    `executeJobForTesting` stays as-is (different semantics: pause skip + reschedule).
  - **Verify**: `schedule_service_test.dart` with `RecordingDeliveryService` proves: manual run delivers with mode
    `announce` (S01); result is alreadyRunning while a run is in flight and only one execution occurs, including
    two `runJobNow` calls dispatched in the same event-loop turn → one started + one alreadyRunning (S04); a
    timer fire landing during an in-flight manual run is skipped by the `_running` guard and the schedule
    continues (S04/OC04); a paused job executes and stays paused with no timer entry afterwards (S06); an
    interval job's pending timer is unchanged by a manual run; a pending `once` job's timer is untouched by a
    manual run; unknown id, an `auto-task-*` id, a built-in *callback* job id (e.g. the memory pruner's), and a
    stopped service → notFound; a prompt-type built-in job id (memory-journal-shaped: `prompt` set,
    `onExecute` null) → started with its configured delivery; a job failing all `retry.attempts` fires
    `ScheduledJobFailedEvent` and never calls `deliver` (S07); existing cases in the suite are unmodified.

- [x] **TI02** `POST /api/scheduling/jobs/<name>/run` is served by the live-control router
  - In `config_routes.dart`, next to the toggle route; decode the `<name>` segment as the CRUD router does –
    `_decodePathSegment` is library-private to `config_api_routes.dart`, so duplicate the small helper locally
    (do not move the run route into the CRUD router); the UI's `encodeURIComponent` fetch depends on it; the
    toggle route's missing decode is a pre-existing gap, out of scope. Maps TI01's synchronously returned result
    to `202` `{"name": <name>, "status": "started"}` / `409` `CONFLICT` / `404` `NOT_FOUND` (message: job not
    present in the running scheduler or not runnable on demand – newly created/edited jobs need a restart;
    otherwise check server logs; same message for unknown names and TI01-excluded internal ids, which are present
    internally but never runnable); `404` `NOT_AVAILABLE` when `scheduleService` is null (toggle parity). The
    handler never awaits job completion (execution runs in the background inside the service, TI01).
  - **Verify**: `config_routes_test.dart` via `ApiRouteTestClient` asserts all four contracts – `202` with body
    `{"name": "daily-summary", "status": "started"}`, `409` `CONFLICT`, `404` `NOT_FOUND` with restart-hint
    message, `404` `NOT_AVAILABLE` – against the mounted router, plus a job whose name contains a space runs via
    its URL-encoded path; `rg` confirms no `/api/scheduling` entry was added to any auth public-path allowlist;
    existing cases in the suite are unmodified.

- [x] **TI03** `dartclaw jobs run <name>` triggers the route from the CLI
  - New `JobsRunCommand extends ConnectedCommand` in `apps/dartclaw_cli/lib/src/commands/jobs/`, registered in
    `JobsCommand`; encode the name with `Uri.encodeComponent` before `postObject('/api/scheduling/jobs/$encodedName/run')`; `--json` flag. Human output names the original job,
    states it started, and points at the configured delivery (if any) and server logs for the outcome. `409`
    flows through `runConnected`'s existing printed-message + exit 1 path; for `404`,
    `DartclawApiClient._exceptionForResponse` currently discards the server envelope message in favor of a
    generic "CLI and server versions may be out of sync" hint – amend that branch to prefer the envelope message
    when present (generic hint as fallback) so the S05 restart hint reaches the operator.
  - **Verify**: `jobs_commands_test.dart` follows the sibling pattern – the `JobsCommand().subcommands`
    registration assertion includes `run`, and behavior is driven via a `CommandRunner` with a DI'd
    `JobsRunCommand` + `FakeApiTransport` (no `DartclawRunner` transport seam exists): human output contains
    `daily-summary` and `started`; `--json` prints the response JSON; a name containing a space is sent in an
    encoded path while human output retains the original name; a `404` envelope's restart-hint message is printed
    verbatim (not the out-of-sync text); missing job name triggers the positional-arg guard (S02).

- [x] **TI04** A play icon exists in the design system, canon-first
  - `.icon-play` added to `dev/design-system/icons.css` and synced verbatim into
    `packages/dartclaw_server/lib/src/static/icons.css` (style-matched to the existing Lucide-derived set).
  - **Verify**: `rg '\.icon-play'` matches in both files; the icons strict-sync fitness check passes.

- [x] **TI05** The Scheduling page offers a Run action on user job rows
  - Run button (`data-icon` play, `title`/`aria-label` "Run now") joins Edit/Delete inside the existing
    `hasActions`-gated `action-btns` cell in `scheduling.html`, and additionally renders alone on prompt-type
    SYSTEM rows. Keep the existing display-map shape: user rows are runnable by default; built-ins opt in with
    `runnable: true` (S03 adds it to `memory-journal`); callback SYSTEM rows omit it and stay action-less. The
    template derives `canRun = !isSystem || job['runnable'] == true`; no new display DTO is needed. The new
    `runJob` action in `dc_scheduling_controller.js` reads the original job name, applies
    `encodeURIComponent(jobName)` to the path segment, POSTs the TI02 route, and toasts
    success ("started") or the error envelope's message (409/404 surfaced verbatim);
    `dart run dev/tools/embed_assets.dart` re-run.
  - **Verify**: template test asserts a rendered user-job row and a prompt-type system-job row each contain
    `data-action="click->dc-scheduling#runJob"`, a callback system-job row does not, and the prompt-type system
    row has no Edit/Delete actions (S03). Add `scheduling_controller_test.dart` using the existing Node controller
    harness: invoking `runJob` for `Q&A digest` captures `/api/scheduling/jobs/Q%26A%20digest/run`, while the toast
    retains `Q&A digest`. Regenerate `embedded_assets.g.dart` in the same change.

- [x] **TI06** User docs describe on-demand runs everywhere the feature surfaces
  - `docs/guide/scheduling.md` (under Cron Jobs): running a job on demand via CLI/API/UI, parity semantics,
    paused-job behavior, busy rejection, restart-pending caveat, and the skipped-fire window (a scheduled fire
    landing during an in-flight run is skipped; for `once` jobs a skipped fire is lost – OC04). `docs/guide/cli-reference.md`: `jobs run` block matching
    sibling subcommand format. `docs/guide/web-ui-and-api.md`: endpoint block under `### Scheduling` matching the
    sibling `####` block format for `POST /api/scheduling/jobs/:name/run` (the section has no route table).
  - **Verify**: `rg 'jobs run' docs/guide/cli-reference.md`, `rg 'jobs/:name/run' docs/guide/web-ui-and-api.md`,
    and `rg -i 'on demand' docs/guide/scheduling.md` all match.

### Testing Strategy

### Validation

### Execution Contract

- TI01 precedes TI02 (route consumes the seam's result type); TI04 precedes TI05 (button references the icon).

## Final Validation Checklist

## Implementation Observations

### Run: 2026-08-08 21:35 UTC – observations

#### NOTICED BUT NOT TOUCHING

- S03 owns creation of the `memory-journal` production display row; that row must include `runnable: true` to opt
  into S04's tested prompt-type SYSTEM Run action contract.
