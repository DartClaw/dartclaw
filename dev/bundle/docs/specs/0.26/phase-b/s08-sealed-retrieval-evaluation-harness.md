# FIS: Sealed Retrieval Evaluation Harness

**Plan**: dev/bundle/docs/specs/0.26/phase-b/plan.json
**Story-ID**: S08

_Authored against public `3396754b6501` on `feat/0.26`; commands and `packages/...` paths run from
`../dartclaw-public/`. S01–S04 pin the consumed contracts. Implementation still requires accepted S05._

## Feature Overview and Goal

**Intent**: Give final milestone acceptance a reproducible, sealed measurement of whether the shipped hybrid search
actually improves Swedish/English retrieval on both corpora and database backends without tuning against held-out
results.

**Expected Outcomes**:

- [OC01] One command evaluates keyword, vector and hybrid retrieval through the real SQLite and PostgreSQL pipelines
  for owner-scoped memory and conversation documents.
- [OC02] The report contains complete, reproducible quality and warm-latency slices with the exact frozen metric
  definitions and every numerical quality gate decided from machine-readable evidence.
- [OC03] Held-out inputs and selected settings remain byte-identical to their pre-score versions, and missing
  infrastructure, incomplete slices, no-result hits or isolation leaks fail instead of disappearing from the report.
- [OC04] The first native embedding measurement includes lazy model verification and initialization, while reported
  performance remains measured-environment evidence rather than a portable SLA.

## Pinned Evaluation Contract

The committed evaluator has two modes only:

1. `--check-assets` verifies the fixed assets, hashes and fixture shape without constructing a provider, opening a
   database, retrieving any result or calculating any held-out score.
2. A full run always evaluates both backends, all three modes and both corpora. It accepts only
   `--model-path <path>` and `--output-dir <path>`; PostgreSQL comes from `DARTCLAW_TEST_POSTGRES_URL`. Fixture paths,
   ranking settings, thresholds, languages, warm-up count and repetition count have no CLI or environment override.

S09 runs this exact command from the public repository after S05, S07 and S08 are accepted and the prepared runtime
credential and native artifact environment are active:

```bash
dart run apps/dartclaw_cli/tool/retrieval_evaluation.dart \
  --model-path "$DARTCLAW_TEST_EMBEDDING_MODEL" \
  --output-dir .agent_temp/0.26-final/retrieval-evaluation
```

The command writes `.agent_temp/0.26-final/retrieval-evaluation/report.json` and
`.agent_temp/0.26-final/retrieval-evaluation/artifact-sha256.txt` atomically. A completed passing run prints
`Retrieval evaluation: PASS (144 slice rows, 0 violations)` and exits 0. A completed failing run still writes both
artifacts, prints `Retrieval evaluation: FAIL (<N> violations)` and exits 1. Missing/invalid assets, model,
PostgreSQL/pgvector capability or an incomplete run write a safe failure report when possible, print one actionable
error without a DSN, credential, query or document body, and exit nonzero.

`report.json` has `schemaVersion: "1"`, `status`, `protocol`, `environment`, `backendRuns`, `sliceRows`, `gateRows` and
`violations`. `sliceRows` contains exactly 144 stably sorted rows: the Cartesian product of backend
`sqlite|postgresql`, mode `keyword|vector|hybrid`, corpus `memory|conversation`, language `en|sv` and family
`exact-keyword|vocabulary-mismatch|named-entity|temporal|relational|no-result`. Every row records `queryCount`,
`hitAt1`, `recallAt5`, `precisionAt5`, `mrrAt5`, `correctEmptyRate` and nearest-rank `warmP95Ms`. Positive rows set
`correctEmptyRate` to null. No-result rows set all four relevance metrics to null and report only correct-empty rate.

`protocol` records the frozen settings, fixture/settings/calibration/model hashes, top-K 5, candidate limit 20, one
warm-up pass and one measured repetition per query/mode/backend, PostgreSQL language mapping `en: english` and
`sv: swedish`, and the source revision. `environment` records Dart/OS versions, architecture and processor count.
Each `backendRuns` entry records provider fingerprint, cold first `embedDocuments` duration, projection/synchronization
counts and total duration. The first embedding call is observed at the provider port while
`VectorSynchronizer.rebuild` drives it, so it includes `NativeEmbeddingProvider`'s lazy SHA verification and model
initialization rather than a constructor timer.

`gateRows` contains the compared aggregate values and threshold for every gate below; `violations` names every failed
row rather than stopping at the first aggregate miss:

- Per backend and corpus, vocabulary-mismatch hybrid hit@1 and MRR@5 must each be strictly greater than keyword-only.
- Per backend and each other positive family, macro hybrid hit@1, recall@5, precision@5 and MRR@5 over all ten queries
  may trail the better keyword/vector constituent by at most 0.10 absolute.
- Per backend, corpus and each other positive family, the same four hybrid metrics over the five-query corpus slice
  may trail the better constituent by at most 0.20 absolute.
- Per backend and mode, all ten no-result queries must return an empty document ranking.
- Per backend and mode, foreign-owner and wrong-corpus result counts must both be zero independently of quality scores.

For every positive query, hit@1 is 1 only when the first unique returned document is relevant; recall@5 is relevant
documents in the first five divided by that query's relevance count; precision@5 always divides relevant documents
by five even when fewer than five results were returned; MRR@5 is the reciprocal rank of the first relevant document
within five or zero. Slice values are macro means of per-query values and are rounded to four decimals only for
serialization, never before gate comparison. Nearest-rank p95 sorts raw microseconds and selects
`ceil(sampleCount * 0.95) - 1`, then reports milliseconds to four decimals.

The evaluator treats each backend's supplied result list as best-first. It may deduplicate chunks by first-seen
document ID, but never sorts or derives rank from `SearchResult.score`. Successful hybrid scores are negative fused
scores for lower-is-better memory composition, pure lexical fallback scores are backend-native, and diagnostic
contributions/fused score remain positive; the evaluator performs no negation or score normalization.

## Required Context

- `docs/specs/0.26/phase-b/plan.json#sharedDecisions` – exact contracts, derived-store lifetime, synchronization
  ownership, frozen ranking settings and final verification ownership.
- `docs/specs/0.26/phase-b/prd.md#fr1-hybrid-retrieval-for-two-corpora` – corpus/owner boundaries, current-source
  identity, real fusion mechanism and the separate wiki composition invariant.
- `docs/specs/0.26/phase-b/prd.md#fr7-sealed-retrieval-evaluation` – fixture shape, metric definitions, complete slice
  matrix, numerical tolerances, provenance and no-retuning rule.
- `docs/specs/0.26/phase-b/s01-search-contracts-and-canonical-chunk-identities.md#pinned-contract-surface` – exact
  vector, embedding, lexical result and diagnostic contracts used by the runner.
- `docs/specs/0.26/phase-b/s02-sqlite-and-postgresql-vector-projections.md#pinned-downstream-api` – the real
  corpus-specific vector indexes and vector schema-gate ordering.
- `docs/specs/0.26/phase-b/s03-native-and-http-embedding-providers.md#pinned-consumer-surface` – synchronous lazy
  native provider construction, verified model identity and lifecycle bounds.
- `docs/specs/0.26/phase-b/s04-hybrid-fusion-and-incremental-synchronization.md#pinned-consumer-api` – real
  `HybridSearch`, `VectorSynchronizer` and `HybridSearchBackend` surfaces; no evaluator-owned fusion or inventory.
- `docs/specs/0.26/phase-b/selected-settings.json#heldOutSha256` – immutable RRF, weight, cutoff, candidate, model,
  prefix and artifact selection frozen before held-out scores.
- `docs/specs/0.26/phase-b/heldout.json#queries` – the 32-document/60-query, two-corpus, two-language held-out fixture;
  its required SHA-256 is `2635bb02da1f8dddd67e9b9f22795cc32dbee34588d642b573bdf00b8ec7b9a3`.
- `docs/specs/0.26/phase-b/calibration-negatives.json` – ten frozen no-result calibration inputs with SHA-256
  `2df62c960c83ffe5485f81ae22ec63acd0ddf6f54292e52837f1531edd08bb46`.
- `docs/specs/0.26/phase-b/calibration-summary.md#rrf-candidates` – correct final calibration macro metrics and the
  evidence for the already-selected settings; it is provenance, never a held-out tuning surface.
- `docs/specs/0.26/phase-b/implementation-context.md#prepared-pgvector-verification-environment` – prepared
  PostgreSQL 16/pgvector 0.8.6 runtime-role environment, public qualification and safe credential handling.
- `../dartclaw-public/dev/state/PRODUCT.md#proportionality` – prototype scale excludes ANN infrastructure, a service,
  a second scorer or a second content authority.
- `../dartclaw-public/dev/adrs/050-native-hybrid-search.md#decision` – native local default, weighted RRF and derived
  vector posture.

## Deeper Context

- `docs/specs/0.26/phase-b/implementation-context.md#existing-preparation-resources` – prepared native/model and
  calibration locations; final product evidence must use the landed implementation.
- `docs/specs/0.26/phase-b/native-artifacts.json#model` – exact model length, checksum, dependency version and licence.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#decision` – package boundaries; the evaluator is
  development tooling and creates no package or production dependency edge.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#layer-4--live-integration--e2e-tests` – real-infrastructure
  execution stays explicit and final-gate-only; deterministic metric logic uses focused tests.
- `../dartclaw-public/packages/dartclaw_core/test/search/wiki_search_source_test.dart#main` – existing FTS/QMD
  composition examples; this story adds a distinct hybrid-personal composition proof.

## Acceptance Scenarios

- **S01 [OC03] [TI01] Frozen assets refuse drift before any held-out scoring**
  - **Given** exact copies of the historical 24-document/16-query calibration fixture, ten calibration negatives,
    calibration summary, selected settings and 60-query held-out fixture
  - **When** `--check-assets` or a full run starts
  - **Then** it verifies the held-out SHA above, selected-settings SHA
    `32bf711292532f51313404072d61ff6443660a5c578cd0095574de94a8303a1a`, calibration-negative SHA above,
    calibration-summary SHA `2c360ad1802a116e54ed4c3b020344bc179615fe71952d48dfb4c3eefb5ff97a` and historical fixture source SHA
    `79cb7e157df009a74096c853cd70ededcecbefc5ac0a89ac928ad2923d3d8148`; any mismatch or missing required
    language/corpus/family cell refuses before provider/database construction

- **S02 [OC01,OC03] [TI02] [runtime] Both backends exercise the real owner-scoped retrieval pipelines**
  - **Given** fixture documents for the target and foreign owner, separate memory and conversation indexes, the
    selected native provider and a PostgreSQL runtime role with pgvector already installed in `public`
  - **When** the evaluator seeds SQLite files and one disposable PostgreSQL namespace and evaluates each query
  - **Then** memory documents pass through `MemoryIndexProjection.document` with their fixture ID retained as canonical
    locator/entry identity; conversation documents pass through `ConversationIndexProjection.document` using
    deterministic valid session/message identity; `VectorSynchronizer.rebuild` derives both vector corpora; keyword
    calls the real FTS index, vector calls the provider plus real `VectorIndex`, and hybrid calls `HybridSearch`; no
    cosine stand-in, evaluator fusion, score-based re-sort or raw metadata shortcut can satisfy the scenario

- **S03 [OC02] [TI01,TI02] Every backend/mode/corpus/language/family slice is explicit and mathematically stable**
  - **Given** positive judgments with one or more relevant document IDs and empty-relevance no-result judgments
  - **When** rankings and raw query durations are aggregated
  - **Then** the evaluator emits exactly the 144 pinned rows in stable order, deduplicates repeated chunks by document
    ID before top-five metrics, uses the fixed denominator five and macro formulas above, reports relevance metrics as
    null for no-result rows, and calculates nearest-rank warm p95 from unrounded samples

- **S04 [OC02,OC03] [TI01] Exact quality tolerances decide the report without post-score adjustment**
  - **Given** constituent and hybrid rankings at, immediately inside and immediately outside each PRD tolerance
  - **When** the gate logic compares vocabulary-mismatch, other positive families and five-query corpus slices
  - **Then** strict vocabulary improvement is required per backend/corpus; the better constituent is selected per
    backend/family/metric; 0.10 family and 0.20 corpus-family regressions pass at equality and fail beyond it; every
    failed comparison appears in `gateRows` and `violations`; no input, setting or tolerance is rewritten

- **S05 [OC03] [TI01,TI02] No-result and isolation failures cannot hide behind aggregate quality**
  - **Given** ten no-result queries plus a returned document belonging to a foreign owner or the other corpus
  - **When** any backend/mode ranking is validated
  - **Then** all ten no-result rankings must be empty for that backend/mode, owner and corpus leaks are counted
    separately, and any nonzero count fails the run even when every positive aggregate passes

- **S06 [OC02,OC04] [TI02] [runtime] Timing and provenance describe the measured execution only**
  - **Given** a synchronously constructed, not-yet-initialized `NativeEmbeddingProvider` and the frozen protocol
  - **When** the first synchronized document batch and subsequent per-mode warm-up/measured queries run
  - **Then** the first provider call duration includes model checksum verification and lazy load, all modes use the same
    candidate/top-K/warm-up/repetition protocol, every report carries model/fixture/settings/source/environment facts,
    and no pass/fail threshold is applied to cold or warm latency

- **S07 [OC01] [TI03] Hybrid personal memory preserves exact wiki-over-raw and lexical-fallback composition**
  - **Given** a real `HybridSearchBackend` that can return at least two canonical personal hits with different positive
    fused ranks, a source-backed wiki result for the same topic, and a semantic-provider failure that exercises pure
    lexical fallback with differently scored personal hits
  - **When** the existing `ComposedSearchBackend` performs unrestricted memory-plus-wiki and memory-only searches for
    both the successful hybrid and semantic-failure cases
  - **Then** wiki remains first for unrestricted searches with its synthesized-knowledge role/provenance intact;
    successful personal hits follow in descending positive fused-rank order using their negative result scores;
    memory-only selection removes wiki without changing that order; and semantic failure preserves the lexical scores
    and best-first order through the mapper and composer, so a missing or second negation reverses an asserted result

## Structural Criteria

- **SC01** Public evaluation assets are byte-for-byte copies of the frozen private sources; the four known source
  hashes and the held-out hash embedded in selected settings are asserted independently of generated results.
- **SC02** Evaluation code is dev-only CLI tooling and tests in existing packages. It adds no production API, package,
  configuration key, database object, scheduler, service, scorer or dependency edge.
- **SC03** PostgreSQL vector ranking uses `PostgresVectorIndex` and pgvector through the prepared application pool;
  SQLite uses `SqliteVectorIndex`; hybrid uses `HybridSearch`; both corpora use their canonical projection functions.
- **SC04** Focused tests use tiny independent literal fixtures and never import/read the held-out fixture or execute the
  native model/PostgreSQL. The actual held-out command runs once only in S09's final combined gate.
- **SC05** The report contains no query/document bodies, DSN, credential, raw vectors or exception payloads; latency is
  informational and has no hardware-independent acceptance threshold.

## Scope & Boundaries

### Work Areas

- Frozen public calibration, held-out and selected-settings assets with exact integrity checks.
- Pure metric, slice-matrix, gate and report serialization logic in existing CLI development tooling.
- Real SQLite/PostgreSQL memory and conversation evaluation composition over S01–S04/S05 surfaces.
- Focused independent-literal tests plus one exact hybrid wiki composition test.
- Final combined-gate command and machine-readable evidence contract consumed by S09.

### What We're NOT Doing

- Running or inspecting held-out scores during S08 implementation – S09 owns the single final combined execution.
- Retuning weights, cutoff, prefixes, candidate limit, judgments or tolerances after held-out results – failure requires
  a causal implementation fix or explicit product decision.
- Adding a cosine scorer for PostgreSQL, evaluator-owned RRF, alternate corpus mapper or synthetic production backend –
  the real landed runtime components are the evaluation subject.
- Adding latency SLAs, benchmark hardware classes, ANN indexes, query expansion or reranking – none is required by FR7.
- Evaluating wiki, KG or task retrieval in the held-out matrix – wiki keeps one separate exact composition regression;
  the other corpora remain outside Phase B hybrid scope.

## Architecture Decision

**Approach**: Put one fixed dev-only evaluator in the existing CLI package, seed valid source documents through the
canonical projections, and measure the injected production ports while a pure result layer owns metrics and gates.
**Why this over alternatives**: Reusing the actual indexes/provider/synchronizer/fusion path makes the result evidence
about the shipped system, while a standalone scorer or copied mapper could pass without exercising it.

## Technical Overview

The evaluator copies frozen inputs into `dev/testing/retrieval/` and hard-pins their source hashes. For each backend it
constructs one native provider and two independent lexical/vector/hybrid/synchronizer pairs. SQLite uses temporary
`search.db` and `vectors.db` files. PostgreSQL creates a unique disposable namespace, runs vector preflight before
authoritative and derived preparation, reprojects for `english` and `swedish`, evaluates only the matching language
queries in each pass, and drops the namespace in `finally`. The same document IDs seed each pass, so language rows can
be combined without changing judgments. Output rankings normalize chunk hits to first-seen unique document IDs. The
pure result layer consumes that supplied best-first order without sorting by backend-native score, then creates the
full slice matrix, aggregate gate rows, provenance and a terminal status.

## Code Patterns & External References

```text
# type | path#anchor | why needed
file | ../dartclaw-public/apps/dartclaw_cli/tool/check_system_sqlite_override.dart#main | existing CLI-package dev-tool placement and exit-code idiom
file | ../dartclaw-public/packages/dartclaw_core/lib/src/memory/memory_index_projection.dart#MemoryIndexProjection.document | valid canonical memory metadata and fixture-ID mapping
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/conversation_index_projection.dart#ConversationIndexProjection.document | valid conversation message/session projection
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/postgres_fts_index.dart#PostgresFtsIndex | actual language-specific PostgreSQL keyword scorer
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/composed_search_backend.dart#ComposedSearchBackend | shipped wiki-over-raw composition owner
file | docs/specs/0.26/phase-b/s02-sqlite-and-postgresql-vector-projections.md#Pinned Downstream API | concrete vector and schema surfaces
file | docs/specs/0.26/phase-b/s03-native-and-http-embedding-providers.md#Pinned Consumer Surface | native provider constructor and lazy lifecycle
file | docs/specs/0.26/phase-b/s04-hybrid-fusion-and-incremental-synchronization.md#Pinned Consumer API | hybrid/synchronizer/adaptor entry points
```

## Constraints & Gotchas

- Copy the five immutable sources without formatting: historical calibration fixture SHA
  `79cb7e157df009a74096c853cd70ededcecbefc5ac0a89ac928ad2923d3d8148`, calibration negatives SHA
  `2df62c960c83ffe5485f81ae22ec63acd0ddf6f54292e52837f1531edd08bb46`, calibration summary SHA
  `2c360ad1802a116e54ed4c3b020344bc179615fe71952d48dfb4c3eefb5ff97a`, selected settings SHA
  `32bf711292532f51313404072d61ff6443660a5c578cd0095574de94a8303a1a`, and held-out SHA
  `2635bb02da1f8dddd67e9b9f22795cc32dbee34588d642b573bdf00b8ec7b9a3`.
- Memory fixture records use `MemoryIndexProjection.document` with fixture ID as `locator` and `entryId`, revision 1,
  role `topic`, fixed UTC timestamps and a safe fixture provenance. Conversation records use
  `ConversationIndexProjection.document` with fixture ID as `Message.id`, fixed valid UUID session IDs, chat-facing
  `SessionType.user`, role `user`, ordinal cursor and the same deterministic UTC timestamp sequence.
- Seed target-owner and foreign-owner documents into their own owner scope. Each query addresses only its declared
  corpus instance and tenant. Validate every returned document ID against the fixture's tenant/corpus lookup before
  metric normalization; an unknown ID is both a leak and a violation.
- PostgreSQL runs with the runtime credential only. Qualify the vector capability through S02's production code, never
  connect as extension administrator, emit the DSN or retain the unique namespace after success/failure.
- Vector-only rankings must come from `NativeEmbeddingProvider.embedQuery` plus the concrete `VectorIndex.search` and
  current lexical identity authentication. Hybrid rankings come directly from `HybridSearch`; keyword rankings come
  directly from the selected `FullTextIndex`. Evaluation helpers may normalize/document-deduplicate returned IDs in
  first-seen order but may not sort by score, negate scores, or recalculate cosine, RRF or canonical metadata.
- Report artifacts use operation-unique temporary siblings and rename only after complete serialization. A quality
  FAIL remains evidence and is published; an interrupted partial JSON is not.

## Implementation Plan

### Implementation Tasks

- **TI01** Frozen inputs and pure evaluation rules have one deterministic contract
  - Copy the exact five inputs into `dev/testing/retrieval/`; implement immutable parsing, hash/shape preflight,
    document-level ranking normalization, metric/slice/gate calculation and schema-v1 report serialization in the
    existing CLI tool surface. Tests use only tiny independent literals and exact boundary values.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/tool/retrieval_evaluation_test.dart && dart run apps/dartclaw_cli/tool/retrieval_evaluation.dart --check-assets` – independent literals prove fixed-denominator metrics, null no-result metrics, nearest-rank p95, 144-row completeness, strict lift, exact 0.10/0.20 boundaries, all-ten empty and isolation gates; asset-only mode proves every frozen hash/shape without producing a held-out score
  - **SATISFIES**: S01, S03, S04, S05, SC01, SC02, SC04, SC05

- **TI02** One executable harness measures both real backend pipelines and emits final-gate evidence
  - Compose the projections, schema gates, concrete lexical/vector indexes, `NativeEmbeddingProvider`,
    `VectorSynchronizer` and `HybridSearch` exactly as pinned; a tiny injected-fixture pipeline test exercises real
    SQLite components and records PostgreSQL/native as final-only infrastructure. Implement the exact command/output
    contract above without running it on held-out data during this story.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/tool/retrieval_evaluation_pipeline_test.dart && dart analyze --fatal-infos apps/dartclaw_cli/tool/retrieval_evaluation.dart apps/dartclaw_cli/test/tool` – a tiny independent fixture passes through real SQLite FTS/vector/synchronizer/hybrid and both canonical projection functions; supplied best-first order survives document deduplication without a score sort or negation; doubles only supply embedding values and timing, while command parsing, safe failures, atomic reports and final PostgreSQL/native wiring compile
  - **SATISFIES**: S02, S03, S05, S06, SC02, SC03, SC04, SC05

- **TI03** Wiki composition is exact with a hybrid personal backend
  - Add one focused runtime-package regression composing a real `HybridSearchBackend` adapter with
    `ComposedSearchBackend` and a source-backed wiki fixture; use at least two differently fused personal hits and a
    semantic-provider failure, then assert exact success/fallback scores, order, labels, locators and layer selection.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/search/hybrid_wiki_composition_test.dart` – wiki plus at least two differently ranked hybrid personal hits prove wiki-first and descending positive fusion through the lower-is-better composer; a semantic-failure case proves unchanged lexical scores/order; unrestricted and memory-only assertions cover every S07 clause
  - **SATISFIES**: S07, SC02, SC03

### Testing Strategy

- TI01 isolates arithmetic, matrix and gate edge cases in small literal rankings that share no held-out IDs/text.
- TI02 uses real temporary SQLite FTS/vector stores and real S01–S04 collaborators with a deterministic embedding-port
  fake. PostgreSQL, pgvector and native model execution are deliberately absent from S08 implementation tests.
- S09 alone runs the pinned full command after its prerequisite stories. A failing held-out report is retained as
  evidence and cannot trigger fixture/settings/tolerance edits within this story.

### Execution Contract

- Do not begin S08 implementation until S05 is accepted. S05's runtime configuration/wiring remains the reference for
  constructing the same corpus/backend/provider combinations; S08 adds no alternate runtime composition.
- During S08, run TI01–TI03 Verifies and standard story checks only. Do not run the full command, inspect any held-out
  aggregate score, or substitute the prepared calibration scorer for production components.
- S09 must run the exact full command once on the accepted combined A+B tree. Targeted reruns are allowed only after a
  causal implementation fix invalidates that evidence, never after a setting, fixture, judgment or tolerance change.

## Final Validation Checklist

- The full S09 command exits 0, `report.json.status` is `pass`, exactly 144 complete slice rows exist, every gate row
  passes and `violations` is empty.
- `artifact-sha256.txt` covers the report, evaluator sources, five committed frozen inputs and actual model bytes; the
  report repeats their hashes plus the source revision and measured environment.
- S09 retains the report beside the Phase A deferred proofs and S07 native/platform evidence before milestone
  consolidation; no raw credential, query/document body or vector appears in either evaluation artifact.

## Implementation Observations

_No observations recorded yet._
