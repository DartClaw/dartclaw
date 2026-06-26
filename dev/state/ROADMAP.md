# DartClaw Roadmap — Current & Next

> Trimmed to the active milestone and what comes next. Full milestone history (MVP onward) and unscheduled drafts are maintained separately in private repo.

## Active Milestone

### 0.19 — Context Engine

**Status: Release-ready (0.19.0) — awaiting squash-merge to `main` + annotated `v0.19.0` tag.** FR1–FR8 (outbound MCP client + governance + audit, `context_research` synthesis, read-only knowledge UI on Afterglow) shipped across S01–S12; FR9–FR11 (validation/dogfooding/steward) carved to a 0.19.x follow-on per the PRD sizing flag. See `CHANGELOG.md`.

A knowledge-serving context layer: DartClaw synthesizes its internal knowledge (LLM-maintained wiki + temporal knowledge graph + memory) into compact, citation-backed packets served to agents over MCP via a single `context_research` call, instead of returning raw ranked rows. Adds outbound MCP — DartClaw as a guard-mediated, audited MCP *client* — so it can consume external MCP servers and systems of record. Includes a documented DartClaw-on-DartClaw dogfooding reference (propose-only). Builds on the 0.17 knowledge backend (temporal KG, wiki, inbox ingestion, FTS5/QMD, inbound MCP).

Scoping backlog disposition:
- TD-109: Add per-turn tool scoping or toolless structured extraction before inbox ingestion is treated as untrusted multi-session input. *(Carried — revisit with the FR9–FR11 0.19.x tail.)*
- TD-110: Guard/audit coverage for write-capable MCP tools — **closed** inside FR3 (S04, egress-guard trust-boundary audit).

## Planned

### Workflow DSL v2 + Dynamic Workflows (Next)

The workflow track is confirmed for the milestone after 0.19.

## Recently Shipped

### 0.18 — Universal Agent Harness ✅

Tagged `v0.18.0` on 2026-06-11. First-party ACP (Agent Client Protocol) harness spawning any ACP-compliant agent over JSON-RPC/stdio through one adapter, with capability-gated reverse-calls routed through the existing `FileGuard`/`CommandGuard` chain; Goose and Mistral Vibe as verified targets (new agents usable via config alone). `delegate_to_agent` MCP tool for delegating to allowlisted ACP/Codex agents with explicit security modes and token budgets. Provider-scoped harness pools (closes TD-068), stuck-turn status + early cancel (closes TD-062), versioned release assets, automated Homebrew tap publication, and refreshed architecture/user guides. See `CHANGELOG.md` for details.

### 0.17 — Personal AI & Developer Experience ✅

Tagged `v0.17.0` on 2026-06-04. Structured `USER.md` identity context, conversational onboarding bootstrapping, inbox-drop knowledge ingestion, LLM-maintained knowledge wiki, temporal knowledge graph (SQLite-based structured facts with time-validity), guard config editor, SDK docs Phase 2, chat input redesign (composable input, slash command palette, file attachments, @-mention context references), interrupted-turn retry UX, automated kill/restart crash-recovery validation. Also hardens the workflow engine (stall detection, foreach resume, resume-aware dependency validation, unified step-retry authority) — captured as PRD Phases G/H. See `CHANGELOG.md` for details.

### 0.16.6 — Web UI Stimulus Adoption ✅

Tagged `v0.16.6` on 2026-05-27. Stimulus is now the standard browser interaction layer across the Web UI while HTMX + Trellis remain the rendering/request foundation and the zero-Node toolchain is preserved. Shared shell behavior, core pages, special surfaces, and migrated browser interactions now use `dc-*` Stimulus controllers with the legacy page-global model removed as the primary path. Architecture deep-dives (`dev/architecture/`) and the design system (`dev/design-system/`) promoted to canonical in this repo. AI-native testing scenarios and profile variants (plain, channels, governance, visual, workflows) migrated from the private repo.

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

### 0.16.5 — Stabilisation & Hardening ✅

Consolidation sprint with zero new user-facing features. Closes the alert-classifier safety gap (`LoopDetectedEvent` + `EmergencyStopEvent` now critical via compiler-enforced exhaustive switch over `sealed DartclawEvent`), wires all 7 orphan sealed events to SSE + alerts, narrows the `dartclaw_workflow` barrel to ≤35 explicit `show` clauses, installs 13 governance fitness checks in CI (7 Level-1 + 6 Level-2), flips `public_member_api_docs` lint on in `dartclaw_models/_storage/_security/_config`, extracts `WorkflowRunRepository` / `WorkflowTaskBindingCoordinator` / `ProcessEnvironmentPlan` / `ClaudeSettingsBuilder` to their canonical packages, shrinks `dartclaw_models` to a true shared kernel (workflow / project / task-event / turn-trace / skill-info migrated to owning packages; `TaskEventKind` enum-ified), types four stringly-typed workflow flags as enums, renames `k`-prefix constants and `get*` service methods per Effective Dart, formalises ADR-023 (workflow↔task boundary) + ADR-025 (AndThen-as-runtime-prerequisite + direct skill-name resolution), refreshes `AGENTS.md` and the user guide, and bundles 13 tech-debt closures (TD-046/053/054/055/056/060/061/063/072/073/074/082/085/088/102/103) plus three explicit triage decisions. 24 catalogued stories + standalone work for workflow output presets shorthand, `aggregate-reviews` step type, AndThen direct skill-name resolution, data-dir skill provisioning, and AndThen `plan.json` adoption. See `CHANGELOG.md` for details.

### 0.16.4 — CLI Operations, Connected Workflows & Workflow Platform Hardening ✅

Connected-by-default CLI workflow execution (`DartclawApiClient` + SSE lifecycle), operational command groups (`agents`, `config`, `jobs`, `projects`, `tasks`, `traces`, expanded `sessions`), workflow trigger surfaces (web launch forms, `/workflow` chat, GitHub PR webhooks), redesigned `plan-and-implement` (per-story `story-pipeline` + `foreach` sub-pipelines, worktree isolation, publish-step PR creation), file-based artifact transport with auto-commit, AndThen-as-runtime-prerequisite skill provisioning under the `dartclaw-` namespace, agent-resolved-merge bundle (`gitStrategy.merge_resolve` + `dartclaw-merge-resolve` skill), `AgentExecution` primitive decomposition, closed `agent|bash|approval|foreach|loop` step-type vocabulary, `inputs:`/`outputs:` rename, engine-managed runtime artifacts at `{{workflow.runtime_artifacts_dir}}`, local-path projects, token-tracking cross-harness consistency. 81 stories (72 main plan + 9 agent-resolved-merge sub-plan). See `CHANGELOG.md` for details.
