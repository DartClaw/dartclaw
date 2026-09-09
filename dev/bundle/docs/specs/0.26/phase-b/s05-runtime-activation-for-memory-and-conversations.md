# FIS: Runtime Activation for Memory and Conversations

**Plan**: dev/bundle/docs/specs/0.26/phase-b/plan.json
**Story-ID**: S05

_Authored against public `3396754b6501` on `feat/0.26`; commands and `packages/...` paths run from
`../dartclaw-public/`. S02, S03 and S04 are prerequisite contracts and must be accepted before execution._

## Feature Overview and Goal

**Intent**: Let an operator activate recoverable hybrid retrieval for canonical memory and persisted conversations
without weakening either source lifecycle, the local-first default or authoritative persistence.

**Expected Outcomes**:

- [OC01] `search.backend: hybrid` composes independent memory and conversation retrieval over the configured database
  backend, while FTS remains zero-config and QMD remains functional with a deprecation warning.
- [OC02] Canonical memory and conversation changes update lexical state first and reconcile vectors from that current
  state, so provider or vector failure never loses authoritative data or makes stale text eligible.
- [OC03] An operator can explicitly acquire the supported local model, recover missing vectors through the existing
  rebuild command, and observe separate memory and conversation unembedded counts.
- [OC04] Explicit HTTP embeddings use the configured endpoint, model, credential reference and existing network
  posture without exposing secrets or applying local-model preprocessing to arbitrary remote models.

## Pinned Configuration and Downstream Surface

S06 consumes these exact runtime/query/count seams. S09 documents these exact keys. No additional embedding,
ranking, dimension, timeout, path, checksum or model-identity setting is introduced.

```dart
enum EmbeddingProviderKind { local, http }

final class EmbeddingConfig {
  const EmbeddingConfig({
    this.provider = EmbeddingProviderKind.local,
    this.model = 'embeddinggemma-300M-Q8_0.gguf',
    this.endpoint,
    this.credential,
  });

  final EmbeddingProviderKind provider;
  final String model;
  final Uri? endpoint;
  final String? credential;
}

final class SearchConfig {
  // Existing fields remain unchanged.
  final EmbeddingConfig embedding;
}

typedef ConversationSearchQuery = Future<List<SearchResult>> Function(
  String query, {
  required String userId,
  required int limit,
  SearchDiagnosticsSink? diagnostics,
});

final class ConversationSearchService {
  const ConversationSearchService({
    required FullTextIndex index,
    ConversationSearchQuery? query,
    String userId = 'owner',
  });

  Future<List<ConversationHit>> search(
    String query, {
    int limit = 20,
    SearchDiagnosticsSink? diagnostics,
  });
}

final class StorageWiring {
  Future<List<SearchResult>?> inspectMemorySearch(
    String query, {
    int limit = 20,
    SearchDiagnosticsSink? diagnostics,
  });
  Future<int?> memoryMissingVectorCount();
  Future<int?> conversationMissingVectorCount();
}

final class ComposedSearchBackend {
  static Future<({T? result, int? canonicalRevision, String? reason})> queryCurrentIndex<T>({
    required Future<T> Function() query,
    SearchIndexHealthProbe? indexHealthProbe,
  });
}
```

The YAML/registry surface is exactly `search.embedding.provider`, `search.embedding.model`,
`search.embedding.endpoint` and `search.embedding.credential`. Provider values are `local` and `http`. The local
provider supports only S03's verified `embeddinggemma-300M-Q8_0.gguf`, resolved at
`<data_dir>/models/embeddinggemma-300M-Q8_0.gguf`; its URL, size, SHA-256 and licence come only from
`DefaultEmbeddingModel`. An existing verified file at that managed path works offline. HTTP requires `endpoint` and
an explicitly present non-empty `model`; `credential` is an optional name of a present generic API-key entry and is
never replaced with its secret in `SearchConfig` or serialized configuration. `endpoint` and `credential` are absent
for `local`; arbitrary native GGUF paths and checksums are refused rather than implied compatible. An HTTP endpoint
must be an absolute HTTP(S) URI with a nonempty host and no userinfo, query or fragment. Reject it before storing,
serializing, fingerprinting or network use, and never include the rejected URI in validation output.

`MemoryStatusService` accepts optional `Future<int> Function()` readers for the two counts. Its existing
`/api/memory/status` `search` object gains nullable `memoryUnembeddedCount` and
`conversationUnembeddedCount`; both are null when hybrid is inactive or its vector runtime is unavailable. S06 uses
`inspectMemorySearch` for health-authenticated opt-in memory diagnostics and
`ConversationSearchService.search(..., diagnostics:)` for conversation diagnostics. The shared
`queryCurrentIndex` helper owns the current `ComposedSearchBackend` before/query/after probe sequence and its
`indexNotCurrent`, `indexHealthUnavailable`, `searchFailure` and `indexChangedDuringSearch` reasons. Normal memory
composition and inspection both call it. Inspection buffers diagnostics until the after-probe confirms the same
current revision/fingerprint; any unavailable result is null and releases neither hits nor diagnostics. S06 adds
token-bounded presentation, not another query service, health authority or status endpoint.

Memory and conversation mapping preserve the backend-native score and best-first order: successful hybrid results
already carry negative fused scores for lower-is-better memory composition, while pure lexical fallback retains its
original scores and order. Runtime wiring and canonical mappers do not negate or re-sort either path.

## Required Context

- `docs/specs/0.26/phase-b/plan.json#sharedDecisions` – exact provider/index/fusion contracts, corpus ownership,
  schema ordering, CLI ownership and final-verification boundaries.
- `docs/specs/0.26/phase-b/prd.md#fr1-hybrid-retrieval-for-two-corpora` – two owner-scoped corpus instances,
  lexical degradation and source-preserving results.
- `docs/specs/0.26/phase-b/prd.md#fr2-local-and-opt-in-http-embeddings` – explicit acquisition, HTTP opt-in,
  credential safety and provider recovery.
- `docs/specs/0.26/phase-b/prd.md#fr3-incremental-projection-and-recovery` – post-commit ordering, deletion,
  rebuild equivalence, missing counts and shutdown drain.
- `docs/specs/0.26/phase-b/prd.md#fr4-backend-vector-storage-and-compatibility` – SQLite/PostgreSQL vector setup,
  pgvector preflight and authoritative-store protection.
- `docs/specs/0.26/phase-b/prd.md#fr6-native-distribution-and-failure-handling` – bounded provider lifecycle and the
  actual platform/process evidence deferred to combined verification.
- `docs/specs/0.26/phase-b/prd.md#fr7-sealed-retrieval-evaluation` – frozen ranking settings must remain internal and
  must not become configuration or be retuned while wiring the runtime.
- `docs/specs/0.26/phase-b/prd.md#fr8-configuration-and-operator-guidance` – typed config, generated surfaces,
  command discoverability and QMD deprecation.
- `docs/specs/0.26/phase-b/s02-sqlite-and-postgresql-vector-projections.md#pinned-downstream-api` – exact vector-table,
  concrete-index and schema-gate consumers this runtime composes.
- `docs/specs/0.26/phase-b/s03-native-and-http-embedding-providers.md#pinned-consumer-surface` – exact provider,
  model-acquisition and network-check consumers, including recovery and terminal lifecycle semantics.
- `docs/specs/0.26/phase-b/s04-hybrid-fusion-and-incremental-synchronization.md#pinned-consumer-api` – exact hybrid,
  synchronizer and memory-adapter constructors and methods; this story adds no alternate implementation.
- `docs/specs/0.26/phase-b/implementation-context.md#constraints-for-hybrid-injection-across-both-corpora` – landed
  memory callback, conversation queue, session-deletion, rebuild and shutdown seams.
- `docs/specs/0.26/phase-b/implementation-context.md#config-and-generated-schema-chain` – existing parser,
  ConfigMeta, serializer, schema/reference and settings ownership chain.
- `../dartclaw-public/dev/state/PRODUCT.md#proportionality` – prototype scale and one-authority rule exclude a
  scheduler, provider pool, alternate content store or automatic background recovery system.
- `../dartclaw-public/dev/adrs/050-native-hybrid-search.md#decision` – accepted local-first hybrid path, HTTP escape
  hatch, derived vectors and QMD deprecation window.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-22--the-tier-order-replaces-the-per-edge-tables`
  – current package tiers and dependency-direction mechanism.

## Deeper Context

- `docs/specs/0.26/phase-b/native-artifacts.json#model` – immutable supported model filename, source, byte count,
  checksum and licence facts consumed through S03's model descriptor.
- `docs/specs/0.26/phase-b/selected-settings.json#rrfK` – frozen ranking/model settings; none becomes runtime config.
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring` – current storage
  composition, post-commit projection and shutdown owner.
- `../dartclaw-public/apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand.run` – one
  complete-source offline rebuild that must reconcile both retained vector corpora after lexical publication.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#layer-2--integration-tests-in-process-with-fakes` – focused
  runtime/CLI proofs use injected providers and stores; native/live/platform gates remain combined verification.

## Acceptance Scenarios

- **S01 [OC01] [TI01] Typed activation preserves FTS defaults and the QMD deprecation window**
  - **Given** omitted search configuration, `backend: fts5`, `backend: hybrid`, or `backend: qmd`
  - **When** configuration is parsed, serialized, validated and composed
  - **Then** omitted/FTS configuration constructs no provider or vector store; hybrid consumes exactly the four
    embedding keys above; QMD follows its existing manager/fallback behavior and emits one visible deprecation
    advisory; unknown keys, provider values and invalid provider-specific combinations are refused through the
    existing config authorities

- **S02 [OC03] [TI02,TI06] Explicit local acquisition and ordinary recovery use one managed verified artifact**
  - **Given** hybrid local configuration with the supported model absent, present and verified, corrupt, or a provider
    whose previous ordinary lazy initialization failed because the model was absent
  - **When** runtime search/write/rebuild is attempted, or `dartclaw search download-model` is run and a later explicit
    query, write or rebuild retries
  - **Then** missing/corrupt bytes leave lexical search available with the exact recovery command and current missing
    counts; download publishes or reuses only S03-verified bytes at the managed path; an ordinary failed attempt may
    recover on the same provider, while a timed-out provider remains terminal until runtime reconstruction/restart and
    cannot accumulate workers

- **S03 [OC04] [TI01,TI02] HTTP activation is explicit, source-safe and secret-free**
  - **Given** `provider: http` with endpoint/model combinations, including URI userinfo, query or fragment, an optional
    named credential and local or public hosts
  - **When** config validation and provider construction run
  - **Then** an absolute HTTP(S) endpoint with nonempty host, no userinfo, query or fragment and an explicitly supplied
    model are required; invalid endpoints are rejected before storage, serialization, fingerprinting or network use
    without echoing the URI; a named credential must resolve through `CredentialRegistry.namedEntry` to a present
    generic API key; runtime passes only the secret to S03 and serializes/logs only the reference; literal loopback is
    allowed because the administrator explicitly selected the endpoint, while non-loopback destinations pass
    `WebFetchTool.checkSsrfPolicy`; raw query/document text reaches the generic endpoint without EmbeddingGemma
    prefixes, and no HTTP fallback is selected automatically

- **S04 [OC01,OC02] [TI02] Hybrid backend setup preserves authoritative schemas and separate corpus stores**
  - **Given** SQLite or PostgreSQL configuration with hybrid enabled, including a fresh PostgreSQL namespace, a
    current authoritative namespace with absent vector objects, and incompatible partial vector objects
  - **When** `StorageWiring.wire` prepares retrieval
  - **Then** SQLite prepares one retained `vectors.db` with memory and conversation `VectorTable` instances independent
    of replaceable `search.db`; PostgreSQL calls vector-extension preflight before existing authoritative prepare and
    vector-projection prepare afterward, then uses two vector tables on the existing backend/pool; FTS/QMD invokes no
    vector gate; missing extension or incompatible projection follows S02's actionable refusal without installing an
    extension, resetting authoritative data or silently falling back to another vector store

- **S05 [OC02,OC03] [TI03,TI05] Canonical memory commits reconcile vectors after authenticated lexical publication**
  - **Given** incremental and complete memory projections containing changed, removed, unchanged and empty content,
    with retained vectors and injected provider/vector failures
  - **When** the existing post-commit projection publishes and authenticates lexical documents
  - **Then** it records lexical health before running vector work; an incremental projection calls the memory
    synchronizer for affected current/prior IDs and a complete projection calls `rebuild`; unchanged chunks reuse
    retained vectors and empty sources clear them; every vector failure remains visible through degradation/counts but
    cannot undo the canonical commit, lexical projection or healthy lexical evidence

- **S06 [OC02,OC03] [TI04,TI05] Conversation lifecycle, query and counts share the existing serialized owner**
  - **Given** append, clear, session deletion, archive and resume events plus a full conversation rebuild, including
    equal IDs in another owner/corpus and provider/vector failure
  - **When** `ConversationIndexer` processes each lexical mutation and `ConversationSearchService` queries the corpus
  - **Then** the same `_pending` chain runs vector synchronization only after its matching lexical mutation; session
    deletion still discovers IDs from surviving owner-scoped lexical rows before deleting them and synchronizes those
    IDs without rereading deleted NDJSON; persistence succeeds on vector failure; injected hybrid query preserves
    message/session/role/UTC/text provenance, backend-native score, best-first order and opt-in positive diagnostics;
    the conversation missing count is independent of memory and excludes removed content

- **S07 [OC02,OC03] [TI02,TI03,TI04,TI05,TI06] Rebuild and shutdown retain reusable vectors and close resources in order**
  - **Given** current canonical and conversation sources, a republished SQLite `search.db`, retained `vectors.db`, or
    PostgreSQL projections, followed by runtime shutdown
  - **When** startup recovery or existing `rebuild-index` completes both lexical rebuilds and vector reconciliation
  - **Then** memory and conversation synchronizers rebuild from their newly authenticated lexical corpora, reuse
    matching vectors, report separate remaining counts and clear empty corpora; shutdown waits for the memory callback
    and `ConversationIndexer.idle`, disposes the shared provider, closes the SQLite vector backend if present, and only
    then closes the authoritative/search backends; bounded vector failure preserves the published lexical indexes

- **S08 [OC01] [TI05] Memory inspection and normal composition share current-index authentication**
  - **Given** current, stale-before-query, changed-during-query and unavailable index-health evidence plus successful
    and throwing personal queries that emit diagnostics
  - **When** normal `ComposedSearchBackend` retrieval or `StorageWiring.inspectMemorySearch` runs
  - **Then** both paths use `queryCurrentIndex` for the same before/query/after sequence and reason values; inspection
    returns null for every unavailable case and discards buffered hits and diagnostics, while a current result releases
    both exactly once; normal composition retains its existing degradations, canonical revision and wiki behavior

## Structural Criteria

- **SC01** The accepted config surface is exactly the four `search.embedding.*` keys pinned above; defaults, equality,
  hash, parser, `ConfigMeta`, validator, serializer, schema, generated reference and Memory settings ownership agree,
  with no clear-text secret, URI userinfo/query/fragment or ranking/provider-lifecycle knob.
- **SC02** Hybrid runtime owns one embedding provider shared by two independent
  `FullTextIndex`/`VectorIndex`/`HybridSearch`/`VectorSynchronizer` corpus sets; it injects
  `MemoryIndexProjection.toSearchResult` and the existing conversation service mapping without score negation or
  re-sorting, with no second mapper, transcript reader, provider fallback or mutation queue.
- **SC03** `DartclawConfig.vectorsDbPath` derives `<data_dir>/vectors.db` without another YAML key; this store survives
  SQLite lexical sibling publication, while PostgreSQL reuses the authoritative backend and is never closed twice.
- **SC04** Root `dartclaw` registers one `search` command family containing `download-model`; the standalone workflow
  binary gains no search family, and the existing root `rebuild-index` command/name remains available in both binaries.

## Scope & Boundaries

### Work Areas

- Kernel search embedding configuration, parsing, registry metadata and runtime serialization.
- Runtime provider, backend-specific vector-store and two-corpus hybrid composition.
- Canonical memory post-commit vector reconciliation and conversation serialized lifecycle integration.
- Shared current-index health guard, runtime diagnostic/count access and existing memory status payload.
- Existing offline rebuild lifecycle and root `search download-model` CLI family.
- Focused config, runtime, source-lifecycle and CLI tests plus generated config/reference artifacts.

### What We're NOT Doing

- Fusion, synchronization, provider or vector-driver alternatives – S02/S03/S04 supply the only accepted implementations.
- Arbitrary local GGUF selection or operator knobs for paths, hashes, dimensions, fingerprints, ranking or deadlines –
  only the verified default native artifact is supported; HTTP `model` is the model-switch path in this release.
- Retrieval presentation, trace locator persistence or `search inspect` – S06 consumes the pinned seams and owns those
  bounded operator behaviors.
- New conversation endpoint, chat UI or conversation agent tool – the typed service/query boundary is sufficient for
  S06 diagnostics and the next milestone's UI.
- Public guide/architecture/release edits and actual live/native/platform/full/UI checks – S09 owns combined docs and
  final evidence after S06–S08 land.

## Architecture Decision

**Approach**: Extend `StorageWiring`, `ConversationIndexer`, `ConversationSearchService`, `MemoryStatusService` and the
existing rebuild/CLI owners around the exact S02–S04 consumers, with one provider and separate corpus instances.
**Why this over alternatives**: These owners already define authoritative post-commit order, serialized message
lifecycle, query mapping, status and rebuild; a new scheduler, mapper or standalone search runtime would duplicate them.

## Technical Overview

Hybrid activation constructs the selected provider once. SQLite opens and prepares retained `vectors.db`; PostgreSQL
preflights pgvector, prepares authoritative storage, then prepares its derived projection. Each backend yields separate
memory/conversation vector indexes, hybrid queries and synchronizers over the existing lexical indexes. Memory keeps
`HybridSearchBackend` inside the existing personal branch before wiki composition; conversation injects the hybrid
query into `ConversationSearchService`. Both mapping paths retain S04's result score and supplied best-first order;
diagnostics retain positive fusion evidence. The composer and memory inspection share `queryCurrentIndex`, with
inspection diagnostics held until the source remains current after the query. Lexical publication and health always
precede vector synchronization. `rebuild-index` follows the same complete-source order and reuses retained vectors.
Provider disposal follows both mutation drains and precedes storage closure.

## Code Patterns & External References

```text
# type | path#anchor | why needed
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring | one runtime storage, corpus composition and close-order owner
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/conversation_indexer.dart#ConversationIndexer | serialized append/delete/archive/resume lifecycle and session-ID discovery
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/conversation_search_service.dart#ConversationSearchService.search | sole conversation result mapping and degradation boundary
file | ../dartclaw-public/packages/dartclaw_core/lib/src/memory/memory_index_projection.dart#MemoryIndexProjection.toSearchResult | canonical memory mapper injected into S04 adapter
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/composed_search_backend.dart#ComposedSearchBackend.queryCurrentIndex | one before/query/after current-index health guard shared by normal composition and inspection
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/search_backend_factory.dart#createSearchBackend | personal-before-wiki composition and retained QMD branch
file | ../dartclaw-public/packages/dartclaw_kernel/lib/src/config_parser_providers.dart#_parseSearch | typed search parse and credential-reference validation pattern
file | ../dartclaw-public/packages/dartclaw_kernel/lib/src/config_meta/server_fields.dart#_serverFields | registry authority for search scalar keys
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/config/config_serializer.dart#ConfigSerializer.toJson | API/settings values and credential masking
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/web/settings/settings_sections.dart#settingsPanels | existing Memory panel owns all search fields
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/memory/memory_status_service.dart#MemoryStatusService._getSearchStatus | existing status payload extended with two counts
file | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand.run | complete memory/conversation lexical publication and offline close pattern
file | ../dartclaw-public/apps/dartclaw_cli/lib/src/runner.dart#buildDartclawRunner | tested root command registration authority
file | ../dartclaw-public/packages/dartclaw_kernel/lib/src/credential_registry.dart#CredentialRegistry.namedEntry | named credential resolution without provider fallback
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/mcp/web_fetch_tool.dart#WebFetchTool.checkSsrfPolicy | existing non-loopback destination check
```

## Constraints & Gotchas

- `search.backend: hybrid` alone activates vector work. FTS/QMD must not construct a provider, open `vectors.db`, call a
  vector PostgreSQL gate or make an embedding/network request.
- Runtime composition passes successful hybrid scores through exactly once: S04 supplies negative fused result scores
  for the lower-is-better personal composer, and pure lexical fallback supplies its original scores and order. Neither
  canonical mapper, conversation service nor wiring performs a second negation or sort.
- A local model name is a supported-artifact selector, not a path. Runtime obtains filename/hash/source only from
  `DefaultEmbeddingModel`; the download command and provider construction derive the same managed destination.
- HTTP preprocessing is raw query/document text. S03 applies frozen EmbeddingGemma prefixes only to its native
  provider; the HTTP fingerprint records its distinct raw-text convention, normalized endpoint and explicit model.
- The configured endpoint is administrator-owned. Permit literal `localhost`, `127.0.0.1` and `::1` using the existing
  `isLoopbackHost` predicate; every other address must pass `WebFetchTool.checkSsrfPolicy` before each S03 request.
  Before that policy or any other use, reject endpoints with userinfo, query or fragment without echoing their value.
- PostgreSQL hybrid ordering is strict: `preflightVectorExtension` → existing `prepareAuthoritativeStore` →
  `prepareVectorProjection`. Lexical-only paths call none of the vector operations. A current authoritative namespace
  may gain an entirely absent derived projection; a partial/incompatible one refuses with S02 guidance.
- Memory post-commit work is already awaited by the source authority. Keep lexical publication, integrity,
  authentication and healthy evidence in its existing error boundary; run vector synchronization afterward with its
  own degradation/logging boundary so a vector failure cannot relabel healthy lexical state.
- Conversation vector work runs in `ConversationIndexer._pending`, after its lexical mutation. For session deletion,
  collect the lexical IDs first, delete them, then synchronize those IDs. Do not add another observer or queue.
- Startup and explicit rebuild run both synchronizer rebuilds after complete lexical source authentication even when
  the lexical store was already current, so newly acquired models and prior missing vectors recover without replacing
  current lexical data. Provider/vector failure remains degraded availability rather than fatal storage setup.
- One provider is shared because the native model is process-resident. Ordinary lazy failures clear for later explicit
  use; initialization timeout makes that instance terminal; disposal is terminal. No background retry exists.
- Drain order is memory post-commit activity, `ConversationIndexer.idle`, provider dispose, SQLite vector backend,
  authoritative backend and lexical backend. Shared PostgreSQL backend closes once at its existing owner.

## Implementation Plan

### Implementation Tasks

- **TI01** Search configuration has one validated, generated and secret-safe embedding surface
  - Implement the pinned `EmbeddingConfig`/`SearchConfig` shape through parsing, equality/hash, `ConfigMeta`,
    validation, serialization, settings ownership, schema and generated reference; retain QMD with one advisory.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/search_providers_config_test.dart packages/dartclaw_kernel/test/config_meta_test.dart packages/dartclaw_kernel/test/config_validator_test.dart packages/dartclaw_runtime/test/config/config_serializer_test.dart packages/dartclaw_runtime/test/web/settings_form_test.dart && dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && dart run dev/tools/render_config_reference.dart --check` – defaults/equality, all provider-specific refusal clauses including URI userinfo/query/fragment with no secret-bearing output, credential references, exact registry keys, masked JSON, one settings owner and generated artifacts agree
  - **SATISFIES**: S01, S03, SC01

- **TI02** Hybrid activation composes one provider and two backend-correct corpus sets
  - Extend `StorageWiring` around the exact S02–S04 consumers, including managed local/HTTP provider selection,
    network/credential injection, SQLite `vectors.db`, strict PostgreSQL gate order and non-hybrid zero-work behavior.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_hybrid_activation_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart` – fakes prove local/HTTP construction, secret-bearing URI rejection without provider construction, request or echoed value, missing-model degradation, two corpus descriptors, strict preflight/prepare order, separate SQLite lifetime, PostgreSQL reuse and no provider/vector call under FTS/QMD
  - **SATISFIES**: S02, S03, S04, S07, SC02, SC03

- **TI03** Canonical memory projection reconciles vectors only after healthy lexical publication
  - Attach the memory `VectorSynchronizer` at the existing post-commit callback, using affected IDs for incremental
    projections and `rebuild` for complete projections with a separate vector-failure boundary.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_memory_hybrid_lifecycle_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_recovery_order_test.dart` – focused callback fixtures prove lexical-before-vector order, incremental IDs, complete/empty rebuild, reuse, healthy lexical evidence and committed-source survival under provider/vector failures
  - **SATISFIES**: S05, S07, SC02

- **TI04** Conversation indexing and search carry hybrid behavior through their existing owners
  - Extend `ConversationIndexer`'s one queue with an injected synchronizer callback and extend
    `ConversationSearchService` with the pinned query/diagnostic seam; retain lexical defaults and provenance mapping.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/conversation_indexer_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_conversation_hybrid_test.dart` – append/clear/delete/archive/resume, pre-delete lexical ID discovery, failure isolation, owner/corpus separation, hybrid provenance, backend-native score/order preservation and positive opt-in diagnostic cases cover every S06 clause
  - **SATISFIES**: S06, S07, SC02

- **TI05** Runtime access, status and close order expose both corpus states without another surface owner
  - Extract the composer's pinned `queryCurrentIndex` helper, supply health-guarded memory inspection and the two
    `MemoryStatusService` count readers; await both lifecycle drains, dispose the shared provider and close distinct
    stores once in the pinned order.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/composed_search_backend_test.dart packages/dartclaw_runtime/test/memory/memory_status_service_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_hybrid_lifecycle_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_conversation_hybrid_test.dart` – shared before/query/after current-index cases preserve normal composition and withhold stale/changed/unavailable inspection hits and buffered diagnostics; status yields independent nullable counts, and success/failure shutdown traces prove drain/dispose/close ordering without double-close
  - **SATISFIES**: S05, S06, S07, S08, SC02, SC03

- **TI06** Operators acquire the verified model and rebuild both retained vector corpora through existing commands
  - Register root `search download-model` against S03's acquirer and the managed destination; extend existing
    `rebuild-index` after each authenticated lexical corpus so it reconciles retained vectors and reports both counts.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/commands/search_download_model_command_test.dart apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart apps/dartclaw_cli/test/commands/rebuild_index_conversation_test.dart apps/dartclaw_cli/test/runner_test.dart` – acquisition reused/downloaded/failure output, root-only registration, unchanged command identity, both backend lifecycles, retained-vector reuse, empty clearing, separate counts and lexical survival under vector failure are covered
  - **SATISFIES**: S02, S07, SC03, SC04

### Testing Strategy

- Runtime and CLI tests inject provider creation, model acquisition, network checks, vector stores and synchronization
  results. They assert call order and persisted lexical/source outcomes, not private implementation state.
- Keep real model, HTTP network, pgvector, process termination and platform packaging out of this story's focused
  suites. S07/S08 create the final harnesses and S09 runs their combined obligations once.

## Implementation Observations

_No observations recorded yet._
