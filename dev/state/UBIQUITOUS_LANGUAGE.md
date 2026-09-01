# Ubiquitous Language

> Domain glossary for DartClaw. Canonical terms for use in code, documentation, and team communication.
>
> **Usage**: Use these exact terms in code (class names, variables, functions), documentation, and discussion. Avoid synonyms listed in the "Avoid" column.
>
> **Structure**: each `##` section is one bounded context from the [Context Map](../architecture/context-map.md), which
> owns context identity. A section's context id is the kebab-slug of its heading (`Guarding & Audit` → `guarding-audit`).
> A term lives in exactly one context; words meaning different things in two contexts are listed under
> [Overloaded Terms](#overloaded-terms).

## Provider Mediation

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Harness | Bridge between Dart host and native LLM binary. Implements protocol parsing, lifecycle, stream translation. Abstract: `AgentHarness`; concrete: `ClaudeCodeHarness`, `CodexHarness`. Never named a bridge – the Container Bridge owns that term | connector, wrapper, bridge |
| Provider | LLM provider (claude, codex). Determines harness implementation and credentials | model, backend, endpoint |
| JSONL Control Protocol | Wire format for Dart-to-binary communication. Bidirectional JSONL over stdin/stdout | stream-json, control stream |
| Stream Event | Atomic output unit from the binary (text delta, tool use, tool result). Sealed: `ClaudeMessage` | message, chunk, output |
| Bridge Event | DartClaw's internal representation of stream events, normalized across providers. Sealed: `BridgeEvent`. Carries protocol-stream signals only – application semantics live on `DartclawEvent` | internal event, translated event |
| Protocol Adapter | Provider-specific protocol parser. Maps wire format to `BridgeEvent`, handles tool name canonicalization. The anticorruption layer where vendor drift stops | protocol handler, translator |
| Canonical Tool Taxonomy | DartClaw-standardized tool names across providers: `shell`, `file_read`, `file_write`, `file_edit`, `web_fetch`, `mcp_call` | tool names, tool mapping |
| 2-Layer Model | Dart host (state/security) → native binary (LLM reasoning). Security boundary between layers | two-tier, client-server |
| Subscription Credential | The operator's plan-backed provider credential DartClaw holds and presents: Claude's static `setup-token`, Codex's ChatGPT token. The default credential kind since 0.24.2 (ADR-053); an API key is the alternative | OAuth token, login token, session token |
| Dedicated Credential Store | DartClaw's own single-writer store for one provider's Subscription Credential, under `<data_dir>/credentials/<provider>` (`0700` dir, `0600` file, atomic write). `SubscriptionCredentialStore.open` is the only construction seam and refuses when a store path resolves onto an Operator Login Store | credential directory, keychain, vault |
| Named Credential Store | DartClaw's file-per-name store for operator-named API keys and GitHub tokens under `<data_dir>/credentials/named/` (`0700` directories, `0600` files, atomic write). A stored entry overlays the same YAML name at load and reload. It is permission-protected, not encrypted, and `secrets audit` inspects it without provisioning paths | vault, keychain, Dedicated Credential Store |
| Operator Login Store | The operator's own vendor login – `~/.claude` / `~/.codex`, or wherever `CLAUDE_CONFIG_DIR` / `CODEX_HOME` points. Never the source or destination of a Subscription Credential; DartClaw resolves it only to refuse a colliding Dedicated Credential Store. Auth-status probing and `use_system_codex_home` seeding are separate, pre-existing paths that do read it | user login, host login, system home |
| Credential Mode | Which credential kind an authority presents: `subscription` or `apiKey` (`CredentialMode`). Chosen by `providers.<id>.auth` (`auto` \| `subscription` \| `api_key`), where an alias inherits its family's setting unless it sets its own | auth type, auth mode, credential type |
| Credential Resolution | The single credential one authority presents for one provider (`CredentialResolution`) – or the typed reason none can be. Exactly one of the two, never a fallback across modes; an unsatisfiable resolution is refused at execution admission | credential lookup, auth result |
| Credential Health State | Probed operator-facing condition of a presented credential: `healthy`, `nearing-expiry`, `refresh-failure`, `reauth-required`, `contract-break`, `unknown`. Distinct from `credentialStatus`, the presence-level field it renders beside | credential status, auth status, credential health check |
| Renewal Deadline | The derived, operator-actionable date by which a Subscription Credential must be renewed: Claude's ingestion time plus the documented ~1-year `setup-token` lifetime, Codex's last store write plus the 8-day refresh-token staleness window. Deliberately not the access token's minutes-scale JWT `exp` | expiry, expiration, token lifetime |
| Provider Availability | Whether a configured provider can be used (`healthy`, `degraded`, `unavailable`), derived from binary presence, credential resolution, credential health and worker capacity – never from a worker lifecycle. A provider whose binary is missing is `unavailable`; one whose binary and credential resolve is `healthy` even with no worker running. Carried as `ProviderStatus.health` | provider health, provider status |
| Codex Refresh Authority | The single-flight per-store refresher that keeps a Codex Subscription Credential usable. Drives the vendor's own `codex app-server` refresh and confirms success by re-reading the store; DartClaw never constructs a token request itself | token refresher, refresh loop, OAuth client |

## Execution Isolation

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Execution Policy | Two-axis per-execution decision: **location** (host or container), chosen by `agent.execution` / `agent.agents.<id>.execution` / scalar `tasks.execution` independently of the **security profile**. One resolver owns precedence; an unrunnable provider/location combination is refused before the turn, never downgraded to host | execution mode, isolation mode, container flag |
| Security Profile | Named container mount and permission tier (`SecurityProfile`, ADR-012): `workspace` (writable `/workspace`, read-only project clones) or `restricted` (no workspace mounts). Chosen independently of execution location | sandbox level, permission mode |
| Principal | The single trust identity a Container Authority is bound to – a standing agent (primary lane, logical-agent session) or a one-shot job (task, workflow step). A container never crosses principals; there is no shared-across-principals scope | trust principal, owner, tenant |
| Container Isolation | Per-authority Docker sandbox: `network:none`, `cap-drop=ALL`, read-only rootfs, `no-new-privileges`. Each Container Authority owns one single-use container whose only path off `network:none` is its per-authority framed Container Bridge to the Host Gateway | sandboxing |
| Container Authority | A live grant of one dedicated container to exactly one Principal, owning that container, its per-authority bridge pipes, and its generated-state directory. Never cached or shared; disposal revokes the pipes, deletes generated state, and destroys the container before capacity returns (ADR-012) | container lease, container slot |
| Host Gateway | Host-side component (`HostGateway`) that registers each live Container Authority and serves its framed `docker exec` pipes to the provider adapters and MCP router. Pins each upstream, injects host-held credentials, and is the container's only path off `network:none` | credential proxy, provider proxy, gateway |
| Container Bridge (`dartclaw_bridge`) | Read-only Dart executable that runs inside the agent container on loopback and forwards bounded, framed provider/MCP traffic to the Host Gateway over the host-opened `docker exec -i` pipe. Chooses no destination and holds no credential; shipped host-side and mounted read-only at create (ADR-051). In-container binary name `dartclaw-bridge` | socat bridge, in-container proxy, credential proxy |
| Credential Proxy (removed 0.24) | Retired term. The Unix-socket credential-injection proxy was removed in 0.24 and replaced by the host-gateway model. No socket-based credential injection remains – use Host Gateway and Container Bridge instead | – |

## Guarding & Audit

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Guard | Policy evaluator in the defense chain. Examines tool/file/network requests. Implementations: `CommandGuard`, `FileGuard`, `NetworkGuard`, `ContentGuard`, `TaskToolFilterGuard`, `ToolPolicyGuard` | policy, filter, validator |
| Guard Chain | Sequential evaluation of multiple guards on a tool approval request | guard pipeline, validation chain |
| Guard Verdict | Sealed outcome: `GuardPass` (allow), `GuardWarn` (log + allow), `GuardBlock` (deny) | decision, outcome, result |
| Guard Audit | Persistent NDJSON journal of every guard verdict (`AuditEntry`: guard, hook, verdict, reason, tool, caller identity). Rotated daily with retention cleanup. Security evidence, not telemetry | guard log, security audit |
| Tool Approval Request | Provider binary asks the Dart host for permission to execute a tool. Handled by the guard chain | permission request, approval prompt |
| egress guard | Guard boundary that evaluates outbound MCP calls before external network or subprocess dispatch and records allow/deny audit evidence (ADR-039) | network filter, outbound policy |
| Defense-in-Depth | Multiple overlapping security controls: OS-level (container isolation, host-held credentials) plus application-level (guards, budgets). Layers are independent – a guard verdict knows nothing about container authorities | layered security |

## Turn Orchestration

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Turn | Single round of agent reasoning, tool execution, and response generation. Atomic work unit | iteration, cycle, pass |
| Worker | Agent subprocess executing turns. Lifecycle: `idle`, `busy`, `crashed`, `stopped`. Operator-facing surfaces call the same thing a Runner | agent process, execution context |
| Execution Coordinator | Post-governance execution authority. Owns one serialized primary lane plus hard per-provider worker lease capacity, lazy worker construction, compatible reuse, and lease-derived snapshots | pool coordinator |
| Execution Lease | Temporary admission to the primary lane or a provider worker. Releasing it returns capacity and may cache a healthy compatible worker | worker slot |
| Execution Fingerprint | Provider, security profile, and runtime configuration identity required for safe worker reuse | pool key |
| Worker Capacity Gate | Bounds concurrent executions independently of reusable worker state, issuing `WorkerCapacityPermit`s. Tracks `quarantinedCount` – slots withheld after an unconfirmed teardown – against `effectiveCapacity` | semaphore, pool |
| Session Lock | Per-session mutual exclusion plus a global parallelism cap (`SessionLockManager`). Same-session requests queue; exceeding the global cap throws `BusyTurnException` | mutex, semaphore |
| Context Monitor | Tracks context-window token usage per turn, triggers the pre-compaction flush, and raises a one-shot per-session threshold warning. Shared across `TurnRunner` instances | token counter, window tracker |
| Turn Context Assembler | Per-turn context-window assembly and compaction abstraction inside `TurnManager`. Explicitly not the Context Engine | context engine |
| Compaction Observability | Provider compaction signals surfaced in the host event model and task timeline. Used to track resumable flush boundaries | compaction handling, flush tracing |
| Prompt Scope | Enum (`primary`, `task`, `restricted`) deciding how much identity and memory content `BehaviorFileService` composes into a system prompt | persona, prompt level |
| Logical Agent | Named execution profile under `agent.agents`: prompt, provider, model/effort overrides, and tool policy. Started with `sessions_spawn` and continued with `sessions_send` | subagent, native agent |
| Logical-Agent Session | Durable hidden session created for one Logical Agent. Pinned to its provider and security profile, then continued only by the handle returned from `sessions_spawn` | delegated conversation, provider thread |

## Runtime Governance

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Runtime Governance | Pre-execution safety controls: rate limiting, token budget, loop detection. All default disabled. Admission happens before the Execution Coordinator, which is the post-governance authority | policy, enforcement |
| Rate Limiter | Per-sender and global turn rate limiting. Sliding window algorithm. Admin exempt | throttle, request limiter |
| Token Budget | Aggregate daily token spending limit per sender. Modes: warn, block. Midnight UTC reset | cost limit, quota |
| Loop Detector | Detects runaway autonomy via turn depth, token velocity, tool fingerprinting | recursion detection |
| Emergency Control | Admin-only: `/stop` (abort all), `/pause` (queue messages), `/resume` (drain queue) | kill switch |

## Conversation & Session

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Session | Top-level conversation container with persisted messages. Types: main, channel, cron, user, task, logicalAgent, archive | conversation, thread, chat |
| Session Key | Deterministic routing string `agent:<agentId>:<scope>:<identifiers>`. Decouples scoping from session discovery | session ID, routing key |
| Session Scope | Rules for session creation: `shared`, `per_contact`, `per_channel_contact`, `per_member` | isolation mode, distribution |
| NDJSON | Newline-Delimited JSON. One JSON object per line. Used for messages, audit logs, usage | JSON lines, line-delimited JSON |
| Cursor | Line number in an NDJSON file used as a crash-recovery resume point. `lastCursor` tracks position | offset, checkpoint, position |
| Atomic Write | Temp file + rename pattern preventing corruption on crash | safe write, transactional write |
| Database Backend | Pluggable database engine behind the storage layer (`DatabaseBackend`: `SqliteBackend` default, `PostgresBackend` opt-in; ADR-045). Always qualified as *database* backend – bare "backend" is a disfavored synonym for Provider | engine, database provider |
| Schema Compatibility Gate | Startup contract using one current schema epoch plus backend-owned required-object checks. It transactionally bootstraps fresh storage, admits the exact supported SQLite transition, refuses incompatible authoritative storage, and rebuilds incompatible derived search storage only from complete supported sources. Not a migration history or automatic upgrade framework (ADR-045) | schema epoch check, compatibility check |

## Channel Integration

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Channel | Integration point for external messaging platforms. Abstract: `Channel`; concrete: `WhatsAppChannel`, `SignalChannel`, `GoogleChatChannel`. Never named a gateway – the Host Gateway owns that term | integration, connector, gateway |
| Channel Message | Normalized inbound DTO every platform adapter produces before routing. Distinct from the persisted `Message` record | inbound message, channel event |
| Sender Attribution | Identity tracking: `Task.createdBy`, `TaskOrigin.senderDisplayName/senderId` | creator tracking |
| Thread Binding | Maps `(channelType, threadId)` to `(taskId, sessionKey)`. Routes thread replies to the task session. Auto-unbinds on completion | thread mapping, routing entry |
| Message Deduplicator | Prevents duplicate processing when a message arrives via multiple paths (webhook + Pub/Sub) | dedup engine, duplicate filter |

## Task & Review

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Task | Discrete unit of work. Status lifecycle: draft → queued → running → interrupted → review → accepted/rejected/cancelled/failed | job, work item, request |
| Task Status | Lifecycle state enum. Terminal: accepted, rejected, cancelled, failed. Non-terminal: draft, queued, running, interrupted, review | state, condition |
| Task Project ID | Persisted `Task.projectId` field naming the project checkout a task runs against. Standalone tasks set it directly; workflow tasks derive it from workflow-level project binding | task project, project field, repoId |
| Task Executor | Orchestrates lifecycle: dequeue, acquire worker, execute turn, cleanup, notify | task runner |
| Task Service | CRUD service with atomic status transitions and optimistic locking | task manager, task repository |
| Worktree | Isolated git worktree for a task declaring `needsWorktree: true`, stored at `~/.dartclaw/worktrees/<taskId>/`. Keyed by task UUID – shared identity fields select bindings but never derive paths. Lifecycle: create → execute → review → merge/reject → cleanup | sandbox directory, work directory |
| Diff | Computed difference between worktree and main branch. `DiffGenerator` → `DiffResult` | file changes, patch |
| Merge | Apply worktree changes to the project base branch. `MergeExecutor` → `MergeSuccess` or `MergeConflict`. Distinct from workflow Promotion | git merge, integration |
| Task Review | A lifecycle decision applied through the task UI, HTTP API, or `task_review` tool to a task identified by its full ID | review action, review decision |
| Scheduled Job | Recurring or one-shot job definition (`ScheduledJob`): id, schedule type, delivery mode, and `ScheduledJobType` (`prompt` or `task`). The scheduling entity – not a `Task` | cron job, trigger, timer |
| Schedule Type | The three schedule kinds a Scheduled Job can carry: `cron`, `interval`, `once` | frequency, recurrence, trigger type |
| Cron Expression | Parsed 5-field expression (`minute hour dom month dow`) supporting `*`, ranges, lists, and steps. Drives next-fire computation for `ScheduleType.cron` | cron string, cron schedule |
| Delivery Mode | How a finished Scheduled Job's result reaches the operator: `announce` (broadcast plus DM targets), `webhook` (HTTP POST), `none` | notification type, output mode |
| Scheduled Task Definition | Config-declared `scheduling.jobs` entry with `type: task` that the runner turns into a callback-backed Scheduled Job. Deduplicates against non-terminal tasks carrying the same schedule id instead of backfilling missed fires | auto-task, task schedule |
| Heartbeat | Periodic self-directed cycle driven by `HEARTBEAT.md`, run as the built-in `heartbeat` Scheduled Job: each fire reads the file and dispatches non-empty content in a session unique to that cycle. Not a liveness probe | health check, keepalive, heartbeat scheduler |

## Workflow Orchestration

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Workflow | Declarative, multi-step automation pipeline defined in YAML. Orchestrated deterministically by the Dart host (not prompt choreography). Consists of sequential steps, parallel groups, and iterative loops | pipeline, automation, flow |
| Workflow Definition | YAML schema describing a workflow: name, description, variables, ordered steps, and optional legacy `loops` compatibility declarations. Loaded from built-in assets or custom workspace directories | workflow template, workflow spec |
| Workflow Project | Top-level `WorkflowDefinition.project` authoring field declaring the default project binding for eligible workflow steps. Distinct from the persisted `Task.projectId` | step project, coding-step project |
| Workflow Run | Single execution instance of a Workflow Definition, with its own lifecycle (`pending` → `running` → `paused` → `completed`/`failed`/`cancelled`), context, and child tasks | workflow instance, workflow execution |
| Workflow Step | Atomic unit of work within a workflow. Step `type:` closes at `{agent, bash, approval, aggregate-reviews, foreach, loop}` (default: `agent`); only `agent` steps create a Task, while `bash`, `approval`, `aggregate-reviews`, and controller constructs (`foreach`, `loop`) are host-executed and zero-task. `aggregate-reviews` is a deterministic host-side step consolidating parallel review outputs into the fixed downstream keys `review_report_path`, `findings_count`, `gating_findings_count`. Steps can declare gates, budgets, `inputs:`, and `outputs:`. Runtime normalization groups steps into ordered action/map/parallel/loop control nodes | workflow action, pipeline step |
| Workflow Context | Accumulated key-value state passed between workflow steps. Steps read inputs from context and write outputs back. Persisted atomically after each step for crash recovery | workflow state, step data, pipeline state |
| WorkflowExecutor | Dart class that drives workflow execution: step dispatch, context management, budget tracking, parallel/loop orchestration. Lives in `dartclaw_workflow` | workflow engine, workflow runner |
| WorkflowRegistry | Manages available workflow definitions (built-in + custom). Loaded at startup from bundled assets and workspace directories | workflow catalog, definition store |
| Exit Gate | Boolean expression evaluated against Workflow Context after each loop iteration. When true, the loop terminates successfully | exit condition, break condition |
| Loop Iteration | A single pass through the loop body in an ordered workflow loop node. Tracked by `_loop.current.iteration` in runtime metadata. Terminates when the exit gate passes or `maxIterations` is reached | loop cycle, loop pass |
| Parallel Group | Set of contiguous steps with `parallel: true` that execute concurrently via `Future.wait()`. Results merged into context after all complete. Failures pause the workflow; resume re-runs only failed steps | concurrent group, parallel block |
| Foreach Iteration | A single execution of a foreach (map) step's body for one item in the iterated collection. Each iteration runs in its own Task, with its own Story Branch and worktree (when `worktree.mode: per-map-item`), and its own Promotion. Distinct from Loop Iteration | foreach pass, map iteration |
| Project Base Branch | The branch the workflow's Integration Branch was created from. Configurable per project – commonly `main` but could be `master`, `develop`, `trunk`. Determined from the `BRANCH` context variable; never hardcoded in workflow code | base ref, project main, default branch |
| Integration Branch | Workflow-owned branch (`dartclaw/workflow/<runId>/integration`) that aggregates work from all stories in a Workflow Run. Created from the Project Base Branch; up-merged to it at workflow completion | workflow branch, aggregation branch |
| Story Branch | Foreach-iteration-owned branch (`dartclaw/workflow/<runId>/<storyId>`) where one story's implementation runs. Created from Integration Branch HEAD at iteration start; promoted to Integration Branch on iteration success | iteration branch, task branch |
| Promotion | Merging a Story Branch's work into the Integration Branch after a story step completes. Performed by `promoteWorkflowBranchLocally`. Strategy is `merge` or `squash` per `gitStrategy.promotion`. Distinct from task-level Merge | story merge, integration merge, foreach merge |
| Promotion Conflict | The `WorkflowGitPromotionConflict` result returned when a Promotion's merge cannot complete mechanically. Common cause: two parallel stories edited the same scaffolding file. Trigger for agent-resolved merge | promotion failure, integration conflict |
| Resolution Attempt | One full invocation of the merge-resolve skill for a single Promotion Conflict, including Resolution Verification and Internal Remediation. Bounded by a per-attempt token ceiling. Retried up to `max_attempts` before escalation | resolve attempt, conflict-resolution try |
| Resolution Verification | Post-resolution checks performed by the merge-resolve skill: no remaining conflict markers and `git diff --check` clean. When discovered project conventions declare format/analyze/test commands, those run as additional verification. Failure triggers Internal Remediation within the same Resolution Attempt | post-merge check, sanity check |
| Internal Remediation | Retry loop inside a single Resolution Attempt: if Resolution Verification fails, the skill agent edits failing files and re-verifies, all within the attempt's token ceiling. Distinct from the outer `max_attempts` retry | inline retry, in-attempt fix |
| Serialize-remaining | Escalation mode that, after `max_attempts` Resolution Attempts fail, drains in-flight parallel foreach iterations and runs the rest with `max_parallel: 1`. Already-promoted iterations are kept; remaining iterations are re-queued serially. Serial iterations cannot Promotion-Conflict by construction | serial fallback, sequential recovery |
| Drain | Cancelling currently in-flight parallel foreach iterations when Serialize-remaining fires, and re-queueing them at the back of the now-serial queue | cancel-and-requeue, foreach teardown |
| Loop Escalation | `onMaxIterations: escalate` policy on a foreach/map-nested remediation loop: exhausting the iteration cap with residual gating findings settles the story needs-review/blocked; the run pauses for human approval when a still-open dependent needs the item, otherwise it advances and reports the item blocked. Distinct from Serialize-remaining | escalate policy, needs-review exhaustion |
| Teardown Interruption | A workflow task ending `TaskStatus.cancelled` while the run is still `running` – run teardown (shutdown SIGTERM) is the designed producer; operator task-cancel and emergency stop reach the same path. Resolves to the engine-side step outcome `cancelled` (unclaimable by agents) and is interrupted/resumable at every scope – the run pauses at its checkpoint and `workflow resume` re-runs the interrupted step; it does not mark the run failed or trigger git cleanup (one exception: a cancelled loop `finally` finalizer keeps failing the loop) | cancelled-as-interrupted, teardown cancellation |
| Workflow Run Artifact | Persistent record of a workflow run event – outcome, inputs/outputs, metadata. Stored alongside other workflow run state and queryable post-hoc. Examples: per-step output records, Resolution Attempt artifact | run artifact, structured artifact |

## Knowledge & Memory

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Context Engine | Server-side layer that synthesizes internal knowledge from wiki, temporal KG, and memory, ingests external sources through MCP, and serves compact citation-backed packets to agents over MCP | turn context assembler, context window assembler |
| Canonical Memory Entry | Stable UUID-addressed record with revision, role, provenance, and validated Markdown representation | memory chunk, indexed text |
| Memory Role | Closed discriminant for every canonical memory document kind: `index`, `topic`, `archive`, `observation`, `learning`, `audit`, `wiki`, `kg`. Only `topic` is index-eligible | memory type, category |
| Memory Provenance | The `MemorySourceRef` tuple every canonical record carries (origin kind, source locator, source event, caller, session ref). Origin kinds: `turn`, `journal`, `inbox`, `curation`, `migration`. Compare with `isExactReplayOf` for dedup and deletion authorization – structural equality is deliberately looser | source ref, origin |
| Memory Observation | Captured raw observation with a trust label and truncation flag, linked forward to the entries it produced. Never prompt-authoritative by location | raw memory, note |
| Memory Locator | Stable canonical entry UUID, or a native source locator for wiki, KG, knowledge-inbox, or eligible QMD results; accepted by `memory_read` and reopened through the source owner | generic source, row ID |
| Temporal Knowledge Graph | Time-scoped fact store (`entity, predicate, value, valid_from, valid_to, source, owner, invalidated_at`) with contradiction detection. Entities are canonicalized before storage | knowledge base, triple store |
| Knowledge Inbox | Drop-folder ingestion path whose files move through the fixed states `inbox`, `processed`, `quarantine`, `skipped` | upload folder, import queue |
| Knowledge Hub | Operator-facing browse/search surface over the knowledge layers (`all`, `wiki`, `kg`, `memory`, `inbox`) | knowledge UI, memory browser |
| Search Index | Rebuildable FTS5 projection of canonical topic, archive, observation, and learning entries. QMD Markdown search is opt-in; audit entries are never indexed | source of truth, search database |
| Full-Text Index | `FullTextIndex` abstraction over backend-native FTS (FTS5 `bm25()` / PostgreSQL `tsvector`). Search, upsert, and delete all carry the tenancy (`user_id`) dimension – the multi-user isolation mechanism (ADR-045) | FTS layer, search abstraction |
| QMD | Optional external hybrid-embedding search daemon managed as a subprocess over loopback HTTP. Never a hard dependency – the search backend falls back to FTS5 when QMD is unreachable | search daemon, embeddings service |
| citation packet | Compact synthesized response where each claim carries source references resolvable to wiki, temporal KG, memory, or external MCP source material | answer blob, summary packet |
| `context_research` | MCP synthesis tool that retrieves across internal knowledge layers and returns a citation packet | context engine tool, research outpost, search summary |
| wiki provenance | Frontmatter field recording who authored a wiki page's content. `human-authored` and `hybrid` rank as search-trusted; `llm-authored` ranks trusted while `sources` is populated; any other stored value is preserved untouched and reported by wiki lint | authorship, page origin |
| `hybrid` | The wiki provenance a page takes on when a `human-authored` or `hybrid` page gains machine-synthesized content, so it is neither relabelled as machine-authored nor claimed as sole machine authorship | mixed, merged provenance |
| supplement section | A `## Supplement from <source> (<date>)` block appended to an existing wiki page. Reachable only when the merge turn declares the new material unrelated to the stored page | append block, merge section |
| wiki collision | An ingestion whose chosen slug already has a stored page. Settled by a page-scoped merge turn and reported as *integrated* (the merged body replaced the stored one), *unchanged* (nothing but the `sources` union moved) or *supplement* (the merge called the material unrelated, so it was appended) | overwrite, merge conflict |
| merge declaration | The merge turn's reply for one collision: `merge`, `integrated_from`, `removed_content` and the merged body. The model declares how to merge; the host decides whether the declaration is admissible | merge decision, merge result |
| shrink floor | The compile-time share (0.8) of a stored body an integrated merge must keep while declaring no `removed_content`; below it the write is refused and the source quarantined | shrink guard, size check |

## Tool Surface

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Host MCP Endpoint | The host-served `POST /mcp` route implementing MCP Streamable HTTP with bearer-or-loopback auth and bounded bodies. The direction where DartClaw *serves* tools to provider binaries; container executions reach it only through the per-authority framed bridge | MCP server (ambiguous with configured external servers) |
| outbound MCP client | DartClaw's client-side MCP runtime for connecting to configured external MCP servers, discovering tools, and calling them through the egress guard. Pooled per server with idle teardown and ping-based reuse | outpost, outpost client, external tool bridge |
| surface_tools | Per-server allowlist filtering an external server's advertised tools down to what harnesses see. Configured names are validated against the live server; an unknown name is a configuration error | exposed tools, tool allowlist |
| MCP Network Class | Per-server network risk classification (`local`, `private`, `public`) used to gate an outbound server's blast radius | trust tier, network tier |
| Outbound Governance | Per-server sliding-window call limit and token budget enforced before an outbound call. Denials are distinct from egress-guard denials | rate limiting, quota |

## Project Registry

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Project | Git checkout a task or workflow executes against: id, remote URL, local path, default branch, clone strategy, PR settings, status. Declared in the `projects:` config section or created at runtime | repo, repository, workspace |
| Project Status | Lifecycle enum: `cloning`, `ready`, `error`, `stale` | state, phase |
| Local-Only Project | A Project with an empty `remoteUrl` – the single discriminator that short-circuits fetch, push, and PR logic. The reserved id `_local` denotes the server's current directory | isLocal flag, default project |
| Default Branch | Per-project default git branch (`branch` in config, `defaultBranch` at runtime). Resolved after an explicit requested branch and before `HEAD`. Not the workflow's Project Base Branch, which is resolved per run | base branch, main branch |

## Configuration & Platform

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Composed Config | `DartclawConfig` decomposed into ~14 typed sections (`ServerConfig`, `AgentConfig`, `AuthConfig`, etc.) | settings, configuration model |
| Reconfigurable Service | Runtime service that can absorb config updates without a full restart via `ConfigNotifier` and `Reconfigurable`. `ConfigDelta` + `watchKeys` is the exchange format | hot reload target, live config |
| Extension Parser | Plugin point: `registerExtensionParser()` + `config.extension<T>()` for custom config sections | custom parser |
| Behavior Files | User-editable agent identity files: SOUL.md, USER.md, TOOLS.md, AGENTS.md, HEARTBEAT.md. Cascaded into the system prompt | config files, manifest |
| Platform Capabilities | Immutable, effect-free OS capability policy (`PlatformCapabilities`): shell policy, process-termination semantics, POSIX signal and file-permission availability, container-isolation availability. Values are policy only – consumers own the I/O and the remediation message | platform detection, OS check (bare "capability" is ambiguous) |
| Bang Operator | Agent Skills convention for executing a literal shell command in a skill prompt (e.g. `` !`git status` ``). The command runs before the LLM sees the rendered skill; stdout replaces the placeholder. Literal command text is fixed at skill-authoring time; `$ENV_VAR` references expand at runtime. Supported by both Claude Code and Codex harnesses | shell prefix, shell injection |
| Env-var Injection | DartClaw mechanism for passing dynamic values into a skill agent process: the orchestrator sets environment variables on agent process spawn; the skill's Bang Operator commands reference them as `$VAR`. Lets static skill text consume runtime-determined values | env injection, environment passing |
| Fitness Function | Executable architecture boundary check – the `dev/tools/arch_check.dart` governance script enforcing package, barrel, LOC-ceiling, and dependency invariants | architecture test, governance check |

## Operator Interface

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Gateway Token | The single bearer credential (64 hex chars, file `gateway_token`) used for API auth and as the HMAC signing key for session cookies. Rotation invalidates all cookies at once (ADR-006). Unrelated to the Host Gateway | API key, auth token, password |
| Session Cookie | Stateless HMAC-signed browser cookie derived from the Gateway Token. Not a server-side session store, not a JWT, and unrelated to a conversation Session | auth cookie, JWT, login session |
| Trellis Template | Paired `.html` + `.dart` template under `templates/`, loaded from a manifest and rendered as a page or an HTMX fragment | view, partial |
| SSE Broadcast | The sanctioned Server-Sent-Events plumbing for pushing live updates to the web UI, including the bridge that forwards `DartclawEvent`s to connected browsers | websocket, event stream |
| Runner | Operator-facing name for leased execution capacity, exposed by `/api/runners` and the CLI. The same thing the coordinator internally calls a Worker | worker (in API/CLI surfaces), pool slot |
| Connected Mode | Default CLI execution mode where commands target a running DartClaw server over the loopback HTTP/SSE API instead of inspecting local files or running in-process | live mode, server mode |
| Standalone Mode | Explicit CLI mode (`--standalone`) that bypasses the server API and runs local workflow logic or direct local DB inspection | offline mode, local mode |
| API Client | The CLI-only loopback HTTP client (`DartclawApiClient`) used for connected commands, auth resolution, error mapping, and SSE workflow streaming | HTTP helper, REST wrapper |
| Server Detection | The CLI health probe that checks the configured loopback server before choosing connected or standalone behavior | server probe, health check |

## Observability & Alerting

| Term | Definition | Avoid (synonyms) |
|------|-----------|-------------------|
| Event Bus | Lightweight typed pub/sub using `StreamController.broadcast()`. The sealed `DartclawEvent` hierarchy is the published exchange format; subscribers never reach into domains (ADR-011) | event system, message bus |
| Turn Trace | Best-effort telemetry record of one turn (session, task, runner, model, provider, token counts, bounded tool-call detail) written asynchronously to the `turns` table. Queried as *traces* by API and CLI. Never called an audit | span, execution log, audit |
| Task Event | Append-only entry on a task's user-visible timeline (`statusChanged`, `toolCalled`, `compaction`, `taskError`, …), persisted synchronously and losslessly | activity log entry, audit event |
| Alert Routing | Classification of a `DartclawEvent` into an alert type and severity (`info`, `warning`, `critical`), resolution of configured targets, and throttled delivery | notifications, alert dispatch |
| Health Status | Aggregated runtime health (`healthy`, `degraded`, `unhealthy`) projected from the host Worker's lifecycle (`WorkerState`) by `healthStatusForWorkerState` – the workspace's only such mapping – plus uptime, session count, and database size. Never derived from, and never a synonym for, Provider Availability | liveness, readiness |

## Overloaded Terms

| Term | Context A | Meaning A | Context B | Meaning B |
|------|-----------|-----------|-----------|-----------|
| Session | Conversation & Session | Durable conversation container with persisted messages | Channel Integration | The messaging platform's own chat-thread concept |
| Session | Operator Interface | The HMAC-signed browser Session Cookie | Turn Orchestration | Logical-Agent Session – a hidden durable session pinned to one Logical Agent |
| Message | Channel Integration | `ChannelMessage` – normalized inbound DTO from any platform | Conversation & Session | Persisted message record inside a Session |
| Thread | Channel Integration | Google Chat thread within a Space | Turn Orchestration | Not used – DartClaw is single-threaded (one Dart isolate) |
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
| Type | Workflow Orchestration | Step type – workflow dispatch kind: `agent`, `bash`, `approval`, `foreach`, `loop`, `aggregate-reviews` | Scheduling | Job kind – `prompt` or `task` |
| Merge | Task & Review | `MergeExecutor` applying a task worktree to the project base branch | Workflow Orchestration | Promotion – a Story Branch merged into the Integration Branch |
| Project | Project Registry | `Project` – the git checkout record and its clone lifecycle | Workflow Orchestration | `WorkflowDefinition.project` – the authoring field binding steps to a checkout |
| Tool | Tool Surface | An MCP tool published to provider binaries or consumed from an external server | Provider Mediation | A Canonical Tool Taxonomy name (`shell`, `file_read`, …) |
| Drain | Workflow Orchestration | Cancelling and re-queueing in-flight foreach iterations on Serialize-remaining | Runtime Governance | `/resume (drain queue)` – replaying the paused message queue |

## Changelog

- 2026-08-25: Added Named Credential Store under `provider-mediation` for the 0.24.3 credential and secrets CLI contract.
- 2026-08-20: Split the overloaded "health" term: Health Status is now stated as the single projection of the host Worker's lifecycle, and Provider Availability is registered beside it as the separately derived provider-mediation term, with an Overloaded Terms row demarcating the two.
- 2026-08-17: Added the 0.24.1 knowledge-inbox wiki vocabulary under `knowledge-memory`: wiki provenance, `hybrid`, supplement section, wiki collision, consolidation debt, declared drop.
- 2026-08-20: Recut the wiki-collision vocabulary for the merge contract: *wiki collision* now names the settled merge, *merge declaration* and *shrink floor* added, *consolidation debt* and *declared drop* removed with the surfaces that reported them.
- 2026-08-15: Added the 0.24.2 subscription-credential vocabulary under `provider-mediation` (ADR-053): Subscription Credential, Dedicated Credential Store, Operator Login Store, Credential Mode, Credential Resolution, Credential Health State, Renewal Deadline, Codex Refresh Authority.
- 2026-08-14: Regrouped the whole glossary onto the 15 bounded contexts registered in `dev/architecture/context-map.md` (closes D-4): the `##` section *is* the context, so the ~50 ad-hoc "Bounded Context" labels and their column are gone. Added the missing Scheduling vocabulary under `task-review` (closes D-5) and first-time coverage for `project-registry`, `tool-surface`, `operator-interface`, and `observability-alerting`. New terms elsewhere: Security Profile, Worker Capacity Gate, Session Lock, Context Monitor, Prompt Scope, Memory Role/Provenance/Observation, Temporal Knowledge Graph, Knowledge Inbox, Knowledge Hub, QMD, Platform Capabilities. Added overloads for Message, Event, Audit, Runner, Context, Budget, Merge, Project, Tool, and the channel-task Bridge. Dropped "Dependency Reversal" and "Outpost Pattern" (generic jargon; "outpost" is already an Avoid synonym for the outbound MCP client) and the degenerate Worker/Guard/Verification overload rows.
- 2026-08-12: Retired the pre-0.24 Credential Proxy entry (redirect to Host Gateway / Container Bridge) and updated Container Isolation to the shipped 0.24 model (per-authority single-use container, `no-new-privileges`, framed bridge as the only egress path).
- 2026-08-12: Added 0.24 execution-isolation terms – Execution Policy, Principal, Container Authority, Host Gateway, Container Bridge (`dartclaw_bridge`); extended the Bridge overloaded-term row with the container-bridge sense.
- 2026-08-09: Replaced legacy pool terminology with Execution Coordinator, Execution Lease, and Execution Fingerprint; capacity is lease-based and independent from optional worker reuse.
- 2026-06-12: Added 0.19 Context Engine, Turn Context Assembler, outbound MCP client, `context_research`, egress guard, and citation packet terms.
- 2026-08-23: Retired the task-category meaning from the overloaded Type row; workflow step and scheduled-job types remain distinct.
- 2026-04-25: Added 0.16.4 agent-resolved-merge terms (workflow git) and the Agent Skills terms Bang Operator and Env-var Injection.
- 2026-08-23: Clarified that workflow-authored step types remain workflow execution metadata while task dispatch uses explicit `readOnly` and `needsWorktree` declarations.
- 2026-04-11: Added 0.16 terms for alert routing, compaction observability, and reconfigurable service; updated workflow ownership to `dartclaw_workflow`; added fitness function as a 0.16.3 architecture-governance term.
- 2026-04-04: Added the Workflows section for the 0.15 milestone.
- 2026-03-24: Reassigned thread binding, sender attribution, review commands, and runtime governance to concrete capability areas after removing the former shared bounded context.
- 2026-03-23: Initial extraction from architecture docs, CLAUDE.md, and codebase.
