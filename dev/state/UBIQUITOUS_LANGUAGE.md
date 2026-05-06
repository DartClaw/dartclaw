# Ubiquitous Language

> Domain glossary for DartClaw. Canonical terms for use in code, documentation, and team communication.
>
> **Usage**: Use these exact terms in code (class names, variables, functions), documentation, and discussion. Avoid synonyms listed in the "Avoid" column.

## Agent Runtime & Execution

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| Turn | Single round of agent reasoning, tool execution, and response generation. Atomic work unit | iteration, cycle, pass | Server orchestration |
| Worker | Agent subprocess executing turns. Lifecycle: `idle`, `busy`, `crashed`, `stopped` | agent process, execution context | Server execution |
| Harness | Bridge between Dart host and native LLM binary. Implements protocol parsing, lifecycle, stream translation. Abstract: `AgentHarness`; concrete: `ClaudeCodeHarness`, `CodexHarness` | bridge, connector, wrapper | Harness pool |
| Harness Pool | Manages N worker harnesses for parallel task execution. `tryAcquire()`, provider affinity, per-provider pool sizing | worker pool, thread pool | Server orchestration |
| Provider | LLM provider (claude, codex). Determines harness implementation and credentials | model, backend, endpoint | Configuration |
| Session | Top-level conversation container. File-based: `sessions/<id>/meta.json` + `messages.ndjson`. Types: main, channel, cron, user, task, archive | conversation, thread, chat | Storage, routing |
| Session Key | Deterministic routing string `agent:<agentId>:<scope>:<identifiers>`. Decouples scoping from session discovery | session ID, routing key | Routing |
| Session Scope | Rules for session creation: `shared`, `per_contact`, `per_channel_contact`, `per_member` | isolation mode, distribution | Scoping |
| Compaction Observability | Provider compaction signals surfaced in the host event model and task timeline. Used to track resumable flush boundaries | compaction handling, flush tracing | Agent runtime / observability |
| Bang Operator | Agent Skills convention for executing a literal shell command in a skill prompt (e.g. `` !`git status` ``). The command runs before the LLM sees the rendered skill; stdout replaces the placeholder. Literal command text is fixed at skill-authoring time; `$ENV_VAR` references expand at runtime. Supported by both Claude Code and Codex harnesses | shell prefix, shell injection | Agent skills |
| Env-var Injection | DartClaw mechanism for passing dynamic values into a skill agent process: the orchestrator sets environment variables on agent process spawn; the skill's Bang Operator commands reference them as `$VAR`. Lets static skill text consume runtime-determined values without dynamic command text | env injection, environment passing | Agent skills |

## Control Protocol

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| JSONL Control Protocol | Wire format for Dart-to-binary communication. Bidirectional JSONL over stdin/stdout | stream-json, control stream | Protocol spec |
| Stream Event | Atomic output unit from binary (text delta, tool use, tool result). Sealed: `ClaudeMessage` | message, chunk, output | Protocol parsing |
| Bridge Event | DartClaw's internal representation of stream events, normalized across providers. Sealed: `BridgeEvent` | internal event, translated event | Harness bridge |
| Protocol Adapter | Provider-specific protocol parser. Maps wire format to `BridgeEvent`, handles tool name canonicalization | protocol handler, translator | Multi-provider |
| Tool Approval Request | Binary asks Dart host for permission to execute a tool. Handled by guard chain | permission request, approval prompt | Guard chain |

## Storage & Persistence

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| NDJSON | Newline-Delimited JSON. One JSON object per line. Used for messages, audit logs, usage | JSON lines, line-delimited JSON | Storage |
| Cursor | Line number in NDJSON file used as crash recovery resume point. `lastCursor` tracks position | offset, checkpoint, position | Crash recovery |
| Atomic Write | Temp file + rename pattern preventing corruption on crash | safe write, transactional write | Storage |
| Memory Chunk | Text snippet indexed in FTS5 search database. Fields: `textContent`, `source`, `category` | memory entry, indexed text | Memory system |
| Search Index | FTS5-backed full-text search over MEMORY.md and daily logs. QMD hybrid search opt-in | search database | Search |

## Security & Guards

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| Guard | Policy evaluator in defense chain. Examines tool/file/network requests. Implementations: `CommandGuard`, `FileGuard`, `NetworkGuard`, `ContentGuard`, `InputSanitizer`, `ToolPolicyGuard` | policy, filter, validator | Security |
| Guard Chain | Sequential evaluation of multiple guards on a tool approval request | guard pipeline, validation chain | Security |
| Guard Verdict | Sealed outcome: `GuardPass` (allow), `GuardWarn` (log + allow), `GuardBlock` (deny) | decision, outcome, result | Security |
| Guard Audit | Persistent NDJSON log of all guard verdicts. Rotated daily with retention cleanup | guard log, security audit | Audit |
| Canonical Tool Taxonomy | DartClaw-standardized tool names across providers: `shell`, `file_read`, `file_write`, `file_edit`, `web_fetch`, `mcp_call` | tool names, tool mapping | Multi-provider |
| Credential Proxy | Unix socket-based credential injection. API keys never in container env or JSONL | credential injection, secret proxy | Security |
| Container Isolation | Docker per-task sandbox: `network:none`, `cap-drop=ALL`, read-only rootfs | sandboxing | Security |

## Channels & Messaging

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| Channel | Integration point for external messaging platforms. Abstract: `Channel`; concrete: `WhatsAppChannel`, `SignalChannel`, `GoogleChatChannel` | integration, connector, gateway | Channels |
| Channel Message | Normalized inbound DTO from any channel | inbound message, channel event | Channels |
| Sender Attribution | Identity tracking: `Task.createdBy`, `TaskOrigin.senderDisplayName/senderId` | creator tracking | Channels |
| Thread Binding | Maps `(channelType, threadId)` to `(taskId, sessionKey)`. Routes thread replies to task session. Auto-unbinds on completion | thread mapping, routing entry | Channels |
| Message Deduplicator | Prevents duplicate processing when message arrives via multiple paths (webhook + Pub/Sub) | dedup engine, duplicate filter | Channels |

## Tasks & Orchestration

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| Task | Discrete unit of work. Status lifecycle: draft → queued → running → interrupted → review → accepted/rejected/cancelled/failed | job, work item, request | Tasks |
| Task Status | Lifecycle state enum. Terminal: accepted, rejected, cancelled, failed. Non-terminal: draft, queued, running, interrupted, review | state, condition | Tasks |
| Task Type | Category: coding, research, writing, analysis, automation, custom. Influences routing and security profile for ordinary tasks; workflow steps preserve their authored type as metadata but execute through the coding-task path | task category, classification | Tasks |
| Task Project ID | Persisted `Task.projectId` field naming the project checkout a task runs against. Standalone tasks set it directly; workflow tasks derive it from workflow-level project binding | task project, project field | Tasks |
| Task Executor | Orchestrates lifecycle: dequeue, acquire worker, execute turn, cleanup, notify | task runner | Tasks |
| Task Service | CRUD service with atomic status transitions and optimistic locking | task manager, task repository | Tasks |
| Worktree | Isolated git worktree per coding task at `~/.dartclaw/worktrees/<taskId>/`. Lifecycle: create → execute → review → merge/reject → cleanup | sandbox directory, work directory | Coding tasks |
| Diff | Computed difference between worktree and main branch. `DiffGenerator` → `DiffResult` | file changes, patch | Coding tasks |
| Merge | Apply worktree changes to main. `MergeExecutor` → `MergeSuccess` or `MergeConflict` | git merge, integration | Coding tasks |
| Review Command | Channel review syntax for task review: accept, reject, "push back: \<feedback\>" | review action, decision command | Channels |

## Workflows

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| Exit Gate | Boolean expression evaluated against WorkflowContext after each loop iteration. When true, the loop terminates successfully | exit condition, break condition | Workflow execution |
| Loop Iteration | A single pass through the loop body in an ordered workflow loop node. Tracked by `_loop.current.iteration` in runtime metadata. Terminates when exit gate passes or `maxIterations` reached | loop cycle, loop pass | Workflow execution |
| Parallel Group | Set of contiguous steps with `parallel: true` that execute concurrently via `Future.wait()`. Results merged into context after all complete. Failures pause the workflow; resume re-runs only failed steps | concurrent group, parallel block | Workflow execution |
| Workflow | Declarative, multi-step automation pipeline defined in YAML. Orchestrated deterministically by the Dart host (not prompt choreography). Consists of sequential steps, parallel groups, and iterative loops | pipeline, automation, flow | Workflow model |
| Workflow Context | Accumulated key-value state passed between workflow steps. Steps read inputs from context and write outputs back. Persisted atomically after each step for crash recovery | workflow state, step data, pipeline state | Workflow execution |
| Workflow Definition | YAML schema describing a workflow: name, description, variables, ordered steps, and optional legacy `loops` compatibility declarations. Loaded from built-in assets or custom workspace directories | workflow template, workflow spec | Workflow model |
| Workflow Project | Top-level `WorkflowDefinition.project` authoring field that declares the default project binding for eligible workflow steps. Distinct from the persisted task-system `Task.projectId` field | step project, coding-step project | Workflow model |
| Workflow Run | Single execution instance of a Workflow Definition, with its own lifecycle (`pending` → `running` → `paused` → `completed`/`failed`/`cancelled`), context, and child tasks | workflow instance, workflow execution | Workflow execution |
| Workflow Step | Atomic unit of work within a workflow. Step `type:` closes at `{agent, bash, approval, foreach, loop}` (default: `agent`); only `agent` steps create a Task, while `bash`, `approval`, and controller constructs (`foreach`, `loop`) are host-executed and zero-task. Steps can declare gates, budgets, `inputs:`, and `outputs:`. Runtime normalization groups steps into ordered action/map/parallel/loop control nodes | workflow action, pipeline step | Workflow model |
| WorkflowExecutor | Dart class that drives workflow execution: step dispatch, context management, budget tracking, parallel/loop orchestration. Lives in `dartclaw_workflow` | workflow engine, workflow runner | Workflow execution |
| WorkflowRegistry | Manages available workflow definitions (built-in + custom). Loaded at startup from bundled assets and workspace directories | workflow catalog, definition store | Workflow model |
| Foreach Iteration | A single execution of a foreach (map) step's body for one item in the iterated collection. Each iteration runs in its own Task, with its own Story Branch and worktree (when `worktree.mode: per-map-item`), and its own Promotion. Distinct from Loop Iteration (which refers to ordered loop nodes) | foreach pass, map iteration | Workflow execution |
| Project Base Branch | The branch the workflow's Integration Branch was created from. Configurable per project — commonly `main` but could be `master`, `develop`, `trunk`, etc. Determined from the `BRANCH` context variable; never hardcoded in workflow code | base ref, project main, default branch | Workflow git |
| Integration Branch | Workflow-owned branch (`dartclaw/workflow/<runId>/integration`) that aggregates work from all stories in a Workflow Run. Created from the Project Base Branch; up-merged to the project's base branch at workflow completion | workflow branch, aggregation branch | Workflow git |
| Story Branch | Foreach-iteration-owned branch (`dartclaw/workflow/<runId>/<storyId>`) where one story's implementation runs. Created from Integration Branch HEAD at iteration start; promoted to Integration Branch on iteration success | iteration branch, task branch | Workflow git |
| Promotion | Merging a Story Branch's work into the Integration Branch after a story step completes. Performed by `promoteWorkflowBranchLocally`. Strategy is `merge` or `squash` per `gitStrategy.promotion`. Distinct from task-level Merge (which targets the project main from a task worktree) | story merge, integration merge, foreach merge | Workflow git |
| Promotion Conflict | The `WorkflowGitPromotionConflict` result returned when a Promotion's merge cannot complete mechanically. Common cause: two parallel stories edited the same scaffolding file (`STATE.md`, `LEARNINGS.md`, `plan.md` checkbox). Trigger for the agent-resolved-merge feature | promotion failure, integration conflict | Workflow git |
| Resolution Attempt | One full invocation of the merge-resolve skill for a single Promotion Conflict, including Resolution Verification and Internal Remediation. Bounded by per-attempt token ceiling. Retried up to `max_attempts` before escalation | resolve attempt, conflict-resolution try | Workflow git |
| Resolution Verification | Post-resolution checks performed by the merge-resolve skill: no remaining conflict markers and `git diff --check` clean. When discovered project conventions declare format/analyze/test commands, those run as additional verification. Failure triggers Internal Remediation within the same Resolution Attempt | post-merge check, sanity check | Workflow git |
| Internal Remediation | Retry loop inside a single Resolution Attempt: if Resolution Verification fails, the skill agent edits failing files and re-verifies, all within the attempt's token ceiling. Distinct from the outer `max_attempts` retry across attempts | inline retry, in-attempt fix | Workflow git |
| Serialize-remaining | Escalation mode that, after `max_attempts` Resolution Attempts fail, drains in-flight parallel foreach iterations and runs the rest with `max_parallel: 1`. Already-promoted iterations are kept; remaining iterations re-queued serially. Serial iterations cannot Promotion-Conflict by construction (each branches from current Integration HEAD) | serial fallback, sequential recovery | Workflow git |
| Drain | The act of cancelling currently in-flight parallel foreach iterations when Serialize-remaining fires, and re-queueing them at the back of the now-serial queue | cancel-and-requeue, foreach teardown | Workflow git |
| Workflow Run Artifact | Persistent record of a workflow run event — outcome, inputs/outputs, metadata. Stored alongside other workflow run state and queryable post-hoc by operators. Examples: per-step output records, Resolution Attempt artifact (9-field record per merge-resolve invocation) | run artifact, structured artifact | Workflow execution |
| Connected Mode | Default CLI execution mode where commands target a running DartClaw server over the loopback HTTP/SSE API instead of inspecting local files or running in-process | live mode, server mode | CLI operations |
| Standalone Mode | Explicit CLI mode (`--standalone`) that bypasses the server API and runs local workflow logic or direct local DB inspection | offline mode, local mode | CLI operations |
| API Client | The CLI-only loopback HTTP client (`DartclawApiClient`) used for connected commands, auth resolution, error mapping, and SSE workflow streaming | HTTP helper, REST wrapper | CLI operations |
| Server Detection | The CLI health probe that checks the configured loopback server before choosing connected or standalone behavior | server probe, health check | CLI operations |

## Governance

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| Runtime Governance | Runtime safety controls: rate limiting, token budget, loop detection. All default disabled | policy, enforcement | Governance |
| Rate Limiter | Per-sender + global turn rate limiting. Sliding window algorithm. Admin exempt | throttle, request limiter | Governance |
| Token Budget | Aggregate daily token spending limit per sender. Modes: warn, block. Midnight UTC reset | cost limit, quota | Governance |
| Loop Detector | Detects infinite loops via turn depth, token velocity, tool fingerprinting | recursion detection | Governance |
| Emergency Control | Admin-only: `/stop` (abort all), `/pause` (queue messages), `/resume` (drain queue) | kill switch | Governance |
| Alert Routing | Runtime routing of operational events to alert sinks and subscribers | notifications, alert dispatch | Governance / observability |

## Configuration

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| Composed Config | `DartclawConfig` decomposed into ~14 typed sections (`ServerConfig`, `AgentConfig`, `AuthConfig`, etc.) | settings, configuration model | Configuration |
| Reconfigurable Service | Runtime service that can absorb config updates without a full restart via `ConfigNotifier` and `Reconfigurable` | hot reload target, live config | Configuration |
| Extension Parser | Plugin point: `registerExtensionParser()` + `config.extension<T>()` for custom config sections | custom parser | Extensibility |
| Behavior Files | User-editable agent identity files: SOUL.md, USER.md, TOOLS.md, AGENTS.md, HEARTBEAT.md. Cascaded into system prompt | config files, manifest | Behavior |

## Architecture Patterns

| Term | Definition | Avoid (synonyms) | Bounded Context |
|------|-----------|-------------------|-----------------|
| 2-Layer Model | Dart host (state/security) → native binary (LLM reasoning). Security boundary between layers | two-tier, client-server | Architecture |
| Outpost Pattern | Purpose-built CLI tools in optimal language, invoked as subprocesses with JSON I/O. No shared runtime | sidecar, helper process | Architecture |
| Defense-in-Depth | Multiple overlapping security controls: OS-level (container) + app-level (guards, credentials, budgets) | layered security | Security |
| Dependency Reversal | Extraction pattern where a foundational package moves below its former consumer to eliminate cycles. Used in 0.16.3 when `dartclaw_core` began depending on `dartclaw_config` instead of owning config parsing | inversion, reverse dependency | Architecture |
| Event Bus | Lightweight typed pub/sub using `StreamController.broadcast()`. Sealed `DartclawEvent` hierarchy | event system, message bus | Architecture |
| Fitness Function | Executable architecture boundary check. In 0.16.3 this is the `dev/tools/arch_check.dart` governance script enforcing package, barrel, and dependency invariants | architecture test, governance check | Architecture |

## Overloaded Terms

| Term | Context A | Meaning A | Context B | Meaning B |
|------|-----------|-----------|-----------|-----------|
| Session | Storage | Conversation container with messages | Channel | Messaging platform's concept of a chat thread |
| Thread | Channels | Google Chat thread within a Space | Coding | Not used — DartClaw is single-threaded (Dart isolate) |
| Worker | Harness Pool | Agent subprocess executing turns | General | Not used for Dart isolates |
| Provider | Agent Runtime | LLM provider (claude, codex) | Google Chat | Google Cloud service account |
| Guard | Security | Policy evaluator in defense chain | UI | Not used |
| Bridge | Protocol | Harness-to-host event translation | Channels | `ChannelTaskBridge` (channel-to-task routing) |
| Drain | Workflow git | Cancelling and re-queueing in-flight foreach iterations on Serialize-remaining | Emergency Control | Informal use in `/resume (drain queue)` describing message-queue replay |
| Verification | Workflow git | Resolution Verification — merge-resolve skill's post-resolution checks | Workflow execution | Generic step-level review/verification activities (e.g. `dartclaw-review`) |

## Changelog

- 2026-04-04: Added Workflows section (10 terms) for 0.15 milestone: Workflow, Workflow Run, Workflow Step, Workflow Context, Workflow Definition, Loop Iteration, Parallel Group, Exit Gate, WorkflowExecutor, WorkflowRegistry
- 2026-04-11: Added 0.16 terms for alert routing, compaction observability, and reconfigurable service; aligned glossary with current runtime governance and workflow observability language
- 2026-04-17: Clarified that workflow-authored step types remain observability metadata while workflow runtime dispatch uses coding tasks plus `readOnly` for non-mutating steps
- 2026-04-11: Updated workflow ownership to `dartclaw_workflow`; added dependency reversal and fitness function as 0.16.3 architecture-governance terms
- 2026-03-24: Reassigned thread binding, sender attribution, review commands, and runtime governance to concrete capability areas after removing the former shared bounded context
- 2026-03-23: Initial extraction from architecture docs, CLAUDE.md, and codebase
- 2026-04-25: Added 0.16.4 agent-resolved-merge terms — Workflow git: Foreach Iteration, Project Base Branch, Integration Branch, Story Branch, Promotion, Promotion Conflict, Resolution Attempt, Resolution Verification, Internal Remediation, Serialize-remaining, Drain, Workflow Run Artifact. Agent skills: Bang Operator, Env-var Injection.
