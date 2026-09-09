# Phase B implementation context

Phase A implementation checkpoint: public `007ab8d48220f07b429f647a3d23dc802bc82141`, all17stories with successful retained receipts. Public state records continuation at `3396754b6501`. The integration checkout stays on `feat/0.26`; the final combined A+B gate still owns all deferred live/platform/release obligations.

## Landed runtime seams

Read-only snapshot of the public working tree at `3c4a82256c98392c93ce00185d311e70e03b8cc8`, including the current Phase A integration changes. This maps existing symbols and constraints only.

## Retrieval contracts and composition

| Path | Symbol | Current responsibility and boundary |
|---|---|---|
| `packages/dartclaw_kernel/lib/src/full_text_index.dart` | `SearchDocument`, `SearchResult`, `FullTextIndex` | Corpus-neutral lexical document port. Identity is `(userId, document.id)`; metadata is an opaque flat `Map<String, String>`. Mutation surface already supplies complete documents plus `retire`/delete IDs and complete-corpus `replaceAll`. Scores are backend-native and best-first. |
| `packages/dartclaw_kernel/lib/src/search_backend.dart` | `SearchBackend`, `SearchResultLayer` | Memory-facing query contract: `search` returns `MemorySearchOutcome`, `resolve` reopens a returned locator, and parameterless `indexAfterWrite` lets QMD rescan. `SearchResultLayer` has only `memory` and `wiki`; this contract does not represent the conversation corpus. |
| `packages/dartclaw_core/lib/src/search/fts5_search_backend.dart` | `Fts5SearchBackend` | Adapts one memory `FullTextIndex` to `SearchBackend` through `MemoryIndexProjection.toSearchResult`. `indexAfterWrite` is a no-op. |
| `packages/dartclaw_core/lib/src/search/composed_search_backend.dart` | `ComposedSearchBackend` | Single owner of memory-plus-wiki request composition. It health-gates the personal branch, merges/deduplicates by `role:locator`, preserves `MemorySearchOutcome` degradations, and sorts by score then role/locator. A hybrid personal backend must remain inside `_personal`; wiki composition and the before/after memory-health check remain outside it. |
| `packages/dartclaw_core/lib/src/search/search_backend_factory.dart` | `createSearchBackend` | Constructs `Fts5SearchBackend` or QMD-with-FTS fallback, then optionally wraps it in `ComposedSearchBackend`. This is the memory query injection point used by runtime wiring. |
| `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` | `_wirePersonalMemoryAfterTaskStorage`, `memoryIndex`, `searchBackend` | Creates the backend-specific memory lexical index, optional QMD manager, and the single `SearchBackend`; supplies `_probeIndexHealth`. The resulting instance flows to memory tools, Context Research, Knowledge Hub, and server observability. |
| `packages/dartclaw_runtime/lib/src/memory_handlers.dart` | `createMemoryHandlers.onSearch` | Only direct production `memory_search` call. It calls `SearchBackend.search`, then serializes every `MemorySearchResult.toRetrievalJson`, including stable `locator`, provenance, score, and canonical entry identity. Normal payload shape is already compact and must remain compatible. |
| `packages/dartclaw_runtime/lib/src/knowledge/knowledge_hub_service.dart` | `KnowledgeHubService.search` | Also queries the same `SearchBackend` and consumes memory/wiki roles and locators. |
| `packages/dartclaw_runtime/lib/src/mcp/context_research_tool.dart` | `ContextResearchTool._memorySearch` | Consumes the same memory backend and converts returned locators into citation `SourceRef`s. |
| `packages/dartclaw_runtime/lib/src/runtime/harness_wiring.dart` | `HarnessWiring.wire` | Passes `StorageWiring.searchBackend` to `createMemoryHandlers`; no separate search backend is built per harness. |
| `packages/dartclaw_runtime/lib/src/runtime/service_wiring_mcp_tools.dart`, `service_wiring_builder.dart` | MCP/server composition | Pass the same storage-owned backend to Context Research and server/Knowledge Hub dependencies. |

## Conversation corpus seams

| Path | Symbol | Current responsibility and boundary |
|---|---|---|
| `packages/dartclaw_core/lib/src/search/conversation_index_projection.dart` | `ConversationIndexProjection` | Maps eligible NDJSON messages to `SearchDocument(id: Message.id, chunks: [content], metadata: session_id/role, timestamp)`. `populate`/`rebuild` accept exactly one `FullTextIndex`, clear it with `replaceAll([])`, then upsert per-session batches. |
| `packages/dartclaw_core/lib/src/search/conversation_indexer.dart` | `ConversationIndexer` | Sole incremental/lifecycle projection owner. It queues append/upsert, clear/delete IDs, session delete, archive/delete-by-session, and resume/upsert operations against exactly one `FullTextIndex`; `idle` is its drain barrier. Session deletion deliberately discovers IDs from owner-scoped lexical rows using `count` plus `listRecent`, because the authoritative NDJSON may already be inaccessible. |
| `packages/dartclaw_core/lib/src/search/conversation_search_service.dart` | `ConversationSearchService.search`, `ConversationHit` | Calls `FullTextIndex.search` directly and maps `SearchResult` metadata into `messageId`, `sessionId`, `role`, UTC timestamp, text, and score. It does not consume `SearchBackend`; no production route/tool calls it yet. |
| `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` | `_conversationIndex`, `_conversationProjection`, `_conversationIndexer`, `_conversationSearch` | Creates a second lexical index over `conversation_chunks`, reprojects it when memory reconciliation published a fresh search store, registers the indexer on both stores, exposes service-level getters, awaits `indexer.idle` before database shutdown. SQLite memory and conversation indexes share `_searchBackend`; PostgreSQL instances share `_taskBackend`. |
| `apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart` | `RebuildIndexCommand.run` | Reconciles memory first, then independently builds a conversation descriptor and calls `ConversationIndexProjection.rebuild`. Empty memory does not skip conversation rebuild. SQLite reopens the published search store; PostgreSQL reuses the validated authoritative backend. |
| `packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart` | `SqliteSearchRebuild.corpora`, `SqliteSearchCorpusRebuild` | Incompatible SQLite search-store rebuild accepts ordered complete populate/authenticate pairs. Runtime currently supplies memory as the primary pair and conversation in `corpora`; all pairs run through the replacement transaction. |

### Constraints for hybrid injection across both corpora

- Keep two corpus instances and `(userId, id)` isolation. Memory IDs/metadata come from `MemoryIndexProjection`; conversation IDs/metadata come from `ConversationIndexProjection`. Hybrid storage cannot merge the corpora or replace their source-specific projections.
- Memory query substitution fits behind `SearchBackend`/`createSearchBackend`, but `SearchBackend` is intentionally memory-shaped (`MemorySearchOutcome`, memory/wiki layers, native locator resolution). Conversation cannot be routed through it unchanged: `ConversationSearchService` currently requires `SearchResult`-equivalent metadata and returns `ConversationHit`.
- Incremental memory vector work must attach where `registerPostCommitProjection` receives the complete projected corpus/delta and `priorRecordIds` in `StorageWiring`; `SearchBackend.indexAfterWrite()` carries no documents, IDs, user, or corpus and is insufficient for a native delta writer by itself.
- Incremental conversation vector work must share `ConversationIndexer`'s serialized queue. Its callbacks already provide the `SearchDocument`s or delete IDs needed for vector mutation. Session deletion must continue deriving IDs from the surviving owner-scoped lexical rows, then retire those same IDs from the vector store; it must not reread deleted NDJSON.
- Rebuild must cover both sides of each corpus. Current memory rebuild sources are the `CanonicalIndexReconciler` document stream/runtime post-rebuild callback and the CLI's `documents()` stream. Current conversation rebuild source is `ConversationIndexProjection.rebuild`; SQLite incompatible-store publication also uses `SqliteSearchRebuild.corpora`. A vector rebuild omitted from any of these leaves the lexical/vector pair at different source revisions.
- The `_memoryIndexRebuilt` conversation re-projection is load-bearing after SQLite sibling-file publication. Any vector store coupled to `search.db` must be published/reprojected in the same lifecycle; an independent store still needs the same source-authentication boundary.
- Preserve degradation ownership: `ComposedSearchBackend` health-gates and reports the memory layer; `ConversationSearchService` catches search failure and returns `[]`; `ConversationIndexer` catches each queued mutation so message persistence never fails. Embedder/vector failure must not escape those existing persistence boundaries.
- Shutdown must drain both corpus mutation queues and close the embedding provider/vector stores before `_taskBackend`/`_searchBackend` close. The existing conversation drain point is `StorageWiring.closeBackends`; memory post-commit projections currently have no analogous explicit queue object.

## Config and generated schema chain

There is no native `EmbeddingConfig`, `EmbeddingProvider`, `VectorIndex`, embedding model field, or vector schema in current production code. QMD is the only semantic implementation.

| Path | Symbol | Constraint |
|---|---|---|
| `packages/dartclaw_kernel/lib/src/search_config.dart` | `SearchConfig` | Holds `backend`, QMD host/port, depth, and web-search providers. Any embedding values must participate in construction, defaults, equality, and hash code. |
| `packages/dartclaw_kernel/lib/src/config_parser_providers.dart` | `_parseSearch` | Parses `search` after credentials, validates `search.backend` through `ConfigMeta`, normalizes QMD, and resolves named API-key credentials for dynamic search providers. Unknown nested keys still fail the global config sweep unless registered. |
| `packages/dartclaw_kernel/lib/src/config_meta/server_fields.dart` | `_serverFields` search rows | Current registry home for `search.backend`, `search.qmd.*`, and `search.default_depth`. `ConfigMeta.fields` is the authority used by validation, CLI config get/set, settings metadata, schema emission, and the unknown-key refusal. |
| `packages/dartclaw_kernel/lib/src/config_meta.dart`, `config_meta/json_schema.dart` | `ConfigMeta.fields`, `toJsonSchema` | Every accepted scalar path needs one `FieldMeta`; the JSON Schema is derived from this registry with closed objects (`additionalProperties: false`). Secret-bearing fields need the correct readonly/credential posture and must not be serialized as clear text. |
| `packages/dartclaw_runtime/lib/src/config/config_serializer.dart` | `ConfigSerializer.toJson`, `metaJson` | Runtime config JSON currently exposes only `search.backend`; adding fields to `SearchConfig` alone does not expose their current values to settings/API. `metaJson` is automatic once registered. |
| `packages/dartclaw_runtime/lib/src/web/settings/settings_sections.dart` | memory panel prefix `search` | Registered `search.*` fields are automatically claimed by the Memory settings panel. Adding a second owner would violate the total/single-owner settings gate. |
| `packages/dartclaw_kernel/tool/generate_config_schema.dart` | schema generator | Regenerates `schemas/dartclaw.schema.json` from `ConfigMeta`; `--check` is a fitness gate. |
| `dev/tools/render_config_reference.dart` | config-reference renderer | Regenerates the marked region of `docs/guide/configuration.md` from the committed schema. `dev/tools/config_reference_core_keys.txt` separately curates at most 90 core keys. |

Database/vector structure has two current authorities: `SchemaIdentity.search` owns SQLite's complete derived-store manifest/bootstrap/drop list, while `PostgresSchemaGate` explicitly augments the shared memory/conversation tables and validates its own PostgreSQL-only columns/indexes. SQLite rebuilds an incompatible derived store; PostgreSQL refuses a non-current authoritative schema. Adding vector objects therefore requires both manifests/bootstrap paths, their exact-object validation, and the existing atomicity posture; changing only `SchemaIdentity.search` does not update PostgreSQL's explicit vector/extension checks.

## Turn-trace provenance path

| Path | Symbol | Current data flow |
|---|---|---|
| `packages/dartclaw_core/lib/src/bridge/bridge_events.dart` | `ToolResultEvent.output` | Carries the raw serialized tool output and is the last event-level point where returned search locators exist. |
| `packages/dartclaw_runtime/lib/src/turn_guard_evaluator.dart` | `TurnToolHooks.handleToolUse/handleToolResult` | Correlates results by tool ID. Pending state retains tool name, input-only `context`, and start time. `handleToolResult` currently discards `event.output` and creates `ToolCallRecord` from name/success/duration/error/context only. |
| `packages/dartclaw_runtime/lib/src/task/tool_call_summary.dart` | `summarizeToolInput` | Produces the bounded input context. It has no result parser and must not be treated as returned-source evidence. |
| `packages/dartclaw_core/lib/src/turn/tool_call_record.dart` | `ToolCallRecord` | Existing per-invocation DTO serialized into traces; it has no source-locator field. This is the narrow flexible record carried by `TurnOutcome` and `TurnTrace`. |
| `packages/dartclaw_core/lib/src/turn/turn_outcome.dart` | `TurnOutcome.toolCalls` | Carries bounded retained records plus exact total/failure counts from the turn loop. |
| `packages/dartclaw_runtime/lib/src/task/task_executor_helpers.dart` | `TaskExecutor._persistTrace` | Copies `outcome.toolCalls` into `TurnTrace`; this is currently the only production trace insertion call. |
| `packages/dartclaw_core/lib/src/turn/turn_trace.dart` | `TurnTrace.toolCalls`, `toJson/fromJson` | Public/API DTO. No top-level sources field exists. |
| `packages/dartclaw_core/lib/src/storage/turn_trace_service.dart` | `TurnTraceService.insert/_decodeToolCalls` | Persists the complete bounded record list in the existing nullable `turns.tool_calls` JSON column. Old list format and current `{records,count,failedCount,truncated}` format are both decoded. |
| `packages/dartclaw_runtime/lib/src/api/trace_routes.dart` | `/api/traces`, `/api/traces/<id>` | Returns `TurnTrace.toJson` directly. CLI `traces list` consumes only summary columns, while JSON mode already passes through the full DTO. |

### Constraints for retaining returned locators

- Locator capture must occur in `TurnToolHooks.handleToolResult` (or before it): later layers receive only `ToolCallRecord`, and the raw `ToolResultEvent.output` has been discarded.
- Correlation must use the pending tool ID/name and successful output. Input `context` is not proof of what the tool returned.
- `memory_search` already emits `results[*].locator`; hybrid ranking must preserve those exact `MemorySearchResult.locator` values through fusion and `toRetrievalJson`. Conversation search currently emits no tool result and has no turn-trace call site.
- The existing `tool_calls` JSON column is the only schema-flexible trace carrier. Adding optional locator data to the per-call DTO can remain backward-readable if missing fields default empty; a new top-level persisted trace field would require task-schema changes on both database backends.
- Retention remains bounded by `TurnToolHooks.maxRetainedToolEvents`. Locator lists need their own deterministic bound/deduplication and must never retain result snippets, embedding vectors, credentials, or the whole raw tool output.
- `TaskExecutor._persistTrace` is fire-and-forget and trace insertion failure is non-fatal. Any locator parsing must complete synchronously with tool-result accounting so the finalized `TurnOutcome` already contains it.

## Verified native API and offline inputs


```dart
final engine = LlamaEngine(LlamaBackend());
try {
  await engine.loadModel(modelPath);
  final query = await engine.embed('task: search result | query: query text');
  final documents = await engine.embedBatch(['title: none | text: document text']);
  final dimensions = query.length;
} finally {
  await engine.dispose();
}
```

- Default ModelParams is sufficient for embeddings; no embeddingMode/pooling flag is required. Defaults: contextSize4096, gpuLayers maxGpuLayers, preferredBackend GpuBackend.auto, automatic batch sizing.
- embed/embedBatch return List<double>/List<List<double>>, normalize defaults true, dimension is vector.length. Native LlamaCppBackend implements BackendBatchEmbeddings and embedBatch, not only a fallback signature.
- No embedding timeout/cancellation parameter exists. cancelGeneration applies to generation; ModelDownloadCancelToken applies only to source download/resolution.
- EmbeddingGemma query prefix: `task: search result | query: {content}`. Document prefix: `title: {title or none} | text: {content}`.

## Offline hook inputs
Nested under hooks.user_defines.llamadart: llamadart_native_path, llamadart_native_tag, llamadart_native_repository, llamadart_native_backends, llamadart_native_runtimes.
Local bundle lookup: <native_path>/<tag>/<bundle>/extracted/ or <native_path>/<tag>/<bundle>/.
Archive fallback: <native_path>/<tag>/<bundle>/llamadart-native-<bundle>-<tag>.tar.gz.
Cached six-platform archives and model are recorded in native-artifact-facts.md and native-artifacts/manifest.json. Reuse verified files rather than downloading again.

## Primary sources
- https://github.com/leehack/llamadart/blob/v0.8.22/lib/src/core/engine/engine.dart
- https://github.com/leehack/llamadart/blob/v0.8.22/lib/src/backends/backend.dart
- https://github.com/leehack/llamadart/blob/v0.8.22/lib/src/backends/llama_cpp/llama_cpp_backend.dart
- https://github.com/leehack/llamadart/blob/v0.8.22/lib/src/core/models/inference/model_params.dart
- https://github.com/leehack/llamadart/blob/v0.8.22/lib/src/hook/native_bundle_config.dart
- https://github.com/leehack/llamadart/blob/v0.8.22/hook/build.dart
- https://llamadart.leehack.com/docs/guides/embeddings
- https://ai.google.dev/gemma/docs/embeddinggemma/model_card

## Initialization lifecycle source check (2026-09-09 02:00 CEST)

Installed llamadart0.8.22 `lib/src/backends/llama_cpp/llama_cpp_backend.dart` already bounds worker initialization to30seconds (constructor51; `_startIsolate`137–218). It observes startup error/exit, waits for a native initialization handshake, kills the worker on failure/timeout and closes the temporary port. Reuse this dependency mechanism and prove it at the provider boundary; do not add another isolate/worker wrapper solely for the historical missing-library startup hang. This is source evidence, not an executed failure-path proof.

Model loading/embedding requests and `_disposeWorker` do not have equivalent response deadlines (`dispose`696–750 waits for `DisposeRequest` response). Keep that distinction explicit: worker-handshake boundedness alone does not prove every model initialization or disposal path bounded. Product failure posture must be tested against the actual selected release package.

## Existing preparation resources

The verified six native archives are under private `.agent_temp/0.26-execution/native-artifacts/`; the model is under private `.agent_temp/spikes/llamadart-embeddings/models/`. Their names/hashes are native-artifacts.json. Reuse these local preparation resources; never ship machine-specific cache paths in runtime configuration. The current AOT feasibility smoke is private `.agent_temp/0.26-execution/native-smoke/`; final product/platform proofs remain required. Calibration reproduction is private `.agent_temp/0.26-execution/calibration/` and historical fixture `.agent_temp/spikes/llamadart-embeddings/lib/fixture.dart`. Frozen settings and judgments are bundled alongside the plan.

## Prepared pgvector verification environment

Prepared 2026-09-09 03:40 CEST. The isolated test server uses PostgreSQL 16.15 and administrator-provisioned pgvector 0.8.6 from `pgvector/pgvector:0.8.6-pg16-bookworm`, digest `sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b` (linux/arm64). A separate non-superuser runtime role has CONNECT and CREATE for disposable test namespaces; it has no CREATEDB or CREATEROLE. The extension is in `public`; the application pool otherwise selects its own namespace, so vector type/operator resolution must be explicit. Root retains the mode600 runtime test credentials outside the bundle and supplies them only to the final test process. This is environment preparation, not a live contract or release pass.

## Native asset bootstrap for implementation worktrees

After normal `dart pub get` and `dart run dev/tools/embed_assets.dart`, run `dart run apps/dartclaw_cli/bin/dartclaw.dart --version` once before package tests in a fresh worktree. The CLI entry point reaches sqlite3 and causes Dart build hooks to generate that worktree’s `.dart_tool/native_assets.yaml`; the embed-assets generator alone does not. This was verified against an existing isolated worktree: the mapping was absent before this command, then pointed at its bundled SQLite 3.53.0 afterward. The verified macOS arm64 archive is already seeded in the installed llamadart package root under `.dart_tool/llamadart/native_bundles/v0.3.0/macos-arm64/`. Its default build hook can reuse that archive without a consumer pubspec override; preserve canonical dependency configuration and do not commit a machine-private path. This is a short JIT/bootstrap command, not a release build or test campaign.
