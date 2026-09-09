# Product Requirements Document: DartClaw 0.26 Phase B – Native Hybrid Search

> **Source**: /Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/specs/0.26/hybrid-search-prd-brief.md
> **Context**: 0.26 completes its database backend milestone with hybrid retrieval for both canonical memory and persisted conversation messages. Phase A supplies the two owner-scoped lexical corpora and current-schema gates.
> **Related Assets**: Public ADR-050 (native hybrid search), ADR-056 (package topology), ADR-045 (database backend), ADR-048 (native release bundles), and the public Product Summary.

## Executive Summary

- **Problem**: Keyword search misses Swedish/English vocabulary mismatches and cross-language questions. The historical 24-document calibration fixture scored 0.38 keyword hit@1; that historical scorer is not a claim about current backend-native search quality. QMD provides opt-in semantic memory search through an external process and does not supply conversation hybrid retrieval.
- **Vision**: An owner enables built-in local embeddings once, then retrieves relevant canonical memory and conversations through the existing source and tenancy boundaries on SQLite or PostgreSQL.
- **Target users**: A single-instance owner querying Swedish/English knowledge, an operator selecting a local or explicitly remote embedding service, and contributors maintaining the runtime and release bundles.
- **Success metrics**: Both corpora meet FR7's frozen held-out quality criteria on both database backends; stale, deleted and foreign-owner vectors never surface; embedding failure preserves keyword search and message persistence with visible degradation; selected native release platforms pass real builds and failure probes.

### Capabilities at a Glance

- **FR1: Hybrid Retrieval for Two Corpora** _(Must / P0)_ – Fuse keyword and semantic matches without merging memory, conversation, wiki, KG or owner boundaries.
- **FR2: Local and Opt-In HTTP Embeddings** _(Must / P0)_ – Load a verified local model by default, with explicit HTTP provider configuration as an alternative.
- **FR3: Incremental Projection and Recovery** _(Must / P0)_ – Preserve source identity across live changes, deletion, rebuild and model changes.
- **FR4: Backend Vector Storage and Compatibility** _(Must / P0)_ – Store derived vectors in SQLite or PostgreSQL with transactional setup and actionable refusal.
- **FR5: Retrieval Diagnostics and Turn Provenance** _(Must / P1)_ – Explain ranking on request and retain the locators actually returned to a turn.
- **FR6: Native Distribution and Failure Handling** _(Must / P0)_ – Ship one binary flavor with pinned native dependencies and bounded initialization failures.
- **FR7: Sealed Retrieval Evaluation** _(Must / P0)_ – Establish current backend-native quality on independently held-out Swedish/English judgments.
- **FR8: Configuration and Operator Guidance** _(Must / P1)_ – Make activation, download, rebuild, diagnostics and QMD deprecation discoverable.

### Scope Highlights

- **In scope**: Both corpora, both database backends, local embedding default, explicit HTTP alternative, ranking explanations, provenance, incremental rebuild, packaging and held-out evaluation.
- **Out of scope**: Query expansion, cross-encoder reranking, approximate-nearest-neighbor infrastructure, task/KG/wiki vector projection, QMD removal, a new conversation UI.
- **MVP boundary**: A complete local-first hybrid path for memory and conversations with verified fallback, source lifecycle, release artifacts and quality evidence.

### Key Constraints, Assumptions & Dependencies

- **Constraint**: FTS remains the zero-config default; hybrid and external embedding endpoints require explicit configuration.
- **Constraint**: Preserve one canonical mapper per corpus and one schema authority per backend; add no migration runner.
- **Dependency**: Phase A's accepted implementation checkpoint precedes production Phase B implementation.
- **Constraint**: Final acceptance uses combined A+B verification. Earlier feasibility experiments do not satisfy release platform or retrieval gates.

## Problem Definition

### Problem Statement

An owner asking about a remembered concept should not need to reproduce the original wording or language. Lexical search alone cannot reliably bridge those gaps. Semantic retrieval must also cover persisted conversations, retain the source needed to verify a hit, and avoid returning stale content after deletion or model changes. Operators need a local default and an inspectable failure mode when embeddings are unavailable.

### Evidence & Context

The historical Swedish/English spike demonstrated a usable native embedding path and showed that equal-weight fusion can degrade an otherwise correct semantic result. Its small calibration fixture motivates weighted fusion and a separate held-out gate, not an unconditional quality claim. The current native dependency has been exercised in a macOS arm64 AOT feasibility smoke; remaining platform and runtime failure proofs are required against the final implementation.

## Scope

### In Scope

- Owner-scoped hybrid retrieval over canonical searchable memory roles and eligible persisted conversation messages, using both landed database backends.
- Native embedding generation, opt-in OpenAI-compatible HTTP embeddings, verified model acquisition, incremental vector maintenance and keyword degradation.
- Heading-aware, code-fence-safe canonical memory chunking, diagnostic ranking evidence, returned-source turn traces, native bundles and sealed evaluation.
- Public operator/developer documentation, generated configuration artifacts, explicit architecture alignment, QMD deprecation and combined milestone release preparation.

### Out of Scope

- LLM query expansion, cross-encoder reranking, SQLite vector extensions, approximate-nearest-neighbor indexes, in-database fusion or additional retrieval layers.
- Vectorizing tasks, authoritative KG facts or wiki pages; inferred entity/link extraction or a graph database.
- Removing QMD this milestone, cloud embedding defaults, alternate build flavors, multi-owner administration or a new conversation browsing UI.
- Expanding chunker adoption beyond canonical memory. Conversations retain their persisted message identity and lifecycle.

### MVP Boundary

Neither corpus nor backend may be dropped to reduce scope. Optional UI or replay breadth and cloud-provider documentation polish may be omitted; the diagnostic contract, provenance, verified fallback, native packaging and held-out gate remain required.

## Functional Requirements

### User Stories

| ID | Story | Acceptance criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As an owner, I want wording-independent retrieval so that Swedish/English questions find my saved knowledge and conversations. | FR1 and FR7 pass separately for both corpora and database backends. | Must / P0 |
| US02 | As an operator, I want local embeddings and an explicit remote alternative so that I control model installation and data disclosure. | FR2, FR6 and FR8 expose activation and failures without sending data by default. | Must / P0 |
| US03 | As an owner, I want searches to reflect edits and deletion so that obsolete content is not presented as current knowledge. | FR3 and FR4 preserve current source membership, tenancy and provenance under failures. | Must / P0 |
| US04 | As an operator, I want to explain a result and inspect a turn's sources so that I can diagnose retrieval without reproducing mutable state. | FR5 retains ranked contributions on request and exact returned locators in existing traces. | Must / P1 |

### Feature Specifications

#### FR1: Hybrid Retrieval for Two Corpora

**Description**: Compose backend-native keyword retrieval with semantic retrieval and weighted reciprocal-rank fusion for memory and conversation corpora independently.

**Acceptance Criteria**:
- [ ] `search.backend: hybrid` enables both corpus instances. Each query and mutation requires the same owner scope as its lexical index; equal document identifiers in different owners or corpora cannot collide.
- [ ] Both SQLite and PostgreSQL use the same weighted RRF rule with k=60 and nonzero keyword/vector contributions. Stable document and chunk identity, rather than backend row IDs or matching text, controls fusion and deduplication.
- [ ] Ranked hits preserve canonical memory locators, roles and revisions, or persisted conversation message/session IDs, role and UTC timestamp. Top-K respects the requested corpus and owner before ranking.
- [ ] Wiki remains a live separate source and preserves the shipped wiki-over-raw ordering invariant. Authoritative KG fact search remains separate; no task search is introduced.
- [ ] Empty queries return no hits. An unavailable embedder or vector store falls back to the lexical path with visible degradation; a lexical failure follows existing source-health behavior rather than inventing results.

**Inputs / Outputs**: Query, owner, corpus and result limit → current ranked hits with their original source identity; diagnostics only when requested.
**Validation**: Reject invalid/non-finite vectors and incompatible model fingerprints; never compare different vector dimensions. Limit and scope apply to each candidate source before final top-K.
**Error Handling**: Retain keyword retrieval when embedding fails, log the failure without credentials or content leakage, and expose FR3's unembedded count.
**Priority**: Must / P0

#### FR2: Local and Opt-In HTTP Embeddings

**Description**: Generate embeddings in-process by default; allow an explicitly configured OpenAI-compatible endpoint.

**Acceptance Criteria**:
- [ ] The local default is embeddinggemma-300M Q8_0, with pinned download URL, SHA-256 and license notice. Model acquisition is an explicit operator action and honors the existing network posture. Existing verified model files work without download.
- [ ] Activating hybrid with no usable model keeps keyword search available and provides the exact recovery command. FTS-only deployments never load a model or send embedding requests.
- [ ] The HTTP alternative requires explicit endpoint/model configuration and supports local services or documented cloud opt-in. API keys use the existing credential-reference model and remain masked in configuration, errors and logs.
- [ ] Query and document embeddings use the selected model's appropriate input conventions. Returned batches preserve input order and cardinality; invalid, empty, non-finite or inconsistent-dimension responses are rejected as embedding failure.
- [ ] Model identity includes the bytes/configuration that determines embeddings and the input convention version. Changing that identity invalidates old vectors for retrieval and schedules current content for re-embedding.

**Inputs / Outputs**: Query text or ordered source chunks and explicit provider configuration → finite vectors and reproducible model identity.
**Validation**: Verify complete download bytes before publishing a model file; reject corrupted files, malformed endpoint settings, conflicting credential references and malformed remote responses.
**Error Handling**: Failed downloads preserve an existing verified model and remove only this operation's temporary artifact. Initialization/request failure becomes visible keyword degradation, never a message-write failure.
**Priority**: Must / P0

#### FR3: Incremental Projection and Recovery

**Description**: Keep vectors derived from the existing source-of-truth corpus rather than creating another content store.

**Acceptance Criteria**:
- [ ] Memory uses exactly the landed topic, archive, observation and learning membership rules. Canonical index, deletion audit and error roles are excluded; daily-log filenames do not independently confer eligibility.
- [ ] One heading-aware, code-fence-safe memory chunker feeds incremental writes and rebuild. Preserve code block content and deterministic chunk boundaries; oversized indivisible blocks remain searchable lexically with explicit embedding failure if the model cannot accept them.
- [ ] Content hashes, stable chunk identities and model fingerprints allow unchanged chunks to reuse existing vectors. `rebuild-index` does not re-embed unchanged content merely because the lexical store is republished.
- [ ] Memory updates, pruning and empty-corpus replacement retire stale vectors. Conversation append, clear, session deletion, archive and resume mirror the existing lexical lifecycle; deleting a session never requires rereading already-deleted NDJSON.
- [ ] Embedding is outside the authoritative persistence success path. Failed or delayed embedding cannot lose a message, roll back a canonical write, or leave stale vectors eligible for search.
- [ ] An operator-visible count reports current chunks without a usable vector separately for each corpus. Counts decrease after successful recovery and do not include deleted chunks.
- [ ] Rebuild from complete canonical sources matches the membership, chunk identity and provenance produced by equivalent incremental history. Empty sources clear both corpus projections. Shutdown drains or bounds pending work before closing underlying resources.

**Inputs / Outputs**: Existing canonical or conversation lifecycle events, content hashes and fingerprints → current derived vectors, retired stale identities and per-corpus unembedded counts.
**Validation**: Authenticate complete rebuild sources using existing boundaries. Prevent a late embedding result from resurrecting a removed or superseded document.
**Error Handling**: Preserve lexical availability on vector failure; incomplete source authentication refuses publication. Retrying recovery reuses matching vectors and embeds only missing/current content.
**Priority**: Must / P0

#### FR4: Backend Vector Storage and Compatibility

**Description**: Use derived vector storage suited to each existing backend without an upgrade framework.

**Acceptance Criteria**:
- [ ] SQLite stores float32 vector data and performs cosine ranking in Dart without a vector extension. PostgreSQL uses pgvector and the existing database/pool boundary.
- [ ] PostgreSQL lexical-only deployments require no vector extension. Enabling hybrid checks administrator-provisioned pgvector before any fresh authoritative bootstrap can write partial state; the runtime does not silently install the extension or require a superuser role.
- [ ] The existing backend schema authorities own required vector objects and current-schema checks. New optional derived projection setup is transactional; malformed or partially present objects are refused with actionable reset/rebuild guidance.
- [ ] Any fresh bootstrap failure rolls back all statements it owns. An existing authoritative database is not reset, migrated or modified to recover a derived vector incompatibility.
- [ ] All vector operations preserve owner and corpus isolation, atomic per-call mutations, deletion and current-fingerprint filtering. Shared contract tests exercise both implementations, including real pgvector execution.

**Inputs / Outputs**: Selected database backend, verified schema state, current vectors and owner scope → derived rows and ranked vector matches.
**Validation**: Extension availability/permissions, exact required objects, finite vectors and matching dimensions/fingerprints are checked before use.
**Error Handling**: Report missing extension or incompatible projection with the affected store and administrator/rebuild action; no secret or silent schema transformation appears in refusal paths.
**Priority**: Must / P0

#### FR5: Retrieval Diagnostics and Turn Provenance

**Description**: Explain retrieval on demand and retain the source locators actually returned by search tools.

**Acceptance Criteria**:
- [ ] An opt-in diagnostic result for either corpus includes keyword rank, vector rank, weighted contributions, fused score, source layer and degradation cause. Missing constituent ranks are explicit rather than fabricated.
- [ ] Ordinary agent search payloads retain their compact existing shape and original locators. Diagnostic output does not include embedding vectors or credentials.
- [ ] Successful search tool results retain the exact returned source locators in the existing per-tool turn-trace record, correlated by tool invocation ID. Inputs and a later requery are not accepted as returned-source evidence.
- [ ] Locator retention is bounded and deduplicated, includes no source snippets or complete raw outputs, and is backward-readable when older traces lack the field. Existing trace JSON access exposes the retained locators.
- [ ] Malformed or failed tool output cannot invent source locators or fail the turn. A corpus with no current tool call site receives the typed diagnostic contract without adding an unrelated chat workflow.

**Inputs / Outputs**: Explicit diagnostic request or completed search tool event → rank evidence or retained source locators on that invocation's trace.
**Validation**: Parse only the declared successful search-result shape; enforce deterministic bounds and preserve the returned locator values.
**Error Handling**: Unavailable constituent results carry degradation metadata; malformed trace input leaves locators empty and preserves normal accounting.
**Priority**: Must / P1

#### FR6: Native Distribution and Failure Handling

**Description**: Deliver native embeddings in the existing single binary distribution shape.

**Acceptance Criteria**:
- [ ] Pin llamadart exactly and verify native archive hashes before release builds consume them. Use a verified local archive/cache override so network-disabled builds do not fetch unverified bundles.
- [ ] Keep one binary flavor, with native libraries beside both shipped binaries as required by their build graph. Package-count/tier amendments explicitly authorize the new search package; concrete drivers remain outside it.
- [ ] Selected macOS arm64, Linux arm64, Linux x64 and Windows release legs execute actual AOT build/load/embed/dispose probes using the selected dependency/model artifacts. Existing broader release matrix obligations remain binding.
- [ ] Missing library, absent/corrupt model and initialization failure return within 60 seconds; shutdown completes within 10 seconds without leaving a stuck process. Reuse dependency-provided failure handling where it satisfies the bound; a historical bug is not permission for another worker framework.
- [ ] Linux runtime dependencies such as OpenMP are included or documented and verified in the actual package environment. Archive checksums, runtime/model identities, hardware and probe outputs are retained.

**Inputs / Outputs**: Pinned dependency/native/model artifacts and the supported release environment → runnable binary bundles and executed failure/embedding evidence.
**Validation**: Checksums precede consumption; builds and probes use the final implementation rather than the July spike.
**Error Handling**: A required platform failure blocks release acceptance and is reported by platform and failing operation; mock tests or another platform's success cannot substitute.
**Priority**: Must / P0

#### FR7: Sealed Retrieval Evaluation

**Description**: Measure the actual retrieval pipeline with frozen, privacy-safe Swedish/English judgments.

**Acceptance Criteria**:
- [ ] Use separate calibration data: the historical 24-document/16-query fixture plus frozen calibration negatives. Freeze weights, vector acceptance threshold, fingerprint and candidate limit before observing held-out scores; choose keyword/vector weights from 0.5/0.5, 0.25/0.75 or 0.1/0.9, retaining both contributions and k=60.
- [ ] The held-out fixture has at least 50 queries across exact-keyword, vocabulary-mismatch, named-entity, temporal, relational and no-result families, and reports memory/conversation and Swedish/English slices. The prepared fixture has 60 queries and SHA-256 `2635bb02da1f8dddd67e9b9f22795cc32dbee34588d642b573bdf00b8ec7b9a3`.
- [ ] Run actual SQLite FTS5 and PostgreSQL keyword retrieval, vector retrieval and hybrid retrieval. Report hit@1, recall@5, precision@5, MRR and warm-query p95 latency per backend/mode/corpus/language/family. Metrics are macro-averaged over queries within each slice; positive precision uses denominator five. MRR uses the returned top-five list (reported explicitly as MRR@5). Empty relevance sets have recall/MRR not applicable and a separate correct-empty rate.
- [ ] On each backend, hybrid strictly improves vocabulary-mismatch hit@1 and MRR over keyword-only, including separately for memory and conversations.
- [ ] For every other positive family, hybrid hit@1, recall@5, precision@5 and MRR trail the better constituent by at most 0.10 absolute over ten queries. Each five-query corpus slice has at most 0.20 absolute regression. Hit@1 therefore permits at most one fewer success per family or corpus slice.
- [ ] All ten no-result queries return no hits. Any foreign-owner or wrong-corpus result fails independently of aggregate scores. Wiki-over-raw ordering has a separate exact composition test.
- [ ] Use the same model, candidate limit, cutoff, warm-up and repetition settings for all three retrieval modes on each backend. Record hardware, artifact hashes, cold initialization, warm-up, repetitions and candidate limit. Latency is reported against the measured environment without an invented hardware-independent SLA.
- [ ] A failed held-out gate requires causal implementation remediation or an explicit product decision. It never authorizes changing judgments, tuning against held-out questions or loosening tolerances after scores are known.

**Inputs / Outputs**: Frozen documents/queries/judgments, selected settings and real backend pipelines → reproducible metric report and pass/fail evidence.
**Validation**: Fixture and settings hashes, independent calibration/held-out sets, backend-native scorers and slice completeness are checked before scoring.
**Error Handling**: Missing backend/model/platform or incomplete slices are a failed/blocked gate, not omitted rows reported as success.
**Priority**: Must / P0

#### FR8: Configuration and Operator Guidance

**Description**: Expose the supported hybrid configuration through existing validation, settings and documentation mechanisms.

**Acceptance Criteria**:
- [ ] `search.backend: hybrid` and the required `search.embedding.*` fields participate in typed parsing, equality/defaults, ConfigMeta, secret masking, generated schema/reference and the existing settings section owner. Unknown or conflicting configuration remains refused.
- [ ] An operator can obtain the verified default model, enable hybrid, inspect both corpus counts/diagnostics, rebuild, switch models, configure an explicit HTTP endpoint and recover from failure using public instructions alone.
- [ ] The search guide explicitly warns that HTTP/cloud embeddings disclose queries and indexed content outside the local trust boundary, states the operator's responsibility for the endpoint/provider, and explains that embeddings address semantic/multilingual gaps while keyword stemming and stopwords remain backend-specific.
- [ ] PostgreSQL instructions distinguish base lexical operation from administrator-provisioned pgvector, least-privilege runtime use and derived-vector recovery. Backup/store tables include any new derived storage.
- [ ] `search.backend: qmd` continues working and emits a deprecation warning; removal is scheduled for the next milestone. It is not removed or silently replaced now.
- [ ] User guide, architecture, glossary, ADR-004/050/056, current state and changelog agree with the implementation. Architecture and package-count amendments use the current tier mechanism; no retired storage package or old edge allowlist is revived.
- [ ] Final combined A+B verification and release preparation execute every obligation in `docs/specs/0.26/deferred-live-platform-proofs.json` (19 recorded commands), including named PostgreSQL security/contract and Windows filesystem proofs. They also run both binary builds, full workspace and integration tests, zero-warning analysis, formatting, architecture/fitness/config drift checks, native packaging/failure probes, the sealed retrieval evaluation, container/workflow conformance and UI smoke with screenshots. Release preparation updates version, changelog, roadmap, architecture markers and feature comparison, then consolidates the complete cycle record before pruning transient specs. The milestone record distinguishes local verification from unrun remote CI/ruleset/publication actions.

**Inputs / Outputs**: Operator configuration and actions → validated runtime behavior, generated references, visible state and current documentation.
**Validation**: Run schema/reference drift and settings ownership checks; inspect new visible configuration/status surfaces and required UI smoke screenshots.
**Error Handling**: Validation names the invalid field and recovery; documentation never implies data transfer, automatic schema migration or an automatic remote embedding fallback.
**Priority**: Must / P1

### User Flows

1. **Activate locally**: Explicit model acquisition verifies bytes → configure hybrid → startup opens compatible projections → current corpora embed → memory and conversation queries return fused source-preserving hits.
2. **Write and recover**: Persist source → lexical projection updates → stale vectors retire → available embedding populates current vectors; if unavailable, keyword search and unembedded counts remain usable → recovery embeds only the missing delta.
3. **Delete and rebuild**: Source lifecycle retires identities → neither search constituent returns them → complete-source rebuild produces the same membership and reuses unchanged vectors.
4. **Inspect a hit**: Request diagnostics → inspect constituent ranks/degradation → a normal search tool call retains its returned locators → existing trace JSON exposes those locators without requerying sources.
5. **Select PostgreSQL or HTTP**: Operator provisions pgvector or explicitly configures an endpoint/credential → validation checks prerequisites before mutation/data disclosure → supported behavior follows the same corpus contracts.

## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Isolation | Owner/corpus separation and deletion | Zero foreign-owner, wrong-corpus or retired-vector hits across contract, failure and held-out tests. |
| Reliability | Authoritative persistence independent of embeddings | All message/canonical-write failure-injection cases preserve committed source data and lexical fallback. |
| Bounded failure | Native initialization and shutdown | Initialization at most 60 seconds and shutdown at most 10 seconds, tested for missing library/model and corrupt model; no indefinitely waiting caller or process. |
| Quality | Actual held-out retrieval | FR7's predeclared thresholds pass on both backends and both corpora. |
| Performance | Incremental embedding | Unchanged content/fingerprint makes zero document embedding calls on rebuild; report actual cold/warm performance. |
| Security | Artifact/credential handling | Every consumed release/model artifact checksum verified; zero credential leakage and zero automatic cloud requests. |
| Simplicity | Existing architecture | One approved search package, injected backend ports, existing schema/trace/config authorities, no new scheduler, migration runner or search service process. |

## Edge Cases

| Scenario | Expected behavior | Recovery path |
|----------|-------------------|---------------|
| Empty memory with populated conversations | Conversations still index/search; memory stays empty. | Independent corpus rebuild. |
| Empty complete corpus | Both lexical/vector rows for that corpus are cleared. | New source writes repopulate. |
| Source changes/deletes during an embedding request | Late result cannot reintroduce old content. | Hash/current-identity check before publication. |
| Model or dimension changes | Old vectors excluded, keyword fallback and missing count visible. | Re-embed current chunks with new identity. |
| Missing pgvector or partial derived schema | Actionable refusal before partial fresh authoritative setup. | Administrator provision or derived reset/rebuild. |
| HTTP malformed batch or transient failure | No invalid vectors published; keyword retrieval retained. | Explicit recovery/rebuild under same provider settings. |
| Oversized fenced block | Preserve source/code content and lexical search; expose inability to embed if rejected. | Operator edits content or selects a capable model. |
| No-result or cross-owner query | No unrelated/foreign hits. | None; evaluated by frozen acceptance. |
| Old turn trace without locators | Decode normally with empty locator collection. | New successful search calls retain locators. |

## Constraints & Assumptions

### Constraints

- ADR-050's local default, explicit cloud opt-in, QMD deprecate-then-remove, one all-in binary and weighted RRF decisions are binding. The accepted new package must align with ADR-056's current tiers and count.
- Ports belong in dartclaw_kernel; concrete database implementations belong in dartclaw_core. The search package must not depend on drivers or cause a production core-to-search import.
- SQLite uses float32 BLOB storage and Dart cosine; PostgreSQL uses administrator-provisioned pgvector. Both are derived from the canonical corpus, with no automatic authoritative migration.
- The prepared current dependency is llamadart0.8.22 with nativev0.3.0; verified native archives and the 333590944-byte model are available for reproduction. The model SHA-256 is `b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63`.
- No private commits, push, merge to main or release publication are part of this authorized execution. Public implementation commits remain on feat/0.26.

### Assumptions

- Planning targets at most ten stories, preserving every Must acceptance criterion; optional UI/replay breadth and cloud documentation polish are the first scope reductions if needed.
- Corpus size remains the Product Summary's single-owner, megabyte-scale deployment; a direct vector scan needs no speculative index infrastructure.
- Existing conversation service APIs remain the consumption boundary until the following chat milestone. Hybrid and diagnostic contracts cover this corpus without adding a chat interface.
- HTTP model aliases can change outside the runtime; operators select a stable model identity and change it/rebuild when the remote provider changes its embedding model. No automatic provider-specific model discovery is added.

### Dependencies

| Dependency | Why it matters |
|------------|----------------|
| Accepted Phase A implementation checkpoint | Supplies both lexical corpus lifecycles and database/schema/security seams. |
| Verified native/model artifacts and release environments | Required for real AOT embedding and failure proofs. |
| Disposable PostgreSQL with pgvector | Required for actual vector and cross-backend contracts/evaluation. |
| Frozen calibration and held-out fixtures | Prevents retrospective tuning or threshold changes from becoming false acceptance. |

## Decisions Log

| Decision | Rationale | Alternatives considered |
|----------|-----------|-------------------------|
| Include both memory and conversations | Explicit owner execution instruction; both use the landed corpus seams. | Memory-only scope is not permitted. |
| Default local embeddinggemma; HTTP explicit opt-in | Accepted ADR-050 posture and historical feasibility. | Cloud default rejected; remote endpoint remains optional. |
| Weighted RRF k=60 and separate calibration | Equal weighting previously degraded a known correct result. | Pure vector and equal-weight results remain measured constituents/candidates. |
| Preserve separate wiki/KG and source mappers | Their authority, lifecycle and provenance differ from derived raw corpora. | A single global vector knowledge store is excluded. |
| Optional derived-vector bootstrap, no authoritative migration | Operators can enable hybrid without corrupting existing authoritative data or forcing pgvector on lexical-only users. | Automatic extension installation and authoritative reset are excluded. |
| Defer heavy checks to final combined A+B gate | Owner scheduling override; each story still gets focused review, tests and standard completion evidence. | Repeated broad per-story campaigns are excluded. |
