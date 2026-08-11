# Feature Implementation Specification: Operator-Visible Memory Lifecycle

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S11

## Feature Overview and Goal

**Intent**: Let operators understand what DartClaw remembers, what is merely observed or derived, and what action is safe when curation, indexing, or recovery is incomplete.

**Expected Outcomes**:

- [OC01] Existing Memory, Knowledge, status, API, CLI, and job surfaces distinguish canonical roles and derived chunks without presenting observations or search rows as curated truth.
- [OC02] Operators see the current collection revision, prompt-index usage, raw-observation usage and coverage, index health, and last successful reconciliation without fabricated zero or complete states.
- [OC03] Operators can start explicit curation through the existing run-now path and inspect truthful running, succeeded, conflicted, or failed results, including committed-but-index-degraded success.
- [OC04] Empty, degraded, rebuilding, conflicted, failed, and successful states remain actionable, accessible, responsive, and visually coherent with the existing design system.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.10` – exact S11 scope, dependencies, risk, existing-surface boundary, and visual-state obligation.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` – canonical roles, one revision authority, observation trust, fixed ceilings, stopped-edit reconciliation, fresh prompt context, immutable host system actions, and release simplicity shared across the bundle.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints` – file authority, shared mutation authority, explicit-only curation, bounded prompt, backend-owned query handling, fixed traversal limits, no new administration infrastructure, and settled threat model.
- `dev/bundle/docs/specs/0.24/prd.md#user-stories` – truthful health, deterministic recovery, bounded context, explicit curation, and role separation outcomes.
- `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` – canonical role and provenance distinctions the presentation must preserve.
- `dev/bundle/docs/specs/0.24/prd.md#fr2-guarded-memory-tools` – canonical-success/index-degraded outcome and current-revision contract.
- `dev/bundle/docs/specs/0.24/prd.md#fr3-on-demand-semantic-curation` – explicit curation lifecycle and whole-proposal result semantics.
- `dev/bundle/docs/specs/0.24/prd.md#fr4-bounded-turn-context` – 150-line and `memory.max_bytes` prompt-index budgets and degraded prompt state.
- `dev/bundle/docs/specs/0.24/prd.md#fr5-retrieval-citation-and-index-integrity` – role-discriminated results, stable locators, derived-index health, and no false zero counts.
- `dev/bundle/docs/specs/0.24/prd.md#fr6-maintenance-limits-and-recovery` – fixed file/traversal/result/warning ceilings and exact-versus-incomplete observation coverage.
- `dev/bundle/docs/specs/0.24/prd.md#fr7-operator-control-and-observability` – authoritative fields, lifecycle states, recovery guidance, and empty/degraded/zero-result distinctions for this story.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – prohibits a new package, database, daemon, scheduler, approval framework, admin system, or QMD responsibility.
- `dev/bundle/docs/specs/0.24/prd.md#edge-cases` – observation growth, corrupt/deleted index, stopped edits, malformed curation, and forget behavior to present truthfully.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – trusted host plus plausible crash, cooperating concurrency, untrusted semantic content, and normal resource limits.
- `dev/bundle/docs/specs/0.24/s03-lossless-memory-migration.md#architecture-decision` – migration status, per-role counts, opaque-legacy locators, retained pre-migration snapshot location, stage, and next action that this story renders.
- `dev/bundle/docs/specs/0.24/s06-fresh-bounded-turn-context.md#architecture-decision` – current dual-capped prompt-index projection and collection revision source.
- `dev/bundle/docs/specs/0.24/s07-search-and-citation-convergence.md#architecture-decision` – canonical result roles, locators, provenance, per-layer degradation, and single-owner composition.
- `dev/bundle/docs/specs/0.24/s08-index-health-and-recovery.md#architecture-decision` – exact healthy/degraded/rebuilding/unknown semantics and persisted recovery action.
- `dev/bundle/docs/specs/0.24/s09-on-demand-memory-curation.md#architecture-decision` – ScheduleService host-callback system-action seam, shared overlap, a descriptor that is read-only through every scheduling configuration surface and merged into list/show while run-now executes the curation callback, persisted four-state lifecycle, bounded results, and single commit authority.
- `dev/bundle/docs/specs/0.24/s10-memory-resource-boundaries.md#fixed-resource-contract` – inclusive 64 MiB, 8 MiB, 1,000-file, 50-result, and observation-warning contracts.
- `dev/design-system/DESIGN.md#status-indicators` – canonical state vocabulary, semantic color, motion, and text-cue rules.
- `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md#viewports` – required 1280 px desktop and 375 px mobile validation.
- `dev/guidelines/TESTING-STRATEGY.md#test-layers` – lowest-effective-layer API, template, integration, and visual proof expectations.

## Deeper Context

- `dev/architecture/cli-api-architecture.md#connected-mode` – connected job commands use the server-owned runtime state rather than a CLI side channel.
- `dev/architecture/cli-api-architecture.md#9-local-only-commands` – offline `rebuild-index` remains available when the server cannot provide live status.
- `dev/architecture/observability-operations-architecture.md#3-health-monitoring` – existing health vocabulary and operator-facing status seam.
- `dev/architecture/observability-operations-architecture.md#11-heartbeat--scheduling` – current job/run-now lifecycle and overlap behavior.
- `dev/guidelines/HTMX-GUIDELINES.md#recommended-patterns` – server-rendered fragment polling and Stimulus ownership boundaries.
- `dev/guidelines/TRELLIS-GUIDELINES.md#security--the-rules-that-matter-most` – escaped dynamic state/reason/action rendering.

## Acceptance Scenarios

- [ ] **S01 [OC01,OC02,OC04] [TI01,TI02,TI03,TI06] A healthy non-empty corpus exposes canonical roles, revision, budgets, and derived state without conflation**
  - **Given** collection revision `42` has 12 curated entries across 3 topics, 4 archived entries, 7 observations, 2 learnings, 5 wiki sources, and 28 derived chunks, and the knowledge layer additionally holds 3 knowledge-graph facts and 1 knowledge-inbox item; prompt rendering uses 101 of 150 lines and 20 KiB of its 32 KiB budget
  - **When** the status API, Memory dashboard, and Knowledge Hub render the current state
  - **Then** curated entries, topics, archive, observations, learnings, wiki sources, and derived chunks have distinct labels and counts; revision `42` and both prompt budgets are visible; derived chunks are labelled as rebuildable index data rather than memory
  - **And** each Knowledge result uses its S07 canonical role and locator, so curated, archive, observation, and learning results carry distinct labels and none inherits the curated-memory label, while the wiki, KG, and inbox results keep their own labels and native source provenance and locators
  - **Proof**: `packages/dartclaw_server/test/memory/memory_status_service_test.dart#getStatus returns complete status with all files present` – green – parity/regression for the existing status aggregation seam

- [ ] **S02 [OC01,OC02,OC04] [TI01,TI02,TI03,TI06] Valid empty, zero-result, and unavailable states remain different**
  - **Given** one fixture is a validated empty canonical union with a healthy empty index, another is a healthy non-empty corpus whose query has no matches, and a third cannot establish collection or count evidence
  - **When** API, Memory, and Knowledge surfaces present each fixture
  - **Then** the first shows a canonical empty-state explanation with exact zero counts, the second shows `No results` without saying memory is empty, and the third shows `unknown` or degraded coverage with nullable counts, reason, and safe action rather than zeros or healthy state
  - **Proof**: `packages/dartclaw_server/test/templates/knowledge_surfaces_test.dart#knowledge hub empty state` – green – parity/regression for distinct layer and query empty states

- [ ] **S03 [OC02,OC04] [TI01,TI02,TI06] Observation usage is exact only when complete and warns without deleting**
  - **Given** bounded status scans whose known observation usage is 64 MiB minus one with complete coverage, exactly 64 MiB with complete coverage, below 64 MiB with work omitted after the 1,000-file or 64 MiB request ceiling, and at or above 64 MiB with work omitted
  - **When** status is serialized and rendered
  - **Then** complete coverage reports an exact byte total and `warning` `none` below the threshold, exact known usage at the threshold reports `warning` `active`, and incomplete coverage reports a lower bound with scanned/omitted/failed files plus known oldest/newest times
  - **And** an incomplete lower bound below the warning threshold reports `warning` `unknown` rather than `none`, an incomplete lower bound at or above the threshold reports `warning` `active` because the bound alone already proves the threshold is met, no state claims full coverage, and no status action deletes or rewrites observations

- [ ] **S04 [OC02,OC03,OC04] [TI01,TI02,TI05,TI06] A committed memory change with failed indexing is successful but visibly degraded**
  - **Given** revision `42` commits durably and its derived-index reconciliation fails after canonical replacement
  - **When** the tool response, persisted status API, Memory dashboard, and later `dartclaw status` CLI inspection are observed
  - **Then** each names canonical revision `42` as committed, index state as `degraded`, the failing stage and bounded reason, and the offline repair action; none rolls back the memory, calls the change failed, or reports search healthy
  - **And** repair guidance says DartClaw must be stopped before `dartclaw rebuild-index`, whose success output includes reconciled revision, indexed-row outcome, and resulting health

- [ ] **S05 [OC02,OC04] [TI01,TI02,TI05,TI06] Active reconciliation is rebuilding and stopped-edit recovery cannot appear healthy early**
  - **Given** a supported stopped-runtime edit has advanced the canonical revision and reconciliation is blocked after fresh-sibling population but before validation and swap
  - **When** Memory/API status is read during the barrier and again after successful settlement
  - **Then** the first view shows `rebuilding`, current canonical revision, last validated index revision/time, and working text without labelling the old index current; the second becomes healthy only after complete parity validation
  - **And** a failed or interrupted attempt settles degraded or unknown with recovery guidance rather than remaining falsely rebuilding

- [ ] **S06 [OC03,OC04] [TI01,TI02,TI04,TI06] Existing run-now surfaces show curation running and durable success**
  - **Given** S09 has validated collision-free configured and reserved action IDs, API/CLI/Web list/show merge configured jobs with the immutable `memory-curation` system action, and no curation has run
  - **When** an operator starts it from the Memory dashboard, Scheduling page, or `dartclaw jobs run memory-curation`, and the one S09 proposal turn later commits changed IDs A and B plus exact-no-op ID C at revision `43`
  - **Then** all triggers call the same existing run endpoint, a concurrent start returns already running, status changes from no prior run to `running` and then `succeeded`, and terminal API/CLI/Web output shows committed revision `43`, A/B, C, last-success time, and index health joined live from S08 rather than stored in the curation record
  - **And** among the curation lifecycle states `running` is the only pulsing one – index `rebuilding` keeps the same live working treatment in its own index region; succeeded is static success, the action is disabled only while its own run is active, and no edit/delete/toggle control, YAML representation, schedule, timer, or automatic retry is created
  - **And** a colliding startup job or config create/edit request is rejected before any duplicate row, show result, or run target appears; the UI and CLI never choose or imply a precedence winner
  - **Proof**: `apps/dartclaw_cli/test/commands/jobs/jobs_commands_test.dart#run starts a job and prints observation guidance` – green – parity/regression for the connected job run command and endpoint

- [ ] **S07 [OC03,OC04] [TI01,TI02,TI04,TI06] Conflict and failure are actionable terminal no-effect states**
  - **Given** one curation proposal conflicts with current revision `52`, and another is rejected with per-operation validation reasons before apply
  - **When** the job, status API, Memory dashboard, Scheduling page, and jobs CLI present the results
  - **Then** the conflict is `conflicted` with current revision `52`, empty changed/no-op IDs, and explicit rerun guidance; the rejection is `failed` with empty changed/no-op IDs and bounded operation reasons
  - **And** conflicted uses the canonical attention treatment plus text, failed uses static error, neither implies partial success, and untrusted model content is never rendered or printed as raw HTML/control text

- [ ] **S08 [OC01,OC02] [TI01,TI02,TI05] Migration outcome is presented with its snapshot and opaque residue rather than as silent success**
  - **Given** one fixture where S03 has migrated a legacy workspace, retaining its no-clobber pre-migration snapshot and copying 3 opaque legacy sources verbatim under `memory/legacy/`, and another fixture whose workspace never required migration
  - **When** the status API, Memory dashboard, and local `dartclaw status` present the `collection` object
  - **Then** the first shows S03's reported migration state, the retained snapshot location, the opaque-legacy count with its locators, and S03's next action; opaque bytes are never rendered inline, never counted as curated entries, and never presented as a canonical role
  - **And** the second reports migration as not applicable rather than a failed, zero-progress, or absent-evidence run, and no surface offers to rerun, restore, or delete the snapshot – S03's stated manual action is the only path

## Structural Criteria

- [ ] `GET /api/memory/status` is the single machine-readable operator projection; Memory, job, and connected CLI presentations consume the same S06–S10 state rather than rescanning canonical/wiki files or deriving health independently. Local-only `dartclaw status` runs with the server stopped, so it reads the persisted S02 collection metadata and S08 health record directly instead of the API, and is equally forbidden from rescanning canonical/wiki files or computing its own health verdict.
- [ ] Status numeric fields are nullable when unavailable; zero is emitted only when complete evidence proves zero. Observation usage explicitly distinguishes `exact`, `lowerBound`, and `unknown`, and `warning` carries the same explicitness with `none` (evidence proves the threshold is not met), `active` (an exact total or a lower bound has reached the threshold), and `unknown` (a lower bound below the threshold decides nothing) – never a bare boolean. The same evidence discipline governs whole objects, not only numbers: an object is omitted only when its absence is proven, never when reading its record failed.
- [ ] Curation has no invented idle lifecycle state: before the first run its result is absent; once started, its state is exactly `running`, `succeeded`, `conflicted`, or `failed` as supplied by S09. An unreadable or corrupt S09 record is therefore presented as unknown curation evidence with its reason and safe action – never as never-ran and never as a fabricated terminal state.
- [ ] API, CLI, Scheduling, and Memory presentations read S09's same merged system-action descriptor and persisted lifecycle; S11 adds no action registry, lifecycle store, run endpoint, or inferred terminal state.
- [ ] Presentations receive only S09's collision-free projection. A reserved-ID startup/config mutation failure uses existing validation/error surfaces and never renders, lists, shows, or runs an ambiguous entry or compatibility alias.
- [ ] Operator reasons and actions are bounded host-classified text. Web output uses escaped Trellis text/attributes; CLI output applies its existing terminal-text safety before printing any model-derived reason.
- [ ] Existing Memory, Knowledge, Scheduling, jobs, status API, and offline rebuild surfaces remain the complete administration surface; no page family, command family, SSE stream, store, database, package, daemon, scheduler, or QMD-specific health path is added.
- [ ] Status presentation uses canonical components/tokens, never color alone: `live` means active work, `attention` means operator action required, `success` and `error` are terminal, `warning` is degraded/unknown, and `idle` is neutral absence.

## Scope & Boundaries

### Work Areas

- `MemoryStatusService` and `GET /api/memory/status` operator projection over prerequisite corpus, prompt, observation, curation, migration, and index state
- Existing Memory dashboard page, Trellis template, 30-second HTMX fragment, file reader, and Stimulus actions
- Existing Knowledge Hub result role/provenance badges, layer failure/empty states, and source labels
- Existing Scheduling system-job row plus `/api/scheduling/jobs/*` list/show/run contracts for `memory-curation`
- Existing jobs CLI, the existing local-only `dartclaw status` command extended with memory corpus and index-health lines, and offline `rebuild-index` output/recovery guidance
- Service, route, template, controller, CLI, accessibility, and visual-state verification

### What We're NOT Doing

- Adding a memory admin page, a `memory` CLI command family, a curation endpoint, or another lifecycle store – reuse the current Memory/Scheduling/jobs/status seams.
- Changing canonical role, mutation, prompt selection, curation, index recovery, or resource-limit semantics – S06–S10 are authoritative producers.
- Adding online index repair or exposing generic file editing/deletion controls – repair remains the stopped-runtime rebuild path and manual Markdown changes remain a stopped-runtime operation.
- Adding automatic curation, raw-observation retention/deletion, approval workflows, or autonomous stewardship – those remain 0.27 product decisions.
- Giving QMD new status, repair, locator, or lifecycle meaning – it remains transitional under the settled release boundary.

## Architecture Decision

**Approach**: Extend the existing memory status projection with typed snapshots from S06–S10, and expose S09's merged read-only system-action descriptor plus persisted lifecycle through the current Memory, Knowledge, Scheduling, API, jobs CLI, and rebuild surfaces.
**Why this over alternatives**: A separate admin service or live-stream protocol would duplicate state and operations; the existing 30-second status poll and connected job endpoint already provide sufficient control and freshness.

## Technical Overview

`GET /api/memory/status` exposes five cohesive objects, with absent evidence represented by null rather than zero:

- `collection`: `revision`, curated/topic/archive/learning counts, opaque-legacy count, and S03 migration state/backup/action. Learnings are a canonical role in the 0.24 model, so their count belongs to this canonical object rather than to a native-source tally alongside wiki.
- `promptIndex`: `usedBytes`, `budgetBytes`, `usedLines`, `lineBudget`, `omittedEntries`, `truncated`, and degraded reason. `MemoryStatusService` obtains them by asking S06's bounded renderer for a fresh projection over the current S02 snapshot – the same producer a turn uses – never by rescanning canonical sources or re-measuring a cached prompt block.
- `observations`: entry count, `usageBytes`, `usageKind` (`exact|lowerBound|unknown`), scanned/omitted/failed files, oldest/newest time, `warningAtBytes`, and `warning` (`none|active|unknown`).
- `index`: `state` (`healthy|degraded|rebuilding|unknown`), canonical/indexed revisions, nullable `derivedChunkCount` and `wikiSourceCount` – null whenever the derived index cannot supply them, never zero – last reconciliation, failure stage/reason, and repair action. Wiki sources are native rather than canonical, so their count belongs here beside the derived rows instead of in `collection`.
- `curation`: absent before first run; otherwise S09 state, start/completion/last-success time, snapshot/committed/current revisions, bounded changed/no-op IDs and operation reasons, and repair/rerun action. The record holds no index health of its own; the independent index state shown beside a curation result is joined at read time from the live `index` object above.

The Memory dashboard uses the polled projection for roles, budgets, lifecycle, and recovery while keeping file tabs outside the poll. Knowledge continues to own search-result presentation and adds the prerequisite role label without exposing derived chunk identity. After S09 reserved-ID validation succeeds, Scheduling list/show, jobs CLI list/show, and Web rows merge the immutable system-action descriptor with configured jobs; their existing run endpoint invokes it, while create/edit/delete/toggle and YAML remain configured-job-only. Startup and config create/edit collisions fail on existing error surfaces before an ambiguous row/result/target exists. The offline rebuild command remains the last-resort repair path.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_server/lib/src/memory/memory_status_service.dart#MemoryStatusService.getStatus | Existing fresh status aggregator and current false-zero paths to replace with prerequisite typed state
file | packages/dartclaw_server/lib/src/api/memory_routes.dart#memoryRoutes | Existing status/file/prune API family; no new administration router
file | packages/dartclaw_server/lib/src/templates/memory_dashboard.dart#memoryDashboardTemplate | Existing render-context seam and 30-second fragment model
file | packages/dartclaw_server/lib/src/templates/memory_dashboard.html#memoryDashboard | Existing Memory layout, metrics, status, file tabs, and action cards
file | packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js#DcMemoryController | Existing Stimulus action and post-HTMX-swap lifecycle
file | packages/dartclaw_server/lib/src/knowledge/knowledge_hub_service.dart#KnowledgeHubItem | S07 result role, locator, and provenance flow into presentation
file | packages/dartclaw_server/lib/src/templates/knowledge_hub.dart#KnowledgeHubItemView | Existing result badge/source view model
file | packages/dartclaw_server/lib/src/templates/knowledge_hub.html#knowledgeHub | Existing layer, partial-failure, result, and empty-state presentation
file | packages/dartclaw_server/lib/src/templates/scheduling.dart#schedulingTemplate | Existing system-job row and runnable action presentation
file | packages/dartclaw_server/lib/src/scheduling/schedule_service.dart#ScheduleService.runJobNow | S09 overlap-safe run-now plus merged immutable system-action descriptor/lifecycle authority
file | packages/dartclaw_server/lib/src/api/config_routes.dart#configRoutes | Existing job run endpoint and immediate started/conflict/not-found outcomes
file | packages/dartclaw_server/lib/src/api/config_api_routes.dart#configApiRoutes | Existing job list/show API projection consumed by connected CLI inspection
file | apps/dartclaw_cli/lib/src/commands/wiring/scheduling_wiring.dart#SchedulingWiring | Existing built-in system-job registration and presentation composition
file | apps/dartclaw_cli/lib/src/commands/jobs/jobs_run_command.dart#JobsRunCommand | Existing connected curation trigger and human/JSON output seam
file | apps/dartclaw_cli/lib/src/commands/jobs/jobs_show_command.dart#JobsShowCommand | Existing connected lifecycle inspection seam
file | apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand | S08 offline repair result and stopped-runtime guidance – the repair action the new `dartclaw status` index-health line points to
file | apps/dartclaw_cli/lib/src/commands/status_command.dart#StatusCommand | Existing local-only status output (data dir, sessions, harness lines) to extend with memory corpus and index-health lines
test | apps/dartclaw_cli/test/commands/status_command_test.dart#existing data directory prints session count and worker status line | Green local status output fixture to preserve while adding memory lines
```

## Constraints & Gotchas

- **Critical – health stays independent**: Curation may be `succeeded` while index state is `degraded`; never collapse them into one badge and never let derived failure negate canonical success. The curation record carries no index health of its own – S08 is its sole durable owner – so every surface joins the live S08 state at read time instead of rendering a health value frozen into a settled curation result.
- **Critical – incomplete is a lower bound**: Observation `usageBytes` and entry count are exact only with `usageKind=exact`; partial traversal preserves known values and nullable warning semantics.
- **Critical – no false zero**: Missing files in a validated complete corpus may yield zero. Read/count/coverage failure yields null plus unknown/degraded evidence.
- **Critical – no hidden status scan**: Reuse S06–S10 snapshots/status sources. Presentation code must not independently recurse through topics, observations, wiki, or index rows.
- **Avoid – lifecycle invention**: `memory-curation` is an on-demand system action, not a persisted user job; list/show/run may present it, but create/edit/delete/schedule controls must not.
- **Critical – no ambiguous presentation**: registered action IDs are reserved upstream. Do not present both colliding entries, choose one by precedence, rename either, or add compatibility copy; surface S09's validation failure and retain the prior valid live view after rejected config mutation.
- **Avoid – unsafe rendering**: Reasons, locators, file paths, and operation summaries may contain untrusted semantic text. Use `tl:text`/`tl:attr`, bounded CLI rendering, and no `tl:utext` or raw `innerHTML` for them.
- **UI state semantics**: Running/rebuilding use live working treatment; conflicted uses attention with text; degraded/unknown use static warning; succeeded/healthy use static success; failed uses static error; never pulse a terminal state.
- **HTMX state**: Polling may replace `#memory-inner` only. File-preview tabs and their scroll/loaded state stay outside the swap, while the Stimulus controller rebinds curation controls after replacement.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** One truthful operator status contract covers the complete memory lifecycle
  - Compose S03 and S06–S10 results in `MemoryStatusService.getStatus`; serialize the five Technical Overview objects through `GET /api/memory/status`, preserving nullable evidence, exact/lower-bound coverage, independent health, and bounded reasons/actions.
  - **Verify**: Service and route matrices prove S01–S08 for complete/empty/unknown corpus, prompt truncation, observation warning-minus-one/exact/partial-below/partial-at-or-above, all four index states, absent plus all four curation states plus an unreadable/corrupt curation record reported as unknown rather than never-ran, migration state with snapshot and opaque residue, and restart persistence without false zeros.

- [ ] **TI02** The Memory dashboard explains corpus roles, budgets, lifecycle, and recovery
  - Extend the existing polled status region and current component vocabulary; keep file previews static, route Curate now through the existing job run endpoint, and show revision, prompt dual-budget use, observation lower bounds, last successes, bounded results, and repair/rerun actions.
  - **Verify**: Render/controller/API tests prove S01–S08, including exact empty copy, at-least usage wording, nullable metrics, running-button overlap, changed/no-op IDs, conflict/no-effect copy, committed-but-degraded copy, migration snapshot/opaque-residue copy, escaped dynamic values, and stable file-tab state across polling.

- [ ] **TI03** Knowledge results preserve role and provenance instead of displaying every search row as memory
  - Consume S07 role metadata in the existing Hub item view: curated, archive, observation, learning, wiki, KG, and inbox labels remain distinct; canonical roles – learning included, since 0.24 makes learnings canonical rather than a native file source – link through canonical entry locators, wiki/KG/inbox retain their native locators, and derived chunk IDs never become visible source identity.
  - **Verify**: Hub service/template tests prove S01–S02 across each role, same-text/different-source results, native wiki attribution, layer failure versus zero results, escaped labels/locators, and unchanged read-only/filter behavior.

- [ ] **TI04** Existing Scheduling and jobs surfaces control and inspect the same curation action
  - Consume S09's merged descriptor/lifecycle contract and present `memory-curation` as a runnable, non-editable, non-scheduled system action in existing list/show/run API, Scheduling, Memory, and jobs CLI surfaces; expose persisted S09 lifecycle/result fields, curation-specific next-action copy, and index health joined from the live S08 state that TI01's `index` object exposes – never a health value read from the S09 record – without adding another endpoint, registry, store, or run authority.
  - **Verify**: API/template/CLI component tests prove S06–S07 for collision-free merged list/show/run, first run, restart-visible last result, running overlap, success, conflict, failure, JSON parity, bounded human output, explicit create/edit/delete/toggle rejection or absence, no YAML/schedule/timer/retry controls, and exactly one S09 dispatch per accepted run. Startup-YAML and config create/edit collision fixtures prove no ambiguous row/show/run target or precedence copy is rendered and rejected mutations preserve the prior valid view.

- [ ] **TI05** Recovery guidance points to the existing safe operation
  - Render S03 backup/opaque guidance and S08 state-specific reason/action consistently; keep `dartclaw rebuild-index` offline, and make its human/JSON result report canonical revision, indexed-row outcome, health, and unchanged-state failure.
  - Extend the existing `dartclaw status` command with memory corpus and index-health lines – canonical role counts, collection revision, index state, and observation usage/warning – read from the persisted S02 collection metadata and S08 health record so the lines stay truthful with the server stopped. No `memory` CLI command family is added.
  - **Verify**: Status, CLI, and template tests prove S04–S05 for deleted/corrupt/degraded index, stopped edit, failed rebuild, successful rebuild, and the explicit stop-runtime precondition without online repair, and prove S08 for migration backup/snapshot presentation, opaque content, and the not-applicable case. `dartclaw status` tests additionally prove the committed-but-degraded reading, nullable/unknown evidence, and the observation warning, and that the existing data-directory, session-count, and harness lines still render.

- [ ] **TI06** Every memory lifecycle state is accessible and visually coherent
  - Use canonical status indicators, cards, banners, empty state, meters, tables, focus behavior, and responsive shells; all state and action meaning has text and ARIA semantics independent of hue/motion.
  - **Verify**: Template/accessibility assertions plus project visual validation cover empty, running, succeeded, degraded, unknown, rebuilding, conflicted, and failed states at 1280 px and 375 px with no console errors; repeat succeeded, degraded, and conflicted semantic treatments in light theme and confirm design tokens/computed state styles, focus, disabled action, wrapping, and reduced-motion behavior.

### Testing Strategy

- [TI01,TI05] Table-drive the typed service/API state matrix. Use prerequisite service values and real temp-corpus integration fixtures where persistence matters; do not reconstruct state by mocking map keys.
- [TI02,TI03,TI04] Test rendered HTML and direct Shelf handlers at Layers 2–3, retaining existing Memory/Knowledge/Scheduling fixture builders and jobs CLI transport fakes. Dynamic content must include hostile HTML/control-text fixtures.
- [TI06] Run the project visual-validation workflow against production templates/routes with deterministic status fixtures or barriers. Capture every required state at desktop/mobile, dark as default, plus the named light-theme semantic states; inspect console and computed tokens as well as screenshots.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS mutability contract. Spec authors leave this section empty._

#### DECISION NOTE: cli-status-carrier

Decision-Key: cli-status-carrier
Altitude: fis-local
Affected surface: ## Acceptance Scenarios S04 (When leg); ## Structural Criteria (single-projection criterion); ### Work Areas (jobs CLI / rebuild bullet); ## Code Patterns & External References (rebuild_index_command row); ## Implementation Tasks TI05 (step + Verify)
Decision: Scenario S04's non-curation CLI inspection leg binds to the EXISTING `dartclaw status` command, which gains memory corpus and index-health lines: canonical role counts, collection revision, index state, and observation usage/warning. No `memory` CLI command family is added – that stays a Non-Goal. Because `dartclaw status` is a local-only command that must work with the server stopped, it reads the persisted S02 collection metadata and S08 health record directly rather than `GET /api/memory/status`; it still may not rescan canonical/wiki files or compute its own health verdict, so the single-projection criterion is scoped to connected CLI surfaces.
Rationale: PRD FR7 sanctions CLI status generally but no source named the command, leaving S04's CLI leg unbound while the FIS Work Areas listed only the jobs CLI and `rebuild-index` – neither of which can report a committed-but-degraded corpus outside a curation run. The owner ratified extending the existing status command over narrowing S04 or adding surface: `dartclaw status` already exists as a local command family, so the degradation reading survives exactly the stopped-runtime conditions S04 and S05 describe, at zero new command surface.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), S11 item 38; `dartclaw status` is classified a local process/lifecycle command in `dev/architecture/cli-api-architecture.md` and implemented at `apps/dartclaw_cli/lib/src/commands/status_command.dart` (data dir, session count, harness line only).

Old:
```
  - **When** the tool response, persisted status API, Memory dashboard, and later CLI inspection are observed
```
New:
```
  - **When** the tool response, persisted status API, Memory dashboard, and later `dartclaw status` CLI inspection are observed
```

Old:
```
- [ ] `GET /api/memory/status` is the single machine-readable operator projection; Memory, job, and CLI presentations consume the same S06–S10 state rather than rescanning canonical/wiki files or deriving health independently.
```
New:
```
- [ ] `GET /api/memory/status` is the single machine-readable operator projection; Memory, job, and connected CLI presentations consume the same S06–S10 state rather than rescanning canonical/wiki files or deriving health independently. Local-only `dartclaw status` runs with the server stopped, so it reads the persisted S02 collection metadata and S08 health record directly instead of the API, and is equally forbidden from rescanning canonical/wiki files or computing its own health verdict.
```

Old:
```
- Existing jobs CLI and offline `rebuild-index` output/recovery guidance
```
New:
```
- Existing jobs CLI, the existing local-only `dartclaw status` command extended with memory corpus and index-health lines, and offline `rebuild-index` output/recovery guidance
```

Old:
```
file | apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand | S08 offline repair result and stopped-runtime guidance
```
New:
```
file | apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand | S08 offline repair result and stopped-runtime guidance – the repair action the new `dartclaw status` index-health line points to
file | apps/dartclaw_cli/lib/src/commands/status_command.dart#StatusCommand | Existing local-only status output (data dir, sessions, harness lines) to extend with memory corpus and index-health lines
test | apps/dartclaw_cli/test/commands/status_command_test.dart#existing data directory prints session count and worker status line | Green local status output fixture to preserve while adding memory lines
```

Old:
```
  - Render S03 backup/opaque guidance and S08 state-specific reason/action consistently; keep `dartclaw rebuild-index` offline, and make its human/JSON result report canonical revision, indexed-row outcome, health, and unchanged-state failure.
  - **Verify**: Status, CLI, and template tests prove S04–S05 for migration backup, opaque content, deleted/corrupt/degraded index, stopped edit, failed rebuild, successful rebuild, and the explicit stop-runtime precondition without online repair.
```
New:
```
  - Render S03 backup/opaque guidance and S08 state-specific reason/action consistently; keep `dartclaw rebuild-index` offline, and make its human/JSON result report canonical revision, indexed-row outcome, health, and unchanged-state failure.
  - Extend the existing `dartclaw status` command with memory corpus and index-health lines – canonical role counts, collection revision, index state, and observation usage/warning – read from the persisted S02 collection metadata and S08 health record so the lines stay truthful with the server stopped. No `memory` CLI command family is added.
  - **Verify**: Status, CLI, and template tests prove S04–S05 for migration backup, opaque content, deleted/corrupt/degraded index, stopped edit, failed rebuild, successful rebuild, and the explicit stop-runtime precondition without online repair. `dartclaw status` tests additionally prove the committed-but-degraded reading, nullable/unknown evidence, and the observation warning, and that the existing data-directory, session-count, and harness lines still render.
```

#### DECISION NOTE: learnings-canonical-role

Decision-Key: learnings-canonical-role
Altitude: fis-local
Affected surface: ## Technical Overview (`collection` object bullet); ## Implementation Tasks TI03 (Hub item view step)
Decision: Runtime learnings are a CANONICAL ROLE in the 0.24 memory model, not a native-format file source. S11's operator projection therefore carries the learning count inside the `collection` object next to curated/topic/archive, and Knowledge presentation links learning results through canonical entry locators exactly like curated, archive, and observation results – never a `learnings.md` path or heading anchor. Only wiki, KG, and inbox remain native-identity sources in this story.
Rationale: Cross-cutting owner-ratified consequence of S01's learnings-canonical-role decision, which supersedes the "learnings retain their native format and identity" premise everywhere it appears. S11 never assigned learnings to either side of its own canonical-versus-native partition: scenario S01 demands a distinct learning count while the `collection` contract listed only curated/topic/archive, and TI03's blanket "source links use canonical locators" covered wiki/KG/inbox too. Left unamended, the status contract has no truthful home for the learning count and TI03 invites the file-level learning locator the ratified model forbids.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), cross-cutting decision `learnings-canonical-role` (S01 item 4, consumed by S11) and `learning-locator-shape` (S01 item 5); scenario S01's Given/Then already require learnings to carry a distinct label and count. Like the S07 note, the correction is enumerative – S11 states no native-format claim to delete.

Old:
```
- `collection`: `revision`, curated/topic/archive counts, opaque-legacy count, and S03 migration state/backup/action.
```
New:
```
- `collection`: `revision`, curated/topic/archive/learning counts, opaque-legacy count, and S03 migration state/backup/action. Learnings are a canonical role in the 0.24 model, so their count belongs to this canonical object rather than to a native-source tally alongside wiki.
```

Old:
```
  - Consume S07 role metadata in the existing Hub item view: curated, archive, observation, learning, wiki, KG, and inbox labels remain distinct; source links use canonical locators and derived chunk IDs never become visible source identity.
```
New:
```
  - Consume S07 role metadata in the existing Hub item view: curated, archive, observation, learning, wiki, KG, and inbox labels remain distinct; canonical roles – learning included, since 0.24 makes learnings canonical rather than a native file source – link through canonical entry locators, wiki/KG/inbox retain their native locators, and derived chunk IDs never become visible source identity.
```

#### DECISION NOTE: curation-record-s08-field

Decision-Key: curation-record-s08-field
Altitude: fis-local
Affected surface: ## Acceptance Scenarios S06 (Then leg); ## Technical Overview (`curation` object bullet); ## Constraints & Gotchas (health-stays-independent bullet); ## Implementation Tasks TI04 (descriptor/lifecycle step)
Decision: S09's persisted curation lifecycle record NO LONGER carries S08 index-health or recovery state. S11 therefore joins the LIVE S08 health at read time wherever a curation result is presented: the `curation` status object exposes no index-health field of its own, and API, Memory, Scheduling, and jobs CLI surfaces read health from the same `index` object TI01 already serializes. Index health and curation outcome stay independent exactly as before – only the source changes, from a curation-held copy to the live S08 record.
Rationale: Owner-ratified consequence of S09 item 34. A curation record is written once at run completion while index health keeps changing afterwards, so a health value copied into a settled record is stale by construction – an operator inspecting a week-old `succeeded` run would read `degraded` long after a rebuild fixed it, which is precisely the fabricated state OC02 forbids. S11's `curation` bullet listed "independent index state" as a record field, which would have made S11 the consumer of the dropped clause; TI04 told implementers to source curation-surface fields from the persisted S09 record, and scenario S06 asserted terminal output carries index health without naming its source.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), S09 item 34; S09's amended Structural Criterion now reads "It holds no S08 index-health or recovery state – S08 stays the sole owner of durable index health, and S11 joins live S08 health at read time rather than reading a curation-held copy", and its Technical Overview states "S08 remains the owner of durable index health". S11's own Constraints & Gotchas already required the two to stay independent.

Old:
```
  - **Then** all triggers call the same existing run endpoint, a concurrent start returns already running, status changes from no prior run to `running` and then `succeeded`, and terminal API/CLI/Web output shows committed revision `43`, A/B, C, last-success time, and independent index health
```

New:
```
  - **Then** all triggers call the same existing run endpoint, a concurrent start returns already running, status changes from no prior run to `running` and then `succeeded`, and terminal API/CLI/Web output shows committed revision `43`, A/B, C, last-success time, and index health joined live from S08 rather than stored in the curation record
```

Old:
```
- `curation`: absent before first run; otherwise S09 state, start/completion/last-success time, snapshot/committed/current revisions, bounded changed/no-op IDs and operation reasons, independent index state, and repair/rerun action.
```

New:
```
- `curation`: absent before first run; otherwise S09 state, start/completion/last-success time, snapshot/committed/current revisions, bounded changed/no-op IDs and operation reasons, and repair/rerun action. The record holds no index health of its own; the independent index state shown beside a curation result is joined at read time from the live `index` object above.
```

Old:
```
- **Critical – health stays independent**: Curation may be `succeeded` while index state is `degraded`; never collapse them into one badge or make derived failure negate canonical success.
```

New:
```
- **Critical – health stays independent**: Curation may be `succeeded` while index state is `degraded`; never collapse them into one badge and never let derived failure negate canonical success. The curation record carries no index health of its own – S08 is its sole durable owner – so every surface joins the live S08 state at read time instead of rendering a health value frozen into a settled curation result.
```

Old:
```
  - Consume S09's merged descriptor/lifecycle contract and present `memory-curation` as a runnable, non-editable, non-scheduled system action in existing list/show/run API, Scheduling, Memory, and jobs CLI surfaces; expose persisted S09 lifecycle/result fields and curation-specific next-action copy without adding another endpoint, registry, store, or run authority.
```

New:
```
  - Consume S09's merged descriptor/lifecycle contract and present `memory-curation` as a runnable, non-editable, non-scheduled system action in existing list/show/run API, Scheduling, Memory, and jobs CLI surfaces; expose persisted S09 lifecycle/result fields, curation-specific next-action copy, and index health joined from the live S08 state that TI01's `index` object exposes – never a health value read from the S09 record – without adding another endpoint, registry, store, or run authority.
```
