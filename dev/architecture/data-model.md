# DartClaw Data Model & Persistence

Every persistent store DartClaw writes: which are authoritative and which are derived, the PostgreSQL schema, the file
layout under the data directory, how records reference each other across stores, write safety, retention, and backup.
The behavior of the domains that use these stores belongs to their own documents: [Task Execution](task-execution-architecture.md),
[Session & State](session-state-architecture.md), [Workflow](workflow-architecture.md) and
[Channel Messaging](channel-messaging-architecture.md). Connection security is in
[Security Architecture](security-architecture.md); package topology and composition are in
[System Architecture](system-architecture.md).

**Current through**: 0.28.0

---

## 1. Storage Authorities

**Files hold canonical documents and standalone execution state. PostgreSQL holds server relational records and
rebuildable search projections.** Design rationale: [ADR-002](../adrs/002-file-based-storage.md) (files for human-inspectable
documents), [ADR-060](../adrs/060-postgresql-only-storage.md) (PostgreSQL for server relational data, files for standalone runs).

| Store | Holds | Authority | If lost |
|-------|-------|-----------|---------|
| Session files (`sessions/`) | Session metadata, conversation state, message transcripts, attachments | Canonical | Unrecoverable without a file backup |
| Memory workspaces (`workspace/`, `agents/<id>/workspace/`) | Canonical memory corpus, wiki, behavior files | Canonical | Restore from workspace Git or a file backup |
| PostgreSQL authoritative tables | Tasks, goals, executions, workflow runs, traces, task events, knowledge facts | Authoritative | Restore from `pg_dump` |
| PostgreSQL `memory_chunks`, `conversation_chunks` | Lexical search projections | Derived | `dartclaw rebuild-index` |
| PostgreSQL `memory_vectors`, `conversation_vectors` | Optional pgvector projections | Derived | `dartclaw rebuild-index` (hybrid mode) |
| `standalone/execution.json` | Task, goal, execution, workflow-run, trace and event records of standalone runs | Authoritative for standalone | Unrecoverable without a file backup |
| Other files (`projects.json`, `kv.json`, `usage.jsonl`, `audit-*.ndjson`, `thread-bindings.json`, credentials) | See [§2](#2-data-directory-layout) | Per file | Per file; see [Backup & Recovery](#9-backup--recovery) |
| `turn_state.json`, `webhook_deliveries/` | Active-turn recovery, webhook dedup | Instance-local, transient | Starts empty |

Two execution modes pick the relational store. A server (`dartclaw serve`) requires PostgreSQL 14 or newer. A standalone
workflow run (`dartclaw workflow run --standalone`) uses no database: it composes file repositories behind the same
repository contracts, composes no knowledge graph or search service, and keeps its sessions, KV and turn state under
`standalone/`. Connected CLI commands use the server's PostgreSQL through its HTTP API. Database histories are never
copied into or out of a standalone checkpoint. Leftover SQLite files from releases before 0.27 (`dartclaw.db`,
`search.db`, `vectors.db`, `state.db`, `webhook_deliveries.db`) are never opened.

[![Storage authorities and data directory](diagrams/data-storage-layout.svg)](diagrams/data-storage-layout.svg)

---

## 2. Data Directory Layout

`<data_dir>` is `server.data_dir` (default `~/.dartclaw`). Marks: **[C]** canonical, **[D]** derived and rebuildable,
**[L]** instance-local, **[R]** reproducible from the binary or configuration.

```
<data_dir>/
├── dartclaw.yaml                   [C] Config (default location; --config may point elsewhere). Every write first copies to dartclaw.yaml.bak
├── gateway_token                   [C] Gateway auth token
├── credentials/                    [C] Owner-only: named/<name>.json, claude/, codex/ provider stores
├── kv.json                         [C] Key-value store: usage_daily:<date>, session_cost:<sessionId>, prune_history, counters
├── usage.jsonl (+ usage.jsonl.1)   [C] Token/cost events, append + size rotation
├── audit-YYYY-MM-DD.ndjson         [C] Guard audit, one partition per day
├── turn_state.json                 [L] Active turn per session (crash recovery)
├── webhook_deliveries/             [L] One marker file per webhook delivery id
├── thread-bindings.json            [L] Channel thread bindings
├── pending-schedule-changes.json   [L] Parked schedule_upsert writes awaiting operator approval
├── projects.json                   [C] Runtime-created projects only (config-defined ones are not persisted)
├── projects/<projectId>/           [R] Git clones (re-cloneable)
├── google-chat-user-oauth.json     [C] Google Chat user OAuth refresh token (owner-only)
├── google-chat-subscriptions.json  [L] Google Chat space-event subscriptions
├── channels/signal/signal-sender-map.json   [L] Signal UUID to phone mapping
├── sessions/
│   ├── .session_keys.json          [C] Deterministic session key to session UUID index
│   └── <uuid>/
│       ├── meta.json               [C] Session record plus nested conversationState
│       ├── messages.ndjson         [C] Transcript, one JSON message per line
│       ├── conversation/           [C] attempts/, queues/, manifests/ records, one <id>.json each
│       └── attachments/            [C] <attachmentId>.json + <attachmentId>.data
├── workspace/                      Owner memory workspace (principal `owner`)
│   ├── MEMORY.md                   [C] Bounded index; its revision prefix is the commit marker of a corpus write
│   ├── memory/topics/<topic>.md    [C] Topic documents
│   ├── memory/YYYY-MM-DD.md        [C] Daily observations
│   ├── MEMORY.archive.md           [C] Archived entries
│   ├── MEMORY.audit.md             [C] Content-free deletion audit (never indexed)
│   ├── learnings.md, errors.md     [C] Learning and error roles (newest 50 each)
│   ├── memory/legacy/              [C] Opaque pre-canonical remainder preserved by preflight
│   ├── wiki/                       [C] Shared wiki pages, read in place (not indexed in PostgreSQL)
│   ├── SOUL.md USER.md TOOLS.md AGENTS.md HEARTBEAT.md   [C] Behavior files
│   ├── .dartclaw-memory-corpus.json  [D] Authenticated member manifest (rebuilt from the Markdown)
│   ├── .dartclaw-memory-index.json   [D] Derived-index health evidence
│   ├── .dartclaw-memory-transaction(.json|/)  [L] Journal and staging of an in-flight corpus write
│   └── .git/                       Workspace version control
├── agents/<id>/
│   ├── identity.json               [C] Host admission marker, exactly {"agentId":"<id>"}\n
│   └── workspace/                  [C] Named-agent behavior, skills, personal memory (same layout as above; principal agent:<id>)
├── tasks/<taskId>/artifacts/       [C] Artifact files of a task (diff.json, conflict.json, PR instructions, ...)
├── worktrees/<taskId>/             [R] Git worktree of a task that declares one
├── workflows/
│   ├── built-in/                   [R] Shipped definitions, materialized with .dartclaw-managed.json fingerprints
│   ├── custom/                     [C] Operator-authored definitions
│   └── runs/<runId>/               [C] context.json (full WorkflowContext) and runtime-artifacts/
├── workflow-workspace/             [R] Default workflow agent workspace (AGENTS.md managed unless edited)
├── standalone/                     Standalone workflow state
│   ├── execution.json              [C] Versioned checkpoint; execution.json.lock is its sidecar OS lock
│   ├── execution.owner.lock        [L] One standalone execution process per data directory
│   ├── sessions/  kv.json  turn_state.json   Isolated copies of the server-side stores
├── containers/  bridge/  models/   [R] Per-container state, delivered bridge binary, downloaded embedding model
├── feeds/  logs/                   [L] Shell-job output files, application logs
└── .claude/  .codex/  .agents/     [R] Provisioned skills and agent definitions
```

The PostgreSQL database is configured separately (`database.url` or `database.credential`); it is not under `<data_dir>`.
The file stores and the database are separate backup authorities.

---

## 3. PostgreSQL

### 3.1 Backend

`DatabaseBackend`, `DatabaseStatement` and `DatabaseBackendFactory` are dependency-free ports in `dartclaw_kernel`.
`PostgresBackend` (`dartclaw_core`) is the only implementation; goal, task, execution, workflow-run, trace, event and
knowledge-graph persistence and the full-text and vector indexes all share its single pool.

- **Pool.** One bounded pool; `database.pool_size` defaults to 5. Open verifies server version 14+ and warns when the
  runtime role is a superuser. The opener (runtime or CLI) owns closure; repositories never close the pool.
- **Statements.** Positional `?` placeholders; values are `int`, `double`, `String`, `Uint8List` or `null`; booleans are
  `0`/`1`; timestamps are ISO 8601 `TEXT`.
- **Transactions.** `transaction()` leases one connection for explicit `BEGIN` and `COMMIT`/`ROLLBACK`. Calls through the
  owning backend from inside the body join that connection; a nested transaction throws `NestedTransactionError`.
  `DatabaseExecutionRepositoryTransactor` delegates to this, so task, execution and step writes commit together.
- **Failure contract.** `PostgresDispatchPolicy` retries a failure observed before dispatch (3 attempts, 50 ms apart; pool
  wait ceiling 30 s). A failure after dispatch surfaces `StorageUnknownOutcomeException` and is never replayed; callers
  must verify state before retrying.
- Connection posture (TLS rules, credential references) is owned by [Security Architecture](security-architecture.md).

### 3.2 Schema gate

`PostgresSchemaGate` (`dartclaw_core/lib/src/storage/postgres_schema_gate.dart`) classifies the database before any
repository is built:

- **Empty schema** (no tables in `current_schema()`): bootstrap every authoritative and search table, the GIN indexes and the
  marker table `dartclaw_schema (id = 1, epoch = 1)` in one transaction.
- **Current schema**: validated by reading the catalog, with no mutation. The identity in
  `schema_identity.dart` is required-only: every table, column (type, nullability, default, primary key) and index the
  runtime reads must match; extra objects and columns are tolerated, which is why the `tasks.type` column survives unused.
- **Anything else** (wrong epoch, missing or partial objects) refuses with `SchemaIncompatibleException` and
  back-up-then-recreate guidance. There is no migration runner.
- **One admitted transition**: an epoch-1 store whose only difference from the manifest is a missing
  `workflow_runs.origin_json` gets the column added inside a transaction that re-validates the whole schema before commit
  (a failure rolls back to the exact legacy shape). Only `prepare` (reached by `dartclaw serve`) applies it;
  `validateCurrent`, used by read-only callers, refuses that shape and names `serve` as the remedy. See
  [ADR-045](../adrs/045-pluggable-database-backend.md) (0.28 amendment).
- **Vector projection**: `memory_vectors` and `conversation_vectors` are validated and created separately, only in hybrid
  mode and only after the authoritative schema validates. `preflightVectorExtension` first proves an
  administrator-installed pgvector in `public` (cast, `vector_dims`, `vector_norm` and the `<=>` operator work for the
  runtime role). Lexical-only startup never touches the extension. A partial or mismatched vector projection refuses with
  derived-only recovery guidance ("reset and rebuild only the vector tables").
- `validatePostgresFtsLanguage` rejects a `database.fts_language` (default `english`) that is not a `pg_ts_config` name.

### 3.3 Serving interlock

A serving runtime (`serving: true`, set for every non-headless composition) opens a dedicated connection and takes the
session advisory lock `pg_try_advisory_lock(0x64617274636c6177)` before the schema gate runs, so two servers cannot share
a database. Headless runs and one-shot maintenance commands (`rebuild-index`, `cleanup`) do not take it.

`PostgresInterlock` re-checks ownership every 60 s and on connection closure. On loss it quarantines the backend: every
statement and prepared-statement operation fails before dispatch with a "recovery pending" error. Recovery retries every
1 s for up to 10 minutes, reacquires the lock, revalidates the server version and the current schema, then lifts the
quarantine. A competing owner, an unsupported server version, a failed schema check or an exhausted budget is fatal
(`exit(1)`). Shutdown disables recovery, closes the pool,
then releases the dedicated connection.

### 3.4 Tables

All timestamps are ISO 8601 `TEXT`; JSON columns are `TEXT`. Source: `schema_identity.dart` (the bootstrap statements).

| Table | Row | Notes |
|-------|-----|-------|
| `tasks` | Task | `status`; `version` (see below); `config_json` (model override, budget, `origin` TaskOrigin, push-back state); `worktree_json`; `created_by`; `max_retries`/`retry_count`. `agent_execution_id` FK to `agent_executions` (`ON DELETE RESTRICT`). Soft refs: `goal_id`, `project_id`, `workflow_run_id`, `step_index`. `type` is an inert placeholder (`'task'`); a retained `research`/`coding` value makes the task read as a refusal marker. Indexes: `status`, `type`, `(status, type)`, `workflow_run_id` |
| `agent_executions` | AgentExecution, the runtime primitive under both tasks and workflow steps | `provider`, `model`, `workspace_dir`, `container_json`, `budget_tokens`, `harness_meta_json`, `started_at`, `completed_at`. `session_id` is a soft ref to a session directory. Indexes: `session_id`, `provider` |
| `workflow_step_executions` | Workflow-only metadata of a step task | PK `task_id` (FK `ON DELETE CASCADE`), `agent_execution_id` (FK), `workflow_run_id` (soft), `step_index`, `step_id`, `step_type`, `git_json`, `provider_session_id`, `structured_schema_json`, `structured_output_json`, `follow_up_prompts_json`, `map_iteration_index/total`, `step_token_breakdown_json`. Indexes: `(workflow_run_id, step_index)`, `agent_execution_id` |
| `task_artifacts` | Artifact record | FK `task_id` `ON DELETE CASCADE`; `kind` is `diff`, `document`, `data`, `branch` or `pr`; `path` is the absolute file path under `tasks/<taskId>/artifacts/`, or the URL/branch name for `pr`/`branch` kinds. Index: `task_id` |
| `goals` | Goal | `parent_goal_id` (soft; `GoalService` allows two levels), `mission`, `max_tokens`. Index: `parent_goal_id` |
| `task_events` | Append-only task timeline | `task_id` (soft), `kind` (enum name; the legacy `error` still reads as `taskError`), `details` (JSON, shape per kind). Awaited insert: `TaskEventRecorder` emits `TaskEventCreatedEvent` only after the insert succeeds, and a failed insert propagates. Indexes: `task_id`, `(task_id, kind)`, `timestamp` |
| `turns` | TurnTrace, one row per task turn | `session_id`, `task_id`, `runner_id`, `model`, `provider`, token counters (input, output, cache read, cache write), `is_error`, `error_type`, `tool_calls` (JSON envelope `{records, count, failedCount, truncated}`). No FKs. Indexes: `session_id`, `task_id`, `started_at`, `model`, `provider` |
| `workflow_runs` | WorkflowRun | `definition_name`, `status`, `definition_json` (snapshot taken at start), `variables_json`, `context_json`, `execution_cursor_json`, `workflow_worktree_json` (`{"items": [...]}`), `origin_json`, `total_tokens`, `current_step_index`, `error_message`. Indexes: `status`, `definition_name` |
| `workflow_run_migrations` | Required by the identity; no runtime reader | `name`, `applied_at` |
| `kg_facts` | Temporal knowledge-graph fact | `entity`, `predicate`, `value`, `valid_from`/`valid_to`, `source`, `owner`, `invalidated_at`, `invalidation_reason`. A fact is invalidated, not deleted. Index: `(entity, predicate, valid_from, valid_to)` |
| `memory_chunks` | Derived memory search row | `user_id` (principal), `locator`/`entry_id`/`entry_revision`, `role`, `provenance`, `source`, `category`, `chunk_index`, `text`, `content_tsv tsvector NOT NULL` with a GIN index |
| `conversation_chunks` | Derived conversation search row | `message_id`, `user_id`, `session_id`, `role`, `chunk_index`, `text`, `created_at`, `content_tsv` with a GIN index |
| `memory_vectors`, `conversation_vectors` | Optional derived vectors | PK `(user_id, document_id, chunk_index)`; `content_hash`, `model_fingerprint`, `dimension`, `embedding public.vector`. Index: `(user_id, model_fingerprint, dimension)` |
| `dartclaw_schema` | Epoch marker | Single row `id = 1`, `epoch = 1` |

**Optimistic concurrency.** `tasks.version` increments on every update, and `update` matches on `(id, version)`;
`updateIfStatus` additionally matches the expected `status` and returns `false` on a lost race. `workflow_runs` updates
take optional `expectedStatus` and `expectedUpdatedAt` compare-and-set guards, and `transitionStatus` is a status CAS.
Neither table uses row locks.

**Run state in two layers.** `workflow_runs.context_json` holds the status and context snapshot; the full
`WorkflowContext` is also written atomically to `workflows/runs/<runId>/context.json`. Resume reads the run record when it
has an execution cursor or a full `data` snapshot, so an older sidecar cannot undo a committed approval, and falls back to
the sidecar for lightweight legacy snapshots. `origin_json` is written once by `insert`; `update` never touches it, and SQL
`NULL` reads as surface `unknown`. A non-null value that does not decode throws rather than inventing provenance.

**SQLite import.** A one-shot, stopped-source Python utility (`dev/tools/migrate_sqlite_to_postgres.py`, source checkouts
only) imports the authoritative SQLite shape of 0.26.1 and 0.26.2 into an empty current schema. It never imports derived
indexes or canonical files and offers no sync or reverse migration. Procedure: [PostgreSQL guide](../../docs/guide/postgresql.md).

---

## 4. Standalone Execution Checkpoint

`FileExecutionStore` (`dartclaw_core/lib/src/storage/file_execution_store.dart`) owns `standalone/execution.json`, a
versioned JSON document (`schemaVersion: 1`) with the maps `tasks`, `agentExecutions`, `workflowSteps`, `workflowRuns`,
`artifacts`, `goals`, `events` and `traces`. `File*Repository` adapters (tasks, goals, agent executions, step executions)
and `FileWorkflowRunRepository` implement the same contracts as the database repositories.

- **Transactions.** `transaction()` stages every joined repository write in one draft and publishes it once through
  `atomicWriteJson` (owner-only permissions) after the action succeeds; a failed action leaves the previous file untouched.
  Nested transactions throw.
- **Concurrency.** Every operation reloads the checkpoint inside a `RepoLock` (in-process) plus an OS lock on
  `execution.json.lock` (across CLI processes), so parallel steps and separate processes cannot publish stale whole-store
  snapshots.
- **Corruption.** A malformed or unsupported checkpoint refuses to load; it is never reset.
- **Origin.** `workflowRuns` records carry `origin` as a key; a checkpoint from before origin existed reads as `unknown`,
  and `update` keeps the stored origin.
- **Single owner.** `StandaloneExecutionLease` takes `standalone/execution.owner.lock` so one execution process owns the
  directory. This protects the per-process caches of the standalone session and KV services while allowing parallel steps
  inside the owner. Lifecycle-only control (`workflow status`, pause, cancel) reads and updates the checkpoint through its
  file lock without taking the lease.
- **Recovery.** A standalone run starts only the requested run; automatic recovery of incomplete runs
  (`recoverIncompleteRuns`) happens only in server startup.
- **Durability.** Atomic replacement and process-crash recovery, not a power-loss guarantee. Back up with every standalone
  process stopped.

Provider credentials, workflow definitions and per-run context/artifact files stay in their normal locations.

---

## 5. File-based Stores

### Sessions and messages

`SessionService` and `MessageService` (`dartclaw_core/lib/src/storage/`) own `sessions/`. Entity semantics (types, keys,
scoping, locking) are in [Session & State](session-state-architecture.md).

- **`meta.json`**: the `Session` record (`dartclaw_kernel/lib/src/models.dart`) plus a nested `conversationState`
  (`ConversationState`: revision, submissions, attempts, branches, visible message identities, effective context). Rewritten
  atomically under a per-file `RepoLock`. `workspaceAgentId` and `workspaceDir` are written together; a durable session
  keeps the workspace binding admitted at creation, and a removed or relocated binding refuses branch and fork rather than
  rewriting history.
- **`messages.ndjson`**: one `Message` JSON object per line. The cursor is the 1-based line number, assigned on read, never
  stored. An append requires the session directory to exist (a code-enforced reference). The only in-place rewrite is a
  queued user message, which keeps its identity and cursor.
- **`.session_keys.json`**: maps deterministic session keys to UUIDs. `getOrCreateByKey` is idempotent under a lock.
- **`attachments/`**: `<id>.json` metadata and `<id>.data` bytes, 10 MiB per attachment; the conversation state records a
  manifest (`id`, `filename`, `mediaType`, `size`, `digest`) per attachment.
- **`conversation/`**: durable per-submission records (`attempts/<attemptId>.json`, `queues/<queueId>.json`,
  `manifests/<submissionId>.json` with the accepted attachment list). Each must match the submission in
  `meta.json`'s `conversationState` (id, revision, message, payload digest, work state); a mismatch or a missing record throws
  rather than being repaired (`conversation_service_persistence.dart`).
- **Process-retained (temporary) conversations** never touch disk: they live in bounded memory (32 sessions, 500 messages
  per session, 20 attachments per session) and are excluded from every durable observer and index. Creation pins
  `provider`, `securityProfile` and `executionMode` from the host's temporary-conversation capability
  (`POST /api/sessions`, `session_routes.dart`), like a logical-agent session.

### Memory corpus

The canonical memory of one workspace is a closed set of Markdown documents managed by `MemoryCorpusService`
(`dartclaw_core/lib/src/memory/`). A *principal* ties a directory to its derived rows: the owner workspace is principal
`owner`; a named agent's `agents/<id>/workspace` is `agent:<id>`. Only an agent whose tool policy grants personal-memory
access gets corpus services, and a project working directory never changes the pairing. The role of a path is fixed
(`MemoryRole`): `index`, `topic`, `archive`, `observation`, `learning`, `error`, `audit`, `wiki`, `kg`. Only `topic` is
index-eligible (`isIndexEligible`). Every canonical record carries a `MemorySourceRef` (origin kind, source locator, source
event, caller, session ref); the origin kind is one of `turn`, `journal`, `inbox`, `curation`, `migration`. Deduplication and
deletion authorization compare refs with `isExactReplayOf`, which requires source event, caller and session ref to be present
on both sides and equal.

- **Commit protocol.** A multi-file write stages target bytes and backups in `.dartclaw-memory-transaction/`, writes the
  journal `.dartclaw-memory-transaction.json` atomically, replaces each target with `MEMORY.md` last, records the manifest,
  then cleans up. `MEMORY.md` carries the collection revision, so it is the commit marker. Recovery after a crash rolls the
  journal forward if `MEMORY.md` shows the target revision and rolls back from the backups otherwise; an inconsistent state
  raises `MemoryCorpusRecoveryRequired` and the corpus stays unavailable.
[![Memory corpus commit and crash recovery](diagrams/data-memory-commit.svg)](diagrams/data-memory-commit.svg)

- **Manifest.** `.dartclaw-memory-corpus.json` records each member's role, length, digest and record ids so ordinary reads and
  sparse writes open only the relevant documents. It is coordination state: a missing manifest is rebuilt from the Markdown, a
  semantic mismatch triggers stopped-edit reconciliation or fails closed. Startup authenticates each corpus in bounded
  batches before publishing its manifest or healthy index state. A failed corpus stays unavailable without affecting the
  owner or other workspaces.
- **Limits** (`MemoryResourceLimits`, fixed): 64 MiB per source file (host reads of workspace text fail closed above it);
  a daily observation record is cut at 512 KiB and a date partition accepts up to 8 MiB (an append that would exceed it is
  rejected before mutation, never trimming prior records); a recursive request admits at most 1,000 files and 64 MiB.
- **`errors.md` and `learnings.md`** are corpus members written through the same authority, CAS and lock as the curated
  roles, so a role-scoped write leaves unselected members byte-identical. `SelfImprovementService` keeps the newest 50.
  A pre-canonical `errors.md` is converted by startup preflight; unrecognized remainder is kept under `memory/legacy/`.
- **Wiki.** `workspace/wiki/` is read in place by `WikiSearchSource`; it has no PostgreSQL projection.
  Frontmatter `provenance` drives search trust: `human-authored` and `hybrid` rank trusted, and `llm-authored` ranks
  trusted only while `sources` is non-empty. Any other stored value is preserved untouched by the writer, ranks untrusted,
  and is reported by wiki lint. A `human-authored` or `hybrid` page that gains synthesized content becomes `hybrid`; a page
  with no frontmatter becomes `hybrid`, and a page with frontmatter but no `provenance` stays unlabeled.

### Derived search indexes

| Corpus | Source of truth | Projection | Document id |
|--------|-----------------|------------|-------------|
| Memory | Validated canonical corpus; only `topic`, `archive`, `observation` and `learning` entries (`errors.md`, `MEMORY.md`, `MEMORY.audit.md` are never indexed) | `MemoryIndexProjection` to `memory_chunks`, per principal | Entry locator |
| Conversation | `messages.ndjson` of durable, chat-facing sessions (`user`, `main`, `channel`, `archive`), `user`/`assistant` messages the `ConversationState` shows | `ConversationIndexProjection` to `conversation_chunks`, one chunk per message, under the session's pinned workspace principal or `owner` | Message UUID |
| Knowledge graph | `kg_facts` (authoritative, not derived) | None; `PostgresFactSearch` builds a query-time vector with `database.fts_language` | n/a |

[![Derived search projections](diagrams/data-search-projections.svg)](diagrams/data-search-projections.svg)

`database.fts_language` drives memory, conversation and fact search. After changing it, restart and run
`dartclaw rebuild-index`; stored projections keep the previous language until then.

- **Live maintenance.** Memory writes re-project through a post-commit hook registered on the corpus; the hook records
  health and, if projection fails, marks the index degraded while canonical memory stays available. Conversation rows are
  maintained by `ConversationIndexer`, an observer of `MessageService` and `SessionService` that queues work on one
  serialized chain: it indexes appended messages, deletes rows on clear or session deletion, and adds or removes a session's
  rows when its type crosses the chat-facing boundary. Archival keeps the rows. Failures are logged and later rebuilds
  reconcile missed work; they never fail message persistence.
- **Health evidence.** `IndexHealthStore` writes `.dartclaw-memory-index.json` beside each corpus (`healthy`, `degraded`,
  `rebuilding`, `unknown`, with the canonical and index revision and fingerprint). An interrupted `rebuilding` reads as
  `degraded`. `CanonicalIndexReconciler` revalidates a current index at startup and rebuilds a stale one.
- **Rebuild** (`dartclaw rebuild-index`, DartClaw stopped): validates managed identity markers, enumerates the owner and the
  read-eligible named agents, and replaces each principal's memory projection through `TransactionalRebuildTarget`: populate,
  validate and swap inside one transaction, so a failure keeps that principal's prior rows, with stable locators, revisions,
  provenance and source timestamps. The conversation corpus is then cleared per principal and repopulated from session NDJSON
  as separate steps (stale rows are cleared even with no chat-facing sessions), so a crash mid-rebuild can leave a partial
  conversation index until the command is rerun. Message NDJSON, wiki pages and KG facts are never changed.
- **Vectors.** `PostgresVectorIndex` keeps every mutation transactional, scopes enumeration and ranking by `user_id`, and
  ranks only rows matching the query's model fingerprint and dimension with the public-qualified cosine operator.
  `VectorSynchronizer` (`dartclaw_search`) reuses a vector only when its content hash and provider fingerprint still match,
  retires stale identities, and refuses a late result whose source changed. An embedding failure leaves the lexical index
  current and counts as unembedded. A changed provider or model makes earlier vectors ineligible until reconciled at startup
  or by `rebuild-index`.

### Instance-local and small stores

| Store | Contents | Write behavior |
|-------|----------|----------------|
| `turn_state.json` (`TurnStateStore`) | `{sessionId: {turnId, startedAt}}` | Each mutation reads and replaces the whole document synchronously (`secureWriteFileSync`), so an unawaited `set` is durable on return. Open deletes temp siblings and quarantines malformed content as `turn_state.json.corrupt-<timestamp>` |
| `webhook_deliveries/<sha256(id)>` (`WebhookDeliveryStore`) | `{state, inserted_at, updated_at}` | Exclusive create reserves `pending`; commit rewrites to `processed`; release deletes a pending claim. A pending claim older than 15 minutes, and any bodyless or malformed marker, is reclaimable. Processed markers are purged after 7 days (first reservation, then at most hourly) |
| `thread-bindings.json` (`ThreadBindingStore`) | JSON array of bindings keyed in memory by `<channelType>::<threadId>`; task or run `kind`, a row without `kind` reads as a task | In-memory map, atomic file writes, lookups synchronous. A missing or invalid file starts empty. Lifecycle and routing: [Session & State](session-state-architecture.md) §10 |
| `kv.json` (`KvService`) | Entries `{value, updatedAt}`; keys `usage_daily:YYYY-MM-DD` (token totals and `budget_warning_posted_at`), `session_cost:<sessionId>`, `prune_history`, `workflow.outcome.fallback` | Cached map, serialized by a bounded write queue, atomic file replace |
| `usage.jsonl` | `UsageEvent` lines | Append, then rotate to `usage.jsonl.1` above 10 MiB (one backup, overwritten) |
| `audit-YYYY-MM-DD.ndjson` | Guard audit entries | Appends serialized on one future chain; a failed append is logged and never delays the guard verdict |
| `projects.json` | Object keyed by project id, runtime-created projects only; `Project` JSON (`dartclaw_kernel/lib/src/project_runtime.dart`) | `atomicWriteJson` of the full registry. Config-defined projects come from `projects:` in the config, and the implicit `_local` project is the runtime working directory; neither is persisted. Project semantics: [Task Execution](task-execution-architecture.md) §10 |
| `pending-schedule-changes.json` | Parked `schedule_upsert` bodies awaiting approval | `PendingScheduleChangeStore`; refuses above 100 records or 1 MiB |
| Channel state | `signal-sender-map.json`, `google-chat-user-oauth.json` (owner-only), `google-chat-subscriptions.json` | Owned by the channel packages. WhatsApp sidecar state is not a DartClaw store |

Governance counters (rate limits, loop detection, pause queue) are in memory and reset on restart; only daily token totals
persist, in `kv.json`. See [Security Architecture](security-architecture.md) and [Session & State](session-state-architecture.md) §11.

---

## 6. Relationships

### Entity map

[![Entities and reference enforcement](diagrams/data-entities.svg)](diagrams/data-entities.svg)

Thread bindings, search rows and knowledge-graph facts are left out of the figure; the table below lists every reference.

### Cross-store references

| From | To | Enforced? |
|------|----|-----------|
| `tasks.agent_execution_id` | `agent_executions.id` | **Yes**, FK `RESTRICT` |
| `workflow_step_executions.task_id` | `tasks.id` | **Yes**, FK `CASCADE` |
| `workflow_step_executions.agent_execution_id` | `agent_executions.id` | **Yes**, FK |
| `task_artifacts.task_id` | `tasks.id` | **Yes**, FK `CASCADE` |
| `agent_executions.session_id` | `sessions/<id>/` | No. A task reaches its session only through its execution; session protection from pruning is by convention (`SessionType.task`) |
| `tasks.goal_id`, `goals.parent_goal_id` | `goals.id` | No. Deleting a goal leaves the tasks pointing at it |
| `tasks.project_id` | `projects.json` or config | No (database to file); null means the implicit `_local` project |
| `tasks.workflow_run_id`, `workflow_step_executions.workflow_run_id` | `workflow_runs.id` | No |
| `task_events.task_id`, `turns.task_id`, `turns.session_id` | tasks, sessions | No. Events and traces survive deletion |
| Message append | session directory | Checked in code at append time |
| `memory_chunks` / `conversation_chunks` (and vectors) | canonical memory / `messages.ndjson` | Derived; reconciled by `rebuild-index` |
| `ThreadBinding.targetId` | `Task.id` or `WorkflowRun.id` by `kind` | No. Startup `reconcile` prunes bindings of terminal or unknown tasks and runs |

### Lifecycle dependencies

| Event | Effect |
|-------|--------|
| Session deleted | Directory removed and its conversation rows queued for removal; a protected-session refusal changes neither. `agent_executions.session_id` can dangle |
| Session archived | Type becomes read-only `archive`; NDJSON and conversation rows are kept (owner-authorized archived-lifecycle search) |
| Task deleted (terminal tasks only) | Task, artifact and step-execution rows go. The `AgentExecution` row, artifact files under `tasks/<taskId>/artifacts/`, session and trace/event rows stay; artifact retention reads tasks, so it no longer reaches a deleted task's files |
| Goal deleted | Tasks keep `goal_id`; lookups return null |
| Task reaches a terminal state, or a workflow run ends | Its thread bindings are removed (a run binding after the terminal post) |
| Memory or chat-facing message changes | The principal's lexical rows update first; hybrid then reuses matching vectors and embeds the rest |
| Embedding provider or model changes | The new fingerprint makes earlier vectors ineligible; startup and `rebuild-index` reconcile owner and managed-workspace corpora independently |
| Server restart | Counters and queues reset. Bindings reload and reconcile against active tasks and runs; orphan `turn_state.json` records are reported and acknowledged after storage wiring |

---

## 7. Write Safety

**Atomic replace.** Mutable JSON goes through `atomicWriteJson` / `secureWriteFile`
(`dartclaw_core/lib/src/storage/atomic_write.dart`): write `<target>.<random>.tmp`, flush, rename over the target. A crash
leaves an orphan temp file and the original intact; opening a store sweeps stale temps where it owns the directory. An
existing target keeps its POSIX mode; `restrictPermissions` forces `0600`. `ConfigWriter` copies the current file to
`.bak` first (aborting if that fails), then replaces the symlink-resolved target.

**Serialization.** Concurrent writers are serialized per resource:

| Service | Mechanism | Guards |
|---------|-----------|--------|
| `SessionService` | `RepoLock` per `meta.json` and `.session_keys.json` | Metadata and key-index rewrites |
| `MessageService` | `BoundedWriteQueue` | NDJSON appends and line counts |
| `KvService` | `BoundedWriteQueue` | `kv.json` rewrites |
| `MemoryCorpusService` | `BoundedWriteQueue` + a static `RepoLock` per workspace + journaled commit | All corpus mutations, pruning, derived-index updates |
| `SelfImprovementService` | Own queue, then the corpus authority | `errors.md`, `learnings.md` |
| `ConfigWriter` | Own queue | YAML rewrites |
| `FileExecutionStore` | `RepoLock` + OS file lock | Standalone checkpoint |

`BoundedWriteQueue` holds at most 1,000 pending operations, warns at 800, and fails an operation that would overflow it.

**Fire-and-forget.** These must not block or fail their caller: guard audit appends, usage metering (each step of
`UsageTracker.record` is isolated), `turns` inserts (`unawaited` from `TaskExecutor`), and `lastActivity` updates of
thread bindings. `task_events` inserts are the awaited exception.

---

## 8. Retention & Maintenance

| Data | Policy | Trigger |
|------|--------|---------|
| `audit-*.ndjson` | Partitions older than `guard_audit.max_retention_days` (default 30; 0 keeps all) deleted | Session-maintenance job |
| `usage.jsonl` | Rotated at 10 MiB | On write |
| `errors.md`, `learnings.md` | Newest 50 records | On write |
| Topic entries | `MemoryPruner` archives entries older than `memory.pruning.archive_after_days` (90) to `MEMORY.archive.md` and removes exact replays, then regenerates the bounded index. Owner workspace only | Cron `memory.pruning.schedule` (`0 3 * * *`), `memory.pruning.enabled` |
| Daily observations | 512 KiB per record, 8 MiB per day partition; no age limit | On write |
| Sessions | Pipeline: archive stale (`sessions.maintenance.prune_after_days`, 30), count cap (`max_sessions`, 500), delete orphaned cron sessions (`cron_retention_hours`, 24), disk budget (`max_disk_mb`, 0 = off). `mode` defaults to `warn`; main, active-turn, active-channel, active-cron and task sessions are protected | `sessions.maintenance.schedule` (`0 3 * * *`) and `dartclaw cleanup` |
| Task artifacts | Rows and files of terminal tasks older than `tasks.artifact_retention_days` (0 = off) | Same job |
| Workflow runtime artifacts | `workflows/runs/<id>/runtime-artifacts` of old finished runs, opt-in via `workflow.runtime_artifacts_retention` | `dartclaw cleanup` |
| Webhook markers | Processed markers purged after 7 days | On reservation, at most hourly |
| Thread bindings | Task bindings idle for 1 hour removed (swept every 5 minutes); run bindings exempt | `ThreadBindingLifecycleManager` |
| `task_events`, `turns`, `workflow_runs`, `goals` | None (unbounded) | |
| Derived search tables | Rebuilt from canonical sources | `dartclaw rebuild-index` and startup reconciliation |

The memory journal and optional curation schedule each register one owner job plus one uniquely named job per
write-enabled workspace.

---

## 9. Backup & Recovery

PostgreSQL and the file stores are separate authorities; capture both with DartClaw stopped so they describe one state.
Commands: [PostgreSQL guide](../../docs/guide/postgresql.md#back-up-and-restore).

| Capture | With | Notes |
|---------|------|-------|
| Database | `pg_dump --format=custom` or provider tooling | Derived tables may be excluded |
| `dartclaw.yaml`, `workspace/`, `sessions/` | File archive | Canonical; derived index rows do not replace them |
| `agents/`, `projects.json`, `credentials/` | File archive, when present | Credentials are sensitive. `projects/` clones are re-cloneable |
| `standalone/` | File archive, standalone processes stopped | Only when standalone runs matter |
| `kv.json`, `usage.jsonl`, `audit-*.ndjson`, `tasks/` | Optional | Usage totals, audit trail, artifact files |
| `turn_state.json`, `webhook_deliveries/`, `thread-bindings.json` | Not needed | Instance-local |

| Scenario | Recovery |
|----------|----------|
| Derived memory or conversation index stale or missing | `dartclaw rebuild-index`. An incompatible schema is refused before the rebuild |
| Database lost or damaged | `pg_restore` from a verified dump or the provider workflow |
| Schema compatibility refusal | Back up the named database, then recreate it for this release or restore a compatible backup. The one admitted transition is applied by `dartclaw serve` |
| Interlock lost | Storage calls refuse during recovery; they resume after the lock is reacquired and the version and schema are revalidated. Terminal failure needs the reported condition fixed and a restart |
| `turn_state.json` corrupted or deleted | Invalid content is quarantined at open and recovery starts empty; in-flight sessions may miss a recovery notice |
| Session directory deleted | Metadata and messages are lost; tasks whose execution points at it dangle |
| `dartclaw.yaml` corrupted | Restore from `dartclaw.yaml.bak` |
| `kv.json` lost | Daily usage aggregates and per-session cost totals are lost; `usage.jsonl` keeps the raw events, with no re-aggregation tool |
| Canonical memory member deleted | Corpus validation reports it; restore the member from workspace Git or a backup before rebuilding. `MEMORY.md` alone is only the bounded index |
| `execution.json` malformed | The standalone store refuses to load and is not reset; restore from backup |

Rollback to a 0.26 SQLite installation is possible only before the PostgreSQL target accepts new writes; there is no
reverse migration ([PostgreSQL guide](../../docs/guide/postgresql.md#move-a-0262-sqlite-installation)).

---

## 10. Where in Code

| Concern | Location |
|---------|----------|
| Ports, storage errors, `DatabaseConfig` | `packages/dartclaw_kernel/lib/src/{database_backend,storage_exceptions,database_config}.dart` |
| Backend, dispatch policy, interlock, schema gate and identity | `packages/dartclaw_core/lib/src/storage/{postgres_*,schema_identity}.dart` |
| Task, goal, execution repositories (database and file), `FileExecutionStore` | `packages/dartclaw_core/lib/src/storage/{database_*,file_*}.dart` |
| Workflow-run repositories, run paths, context persistence | `packages/dartclaw_workflow/lib/src/storage/`, `.../workflow/{workflow_run_paths,workflow_context_persistence}.dart` |
| Sessions, messages, conversation state | `packages/dartclaw_core/lib/src/storage/{session_service,message_service,conversation_state}.dart` |
| Trace and event services | `packages/dartclaw_core/lib/src/storage/{turn_trace_service,task_event_service}.dart` |
| Memory corpus, projection, pruner, preflight | `packages/dartclaw_core/lib/src/memory/` |
| Lexical and vector indexes, conversation projection, rebuild and health | `packages/dartclaw_core/lib/src/search/`, `.../storage/{index_reconciler,index_rebuild_target}.dart`; `HybridSearch` and `VectorSynchronizer` in `packages/dartclaw_search/lib/src/` |
| Knowledge graph | `packages/dartclaw_core/lib/src/knowledge/` |
| Local stores and write primitives | `packages/dartclaw_core/lib/src/storage/{turn_state_store,webhook_delivery_store,kv_service,atomic_write,write_op}.dart`; `.../channel/thread_binding.dart` |
| Store wiring, standalone lease | `packages/dartclaw_runtime/lib/src/runtime/{storage_wiring,standalone_execution_lease}.dart` |
| Projects, usage, audit, maintenance | `packages/dartclaw_runtime/lib/src/{project/project_service_impl,observability/usage_tracker,maintenance/session_maintenance_service}.dart`; `packages/dartclaw_kernel/lib/src/guard_audit.dart` |
| `rebuild-index` | `apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart` |
