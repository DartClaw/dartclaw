# DartClaw Roadmap — Current & Next

> Trimmed to the active milestone and what comes next. Full milestone history (MVP onward) and unscheduled drafts are maintained separately in private repo.

## Active Milestone

### 0.25 — Lean Runtime

**Status: feature-complete on `feat/0.25-lean-runtime`, awaiting bundle removal, release check and merge.** 93 of 96
stories done. The milestone deleted the re-derive/repair/default machinery and the hand-rolled chat grammars, moved
those capabilities onto a guarded MCP tool surface (`task_create`, `task_review`, `task_bind`, `workflow_run`,
`schedule_upsert`, `attach_media`, `wiki_write`), made container isolation the default posture where a runtime
exists, re-cut the package topology to thirteen members behind downward-only per-package LOC ceilings, moved the
composition root into `dartclaw_runtime` and halved the CLI app, and put workflow step turns on the same guarded
harness path as interactive ones.

**Three of seven success metrics did not hold**, and are recorded as such rather than re-baselined: the net LOC
reduction (lib fell 1,996 against a 12,000 target and the test surface grew 7,520), the CLI's ≤ 8K lib LOC bar
(10,491, down from 20,769), and the ≥ 40 dead-config-key removal (~29 plus 2 uncounted — several keys turned out to
be live and were preserved under the no-regression constraint). Measured figures, the command that produced them and
the per-clause verdicts are in [`STATE.md`](STATE.md) and [`LOC-BASELINE-0.25.md`](LOC-BASELINE-0.25.md).

**Deferred to 0.30**: S63 and S64, the workflow schema-emitting validator. They stayed `spec-ready`; the preserved
work is parked on `parked/s64-workflow-schema`.

## Planned

### Pluggable Database Backend & Multi-Language Search

> Milestone number owner-assigned — this entry held "0.25" before the Lean Runtime milestone took that number.

### 0.26 — Chat & Session Experience

Best-in-class Web chat + session-management control-plane on the Afterglow system — the app-track flagship. Sequenced
after 0.22 (renumbered from 0.23 on 2026-07-24). **Hard prerequisite: 0.23** — its canon revision changes the
Phase-0 conversation components (`.composer`, `.tool-call`, `.approval-card`, `.notif-item`, `.palette-item`) this
milestone builds on (added 2026-07-25).

### 0.27 — Knowledge Interop & Steward

Guarded knowledge writes, the deferred validation/dogfooding/steward loop, OKF bundle interop, and governed idle-time
memory curation. Reuses 0.24's observe/apply/CAS authority and on-demand action surfaces for governed autonomy and
guarded wiki/KG writes; it does not gain a generic file-replacement tool. It follows the 0.25 storage/search seams. Phase A
also owns caller-aware MCP dispatch context, exact logical-agent-turn cancellation, and an opt-in pinned-provider matrix for
the guard-interception capabilities this milestone relies on.

### 0.28 — Workflow Track: DSL v2

Additive workflow DSL v2 grammar (`script:`, `workflow:` sub-workflows, inline `agents:`, fresh-context loops, conditional `approval:` routing) plus the TR-10 server-first authoring UI. First slice of the workflow track (the 2026-07-04 rebrand's "0.22" target, split + renumbered 2026-07-06, shifted again 2026-07-24).
Inline-agent execution shares the existing global worker capacity. Provider `pool_size` is the sole worker-capacity limit
for background execution.

### 0.29 — Workflow Track: Dynamic Workflows + Orchestration Agent

Runtime-composed, schema-validated workflows (generate-validate-run, restored `workflow-builder`) plus the ADR-044 orchestration agent. Second workflow slice.

## Recently Shipped

### 0.24.3 — Trust Boundaries and Credential Delivery ✅

Released 2026-08-27. Strict schema-bound logical-agent output, one content-scan authority with public outbound-MCP
coverage, and named credential storage with `dartclaw secrets`, search-provider references, and a read-only
secret-location audit. See `CHANGELOG.md` for details.

### 0.23 — Design-System Refinement, Web UI Polish & Runtime Hardening ✅

Tagged `v0.23.0` on 2026-08-08. Refined the Afterglow design-system canon and complete Web UI, added persistent session
navigation and native Signal/WhatsApp typing indicators, and shipped session/task concurrency fixes, generated embedded
assets, deployment/onboarding hardening, guard-chain corrections, channel formatting fixes, and release-build repairs.
See `CHANGELOG.md` for details.

### 0.22 — Afterglow Design-System Overhaul ✅

Tagged `v0.22.0` on 2026-07-25. Full Web UI adoption of the canonical "Afterglow" design system plus the drift-checked
`design-system.css`/`app.css` split. All 14 stories complete; final implementation review passed. Its structural
acceptance criteria hold (zero inline styles, zero template-local `<style>` blocks, tokenized typography) — the
refinement follow-up in 0.23 addresses canon-level quality, not 0.22 execution. See `CHANGELOG.md` for details.

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

Consolidation sprint with zero new user-facing features. It closed the alert-classifier safety gap, wired orphan sealed events to SSE and alerts, narrowed the workflow barrel, installed governance fitness checks, strengthened public API documentation, moved shared seams to their canonical owners, and tightened the bottom-tier value surface that later formed `dartclaw_kernel`. It also typed workflow flags, aligned names with Effective Dart, formalised ADR-023 and ADR-025, refreshed contributor and user guidance, and closed the listed tech-debt items. See `CHANGELOG.md` for the point-in-time package details.

### 0.16.4 — CLI Operations, Connected Workflows & Workflow Platform Hardening ✅

Connected-by-default CLI workflow execution (`DartclawApiClient` + SSE lifecycle), operational command groups (`agents`, `config`, `jobs`, `projects`, `tasks`, `traces`, expanded `sessions`), workflow trigger surfaces (web launch forms, `/workflow` chat, GitHub PR webhooks), redesigned `plan-and-implement` (per-story `story-pipeline` + `foreach` sub-pipelines, worktree isolation, publish-step PR creation), file-based artifact transport with auto-commit, AndThen-as-runtime-prerequisite skill provisioning under the `dartclaw-` namespace, agent-resolved-merge bundle (`gitStrategy.merge_resolve` + `dartclaw-merge-resolve` skill), `AgentExecution` primitive decomposition, closed `agent|bash|approval|foreach|loop` step-type vocabulary, `inputs:`/`outputs:` rename, engine-managed runtime artifacts at `{{workflow.runtime_artifacts_dir}}`, local-path projects, token-tracking cross-harness consistency. 81 stories (72 main plan + 9 agent-resolved-merge sub-plan). See `CHANGELOG.md` for details.
