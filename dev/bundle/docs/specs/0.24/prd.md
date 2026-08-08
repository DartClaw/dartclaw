# PRD – 0.24

> Thin milestone PRD. All four features are **already fully specced** – each story's authoritative spec is its existing FIS in this directory (adopt via `stories[].fis`; do **not** regenerate). This document exists to give the plan bundle its source anchors, ordering, and binding constraints. Execution repo: `dartclaw-public`; milestone branch `feat/0.24`, after 0.23 ships (`feat/0.23` is scope-frozen release prep). Authored 2026-08-05.

## Problem & Goal

0.24 bundles four accepted items: two security/correctness defect fixes on the sub-agent delegation path (tool sandbox is prompt-level fiction; persona/model config is unapplied and delegation is unreachable while the caller's turn is active), and two operability features from field feedback (a built-in opt-in memory journal job; on-demand execution of scheduled jobs via CLI/API/Web UI).

## Features (one story each; FIS is authoritative)

### F1 – Agent tool policy enforcement on the live tool-call path
- FIS: `s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md` (doc review report alongside)
- Outcome summary: per-agent tool whitelist enforced on every active host guard path (unconditional on Claude; approval-routed on Codex/ACP as documented in the FIS); per-agent network domain grants honored; unenforced spawn-config fields retired; docs honest.
- Key surfaces: `dartclaw_security`, `dartclaw_core` (incl. `AgentHarness.turn` +`agentId` and the ~23-file implementer/fake sweep), `dartclaw_models`, `dartclaw_server`, `dartclaw_cli`, docs.

### F2 – Agent persona and model application on the delegation dispatch path
- FIS: `s02-agent-persona-and-model-application-on-the-delegation-dispatch-path.md` (doc review report alongside; preflight decisions resolved 2026-08-06)
- Outcome summary: delegated turns run under the definition's persona prompt and model/effort (Claude/Codex; ACP persona-only); delegation is reachable via pool-worker routing with spawn-on-demand; fresh onboarding reaches every human-facing conversational channel through the same scoped-prompt contract; no leakage into automated, delegated, or ordinary post-onboarding turns.
- **Depends on F1** (same `AgentHarness.turn` interface, same dispatch closure in `harness_wiring.dart`; FIS Execution Contract mandates executing after F1 lands and re-resolving anchors).

### F3 – Built-in memory journal job (`memory.journal`)
- FIS: `s03-built-in-memory-journal-job-memoryjournal.md`
- Outcome summary: `memory.journal.enabled: true` suffices for MEMORY.md to accumulate curated entries from daily turn logs through an exact read-plus-`memory_save` tool boundary; default off; journal/consolidation/pruning distinctly named.
- **Depends on F1** (F1 defines and enforces the exact own-MCP `memory_save` identity used by the journal's closed tool policy).
- Key surfaces: `dartclaw_config`, `dartclaw_server` (prompt constant, config serializer, `ScheduledJob.allowedTools`, `ScheduleService` forwarding), `dartclaw_cli` (`scheduling_wiring.dart`), docs, `examples/personal-assistant.yaml`.

### F4 – Run scheduled jobs on demand (CLI + API + Web UI)
- FIS: `s04-run-scheduled-jobs-on-demand-cli-api-web-ui.md`
- Outcome summary: `dartclaw jobs run <name>` / `POST /api/scheduling/jobs/<name>/run` / Web UI Run button execute a configured job immediately with exact scheduled-fire parity; schedule state untouched.
- Key surfaces: `dartclaw_server` (`schedule_service.dart`, `config_routes.dart`, templates/controllers/embedded assets), `dartclaw_cli` (`commands/jobs/`), design-system icons, docs.

## Ordering & Parallelism

- **F2 dependsOn F1** – hard dependency (shared interface + files); never parallel.
- **F3 dependsOn F1 and F4** – F3 consumes F1's exact own-MCP `memory_save` mapping and live guard seam, then opts the journal into F4's generic on-demand seam and UI predicate.
- **F1 and F4 are wave-1 parallel candidates** – their production-code inventories are disjoint.
- **F2 and F3 are wave-2 parallel candidates after F1 and F4** – their production-code inventories are disjoint; both may edit `docs/guide/search.md`, so merge in story order and resolve that documentation overlap semantically. F1 and F3 may also both touch `dartclaw_server` barrel/sub-barrel exports (low risk).

## Binding Constraints

1. Execute on the 0.24 milestone branch, after 0.23 ships – `feat/0.23` is scope-frozen (recorded in F3/F4 FISes and the F1/F2 target notes).
2. The canonical, preflight-reconciled FIS files in this directory are the authoritative story specs – the plan references them via `stories[].fis`; do not regenerate them.
3. F2 executes only after F1 lands; F2's executor must re-resolve all code anchors against the then-current tree (F2 FIS Execution Contract).
4. F3 executes only after F1 and F4 land because it consumes F1's exact own-MCP `memory_save` semantic mapping and live guard seam, then opts the journal into F4's generic on-demand seam and UI predicate.
5. Milestone preflight completed 2026-08-06: delegated lifecycle, provider defaults, Codex and ACP persona transport, pool provisioning, cross-channel onboarding, journal tool boundary, reserved-ID collision, and live-proof requirements are settled in the FIS decision notes.
6. Per-milestone transient copy: on execution, specs copy to `dartclaw-public/dev/bundle/docs/specs/0.24/` per `SPEC-LIFECYCLE.md`; this private directory stays canonical.
7. Before public execution, rewrite only the four exported FIS `**Plan**:` headers from `docs/specs/0.24/plan.json` to `dev/bundle/docs/specs/0.24/plan.json`; leave the canonical private headers unchanged. Gate execution on the exported `plan.json` existing, all four exported canonical FISes carrying the public path, and no exported canonical FIS retaining the private path. This exact post-export rewrite is required because the exporter preserves content verbatim.
