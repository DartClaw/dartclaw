# FIS: Retrieval Inspection and Turn Source Provenance

**Plan**: dev/bundle/docs/specs/0.26/phase-b/plan.json
**Story-ID**: S06

_Authored against public `3396754b6501` on `feat/0.26`; commands and `packages/...` paths run from
`../dartclaw-public/`. S05 is a prerequisite and must be accepted before execution._

## Feature Overview and Goal

**Intent**: Let an owner explain hybrid retrieval and audit which memory sources an agent actually received without
replaying mutable search state or enlarging ordinary agent payloads.

**Expected Outcomes**:

- [OC01] An authenticated operator can run one bounded diagnostic query against memory or persisted conversations and
  see returned source identity beside nullable constituent ranks, weighted contributions, fused score and degradation.
- [OC02] Each successful `memory_search` invocation in a turn trace retains only the bounded, deduplicated locators
  that its declared result returned, correlated to that invocation rather than inferred from its input or later state.
- [OC03] Existing search payloads, failed turns and old traces remain compatible when diagnostics or retained locators
  are absent.

## Pinned Operator and Trace Surface

The root CLI command is:

```text
dartclaw search inspect --corpus <memory|conversation> --query <text> [--limit <1..20>] [--json]
```

`--query` must be nonblank; `--limit` defaults to 20. The command extends S05's root-only `search` family and uses the
existing connected-command `--config`, `--server`, `--token`, authentication and exit-code behavior. `--json` emits
the server object unchanged. Human output identifies each result, prints `-` for either absent constituent rank,
shows both contributions, fused score and source layer, then summarizes unembedded count and degradations.

The command calls authenticated `POST /api/search/inspect` with the closed JSON body
`{"corpus":"memory|conversation","query":"...","limit":20}`. The body accepts only `corpus`, `query` and optional
`limit`; invalid JSON, unknown keys, an unsupported corpus, blank query or a limit outside 1–20 returns
`400 INVALID_INPUT`. Inactive/unavailable hybrid retrieval or a query that cannot supply diagnostics returns
`503 SEARCH_INSPECTION_UNAVAILABLE`. Memory inspection calls S05's guarded `StorageWiring.inspectMemorySearch`, which
returns null when the index was stale before the query, changed during it, health probing failed, personal search
failed or hybrid is inactive. The route returns 503 without hits or diagnostics in every such case. The `200` response
has exactly `corpus`, `results` and `diagnostics`:

```json
{
  "corpus": "memory",
  "results": [],
  "diagnostics": {
    "candidates": [
      {
        "documentId": "...",
        "chunkIndex": 0,
        "keywordRank": null,
        "vectorRank": 1,
        "keywordContribution": 0.0,
        "vectorContribution": 0.012295081967213115,
        "fusedScore": 0.012295081967213115,
        "sourceLayer": "memory"
      }
    ],
    "unembeddedCount": 0,
    "degradations": []
  }
}
```

Every memory result has `documentId`, `chunkIndex`, `role`, bounded `snippet`, `provenance`, `locator`, `score`, and
optional `entryId`/`entryRevision`, using `MemoryIndexProjection.toSearchResult` and the existing 240-Unicode-scalar
snippet bound. Every conversation result has `documentId`, `chunkIndex`, `messageId`, `sessionId`, `role`, UTC
`createdAt`, bounded `snippet` and `score`, using `ConversationSearchService`. Diagnostics contain only the exact
`SearchDiagnostics` fields above; no raw metadata, full conversation text, source text, vectors or credentials.
Results and candidates correlate by `(documentId, chunkIndex)`. Result `score` is exposed exactly as supplied by the
backend: successful hybrid fusion is negative for lower-is-better composition, while pure lexical fallback keeps its
original score. Diagnostic contributions and `fusedScore` remain positive. Inspection mapping performs no negation or
re-sorting.

`ToolCallRecord` gains immutable `List<String> sourceLocators`, encoded as `sourceLocators` and defaulting to `[]` when
absent. Only a successful pending call named `memory_search` may populate it: decode the correlated
`ToolResultEvent.output` as the declared JSON object, require `results` to be a list whose entries are objects with
nonblank string `locator` values, preserve first-return order, deduplicate exact strings and retain at most 50. An
error result, unmatched tool ID, other tool, malformed JSON or any malformed declared result leaves the list empty and
never escapes the existing tool-result accounting path. Inputs, snippets, guesses and a later query are never evidence.

## Required Context

- `docs/specs/0.26/phase-b/plan.json#sharedDecisions` – exact diagnostic types, S05 runtime/count seams, existing trace
  path, CLI ownership and final-verification boundaries.
- `docs/specs/0.26/phase-b/prd.md#fr5-retrieval-diagnostics-and-turn-provenance` – opt-in evidence, exact-return
  provenance, bounded retention, compatibility and malformed-output behavior.
- `docs/specs/0.26/phase-b/prd.md#fr8-configuration-and-operator-guidance` – operator must be able to inspect both
  corpus diagnostics through the supported command surface.
- `docs/specs/0.26/phase-b/s01-search-contracts-and-canonical-chunk-identities.md#pinned-contract-surface` – exact
  `SearchRankEvidence`, `SearchDiagnostics`, sink and chunk-identity contracts.
- `docs/specs/0.26/phase-b/s04-hybrid-fusion-and-incremental-synchronization.md#pinned-consumer-api` – the only hybrid
  query and missing-count implementations this story may expose.
- `docs/specs/0.26/phase-b/s05-runtime-activation-for-memory-and-conversations.md#pinned-configuration-and-downstream-surface`
  – exact guarded memory inspection, diagnostic-capable conversation service and status/count boundaries.
- `docs/specs/0.26/phase-b/implementation-context.md#turn-trace-provenance-path` – existing event correlation,
  `ToolCallRecord`, persistence column and trace API data flow.
- `../dartclaw-public/dev/state/PRODUCT.md#proportionality` – one-owner prototype scale excludes replay storage,
  another query service or a broader observability subsystem.

## Deeper Context

- `docs/specs/0.26/phase-b/implementation-context.md#retrieval-contracts-and-composition` – canonical memory mapper,
  compact tool result and shared runtime backend ownership.
- `docs/specs/0.26/phase-b/implementation-context.md#conversation-corpus-seams` – existing conversation result mapping
  and the absence of a production conversation tool/chat route.
- `../dartclaw-public/dev/adrs/050-native-hybrid-search.md#decision` – accepted local-first hybrid and opt-in
  diagnostic direction.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#layer-3--api--handler-tests` – direct handler and auth proof
  for a CLI-consumed endpoint.
- `../dartclaw-public/dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#testing-unit-integration-e2e` – focused command shape
  and standard fast-tier ownership.

## Acceptance Scenarios

- **S01 [OC01,OC03] [TI03] Memory inspection correlates compact results with complete diagnostic evidence**
  - **Given** authenticated hybrid memory retrieval containing keyword-only, vector-only and shared candidates plus a
    typed degradation and current unembedded count
  - **When** the operator posts a valid memory inspection request with a limit from 1 through 20
  - **Then** at most that many memory results retain canonical locators and bounded snippets; candidates correlate by
    document ID and ordinal and expose nullable one-based ranks, zero absent contributions, weighted contributions
    summing to positive fused score, `memory` source layer, count and structured degradations without forbidden
    content; results retain backend-native scores and supplied best-first order

- **S02 [OC01,OC03] [TI03] Conversation inspection preserves persisted message provenance through its service owner**
  - **Given** authenticated hybrid conversation results with persisted message/session IDs, role and UTC timestamp
  - **When** the operator requests conversation diagnostics
  - **Then** the route uses the diagnostic-capable `ConversationSearchService` under its bound owner scope; each
    bounded result retains that provenance, backend-native score and supplied best-first order and correlates to
    positive `conversation` evidence without adding a conversation tool, chat flow or second mapper

- **S03 [OC01,OC03] [TI03,TI04] Inspection rejects unsafe shape and reports unavailable hybrid retrieval**
  - **Given** malformed JSON, unknown fields, unsupported corpus, blank query, limit outside 1–20, missing hybrid
    wiring, stale pre-query memory health, changed post-query memory health, unavailable health, personal search
    failure, or a query that produces no diagnostic callback
  - **When** the API or connected `search inspect` receives the request
  - **Then** invalid input returns `400 INVALID_INPUT`; unavailable diagnostics return
    `503 SEARCH_INSPECTION_UNAVAILABLE` without stale/changed hits or buffered diagnostics; gateway authentication and
    connected CLI error/exit behavior remain in force

- **S04 [OC02,OC03] [TI01,TI02] Successful memory search retains only exact returned locators on its tool record**
  - **Given** one correlated successful `memory_search` output with repeated locators and more than 50 valid results
  - **When** `ToolResultEvent` completes that invocation and the turn trace is persisted and read through its JSON API
  - **Then** that call's `sourceLocators` contains the first 50 distinct exact returned locator strings in first-return
    order; no snippet or raw output is retained; the existing trace JSON round trip exposes the same list from the
    existing `turns.tool_calls` column

- **S05 [OC02,OC03] [TI01,TI02] Untrusted tool output cannot invent provenance or fail a turn**
  - **Given** failed, unmatched, non-memory, invalid-JSON, wrong-envelope, non-list `results`, non-object result or
    missing/non-string/blank locator outputs, plus stored legacy tool records without `sourceLocators`
  - **When** tool accounting completes and current or legacy traces decode
  - **Then** each affected call has an empty locator list, existing success/failure/count/duration behavior is
    unchanged, decoding remains non-throwing and no value from tool input, snippet text or requery is substituted

- **S06 [OC01,OC03] [TI04] Connected CLI renders nullable evidence and preserves machine JSON**
  - **Given** memory and conversation responses containing present and absent constituent ranks, counts and
    degradations
  - **When** the root CLI runs with or without `--json`
  - **Then** human output identifies result provenance, prints `-` for each absent rank and summarizes counts and
    degradation; JSON output equals the API object; corpus/query/limit map exactly to the pinned POST body

## Structural Criteria

- **SC01** Ordinary `memory_search`, Knowledge Hub, Context Research and conversation query result shapes are unchanged;
  diagnostics remain opt-in and no status endpoint, status UI, conversation UI or agent conversation tool is added.
- **SC02** Returned locators persist only inside each existing `ToolCallRecord` in `turns.tool_calls`; no table/column,
  top-level trace source list, replay store, source parser service or authoritative response schema is introduced.
- **SC03** The endpoint is mounted under the existing server pipeline and the CLI uses `ConnectedCommand` plus
  `DartclawApiClient.postObject`; no parallel token, owner, connection or error policy is created.

## Scope & Boundaries

### Work Areas

- `ToolCallRecord`, turn tool-result correlation and existing trace JSON persistence/API.
- Runtime diagnostic query route and server composition over S05's two query owners.
- Root `search inspect` connected CLI command and output formatting.
- Focused model/storage, adversarial output, API/auth/client and CLI tests.

### What We're NOT Doing

- Changing normal agent retrieval payloads or adding diagnostic fields to `memory_search` – inspection is operator
  opt-in and separate.
- Conversation chat/tool/UI work – there is no current tool call site and S05's service boundary is sufficient.
- A new status route or page – S05 already exposes both missing-vector counts through `/api/memory/status`.
- Requerying, replaying or persisting raw tool output/source text – mutable state cannot prove what a past call returned.
- Broad/live/PostgreSQL/native/platform/UI/release validation – S09 owns the single combined A+B final gate.

## Architecture Decision

**Approach**: Present S05's two diagnostic-capable query owners through one authenticated connected route/CLI, and
extend the already-correlated per-call trace record with a bounded exact locator list.
**Why this over alternatives**: A second search/replay service or persistence surface would duplicate current owners
and could manufacture historical provenance after source state changed.

## Technical Overview

The inspection route validates one closed bounded request, dispatches memory to
`StorageWiring.inspectMemorySearch` with a buffered diagnostic sink or conversation to
`ConversationSearchService.search`, and captures the single `SearchDiagnostics` callback for response serialization.
The memory path releases results and diagnostics only after S05's shared health guard confirms an unchanged current
index. Both paths preserve returned order and score signs while serializing positive diagnostic fusion evidence. The
turn path extracts provenance synchronously where `ToolResultEvent.output` still exists, after tool-ID/name
correlation and before `TurnOutcome` snapshots its records. Existing trace persistence and APIs then carry the
optional field without schema work.

## Code Patterns & External References

```text
# type | path#anchor | why needed
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/turn_guard_evaluator.dart#TurnToolHookCallbackHandler | correlated tool completion and bounded records
file | ../dartclaw-public/packages/dartclaw_core/lib/src/turn/tool_call_record.dart#ToolCallRecord | optional per-call JSON field and legacy default
file | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/turn_trace_service.dart#TurnTraceService | existing turns.tool_calls round trip
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/memory_handlers.dart#createMemoryHandlers | declared memory_search output shape and 50-result ceiling
file | ../dartclaw-public/packages/dartclaw_core/lib/src/memory/memory_index_projection.dart#MemoryIndexProjection.toSearchResult | sole memory result mapper
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/conversation_search_service.dart#ConversationSearchService.search | bound owner and conversation provenance mapper
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/api/api_helpers.dart#readJsonObject | bounded JSON body/error pattern
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/server.dart#DartclawServer._buildPipeline | shared gateway authentication policy
file | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/connected_command_support.dart#ConnectedCommand | shared client/auth/error/exit policy
file | ../dartclaw-public/apps/dartclaw_cli/lib/src/runner.dart#buildDartclawRunner | tested root command registration
```

## Constraints & Gotchas

- Treat the complete declared successful output as untrusted. Parse once inside `handleToolResult`; any malformed
  envelope/result/locator yields an empty list for that call. Catch format/type failures locally and still retain the
  original successful tool accounting record.
- Correlate before parsing: only the pending record resolved by `event.toolId` supplies the canonical tool name.
  `summarizeToolInput`, snippets and later search state are never locator sources.
- Freeze `sourceLocators`; preserve first-return order; deduplicate exact strings before the 50-item cap. Do not
  normalize, validate as current locators, resolve, requery or retain the whole output.
- Inspection limits apply before result presentation. Conversation text uses the existing 240-scalar memory snippet
  bound; diagnostic candidates never carry text. The response projects named provenance fields rather than raw
  metadata maps.
- The memory route uses only `StorageWiring.inspectMemorySearch`; it neither accesses raw `HybridSearch` nor duplicates
  the composer's index-health probe. S05 buffers diagnostics inside the guarded query and returns null unless the
  before/query/after sequence authenticates one current index revision/fingerprint.
- After successful authentication, the route invokes the existing canonical mapper. Conversation stays behind its
  service so owner scope and metadata interpretation remain singular. Both paths serialize supplied result order and
  backend-native score; neither derives ranking from the score nor negates it. Diagnostic contributions and fused
  score stay positive.
- S05 must be accepted before implementation because it owns guarded memory inspection, the diagnostic-capable
  conversation method and root `search` family consumed here.

## Implementation Plan

### Implementation Tasks

- **TI01** Per-tool trace records carry immutable backward-readable returned locators
  - Extend `ToolCallRecord` JSON/value semantics with `sourceLocators = const []`; keep `TurnTrace` and
    `TurnTraceService` on the existing nested record list and `turns.tool_calls` column.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/task/turn_trace_test.dart packages/dartclaw_core/test/storage/turn_trace_service_test.dart packages/dartclaw_runtime/test/api/trace_routes_test.dart` – current and legacy record/storage/API round trips preserve bounded locator lists and all existing counts/truncation
  - **SATISFIES**: S04, S05, SC02

- **TI02** Correlated successful memory results are the sole locator source
  - At `TurnToolHookCallbackHandler.handleToolResult`, parse only the pinned successful `memory_search` output after
    tool-ID correlation; apply exact deduplication/cap and contain every malformed shape without changing accounting.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/turn_guard_evaluator_test.dart` – raw successful, duplicate/over-limit, failed, unmatched, other-tool and every adversarial envelope/result/locator case prove exact provenance and non-throwing empty fallback
  - **SATISFIES**: S04, S05, SC02

- **TI03** One authenticated bounded route inspects either hybrid corpus
  - Mount the pinned `POST /api/search/inspect` contract through existing server deps/pipeline; dispatch only to S05's
    guarded memory inspection and conversation service, preserve owner scope, canonical mapping and content-free
    diagnostics.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/search_inspection_routes_test.dart packages/dartclaw_runtime/test/server_test.dart` – both corpus success shapes, identity/evidence correlation, backend-native result scores/order, positive diagnostic fusion evidence, nullable ranks, bounds, forbidden-field absence, malformed/unknown inputs, stale/changed/unavailable health with no released memory diagnostics, unavailable diagnostics and gateway authentication satisfy S01–S03
  - **SATISFIES**: S01, S02, S03, SC01, SC03

- **TI04** Root CLI exposes connected inspection with faithful human and JSON output
  - Add `inspect` under S05's root-only `search` family using `ConnectedCommand` and `postObject`; validate flags before
    dispatch, render the pinned evidence/provenance fields, and retain shared errors/exit codes.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/commands/search_inspect_command_test.dart apps/dartclaw_cli/test/runner_test.dart` – request method/path/body, bearer-capable shared client use, root-only registration, nullable-rank rendering, summaries, JSON identity and API error exit mapping satisfy S03 and S06
  - **SATISFIES**: S03, S06, SC03

### Testing Strategy

- Use pure/model and in-memory SQLite round trips for trace compatibility, adversarial literal output strings for the
  trust boundary, direct Shelf handler/server requests for API/auth, and an injected API transport for connected CLI
  request/response behavior. No live server, model, pgvector, browser or provider process is needed.

## Implementation Observations

_No observations recorded yet._
