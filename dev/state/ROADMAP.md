# DartClaw Roadmap — Current & Next

> Trimmed to the active milestone and what comes next. Full milestone history (MVP onward) and unscheduled drafts are maintained separately in private repo.

## Active Milestone

### 0.22 — Afterglow Design-System Overhaul

**Status: Planned; not started.** Full Web UI adoption of the canonical "Afterglow" design system plus a drift-checked
`design-system.css`/`app.css` split. Hard prerequisite for all later UI work.

## Planned

### 0.23 — Pluggable Database Backend & Multi-Language Search

ADR-045 (Accepted 2026-07-24): `DatabaseBackend` abstraction + versioned in-house migration runner (SQLite-only refactor first), then the opt-in `PostgresBackend` with core-PG `tsvector` language-aware FTS (Swedish/multi-language — the milestone's driving requirement), credential-reference `DATABASE_URL`, and a dual-backend contract-test suite. `pgvector` deferred pending an embedding-source decision. Backend track, parallel to the UI track.

### 0.24 — Chat & Session Experience

Best-in-class Web chat + session-management control-plane on the Afterglow system — the app-track flagship. Sequenced after 0.22 (renumbered from 0.23 on 2026-07-24).

### 0.25 — Workflow Track: DSL v2

Additive workflow DSL v2 grammar (`script:`, `workflow:` sub-workflows, inline `agents:`, fresh-context loops, conditional `approval:` routing) plus the TR-10 server-first authoring UI. First slice of the workflow track (the 2026-07-04 rebrand's "0.22" target, split + renumbered 2026-07-06, shifted again 2026-07-24).

### 0.26 — Workflow Track: Dynamic Workflows + Orchestration Agent

Runtime-composed, schema-validated workflows (generate-validate-run, restored `workflow-builder`) plus the ADR-044 orchestration agent. Second workflow slice.

## Recently Shipped

### 0.21 — Windows Support & Cross-Platform Hardening ✅

Tagged `v0.21.0` on 2026-07-18. Native Windows x64 core runtime, bundled SQLite/FTS5 archive, PowerShell installer,
Scoop publication path, hard-terminate process lifecycle, file-watch config reload, Git Bash workflow steps, and
explicit degradation for Unix-coupled features. See `CHANGELOG.md` for details.

### 0.20.1 — Embedded Binary Assets ✅

Tagged `v0.20.1` on 2026-07-11. ADR-047: the four built-in asset directories (server templates + static, workflow skills + definitions) compile into the AOT binary as checked-in, drift-gated generated libraries; asset resolution collapses to `explicit config → dev/source tree → embedded`; the `dartclaw assets` command, asset cache, and release assets tarball are deleted. Plus ADR-048: release binaries built via `dart build cli` with bundled SQLite (`bin/dartclaw` + sibling `lib/libsqlite3.*`), fixing Linux binaries crashing at first SQLite call. See `CHANGELOG.md` for details.

### 0.20 — Workflow Hardening, Simplification & Polish ✅

Tagged `v0.20.0` on 2026-07-09. Maintenance/hardening milestone (rebranded from 0.19.1): workflow robustness honesty (teardown-cancellation, nested-loop escalation, always-on one-shot timeouts), DartClaw-owned framework-neutral review scoring, output-contract + vocabulary simplification, a two-pass simplification of `dartclaw_workflow` (+ a LOC fitness ceiling), authoring/operator UX polish (live CLI spinner, standalone-run observability, why-paused parity), and test-suite speed + log-noise hardening. 34 stories + the workflow-simplification-residue plan (S01–S08) + the E-track iteration-internals design pass (ADR-046). Tech debt TD-109/111/112/113 closed; TD-070 deferred (ADR-043). See `CHANGELOG.md` for details.

### 0.19 — Context Engine ✅

Tagged `v0.19.0` on 2026-06-26. `context_research` synthesis over MCP (memory + temporal KG + wiki → one compact, citation-backed packet), a guard-mediated and audited outbound MCP *client* (egress allowlist, per-server governance, runtime pool composition), and a read-only Knowledge UI (hub/research/timeline) on the new Afterglow design system. Plus standalone workflow lifecycle control, inline git-strategy override, non-interactive approval policy, provider auth preflight, and the framework-agnostic workflow engine (ADR-041). FR9–FR11 (validation/dogfooding/steward) carried to a follow-on. See `CHANGELOG.md` for details.

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
