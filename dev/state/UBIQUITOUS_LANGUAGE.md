# Ubiquitous Language

> Domain glossary for DartClaw. Canonical terms for use in code, documentation, and team communication.
>
> **Usage**: Use these exact terms in code (class names, variables, functions), documentation, and discussion. Avoid synonyms listed in the "Avoid" column.
>
> **Glossary and nothing else.** A term earns a row when getting its name wrong causes a defect – ambiguity, schema
> drift, misrouting. A row is one sentence under 200 characters: what the term is and where it lives. Mechanism,
> rationale, status, and open questions stay in the document that owns them – point, don't restate.
>
> **Structure**: each `##` section is one bounded context from the [Context Map](../architecture/context-map.md), which
> owns context identity. A section's context id is the kebab-slug of its heading (`Guarding & Audit` → `guarding-audit`).
> A term lives in exactly one context; words meaning different things in two contexts are listed under
> [Overloaded Terms](#overloaded-terms).

## Provider Mediation

Owned by [control-protocol.md](../architecture/control-protocol.md); credentials in [security-architecture.md](../architecture/security-architecture.md) § Credential Security (ADR-053).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Harness | Host-side driver of one native LLM binary's protocol, lifecycle and stream translation: `AgentHarness`, implemented by `ClaudeCodeHarness` and `CodexHarness` in `dartclaw_core` | connector, wrapper, bridge |
| Provider | LLM provider (claude, codex) that determines the harness implementation and credentials | model, backend, endpoint |
| JSONL Control Protocol | Bidirectional JSONL wire format over stdin/stdout between the Dart host and a provider binary | stream-json, control stream |
| Stream Event | Atomic output unit from the binary (text delta, tool use, tool result), sealed as `ClaudeMessage` | message, chunk, output |
| Bridge Event | DartClaw's provider-normalized form of stream events (sealed `BridgeEvent`), carrying protocol-stream signals only; application semantics live on `DartclawEvent` | internal event, translated event |
| Protocol Adapter | Provider-specific protocol parser that maps wire format to `BridgeEvent` and canonicalizes tool names, the anticorruption layer where vendor drift stops | protocol handler, translator |
| Canonical Tool Taxonomy | DartClaw-standardized tool names across providers: `shell`, `file_read`, `file_write`, `file_edit`, `web_fetch`, `mcp_call` | tool names, tool mapping |
| 2-Layer Model | Dart host (state/security) → native binary (LLM reasoning), with the security boundary between the two layers | two-tier, client-server |
| Subscription Credential | The operator's plan-backed provider credential DartClaw holds and presents (Claude's `setup-token`, Codex's ChatGPT token), the default credential kind per ADR-053 | OAuth token, login token, session token |
| Dedicated Credential Store | DartClaw's own single-writer store for one provider's Subscription Credential under `<data_dir>/credentials/<provider>`, opened only through `SubscriptionCredentialStore.open` | credential directory, keychain, vault |
| Named Credential Store | DartClaw's file-per-name store for operator-named API keys and GitHub tokens under `<data_dir>/credentials/named/`, overlaying the same-named YAML entry | vault, keychain, Dedicated Credential Store |
| Operator Login Store | The operator's own vendor login (`~/.claude`, `~/.codex`, or wherever `CLAUDE_CONFIG_DIR` / `CODEX_HOME` points), which a Dedicated Credential Store never copies | user login, host login, system home |
| Credential Mode | Which credential kind an authority presents (`CredentialMode`: `subscription` or `apiKey`), chosen by `providers.<id>.auth`, which an alias inherits from its family unless set | auth type, auth mode, credential type |
| Credential Resolution | The single credential one authority presents for one provider, or the typed reason none can be (`CredentialResolution`), never a fallback across modes | credential lookup, auth result |
| Credential Health State | Probed condition of a presented credential (`healthy`, `nearing-expiry`, `refresh-failure`, `reauth-required`, `contract-break`, `unknown`), distinct from presence-level `credentialStatus` | credential status, auth status, credential health check |
| Renewal Deadline | The derived date by which the operator must renew a Subscription Credential, computed per provider and deliberately not the access token's JWT `exp` | expiry, expiration, token lifetime |
| Provider Availability | Whether a configured provider can be used (`ProviderStatus.health`: `healthy`, `degraded`, `unavailable`), derived from binary, credential and capacity, never a worker lifecycle | provider health, provider status |
| Codex Refresh Authority | The single-flight per-store refresher keeping a Codex Subscription Credential usable by driving the vendor's own `codex app-server` refresh, never a DartClaw-built token request | token refresher, refresh loop, OAuth client |

## Execution Isolation

Owned by [security-architecture.md](../architecture/security-architecture.md) § Container Isolation (ADR-012, ADR-051, ADR-055).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Execution Policy | Per-execution choice of location (host or container) from `agent.execution`, `agent.agents.<id>.execution` or `tasks.execution`, independent of the Security Profile | execution mode, isolation mode, container flag |
| Security Profile | Named container mount and permission tier (`SecurityProfile`, ADR-012), `workspace` or `restricted`, chosen independently of execution location | sandbox level, permission mode |
| Principal | The single trust identity a Container Authority is bound to: a standing agent (primary lane, logical-agent session) or a one-shot job (task, workflow step) | trust principal, owner, tenant |
| Container Isolation | Per-authority Docker sandbox (`network:none`, `cap-drop=ALL`, read-only rootfs, `no-new-privileges`) whose only egress is its Container Bridge to the Host Gateway | sandboxing |
| Container Authority | A live, never-shared grant of one dedicated container to exactly one Principal, owning that container, its bridge pipes and its generated-state directory (ADR-012) | container lease, container slot |
| Host Gateway | Host-side `HostGateway` that registers each live Container Authority and serves its framed `docker exec` pipes, the container's only path off `network:none` | credential proxy, provider proxy, gateway |
| Container Bridge (`dartclaw_bridge`) | Read-only, credential-free Dart executable `dartclaw-bridge` inside the agent container, forwarding framed provider/MCP traffic to the Host Gateway (ADR-051) | socat bridge, in-container proxy, credential proxy |
| Credential Proxy (removed 0.24) | Retired term for the Unix-socket credential-injection proxy removed in 0.24; say Host Gateway and Container Bridge instead | – |

## Guarding & Audit

Owned by [security-architecture.md](../architecture/security-architecture.md) § Guard Pipeline, § Audit Chain (ADR-039).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Guard | Policy evaluator in the defense chain that examines tool, file and network requests: `CommandGuard`, `FileGuard`, `NetworkGuard`, `ContentGuard`, `TaskToolFilterGuard`, `ToolPolicyGuard` | policy, filter, validator |
| Guard Chain | Sequential evaluation of multiple guards on a tool approval request | guard pipeline, validation chain |
| Guard Verdict | Sealed outcome: `GuardPass` (allow), `GuardWarn` (log + allow), `GuardBlock` (deny) | decision, outcome, result |
| Guard Audit | Persistent, daily-rotated NDJSON journal of every guard verdict (`AuditEntry`: guard, hook, verdict, reason, tool, caller identity), kept as security evidence, not telemetry | guard log, security audit |
| Tool Approval Request | A provider binary's request for the Dart host's permission to execute a tool, handled by the Guard Chain | permission request, approval prompt |
| egress guard | Guard boundary that evaluates outbound MCP calls before external network or subprocess dispatch and records allow/deny audit evidence (ADR-039) | network filter, outbound policy |
| Defense-in-Depth | Independent, overlapping security controls: OS-level (container isolation, host-held credentials) plus application-level (guards, budgets) | layered security |

## Turn Orchestration

Owned by [task-execution-architecture.md](../architecture/task-execution-architecture.md), [session-state-architecture.md](../architecture/session-state-architecture.md) § Turn Admission and Locking (ADR-058).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Turn | Single atomic round of agent reasoning, tool execution and response generation | iteration, cycle, pass |
| Worker | Agent subprocess executing turns (lifecycle `idle`, `busy`, `crashed`, `stopped`) that operator-facing surfaces call a Runner | agent process, execution context |
| Execution Coordinator | Post-governance execution authority owning one serialized primary lane, hard per-provider worker lease capacity, lazy worker construction, compatible reuse and lease snapshots | pool coordinator |
| Execution Lease | Temporary admission to the primary lane or a provider worker, whose release returns capacity and may cache a healthy compatible worker | worker slot |
| Execution Fingerprint | Provider, security profile, and runtime configuration identity required for safe worker reuse | pool key |
| Worker Capacity Gate | Bound on concurrent executions independent of reusable worker state, issuing `WorkerCapacityPermit`s and withholding quarantined slots from `effectiveCapacity` (ADR-058) | semaphore, pool |
| Session Lock | Per-session mutual exclusion plus a global parallelism cap (`SessionLockManager`): same-session requests queue, and exceeding the cap throws `BusyTurnException` | mutex, semaphore |
| Context Monitor | Per-turn context-window token tracker, shared across `TurnRunner` instances, that triggers the pre-compaction flush and a one-shot per-session threshold warning | token counter, window tracker |
| Turn Context Assembler | Per-turn context-window assembly and compaction abstraction inside `TurnManager`, explicitly not the Context Engine | context engine |
| Compaction Observability | Provider compaction signals surfaced in the host event model and task timeline to track resumable flush boundaries | compaction handling, flush tracing |
| Prompt Scope | Enum (`primary`, `task`, `restricted`) deciding how much identity and memory content `BehaviorFileService` composes into a system prompt | persona, prompt level |
| Logical Agent | Named execution profile under `agent.agents` (prompt, provider, model/effort overrides, tool policy), started with `sessions_spawn` and continued with `sessions_send` | subagent, native agent |
| Logical-Agent Session | Durable hidden session for one Logical Agent, pinned to its provider and security profile and continued only by the handle `sessions_spawn` returned | delegated conversation, provider thread |

## Runtime Governance

Owned by [security-architecture.md](../architecture/security-architecture.md) § Runtime Governance.

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Runtime Governance | Default-disabled pre-execution safety controls (rate limiting, token budget, loop detection) that admit work before the post-governance Execution Coordinator | policy, enforcement |
| Rate Limiter | Sliding-window per-sender and global turn rate limit, with the admin exempt | throttle, request limiter |
| Token Budget | Aggregate daily per-sender token spending limit (modes `warn`, `block`), reset at midnight UTC | cost limit, quota |
| Loop Detector | Detects runaway autonomy via turn depth, token velocity, tool fingerprinting | recursion detection |
| Emergency Control | Admin-only: `/stop` (abort all), `/pause` (queue messages), `/resume` (drain queue) | kill switch |

## Conversation & Session

Owned by [session-state-architecture.md](../architecture/session-state-architecture.md), [data-model.md](../architecture/data-model.md) (ADR-060).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Session | Top-level conversation container with persisted messages, typed main, channel, cron, user, task, logicalAgent or archive | conversation, thread, chat |
| Session Key | Deterministic routing string `agent:<agentId>:<scope>:<identifiers>` that decouples scoping from session discovery | session ID, routing key |
| Session Scope | Rules for session creation: `shared`, `per_contact`, `per_channel_contact`, `per_member` | isolation mode, distribution |
| Managed Workspace Binding | Agent id and derived `data_dir/agents/<id>/workspace` pinned to a conversation at creation, owning behavior and skills under the `agent:<id>` principal regardless of project | workspace selection, configured path, project workspace |
| Conversation Attempt | One admitted unit of conversation work linking its submission, captured effective context, provider turn, terminal outcome, messages, tools, approvals, and branch lineage | turn (when persistence identity matters), retry |
| Effective Context | Complete nullable project association, directory, reference root, provider, model, and effort snapshot captured by the next admitted attempt; never changes the Managed Workspace Binding | workspace, execution defaults |
| General Chat | Owner web conversation without a project association, executing in the existing owner workspace; Agent and global New chat start here | General project, implicit local project |
| Project Chat | Owner web conversation associated with an explicitly selected Project for subsequent work; association changes preserve owner, memory and past attempts | project workspace, project agent |
| Attention Event | Durable completion, failure, or input-request record linked to exact conversation history and projected into the owner's attention feed | notification, alert |
| Action Availability | Server projection that an exact live request and owning turn still permit an action; read or dismiss state does not confer it | button state, permission |
| Temporary Conversation | Owner-authorized conversation with `process` retention whose DartClaw state, attachments, usage context, and provider home remain in process, page, or volatile container storage until confirmed end | incognito chat, automatically private chat |
| NDJSON | Newline-Delimited JSON, one object per line, used for messages, audit logs and usage | JSON lines, line-delimited JSON |
| Cursor | Line number in an NDJSON file (`lastCursor`) used as a crash-recovery resume point | offset, checkpoint, position |
| Atomic Write | Temp file + rename pattern preventing corruption on crash | safe write, transactional write |
| Database Backend | Dependency-free relational port implemented only by the PostgreSQL adapter (ADR-060); always say *database* backend, since bare "backend" means Provider | engine, database provider |
| Authoritative Store | Durable PostgreSQL records for tasks, goals, executions, workflow runs, traces, events and knowledge-graph facts, unlike the rebuildable memory and conversation indexes | relational store |
| Instance-Local Store | Transient serve-process-only filesystem state (`turn_state.json`, `webhook_deliveries/`) that is safe to lose and never moves into PostgreSQL | state database, delivery database |
| Schema Compatibility Gate | `PostgresSchemaGate`, which checks one current schema epoch and required-object manifests and refuses partial, foreign or incompatible storage; not a migration history | schema epoch check, compatibility check |

## Channel Integration

Owned by [channel-messaging-architecture.md](../architecture/channel-messaging-architecture.md).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Channel | Integration point for an external messaging platform: `Channel`, implemented by `WhatsAppChannel`, `SignalChannel`, `GoogleChatChannel` and `SlackChannel` | integration, connector, gateway |
| Channel Message | Normalized inbound DTO every platform adapter produces before routing, distinct from the persisted `Message` record | inbound message, channel event |
| Sender Attribution | Identity tracking: `Task.createdBy`, `TaskOrigin.senderDisplayName/senderId` | creator tracking |
| Thread Binding | A `ThreadBinding` mapping `(channelType, threadId)` to a task (with its `sessionKey`) or a workflow run, held only by a Threaded Channel | thread mapping, routing entry |
| Threaded Channel | A channel whose `threadedNotifications` getter returns `ThreadedNotifications` (Google Chat, Slack), its one declaration that it can thread, edit posts and render native cards or blocks | threading flag, thread support |
| Run Thread | The chat thread carrying one Workflow Run's lifecycle posts, held as a `ThreadBinding` of kind `run` | run channel, run conversation |
| Message Deduplicator | Prevents duplicate processing when a message arrives via multiple paths (webhook + Pub/Sub) | dedup engine, duplicate filter |

## Task & Review

Owned by [task-execution-architecture.md](../architecture/task-execution-architecture.md); scheduling in [observability-operations-architecture.md](../architecture/observability-operations-architecture.md) § Scheduling and Heartbeat.

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Task | Discrete unit of work with the lifecycle draft → queued → running → interrupted → review → accepted/rejected/cancelled/failed | job, work item, request |
| Task Status | Task lifecycle enum, terminal at accepted, rejected, cancelled or failed and non-terminal at draft, queued, running, interrupted or review | state, condition |
| Task Project ID | Persisted `Task.projectId` naming the project checkout a task runs against, set directly by a standalone task and derived from the workflow's project binding otherwise | task project, project field, repoId |
| Task Executor | Orchestrates lifecycle: dequeue, acquire worker, execute turn, cleanup, notify | task runner |
| Task Service | CRUD service with atomic status transitions and optimistic locking | task manager, task repository |
| Worktree | Isolated git worktree for a task with `needsWorktree: true`, at `<workspaceDir>/.dartclaw/worktrees/<taskId>/` and keyed only by task UUID | sandbox directory, work directory |
| Diff | Computed difference between a worktree and the main branch (`DiffGenerator` → `DiffResult`) | file changes, patch |
| Merge | Applying worktree changes to the project base branch (`MergeExecutor` → `MergeSuccess` or `MergeConflict`), distinct from workflow Promotion | git merge, integration |
| Task Review | A lifecycle decision applied through the task UI, HTTP API, or `task_review` tool to a task identified by its full ID | review action, review decision |
| Scheduled Job | Recurring or one-shot job definition (`ScheduledJob`: id, schedule type, delivery mode, `ScheduledJobType` `prompt` or `task`), the scheduling entity rather than a `Task` | cron job, trigger, timer |
| Schedule Type | The three schedule kinds a Scheduled Job can carry: `cron`, `interval`, `once` | frequency, recurrence, trigger type |
| Cron Expression | Parsed 5-field `minute hour dom month dow` expression with `*`, ranges, lists and steps, driving next-fire computation for `ScheduleType.cron` | cron string, cron schedule |
| Delivery Mode | How a finished Scheduled Job's result reaches the operator: `announce` (broadcast plus DM targets), `webhook` (HTTP POST), `none` | notification type, output mode |
| Scheduled Task Definition | A `scheduling.jobs` config entry with `type: task` that the runner turns into a callback-backed Scheduled Job | auto-task, task schedule |
| Heartbeat | Periodic self-directed cycle driven by `HEARTBEAT.md` and run as the built-in `heartbeat` Scheduled Job; not a liveness probe | health check, keepalive, heartbeat scheduler |

## Workflow Orchestration

Owned by [workflow-architecture.md](../architecture/workflow-architecture.md) (ADR-024, ADR-046).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Workflow | Declarative multi-step YAML automation the Dart host orchestrates deterministically, not by prompt choreography, from sequential steps, parallel groups and loops | pipeline, automation, flow |
| Workflow Definition | YAML schema of a workflow (name, description, variables, ordered steps, optional legacy `loops`), loaded from built-in assets or custom workspace directories | workflow template, workflow spec |
| Workflow Project | Top-level `WorkflowDefinition.project` authoring field declaring eligible steps' default project binding, distinct from the persisted `Task.projectId` | step project, coding-step project |
| Workflow Run | Single execution instance of a Workflow Definition, with its own lifecycle (`pending` → `running` → `paused` → `completed`/`failed`/`cancelled`), context, and child tasks | workflow instance, workflow execution |
| Workflow Step | Atomic unit of work in a workflow, typed `agent` (default, the only type that creates a Task), `bash`, `approval`, `aggregate-reviews`, `foreach` or `loop` (ADR-024) | workflow action, pipeline step |
| Workflow Context | Key-value state accumulated between workflow steps, which read inputs from it and write outputs back, persisted atomically after each step for crash recovery | workflow state, step data, pipeline state |
| WorkflowExecutor | The `dartclaw_workflow` class driving workflow execution: step dispatch, context management, budget tracking and parallel/loop orchestration | workflow engine, workflow runner |
| WorkflowRegistry | Registry of available built-in and custom workflow definitions, loaded at startup from bundled assets and workspace directories | workflow catalog, definition store |
| Exit Gate | Boolean expression evaluated against Workflow Context after each loop iteration that, when true, ends the loop successfully | exit condition, break condition |
| Loop Iteration | A single pass through an ordered loop node's body, tracked as `_loop.current.iteration` and ending when the Exit Gate passes or `maxIterations` is reached | loop cycle, loop pass |
| Parallel Group | Contiguous `parallel: true` steps that run concurrently and merge into context in step order; a blocking failure fails or pauses the run per `onError`, and resume re-runs only failed steps | concurrent group, parallel block |
| Foreach Iteration | One execution of a foreach (map) step's body for one collection item, run as its own Task with its own Promotion; distinct from Loop Iteration | foreach pass, map iteration |
| Project Base Branch | The branch a run's Integration Branch was created from, configured per project and read from the `BRANCH` context variable, never hardcoded | base ref, project main, default branch |
| Integration Branch | Workflow-owned branch `dartclaw/workflow/<runToken>/integration` aggregating a run's stories, created from the Project Base Branch and up-merged into it on completion | workflow branch, aggregation branch |
| Story Branch | Foreach-iteration branch `dartclaw/task-wf-<token>-map-<i>` where one story runs, cut from the Integration Branch HEAD and promoted back into it on success | iteration branch, task branch |
| Promotion | Merging a Story Branch into the Integration Branch after its story step completes (`promoteWorkflowBranchLocally`, strategy per `gitStrategy.promotion`); distinct from task Merge | story merge, integration merge, foreach merge |
| Promotion Conflict | The `WorkflowGitPromotionConflict` result when a Promotion's merge cannot complete mechanically, which triggers agent-resolved merge | promotion failure, integration conflict |
| Resolution Attempt | One invocation of the merge-resolve skill for one Promotion Conflict, including Resolution Verification and Internal Remediation, retried up to `max_attempts` before escalation | resolve attempt, conflict-resolution try |
| Resolution Verification | The merge-resolve skill's checks inside one Resolution Attempt: the project's documented format/analyze/test commands, else no conflict markers and a clean `git diff --check` | post-merge check, sanity check |
| Internal Remediation | The fix-and-re-verify loop inside one Resolution Attempt when Resolution Verification fails, within its token ceiling; distinct from the outer `max_attempts` retry | inline retry, in-attempt fix |
| Serialize-remaining | Escalation mode that, after `max_attempts` failed Resolution Attempts, drains in-flight foreach iterations and runs the rest with `max_parallel: 1` | serial fallback, sequential recovery |
| Drain | Cancelling currently in-flight parallel foreach iterations when Serialize-remaining fires, and re-queueing them at the back of the now-serial queue | cancel-and-requeue, foreach teardown |
| Loop Escalation | The `onMaxIterations: escalate` policy on a foreach-nested remediation loop that records an exhausted item needsInput/blocked and pauses the run for review; distinct from Serialize-remaining | escalate policy, needs-review exhaustion |
| Teardown Interruption | A workflow task ending `TaskStatus.cancelled` while its run is still `running`, resolved as the resumable engine-side step outcome `cancelled` rather than a run failure | cancelled-as-interrupted, teardown cancellation |
| Workflow Run Artifact | Persistent, post-hoc queryable record of a workflow run event (outcome, inputs/outputs, metadata), such as a per-step output or a Resolution Attempt record | run artifact, structured artifact |
| Run Origin | Where a Workflow Run was started (`WorkflowRunOrigin`): a `surface` plus, for a chat start, channel type, recipient, thread, session key and sender, recorded once | run source, trigger, creator |
| Approval Interaction | The durable single-use `WorkflowApprovalInteraction` binding one chat post, step and nonce so that post can resolve one pending approval | approval button, approval token, approval callback |

## Knowledge & Memory

Owned by [data-model.md](../architecture/data-model.md), [system-architecture.md](../architecture/system-architecture.md) § Memory, Search and Context Research (ADR-029, ADR-050).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Context Engine | Server-side layer that combines caller-private personal memory with the shared wiki and temporal KG, then serves compact citation-backed packets to agents and read-only MCP clients | turn context assembler, context window assembler |
| Personal Memory | Canonical memory and derived projections owned by one storage principal (`owner` or `agent:<id>`); never a shared source merely because its managed workspace exists | global memory, shared memory |
| Selected Private Corpus | The single owner-authorized personal-memory corpus an opaque selector picks for administration, whose principal its reads, health, search and revision-checked writes use | active workspace, shared memory |
| Retained Agent Corpus | Canonical memory left under a removed named agent's validated managed home, which the owner may inspect and correct and the removed agent has no tool access to | orphan workspace, adopted memory |
| Curated Removal | Revision-checked removal of one canonical curated entry that leaves its source observations, transcripts, audit records and backups intact | source purge, hard delete |
| Shared Knowledge Surface | Explicitly published wiki pages and temporal KG facts readable by owner, named agents with `context_research`, and named MCP clients; excludes personal memory and knowledge-inbox files | all knowledge, global memory |
| Canonical Memory Entry | Stable UUID-addressed record with revision, role, provenance, and validated Markdown representation | memory chunk, indexed text |
| Memory Role | Closed `MemoryRole` discriminant for canonical memory documents and knowledge layers: `index`, `topic`, `archive`, `observation`, `learning`, `error`, `audit`, `wiki`, `kg` | memory type, category |
| Memory Provenance | The `MemorySourceRef` tuple (origin kind, source locator, source event, caller, session ref) every canonical record carries, compared by `isExactReplayOf` for dedup and deletion | source ref, origin |
| Memory Observation | Captured raw observation with a trust label and truncation flag, linked forward to the entries it produced and never prompt-authoritative by location | raw memory, note |
| Memory Locator | Stable canonical entry UUID, or a native source locator for wiki, KG, knowledge-inbox, or an eligible search result; accepted by `memory_read` and reopened through the source owner | generic source, row ID |
| Temporal Knowledge Graph | Time-scoped fact store (`entity, predicate, value, valid_from, valid_to, source, owner, invalidated_at`) with canonicalized entities and contradiction detection | knowledge base, triple store |
| Knowledge Inbox | Drop-folder ingestion path whose files move through the fixed states `inbox`, `processed`, `quarantine`, `skipped` | upload folder, import queue |
| Knowledge Hub | Operator-facing browse/search surface over the knowledge layers (`all`, `wiki`, `kg`, `memory`, `inbox`) | knowledge UI, memory browser |
| Search Index | Rebuildable lexical and vector projections of canonical memory and chat-facing conversation messages in separate corpora, excluding memory audit entries and non-chat messages | source of truth, search database |
| Full-Text Index | The `FullTextIndex` lexical port over PostgreSQL text search, instantiated separately for memory documents and conversation messages and scoped by principal, never global | FTS layer, search abstraction |
| Embedding Provider | Owner of query and document embeddings under one Model Fingerprint: `local` (the verified EmbeddingGemma artifact) or `http` (one explicit endpoint owning preprocessing and trust) | embedding backend, model |
| Model Fingerprint | Derived, never operator-configured identity of the provider, model and input convention that authenticates reusable vectors | model ID, embedding version |
| Vector Index | Optional principal- and corpus-scoped PostgreSQL `VectorIndex` projection for exact-fingerprint embeddings, using the administrator-provisioned `public.vector` type | vector database, semantic store |
| Hybrid Search | `dartclaw_search` composition of one Full-Text Index and one Vector Index by weighted RRF, still serving lexical results when vectors degrade (ADR-050) | semantic search, reranker |
| QMD | Retired external hybrid-search daemon removed in 0.27, whose old config subtree is parser-only transition input that never activates a runtime path | current hybrid backend, embeddings service |
| citation packet | Compact synthesized response where each claim carries source references resolvable to wiki, temporal KG, memory, or external MCP source material | answer blob, summary packet |
| `context_research` | MCP synthesis tool that retrieves caller-private personal memory when available plus the shared wiki and KG, then returns a citation packet; named clients receive shared sources only | context engine tool, research outpost, search summary |
| wiki provenance | Frontmatter field recording who authored a wiki page's content (`human-authored`, `hybrid`, `llm-authored`), which sets the page's search trust | authorship, page origin |
| `hybrid` | The wiki provenance a page takes on when a `human-authored` or `hybrid` page gains machine-synthesized content, so it is neither relabelled as machine-authored nor claimed as sole machine authorship | mixed, merged provenance |
| supplement section | A `## Supplement from <source> (<date>)` block appended to an existing wiki page, only when the merge turn declares the new material unrelated to the stored page | append block, merge section |
| wiki collision | An ingestion whose chosen slug already has a stored page, settled by a page-scoped merge turn and reported as *integrated*, *unchanged* or *supplement* | overwrite, merge conflict |
| merge declaration | The merge turn's reply for one collision (`merge`, `integrated_from`, `removed_content`, merged body), which the model declares and the host admits or refuses | merge decision, merge result |
| shrink floor | The compile-time share (0.8) of a stored body an integrated merge must keep while declaring no `removed_content`; below it the write is refused and the source quarantined | shrink guard, size check |

## Tool Surface

Owned by [control-protocol.md](../architecture/control-protocol.md) § MCP Integration, [system-architecture.md](../architecture/system-architecture.md) § MCP Server (ADR-039).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Host MCP Endpoint | The host-served `POST /mcp` MCP Streamable HTTP route where DartClaw serves tools to provider binaries, reached from containers only through the Container Bridge | MCP server (ambiguous with configured external servers) |
| outbound MCP client | DartClaw's client-side MCP runtime that connects to configured external MCP servers, discovers their tools and calls them through the egress guard | outpost, outpost client, external tool bridge |
| surface_tools | Per-server allowlist of an external server's advertised tools that harnesses see, validated against the live server so an unknown name is a configuration error | exposed tools, tool allowlist |
| MCP Network Class | Per-server network risk classification (`local`, `private`, `public`) used to gate an outbound server's blast radius | trust tier, network tier |
| Outbound Governance | Per-server sliding-window call limit and token budget enforced before an outbound call, with denials distinct from egress-guard denials | rate limiting, quota |

## Project Registry

Owned by [task-execution-architecture.md](../architecture/task-execution-architecture.md) § Multi-Project (ADR-017).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Project | Git checkout a task or workflow runs against (id, remote URL, local path, default branch, clone strategy, PR settings, status), from `projects:` config or created at runtime | repo, repository, workspace |
| Project Status | Lifecycle enum: `cloning`, `ready`, `error`, `stale` | state, phase |
| Local-Only Project | A Project with an empty `remoteUrl`, the single discriminator that short-circuits fetch, push and PR logic; the reserved id `_local` is the server's current directory | isLocal flag, default project |
| Default Branch | Per-project default git branch (`branch` in config, `defaultBranch` at runtime), a task's last-resort base ref and distinct from the per-run Project Base Branch | base branch, main branch |

## Configuration & Platform

Owned by [configuration-architecture.md](../architecture/configuration-architecture.md); platform policy in [system-architecture.md](../architecture/system-architecture.md) (ADR-049).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Composed Config | `DartclawConfig` decomposed into ~14 typed sections (`ServerConfig`, `AgentConfig`, `AuthConfig`, etc.) | settings, configuration model |
| Reconfigurable Service | Runtime service absorbing config updates without a restart via `ConfigNotifier` and `Reconfigurable`, exchanging `ConfigDelta` against its `watchKeys` | hot reload target, live config |
| Extension Parser | Plugin point: `registerExtensionParser()` + `config.extension<T>()` for custom config sections | custom parser |
| Behavior Files | User-editable agent identity files (SOUL.md, USER.md, TOOLS.md, AGENTS.md, HEARTBEAT.md) cascaded into the system prompt | config files, manifest |
| Platform Capabilities | Immutable, effect-free OS capability policy (`PlatformCapabilities` in `dartclaw_kernel`, ADR-049) covering home and executable lookup, shell, signals, permissions and containers | platform detection, OS check (bare "capability" is ambiguous) |
| Bang Operator | Agent Skills convention for running a literal shell command in a skill prompt (e.g. `` !`git status` ``), whose stdout replaces it before the LLM sees the skill | shell prefix, shell injection |
| Env-var Injection | Passing runtime values into a skill agent by setting environment variables at process spawn, which the skill's Bang Operator commands read as `$VAR` | env injection, environment passing |
| Fitness Function | Executable architecture boundary check – the `dev/tools/arch_check.dart` governance script enforcing package, barrel, LOC-ceiling, and dependency invariants | architecture test, governance check |

## Operator Interface

Owned by [cli-api-architecture.md](../architecture/cli-api-architecture.md); auth in [security-architecture.md](../architecture/security-architecture.md) § Access Control (ADR-006).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Gateway Token | The single bearer credential (file `gateway_token`) for API auth that also signs session cookies (ADR-006); unrelated to the Host Gateway | API key, auth token, password |
| Session Cookie | Stateless HMAC-signed browser cookie derived from the Gateway Token, not a server-side session store or JWT, and unrelated to a conversation Session | auth cookie, JWT, login session |
| Trellis Template | Paired `.html` + `.dart` template under `templates/`, loaded from a manifest and rendered as a page or an HTMX fragment | view, partial |
| SSE Broadcast | The sanctioned Server-Sent-Events plumbing for pushing live updates to the web UI, including the bridge that forwards `DartclawEvent`s to connected browsers | websocket, event stream |
| Runner | Operator-facing name for leased execution capacity, exposed by `/api/runners` and the CLI. The same thing the coordinator internally calls a Worker | worker (in API/CLI surfaces), pool slot |
| Connected Mode | Default CLI execution mode where commands target a running DartClaw server over the loopback HTTP/SSE API instead of inspecting local files or running in-process | live mode, server mode |
| Standalone Mode | Explicit CLI mode (`--standalone`) that bypasses the server API and runs local workflow logic or direct local DB inspection | offline mode, local mode |
| API Client | The CLI-only loopback HTTP client (`DartclawApiClient`) used for connected commands, auth resolution, error mapping, and SSE workflow streaming | HTTP helper, REST wrapper |
| Server Detection | The CLI health probe that checks the configured loopback server before choosing connected or standalone behavior | server probe, health check |

## Observability & Alerting

Owned by [observability-operations-architecture.md](../architecture/observability-operations-architecture.md) (ADR-011).

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Event Bus | Typed pub/sub on `StreamController.broadcast()` whose sealed `DartclawEvent` hierarchy is the exchange format, so subscribers never reach into domains (ADR-011) | event system, message bus |
| Turn Trace | Best-effort, asynchronously written telemetry record of one task turn in the `turns` table, queried as *traces* by API and CLI; never called an audit | span, execution log, audit |
| Task Event | Append-only entry on a task's user-visible timeline (`statusChanged`, `toolCalled`, `compaction`, `taskError`, …), persisted synchronously and losslessly | activity log entry, audit event |
| Alert Routing | Classification of a `DartclawEvent` into an alert type and severity (`info`, `warning`, `critical`), resolution of configured targets, and throttled delivery | notifications, alert dispatch |
| Health Status | Aggregated runtime health (`healthy`, `degraded`, `unhealthy`) projected from the host Worker's `WorkerState` by `healthStatusForWorkerState`; never Provider Availability | liveness, readiness |

## Overloaded Terms

| Term | Context A | Meaning A | Context B | Meaning B |
|------|-----------|-----------|-----------|-----------|
| Session | Conversation & Session | Durable conversation container with persisted messages | Channel Integration | The messaging platform's own chat-thread concept |
| Session | Operator Interface | The HMAC-signed browser Session Cookie | Turn Orchestration | Logical-Agent Session – a hidden durable session pinned to one Logical Agent |
| Message | Channel Integration | `ChannelMessage` – normalized inbound DTO from any platform | Conversation & Session | Persisted message record inside a Session |
| Thread | Channel Integration | A platform thread DartClaw posts into or binds: a Google Chat thread within a Space, a Slack thread under a message | Turn Orchestration | Not used – DartClaw is single-threaded (one Dart isolate) |
| Provider | Provider Mediation | LLM provider (claude, codex) | Channel Integration | Google Cloud service account (Google Chat) |
| Bridge | Execution Isolation | Container Bridge / `dartclaw_bridge` – the read-only in-container executable forwarding framed provider/MCP traffic to the Host Gateway | Provider Mediation | `BridgeEvent` – harness-to-host event translation |
| Bridge | Channel Integration | `ChannelTaskBridge` – the seam that applies reserved-command, thread-binding, and rate-limit routing before normal channel dispatch | Task & Review | Task creation is model-initiated through `task_create`, not inferred from channel text |
| Event | Observability & Alerting | `DartclawEvent` – sealed application-semantics bus payload | Provider Mediation | `BridgeEvent` – provider protocol-stream signal, no application semantics |
| Event | Task & Review | `TaskEvent` – persisted, user-visible task timeline entry | Turn Orchestration | `ExecutionEventKind` – coordinator-internal capacity/lease signal |
| Audit | Guarding & Audit | The guard verdict journal – security decision evidence | Observability & Alerting | Never used here: a Turn Trace is telemetry, not audit |
| Runner | Operator Interface | API/CLI name for leased execution capacity | Turn Orchestration | Worker – the coordinator's internal name for the same thing |
| Health | Observability & Alerting | Health Status – the host Worker's lifecycle projected onto `healthy`/`degraded`/`unhealthy` | Provider Mediation | Provider Availability – binary presence, credential resolution and capacity, projected onto `healthy`/`degraded`/`unavailable` |
| Context | Turn Orchestration | The per-turn context window assembled for a provider call | Workflow Orchestration | Workflow Context – key-value state accumulated between steps |
| Context Engine | Knowledge & Memory | Server-side synthesis and external-ingestion layer served over MCP | Turn Orchestration | Not the per-turn context-window assembler |
| Budget | Runtime Governance | Token Budget – aggregate daily token spend per sender | Workflow Orchestration | Per-step budget declared on a Workflow Step |
| Type | Workflow Orchestration | Step type – workflow dispatch kind: `agent`, `bash`, `approval`, `foreach`, `loop`, `aggregate-reviews` | Task & Review | Scheduled Job kind – `prompt` or `task` |
| Merge | Task & Review | `MergeExecutor` applying a task worktree to the project base branch | Workflow Orchestration | Promotion – a Story Branch merged into the Integration Branch |
| Project | Project Registry | `Project` – the git checkout record and its clone lifecycle | Workflow Orchestration | `WorkflowDefinition.project` – the authoring field binding steps to a checkout |
| Tool | Tool Surface | An MCP tool published to provider binaries or consumed from an external server | Provider Mediation | A Canonical Tool Taxonomy name (`shell`, `file_read`, …) |
| Drain | Workflow Orchestration | Cancelling and re-queueing in-flight foreach iterations on Serialize-remaining | Runtime Governance | `/resume (drain queue)` – replaying the paused message queue |

## Changelog
- 2026-10-16: Cut every row to one sentence under 200 characters, moved mechanism to the owning docs each section now names, and corrected Memory Role, Memory Provenance, Default Branch, Parallel Group, Loop Escalation, Resolution Verification, Story Branch and Integration Branch against the code.
- 2026-10-07: Added Run Origin, Run Thread, Threaded Channel and Approval Interaction; Channel and Thread name Slack.
- 2026-09-26: Clarified that Effective Context permits a null project association for general chats.
- 2026-09-25: Added General Chat and Project Chat and nullable Effective Context from ADR-017 §9.
- 2026-09-22: Replaced configurable Workspace Binding with Managed Workspace Binding and added Personal Memory and Shared Knowledge Surface.
- 2026-09-14: Added Workspace Binding, Conversation Attempt, Effective Context, Attention Event, Action Availability, and Temporary Conversation.
- 2026-09-09: Aligned database and schema-compatibility terms and added Instance-Local Store.
- 2026-09-09: Full-Text Index and Search Index now name separate memory and conversation corpora and their owner scope.
- 2026-09-09: Added Embedding Provider, Model Fingerprint, Vector Index, and Hybrid Search; marked QMD's 0.26 deprecation window.
- 2026-09-08: Added Authoritative Store and its `dartclaw.db` SQLite filename; `tasks.db` is the retired name.
- 2026-08-25: Added Named Credential Store under `provider-mediation` for the 0.24.3 credential and secrets CLI contract.
- 2026-08-20: Split the overloaded "health" term: Health Status is now stated as the single projection of the host Worker's lifecycle, and Provider Availability is registered beside it as the separately derived provider-mediation term, with an Overloaded Terms row demarcating the two.
- 2026-08-20: Recut the wiki-collision vocabulary for the merge contract: *wiki collision* now names the settled merge, *merge declaration* and *shrink floor* added, *consolidation debt* and *declared drop* removed with the surfaces that reported them.
