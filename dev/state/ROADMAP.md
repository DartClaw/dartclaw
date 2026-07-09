# DartClaw Roadmap — Current & Next

> Trimmed to the active milestone and what comes next. Full milestone history (MVP onward) and unscheduled drafts are maintained separately in private repo.

## Active Milestone

### 0.20 — Workflow Hardening, Simplification & Polish

**Status: Release-ready, awaiting tag.** Opened 2026-06-26 from the `v0.19.0` tag as maintenance milestone 0.19.1 (tech debt + test-suite hardening); rebranded to 0.20 on 2026-07-04 after the scope grew into a full workflow-feature hardening/simplification/polish release (25+ stories: teardown-cancellation honesty, nested-loop escalation, framework-neutral severity scoring, preset relocation, output-contract hygiene, vocabulary neutralization, execution envelope, escalation-visibility fix, YAGNI trims, authoring/operator UX polish). Planned versions previously labeled 0.20/0.21 shifted to 0.21/0.22; a 2026-07-06 renumber then moved the workflow track to 0.24/0.25 and made 0.22/0.23 lead with the UX/app track (see Planned).

Headline: **test-suite speed + log-noise hardening** (spec via `andthen:spec` first). The workspace suite runs ~5 min — dominated by the serialized `-j 1` workflow+server+cli gate — and floods output with `SEVERE` lines from injected negative-path tests (fake `serveFn` bind-failure, mock asset downloads), which makes a green run look broken and would bury a real failure. Profile the serialized suite, reduce the slowest tests, and capture/silence expected-error logs so output is clean.

The open `dev/state/TECH-DEBT-BACKLOG.md` items, dispositioned in the 2026-07-08 cleanup pass:
- TD-109 (HIGH security): **closed** — already resolved in-tree (per-turn session-scoped tool scoping); the untested TurnRunner apply/clear wiring is now regression-guarded.
- TD-113 (test determinism): **closed** — already resolved by the 0.20 test-suite hardening (injected fake timers into the turn wait/stall monitors).
- TD-112 (cohesion, decision-needed): **closed** — decided keep-status-quo (extracting a `TurnWaitMonitor` now is speculative per KISS/YAGNI; revisit on trigger).
- TD-070 (WorkflowCliRunner location): **deferred** — ADR-043 keep-status-quo, pinned; no code.
- TD-111 (wait-state typing): **closed** — the turn wait-state event now carries the `dartclaw_core` `TurnWaitState`/`TurnWaitReason` enums across the sealed-event + SSE-wire contract (`ba33e8bf`).

## Planned

### 0.21 — Windows Support & Cross-Platform Hardening (Next)

Shifted from the 0.20 label by the 2026-07-04 rebrand; scope unchanged (see private repo specs).

### 0.22 — Afterglow Design-System Overhaul

Full Web UI adoption of the canonical "Afterglow" design system + a drift-checked `design-system.css`/`app.css` split. Hard prerequisite for all later UI work; pulled forward by the 2026-07-06 renumber to lead with the UX/app track.

### 0.23 — Chat & Session Experience

Best-in-class Web chat + session-management control-plane on the Afterglow system — the app-track flagship. Sequenced after 0.22.

### 0.24 — Workflow Track: DSL v2

Additive workflow DSL v2 grammar (`script:`, `workflow:` sub-workflows, inline `agents:`, fresh-context loops, conditional `approval:` routing) plus the TR-10 server-first authoring UI. First slice of the workflow track (the 2026-07-04 rebrand's "0.22" target, split + renumbered 2026-07-06).

### 0.25 — Workflow Track: Dynamic Workflows + Orchestration Agent

Runtime-composed, schema-validated workflows (generate-validate-run, restored `workflow-builder`) plus the ADR-044 orchestration agent. Second workflow slice.

## Recently Shipped

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
