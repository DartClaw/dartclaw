# Feature Implementation Specification: Canonical Memory Model

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: Give every later memory slice one inspectable, rebuild-safe vocabulary for what memory is and how its identity survives file, archive, and derived-index changes.

**Expected Outcomes**:

- [OC01] Curated personal memory retains stable collection and entry identity, revisions, topic, timestamps, provenance, and content across deterministic Markdown parse/render cycles.
- [OC02] Index, topic, archive, observation, runtime-learning, wiki, and temporal-KG material remain explicitly role-discriminated so storage location alone never grants prompt authority.
- [OC03] Later mutation, retrieval, citation, migration, and recovery slices can consume one canonical locator and document contract without making a database authoritative.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.0` – S01 scope, risk, dependencies, provenance, and owned assets.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` – corpus, authority, locator, release-boundary, and stopped-runtime-edit contracts shared by later stories.
- `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` – canonical store roles, legacy-preservation behavior, stable identity, and file-authority acceptance contract.
- `dev/bundle/docs/specs/0.24/prd.md#data-requirements` – required fields for observations, curated entries, snapshots, locators, and derived chunks.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – single-owner/file-canonical boundary, package placement, settled trust model, and prohibition on a second persistence authority.
- `dev/bundle/docs/specs/0.24/prd.md#decisions-log` – bounded-index/topic split, model-versus-host authority, wiki/KG separation, and later-release boundaries.
- `dev/adrs/002-file-based-storage.md#decision` – canonical files and rebuildable search-index boundary; its `MEMORY.md`-only wording is intentionally broadened by the PRD to the canonical Markdown corpus.
- `dev/adrs/029-temporal-knowledge-graph-durable-knowledge-loop.md#decision` – wiki synthesis and temporal facts remain source-backed knowledge layers, not personal-memory stores.
- `dev/adrs/042-context-research-synthesis-and-citation-model.md#decision` – citations carry a role/layer plus a layer-native locator; personal-memory locators must become canonical entry IDs.

## Deeper Context

- `dev/bundle/docs/specs/0.24/memory-architecture-recommendations.md#invariants-to-preserve` – reviewed preservation constraints for files, opaque content, semantic authority, and knowledge boundaries.
- `dev/bundle/docs/specs/0.24/memory-architecture-recommendations.md#architecture-fitness-functions-and-tests` – identity, derivability, trust, citation, migration, and recovery proof expectations allocated across the plan.
- `dev/architecture/data-model.md#memory-chunk-search-index` – current derived `MemoryChunk` shape and its generic source limitation.
- `dev/architecture/data-model.md#write-safety` – current file write and shared-lock seams that S02 will reuse rather than duplicate here.

## Acceptance Scenarios

- [ ] **S01 [OC01,OC03] [TI01,TI02] A canonical active entry and collection round-trip without identity or metadata loss**
  - **Given** collection UUID `9a56ad9e-573c-45a4-901f-4fc073a20f84` at revision `7`, and active entry UUID `e907c4e7-0c55-43c0-95cd-ebf41c4f6721` at revision `3` with topic `preferences`, UTC timestamps, summary, Markdown detail, and a user-turn provenance reference
  - **When** the collection index and topic document are rendered, parsed, and rendered again
  - **Then** every semantic field is equal after parsing, the second render is byte-identical canonical Markdown, the collection and entry revisions remain distinct positive integers, and the personal-memory locator is exactly the entry UUID

- [ ] **S02 [OC01,OC03] [TI01,TI02,TI03] Active-to-archive movement preserves identity while revision state remains internally consistent**
  - **Given** two valid corpus values describing the same entry before and after an archive transition, with the entry revision advancing from `3` to `4` and the collection revision advancing from `7` to `8`
  - **When** both values pass validation and their topic/index/archive documents are round-tripped
  - **Then** the entry UUID and locator are unchanged, the later value exists only in the archive role, the active index no longer points to it, and no derived chunk or file position becomes a second identity

- [ ] **S03 [OC02,OC03] [TI01,TI02,TI03] Observation, learning, personal-memory, wiki, and KG roles cannot collapse into one authority**
  - **Given** an imperative journal observation, a curated personal preference, a runtime learning, a wiki path, and a temporal-KG fact ID
  - **When** their canonical roles, provenance references, documents, and locators are represented
  - **Then** only the curated personal entry is eligible for the prompt index, the observation remains in its observation document, runtime learning retains its existing distinct role, and wiki/KG references keep their native path/fact-ID locators without copying their sourced claim into personal topic memory

- [ ] **S04 [OC01,OC02] [TI01,TI03] Invalid or ambiguous canonical metadata fails explicitly**
  - **Given** fixtures containing, respectively, a blank or non-canonical UUID, revision `0`, missing provenance, an unsupported format version, duplicate entry IDs across active/archive documents, a dangling index pointer, and an index/detail topic or revision mismatch
  - **When** each fixture is parsed or validated
  - **Then** the exact invalid field or cross-document inconsistency is reported and no value is silently defaulted, reclassified, or partially accepted

- [ ] **S05 [OC01,OC02] [TI02,TI03] Existing opaque and fenced Markdown remains untouched by the new canonical seam**
  - **Given** a legacy `MEMORY.md` containing a hand-written preamble, fenced timestamp-shaped examples, unrecognized bullets, and one recognized entry
  - **When** existing legacy parsing or pruning runs alongside the new canonical model
  - **Then** opaque bytes remain in place, fenced examples do not become entries, and the recognized source block still maps to its exact offsets for S03 migration
  - **Proof**: `packages/dartclaw_storage/test/memory/memory_pruner_test.dart#prune() integration preserves opaque content while pruning recognized entries` – green – parity/regression

## Structural Criteria

- [ ] Canonical collection metadata, active index entries, topic details, archived entries, and observations are representable in plain Markdown; no canonical fact exists only in `search.db` or another derived store.
- [ ] `dartclaw_core` remains SQLite-free and owns the domain values, pure codec, and validation contract without importing storage or server packages.
- [ ] No new package, database, daemon, scheduler, provider abstraction, or runtime dependency is introduced.
- [ ] The current `MemoryEntry` source-offset parser contract remains available for lossless S03 migration; S01 does not silently reinterpret opaque legacy content as canonical.
- [ ] Personal-memory serialization does not write `wiki/` or temporal-KG state and does not redefine their native source identities.

## Scope & Boundaries

### Work Areas

- `packages/dartclaw_core/lib/src/memory/` – canonical role, collection, entry, observation, provenance, locator, document, codec, and corpus-validation values.
- `packages/dartclaw_core/lib/dartclaw_core.dart` – explicit public seam consumed by S02–S12.
- `packages/dartclaw_core/test/memory/` – table-driven value validation, canonical Markdown golden/round-trip cases, corpus-consistency failures, and legacy compatibility coverage.

### What We're NOT Doing

- File locking, staged writes, compare-and-swap, collection-revision advancement, and stopped-runtime edit reconciliation – S02 owns the single mutation authority.
- Legacy corpus discovery, backup, conversion, opaque-section reporting, and idempotent migration – S03 consumes this codec and the existing source-offset parser.
- `memory_observe`, `memory_read`, `memory_search`, `memory_apply`, or provider/guard mappings – S04 and S05 own tool behavior and mutation policy.
- Prompt budgeting, search-index schema/results, citation-consumer rewiring, rebuild health, pruning/resource limits, operator surfaces, and final documentation cleanup – S06–S12 own those outcomes.

## Architecture Decision

**Approach**: Add a versioned, pure canonical-memory model/Markdown codec/validator seam under `dartclaw_core/src/memory`; persist collection UUID plus positive collection revision in `MEMORY.md`, keep detailed active entries in `memory/topics/`, observations in the existing `memory/` date partitions, and archived entries in `MEMORY.archive.md`.
**Why this over alternatives**: It extends the existing file-first/parser seam with the minimum durable identity contract, leaves I/O and semantic migration to their owning stories, and avoids a new store, package, or duplicate mutation authority.

## Technical Overview

`MEMORY.md` is the versioned collection metadata and bounded active-entry index. Each index row carries canonical entry UUID, positive entry revision, topic, concise summary, update time, and a locator equal to that UUID. Detailed active entries live in topic Markdown documents; archived details retain the same UUID in `MEMORY.archive.md`. Date-partitioned observation documents use host-generated observation UUIDs and explicit origin/trust metadata but are never index entries by type alone. Runtime `learnings.md`, `wiki/`, and the temporal KG retain their native formats and identities.

The codec is pure: it converts typed documents to/from canonical LF-terminated Markdown with deterministic field and entry ordering. A corpus validator checks cross-document uniqueness and index/detail agreement. It also exposes a deterministic relative-path-to-canonical-bytes inventory so S02 can detect stopped-runtime drift and own revision advancement without S01 introducing persistence state.

## Code Patterns & External References

```
# type | path#anchor                                                                  | why needed (intent)
file   | packages/dartclaw_core/lib/src/memory/memory_entry.dart#MemoryEntry          | Preserve the legacy parsed-block/source-offset type; use a distinct canonical entry type
file   | packages/dartclaw_core/lib/src/memory/memory_entry_parser.dart#parseMemoryEntries | Reuse fence recognition and exact source spans for later lossless migration
file   | packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService | Match the current core memory ownership and bounded regular-file seam without adding I/O here
file   | packages/dartclaw_core/lib/dartclaw_core.dart                                | Explicit public export pattern for later stories
file   | packages/dartclaw_storage/lib/src/memory/memory_pruner.dart#MemoryPruner      | Preserve opaque bytes and avoid pulling current lifecycle mutation into S01
file   | packages/dartclaw_server/lib/src/mcp/citation_packet.dart#SourceRef           | Align role-discriminated locators while keeping core independent of server types
file   | packages/dartclaw_storage/lib/src/search/wiki_search_source.dart#WikiSearchSource | Preserve native wiki-path identity and synthesized-knowledge role
file   | packages/dartclaw_storage/lib/src/knowledge/temporal_knowledge_graph_service.dart#TemporalKnowledgeGraphService | Preserve source-linked KG fact identity; do not duplicate its state
```

## Constraints & Gotchas

- **Canonical wire values**: collection and entry IDs are lowercase canonical UUIDs; collection and entry revisions are separate integers starting at `1` and never decrease. S01 validates/preserves them; only S02 advances the collection revision.
- **Locator contract**: a personal-memory locator is the canonical entry UUID itself because the citation layer already carries the role; never use a derived chunk ID, `memory_save`, `archive`, or a file offset. Wiki paths and KG fact IDs remain native locators.
- **Closed roles**: the stable external role vocabulary is `index`, `topic`, `archive`, `observation`, `learning`, `wiki`, and `kg`. Provenance additionally records a closed origin kind plus a nonblank source locator and available caller/session reference; raw content does not change role by being stored.
- **Version boundary**: the canonical codec rejects unsupported canonical format versions. Legacy detection and conversion are S03 behavior, so S01 must not guess metadata for old or opaque Markdown.
- **Current-name collision**: the exported `MemoryEntry` is the legacy parser record used by `MemoryPruner`; introduce a distinct `CanonicalMemoryEntry` rather than widening that record into two incompatible meanings.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Canonical memory identities, roles, revisions, provenance, and document values have one validated core contract
  - Define the lean immutable values under `packages/dartclaw_core/lib/src/memory/`, including `CanonicalMemoryEntry`, `MemoryIndexEntry`, `MemoryObservation`, `MemoryRole`, `MemorySourceRef`, collection metadata, and personal locator derivation; reject non-canonical IDs, nonpositive revisions, unsafe/blank topics, missing provenance, and inconsistent timestamps.
  - **Verify**: Focused table-driven tests accept the complete S01 fixture and reject every S04 field failure while proving collection revision, entry revision, role, source locator, and caller/session provenance survive value construction unchanged.

- [ ] **TI02** Canonical memory documents have a deterministic, versioned Markdown representation
  - Implement a pure `MemoryMarkdownCodec` for collection/index, topic, archive, and observation documents, following `parseMemoryEntries` only for fence/source-span lessons; canonical output uses stable relative paths, field/entry order, escaping, LF endings, and final newline without performing file I/O or legacy migration.
  - **Verify**: Golden and seeded round-trip tests prove S01–S03: parse(render(value)) equals the value, render(parse(canonical Markdown)) is byte-identical, Markdown bodies containing Unicode, headings, lists, links, and fences survive, archived identity stays stable, and observations cannot appear in the active index by role alone.

- [ ] **TI03** A validated corpus exposes one unambiguous canonical identity and byte inventory to every later slice
  - Add `MemoryCorpusValidator` over decoded index/topic/archive/observation documents, export the new seam explicitly from `dartclaw_core.dart`, and keep the existing legacy `MemoryEntry`/parser surface intact for S03.
  - **Verify**: Corpus tests reject duplicate active/archive IDs, dangling index rows, topic/revision/locator mismatches, and unsupported formats; the public-barrel smoke plus current core memory parser/file and storage pruner suites remain green, including exact opaque-content/source-offset preservation, and package checks confirm no SQLite/storage/server dependency entered core.

### Testing Strategy

- [TI01,TI02,TI03] Use focused unit tests for values, codecs, and cross-document validation, with checked-in golden Markdown and a fixed-seed generated matrix covering entry order, Unicode, multiline/fenced bodies, role permutations, and active/archive placement. Add no property-testing dependency.
- [TI03] Retain the existing temp-directory parser/file/pruner suites as parity evidence; do not rewrite those tests around the canonical codec before S03 migration exists.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS mutability contract. Spec authors leave this section empty._

_No observations recorded yet._
