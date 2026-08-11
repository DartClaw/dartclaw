# Product Requirements Document: DartClaw 0.24 Memory Model

> **Source Trust**: trusted-local
> **Context**: `dev/state/PRODUCT.md`, `dev/state/ROADMAP.md`, and the decision to reopen the untagged 0.24 milestone for the complete memory model.
> **Related Assets**: `memory-architecture-recommendations.md`; ADR-002, ADR-007, ADR-029, ADR-033, ADR-042, ADR-045, ADR-050; `dev/architecture/data-model.md`; `dev/architecture/system-architecture.md`; `dev/architecture/observability-operations-architecture.md`.

## Executive Summary

- **Problem**: DartClaw presents `MEMORY.md` as curated durable memory, but the only write tool appends. Its model-driven consolidator therefore cannot replace or shrink memory, prompt loading is physically truncated rather than semantically bounded, and several retrieval/recovery paths violate their documented contracts.
- **Vision**: A Claude Code/AndThen-inspired memory system in which the model decides what matters and how memories relate, while DartClaw deterministically enforces identity, provenance, bounds, concurrency, persistence, indexing, and recovery.
- **Target Users**: The single user operating a personal DartClaw instance, plus operators and contributors maintaining that instance.
- **Success Metrics**: No append-only consolidation path; stable and resolvable memory identities; bounded next-turn context; atomic conflict-safe curation; visible and recoverable index degradation; every architecture-review recommendation resolved or explicitly deferred.

### Capabilities at a Glance

- **FR1: Coherent Memory Corpus** _(Must / P0)_ – Establish explicit roles for observations, the bounded memory index, topic memory, archive, learnings, wiki, and temporal facts.
- **FR2: Guarded Memory Tools** _(Must / P0)_ – Replace append-only `memory_save` with observe, search, read, and atomic apply capabilities.
- **FR3: On-Demand Semantic Curation** _(Must / P0)_ – Let a model reason over a bounded snapshot and commit a conflict-safe structured change set.
- **FR4: Bounded Turn Context** _(Must / P0)_ – Give primary turns a current bounded index while retrieving detailed topics only on demand.
- **FR5: Retrieval, Citation, and Index Integrity** _(Must / P0)_ – Make query handling, stable locators, index health, and live/rebuilt results coherent.
- **FR6: Maintenance, Limits, and Recovery** _(Must / P0)_ – Make pruning, bounds, configuration, and corrupt-index recovery safe and explicit.
- **FR7: Operator Control and Observability** _(Should / P1)_ – Make memory state, degradation, curation, limits, and repair understandable through existing surfaces.
- **FR8: Simplification and Release Boundaries** _(Must / P0)_ – Remove broken/unused memory machinery and preserve the 0.25/0.27 responsibilities.
- **FR9: Architecture Governance and Documentation** _(Must / P0)_ – Keep code, tests, ADRs, architecture references, and user guidance aligned.

### Scope Highlights

- **In scope**: complete 0.24 memory semantics, safe migration, guarded mutation, on-demand curation, prompt context, retrieval/index integrity, recovery, bounds, observability, simplification, and documentation.
- **Out of scope**: PostgreSQL, embeddings/hybrid search, new QMD work, multi-user product behavior, hostile filesystem races, and autonomous idle-time stewardship.
- **MVP boundary**: DartClaw can remember during normal turns and explicitly curate that memory without silent overwrite, unbounded prompt loading, false index health, or an append-only pseudo-consolidator.

### Key Constraints, Assumptions & Dependencies

- *Constraint:* Canonical memory remains inspectable Markdown; search/vector structures remain derived and rebuildable.
- *Constraint:* The host OS/runtime user/filesystem is trusted. Semantic content remains untrusted data, including content written by users, models, tools, journals, and imports.
- *Dependency:* 0.25 must preserve 0.24 memory identities and corpus semantics across storage/search backends; it must not redefine them.
- *Assumption:* Breaking preview-format and tool changes are acceptable, but migration may not silently discard unknown user-authored content.

## Problem Definition

### Problem Statement

The current subsystem conflates chronological capture, curated memory, prompt context, synthesized knowledge, and derived search. `memory_save` can only append, yet the scheduled `MemoryConsolidator` asks a model to save a cleaned replacement. Once the threshold is crossed, it can repeatedly launch turns that cannot shrink the source and may overlap. At the same time, full-file prompt reads, generic citation sources, caller-owned FTS escaping, concealed index failures, incomplete corruption recovery, and inconsistent resource limits make the system less reliable than its public documentation claims.

If unchanged, 0.25 would migrate, index, and embed an unstable memory abstraction. That would increase migration complexity while preserving the underlying semantic and recovery defects.

### Evidence & Context

- `MemoryConsolidator` requests replacement-style deduplication while `memory_save` appends only; existing tests prove dispatch, not consolidation outcome or overlap safety.
- Prompt assembly reads and encodes the whole `MEMORY.md` before applying a physical-tail budget even though category order is not recency order.
- ADR-042 requires a memory-entry locator; current search rows expose generic `memory_save` or `archive` sources.
- Natural-language query treatment differs by caller, causing FTS punctuation failures and distorting QMD input.
- Canonical saves can succeed while index insertion fails, yet the response and status surfaces appear healthy.
- The documented corrupt-index recovery command opens the target database in place rather than building a fresh replacement.
- Archive, wiki traversal, aggregate observations, and negative memory configuration values have incomplete ordinary-resource handling.
- Dead vector/identity surfaces and duplicate wiki composition add maintenance cost without product value.
- The project is early experimental, 0.24 is not tagged, and correctness may take precedence over compatibility.

## Scope

### In Scope

- A canonical taxonomy and routing rules for durable observations, curated memory, topic detail, archive, runtime learnings, source-backed wiki knowledge, and temporal facts.
- Stable canonical IDs, per-entry revisions, timestamps, topics, provenance references, and a collection/snapshot revision.
- `memory_observe`, `memory_search`, `memory_read`, and `memory_apply`; removal of `memory_save` as an ambiguous duplicate.
- Model-authored add, revise, merge, and remove decisions committed through one atomic host validation path.
- Ordinary-turn automatic remembering and explicit on-demand curation.
- A bounded `MEMORY.md` index available to primary human-facing turns, with detailed topic pages retrieved on demand.
- Safe deterministic migration of recognized and opaque existing memory content.
- Search query ownership, stable citation locators, one wiki-composition owner, saved-but-index-degraded state, index reconciliation, and fresh-file rebuild.
- Deterministic exact deduplication, archival compatibility, input/configuration validation, and per-file/recursive/aggregate processing bounds.
- Policy and audit classification for the renamed memory tools, without weakening documented provider-interception limits.
- Existing Memory/Knowledge/status/CLI/API/job surfaces updated only as needed for visibility and explicit curation.
- Removal of broken, obsolete, duplicated, or prematurely generalized memory code.
- Architecture fitness functions, fault-injection tests, ADR/architecture updates, and user documentation.

### Out of Scope

- PostgreSQL or `DatabaseBackend` implementation, language-aware FTS, embeddings, vector storage, RRF, or hybrid-search packaging.
- New QMD semantics, lifecycle complexity, or hardening beyond compatibility during its deprecation window.
- Autonomous scheduled or idle-time curation, curation policy tuning, approval workflows, or OKF interoperability.
- General caller-aware MCP dispatch, provider cancellation, or unrelated guard matrices; the renamed memory tools' existing policy/audit treatment and minimum provenance remain in scope.
- Multi-user UX, shared-instance authorization, active-active processing, or tenant administration. Existing `userId` scoping remains intact for future compatibility.
- Native descriptor-bound I/O or defenses against a hostile runtime user/pathname/inode swap.
- Automatic deletion of raw observations. User-initiated deletion remains possible; destructive default retention waits for an accepted policy.

### MVP Boundary

The smallest acceptable 0.24 release has no automatic append-only consolidator; canonical memory has stable identities and bounded prompt/index roles; models can safely add and curate through a compare-and-swap mutation contract; all search/citation/index/recovery contracts are truthful; existing content migrates without silent loss; and the full review-finding matrix is verified.

## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As a user, I want DartClaw to remember useful context during ordinary turns, so that later conversations do not require repeated explanation. | A primary turn can create a curated entry through the guarded contract and the entry is available to the next primary turn. | Must / P0 |
| US02 | As a user, I want concise always-available memory with details on demand, so that persistence does not consume an unbounded prompt budget. | The prompt contains only the bounded index; relevant topic detail is retrievable by ID/topic. | Must / P0 |
| US03 | As a user, I want explicit semantic curation, so that duplicate, stale, or conflicting memory can be revised without losing concurrent changes. | A curation run may add/revise/merge/remove; a stale snapshot is rejected atomically. | Must / P0 |
| US04 | As a user, I want personal memory separated from sourced knowledge, so that an observation is not mistaken for a verified fact. | Memory, wiki, and KG results retain distinct roles and provenance labels. | Must / P0 |
| US05 | As an operator, I want truthful memory and index health, so that a durable save is never confused with searchable success. | Degraded indexing is visible with a repair path and clears only after reconciliation. | Must / P0 |
| US06 | As an operator, I want deterministic recovery and limits, so that ordinary corruption or growth does not destroy canonical memory. | Deleted/corrupt indexes rebuild safely; boundary violations do not partially mutate canonical state. | Must / P0 |
| US07 | As a contributor, I want one lean memory contract, so that 0.25 can change storage/search technology without redefining memory behavior. | Review findings are mapped, dead/duplicate surfaces are removed, and 0.25 consumes stable identities/semantics. | Must / P0 |

### Feature Specifications

#### FR1: Coherent Memory Corpus

**Description**: Define one user-understandable role and routing rule for each memory and knowledge store.

**Acceptance Criteria**:
- [ ] `MEMORY.md` is a bounded prompt index, not an append-only chronological authority.
- [ ] Detailed curated personal/experiential memory lives in canonical topic pages reachable from the index.
- [ ] Existing dated activity records are provenance-labelled observations and are not prompt-authoritative by storage location alone.
- [ ] `MEMORY.archive.md` remains searchable cold memory with an explicit relationship to active entries and migration.
- [ ] `learnings.md` remains bounded runtime self-improvement knowledge, distinct from personal memory.
- [ ] `wiki/` remains source-backed synthesized knowledge and the temporal KG remains the source-linked time-aware fact store; sourced facts are not duplicated into personal topic memory as a second authority.
- [ ] Recognized legacy entries receive stable identity without changing their semantic text; opaque legacy content is preserved and reported rather than dropped.
- [ ] Canonical identity survives index deletion/rebuild and is preserved by both 0.25 derived-search implementations; canonical memory remains file-based and outside ADR-045's `DatabaseBackend`.

**Inputs / Outputs**:
- **Inputs**: Existing workspace memory files, topic/user context, observations, imported/source-backed knowledge.
- **Outputs**: Bounded index, curated topic entries, archive, preserved legacy content, stable routing/provenance.

**Validation**:
- No canonical content may exist only in a derived database.
- Migration must be idempotent and preserve unknown content byte-for-byte or in a clearly identified preserved legacy section.
- A source-backed claim routes to wiki/KG; a user preference or experiential context routes to personal memory.

**Error Handling**:
- Migration failure leaves the pre-migration canonical files recoverable and reports the exact failing stage.
- Ambiguous legacy content is preserved without inventing provenance or semantic categorization.

**Priority**: Must / P0

#### FR2: Guarded Memory Tools

**Description**: Give models a small coherent tool surface for observation, retrieval, and conflict-safe mutation.

**Acceptance Criteria**:
- [ ] `memory_observe` appends bounded provenance-labelled content under a closed observation or learning role; observations are not injected as authoritative instructions, learnings retain the existing bounded self-improvement role rather than becoming personal topic memory, and a successful write advances the shared collection revision.
- [ ] `memory_search` returns bounded role-discriminated matches with provenance and a resolvable locator; personal-memory matches also carry canonical entry ID and revision, while wiki matches retain native source identity rather than fabricated memory-entry metadata.
- [ ] `memory_read` supports bounded reads by stable entry ID and topic/store scope without requiring a whole-file read.
- [ ] `memory_apply` accepts an expected collection revision and an atomic structured change set whose only operation kinds are add, revise, merge, and remove; archive and re-topic changes are revisions, not additional operation kinds.
- [ ] All operations use one validation/mutation authority and the existing shared workspace lock and atomic-write discipline.
- [ ] Every successful canonical write advances the same collection revision; read/conflict results expose the current revision needed for compare-and-swap.
- [ ] `memory_save` is removed from the model-facing contract rather than retained as a duplicate alias.
- [ ] Every production caller, prompt, recipe, provider mapping, and allowlist using `memory_save` is migrated: observation producers use `memory_observe`, curated personal-memory producers use `memory_apply`, and learning producers use `memory_observe`'s bounded learning role without routing learnings into personal topic memory.
- [ ] `memory_observe` and `memory_apply` retain persistent-memory write policy/audit treatment wherever provider interception exists; `memory_search` and `memory_read` remain read-only, renamed tools never fall through to generic MCP identity, and documented provider limits remain truthful.
- [ ] Invalid IDs, stale revisions, malformed per-operation fields, missing provenance, and size violations fail before any canonical or index mutation.
- [ ] A remove operation removes active content and derived-index rows; audit metadata may retain identity/time/reason but not deleted content.

**Inputs / Outputs**:
- **Inputs**: Structured observations, queries, IDs/topics, expected revision, structured change set, minimal caller/source context.
- **Outputs**: Observation acknowledgement, bounded results, current revisions, committed change summary, or typed failure/degradation state.

**Validation**:
- Operation-specific fields form a closed contract; unknown operations or conflicting fields are rejected.
- IDs and revisions are host-generated/validated; models never choose collision-sensitive identity.
- Existing `userId` scope remains applied to every search and mutation.

**Error Handling**:
- A stale expected revision returns a conflict with the current revision and no partial effect.
- An index failure after canonical commit returns saved-but-index-degraded rather than generic success or rollback of the canonical truth.

**Priority**: Must / P0

#### FR3: On-Demand Semantic Curation

**Description**: Preserve model reasoning for importance, synthesis, conflict resolution, and organization while making the commit deterministic.

**Acceptance Criteria**:
- [ ] An explicit curation action snapshots a bounded index, relevant topic entries, and bounded observations with a collection revision.
- [ ] The model returns only a structured proposal; it does not directly rewrite files or claim success before host commit.
- [ ] The proposal may add, revise (including archive or re-topic changes), merge, or remove entries and must reference its source observations/entries.
- [ ] The host validates and atomically applies the proposal through the same mutation service used by `memory_apply`.
- [ ] A concurrent valid memory write causes the stale curation proposal to fail without partial effects.
- [ ] Curation reports either changed and exact-no-op IDs after a wholly valid atomic commit, or proposal rejection with per-operation reasons and no changed IDs; invalid operations are never skipped into a partial commit.
- [ ] The existing threshold-triggered `MemoryConsolidator` and all automatic dispatch wiring are removed or disabled.
- [ ] No autonomous background curation is introduced in 0.24; explicit execution registers one host callback as a system action on the existing run-now surface. Its descriptor is read-only through scheduling configuration surfaces, and it is excluded from timers, automatic retries, and YAML mutation while sharing overlap protection and list/show visibility.
- [ ] Registered system-action IDs are reserved; a configured YAML job whose ID collides with any system action is rejected before scheduling starts or list/show/run publishes an ambiguous identity.

**Inputs / Outputs**:
- **Inputs**: Explicit curation request, bounded snapshot, provenance-labelled candidate observations/entries.
- **Outputs**: Structured proposal, committed change summary, or conflict/validation failure.

**Validation**:
- The model decides semantic equivalence and importance; deterministic code performs only structural/exact validation, identity, concurrency, bounds, and persistence.
- A curation run may not invoke itself or recursively dispatch another curation turn.

**Error Handling**:
- Model timeout/malformed proposal changes nothing and remains safely retryable.
- Stale snapshot or failed canonical write changes nothing; post-commit index failure is reported as degraded.

**Priority**: Must / P0

#### FR4: Bounded Turn Context

**Description**: Make memory useful on every primary human-facing turn without bulk-loading the corpus or trusting physical file order.

**Acceptance Criteria**:
- [ ] The effective context of each primary human-facing turn contains the memory index state current at turn start.
- [ ] The bounded index supplied to each primary turn includes the current collection revision required by `memory_apply`.
- [ ] The default loaded representation is capped at both 150 rendered lines and `memory.max_bytes` (default 32 KiB), whichever is reached first.
- [ ] Topic detail, archive, observations, learnings, wiki, and KG are not bulk-injected; they are retrieved through their appropriate tools/context layer.
- [ ] Index selection uses semantic index entries and explicit priority/recency metadata, never a physical head/tail slice of a fully read file.
- [ ] Loading does not read or UTF-8 encode an oversized whole canonical file before applying the budget.
- [ ] Prompt memory is delimited and described as potentially stale/untrusted contextual data, not executable instructions; the existing safety/instruction precedence remains intact.
- [ ] Primary-turn freshness and restart behavior are truthful and tested for every supported prompt strategy/provider.

**Inputs / Outputs**:
- **Inputs**: Current bounded index snapshot and primary-turn prompt scope/provider.
- **Outputs**: Effective prompt context plus on-demand retrieval hints that preserve stable IDs.

**Validation**:
- Newer/high-priority entries in an early topic remain eligible when older trailing entries exist.
- Ordinary subagents/background workers do not silently inherit personal prompt memory unless their documented scope requires it.

**Error Handling**:
- Unreadable/malformed index content produces an explicit degraded prompt-memory state while preserving safe base instructions.

**Priority**: Must / P0

#### FR5: Retrieval, Citation, and Index Integrity

**Description**: Make search and citation behavior consistent across MCP, Knowledge Hub, Context Research, current backends, and rebuilds.

**Acceptance Criteria**:
- [ ] Search callers pass plain natural language; each backend exclusively owns its query encoding/escaping.
- [ ] Punctuation, quotes, operators, and empty/whitespace queries have one documented outcome through MCP, Hub, Context Research, and fallback paths.
- [ ] Every result exposes a stable unique source locator that resolves to its canonical source; personal-memory locators resolve to canonical entries, wiki locators retain native source identity, and generic `memory_save` or `archive` locators are invalid.
- [ ] Wiki synthesis continues to rank above raw personal memory for the same topic and retains its provenance label, as required by ADR-029.
- [ ] Wiki composition has one owner per search request; Context Research does not trigger a duplicate recursive scan.
- [ ] Canonical commit success and derived-index success are separate observable outcomes.
- [ ] Live mutation, pruning, migration, and full rebuild use one normalization/chunking/identity contract and converge on equivalent indexed rows.
- [ ] Status/count failures are never converted into healthy zero values.
- [ ] Search remains derived and rebuildable, `userId` scoped, and compatible with ADR-045 set-membership parity.

**Inputs / Outputs**:
- **Inputs**: Natural-language query, user scope, canonical memory/wiki sources, mutation/rebuild events.
- **Outputs**: Bounded ranked results, resolvable citations, degraded-layer metadata, index-health state.

**Validation**:
- Same-category/same-text entries with different identities remain distinguishable where both legitimately exist.
- Locator resolution proves identity/existence; synthesis still carries citations and never treats locator existence as semantic proof.

**Error Handling**:
- A failing retrieval layer appears in `degradedLayers` or equivalent operator status rather than disappearing silently.
- Reconciliation clears degraded state only after validating the complete canonical union.

**Priority**: Must / P0

#### FR6: Maintenance, Limits, and Recovery

**Description**: Bound ordinary resource use and make canonical/index maintenance crash-safe and recoverable.

**Acceptance Criteria**:
- [ ] Exact normalized deduplication compares store role/topic, content, and provenance/source-event identity; equal text with different provenance or event identity remains distinct, and semantic deduplication remains model curation.
- [ ] Archive writes are rejected before exceeding the canonical readable ceiling and never leave half-applied active/archive/index state.
- [ ] A canonical Markdown source is accepted through 64 MiB inclusive; an operation that would create or read 64 MiB plus one byte is rejected with no partial canonical mutation.
- [ ] A dated observation partition is accepted through 8 MiB inclusive; a limit-plus-one append is rejected instead of trimming prior observations. Recursive traversal processes at most 1,000 regular files and 64 MiB aggregate per request, and search returns the best 50 results after ranking every admitted candidate, with explicit degradation signals when a processing ceiling is reached.
- [ ] Migration processes at most 256 parsed records per in-memory batch while preserving one final atomic corpus commit; its operator report contains at most 100 diagnostics and 64 KiB UTF-8, with total and omitted counts when truncated.
- [ ] Raw observations are not automatically deleted or hard-capped in aggregate in 0.24; aggregate disk use, oldest/newest coverage, and a warning at or above 64 MiB are visible, and user-initiated deletion is documented.
- [ ] `memory.max_bytes` and archive-age configuration reject zero, negative, or out-of-range values through every load/write path. Fixed file, partition, traversal, result, and warning safety ceilings remain non-configurable constants and have exact-limit/limit-plus-one tests.
- [ ] Rebuild creates and validates a fresh sibling index, then atomically replaces the target; corrupt target bytes are not opened as a prerequisite.
- [ ] Failure before replacement preserves the previous target and canonical files; orphaned temporary files are safely recognizable/recoverable.
- [ ] Deleted-index startup does not settle into a silently empty healthy index when canonical sources contain data.
- [ ] Cooperating runtime maintenance and mutation paths share one lock/revision authority and do not overlap incompatible phases.

**Inputs / Outputs**:
- **Inputs**: Prune/rebuild/migration requests, canonical sources, configuration limits, injected I/O/index failures.
- **Outputs**: Reconciled canonical/index state, explicit degradation/limit status, safe prior state on failure.

**Validation**:
- Boundary and limit-plus-one tests prove no partial canonical mutation.
- Fault injection targets write, index, validation, and pre-swap transitions rather than merely throwing before work begins.

**Error Handling**:
- Limit, corruption, or reconciliation failures identify the affected store and the safe next action.

**Priority**: Must / P0

#### FR7: Operator Control and Observability

**Description**: Make memory understandable and repairable without requiring database inspection.

**Acceptance Criteria**:
- [ ] Existing status/Memory/Knowledge surfaces distinguish curated entries, topics, archive, observations, learnings, wiki sources, and derived chunks.
- [ ] Surfaces show collection revision, prompt-index budget usage, aggregate observation usage/coverage, last successful curation/reconciliation, and current index health.
- [ ] Explicit curation is available through the existing on-demand job/operator execution path with clear running/succeeded/conflicted/failed outcomes.
- [ ] A saved-but-index-degraded response names the durable outcome and repair action.
- [ ] Users can inspect and manually edit/delete canonical Markdown, including raw observations, while the runtime is stopped; on restart, supported edits are validated and collection-revision/index reconciliation completes or reports degraded before health is reported.
- [ ] Recovery guidance covers migration backup, deleted/corrupt index rebuild, legacy opaque content, and failed curation.

**Inputs / Outputs**:
- **Inputs**: Memory/corpus status, curation/rebuild lifecycle, operator requests.
- **Outputs**: Accurate CLI/API/Web/status information and actionable recovery guidance.

**Validation**:
- Empty corpus, degraded index, and zero-result search remain distinguishable states.

**Error Handling**:
- Status collection failure reports unknown/degraded, never fabricated zero counts.

**Priority**: Should / P1

#### FR8: Simplification and Release Boundaries

**Description**: Remove current memory architecture that is broken, duplicated, obsolete, or belongs to later milestones.

**Acceptance Criteria**:
- [ ] Remove `MemoryConsolidator`, its prompts, threshold dispatch wiring, overlap risk, and tests that only assert dispatch.
- [ ] Remove obsolete `searchVector`, legacy `MemoryChunk`, and unused identity helpers unless an accepted 0.25 contract has a concrete production consumer.
- [ ] Remove duplicate wiki-search composition and retain one tested owner.
- [ ] Do not add a new package, database, daemon, scheduler, approval framework, or speculative provider abstraction for this work.
- [ ] QMD receives no new memory semantics and follows ADR-050 deprecation/removal timing.
- [ ] 0.25 owns database abstraction, PostgreSQL, multilingual FTS, embeddings, hybrid/vector indexing, and QMD deprecation at Phase B GA; QMD implementation removal remains one milestone later per ADR-050.
- [ ] 0.27 owns autonomous scheduling/policy, governed idle-time stewardship, richer approval workflows, validation/dogfooding loops beyond 0.24 contract tests, and OKF interoperability.
- [ ] 0.27 retains guarded wiki/KG knowledge-write policy and semantics; 0.24 memory mutation tools do not write wiki/KG or broaden their existing write contracts.

**Inputs / Outputs**:
- **Inputs**: Current production-reference inventory, accepted ADR seams, roadmap boundary.
- **Outputs**: Smaller public/runtime surface with explicit later-milestone handoffs.

**Validation**:
- Repository scans and analyzer/barrel tests find no orphaned public exports or dead wiring introduced by removal.

**Error Handling**:
- If a supposedly obsolete API has a real consumer, retain it only with documented contract evidence and adjust the plan before implementation.

**Priority**: Must / P0

#### FR9: Architecture Governance and Documentation

**Description**: Make the new memory model durable through executable invariants and code-backed documentation.

**Acceptance Criteria**:
- [ ] Add contract/fault tests for mutation CAS, prompt bounds/freshness, query ownership, locator resolution, index convergence/degradation, resource ceilings, and corrupt-index recovery.
- [ ] Add narrow fitness checks where a cheap structural invariant prevents regression, including no generic locator, no caller-side FTS encoding, no automatic consolidator, and no unconsumed exported memory API.
- [ ] Record the memory corpus, identity, provenance, mutation, prompt-context, and 0.25/0.27 boundaries in a new or amended accepted ADR; amend ADR-002's `MEMORY.md`-only source wording for the bounded index plus topic corpus.
- [ ] Amend ADR-042 for stable memory-entry locators and reconcile ADR-007 status/content with actual provider prompt behavior.
- [ ] Preserve ADR-029 wiki-over-memory ranking, ADR-045's file-canonical/database-index boundary, and ADR-050's 0.25 Phase B deprecation plus one-milestone-later removal timing in code-backed acceptance tests and documentation.
- [ ] Update data-model, system, security/semantic-trust, observability/operations, package AGENTS, configuration, workspace, search, CLI/API, and recovery documentation in the same changes as behavior.
- [ ] All architecture-review findings below map to an implemented acceptance test or an explicit later-release boundary.

**Inputs / Outputs**:
- **Inputs**: Accepted requirements, implementation, existing ADRs/docs/tests.
- **Outputs**: Enforced invariants and synchronized contributor/user references.

**Validation**:
- Documentation claims are verified against code and recovery tests, not copied from prior prose.

**Error Handling**:
- A binding decision not settled by this PRD blocks its implementation story rather than being guessed during execution.

**Priority**: Must / P0

### User Flows

1. **Automatic remembering**: A primary turn receives the current collection revision with its bounded index → identifies useful durable context → calls `memory_apply` with an add/revise operation and that revision → host validates/commits/reconciles → next primary turn receives the updated bounded index.
2. **Observation capture**: A journal or ordinary turn calls `memory_observe` → host stores bounded content with provenance → observation remains outside prompt-authoritative memory until a curated operation references it.
3. **Explicit curation**: Operator runs the existing on-demand curation action → host snapshots bounded candidates → model proposes structured changes → host commits through CAS → operator sees changed IDs and index state.
4. **Conflict**: Another canonical mutation lands during curation → commit rejects stale revision → no partial write → operator may rerun from a fresh snapshot.
5. **Retrieval**: Agent searches natural language → backend owns encoding → result includes stable locator/provenance → agent reads the relevant entry/topic → Context Research preserves the locator in its citation packet.
6. **Index failure and recovery**: Canonical change commits but indexing fails → response/status report degraded → rebuild creates/validates fresh sibling → atomic swap → health clears.
7. **Legacy migration**: Operator starts upgraded DartClaw → compatible content migrates deterministically with backup → opaque content remains preserved/reported → first explicit curation may semantically reorganize it.
8. **Stopped-runtime edit**: User edits supported canonical Markdown while DartClaw is stopped → startup validates the corpus and reconciles the collection revision and derived index before reporting healthy → invalid content remains recoverable and reports degraded rather than being overwritten.

### Data Requirements

- **Observation**: host-generated ID, recorded time, origin/caller/session reference when available, content, truncation markers, trust/provenance label, and optional references to resulting curated entries.
- **Curated memory entry**: stable host-generated ID, revision, topic, concise index representation, detailed content/reference, created/updated times, provenance/source references, active/archive state.
- **Memory snapshot/change set**: collection revision, bounded included IDs/revisions, structured operations, reason, and source references; the commit is all-or-nothing.
- **Memory locator**: stable source identity that resolves independently of a derived chunk row ID or database rebuild.
- **Index health**: healthy/degraded/rebuilding/unknown state, last successful reconciliation, failure summary, and canonical/index coverage information.
- **Deletion audit**: entry ID, time, actor/source, and reason only; deleted content is not retained in the audit record.
- **Derived Memory Chunk**: backend-owned indexed snippet carrying stable canonical entry identity, user scope, topic/source role, timestamp, and ranking fields; never authoritative by itself.

## Architecture Review Coverage

| Review item | PRD disposition |
|-------------|-----------------|
| Append-only model consolidator cannot consolidate and may overlap | Fix in FR3; remove in FR8. |
| Generic memory locators violate ADR-042 | Fix in FR1/FR5; preserve through 0.25 in FR8/FR9. |
| Caller/backend query encoding is inconsistent | Fix in FR5; fitness check in FR9. |
| Corrupt index cannot follow documented rebuild path | Fix in FR6. |
| Journal/tool content can become authoritative prompt content | Fix in FR1/FR2/FR4. |
| Canonical save hides index failure; status fabricates zero | Fix in FR2/FR5/FR7. |
| Archive/wiki/recursive/aggregate processing is incompletely bounded | Fix processing in FR6; destructive retention deferred explicitly. |
| Negative memory configuration values are accepted | Fix in FR6. |
| Prompt loading reads whole file and truncates physical tail | Fix in FR4. |
| Wiki is scanned twice in Context Research | Remove in FR5/FR8. |
| Dead vector/chunk/identity public surface | Remove or prove consumer in FR8. |
| Canonical/index live and rebuilt states can drift | Fix in FR5/FR6. |
| Renamed memory mutation tools could lose existing policy/audit classification | Preserve the write boundary in FR2 and documentation/fitness coverage in FR9. |
| Corpus roles, provenance, prompt policy, save semantics, retention, and revision authority were undecided | Settled in FR1–FR7 and Decisions Log. |
| QMD should not shape the future architecture | Explicit 0.25 Phase B deprecation and later removal boundary in FR8. |
| Autonomous steward policy was planned for 0.27 | On-demand foundation pulled into 0.24; autonomy/policy remains 0.27 in FR3/FR8. |

## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Reliability | Canonical mutation is serialized, revision-checked, atomic, and independently reconciled to the derived index. | Zero partial canonical change under injected write/index/swap failures. |
| Crash consistency | Existing canonical files/index remain usable until a complete replacement validates. | Every failure point before atomic rename/swap preserves the prior target. |
| Prompt efficiency | Primary turns receive only the bounded index. | Default ≤150 rendered lines and ≤32 KiB; no whole-corpus pre-read. |
| Retrieval efficiency | Recursive/file retrieval is bounded and duplicate composition removed. | One wiki composition per request; explicit file/count/byte/result ceilings. |
| Disk safety | Canonical writes cannot create unreadable files; raw aggregate growth is visible. | Per-store hard readable ceilings; aggregate usage/coverage reported. |
| Index integrity | Canonical and derived state divergence is detectable and repairable. | No healthy/zero status on failure; rebuild convergence proven. |
| Security | Treat content as untrusted semantic data while retaining the settled host-trust threat model. | No journal/observation instruction gains authority without curated mutation; no hostile-path hardening scope. |
| Compatibility | Existing memory upgrades without silent user-content loss. | Idempotent migration plus preserved/reported opaque content. |
| Portability | Behavior and tests work on supported macOS, Linux, and Windows paths. | Workspace CI-equivalent gates and portable filesystem/fault tests pass. |
| Simplicity | Reuse current locks, atomic writes, services, and surfaces. | No new runtime package, DB, daemon, scheduler, or compatibility alias. |

## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|----------|-------------------|---------------|
| Concurrent ordinary mutation and curation commit | One valid commit wins; stale revision rejects the other without partial effects. | Re-read current revision and resubmit/recurate. |
| Same semantic claim with different wording | Host preserves both unless model curation proposes a merge. | Explicit curation; no heuristic semantic deletion. |
| Same normalized content, store/topic, and provenance/source event is replayed | Deterministic exact deduplication prevents replay of the same record; equal text from a distinct provenance/event remains separate. | Report no-op with existing ID for the replayed record. |
| Opaque legacy Markdown | Preserved outside structured mutation until explicitly rewritten. | Inspect reported legacy section and curate manually/on demand. |
| Topic/index exceeds prompt budget | Deterministic priority/recency selection fits budget; full detail remains retrievable. | Curate or inspect the omitted/overflow status. |
| Individual canonical file at limit | Reject limit-plus-one operation before mutation. | Curate/archive or adjust an approved limit. |
| Aggregate raw observations grow indefinitely | Continue bounded per-operation access and show disk/coverage warning; do not auto-delete. | User deletes/backs up manually; 0.27 decides automated retention. |
| FTS punctuation/operator query | Backend treats it as natural-language content and returns results/empty result, not syntax failure. | None required. |
| QMD unavailable during deprecation window | Existing documented fallback remains; no new QMD semantics. | Use FTS5 and visible degradation as currently supported. |
| Index corrupt | Rebuild ignores target contents, creates fresh validated sibling, atomically replaces target. | Rerun after source/resource repair if fresh build fails. |
| Index deleted while canonical data exists | Startup/status reports missing/degraded and rebuilds or directs repair; never healthy empty. | Run documented reconciliation/rebuild. |
| Canonical Markdown changed while runtime was stopped | Startup validates supported edits, advances/reconciles collection identity, and repairs the derived index before reporting healthy. | Correct invalid Markdown from backup or run the documented reconciliation path. |
| Model curation emits malformed or unsupported operation | Reject entire proposal and preserve state. | Retry explicit curation or inspect model output summary. |
| User requests forgetting | Remove active canonical content and index rows; content-free audit remains. | Restore only from user backup if deletion was intentional. |

## Constraints & Assumptions

### Constraints

- DartClaw remains a single-user, single-deployment, single-isolate personal assistant runtime.
- Canonical personal memory is plain Markdown; derived indexes may be deleted and rebuilt.
- `dartclaw_core` remains SQLite-free; storage implementations remain outside it; MCP/operator orchestration remains server/CLI-owned.
- Existing shared workspace serialization and atomic-write primitives are the mutation authority; do not create a competing lock/queue.
- Host OS/runtime user/filesystem are trusted. Plausible crashes, cooperating concurrency, untrusted model/tool content, and normal resource limits are in scope.
- No new runtime Node/npm dependency, daemon, database, or package.
- 0.25 ADR-045/050 backend and hybrid-search contracts remain valid, must consume the newly settled 0.24 identity/corpus, and must not move canonical memory behind `DatabaseBackend`.
- QMD is transitional and receives no new architectural responsibility.

### Assumptions

- The user accepts a breaking tool and on-disk preview-format transition in exchange for a coherent contract.
- A model can reliably propose a bounded structured change set when given stable IDs/revisions and explicit schema; malformed output is expected and safely rejected.
- The existing on-demand scheduled-job/operator surface can expose explicit curation without a new scheduler or autonomous policy.
- Retaining raw observations by default is acceptable for 0.24 when aggregate usage and trust boundaries are visible.
- Primary-turn effective context can be made current across supported providers; provider-specific delivery is an implementation decision that must not weaken the user-visible freshness requirement.

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| Existing memory/parser/pruner/index services and workspace lock | Reuse is required to avoid a second mutation authority. |
| Prompt-strategy/harness behavior | Must deliver a current bounded index truthfully across providers. |
| Existing MCP registry and execution coordinator | Tools and explicit curation must use standard capability and capacity paths. |
| Memory/Knowledge status and dashboard surfaces | Existing operator entry points should expose health and curation with minimal UI expansion. |
| ADR-029/042 knowledge and citation contracts | Preserve wiki/KG distinction, ranking provenance, and citation packet semantics. |
| ADR-045/050 planned seams | Stable IDs/user scope/index semantics must transfer into 0.25's derived search implementations without moving canonical memory into the database abstraction or requiring a second migration of meaning. |

## Decisions Log

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| Reopen 0.24 for Memory Model v2 | The release is untagged; correcting semantics before 0.25 avoids indexing/migrating the wrong abstraction. | Critical patch only; dedicated intervening milestone; defer to 0.27. |
| Keep canonical Markdown and derived indexes | Preserves ADR-002's file-first/derived-index boundary; ADR-002's `MEMORY.md`-only wording must be amended for the bounded index plus topic corpus. | Make SQLite/PostgreSQL authoritative; add another store. |
| Use bounded index plus on-demand topic detail | Persistent context stays useful without loading the whole corpus. | Retrieval only; chronological tail; full-file prompt injection. |
| Keep personal topic memory separate from wiki/KG | Personal experience and source-backed claims have different provenance/authority. | Reuse wiki for all topics; one mixed memory corpus. |
| Let models judge semantics and hosts enforce integrity | Importance, synthesis, conflict, and organization require reasoning; identity/concurrency/persistence do not. | Fully deterministic curation; unrestricted model file writes. |
| Replace `memory_save` with observe/search/read/apply | Separates evidence from curated state and supports atomic multi-entry change without tool sprawl. | Append-only save; separate add/update/delete/merge tools; compatibility alias. |
| Allow guarded ordinary-turn auto-memory | Matches desired auto-memory behavior while retaining deterministic validation. | User approval per mutation; journal/scheduled-only writes. |
| Make curation explicit/on-demand in 0.24 | Proves mutation and recovery before adding policy/scheduling. | Threshold heartbeat consolidation; fully autonomous steward now. |
| Do not auto-delete raw observations in 0.24 | Avoid irreversible loss before retention and stewardship are validated. | Fixed age; post-curation grace period. |
| Pull stable identity/provenance and guarded writes from 0.27 into 0.24 | They are prerequisites for a sound corpus and for 0.25 indexing. | Temporary locators now and persisted IDs later. |
| Keep autonomous stewardship/OKF in 0.27 | Those require policy, governance, validation, and interop beyond the foundational memory contract. | Pull the complete 0.27 knowledge milestone forward. |
| Respect settled host trust | Native descriptor-bound hostile-path defenses add disproportionate complexity. | Descriptor-relative native I/O and hostile pathname defenses. |
