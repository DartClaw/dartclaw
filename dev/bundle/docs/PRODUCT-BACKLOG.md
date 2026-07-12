# DartClaw — Product Backlog

Features deferred from the implemented scope. Ordered roughly by expected value, not by implementation order. Items promoted to specific milestones are struck through with a promotion note.

> See also: [roadmap](ROADMAP.md) · [feature comparison](specs/feature-comparison.md) · [tech debt backlog](TECH-DEBT-BACKLOG.md)

---

## Deferral Rationale

| Feature | Why Deferred |
|---|---|
| Automated browser E2E tests | 132+ handler tests cover API correctness; manual smoke tests cover browser interactions. Adds `puppeteer` dependency (~200MB Chromium). Justified when UI surface grows (post-0.14 multi-project UI). See [E2E Test Strategy](#automated-browser-e2e-tests) |
| Full multi-agent / Agent Swarms | 2-agent (main+search) + task harness pool sufficient; full swarms add complexity without proportional single-user value |
| Async sub-agent delegation parity (`sessions_spawn` redux) | The 0.18-era `sessions_spawn` half-port was removed (no result retrieval, bypassed the content-guard); only synchronous `sessions_send` ships. Proper async parity is genuine feature work: reintroduce `sessions_spawn` **only** alongside `sessions_list` + `sessions_history` fan-in tools (result retrieval), a content-guard at the async boundary, leaf/orchestrator authority scope, and session lifecycle (idle/maxAge). Gated on a roadmap decision about the OpenClaw power-user audience. _Ref: research/openclaw-power-user-analysis, research/harness-profiles-and-agent-roles_ |
| Channel-guard (ML injection) | Single-user messaging = trusted sender; content-guard (web boundary) is higher priority |
| Identity links (cross-channel) | Separate sessions per channel is acceptable for single user. See [Identity Links & Contact Coalescing](#identity-links--contact-coalescing) |
| Binding-based routing (6-level) | Simple trigger-word routing sufficient for single user. See [Binding-Based Message Routing](#binding-based-message-routing) |
| Queue modes (steer/followup/collect) | Simple FIFO queue sufficient for single user |
| Project auto-commit (per-turn git sync) | SOUL.md workaround sufficient for workshops. Formal implementation needs design (trigger, commit message, push strategy). See [Project Auto-Commit](#project-auto-commit-per-turn-git-sync) |
| ~~Guard Audit Log (persistent + web UI)~~ | ~~Stdout logging sufficient for now~~ → **Promoted to 0.6** Phase B. See [0.6 PRD](specs/0.6/prd.md) |
| ~~OpenTelemetry / LangFuse~~ | ~~Structured logs sufficient for single-user debugging~~ → Foundation promoted to 0.next-projects Phase B (turn traces, cost calc). Budget enforcement in 0.15 Phase D. OTEL export + advanced analytics remain Future. See [agent observability research](research/agent-observability/research.md) |
| ObservabilitySink abstraction | May be subsumed by EventBus + turn traces (0.next-projects) + OTEL export (Future). Evaluate after 0.next-projects |
| ~~Session disk budget~~ | ~~Manual cleanup acceptable for single user at 1.0 scale~~ → **Promoted to 0.7** Phase B (F09). See [0.7 PRD](specs/0.7/prd.md) |
| ~~Flutter app~~ | ~~Web UI + WhatsApp + Telegram covers all surfaces~~ → Replaced by Tauriel desktop app. See [Desktop App (Tauriel)](#desktop-app-tauriel) |
| Computer use / VM tools | Niche use case |
| VM isolation / multi-user deployment | Docker containers sufficient for single user. Multi-user needs Slack/Google Chat integrations, session isolation, role-based tool policies, channel-guard. See [research](research/multi-user-channels/research.md) |
| Slack integration | Multi-user channel; single-user doesn't need team chat. Channel interface in 0.8 makes addition straightforward |
| ~~Google Chat integration~~ | ~~Multi-user channel; requires Google Workspace~~ → **Promoted to 0.8** Phase F (F29-F39). See [0.8 PRD](specs/0.8/prd.md) |
| Security audit CLI | Guards + doctor cover current needs |
| ~~Config hot-reload~~ | ~~Restart is acceptable for single user~~ → Tier 1 in 0.5, Tier 2 in 0.6, ~~Tier 3 (full hot-reload) remains Future~~ → **Implemented in 0.16** (ConfigNotifier + Reconfigurable services + SIGUSR1/file-watch triggers). See [Live Config Tier 3](#live-config--hot-reload-tier-3) |
| Image generation | Nice-to-have, not core assistant utility |
| ~~Knowledge graph~~ | ~~Mem0/Zep-style relational storage~~ → Lightweight temporal KG (two SQLite tables, ~1000 LOC) **promoted to 0.17 Phase B** alongside LLM Wiki. [MemPalace research](research/temporal-knowledge-graph/research.md) demonstrated that a temporal KG requires no graph DB infrastructure — just SQLite (which `dartclaw_storage` already uses). Complements wiki: KG = machine-queryable structured facts with time-validity; wiki = synthesized narrative. Full Neo4j-scale graph remains Future |
| BOOT.md / BOOTSTRAP.md | SOUL.md + CLAUDE.md + USER.md + TOOLS.md cover current needs |
| ~~Dedicated search APIs (Brave, Tavily)~~ | **Implemented in 0.6** Phase D (F18). Perplexity + SearXNG remain Future |
| MCP server hosting (standalone) | Memory MCP in 0.8 is sufficient; external MCP hosting is post-0.8 |
| Multi-gateway profiles | Single user = single gateway |
| `plugins` SDK passthrough | Skills via `settingSources` sufficient for shipped scope |
| Skill lifecycle management (install/sync) | 0.15.1 ships discovery + validation (SkillRegistry). Install, sync across harnesses, versioning deferred. See [Skill Lifecycle Management](#skill-lifecycle-management) |
| ~~Signal integration~~ | **Implemented in 0.4** (Phase D: S11–S12). `SignalCliManager`, `SignalChannel`, webhook route, pairing page |
| Telegram integration | WhatsApp is the must-have channel; Telegram reduces scope without proportional daily-driver value. Channel interface abstraction in 0.8 makes it a straightforward addition |
| ~~CLI REPL (`dartclaw chat`)~~ | ~~Web UI + WhatsApp covers daily-driver surfaces; REPL is convenience, not critical path~~ → **Split to own milestone**: [0.next-cli-repl](specs/0.next-cli-repl/prd-draft.md) (unscheduled). Niche SSH/headless use case |
| ~~`dartclaw doctor --fix`~~ | ~~Guards + deployment tooling cover current validation needs; doctor is a quality-of-life improvement~~ → **Deferred to 0.19+** |
| Feedback signals / learning loop | Current memory system handles core needs; behavioral self-improvement is a polish feature. _Ref: PAI SIGNALS system_ |
| Push notifications (ntfy) | Useful for long-running tasks but channel-based system alerts (0.16 Phase B) cover the primary use case using existing channel infrastructure. ntfy.sh remains Future — add if channel alerts prove insufficient. _Ref: PAI ntfy integration_ |
| ~~Extended identity context (TELOS)~~ | ~~USER.md in 0.8 covers basics; richer goal/belief/strategy files are post-0.8 refinement~~ → **Planned for 0.17** Phase A as expanded USER.md sections (not separate files). _Ref: PAI TELOS_ |
| ~~Inbox-drop knowledge ingestion~~ | → **Planned for 0.17** Phase B. _Ref: Alfred Curator pattern_ |
| Work memory (structured task units) | Session-based memory sufficient for shipped scope; per-task persistent artifacts are a quality-of-life improvement. _Ref: PAI Tier 2 Work Memory_ |
| Builder-Validator agent pairs | Requires full multi-agent orchestration. _Ref: PAI v3.0 Agent Swarms_ |
| ~~Tailscale integration~~ | ~~Localhost + token auth covers shipped scope daily-driver. Remote access is a deployment-phase concern~~ → **Deferred to 0.19+** (bundles with Doctor for "headless access & diagnostics" story). Auth layer already tunnel-safe (ADR-006). See [Tailscale Integration](#tailscale-integration) |
| ~~SDK support (`dartclaw_core`)~~ | **Planned for 0.5** (Phase D: F08–F11). API surface audit, packaging, pub.dev publish. See [0.5 PRD](specs/0.5/prd.md) |
| Channel config editor | 0.6 shipped channel access editing only; full channel config needs reconnection-safe UX and validation | Keep YAML-only editing |
| Container config editor | Rarely used and restart-sensitive; not worth 0.6 scope | Keep YAML-only editing |
| Config rollback / versioning | Backup-on-write covers recovery; richer rollback needs change history and restore UX | Single `.bak` only |
| Multi-file config (`include`) | Single-file config remains simpler for single-user; includes add merge and validation complexity | One file forever |
| Memory content editing | 0.6 memory dashboard is read-only by design; editing needs integrity rules and agent/operator conflict handling | SSH-only edits |
| Retrieval transparency | 0.6 dashboard exposes memory health, not per-turn retrieval traces | No retrieval introspection |
| Goal ancestry context injection (deep) | 0.8 shipped capped goals; deeper ancestry needs context budgeting and clearer UX | Two-level cap forever |
| Plan review UX (inline comments) | 0.8 shipped chat-embedded review first; inline review is more expensive but still valuable. Deferred from original 0.10 scope split — chat-only review is sufficient | Future |
| ~~Per-task autonomy controls~~ | ~~0.8 task execution is intentionally simple; per-task guard or autonomy dials add policy surface~~ → **Planned for 0.15** Phase D | Global policy only |
| Extra container profiles | 0.8 ships profile-aware containers but not additional built-in profiles like `integration` or VM-backed modes | Reuse current profiles forever |
| Task type extensibility | 0.8 fixed `TaskType` enum + `custom` escape hatch; registry-based extensibility still deferred | Fixed enum forever |
| Google Chat native quoting/reactions | `chat.bot` scope doesn't support `quotedMessageMetadata` or reactions. Needs dedicated Workspace account + user OAuth. Text-level quoting (`> @Sender: …`) ships as fallback. See [Advanced Messaging Features](#google-chat-user-oauth-for-native-features-quote-reply-reactions) |
| Cost-based budget enforcement (`maxCostUsd`) | 0.15 ships tokens-only budget — universal across all harnesses. Cost reporting only supported by `ClaudeCodeHarness` (`supportsCostReporting: true`); Codex harnesses report `0.0`. See [Cost-Based Budget Enforcement](#cost-based-budget-enforcement) |
| ~~Package manager distribution (Homebrew first)~~ | ~~Standalone binary exists, but release artifact publishing, checksums, signing, and tap maintenance are still missing. GitHub Releases + manual binary copy are sufficient short-term~~ → **Planned for 0.18** Phase D. Homebrew-first package-manager distribution built on top of versioned GitHub Release assets | GitHub Releases/manual install only |
| ~~Auto-retry on failure / rejection~~ | ~~0.8 avoids retry loops; a bounded retry policy remains future work~~ → **Planned for 0.15** Phase D | Manual retry only |
| ~~Context compact instructions~~ | ~~Binary handles auto-compaction opaquely~~ → **Planned for 0.10** Phase B (F-CTX-01). System prompt injection guides binary's compaction behavior |
| ~~Exploration summaries~~ | ~~Head+tail truncation sufficient~~ → **Planned for 0.10** Phase B (F-CTX-02). Type-aware structural summaries for large files |
| ~~Compaction observability (Tier 1.5)~~ | ~~Cross-harness compaction event model, `PreCompact` hook, Codex `contextCompaction` handling, flush dedup, identifier preservation~~ → **Implemented in 0.16** Phase 0. See [Context Management Infrastructure](#context-management-infrastructure-lcm) |
| Context engine abstraction + conversation search | Useful independently (Tier 2) but primarily needed for Pi/DirectApiHarness. See [Context Management Infrastructure](#context-management-infrastructure-lcm) | After multi-harness decision |
| DAG compaction + operator recursion | Full LCM implementation. No longer a DirectApiHarness prerequisite (Compaction API covers it). Remains valuable for provider-independent compaction and custom retrieval. See [Context Management Infrastructure](#context-management-infrastructure-lcm) | Optional — after Pi/DirectApi harness |
| Workflow `--dry-run` execution-plan preview | Deferred from the 2026-07-04 workflow deep-dive (0.20): validate + print resolved step/gate/branch plan before spending tokens/git. `workflow show --resolved` + the new `validate --skills` (0.20 S07) cover the near cases; a true dry-run reuses the resolver machinery but is net-new surface under the keep-workflows-lightweight mandate |
| Workflow mid-run context inspector / template debugger | Deferred from the 2026-07-04 deep-dive: consolidated "context so far" view + template-resolution debugging. Per-step web context view covers the 80% case; revisit if the 0.22 orchestration agent's authoring loop needs it |
| Workflow approval-step wall-clock backstop | Deferred from the 2026-07-04 deep-dive: an approval step without `timeoutSeconds` waits indefinitely (deliberate for interactive use; a footgun for unattended custom workflows — built-ins don't author bare approval steps). Needs a product decision on a default (auto-cancel vs auto-escalate) before wiring |
| Workflow multi-prompt per-step wall-clock ceiling | Deferred from the 2026-07-04 deep-dive: the 0.20 step ceiling (`max_duration` 1800s) applies per provider turn, so an N-prompt step can take N× the ceiling before being bounded overall. Low likelihood today (built-ins use short chains); fold into any future timeout rework |
| Review output object-collapse (gate-grammar rework) | Deferred from the 2026-07-04 deep-dive: collapsing path/counts/verdict into one object-valued review key requires replacing the regex-based gate parser first (TD-076). 0.20 S05 ships the honest-rename + enforced-prefixing fix; the object model only pays off together with TD-076 and the 0.22 DSL v2 track |
| One-shot agent MCP-set curation | Known gap (2026-06 dogfooding, re-flagged 2026-07-04): spawned codex/claude one-shot review agents inherit the full global `~/.codex`/`~/.claude` MCP config unfiltered — no project-config curation surface. Security/attack-surface concern more than UX; needs a config-schema decision (per-provider allowlist vs empty-by-default) |

---

## Full Multi-Agent Orchestration
- Agent teams/swarms beyond 2-agent main+search pattern. **Design note**: NanoClaw uses Anthropic SDK native Agent Swarms (per-swarm-agent memory isolation, launched 2026-02-09). Evaluate SDK swarm support vs. custom orchestration at implementation time — SDK native may simplify implementation significantly
- **Tool policy cascade expansion**: 5+ layers (`global deny → group policy → agent deny → sandbox policy → subagent policy`)
- **Agent delegation patterns**: channel agents delegate exec/browser/fs tasks to main via `sessions_send`. SOUL.md behavioral boundaries per agent type
- `extraPaths` for indexing shared knowledge bases across agents
- Behavior file caching with file-watch invalidation — replaces per-turn re-read for high-frequency multi-agent use
- **Builder-Validator pairs**: every work unit gets a builder agent AND an independent validator agent. The agent separation is necessary but not sufficient — **evaluator calibration is the actual feature**. Anthropic's research found that out-of-the-box, Claude is a "poor QA agent" that talks itself into approving bad work. Calibration requires: anti-leniency prompting, per-criterion hard thresholds, few-shot grading examples, and tool-assisted verification (browser automation for live-app interaction). Multiple rounds of prompt tuning were needed before the evaluator graded reasonably. 0.15's workflow evaluator steps are a first step; full builder-validator pairs extend this to all task types. _Ref: PAI v3.0 Agent Swarms, [Anthropic harness design research](research/harness-design-long-running/research.md)_
- **ISC-style task criteria / sprint contracts**: binary testable, state-based success criteria per task — prevents vague "done" claims. Anthropic's research uses "sprint contracts" where generator and evaluator agree on acceptance criteria before work begins. 0.15's `acceptance_criteria` context key is a lightweight version; full ISC extends this with structured schema, per-criterion scoring, and evaluator-verifiable conditions. _Ref: PAI Ideal State Criteria, [Anthropic harness design research](research/harness-design-long-running/research.md)_

## Task Orchestrator + Dashboard Extensibility
_Ref: [task orchestrator research](research/task-orchestrator/research.md) · [ADR-003](adrs/003-coding-task-support-and-agent-extensibility.md) (agent extensibility layers)_

DartClaw as a **control plane** and task orchestrator — managing multiple concurrent agent conversations for parallel execution, with structured review flows before accepting results. Not limited to coding; research, writing, analysis, and automation tasks are equally important. Competitive landscape: Codex App, Kintsugi, Conductor, Paperclip, Claude Desktop Cowork.

### Three-Layer Architecture

1. **Page Registry** (foundation) — replace hardcoded page registration with a `PageRegistry`. Existing pages become `DashboardPage` implementations. Unlocks `server.registerDashboardPage()` as public SDK API
2. **Task Model + Execution Engine** — new `Task` domain model (draft/queued/blocked/running/interrupted/review/accepted/rejected/failed) distinct from `Session`. Task-type-agnostic base with optional type-specific capabilities (worktrees for coding, standard sessions for knowledge work). Goal/mission hierarchy for context alignment. Storage: SQLite (relational queries on status, type, goal, parent/child, dependencies)
3. **Review UX** — plan approval before execution, artifact review (diff viewer for code, document viewer for research), accept/reject/revise workflow

### Key Concepts
- **Task types**: coding (git worktree isolation), research, writing, analysis, automation, custom
- **Goal ancestry**: every task carries parent chain to mission — structured context for agents. _Ref: Paperclip's SKILL.md protocol_
- **Harness Pool**: pool of `AgentHarness` instances (one per active task) replacing the current single global harness. `acquire(task)` / `release(task)` lifecycle. Configurable `maxConcurrent`. Current single-harness architecture is the hard blocker for parallelism
- **Atomic checkout**: `POST /tasks/{id}/checkout` with 409-on-conflict — prevents double-assignment when multiple agents or automation compete for tasks (useful even single-user: prevents automation + user conflicts). _Ref: Paperclip_
- **Task-Session architecture**: 1:1 Task→Session composition. New `SessionType.task` + `SessionKey.taskSession(taskId)` for deterministic mapping. Existing chat rendering reusable without modification
- **Agent observability**: per-task status API (`GET /tasks/{id}/status`), streaming progress events, task dashboard with live status indicators. Cross-ref: [Observability Integrations](#observability-integrations) for OTel/LangFuse sinks
- **Structured coordination** (Level 2): task dependencies and sub-task delegation through the control plane — not direct agent-to-agent communication. Agents request sub-tasks; orchestrator manages scheduling and results
- **Coding task worktrees**: each coding task gets an isolated git worktree (`dartclaw/task-<id>` branch). Full lifecycle: create → execute → stale detection → review (diff) → accept (merge) / reject (retry or discard) → cleanup. Configurable merge strategy (squash default). FileGuard registers worktree paths. See research doc for full lifecycle spec
- **Channel-to-task**: "Fix the login bug" from WhatsApp/Signal → task created → agent executes → review from browser. DartClaw's most differentiating capability. Config-driven: explicit command prefix, default task type, auto-start toggle. See research doc for mechanism sketch
- **Concurrency**: parallel task execution with per-task session isolation. Extend existing `SessionLockManager`
- **Review flow**: structured review message types in chat UI + dedicated review page

### Implementation Phasing (by task type)
Task model is type-agnostic from day one. Implementation phases by type:
1. **Research/writing** first — simplest (standard sessions, document artifacts, no merge conflicts). Validates core model
2. **Automation** — extends existing scheduling with review status. Lowest new code
3. **Coding** — most complex (worktrees, diff review, merge, FileGuard). Ships after model is proven
4. **Analysis/custom** — incremental additions

### Milestone Placement
- **Page Registry**: 0.8 Phase A (foundation for task dashboard, SDK-enabling)
- **Per-type container isolation**: 0.8 Phase A ([ADR-012](adrs/012-per-type-container-isolation.md) — ships with harness pool)
- **Task Model + sequential execution**: 0.8 Phase B (validates model without parallelism)
- **HarnessPool + parallel execution**: 0.8 Phase C (after task model is proven)
- **Coding worktrees**: 0.8 Phase D (most complex type — ships after simpler types)
- **Task Dashboard UI**: 0.8 Phase E (depends on all prior phases)
- **Channel → Task integration**: 0.9+

### Prerequisites
- `AgentHarness` abstraction (ADR-007) — in place
- Multi-session support — in place
- Scheduling infrastructure — in place
- Harness Pool (new) — required for parallel execution

## ~~Multi-Provider Agent Harnesses~~
~~_Ref: [alternative agent harnesses research](research/alternative-agent-harnesses/research.md) · ADR-007 (AgentHarness interface)_~~

→ **Promoted to 0.13** (CodexHarness as first second-harness implementation). See [0.13 PRD](specs/0.13/prd.md). **Next milestone: [0.18](specs/0.18/prd-draft.md)** — AcpHarness (universal, 34 agents), Goose as first ACP agent, agent-as-MCP-tool delegation. Research refreshed April 2026: [alternative-agent-harnesses](research/alternative-agent-harnesses/research.md), [outpost-pattern-integration](research/outpost-pattern-integration/research.md).

### Remaining Options (after 0.18)

- **DirectApiHarness** — pure Dart, zero deps, ~1,000-1,500 LOC. Feasible now (Dart SDK ecosystem mature). See [inspiration backlog](INSPIRATION-BACKLOG.md#directapiharness--pure-dart-agent-loop-zero-subprocess-dependencies)
- **Native PiHarness** — only if Pi-specific features (mid-run steering, context monitoring) prove valuable through ACP usage
- **Per-agent harness profiles** — coding/research/review/automation profiles mapped to specific harness types. See [inspiration backlog](INSPIRATION-BACKLOG.md#per-agent-harness-profiles)

**Relationship to HarnessPool (0.8)**: The 0.8 `HarnessPool` manages multiple `ClaudeCodeHarness` instances (same provider, parallel execution). Multi-provider harnesses are orthogonal — a future pool could contain a mix of `ClaudeCodeHarness`, `AcpHarness` (Goose, Pi, Gemini CLI), and `DirectApiHarness` instances, with task type routing determining which harness type a task acquires. Multi-agent swarms ([Full Multi-Agent Orchestration](#full-multi-agent-orchestration)) are a third dimension — multiple agents coordinating within a single harness session via SDK-native swarm support.

## Project Auto-Commit (Per-Turn Git Sync)

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: Future

When the agent edits files in a project directory (external repo registered via `projects:`, or the working directory in a non-worktree crowd coding session), those changes are not auto-committed. `WorkspaceGitSync` only covers `<data_dir>/workspace/` (behavioral files). Worktree-based tasks auto-commit on accept (via `TaskReviewService`), but non-task edits and Scenario C freeform sessions leave changes uncommitted in the working directory.

**What exists:**
- `WorkspaceGitSync` — auto-commits behavioral files on heartbeat. Covers `<data_dir>/workspace/` only
- `RemotePushService` — pushes task branches on accept. Worktree-specific
- Task accept flow — squash-merges worktree branch. Only for formal tasks

**What's missing:**
- Auto-commit for agent edits in project directories (non-workspace, non-worktree)
- Configurable trigger: per-turn, per-heartbeat, or on-idle (Aider uses per-edit auto-commit)
- Push strategy for project auto-commits (push to branch? to main? configurable?)

**Design considerations:**
- Per-turn auto-commit (like Aider) is most predictable — each agent response becomes a commit. Avoids data loss if server crashes mid-session
- Commit messages should be auto-generated from the turn's activity (files changed, brief summary)
- Must respect `.gitignore` and avoid committing secrets
- For crowd coding (Scenario C), this replaces the current workaround of heartbeat-based workspace git sync

**Current workaround:** Add "Git Discipline" section to SOUL.md instructing the agent to commit after every code change. See [crowd coding recipe](../dartclaw-public/docs/guide/recipes/08-crowd-coding.md) Behavior Files section.

**When to implement:** When crowd coding usage grows beyond workshops into sustained multi-session projects where data loss risk from uncommitted changes becomes unacceptable.

---

## Context Management Infrastructure (LCM)
_Ref: [LCM research](research/lossless-context-management/research.md) · [Compaction observability research](research/compaction-observability/research.md) · [Anthropic harness design research](research/harness-design-long-running/research.md) · [LCM paper](https://papers.voltropy.com/LCM) (Ehrlich & Blackman, Voltropy, 2026) · [lossless-claw](https://github.com/martian-engineering/lossless-claw) (OpenClaw implementation) · [Anthropic Compaction API](https://platform.claude.com/docs/en/build-with-claude/compaction)_

Engine-managed context window management based on the Lossless Context Management (LCM) architecture. Tier 1 improvements (compact instructions, exploration summaries) shipped in 0.10. The features below are the medium- and high-effort tiers.

**Updated 2026-03-28:** The Anthropic Compaction API (`compact_20260112`, beta Feb 5, 2026) fundamentally changes the Tier 3 analysis. A DirectApiHarness can now delegate compaction to Anthropic's servers — DAG compaction is no longer a prerequisite. Additionally, Claude Code's `PreCompact` hook is available via JSONL `hookCallbackIds`, enabling deterministic compaction observability without heuristics. See [compaction observability research](research/compaction-observability/research.md) for cross-harness analysis.

### Tier 1.5 — Compaction Observability (Low Effort, Immediate Value)

**Compaction event model**: Define `CompactionEvent` sealed class on EventBus (`CompactionStarting`, `CompactionCompleted`). Wire each harness adapter to emit events via its native mechanism: Claude Code → `PreCompact` hook + `compact_boundary`; Codex → `contextCompaction` item events; DirectApi → `stop_reason: "compaction"`.

**PreCompact hook registration**: Register `PreCompact` in the Claude Code harness `initialize` handshake. Replaces heuristic `ContextMonitor.shouldFlush` with deterministic signal from the binary. Route via `_handleHookCallback` alongside existing PreToolUse/PostToolUse.

**Codex `contextCompaction` handling**: Recognize `contextCompaction` item type in `codex_protocol_adapter.dart` (currently silently dropped). Emit `CompactionEvent` on EventBus.

**Flush dedup**: SHA-256 hash of last N user/assistant messages before triggering `_runFlushTurn()`. Per-compaction-cycle tracking. Prevents redundant flushes. (Pattern from OpenClaw `memory-flush.ts`.)

**Identifier preservation**: Append to `defaultCompactInstructions`: preserve session keys, task IDs, UUIDs, file paths, hostnames, URLs. (Pattern from OpenClaw `identifierPolicy: "strict"`.)

**Context anxiety detection**: Monitor behavioral signals indicating the model is prematurely wrapping up work due to perceived context limits — premature summary language, declining response length, refusal to start new subtasks. Anthropic's research found this is model-dependent (strong in Sonnet 4.5, largely resolved in Opus 4.6). When detected alongside high token usage, trigger proactive context reset or user warning. See [Anthropic harness design research](research/harness-design-long-running/research.md) and [INSPIRATION-BACKLOG.md](INSPIRATION-BACKLOG.md#context-anxiety-detection).

### Tier 2 — Conversation Search & Context Assembly (Medium Effort)

**Conversation search over stored history**: MCP tool (`conversation_search` or `lcm_grep`) that searches across all stored messages in NDJSON files — not just MEMORY.md. DartClaw already has the lossless ground truth (NDJSON message files) and FTS5 infrastructure (`dartclaw_storage`). Implementation: index messages into FTS5 alongside memory chunks. Scope search to current session by default (avoid cross-session data leakage — learned from lossless-claw issue #70). Results grouped by turn/timestamp for conversational context. Gives the agent retrievability after the binary's auto-compaction drops old content from its active context.

**Context assembly layer**: Abstract "what the harness receives" from "what's stored." Currently DartClaw sends all messages and the binary decides what fits. A `ContextEngine` interface in `dartclaw_core` would separate this:

```dart
abstract interface class ContextEngine {
  Future<void> ingest(Message message);
  Future<List<ContextItem>> assemble({required int tokenBudget});
  Future<void> compact({bool blocking = false});
  Future<void> reset();  // full context reset with structured handoff
  Future<void> afterTurn();
}
```

**Harness-initiated context reset**: Full context reset (kill session, start fresh with structured handoff artifact) as an alternative to in-place compaction for long-running single tasks. Anthropic's research found context resets superior to compaction — 0.15 workflow steps already embody this pattern (fresh session per step), but intra-task resets are not yet supported. The `reset()` method prompts the agent to summarize current state, persists the handoff, kills the session, and starts fresh with the handoff as initial context. More impactful than DAG compaction (Tier 3) for practical long-running task quality. See [Anthropic harness design research](research/harness-design-long-running/research.md) and [INSPIRATION-BACKLOG.md](INSPIRATION-BACKLOG.md#harness-initiated-context-reset).

Three concrete implementations become viable:
- `ClaudeCodeContextEngine` — `ingest` (NDJSON write), `compact` no-op (binary-managed), `assemble` budget-constrains messages
- `CodexContextEngine` — `ingest` (NDJSON), `compact` delegates to `thread/compact/start`, observes `contextCompaction` items
- `DirectApiContextEngine` — `ingest` (NDJSON), `compact` uses `compact_20260112` with custom `instructions`, `assemble` uses token counting pre-flight (`POST /v1/messages/count_tokens`), automatic prompt caching for 10× cost reduction

The `context_items` table pattern (ordered list of message/summary pointers with atomic range-replace) is the key data structure.

### Tier 3 — DAG Compaction & Operator Recursion (High Effort, Optional)

> **Updated 2026-03-28:** DAG compaction is no longer a DirectApiHarness prerequisite. The Anthropic Compaction API provides server-side summarization. DAG remains valuable for: (a) provider-independent compaction, (b) custom retrieval via `lcm_expand`, (c) multi-level progressive summarization with provenance. Implement only if these use cases justify the effort.

**DAG compaction engine**: Full hierarchical compaction — leaf summaries of old message chunks (depth 1), condensed summaries at higher depths (depth 2+), depth-aware prompts (d1: hourly decisions, d2: phase transitions, d3+: cold-start essentials). Three-level summarization escalation guarantees convergence: normal → aggressive → deterministic truncation (no LLM, hard floor at 512 tokens). Dual-threshold context control loop: soft threshold triggers async non-blocking compaction, hard threshold triggers synchronous blocking compaction. Below soft threshold, zero overhead (Zero-Cost Continuity).

- ~400–600 lines of Dart for compaction + assembly + storage
- SQLite storage: messages, summaries, DAG edges (summary_messages, summary_parents), context_items
- Security: summaries generated as system-role (prevents prompt injection surviving compaction — lossless-claw issue #71). Per-compaction token budget cap (prevents unbounded LLM spend — lossless-claw issue #74)

**Operator-level recursion (llm_map / agentic_map)**: Engine-managed parallel primitives that replace model-written loops. `llm_map` dispatches stateless LLM calls per item in a JSONL file (schema validation, concurrency control, retries). `agentic_map` spawns full sub-agent sessions per item. DartClaw's `TaskExecutor` + `HarnessPool` is the foundation — the gap is the structured tool interface (JSONL I/O, per-item schema, results outside active context). Maps naturally to the Workflow Engine (0.15) — could be implemented as a workflow step type. Scope-reduction invariant for delegation: sub-agents must declare `delegated_scope` + `kept_work` (structural termination guarantee, no depth bound needed).

### Implementation Trigger

Tier 1.5 is low-effort, high-value — can ship in any milestone. Tier 2 is independently useful (conversation search improves agent recall even with Claude Code binary). Tier 3's urgency is significantly reduced by the Compaction API — it's no longer a gate for DirectApiHarness. Design the `ContextEngine` interface in Tier 2 so that both server-side compaction and DAG compaction are plug-in implementations.

## Distribution Model (Binary Releases)

The orchestrator application source code may remain private, with binary-only releases. This follows the **open protocol, closed implementation** model (similar to Cursor/Windsurf).

**Private (compiled binary)**: `apps/dartclaw_cli` + `packages/dartclaw_server` — the AOT-compiled Dart binary users run. Distributed via GitHub Releases, then package managers layered on top (Homebrew first). Platform-specific binaries (macOS arm64/x64, Linux x64). Zero runtime dependencies.

**Public (SDK/protocol)**:
- `dartclaw_core` — `AgentHarness` interface, guard contracts, plugin interfaces
- `dartclaw_models` — `Task`, `Session`, `Goal` data models
- REST API documentation — enables third-party UIs and integrations
- Config format (`dartclaw.yaml`) — documented schema

**Extensibility via protocol, not source**:
- Tools: registered via MCP servers (external processes), not Dart imports — `registerTool()` already works this way
- Dashboard pages: via config pointing to external URLs or templates (future), or `.dcplugin` packages (MCP server + page templates + config)
- Skills: `.claude/skills/` files — already works without source access

**Standalone binary maturity**: 0.16.3 now embeds templates, static assets, and built-in skills into `build/dartclaw`, so the normal runtime no longer depends on the source tree. `dart run ...` and `--dev` remain the development/hot-reload path, but user-facing documentation should default to the standalone binary.

**Package manager distribution (Homebrew first)**:

- **Why now**: once the binary is self-contained, the main missing step is distribution convenience, not runtime correctness. The user guide should teach `dartclaw ...`, not `dart run ...`, and package-manager install is the cleanest way to make that true.
- **Phase 1**: publish versioned GitHub Release assets with stable filenames, checksums, and a documented manual install path.
- **Phase 2**: ship a dedicated Homebrew tap/formula that downloads the release asset, installs `dartclaw`, and runs a lightweight `dartclaw --version` smoke check. Homebrew should install DartClaw itself, not implicit provider CLIs like `claude` or `codex`.
- **Phase 3**: consider broader package-manager coverage only after the release artifact contract stabilizes (apt/rpm/Nix are optional follow-ons, not prerequisites).
- **Operational rule**: service management stays a runtime concern (`dartclaw init`, `dartclaw service install`), not something the package manager tries to own.

**Impact on SDK publishing**: The existing `dartclaw` pub.dev name-squat (0.0.1-dev.1) becomes the SDK packages only. The orchestrator app is never published to pub.dev.

_Decision: needs ADR. Affects [ADR-008](adrs/008-sdk-publishing-strategy.md) (SDK publishing strategy)._

## Vector Search (Hybrid FTS5 + Embeddings)
_Ref: [vector search research](research/vector-search-approach/research.md) · [recommendation](research/vector-search-approach/recommendation.md) · [PKM landscape research](research/personal-ai-pkm-landscape/research.md) (Tier 1→2 progression)_

> **Update 2026-07-10 (ADR-045):** the pluggable-database-backend track (public `dev/adrs/045-pluggable-database-backend.md`, roadmap `0.next-database-backend`) adds a third storage path — `pgvector` in-database vector search behind the opt-in PostgreSQL backend, which would be DartClaw's first non-stub in-DB vector search (sqlite-vec never left stub status, ADR-002/004). The cloud-embeddings + sqlite-vec approach below remains the SQLite-default-path candidate; embedding generation is orthogonal to which store holds the vectors.

Hybrid memory search combining existing FTS5 full-text with vector similarity via cloud embeddings. Complements the knowledge graph feature. Identified as the highest-impact memory improvement in the PKM landscape research — Khoj's bi-encoder + cross-encoder reranking and Letta's 3-tier memory both demonstrate significant retrieval quality gains over keyword-only search. Pairs naturally with [Temporal Memory Tracking](#temporal-memory-tracking-superseded_at) for a combined Tier 2 memory upgrade.

- **Approach**: Cloud Embedding API (OpenAI `text-embedding-3-small`) + `sqlite-vec` extension in Dart. ~$0.02/year for single-user corpus
- **Embed-on-write**: embeddings generated at memory_save time, stored as BLOB column on `memory_chunks`. Search is always local; API unavailability only blocks embedding new chunks
- **Hybrid search**: RRF (Reciprocal Rank Fusion) of FTS5 + vector KNN results. `searchHybrid()` extends existing `MemoryService`
- **sqlite-vec**: two viable Dart paths — `sqlite_vector` (sqliteai, pub.dev) or `sqlite-vec` (asg017, native asset build hook)
- **Graceful degradation**: FTS5 fallback absorbs all failure modes. Vector search is additive, not replacement
- _Note: Deno Worker Embeddings option from original research is architecturally obsolete (Deno eliminated in Phase 0)_

## Channel-guard Plugin
- Local ML model (DeBERTa ONNX, ~370MB cached) scans inbound channel messages for prompt injection
- Three-tier response: pass (< 0.4) → warn (0.4–0.8, inject advisory) → block (> 0.8, reject message)
- Chunking: messages split into ~1500-char chunks (~512 tokens), classified separately
- Lazy singleton: model loads on first guard call, cached. Offline-capable, no API dependency
- _Ref: OpenClaw `extensions/channel-guard/`_
- **When to add**: when DartClaw is exposed to untrusted senders (multi-user, open DM policy, public groups)

## Advanced Messaging Features

### Identity Links & Contact Coalescing
Map provider-specific peer IDs to canonical identity for cross-channel session coalescing (e.g., Alice's WhatsApp + Google Chat → single session). 0.7 introduced configurable `dm_scope` and `group_scope` per channel — identity links would sit above this, resolving a `(channel, peerId)` tuple to a canonical `contactId` before session key generation. Requires: contact registry, manual link confirmation UI, collision handling for ambiguous matches. Prerequisite for multi-user deployment.

### Binding-Based Message Routing
Deterministic routing with 6-level precedence: peer → guild → team → account → channel → default (first match wins). Each binding specifies target session, agent config override, and priority. Currently, DartClaw routes messages via `ChannelManager.deriveSessionKey()` using static scope config — binding-based routing would make routing configurable and composable. Primary value: multi-user deployments where different users/groups need different agent behaviors.

### Queue Modes
Three modes beyond current FIFO: `steer` (inject into current running turn), `followup` (wait for turn end, then process), `collect` (coalesce multiple messages before processing). Current behavior is FIFO with debouncing.

### Google Chat User OAuth for Native Features (Quote-Reply, Reactions)

Google Chat API's `quotedMessageMetadata` and reaction endpoints require user-level auth (`chat.messages.create`, `chat.messages.reactions`). The `chat.bot` service-account scope returns 403 for both.

**Approach**: Dedicated Workspace account (e.g. `dartclaw-bot@domain.com`) with user OAuth for all outbound Chat API calls. Service account handles infrastructure (events, Pub/Sub). User OAuth handles interaction (messages, reactions, quotes).

**Trade-offs**: Extra Workspace license (~$6-14/month), messages lose "APP" badge, two identities per space (Chat app + user). Could potentially replace the Chat app entirely if slash commands aren't needed — receiving events via Pub/Sub Space Events doesn't require the Chat app webhook.

**Current state** (0.14.4): `quote_reply: text` ships as pragmatic default (text-level `> @Sender: …` quoting, works with `chat.bot`). `quote_reply: native` kept but falls back to text-level on 403. See [research](research/google-chat-integration/research.md#user-oauth-for-native-quoting--reactions-2026-03-28).

**Implementation scope**: Add `send_auth: user` config option to GoogleChatConfig. When enabled, use the stored user OAuth client for all message sends (not just reactions). Merge scope requirements (`chat.messages.create` + `chat.messages.reactions`). Update `dartclaw google-auth` to request combined scopes. Channel wiring creates a unified user OAuth client. Service account remains for Space Events and webhook verification.

### Other
- ~~DM scope isolation: default `per-channel-peer` for multi-user~~ → **Promoted to 0.7** Phase A (F01-F06). Configurable `dm_scope` + `group_scope` with per-channel overrides. See [0.7 PRD](specs/0.7/prd.md)
- Two-tier privilege model (admin vs sandboxed groups) — relevant when multiple users access the system
- Additional channels via channel interface (see below)

## Slack Integration
_Ref: [multi-user channels research](research/multi-user-channels/research.md)_

- **Architecture**: Dart-native adapter on existing `shelf` server — HTTP Events API endpoint (`/integrations/slack/events`). No sidecar, no Bolt dependency (zero-npm). Socket Mode optional for local dev
- **Streaming**: DartClaw SSE → Slack `chat.startStream`/`chat.appendStream`/`chat.stopStream` (Oct 2025 APIs). Maps almost 1:1 to existing streaming
- **AI App features**: `assistant.threads.setStatus` typing indicator, `assistant.threads.setSuggestedPrompts`, thread titling
- **Session keying**: `thread_ts` → DartClaw session ID. DMs use channel ID. New thread on `app_mention` without `thread_ts`
- **Auth**: Bot token (`xoxb-`) + HMAC-SHA256 signing secret verification (~30 LOC). Scopes: `assistant:write`, `chat:write`, `channels:history`, `im:history`, `im:write`, `app_mentions:read`
- **Rate limits**: 1 msg/sec/channel, 4K chars recommended (40K hard truncation). Streaming avoids single-message length issues
- **Multi-user**: native @mention, stable user IDs, first-class threads = natural session isolation
- **Priority**: Second channel for multi-user (best platform support, native AI features, no policy risk)

## ~~Google Chat Integration~~ — PROMOTED to 0.8
_Core channel promoted to [0.8 PRD Phase F](specs/0.8/prd.md) (F29-F39). Ref: [Google Chat research](research/google-chat-integration/research.md)_

Remaining future extensions (not in 0.8):
- **Cards v2**: Rich structured UI for search results, status dashboards
- **Slash commands**: `APP_COMMAND` events — `/new`, `/reset`, `/status`
- **Outbound attachment upload**: Send files/images to spaces
- **Multi-account**: Multiple service accounts for multi-org deployments
- **Workspace Add-on token format**: Alternative auth path for Add-on deployments

## Observability Integrations

_Ref: [Agent observability research](research/agent-observability/research.md) — PAI model, Langfuse/OTEL Gen-AI/AgentOps/Arize Phoenix analysis, DartClaw gap analysis (2026-03-14)_

**Foundation (0.next-projects Phase H):** Turn-level trace persistence, cost calculation, and budget enforcement. See [0.next-projects PRD Phase H](specs/0.next-projects/prd-draft.md).

**Post-0.next-projects observability features** (R5-R12 from research, ordered by priority):

- **Historical trace query API** (`GET /api/traces`) — Query the `turns` table with filters: `?taskId=`, `?sessionId=`, `?runnerId=`, `?since=`, `?until=`, `?limit=`, `?offset=`. Returns structured turn records with tokens, cost, latency, and tool calls. Enables dashboards to show historical cost burn, turn latency trends, tool failure patterns. Prerequisite: 0.next-projects F33 (turn trace persistence). _Ref: Langfuse trace query API, LangSmith run filtering_
- **Phase-level timing spans** — Record wall-clock timestamps in `TurnRunner` at: turn start, first token received (TTFT), last token, turn end. Include in turn trace record. TTFT is the primary UX latency indicator for streaming sessions. Extend to planning vs tool-execution vs generation breakdown for multi-step turns. _Ref: OTel `gen_ai.server.time_to_first_token` metric_
- **Per-tool analytics API** (`GET /api/tools/stats`) — Compute aggregates from the `turns` table: per-tool invocation count, success rate, P50/P95 latency, error type breakdown. Queryable by time range, task type, runner. Surfaces tool reliability bottlenecks. Prerequisite: 0.next-projects F31 (tool call records in turn traces). _Ref: Portkey tool observability taxonomy_
- **Evaluation scores on tasks** — `task_scores` SQLite table: `{id, task_id, name, value, category, source (human|llm|system), comment, created_at}`. Modeled on [Langfuse scores](https://langfuse.com/docs/observability/data-model). `TaskReviewService.accept/reject` already produces the human judgment signal — persisting it as a structured score creates a quality history. Extend with optional LLM-as-judge scoring (Haiku-class, async) on task completion for automated quality assessment. Foundation for offline evaluation datasets.
- **Execution timeline / waterfall UI** — Collapsible "Execution Timeline" section on `/tasks/<id>` detail page. Horizontal waterfall rendering turn records and tool calls using CSS grid + HTMX polling. Each row: tool name or "LLM call", start time (relative to task start), duration bar, token count, cost, success/error indicator. Pure HTMX + CSS, consistent with Trellis architecture. _Ref: AgentOps Session Waterfall, [AgentPrism](https://github.com/evilmartians/agent-prism) Timeline/Gantt view_
- **Live activity pulse on `/tasks`** — Compact per-runner status indicator on the task list page: color-coded badges (green=idle, amber=busy, red=error) with current task title and elapsed time. Updates via existing SSE `agent_state` events. Eliminates manual `/api/agents` polling. _Ref: [disler/claude-code-hooks-multi-agent-observability](https://github.com/disler/claude-code-hooks-multi-agent-observability) live pulse chart_
- **Offline evaluation dataset from task reviews** — When a task is rejected with a reason, store `{taskSpec, agentOutput, reviewOutcome, reason}` as an evaluation record. `GET /api/evals/dataset` endpoint returning these records. Creates a regression test dataset from production judgments — the starting point for automated quality gates. _Ref: Braintrust offline+online eval loop, Arize "Closing the Loop"_
- **OTEL export (opt-in)** — Map DartClaw's turn traces to [OpenTelemetry Gen-AI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/) (`invoke_agent` → `execute_tool` → inference span hierarchy). Minimal OTLP/HTTP JSON exporter — no gRPC dependency. Enables shipping traces to Langfuse, Arize Phoenix, Grafana Tempo, Datadog. Configured via `observability.otel.endpoint` in `dartclaw.yaml`. The internal trace schema (0.next-projects F33) is already modeled on OTEL conventions, making this a serialization step rather than a data model change.

**Pre-existing items (retained):**

- **ObservabilitySink** abstract class: `onTurnStart()`, `onTurnEnd()`, `onToolCall()`, `onLlmInput()`, `onLlmOutput()`, `onGuardVerdict()`, `onError()` — subsumes into the OTEL export + event bus pattern above. May not need a separate abstraction if the EventBus + turn traces cover all use cases.
- ~~**Session disk budget**~~ — **Promoted to 0.7** Phase B (F08-F11). See [0.7 PRD](specs/0.7/prd.md)

## Cost-Based Budget Enforcement

_Added 2026-04-01. 0.15 ships tokens-only budget enforcement (`Task.maxTokens`). Cost-based budgets (`maxCostUsd`) deferred because cost reporting is not universal across harnesses._

**Problem**: The `AgentHarness.supportsCostReporting` capability flag is only `true` for `ClaudeCodeHarness`. `CodexHarness` has `supportsCostReporting: false`, meaning `TurnRunner._updateSessionCost()` records `estimated_cost_usd: 0.0` for Codex tasks. A `maxCostUsd` budget would silently never trigger on Codex-executed workflow steps — worse than no budget at all.

**Tokens as universal currency**: Both harnesses report `input_tokens` and `output_tokens` reliably. Token-based budgets work consistently regardless of provider. Users who need dollar-based limits can derive them from their model's per-token pricing.

**Future path to cost-based budgets** (two options, not mutually exclusive):

1. **Codex cost reporting**: If/when the Codex CLI reports `total_cost_usd` in its turn-complete events, flip `supportsCostReporting` to `true` and cost data flows through the existing `session_cost` KV infrastructure. Zero DartClaw changes needed beyond the flag flip.

2. **Token-to-cost estimation**: Build a `CostEstimator` that maps `(provider, model, input_tokens, output_tokens, cache_read_tokens)` → `estimated_cost_usd` using known per-model pricing tables. This gives approximate cost even for providers that don't report it natively. Pricing tables would need periodic updates (config-driven or fetched). Complexity: medium — the estimation logic is simple, but keeping pricing current adds maintenance burden.

**When to revisit**: When DartClaw adds a third provider class, or when Codex starts reporting cost, or when users request dollar-based budgets. The `Task` model can gain `maxCostUsd` without breaking changes (nullable field addition).

**Prerequisite for implementation**: Either option 1 (upstream fix) or option 2 (estimation layer). The `TaskExecutor` budget check infrastructure from 0.15 is designed to be extended — adding a cost dimension is a small increment once the data is available.

## Desktop App (Tauriel)
_Ref: [Tauriel research](research/templating-and-gui-app/04-tauriel.md) · [GUI options](research/templating-and-gui-app/03-dartclaw-gui.md) · [FFI deep-dive](research/templating-and-gui-app/05-pure-ffi-deep-dive.md)_

Native desktop app using **Tauriel** — a Dart-based Tauri analog. AOT-compiled Dart backend + OS-native webview (WKWebView/WebView2/WebKitGTK), rendering with Trellis templates + HTMX. Cross-platform (macOS first, Linux/Windows follow). Work has started on Tauriel as an independent framework.

- **Architecture**: Shelf HTTP server (localhost) + webview shell. IPC via HTTP + SSE (no custom JS bridge). DartClaw's existing web UI runs unmodified inside the webview — same templates, same HTMX, same CSS
- **Menu bar integration**: macOS tray icon with quick actions (new session, status, recent sessions)
- **Why not Flutter**: Tauriel aligns with DartClaw's philosophy (zero npm, AOT, minimal deps). Reuses the existing web UI stack instead of reimplementing in Flutter widgets. Smaller binary (~8-12 MB vs ~20-30 MB with Flutter)
- **Trellis templates**: Tauriel uses Trellis (Dart Thymeleaf-inspired template engine) for server-side rendering. Trellis is a standalone pub package, usable independently of Tauriel
- **Effort**: Tauriel v0.1 (macOS webview + Shelf IPC) is tractable; pure FFI shell deferred to v0.2+ (see FFI deep-dive)

## ~~Guard Audit Log~~ — PROMOTED TO 0.6
_Moved to [0.6 PRD](specs/0.6/prd.md) (Phase B: F06–F08). Persistent audit storage + Web UI viewer on health dashboard._

## Live Config — Hot-Reload (Tier 3)

Full config hot-reload without process restart. Builds on Tier 1 (0.5) runtime toggles and Tier 2 (0.6) persistent config editing.

### Problem

Tier 2 (0.6) enables editing `dartclaw.yaml` from the Web UI but most changes require a restart. This causes brief downtime, drops active SSE connections, and interrupts any in-flight turns. For a daily-driver personal assistant that should be always-on, restart-free config changes are the ideal.

### Approach

- **Reactive config holder** — `ConfigNotifier` (similar to Flutter's `ValueNotifier`) that holds the current `DartclawConfig` and notifies listeners on change
- **SIGUSR1 signal handler** — catches `SIGUSR1`, re-reads `dartclaw.yaml`, diffs against current config, pushes changes through `ConfigNotifier`
- **File-watch mode** — optional `gateway.reload.mode: "auto"` watches `dartclaw.yaml` for changes (inotify/kqueue) and triggers reload automatically
- **Service `reconfigure()` protocol** — each service implements `Reconfigurable` interface with `reconfigure(ConfigDelta delta)` method. Only receives the fields that changed
- **Non-reloadable fields** — `port`, `host`, `data_dir` cannot change without restart. `ConfigNotifier` rejects changes to these fields and logs a warning

### Service Reconfigurability Matrix

| Service | Reconfigurable | Fields | Complexity |
|---------|:-:|---|---|
| `HeartbeatScheduler` | ✅ | interval, enabled | Low — restart timer |
| `WorkspaceGitSync` | ✅ | enabled, pushEnabled | Low — toggle flag |
| `ScheduleService` | ✅ | jobs list | Medium — diff jobs, add/remove |
| `SessionLockManager` | ✅ | maxParallelTurns | Low — update semaphore |
| `SessionResetService` | ✅ | resetHour, idleTimeout | Low — reschedule timer |
| `TurnManager` | ✅ | workerTimeout | Low — update timeout value |
| `ContextMonitor` | ✅ | reserveTokens | Low — update threshold |
| `ResultTrimmer` | ✅ | maxResultBytes | Low — update limit |
| `MessageRedactor` | ⚠️ | redactPatterns | Medium — recompile regexes |
| `InputSanitizer` | ⚠️ | extra_patterns | Medium — recompile regexes |
| `GuardChain` | ❌ | guard config | High — rebuild chain |
| `HarnessConfig` | ❌ | model, maxTurns, etc. | High — active harness can't change mid-session |
| `WhatsAppChannel` | ❌ | channel config | High — reconnection logic |
| `SignalChannel` | ❌ | channel config | High — reconnection logic |
| HTTP server binding | ❌ | port, host | Impossible without restart |

### Implementation Sketch

```dart
abstract interface class Reconfigurable {
  /// Apply config changes. Called by ConfigNotifier when relevant fields change.
  void reconfigure(ConfigDelta delta);
}

class ConfigDelta {
  final Map<String, (dynamic old, dynamic new_)> changes;
  bool hasChanged(String key) => changes.containsKey(key);
}

class ConfigNotifier {
  DartclawConfig _current;
  final List<(Reconfigurable, Set<String>)> _listeners = [];

  void register(Reconfigurable service, Set<String> watchedKeys) { ... }

  Future<void> reload() async {
    final newConfig = DartclawConfig.load(_configPath);
    final delta = _diff(_current, newConfig);
    if (delta.changes.isEmpty) return;

    // Reject non-reloadable changes
    for (final key in ['port', 'host', 'data_dir']) {
      if (delta.hasChanged(key)) {
        log.warning('$key cannot be changed without restart');
        delta.changes.remove(key);
      }
    }

    _current = newConfig;
    for (final (service, keys) in _listeners) {
      if (keys.any(delta.hasChanged)) {
        service.reconfigure(delta);
      }
    }
  }
}
```

### Web UI Integration

- Tier 2 restart-required banner replaced with immediate-apply for reconfigurable fields
- Non-reloadable fields still show ⚠ restart indicator
- Config save → `ConfigNotifier.reload()` → affected services reconfigure → UI confirms "Applied"
- No downtime, no dropped connections

### Prerequisites

- Tier 2 (0.6) config write API and YAML writer
- Service constructor refactoring to accept `ConfigNotifier` instead of static values
- Signal handler infrastructure (`ProcessSignal.sigusr1.watch()` in Dart)

### Effort

Large. Requires touching every service's constructor + adding `Reconfigurable` implementations. The `ConfigNotifier` + `ConfigDelta` infrastructure is moderate; the per-service work is spread across many files. Guard chain and channel reconnection are the hardest parts (marked ❌ above — likely stay restart-required even in Tier 3 v1).

### References

- [0.5 PRD](specs/0.5/prd.md) — Tier 1: runtime toggles
- [0.6 PRD](specs/0.6/prd.md) — Tier 2: persistent config editing
- [0.6 PRD](specs/0.6/prd.md) — predecessor milestone

## ~~Guard Configuration Editor (Web UI)~~ — PLANNED for 0.17 Phase C

Full read-write guard editor in the Web UI. Builds on 0.6's read-only guard detail viewer (F12) and guard audit log (F06-F08).

- **Per-guard rule management**: add/remove/edit rules for CommandGuard, FileGuard, NetworkGuard, InputSanitizer
- **CommandGuard editor**: autocomplete for known command names, pattern builder for glob/regex, allow/deny toggle per rule
- **FileGuard editor**: path picker (shows data dir tree), access level dropdown (read/write/none), glob pattern builder
- **NetworkGuard editor**: host/port input with validation, IP range builder, default policy toggle (allow/deny)
- **InputSanitizer editor**: pattern category toggles (instruction override, role-play, prompt leak, meta-injection), custom pattern input with live regex validation, test input field ("Would this message be blocked?")
- **Pattern tester**: input a test string → show which guards would trigger and why. Essential for debugging false positives
- **Validation**: regex compilation check before save, duplicate rule detection, conflict detection (e.g., allow + deny same path)
- **Persistence**: writes to `guards` section in `dartclaw.yaml` via Tier 2 config writer. Restart-required (guard chain rebuild — unless Tier 3 hot-reload is implemented)
- **Prerequisites**: 0.6 F12 (guard detail viewer), Tier 2 config write API, ideally Tier 3 `GuardChain` reconfigurability (otherwise changes need restart)

## Automated Browser E2E Tests
_Ref: [E2E test strategy research](research/e2e-test-strategy/research.md) · [testing strategy](guidelines/TESTING-STRATEGY.md) · [UI smoke test](../dartclaw-public/dev/testing/UI-SMOKE-TEST.md)_

DartClaw has 132+ test files at Layers 1–3 (unit/component/handler) but zero automated browser tests. All JS-driven interactions (HTMX OOB swaps, SSE DOM updates, localStorage, responsive layout) are verified only through the 24-case manual smoke test suite. The v0.13.1 E2E test uncovered a P2 bug (`data-tasks-enabled` not rendered on session pages) that handler tests could not catch.

- **Dart `puppeteer` package** (recommended) — browser E2E tests in `dartclaw_server/test/e2e/`, tagged `@Tags(['e2e'])`, skipped by default. Fully Dart-native, no Node.js. Uses `DartclawServerBuilder` to start a programmatic server on a random port
- **Real HTTP integration tests** (supplement) — `test/http/` tagged `http_integration`. Cookie auth round-trip, SSE connection headers, redirect chains over real TCP. No browser needed
- **13 of 24 smoke TCs automatable**: auth flows (TC-01, TC-02), structural checks (TC-04–06, TC-10, TC-11), interactions (TC-12, TC-14–16), JS-driven flows (TC-22, TC-23). 11 stay manual (visual, stateful, subjective)
- **Fixture strategy**: programmatic server with ephemeral temp dirs for isolation, not the static `plain` testing profile

## Production Hardening
- ~~**Config hot-reload** — SIGUSR1 signal reloads config without restart. File-watch mode (`gateway.reload.mode: "auto"`)~~ → see [Live Config Tier 3](#live-config--hot-reload-tier-3) above
- **`dartclaw security audit`** — security posture scan: guard configs, file permissions, exposed ports, credential storage, Docker network config. `--deep` mode queries running gateway. `--fix` applies recommended guardrails. _Ref: OpenClaw `openclaw security audit`_
- Egress firewall rules
- ~~Tailscale Serve integration for remote access~~ → promoted to standalone section. See [Tailscale Integration](#tailscale-integration) below
- Emergency shutdown procedures
- Multi-gateway via profiles: separate state directories (`~/.dartclaw-<profile>/`), one service per profile, port spacing (≥20 gap)

## Configuration Management Extensions

Builds on 0.6 Tier 2 config editing and fills the admin gaps left intentionally out of scope there.

- **Channel config editor**: edit non-access channel settings such as endpoints, sidecar options, verification methods, and reconnect-sensitive values from the Web UI
- **Container config editor**: edit container image, mount policy, and isolation options with explicit restart and validation flow
- **Rollback and change history**: keep a bounded config history with diff view and one-click restore, not just a single `.bak`
- **Multi-file config support**: optional `include` support for splitting large deployments into smaller YAML fragments while preserving validation and effective-config inspection
- **Effective-config view**: show merged runtime config, restart-required fields, and source-of-truth for each value

## Memory Editing & Retrieval Transparency

Builds on 0.6's memory dashboard, which is intentionally read-only.

- **Memory content editing**: safe operator editing for `MEMORY.md`, archive files, and self-improvement files with conflict-aware writes
- **Per-turn retrieval trace**: show which memories or search hits were injected or surfaced during a turn
- **Source attribution**: link retrieved snippets back to their file and section from the dashboard or review UI
- **Guardrails**: preserve parser expectations, timestamps, and prune/archive semantics when edits are made through the UI

## Temporal Memory Tracking (`superseded_at`)
_Ref: [personal-ai-pkm-landscape research](research/personal-ai-pkm-landscape/research.md) · Inspired by Zep temporal knowledge graph and Mem0 graph+vector hybrid_

> **Update 2026-04-10**: The lightweight temporal KG approach (see [temporal-knowledge-graph research](research/temporal-knowledge-graph/research.md)) subsumes and extends this item. The `superseded_at` column on `memory_chunks` remains a valid incremental improvement for raw memory entries, but the temporal KG provides a proper structured-fact layer with entity-relationship triples, time-validity windows, and relationship traversal — all in two SQLite tables (~1000 LOC). **Promoted to 0.17 Phase B**. The `superseded_at` column could still be added independently as a complementary improvement to `memory_search` ranking.

The cheapest meaningful step from Tier 1 memory (keyword/vector search) toward Tier 2 (temporal knowledge graph) — without introducing external dependencies.

- **`superseded_at` column on `memory_chunks`**: nullable timestamp. When a newer memory entry contradicts or updates an older one, the older entry is marked superseded. Not deleted — still searchable, but ranked lower and annotated as superseded in retrieval results
- **Supersession detection**: agent includes `supersedes: <chunk_id>` metadata when calling `memory_save` for facts that update previous knowledge. Deterministic — no LLM classification needed at write time
- **Query semantics**: `memory_search` filters superseded entries by default (`WHERE superseded_at IS NULL`). Optional `include_superseded: true` parameter for "what changed?" queries
- **Conflict surfacing**: when the agent retrieves a non-superseded memory that contradicts the current conversation, it can flag the conflict: "Your memory says X, but you just said Y — should I update?"
- **Migration**: additive schema change — single `ALTER TABLE` on `memory_chunks`. No data migration needed
- **Value**: enables temporal reasoning ("what did we decide about X, and has it changed?") — the #1 limitation of flat keyword search. Mem0 reports ~10% improvement on multi-hop/temporal queries with graph+vector vs. pure vector

**What this is NOT**: a full knowledge graph. No entity extraction, no relationship types, no graph queries. Just temporal awareness on existing memory entries. The temporal KG (0.17) provides the full structured-fact layer.

**Prerequisites**: existing `memory_chunks` SQLite table in `dartclaw_storage`

## Epistemic Extraction (Distiller)
_Ref: [personal-ai-pkm-landscape research](research/personal-ai-pkm-landscape/research.md) · Inspired by Alfred's Distiller worker_

Background job that reads recent conversation history and extracts latent knowledge — decisions, assumptions, constraints, contradictions — that the user never explicitly captured via `memory_save`. Surfaces the "dark knowledge" buried in conversation transcripts.

- **Distiller cron job**: configurable schedule (e.g., nightly or weekly). Reads recent session transcripts (last N days, configurable). Agent turn with focused prompt: "Extract decisions, assumptions, constraints, and contradictions from these conversations"
- **Output categories**: each extracted item tagged as `decision`, `assumption`, `constraint`, `contradiction`, or `synthesis`. Written to memory via `memory_save` with `source: distiller` metadata for provenance tracking
- **Scope constraints**: Distiller agent session uses existing `TaskFileGuard` extended with **operation-type constraints** — create-only (no edit, no delete). Maps Alfred's scope-enforcement-as-security-primitive pattern to DartClaw's existing guard architecture
- **Dedup against existing memory**: before writing, Distiller checks `memory_search` for semantic overlap. Skips items already captured (either by user or by previous Distiller runs)
- **Synthesis reports**: periodic (weekly/monthly) synthesis that reads accumulated Distiller outputs and produces a structured summary — "Key decisions this month", "Unresolved contradictions", "Recurring assumptions". Written to `workspace/distiller/` as timestamped markdown files
- **Opt-in**: disabled by default. Configured via `intelligence.distiller` section in `dartclaw.yaml`

**Relationship to 0.17 Phase B**: Distiller complements inbox-drop ingestion (F30) — inbox handles external knowledge, Distiller handles internal knowledge. Both use the same `memory_save` pipeline. Could share the same cron schedule

**Effort**: Medium. Core is a specialized cron job type (~100 LOC for the job + prompt template). Scope-constrained TaskFileGuard extension is reusable infrastructure. The quality of extraction depends heavily on prompt engineering

## Tailscale Integration
_Ref: [supporting document](specs/0.next-headless-access/tailscale-integration.md) · [initial research](ideas/tailscale-integration.md) · [ADR-006](adrs/006-http-auth-scope.md) (tunnel-safe auth)_

Secure remote access to DartClaw's Web UI, API, and health dashboard from any device on the user's Tailscale mesh network — without opening firewall ports, managing TLS certificates, or exposing the gateway to the public internet. Also enables webhook ingress (WhatsApp, Signal) via Funnel.

**Deployment scenarios**: always-on home server (Mac Mini/NUC/RPi), zero-public-port VPS, webhook ingress for external services.

### Features

| # | Feature | What It Does | Complexity |
|---|---------|-------------|------------|
| **T1** | Serve/Funnel Automation | `tailscale serve` on startup, reset on shutdown. Prints Tailscale URL alongside local URL. Funnel safety gate (requires token auth) | Low |
| **T2** | Identity Verification | Tokenless Web UI access for tailnet users. Whois-verified identity headers (fail-closed). Session cookie on success | Medium |
| **T3** | Connection Keep-Alive | Periodic `tailscale ping` prevents DERP relay staleness on idle connections | Low |

### Key Design Decisions

- **Serve-only, no direct-IP bind** — avoids the class of TLS/bind bugs OpenClaw hit (#1380, #30990). Tailscale Serve handles HTTPS termination
- **Whois verification is mandatory** (fail-closed) — fixes OpenClaw's header injection vulnerability (#13153) where loopback + header presence was sufficient. DartClaw cross-checks headers against the local Tailscale daemon
- **Local API over Unix socket** (not CLI subprocess) — ~1-5ms vs ~50ms per call. Dart `HttpClient` supports Unix sockets. Falls back to CLI if socket unavailable
- **`allowIdentity: false` by default** — because DartClaw runs agent tools on the same host; a compromised tool could forge loopback requests. Opt-in for users who understand the trust model
- **Funnel requires token auth** — Funnel traffic is public (no identity headers). Hard gate at startup prevents accidental exposure

### Config

```yaml
gateway:
  tailscale:
    mode: off              # off | serve | funnel
    resetOnExit: false     # Undo serve/funnel on clean shutdown
    httpsPort: 443         # 443, 8443, or 10000
    allowIdentity: false   # Trust Tailscale identity for Web UI sessions
    keepAlive:
      enabled: false
      intervalSeconds: 300
      peers: auto          # "auto" or explicit hostname list
```

### Improvements Over OpenClaw

- Whois verification mandatory (not optional/header-only)
- Local API instead of CLI (lower latency)
- Keep-alive (OpenClaw doesn't implement this)
- No direct-IP bind mode (eliminates bind/TLS bug class)
- ACL guidance included (OpenClaw leaves this to community posts)

### ACL Recommendation

Tag the DartClaw machine `tag:dartclaw`. Allow inbound on port 443 from `autogroup:member`. No outbound grants — prevents lateral movement if agent is compromised. Detailed ACL examples in [supporting document](specs/0.next-headless-access/tailscale-integration.md#acl-recommendations).

### Prerequisites

- Auth system: ADR-006 (implemented) — tunnel-safe by design
- Tailscale installed on the host machine (graceful degradation if absent)
- `mode: "serve"` or `"funnel"` in config (off by default)

## Multi-User Deployment
_Ref: [multi-user channels research](research/multi-user-channels/research.md)_

- Separate OS users per channel/identity (UID-enforced filesystem boundaries). Each instance gets separate state dir, gateway token, port, auth profiles
- VM isolation option (Lume VM for macOS, Multipass for Linux). Docker inside VM for strongest posture
- **Session isolation**: `per-channel-peer` scope as default — one session per sender + channel. Configurable: `per-peer` (cross-channel), `per-account-channel-peer` (most isolated)
- **Identity links**: map provider-specific peer IDs to canonical identity for cross-channel session coalescing (e.g., Alice's WhatsApp + Slack → single session)
- **Tool-based role restriction**: per-agent tool policies (not RBAC). Channel agents deny `exec`, `process`, `browser` — delegate privileged ops to main via `sessions_send`. Leverages existing `disallowedTools` SDK passthrough
- **Memory namespace isolation**: `user_id` column on `memory_chunks` table (added in 0.8 as forward-compatible preparation). Filter all queries by user context. Per-user MEMORY.md files
- **Channel identity resolution**: map `(channelId, senderId)` → `(userId, role)` at Dart host layer before session creation
- **Token budget tracking**: per-user daily/hourly token limits. Aggregate existing per-session cost counters. Enforce before dispatching to agent harness. Three-tier: global budget, per-user budget, per-function budget
- **Session workspace isolation**: per-session directories with file-guard enforcement. Docker bind mounts per session
- **Channel-guard becomes mandatory**: with untrusted senders, ML injection scanning (DeBERTa ONNX, ~370MB) moves from nice-to-have to required

### Multi-User Implementation Sequence
1. Memory namespace isolation (schema preparation)
2. Channel identity resolution
3. `disallowedTools` per role
4. Session workspace isolation
5. Token budget tracking
6. Channel-guard deployment
7. Google Chat adapter (first — simplest, pure REST)
8. Slack adapter

## Computer Use (VM Interaction)
- **7 VM tools** via Lume VM + WebSocket to `cua-computer-server`: `vm_screenshot`, `vm_exec`, `vm_click`, `vm_type`, `vm_key`, `vm_launch`, `vm_scroll`. Requires Apple Silicon + Lume
- Lazy WebSocket singleton, mutex-serialized commands
- Screenshot loop pattern: screenshot → analyze → click → type → repeat
- _Ref: OpenClaw `extensions/computer-use/`_

## WhatsApp Group Chat — Policy Warning
_Ref: [multi-user channels research](research/multi-user-channels/research.md)_

- **Meta AI chatbot ban (Jan 15, 2026)**: Meta banned general-purpose AI chatbots from WhatsApp Business API. DartClaw likely qualifies as "primary AI functionality" — banned on official API. Under EU antitrust scrutiny
- **Official Groups API**: Max 8 participants, 100K+ conversations/month eligibility. Unsuitable for multi-user at scale
- **Unofficial path (whatsmeow/GOWA)**: Full group support for personal single-user use (shipped scope). Not suitable as foundation for multi-user product due to ban risk, supply-chain concerns
- **Recommendation**: For multi-user, prioritize Slack and Google Chat. WhatsApp groups only viable for small personal use via unofficial API

## ~~Signal Integration~~ — IMPLEMENTED (0.4)
_Implemented in 0.4 Phase D (S11–S12). Ref: [signal-cli research](research/signal-integration/research.md)_

Remaining Signal gaps tracked in 0.5 Phase F (TD-022 formatResponse chunking, TD-023 config-driven access, TD-024 voice verification) and Phase E (S14 E2E verification).

## Telegram Integration
- Channel adapter using Grammy library (Dart). Channel interface abstraction from shipped scope makes this a straightforward addition
- Send/receive text messages, bot API integration
- Inline button support, group chat support
- _Was originally planned; deferred because WhatsApp is the must-have channel_

## CLI REPL (`dartclaw chat`)
- Interactive REPL for terminal-based chat sessions
- Slash commands: `/new [model]`, `/reset`, `/compact [instructions]`, `/status`, `/stop`
- Extensible command registry for future additions
- _Was originally planned; deferred because web UI + WhatsApp covers daily-driver surfaces_

## `dartclaw doctor --fix`
- Config + dependency validation: claude binary, Docker, DB connectivity, config syntax, file permissions
- Auto-fix mode for common issues (permissions, missing dirs, config defaults)
- _Ref: OpenClaw `openclaw doctor`_
- _Was originally planned; deferred because guards + deployment tooling cover current validation needs_

## Feedback Signals & Behavioral Learning
_Inspired by PAI's SIGNALS system. Ref: [PAI research](research/pai-personal-ai-infrastructure/research.md)_

- **Implicit sentiment detection**: hook on user messages detects frustration/satisfaction expressions → records with confidence score. Haiku-class inference on every user message, async/non-blocking. Appends to `signals.ndjson`
- **Explicit rating capture**: user rates responses (thumbs up/down) → append to NDJSON signal log. Web UI rating widget + full failure capture on low ratings
- **Failure context dumps**: low ratings (≤3) automatically capture full session context to `failures/` directory for later analysis
- **Signal storage**: NDJSON append-only log (`signals.ndjson`)
- **Steering rule derivation**: periodic analysis of failure patterns → auto-generated behavioral rules injected into SOUL.md or equivalent
- **Web UI integration**: simple rating widget, weekly synthesis report display

## Push Notifications (ntfy.sh)
_Inspired by PAI's ntfy integration. Deferred — channel system alerts (0.16 Phase B) cover the primary notification use case using existing channel infrastructure. Add ntfy.sh if channel alerts prove insufficient for scenarios where no messaging channel is configured._

- **ntfy.sh integration**: fire-and-forget HTTP POST to ntfy topic → instant mobile notification
- **Duration-aware escalation**: short tasks = silent; long tasks = notification on completion
- **Configurable triggers**: task completion, errors, scheduled task results, channel messages when away
- **Self-hosted option**: ntfy server can run alongside DartClaw in Docker Compose
- **Priority-based batching**: critical=immediate, high=hourly, medium=3-hourly — prevents notification spam
- **Zero dependency**: single HTTP POST, no SDK needed
- **When to reconsider**: if users want push for web-originated tasks without any channel configured, or if channel-based alerts have delivery reliability issues

## ~~Extended Identity Context (TELOS)~~ — PROMOTED to 0.17
_Inspired by PAI's TELOS system (v4.0: GOALS.md, BELIEFS.md, CHALLENGES.md, BOOKS.md, FRAMES.md, WISDOM.md, AUTHORS.md). Ref: [PAI research](research/pai-personal-ai-infrastructure/research.md)_

**Promoted to 0.17 Phase A (F01)** — but as an **expanded USER.md** rather than separate TELOS files. See [0.17 PRD](specs/0.17/prd.md#design-usermd-identity-context) for the design rationale.

**Decision**: DartClaw consolidates TELOS into USER.md structured sections (Identity, Goals, Current Challenges, Preferences, Not Relevant) because: (a) DartClaw has searchable memory (`memory_search`) for long-tail content, unlike PAI which must inject everything via files; (b) fewer files = simpler mental model; (c) high-signal content (goals, challenges) belongs in every turn's context, while long-tail content (books, influences, detailed beliefs) belongs in searchable memory entries.

- ~~**Structured identity files**: GOALS.md, PROJECTS.md, BELIEFS.md, STRATEGIES.md, IDEAS.md~~ → consolidated into USER.md sections
- ~~**Auto-referencing**: agent consults relevant files based on task type~~ → USER.md loaded every turn; long-tail content in `memory_search`
- ~~**Living documents**: agent can suggest updates based on conversations~~ → **Promoted**: SOUL.md behavioral instruction to suggest USER.md updates
- **Clean separation**: user identity files never modified by system upgrades — preserved (USER.md is user-owned)

## ~~Inbox-Drop Knowledge Ingestion~~ — PROMOTED to 0.17
_Inspired by Alfred's Curator worker + user-profile relevance filtering. Ref: [0.17 PRD Phase B (F03)](specs/0.17/prd.md#design-inbox-ingestion)_

**Promoted to 0.17 Phase B (F03).** An `inbox/` directory in the workspace watched by a cron job. Files dropped into `inbox/` are processed by a Curator-style agent turn: classify content, extract structured records (tasks, people, action items, decisions, key facts), write to memory via `memory_save`, move processed files to `inbox/processed/`. The agent uses USER.md context (especially "Not Relevant" section) for relevance filtering. Supports plain text, markdown, PDF (via `pdftotext` outpost), JSON, NDJSON.

## Work Memory (Structured Task Units)
_Inspired by PAI's Tier 2 Work Memory. **Note**: significant overlap with [Task Orchestrator](#task-orchestrator--dashboard-extensibility) — the task model's `TaskArtifact` and lifecycle states subsume most of what Work Memory describes. Consider merging into the task orchestrator rather than implementing independently._

- **Per-task directories**: persistent work units with metadata, artifacts, research, and verification evidence
- **Task lifecycle**: DRAFT → IN_PROGRESS → VERIFYING → COMPLETE with timestamps
- **Cross-session persistence**: tasks survive session boundaries — resume where you left off
- **Verification evidence**: each completed task stores proof of completion (test output, screenshots, etc.)
- **Complements session memory**: sessions = conversation history; work memory = structured task state
- **Storage**: file-based (JSON/NDJSON), consistent with existing storage patterns

## ~~Task Workflow Refinements~~ — PARTIALLY PROMOTED to 0.10

Post-0.8 refinements to the shipped task system. The three major additions (Projects, Workflows, Task Timeline) and three tactical refinements (inline review, autonomy dial, auto-retry) are **promoted to [0.10 PRD](specs/0.10/prd.md)**. Remaining items stay Future.

### Promoted to 0.10

- ~~**Inline plan review**~~: Kintsugi-style comments and anchored review feedback over plans, diffs, or documents → **0.10 Phase F (F37)**
- ~~**Per-task autonomy dial**~~: task-specific limits for allowed tools, review strictness, and execution posture → **0.10 Phase F (F38)**
- ~~**Auto-retry policies**~~: bounded retry or retry-on-pushback rules with loop prevention and explicit token budgeting → **0.10 Phase F (F39)**

### Remaining Future

- **Deep goal ancestry injection**: configurable context depth beyond 0.8's two-level cap
- **Task type registry**: SDK-registered task types with custom forms, artifact collectors, and review renderers
- **Additional execution profiles**: built-in `integration`, `sandbox`, and VM-backed profiles layered on top of 0.8's per-profile container architecture

## Projects (External Git Repositories) — PLANNED for 0.10
_Ref: [0.10 PRD Phase A](specs/0.10/prd.md)_

External codebase support for coding tasks. Currently, `WorktreeManager` only works with the local repo. Projects allow tasks to target external git repos — clone at task start, work in an isolated worktree, push branch and optionally create a PR on accept.

- **`Project` model**: id, name, remoteUrl, defaultBranch, credentials (reference-based, never in config), clone strategy (shallow/full/sparse), PR strategy (branch-only/github-pr/gitlab-mr)
- **`ProjectService`**: CRUD, clone management at `<dataDir>/projects/<id>/`, fetch/update, stale detection
- **WorktreeManager integration**: `create(taskId, {project?})` — when project provided, worktree is created from project clone
- **Push-to-remote + PR creation**: on accept, push branch via `git push origin`, create PR via `gh` CLI (outpost pattern). PR URL stored as artifact
- **Credential security**: reference-based only (`credentials: ssh-key-name`). Resolved at clone/push time via `GIT_SSH_COMMAND` / `GIT_ASKPASS`. Extends existing credential proxy pattern
- **Config**: `projects:` section in `dartclaw.yaml` for declarative definitions + runtime API for CRUD

## Workflow Engine — PLANNED for 0.10
_Ref: [0.10 PRD Phases C-E](specs/0.10/prd.md) · Inspired by [cc-workflows](https://github.com/tolo/claude_code_common) plugin_

Multi-step agent pipelines where each step is executed in a fresh session (clean context) with shared state passed between steps via a `WorkflowContext`. The workflow engine is a **coordinator**, not a new execution engine — each step becomes a `Task` executed by the existing `TaskExecutor`.

- **`WorkflowDefinition`**: name, description, steps list, variables (required/optional). Defined in YAML, loaded from `<workspace>/workflows/` and built-in resources
- **`WorkflowStep`**: id, name, prompt template (`{{variable}}` + `{{context.key}}` refs), task type override, model override, timeout, context inputs/outputs, gate expression, parallel flag
- **`WorkflowContext`**: persistent JSON map accumulated across steps. Each step reads inputs and produces outputs. Convention-based extraction from artifacts (first `.md` → document, `diff.json` → diff summary)
- **`WorkflowExecutor`**: step sequencing — resolve template → create Task → execute → extract outputs → check gate → continue. Sequential and parallel step groups. Pauses on gate failure or step failure for user intervention
- **5 built-in workflows**: spec-and-implement (6-step flagship with gap analysis + remediation), research-and-evaluate (trade-off analysis), fix-bug, refactor, review-and-remediate
- **Custom workflows**: user-defined YAML in workspace, discovered on startup, validated against schema
- **Workflow UI**: picker in "New Task" dialog, run detail page with step pipeline visualization, per-step artifact access, context viewer

### Design Principles (from cc-workflows)
- **Orchestrator never implements** — it delegates to fresh sessions per step, keeping context lean
- **Reference-heavy context** — pass artifact references and summaries, not full content, to avoid prompt bloat
- **Explicit gates** — preconditions between steps prevent incomplete work from cascading
- **Fresh conversation per step** — isolates context per step, prevents accumulation. The `WorkflowContext` is the only bridge

## Task Timeline & Visual Progress — PLANNED for 0.10
_Ref: [0.10 PRD Phase B](specs/0.10/prd.md)_

Event-sourced timeline and live progress indicators for tasks and workflows. Addresses the opacity of the current task UI where only 9 status states are visible.

- **`TaskEvent` model**: event-sourced entries per task — status changes, step transitions, tool calls, artifact creation, push-backs, token updates, errors. Persisted to `task_events` SQLite table
- **Timeline UI**: vertical timeline on task detail page (GitHub PR activity feed style), filterable by event type
- **Live activity indicator**: forward harness stream events to per-task SSE channel. Show current tool call ("Reading src/auth/login.dart") in real-time
- **Progress estimation**: step-based for workflows (step 2/5 = 40%), token-budget-based for single tasks. Progress bar on task detail and task list
- **Multi-task dashboard**: progress bars per task on `/tasks`, token consumption indicator, agent assignment badge, compact timeline preview

## ~~Dedicated Search API Providers~~ — PARTIALLY IMPLEMENTED (0.6)
_Brave Search and Tavily implemented as MCP tools in 0.6 Phase D (`web_fetch` + search tools, `registerTool()` API, ContentGuard integration). Perplexity and SearXNG remain future._

### Remaining Providers

| Provider | Type | Key Feature | API Model |
|----------|------|-------------|-----------|
| **Perplexity** | AI-augmented search | Synthesized answers with citations | API key |
| **SearXNG** | Meta-search (self-hosted) | Privacy-first, aggregates multiple engines, no API key | Self-hosted instance |

SearXNG is notable for privacy-sensitive deployments — no data leaves the network. Can run as Docker Compose sidecar alongside DartClaw.

## Additional Extensions
- **Image generation plugin** — text-to-image via OpenRouter (FLUX, Gemini, GPT models). SSRF protection. _Ref: OpenClaw `extensions/image-gen/`_
- **~~Knowledge graph~~** — ~~structured relationships between memory entries~~ → Lightweight temporal KG promoted to 0.17. See [research](research/temporal-knowledge-graph/research.md). Full Neo4j-scale graph remains Future
- **MCP server hosting** — expose DartClaw services as standalone MCP servers for external tools
- **Skills & plugin bundling** — `plugins` SDK option passthrough, `.claude/agents/` definitions. Implements [ADR-003](adrs/003-coding-task-support-and-agent-extensibility.md) Layer 3. **Design note**: NanoClaw now has **23 skills** and a skills-as-branches architecture (git branches on upstream, CI auto-merge with Haiku, community marketplaces, "Flavors" concept). Their model evolved from skill `.md` files to full git branches merged into the user's fork. Qodo AI partnership provides third-party skills. _Ref: [feature-comparison.md](feature-comparison.md) Extension Model section, [competitor-analysis.md](competitor-analysis.md) NanoClaw section_
- **BOOT.md** — startup automation hooks (run on every gateway start)
- **BOOTSTRAP.md** — first-run onboarding script (run once, then deleted)

---

## Hypervisor-Level Isolation (gVisor / Firecracker)

NanoClaw shipped Docker Sandboxes (Mar 2026) — hypervisor-level micro VMs creating a two-boundary model: Host → Sandbox VM → NanoClaw → Docker-in-Docker → agent containers. This is now arguably stronger raw isolation than DartClaw's Docker `network:none` approach, though DartClaw compensates with the guard pipeline + credential proxy.

**Options (ranked by isolation strength):**

| Technology | Boot Time | Overhead | Isolation | DartClaw Fit |
|---|---|---|---|---|
| gVisor (`runsc`) | ~200ms | 10-30% on I/O | User-space kernel (syscall interception) | Best. Drop-in Docker runtime replacement. `--runtime=runsc` flag |
| Kata Containers | ~500ms | Low | MicroVM (Firecracker/QEMU) | Good. Heavier setup. True VM boundary |
| Firecracker | ~125ms | <5 MiB/VM | Dedicated microVM kernel | Strong. AWS Lambda production-proven. Requires orchestration |
| Fly.io Sprites | 1-2s (300ms restore) | Low | Persistent microVM with checkpoint/restore | Interesting. Deployment target, not self-hosted option |

**Implementation approach**: Offer gVisor as opt-in isolation tier via `containers.runtime: "runsc"` config. No code changes to DartClaw's container management — gVisor is a Docker runtime flag. Document as "enhanced isolation" option in security guide.

**Motivation**: Not about replacing Docker `network:none` but about adding kernel-level isolation on top. gVisor intercepts syscalls in user-space, preventing container escape exploits that bypass Linux namespace boundaries. The combination of `network:none` + credential proxy + gVisor + guard pipeline would be the strongest isolation model in the personal AI assistant space.

_Ref: [Northflank — How to Sandbox AI Agents](https://northflank.com/blog/how-to-sandbox-ai-agents), [NVIDIA — Practical Security for Agentic Workflows](https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/)_

---

## Agent Teams / Auto-Assembly

Proma (297 stars, Mar 2026) demonstrated **Agent Teams auto-assembly** — automatically sizing a multi-agent team based on task complexity. OpenClaw shipped Agent Teams (experimental, `TeammateIdle`/`TaskCompleted` hooks). NanoClaw supports SDK Swarms.

DartClaw's `HarnessPool` + `TaskService` infrastructure can support a similar pattern:

- **Simple tasks** (research, writing) → single harness, sequential execution
- **Medium tasks** (coding with review) → primary harness + review harness
- **Complex tasks** (workflow steps) → multiple parallel harnesses with step coordination

**Implementation sketch**: `AgentTeamResolver` service that examines task type, goal complexity, and available pool capacity to determine harness count and agent configurations. Each harness gets a tailored `--agents` JSON definition. Team coordination via `EventBus` (existing 0.7 infrastructure).

**Prerequisite**: `--agents` flag adoption (deferred from 0.10), workflow engine maturity. Evaluate after 0.10 workflows prove multi-step patterns.

_Ref: [Proma Agent Teams](https://github.com/ErlichLiu/Proma), OpenClaw `TeammateIdle`/`TaskCompleted` hooks, Claude Agent SDK `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`_

---

## `sessions_yield` Equivalent

OpenClaw shipped `sessions_yield` (v2026.3.12) — an orchestration primitive that lets an orchestrator end the current turn immediately, skip queued tool work, and carry a hidden follow-up payload into the next session turn. This enables clean multi-step coordination within a single session.

DartClaw's current model uses separate sessions per workflow step (0.10 Phase E), which avoids needing `sessions_yield`. However, for push-back loops and complex single-session orchestration, a similar primitive would be useful:

- **`TurnRunner.yield(payload)`** — end current turn, store follow-up in session metadata, auto-trigger next turn with payload injected
- **Use cases**: Multi-stage tool approval chains, deferred work after partial completion, explicit "checkpoint and continue" semantics

**Evaluate after 0.10** — if workflow engine's fresh-session-per-step model proves sufficient for all orchestration needs, `sessions_yield` may be unnecessary. Monitor user feedback.

_Ref: OpenClaw `sessions_yield` (v2026.3.12)_

---

## MCP Elicitation Support

Claude Agent SDK v2.1.76 added MCP Elicitation — MCP servers can now request structured mid-task input via interactive dialog. The `claude` binary emits `Elicitation` hook events; the host intercepts and presents a form-style input UI.

DartClaw should intercept `Elicitation`/`ElicitationResult` hook events in the JSONL control protocol handler and route them to:
- **Web UI**: modal dialog with form fields (the MCP server specifies the schema)
- **Channel messages**: structured question sent to the user's messaging channel, response captured and returned
- **CLI REPL**: terminal prompt with field labels

**Implementation**: Extend `AgentHarness._handleStreamEvent()` to detect `Elicitation` events, emit a `ElicitationRequestEvent` on the `EventBus`, and have the web/channel/CLI handlers respond. The response is written back to the harness stdin as an `ElicitationResult`.

**Priority**: Low-medium. Few MCP servers currently use Elicitation. Priority increases as the MCP ecosystem matures and DartClaw's `/mcp` server hosting expands.

_Ref: [Claude Code changelog](https://code.claude.com/docs/en/changelog), [MCP 2026 Roadmap](http://blog.modelcontextprotocol.io/posts/2026-mcp-roadmap/)_

---

## Security Audit (OWASP + MCP)

Comprehensive security audit against multiple OWASP frameworks and MCP-specific threat models.

### OWASP Top 10 for Web Applications

DartClaw serves an HTMX web UI over HTTP — standard web application security risks apply. Audit against the [OWASP Top 10 Web Application Security Risks](https://owasp.org/www-project-top-ten/):

| Risk | DartClaw Status | Notes |
|---|---|---|
| A01: Broken Access Control | ✅ Mitigated | Token auth, per-session locks, tool policy cascade |
| A02: Cryptographic Failures | ⚠ Review | Token storage, credential proxy, session IDs |
| A03: Injection | ✅ Mitigated | Trellis auto-escaping (`tl:text`), CSP, SRI, command-guard regex |
| A04: Insecure Design | ⚠ Review | Audit trust boundaries, threat modeling of new features |
| A05: Security Misconfiguration | ⚠ Review | Default configs, exposed endpoints, error messages |
| A06: Vulnerable Components | ✅ Low risk | Minimal deps, no npm, AOT binary — but vendored JS (marked.js, highlight.js) needs version tracking |
| A07: Identification/Authentication | ⚠ Review | Single token auth, no rate limiting, no brute-force protection |
| A08: Software/Data Integrity | ✅ Mitigated | No npm supply chain, SRI on CDN scripts, atomic writes |
| A09: Security Logging/Monitoring | ✅ Implemented | Guard audit log (0.6), event bus (0.7), structured logging |
| A10: SSRF | ✅ Mitigated | `web_fetch` SSRF hardening (0.7), DNS resolution + address range validation |

**Action items**: Formalize as a checklist in `dartclaw doctor --fix` security posture scan (0.18+). Add rate limiting on auth endpoints. Review cryptographic practices (token generation entropy, session ID predictability).

### OWASP Top 10 for LLM Applications

Audit against the [OWASP Top 10 for LLM Applications](https://genai.owasp.org/):

| Risk | DartClaw Status | Notes |
|---|---|---|
| LLM01: Prompt Injection | ✅ Partially mitigated | InputSanitizer (0.5), ContentClassifier (0.5), content-guard at agent boundary. Channel-guard (ML injection) deferred to P3 |
| LLM02: Insecure Output Handling | ✅ Mitigated | MessageRedactor (0.5), Trellis auto-escaping, no raw LLM output in HTML |
| LLM03: Training Data Poisoning | N/A | Using Anthropic's Claude models, not self-trained |
| LLM04: Model Denial of Service | ⚠ Review | Token budget enforcement (0.next-projects F32) addresses this. Per-turn timeout exists |
| LLM05: Supply Chain Vulnerabilities | ✅ Low risk | No npm, AOT binary, minimal deps. ClawHub-type marketplace explicitly avoided |
| LLM06: Sensitive Information Disclosure | ✅ Mitigated | Credential proxy (keys never in container), MessageRedactor, redactPatterns |
| LLM07: Insecure Plugin Design | ⚠ Review | MCP tool registration (0.6) needs tool description scanning. Guard pipeline intercepts tool calls |
| LLM08: Excessive Agency | ✅ Mitigated | Tool policy cascade (3-layer), command-guard, file-guard, network-guard |
| LLM09: Overreliance | N/A | User-facing concern, not runtime security |
| LLM10: Model Theft | N/A | Using API-hosted models |

### OWASP MCP Top 10

MCP tool poisoning is now a documented attack class with real-world incidents (Smithery attack, Oct 2025: 3,000+ hosted apps compromised). The [OWASP MCP Top 10](https://www.practical-devsecops.com/mcp-security-vulnerabilities/) has been published.

**Attack vectors relevant to DartClaw:**
- Hidden instructions in tool descriptions (visible to model, invisible in most UIs)
- Rug pull attacks (tool behavior changes silently after user approval)
- Cross-origin escalation (malicious MCP server hijacks trusted server behavior)

**Defense layers (extend existing guard pipeline):**
1. **Tool description scanning** — `PreToolUse` guard extension to inspect MCP tool metadata for suspicious patterns (hidden instructions, cross-tool references)
2. **Tool pinning** — version-lock MCP server configurations in `dartclaw.yaml`
3. **Tool allowlist** — restrict which MCP tools are available per agent/session (extends existing tool policy cascade)
4. **Periodic auditing** — `mcp-scan` equivalent integrated into `dartclaw doctor`

**Implementation**: Most defense layers build on existing infrastructure (guard pipeline, tool policy cascade, doctor CLI). Tool description scanning is the novel piece.

### Implementation Plan

- **Phase 1 (0.19+ `dartclaw doctor`)**: Add OWASP web app checklist to security posture scan. Automated checks where possible (CSP headers present, auth endpoint rate limiting, token entropy, exposed debug endpoints).
- **Phase 2 (Future)**: MCP tool description scanning in guard pipeline. Tool pinning in config. `mcp-scan` equivalent.
- **Phase 3 (Future)**: Full LLM app audit with channel-guard (ML injection detection, P3).

_Ref: [OWASP Top 10](https://owasp.org/www-project-top-ten/), [OWASP Top 10 for LLM](https://genai.owasp.org/), [OWASP MCP Top 10](https://www.practical-devsecops.com/mcp-security-vulnerabilities/), [Invariant Labs — MCP Tool Poisoning](https://invariantlabs.ai/blog/mcp-security-notification-tool-poisoning-attacks), [OpenClaw CVE cluster (Feb 2026)](https://www.adminbyrequest.com/en/blogs/openclaw-went-from-viral-ai-agent-to-security-crisis-in-just-three-weeks)_

---

## Skill Lifecycle Management

0.15.1 ships skill **discovery and validation** (`SkillRegistry`) — DartClaw scans harness-native directories (`.claude/skills/`, `.agents/skills/`) and its own `<dataDir>/skills/` to find [Agent Skills](https://agentskills.io)-compatible skill definitions. Workflow steps can reference skills via the `skill:` field, with validation that the skill exists and is available to the target harness.

What's missing is the full lifecycle:

1. **Install** — `dartclaw skill install <source>` (from git URL, local path, or future registry). Copies skill to the appropriate harness-native directory. Runs security audit (symlink blocking, size limits, script flagging — aligned with ZeroClaw's mandatory pre-load audit pattern).
2. **Sync across harnesses** — A skill installed for Claude Code (`.claude/skills/`) should optionally sync to Codex (`.agents/skills/`) and vice versa. The Agent Skills format is cross-compatible; the directory structure differs.
3. **Version pinning** — Pin skill versions (git tag, semver) to prevent unexpected behavior changes. Lock file for reproducible builds.
4. **Update** — `dartclaw skill update <name>` pulls latest from source, re-runs security audit.
5. **Remove** — `dartclaw skill remove <name>` with cleanup across harness directories.
6. **Audit** — `dartclaw skill audit` re-runs security checks on all installed skills. Standalone command for periodic validation.

**Security context:** ClawHub's 2026 incident (1,467 malicious skills, 200k+ affected) demonstrates that community skill registries need: mandatory security audit before install, code signing for submissions, and author verification. DartClaw should start with local-only install (git URL, local path) and add curated registry support later with Ed25519-signed packages (ZeroClaw model).

**Depends on:** 0.15.1 `SkillRegistry` (F7)
**Ref:** [AndThen research](research/andthen-workflow-framework/research.md), [Agent Skills spec](https://agentskills.io)

---

## AGENTS.md Standard

PocketPaw has adopted the AGENTS.md standard (emerging spec for agent configuration files). If Anthropic formally backs this standard, DartClaw should support it alongside existing behavior files (SOUL.md, USER.md, TOOLS.md).

**Evaluation criteria**: Check whether `github.com/anthropics/agents-spec` exists and is maintained. If the spec stabilizes, add AGENTS.md to the behavior file cascade (global → project → AGENTS.md, concatenated). Implementation is straightforward — `BehaviorFileService` already handles multi-file cascades.

---

## Kubernetes Deployment

OpenClaw shipped K8s support (v2026.3.12: raw manifests, Kind setup, deployment docs, liveness+readiness probes). DartClaw already has the foundation:
- `/health` endpoint (since 0.2) with uptime, worker state, DB size
- Docker container support with network isolation
- LaunchDaemon + systemd unit generation

**To add**: K8s deployment manifests (`Deployment`, `Service`, `ConfigMap`, `PersistentVolumeClaim`), Kind quickstart, Helm chart (optional). The `/health` endpoint already serves as both liveness and readiness probe.

**Priority**: Low. DartClaw targets single-user deployment where K8s is uncommon. But for VPS/cloud deployments, K8s manifests provide a standard deployment path.

---

## Scoped Task Share Links

Workshop-style task sharing sometimes needs a lightweight "watch this task live" URL that can be opened from a chat card without a normal login flow. DartClaw does **not** have this today, and reusing the gateway token in query params would be too broad for that purpose.

Future direction:

- dedicated short-lived share token or read-only task-view token
- route-scoped to task detail and related read-only task endpoints
- separate from the gateway token and normal browser login bootstrap
- suitable for workshop links, projected demos, or externally shared task views

**Why deferred**: This is an auth/product feature, not a 0.14.1 UX patch. The simple `base_url` link is enough for now; scoped public/read-only access can be designed properly later.

---

## Deployment Architecture Options (Post-0.8)

_Extends the shipped Pragmatic and Docker postures with stronger isolation._

| Posture | Isolation | Filesystem | Network | Credentials | Use When |
|---------|-----------|-----------|---------|------------|----------|
| **Docker + multi-user** | Container + UID per channel | Docker mount + UID boundaries | Per-instance egress network | Per-instance API keys | Multi-channel, strong isolation |
| **VM** (maximum) | Hypervisor kernel boundary | VM filesystem | VM network | Per-VM secrets | Highest security requirement |

## Feature Origin Summary

| Source | Total Features | Shipped (MVP–0.8) | Post-0.8 |
|--------|:-:|:-:|:-:|
| NanoClaw | 24 | 22 | 2 |
| OpenClaw Security Guide | 20 | 13 | 7 |
| OpenClaw Pragmatic Guide (deep) | — | 30 | 11 |
| Cole Medin | 9 | 3 | 6 |
| DartClaw (original) | 12 | 12 | 0 |
| PAI (Miessler) | 5 | 0 | 5 (1 promoted to 0.17) |
| Agent Observability Research | 12 | 0 | 12 (4 promoted to 0.next-projects, 8 remain Future) |
| Alfred (Curator/Distiller) | 3 | 0 | 3 (1 promoted to 0.17) |
| PKM Landscape (Zep/Mem0) | 1 | 0 | 1 |
| Competitive Research (Mar 2026) | 7 | 0 | 7 (hypervisor isolation, Agent Teams, sessions_yield, MCP Elicitation, MCP security, AGENTS.md, K8s) |

### Changelog
- **2026-04-01**: Added Cost-Based Budget Enforcement section. 0.15 ships tokens-only budget (`Task.maxTokens`) because `CodexHarness` has `supportsCostReporting: false`. Cost-based budgets (`maxCostUsd`) deferred with two future paths: Codex cost reporting or token-to-cost estimation. Added to deferral rationale table.
- **2026-03-15c**: Milestone redistribution. Original 0.10 (47 features, 9 phases) and 0.11 (32 features, 8 phases) split into 5 right-sized milestones (10-13 stories each): 0.10 (visual foundation + context), 0.11 (projects + observability + timeline), 0.12 (workflow platform), 0.13 (always-on product), 0.14 (personal AI + developer experience). Push notifications (ntfy.sh) replaced by channel system alerts (0.next-always-on Phase C) — existing channels cover the notification use case. ntfy.sh moved to Future. Inline plan review deferred to Future (chat-based push-back sufficient). Updated all promotion references in deferral table. Guard editor promoted to 0.14 Phase C.
- **2026-03-15b**: Competitive landscape research update. Added 8 new sections from Mar 2026 research: Hypervisor-Level Isolation (gVisor/Firecracker — NanoClaw Docker Sandboxes validates the tier), Agent Teams / Auto-Assembly (Proma's auto-sizing pattern, DartClaw HarnessPool can support), `sessions_yield` Equivalent (OpenClaw v2026.3.12 orchestration primitive), MCP Elicitation Support (Claude Agent SDK v2.1.76), Security Audit (expanded from MCP-only to comprehensive OWASP Top 10 Web App + LLM App + MCP Top 10 audit with status matrices and 3-phase implementation plan), AGENTS.md Standard (PocketPaw adoption), Kubernetes Deployment (OpenClaw v2026.3.12 shipped K8s). Updated NanoClaw skills reference (23 skills, skills-as-branches architecture). Updated Feature Origin Summary with Competitive Research source (7 features). Ref: [feature-comparison.md](feature-comparison.md), [competitor-analysis.md](competitor-analysis.md).
- **2026-03-15**: Added Context Management Infrastructure (LCM) section — Tier 2 (conversation search, context assembly layer with `ContextEngine` interface) and Tier 3 (DAG compaction engine, operator-level recursion). Based on LCM paper analysis and lossless-claw implementation review. Tier 1 features (compact instructions, exploration summaries) promoted to 0.10 Phase B. Updated deferral rationale table with LCM-related promotions and deferrals. Updated Multi-Provider Agent Harnesses section with cross-reference to LCM as the solution to DirectApiHarness's context management blocker. Ref: [LCM research](research/lossless-context-management/research.md).
- **2026-03-14c**: Expanded Observability Integrations section with R5-R12 from agent observability research. 8 post-0.11 features: historical trace query API, phase-level timing, per-tool analytics, evaluation scores, execution timeline/waterfall UI, live activity pulse, offline eval dataset, OTEL export. R1-R4 promoted to 0.11 Phase H (F31-F34). Updated deferral rationale table. Added Agent Observability Research to Feature Origin Summary. Ref: [agent observability research](research/agent-observability/research.md), [0.11 PRD Phase H](specs/0.11/prd.md).
- **2026-03-14b**: Added medium-term personal AI/PKM features from landscape research. New sections: Temporal Memory Tracking (`superseded_at` on `memory_chunks` — cheapest Tier 2 step, inspired by Zep/Mem0), Epistemic Extraction (Distiller background job — extract decisions/assumptions/constraints from conversation history, inspired by Alfred's Distiller worker with scope-constrained TaskFileGuard). Updated Vector Search section with PKM landscape cross-reference and Tier 1→2 framing. Updated Feature Origin Summary with Alfred Distiller scope-constraint feature and PKM Landscape (Zep/Mem0) source. Ref: [personal-ai-pkm-landscape research](research/personal-ai-pkm-landscape/research.md).
- **2026-03-14**: Personal AI intelligence features promoted to 0.11 Phase G. Extended Identity Context (TELOS) → consolidated into expanded USER.md sections (not separate files) per design decision (F27). New feature: Inbox-Drop Knowledge Ingestion (F28), inspired by Alfred's Curator worker pattern. Feedback Signals kept in Future (sentiment scoring + failure capture deferred to keep 0.11 focused). Added Alfred to Feature Origin Summary. Updated deferral rationale table. Ref: [PAI v4.0 research update](research/pai-personal-ai-infrastructure/research.md), [0.11 PRD](specs/0.11/prd.md).
- **2026-03-13**: Major reorganization for 0.10 and 0.11 planning. Added: Projects (External Git Repositories) section — `Project` model, clone/fetch/push lifecycle, PR creation, credential security. Added: Workflow Engine section — multi-step pipelines with fresh sessions per step, `WorkflowContext` shared state, 5 built-in workflows (spec-and-implement, research-and-evaluate, fix-bug, refactor, review-and-remediate), custom workflow YAML format. Inspired by cc-workflows plugin. Added: Task Timeline & Visual Progress section — `TaskEvent` model, timeline UI, live activity, progress estimation. Promoted to 0.10: inline plan review (F37), per-task autonomy dial (F38), auto-retry policies (F39). Promoted to 0.11: Live Config Tier 3 (Phase A), Tailscale Integration (Phase B), push notifications (Phase C), `dartclaw doctor --fix` (Phase D), CLI REPL (Phase F). Updated deferral rationale table with promotion notes. Updated roadmap with 0.10, 0.11, and revised Future entries.
- **2026-03-09**: Task orchestrator section expanded per review council findings. Added: implementation phasing by task type (research/writing first, coding last), milestone placement (Page Registry in next milestone, task model as dedicated 0.8), coding task worktree lifecycle (create → execute → stale detection → review → merge/reject → cleanup), channel-to-task integration as key differentiator, `blocked`/`interrupted` task states, SQLite storage for tasks, atomic checkout single-user justification. Added: Distribution Model (Binary Releases) section — open protocol / closed implementation, SDK packages public, orchestrator binary private. Added: Work Memory merge note (overlaps with task model). Ref: [task orchestrator research](research/task-orchestrator/research.md) (review council findings incorporated 2026-03-09).
- **2026-03-08**: Research audit updates. Added: Task Orchestrator + Dashboard Extensibility, Multi-Provider Agent Harnesses (Pi/DirectApi), Vector Search (hybrid FTS5+embeddings). Replaced Flutter App with Desktop App (Tauriel). Struck through Dedicated Search APIs (Brave/Tavily shipped in 0.6 Phase D; Perplexity/SearXNG remain). Fixed stale Deno references (lines 304, 350). Ref: [task orchestrator research](research/task-orchestrator/research.md), [alternative harnesses research](research/alternative-agent-harnesses/research.md), [vector search research](research/vector-search-approach/research.md), [Tauriel research](research/templating-and-gui-app/04-tauriel.md).
- **2026-03-07**: Promoted session disk budget and DM scope isolation to 0.7. Identity links planned for 0.8+. See [0.7 PRD](specs/0.7/prd.md).
- **2026-03-03**: Added Tailscale Integration as standalone section (promoted from Production Hardening bullet). Three features: T1 Serve/Funnel automation, T2 identity verification middleware (whois-verified, fail-closed — fixes OpenClaw #13153), T3 connection keep-alive. Supporting document: [tailscale-integration.md](specs/0.next-headless-access/tailscale-integration.md). Research: OpenClaw implementation, Tailscale Serve/Funnel/ACLs/LocalAPI, self-hosted app patterns (HA, Vaultwarden, Forgejo, Jellyfin, Immich).
- **2026-03-02**: Added Dedicated Search API Providers section (Brave, Tavily, Perplexity, SearXNG). Builds on 0.5 Phase G internal MCP server infrastructure. Claude Code's `WebSearch` remains default; dedicated APIs are quality upgrade.
- **2026-02-27**: Added Signal integration (signal-cli-rest-api sidecar, outpost pattern). Ref: [research](research/signal-integration/research.md).
- **2026-02-25d**: Multi-user channels research. Added: Slack integration, Google Chat integration, WhatsApp group policy warning, expanded multi-user deployment with implementation sequence (session isolation, identity links, tool-based roles, memory namespacing, token budgets, channel-guard). Ref: [research](research/multi-user-channels/research.md).
- **2026-02-25c**: Added PAI-inspired features: feedback signals/behavioral learning, push notifications (ntfy), extended identity context (TELOS), work memory, Builder-Validator pairs. Ref: [PAI research](research/pai-personal-ai-infrastructure/research.md).
- **2026-02-25b**: Added Telegram integration, CLI REPL (`dartclaw chat`), and `dartclaw doctor --fix` — deferred from shipped scope during PRD interview.
- **2026-02-25**: Initial split from unified roadmap. Features incorporated from OpenClaw 2026.2.17–2026.2.24 and NanoClaw v1.1.2. Agent Swarms noted as SDK-native implementation option. Session disk budget, channel-guard, full multi-agent, and advanced messaging deferred from shipped scope scope.
