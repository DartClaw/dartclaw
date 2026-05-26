# DartClaw Roadmap — Current & Next

> Trimmed to the active milestone and what comes next. Full milestone history (MVP onward) and unscheduled drafts are maintained separately.

## Active Milestone

### 0.16.6 — Web UI Stimulus Adoption (Active)

Standardize the browser interaction layer on Stimulus across the Web UI while preserving HTMX + Trellis and the zero-Node toolchain. Covers shared shell behavior, page/controller migration across the main browser surfaces, legacy page-global pattern removal, and post-migration doc/spec synchronization.

## Planned

### 0.17 — Personal AI & Developer Experience (Planned)

Structured `USER.md` identity context, conversational onboarding bootstrapping, inbox-drop knowledge ingestion, LLM-maintained knowledge wiki, temporal knowledge graph (SQLite-based structured facts with time-validity), guard config editor, SDK docs Phase 2, chat input redesign (composable input, slash command palette, file attachments, @-mention context references), interrupted-turn retry UX, automated kill/restart crash-recovery validation.

Backlog migrations from 0.16.5 close-out triage:
- TD-020: Reply-to-bot gating with GOWA v8 `replied_to_id` tracking.
- TD-035: Validate and re-enable phone-number pairing alternatives when channel flows are proven.
- TD-037: NDJSON message compaction or tail-window loading for long-lived sessions.
- TD-040: Live turn crash retry UX for SSE sessions.
- TD-043: Merge-conflict artifact format and task-detail resolution UX.
- TD-046: Kill/restart crash-recovery integration validation.
- TD-076: Gate-expression parser to replace regex-based gate parsing.
- TD-079: Output-contract inference from `outputs:` declarations.
- TD-080: Agent-resolved-merge v2 cluster: pause escalation, conflict review UI, default-on rollout.
- TD-084: Foreach/map empty-collection policy (`onEmpty`) for misconfigured upstream outputs.

### 0.18 — Provider Harness Expansion (Planned)

Provider-runtime expansion beyond the current Claude/Codex families, including per-provider pool structure and queueing semantics needed when a third built-in provider is introduced.

Backlog migrations from 0.16.5 close-out triage:
- TD-068: Replace the shared mixed-provider `HarnessPool` with provider-scoped pools before adding the third built-in provider.

## Recently Shipped

### 0.16.5 — Stabilisation & Hardening ✅

Consolidation sprint with zero new user-facing features. Closes the alert-classifier safety gap (`LoopDetectedEvent` + `EmergencyStopEvent` now critical via compiler-enforced exhaustive switch over `sealed DartclawEvent`), wires all 7 orphan sealed events to SSE + alerts, narrows the `dartclaw_workflow` barrel to ≤35 explicit `show` clauses, installs 13 governance fitness checks in CI (7 Level-1 + 6 Level-2), flips `public_member_api_docs` lint on in `dartclaw_models/_storage/_security/_config`, extracts `WorkflowRunRepository` / `WorkflowTaskBindingCoordinator` / `ProcessEnvironmentPlan` / `ClaudeSettingsBuilder` to their canonical packages, shrinks `dartclaw_models` to a true shared kernel (workflow / project / task-event / turn-trace / skill-info migrated to owning packages; `TaskEventKind` enum-ified), types four stringly-typed workflow flags as enums, renames `k`-prefix constants and `get*` service methods per Effective Dart, formalises ADR-023 (workflow↔task boundary) + ADR-025 (AndThen-as-runtime-prerequisite + direct skill-name resolution), refreshes `AGENTS.md` and the user guide, and bundles 13 tech-debt closures (TD-046/053/054/055/056/060/061/063/072/073/074/082/085/088/102/103) plus three explicit triage decisions. 24 catalogued stories + standalone work for workflow output presets shorthand, `aggregate-reviews` step type, AndThen direct skill-name resolution, data-dir skill provisioning, and AndThen `plan.json` adoption. See `CHANGELOG.md` for details.

### 0.16.4 — CLI Operations, Connected Workflows & Workflow Platform Hardening ✅

Connected-by-default CLI workflow execution (`DartclawApiClient` + SSE lifecycle), operational command groups (`agents`, `config`, `jobs`, `projects`, `tasks`, `traces`, expanded `sessions`), workflow trigger surfaces (web launch forms, `/workflow` chat, GitHub PR webhooks), redesigned `plan-and-implement` (per-story `story-pipeline` + `foreach` sub-pipelines, worktree isolation, publish-step PR creation), file-based artifact transport with auto-commit, AndThen-as-runtime-prerequisite skill provisioning under the `dartclaw-` namespace, agent-resolved-merge bundle (`gitStrategy.merge_resolve` + `dartclaw-merge-resolve` skill), `AgentExecution` primitive decomposition, closed `agent|bash|approval|foreach|loop` step-type vocabulary, `inputs:`/`outputs:` rename, engine-managed runtime artifacts at `{{workflow.runtime_artifacts_dir}}`, local-path projects, token-tracking cross-harness consistency. 81 stories (72 main plan + 9 agent-resolved-merge sub-plan). See `CHANGELOG.md` for details.
