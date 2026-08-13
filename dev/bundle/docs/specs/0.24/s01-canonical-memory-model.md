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

- [x] **S01 [OC01,OC03] [TI01,TI02,TI03] A populated and an empty canonical corpus round-trip without identity or metadata loss**
  - **Given** collection ID `9a56ad9e-573c-45a4-901f-4fc073a20f84` at revision `7`, and active entry ID `e907c4e7-0c55-43c0-95cd-ebf41c4f6721` at revision `3` with topic `preferences`, UTC timestamps, summary, Markdown detail, and a user-turn provenance reference, and separately an empty corpus – the same collection metadata with an empty active index and no topic, archive, observation, or learning documents
  - **When** the collection index and topic document are rendered, parsed, and rendered again, and the empty corpus is rendered, parsed, and validated
  - **Then** every semantic field is equal after parsing, the second render is byte-identical canonical Markdown, the collection and entry revisions remain distinct positive integers, and the personal-memory locator is exactly the entry ID; the empty corpus round-trips to an equal empty value with its collection ID and revision intact and validates as consistent rather than being reported as missing or inconsistent

- [x] **S02 [OC01,OC03] [TI01,TI02,TI03] Active-to-archive movement preserves identity while revision state remains internally consistent**
  - **Given** two valid corpus values describing the same entry before and after an archive transition, with the entry revision advancing from `3` to `4` and the collection revision advancing from `7` to `8`
  - **When** both values pass validation and their topic/index/archive documents are round-tripped
  - **Then** the entry ID and locator are unchanged, the later value exists only in the archive role, the active index no longer points to it, and no derived chunk or file position becomes a second identity

- [x] **S03 [OC02,OC03] [TI01,TI02,TI03] Observation, learning, personal-memory, wiki, and KG roles cannot collapse into one authority**
  - **Given** an imperative journal observation, a curated personal preference, a runtime learning, a wiki path, and a temporal-KG fact ID
  - **When** their canonical roles, provenance references, documents, and locators are represented
  - **Then** only the curated personal entry is eligible for the prompt index, the observation remains in its observation document, the runtime learning is a canonical learning-role entry with its own stable entry ID, revision, and validation, addressed by that entry ID rather than a file-plus-heading anchor, and is never index-eligible by role, and wiki/KG references keep their native path/fact-ID locators without copying their sourced claim into personal topic memory

- [x] **S04 [OC01,OC02] [TI01,TI03] Invalid or ambiguous canonical metadata fails explicitly**
  - **Given** fixtures containing, respectively, a blank or non-canonical entry ID, revision `0`, missing provenance, an unsupported format version, an invalid topic (blank, uppercase, whitespace-bearing, and longer than 64 characters), inconsistent timestamps (a non-UTC value, `created` after `updated`, and an index row whose update time disagrees with its detail document), duplicate entry IDs across active/archive documents, a dangling index pointer, an active entry present in a topic document but absent from the active index, and an index/detail topic or revision mismatch
  - **When** each fixture is parsed or validated
  - **Then** the exact invalid field or cross-document inconsistency is reported and no value is silently defaulted, reclassified, or partially accepted

- [x] **S05 [OC01,OC02] [TI02,TI03] Existing opaque and fenced Markdown remains untouched by the new canonical seam**
  - **Given** a legacy `MEMORY.md` containing a hand-written preamble, fenced timestamp-shaped examples, unrecognized bullets, and one recognized entry
  - **When** existing legacy parsing or pruning runs alongside the new canonical model
  - **Then** opaque bytes remain in place, fenced examples do not become entries, and the recognized source block still maps to its exact offsets for S03 migration
  - **Proof**: `packages/dartclaw_storage/test/memory/memory_pruner_test.dart#prune() integration preserves opaque content while pruning recognized entries` – green – parity/regression

## Structural Criteria

- [x] Canonical collection metadata, active index entries, topic details, archived entries, observations, runtime learnings, and deletion audits are representable in plain Markdown; no canonical fact exists only in `search.db` or another derived store.
- [x] The corpus seam exposes a deterministic relative-path-to-bytes inventory with two member classes: canonical documents – index, topic, archive, observation, learning, and audit – whose inventory value is exactly that document's rendered canonical Markdown and which the validator parses, and verbatim members – preserved opaque legacy files under `memory/legacy/` – whose inventory value is exactly the preserved original bytes and which the canonical validator never parses. The same corpus value always yields the same relative paths in the same order across both classes, and S02 fingerprints their union.
- [x] `dartclaw_core` remains SQLite-free and owns the domain values, pure codec, and validation contract without importing storage or server packages.
- [x] No new package, database, daemon, scheduler, provider abstraction, or runtime dependency is introduced.
- [x] The current `MemoryEntry` source-offset parser contract remains available for lossless S03 migration; S01 does not silently reinterpret opaque legacy content as canonical.
- [x] Personal-memory serialization does not write `wiki/` or temporal-KG state and does not redefine their native source identities.

## Scope & Boundaries

### Work Areas

- `packages/dartclaw_core/lib/src/memory/` – canonical role, collection, entry, observation, learning, provenance, locator, document, codec, and corpus-validation values.
- `packages/dartclaw_core/lib/dartclaw_core.dart` – explicit public seam consumed by S02–S12.
- `packages/dartclaw_core/test/memory/` – table-driven value validation, canonical Markdown golden/round-trip cases, corpus-consistency failures, and legacy compatibility coverage.

### What We're NOT Doing

- File locking, staged writes, compare-and-swap, collection-revision advancement, and stopped-runtime edit reconciliation – S02 owns the single mutation authority.
- Legacy corpus discovery, backup, conversion, opaque-section reporting, and idempotent migration – S03 consumes this codec and the existing source-offset parser.
- `memory_observe`, `memory_read`, `memory_search`, `memory_apply`, or provider/guard mappings – S04 and S05 own tool behavior and mutation policy.
- Prompt budgeting, search-index schema/results, citation-consumer rewiring, rebuild health, pruning/resource limits, operator surfaces, and final documentation cleanup – S06–S12 own those outcomes.

## Architecture Decision

**Approach**: Add a versioned, pure canonical-memory model/Markdown codec/validator seam under `dartclaw_core/src/memory`; persist collection ID plus positive collection revision in `MEMORY.md`, keep detailed active entries in `memory/topics/`, observations in the existing `memory/` date partitions, archived entries in `MEMORY.archive.md`, deletion audits in `workspace/MEMORY.audit.md`, and runtime learnings in the existing `workspace/learnings.md` – the single canonical learning document, whose role, path, and newest-50 cap are unchanged; only its serialization becomes canonical Markdown.
**Why this over alternatives**: It extends the existing file-first/parser seam with the minimum durable identity contract, leaves I/O and semantic migration to their owning stories, and avoids a new store, package, or duplicate mutation authority.

## Technical Overview

`MEMORY.md` is the versioned collection metadata and bounded active-entry index. Each index row carries canonical entry ID, positive entry revision, topic, concise summary, update time, and a locator equal to that ID. Detailed active entries live in topic Markdown documents under `memory/topics/`, one document per topic, named verbatim by the topic slug; archived details retain the same entry ID in `MEMORY.archive.md`. Date-partitioned observation documents use host-generated observation IDs and explicit origin/trust metadata but are never index entries by type alone. Runtime learnings are a canonical role like curated, archive, and observation material: learning entries carry a stable canonical entry ID, revision, and validation, render as canonical Markdown learning documents, and appear in the canonical byte inventory S02 fingerprints. S03 converts the legacy workspace `learnings.md` content into canonical learning entries; only `wiki/` and the temporal KG retain their native formats and identities.

The codec is pure: it converts typed documents to/from canonical LF-terminated Markdown with deterministic field and entry ordering. A corpus validator checks cross-document uniqueness and index/detail agreement. It also exposes a deterministic relative-path-to-bytes inventory – codec-rendered canonical documents plus verbatim members carrying preserved opaque legacy bytes – so S02 can detect stopped-runtime drift across both classes and own revision advancement without S01 introducing persistence state.

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

- **Canonical wire values**: collection, entry, and observation IDs are lowercase canonical UUIDs – the wire form is stated here once, and every other section calls them IDs; collection and entry revisions are separate integers starting at `1` and never decrease. S01 validates/preserves them; only S02 advances the collection revision.
- **Locator contract**: a personal-memory locator is the canonical entry ID itself because the citation layer already carries the role; never use a derived chunk ID, `memory_save`, `archive`, or a file offset. A learning locator has the same shape – the stable learning entry ID within the learning role – never a file-plus-heading anchor; the earlier file-level locator recommendation is superseded along with the native-format premise it rested on. Wiki paths and KG fact IDs remain native locators.
- **Closed roles**: the stable external role vocabulary is `index`, `topic`, `archive`, `observation`, `learning`, `audit`, `wiki`, and `kg` – `audit` is the canonical deletion-audit document, a canonical document in every structural sense (codec-rendered, validated, inventory and fingerprint member) whose writes S05 commits inside the same S02 transaction as the removal they record. Provenance additionally records a closed origin kind plus a nonblank source locator and available caller/session reference; raw content does not change role by being stored.
- **Closed origin kinds**: the origin-kind vocabulary is exactly `turn`, `journal`, `inbox`, `curation`, and `migration` – one kind per 0.24 capture path. Manual stopped-runtime edits are not tool captures and carry no origin kind. The set is closed: adding a kind requires a spec change. S03 records `migration`, S04 maps `memory_observe` callers onto the remaining kinds, and S10 consumes the kind inside its dedup identity tuple.
- **Provenance absence rule**: every optional provenance component – the source-event discriminator, caller, and session reference – participates in equality only when it is PRESENT on both sides and equal; any absent component makes the two references unequal. Exact-replay dedup therefore never fires on legacy or migrated entries, and equal text alone never authorizes deletion.
- **Version boundary**: the canonical codec rejects unsupported canonical format versions. Legacy detection and conversion are S03 behavior, so S01 must not guess metadata for old or opaque Markdown.
- **Current-name collision**: the exported `MemoryEntry` is the legacy parser record used by `MemoryPruner`; introduce a distinct `CanonicalMemoryEntry` rather than widening that record into two incompatible meanings.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** Canonical memory identities, roles, revisions, provenance, and document values have one validated core contract
  - Define the lean immutable values under `packages/dartclaw_core/lib/src/memory/`, including `CanonicalMemoryEntry`, `MemoryIndexEntry`, `MemoryObservation`, `CanonicalMemoryLearning`, `MemoryRole`, `MemoryOriginKind`, `MemorySourceRef`, collection metadata, and canonical locator derivation for both personal and learning entries; reject non-canonical IDs, nonpositive revisions, invalid topics, missing provenance, and inconsistent timestamps.
  - `MemoryOriginKind` is a closed enum with exactly `turn`, `journal`, `inbox`, `curation`, and `migration`; an unknown kind is rejected rather than mapped to a fallback, and provenance for a manual stopped-runtime edit carries no origin kind.
  - A valid topic is a lowercase slug matching `[a-z0-9]+(-[a-z0-9]+)*`, at most 64 characters, used verbatim as the topic document file name; blank and non-conforming topics are rejected, never normalized on the fly – a new runtime topic longer than 64 characters is rejected, never truncated. S03 slugifies legacy categories at migration time (lowercase, whitespace runs to a single hyphen, other characters dropped, repeated hyphens collapsed, leading/trailing hyphens trimmed), truncates a resulting slug longer than 64 characters at 64 characters and trims a trailing hyphen the cut leaves behind, and merges slug collisions – including collisions truncation creates – into one topic. Truncation is a migration-only affordance and never a runtime normalization.
  - Canonical timestamps are UTC instants only; a value carrying any other zone or offset is rejected. Within an entry `created` must be less than or equal to `updated`, and an index row's update time must equal the update time on its detail document – those three conditions define the rejected inconsistent-timestamp case.
  - `MemorySourceRef` carries an optional source-event discriminator alongside the origin kind and source locator: session id plus message index for `turn`, journal entry id for `journal`, inbox item id for `inbox`, curation run id for `curation`, and absent for `migration`. Equality over optional provenance components follows the absence rule in Constraints & Gotchas.
  - **Verify**: Focused table-driven tests accept the complete S01 fixture and reject every S04 field failure while proving collection revision, entry revision, role, source locator, source-event discriminator, and caller/session provenance survive value construction unchanged, and proving two provenance references compare equal only when every optional component is present on both sides and equal.

- [x] **TI02** Canonical memory documents have a deterministic, versioned Markdown representation
  - Implement a pure `MemoryMarkdownCodec` for collection/index, topic, archive, observation, learning, and audit documents, following `parseMemoryEntries` only for fence/source-span lessons; canonical output uses stable relative paths, field/entry order, escaping, LF endings, and final newline without performing file I/O or legacy migration.
  - **Verify**: Golden and seeded round-trip tests prove S01–S03: parse(render(value)) equals the value, render(parse(canonical Markdown)) is byte-identical, Markdown bodies containing Unicode, headings, lists, links, and fences survive, an empty active index and empty topic/archive/observation/learning/audit documents round-trip to equal empty values with byte-identical output, archived identity stays stable, and observations, learnings, and audit records cannot appear in the active index by role alone.

- [x] **TI03** A validated corpus exposes one unambiguous canonical identity and byte inventory to every later slice
  - Add `MemoryCorpusValidator` over decoded index/topic/archive/observation/learning/audit documents, expose the deterministic relative-path-to-bytes inventory S02 consumes for stopped-runtime drift detection – canonical documents holding the codec's rendered Markdown plus verbatim members holding the preserved original bytes of opaque legacy files under `memory/legacy/`, which the validator never parses – export the new seam explicitly from `dartclaw_core.dart`, and keep the existing legacy `MemoryEntry`/parser surface intact for S03.
  - **Verify**: Corpus tests reject duplicate active/archive IDs, dangling index rows, an active entry present in a topic document but absent from the index, inconsistent timestamps, topic/revision/locator mismatches, and unsupported formats, and accept an empty corpus as consistent; inventory tests prove the path-to-bytes inventory exists and is deterministic – repeated calls, and an equal corpus assembled in a different insertion order, yield the identical ordered relative-path set over both member classes – and that every canonical-document inventory value is byte-equal to the codec's rendered canonical Markdown for that document while every verbatim member's value is byte-equal to its preserved original bytes and is never parsed by the validator; the public-barrel smoke plus current core memory parser/file and storage pruner suites remain green, including exact opaque-content/source-offset preservation, and package checks confirm no SQLite/storage/server dependency entered core.

### Testing Strategy

- [TI01,TI02,TI03] Use focused unit tests for values, codecs, and cross-document validation, with checked-in golden Markdown and a fixed-seed generated matrix covering entry order, empty documents and an empty corpus, Unicode, multiline/fenced bodies, role permutations, and active/archive placement. Add no property-testing dependency.
- [TI03] Retain the existing temp-directory parser/file/pruner suites as parity evidence; do not rewrite those tests around the canonical codec before S03 migration exists.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS mutability contract. Spec authors leave this section empty._

### Run: 2026-08-11 18:14 UTC – observations

#### NOTICED BUT NOT TOUCHING

- The pre-existing `dartclaw_core` LOC baseline was 16,474 against a 16,500 hard cap, leaving no feasible room for this core-owned canonical-memory contract. The required gate fix raised the ratchet to 18,000 with a 17,300 warning threshold; the final architecture gate passed at 17,372 lines.

#### DECISION NOTE: origin-kind-vocabulary
Decision-Key: origin-kind-vocabulary
Altitude: fis-local
Affected surface: ## Constraints & Gotchas (closed-roles bullet, new closed-origin-kinds bullet); ## Implementation Tasks TI01 (value list + new origin-kind bullet)
Decision: The origin-kind vocabulary is the closed set `turn`, `journal`, `inbox`, `curation`, `migration` – one kind per 0.24 capture path; manual stopped-runtime edits are not tool captures and carry no origin kind; adding a kind requires a spec change.
Rationale: Owner-ratified preflight resolution – one enumerated vocabulary lets S03 (`migration`), S04 (memory_observe caller mapping) and S10 (dedup identity tuple) share one provenance meaning instead of each inventing kinds.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), S01 item 1.

Old:
```
- **Closed roles**: the stable external role vocabulary is `index`, `topic`, `archive`, `observation`, `learning`, `wiki`, and `kg`. Provenance additionally records a closed origin kind plus a nonblank source locator and available caller/session reference; raw content does not change role by being stored.
```
New:
```
- **Closed roles**: the stable external role vocabulary is `index`, `topic`, `archive`, `observation`, `learning`, `wiki`, and `kg`. Provenance additionally records a closed origin kind plus a nonblank source locator and available caller/session reference; raw content does not change role by being stored.
- **Closed origin kinds**: the origin-kind vocabulary is exactly `turn`, `journal`, `inbox`, `curation`, and `migration` – one kind per 0.24 capture path. Manual stopped-runtime edits are not tool captures and carry no origin kind. The set is closed: adding a kind requires a spec change. S03 records `migration`, S04 maps `memory_observe` callers onto the remaining kinds, and S10 consumes the kind inside its dedup identity tuple.
```
Old:
```
  - Define the lean immutable values under `packages/dartclaw_core/lib/src/memory/`, including `CanonicalMemoryEntry`, `MemoryIndexEntry`, `MemoryObservation`, `MemoryRole`, `MemorySourceRef`, collection metadata, and personal locator derivation; reject non-canonical IDs, nonpositive revisions, unsafe/blank topics, missing provenance, and inconsistent timestamps.
```
New:
```
  - Define the lean immutable values under `packages/dartclaw_core/lib/src/memory/`, including `CanonicalMemoryEntry`, `MemoryIndexEntry`, `MemoryObservation`, `MemoryRole`, `MemoryOriginKind`, `MemorySourceRef`, collection metadata, and personal locator derivation; reject non-canonical IDs, nonpositive revisions, unsafe/blank topics, missing provenance, and inconsistent timestamps.
  - `MemoryOriginKind` is a closed enum with exactly `turn`, `journal`, `inbox`, `curation`, and `migration`; an unknown kind is rejected rather than mapped to a fallback, and provenance for a manual stopped-runtime edit carries no origin kind.
```

#### DECISION NOTE: topic-validity-contract
Decision-Key: topic-validity-contract
Altitude: fis-local
Affected surface: ## Technical Overview (`memory/topics/` sentence); ## Implementation Tasks TI01 (validation phrase + new topic-contract bullet); ## Acceptance Scenarios S04 (fixture list)
Decision: A valid topic is a lowercase slug matching `[a-z0-9]+(-[a-z0-9]+)*`, at most 64 characters, used verbatim as the topic document file name; blank and non-conforming topics are rejected, and S03 slugifies legacy categories (lowercase, whitespace runs to a single hyphen, other characters dropped, repeated hyphens collapsed, leading/trailing hyphens trimmed) with slug collisions merging into one topic.
Rationale: Owner-ratified preflight resolution – a topic is a file name, so one slug rule makes topic identity, file identity, and migration collision behavior a single decidable contract instead of three per-story guesses.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), S01 item 2.

Old:
```
Detailed active entries live in topic Markdown documents; archived details retain the same UUID in `MEMORY.archive.md`.
```
New:
```
Detailed active entries live in topic Markdown documents under `memory/topics/`, one document per topic, named verbatim by the topic slug; archived details retain the same UUID in `MEMORY.archive.md`.
```
Old:
```
reject non-canonical IDs, nonpositive revisions, unsafe/blank topics, missing provenance, and inconsistent timestamps.
```
New:
```
reject non-canonical IDs, nonpositive revisions, invalid topics, missing provenance, and inconsistent timestamps.
```
Old:
```
  - `MemoryOriginKind` is a closed enum with exactly `turn`, `journal`, `inbox`, `curation`, and `migration`; an unknown kind is rejected rather than mapped to a fallback, and provenance for a manual stopped-runtime edit carries no origin kind.
```
New:
```
  - `MemoryOriginKind` is a closed enum with exactly `turn`, `journal`, `inbox`, `curation`, and `migration`; an unknown kind is rejected rather than mapped to a fallback, and provenance for a manual stopped-runtime edit carries no origin kind.
  - A valid topic is a lowercase slug matching `[a-z0-9]+(-[a-z0-9]+)*`, at most 64 characters, used verbatim as the topic document file name; blank and non-conforming topics are rejected, never normalized on the fly. S03 slugifies legacy categories at migration time (lowercase, whitespace runs to a single hyphen, other characters dropped, repeated hyphens collapsed, leading/trailing hyphens trimmed) and merges slug collisions into one topic.
```
Old:
```
  - **Given** fixtures containing, respectively, a blank or non-canonical UUID, revision `0`, missing provenance, an unsupported format version, duplicate entry IDs across active/archive documents, a dangling index pointer, and an index/detail topic or revision mismatch
```
New:
```
  - **Given** fixtures containing, respectively, a blank or non-canonical UUID, revision `0`, missing provenance, an unsupported format version, an invalid topic (blank, uppercase, whitespace-bearing, and longer than 64 characters), duplicate entry IDs across active/archive documents, a dangling index pointer, and an index/detail topic or revision mismatch
```
#### DECISION NOTE: source-event-discriminator
Decision-Key: source-event-discriminator
Altitude: fis-local
Affected surface: ## Constraints & Gotchas (new provenance-absence-rule bullet); ## Implementation Tasks TI01 (new `MemorySourceRef` discriminator bullet + Verify)
Decision: `MemorySourceRef` gains an OPTIONAL source-event discriminator populated per capture path (`turn` – session id plus message index; `journal` – journal entry id; `inbox` – inbox item id; `curation` – curation run id; `migration` – absent), and every optional provenance component (discriminator, caller, session) participates in equality only when PRESENT on both sides and equal – any absent component makes two references unequal.
Rationale: Owner-ratified preflight resolution – a per-event discriminator makes retry idempotent for S04's inbox replay and S10's exact-replay dedup, while the presence-required equality rule keeps dedup from ever firing on legacy or migrated entries where equal text alone would otherwise authorize deletion.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), S01 item 3 (consumed by S04 item 18 and S10 item 35).

Old:
```
- **Closed origin kinds**: the origin-kind vocabulary is exactly `turn`, `journal`, `inbox`, `curation`, and `migration` – one kind per 0.24 capture path. Manual stopped-runtime edits are not tool captures and carry no origin kind. The set is closed: adding a kind requires a spec change. S03 records `migration`, S04 maps `memory_observe` callers onto the remaining kinds, and S10 consumes the kind inside its dedup identity tuple.
```
New:
```
- **Closed origin kinds**: the origin-kind vocabulary is exactly `turn`, `journal`, `inbox`, `curation`, and `migration` – one kind per 0.24 capture path. Manual stopped-runtime edits are not tool captures and carry no origin kind. The set is closed: adding a kind requires a spec change. S03 records `migration`, S04 maps `memory_observe` callers onto the remaining kinds, and S10 consumes the kind inside its dedup identity tuple.
- **Provenance absence rule**: every optional provenance component – the source-event discriminator, caller, and session reference – participates in equality only when it is PRESENT on both sides and equal; any absent component makes the two references unequal. Exact-replay dedup therefore never fires on legacy or migrated entries, and equal text alone never authorizes deletion.
```
Old:
```
  - A valid topic is a lowercase slug matching `[a-z0-9]+(-[a-z0-9]+)*`, at most 64 characters, used verbatim as the topic document file name; blank and non-conforming topics are rejected, never normalized on the fly. S03 slugifies legacy categories at migration time (lowercase, whitespace runs to a single hyphen, other characters dropped, repeated hyphens collapsed, leading/trailing hyphens trimmed) and merges slug collisions into one topic.
```
New:
```
  - A valid topic is a lowercase slug matching `[a-z0-9]+(-[a-z0-9]+)*`, at most 64 characters, used verbatim as the topic document file name; blank and non-conforming topics are rejected, never normalized on the fly. S03 slugifies legacy categories at migration time (lowercase, whitespace runs to a single hyphen, other characters dropped, repeated hyphens collapsed, leading/trailing hyphens trimmed) and merges slug collisions into one topic.
  - `MemorySourceRef` carries an optional source-event discriminator alongside the origin kind and source locator: session id plus message index for `turn`, journal entry id for `journal`, inbox item id for `inbox`, curation run id for `curation`, and absent for `migration`. Equality over optional provenance components follows the absence rule in Constraints & Gotchas.
```
Old:
```
  - **Verify**: Focused table-driven tests accept the complete S01 fixture and reject every S04 field failure while proving collection revision, entry revision, role, source locator, and caller/session provenance survive value construction unchanged.
```
New:
```
  - **Verify**: Focused table-driven tests accept the complete S01 fixture and reject every S04 field failure while proving collection revision, entry revision, role, source locator, source-event discriminator, and caller/session provenance survive value construction unchanged, and proving two provenance references compare equal only when every optional component is present on both sides and equal.
```

#### DECISION NOTE: learnings-canonical-role
Decision-Key: learnings-canonical-role
Altitude: fis-local
Affected surface: ## Technical Overview (native-format sentence); ## Structural Criteria (canonical-Markdown inventory criterion); ## Acceptance Scenarios S03 (Then clause); ### Work Areas (core value list); ## Implementation Tasks TI01 value list, TI02 codec scope + Verify, TI03 validator scope
Decision: Runtime learnings are a canonical role in this model – stable entry identity, revision, validation, canonical Markdown rendering, and participation in the canonical byte inventory, exactly like curated, archive, and observation material; the previous "learnings retain their native format and identity" premise is superseded, and S03 converts the legacy `learnings.md` content into canonical learning entries.
Rationale: Owner-ratified cross-cutting preflight resolution – a permanent dual-format special case inside the single mutation authority is the failure mode being removed; the owner chose the long-term-stable contract (directive D-B) and single-user conversion cost is acceptable (directive D-A).
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), cross-cutting learnings-canonical-role decision and S01 item 4; consumed by S02 item 8, S03 item 13, S04 item 19, S07, S11, S12.

Old:
```
Runtime `learnings.md`, `wiki/`, and the temporal KG retain their native formats and identities.
```
New:
```
Runtime learnings are a canonical role like curated, archive, and observation material: learning entries carry a stable canonical entry ID, revision, and validation, render as canonical Markdown learning documents, and appear in the canonical byte inventory S02 fingerprints. S03 converts the legacy workspace `learnings.md` content into canonical learning entries; only `wiki/` and the temporal KG retain their native formats and identities.
```
Old:
```
- [ ] Canonical collection metadata, active index entries, topic details, archived entries, and observations are representable in plain Markdown; no canonical fact exists only in `search.db` or another derived store.
```
New:
```
- [ ] Canonical collection metadata, active index entries, topic details, archived entries, observations, and runtime learnings are representable in plain Markdown; no canonical fact exists only in `search.db` or another derived store.
```
Old:
```
  - **Then** only the curated personal entry is eligible for the prompt index, the observation remains in its observation document, runtime learning retains its existing distinct role, and wiki/KG references keep their native path/fact-ID locators without copying their sourced claim into personal topic memory
```
New:
```
  - **Then** only the curated personal entry is eligible for the prompt index, the observation remains in its observation document, the runtime learning is a canonical learning-role entry with its own stable entry ID, revision, and validation and is never index-eligible by role, and wiki/KG references keep their native path/fact-ID locators without copying their sourced claim into personal topic memory
```
Old:
```
- `packages/dartclaw_core/lib/src/memory/` – canonical role, collection, entry, observation, provenance, locator, document, codec, and corpus-validation values.
```
New:
```
- `packages/dartclaw_core/lib/src/memory/` – canonical role, collection, entry, observation, learning, provenance, locator, document, codec, and corpus-validation values.
```
Old:
```
including `CanonicalMemoryEntry`, `MemoryIndexEntry`, `MemoryObservation`, `MemoryRole`, `MemoryOriginKind`, `MemorySourceRef`, collection metadata
```
New:
```
including `CanonicalMemoryEntry`, `MemoryIndexEntry`, `MemoryObservation`, `CanonicalMemoryLearning`, `MemoryRole`, `MemoryOriginKind`, `MemorySourceRef`, collection metadata
```
Old:
```
  - Implement a pure `MemoryMarkdownCodec` for collection/index, topic, archive, and observation documents, following `parseMemoryEntries` only for fence/source-span lessons; canonical output uses stable relative paths, field/entry order, escaping, LF endings, and final newline without performing file I/O or legacy migration.
```
New:
```
  - Implement a pure `MemoryMarkdownCodec` for collection/index, topic, archive, observation, and learning documents, following `parseMemoryEntries` only for fence/source-span lessons; canonical output uses stable relative paths, field/entry order, escaping, LF endings, and final newline without performing file I/O or legacy migration.
```
Old:
```
archived identity stays stable, and observations cannot appear in the active index by role alone.
```
New:
```
archived identity stays stable, and observations and learnings cannot appear in the active index by role alone.
```
Old:
```
  - Add `MemoryCorpusValidator` over decoded index/topic/archive/observation documents, export the new seam explicitly from `dartclaw_core.dart`, and keep the existing legacy `MemoryEntry`/parser surface intact for S03.
```
New:
```
  - Add `MemoryCorpusValidator` over decoded index/topic/archive/observation/learning documents, export the new seam explicitly from `dartclaw_core.dart`, and keep the existing legacy `MemoryEntry`/parser surface intact for S03.
```

#### DECISION NOTE: learning-locator-shape
Decision-Key: learning-locator-shape
Altitude: fis-local
Affected surface: ## Constraints & Gotchas (locator-contract bullet); ## Acceptance Scenarios S03 (Then clause); ## Implementation Tasks TI01 (locator derivation)
Decision: A learning result carries the ordinary canonical entry locator – the stable learning entry ID within the learning role – never a file-plus-heading anchor; the earlier file-level locator recommendation is superseded because its premise (learnings retaining a native format) no longer holds.
Rationale: Owner-ratified preflight resolution and direct consequence of the learnings-canonical-role decision – one locator shape for every canonical role keeps citation, search-to-read round-trip, and mutation addressing on a single contract.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), S01 item 5 (consequence of item 4); consumed by S04 item 19.

Old:
```
- **Locator contract**: a personal-memory locator is the canonical entry UUID itself because the citation layer already carries the role; never use a derived chunk ID, `memory_save`, `archive`, or a file offset. Wiki paths and KG fact IDs remain native locators.
```
New:
```
- **Locator contract**: a personal-memory locator is the canonical entry UUID itself because the citation layer already carries the role; never use a derived chunk ID, `memory_save`, `archive`, or a file offset. A learning locator has the same shape – the stable learning entry UUID within the learning role – never a file-plus-heading anchor; the earlier file-level locator recommendation is superseded along with the native-format premise it rested on. Wiki paths and KG fact IDs remain native locators.
```
Old:
```
the runtime learning is a canonical learning-role entry with its own stable entry ID, revision, and validation and is never index-eligible by role
```
New:
```
the runtime learning is a canonical learning-role entry with its own stable entry ID, revision, and validation, addressed by that entry ID rather than a file-plus-heading anchor, and is never index-eligible by role
```
Old:
```
collection metadata, and personal locator derivation;
```
New:
```
collection metadata, and canonical locator derivation for both personal and learning entries;
```

#### DECISION NOTE: learning-document-path
Decision-Key: learning-document-path
Altitude: fis-local
Affected surface: ## Architecture Decision (Approach enumeration – the canonical learning document clause)
Decision: The canonical learning document REMAINS at `workspace/learnings.md`; its role, path, and existing newest-50 cap are unchanged and only its serialization becomes canonical Markdown with stable entry IDs, revision, and fingerprint participation – no new path such as `memory/learnings/` is introduced.
Rationale: Owner-ratified preflight resolution – `workspace/learnings.md` is the established path in `dev/architecture/data-model.md` and `docs/guide/workspace.md`, and the PRD constrains the learning ROLE ("bounded runtime self-improvement knowledge, distinct from personal memory") and never its serialization, so relocating the file would add breakage the format change does not require.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), item 41 learning-document-path; the Approach sentence in `## Architecture Decision` already states it – "runtime learnings in the existing `workspace/learnings.md` – the single canonical learning document, whose role, path, and newest-50 cap are unchanged; only its serialization becomes canonical Markdown"; therefore this note carries zero `Old:`/`New:` pairs.

#### DECISION NOTE: topic-slug-length-overflow
Decision-Key: topic-slug-length-overflow
Altitude: fis-local
Affected surface: ## Implementation Tasks TI01 (topic-validity bullet – the runtime over-length clause)
Decision: A RUNTIME topic longer than the 64-character ceiling is rejected, never truncated or otherwise normalized; truncating an over-length slug is a migration-only affordance owned by S03, so S01's contract keeps a single accept/reject gate for topics supplied at runtime.
Rationale: Owner-ratified preflight resolution – a topic is the topic document's file name, so silently shortening one at runtime would rewrite identity under the caller; rejection keeps runtime topic identity exactly what the caller asked for, while migration (which has no live caller to reject to) is the only path allowed to normalize.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), item 42 topic-slug-length-overflow; TI01's topic bullet already states it – "a new runtime topic longer than 64 characters is rejected, never truncated" and "Truncation is a migration-only affordance and never a runtime normalization"; therefore this note carries zero `Old:`/`New:` pairs.

#### DECISION NOTE: deletion-audit-role
Decision-Key: deletion-audit-role
Altitude: fis-local
Affected surface: ## Constraints & Gotchas (closed-roles bullet); ## Architecture Decision (Approach path enumeration – deletion-audits clause); ## Structural Criteria (canonical-Markdown criterion + inventory member-class criterion); ## Implementation Tasks TI02 (codec scope + Verify), TI03 (validator scope)
Decision: S01's closed role vocabulary gains `audit`, becoming `index`, `topic`, `archive`, `observation`, `learning`, `audit`, `wiki`, and `kg`. The canonical audit document is `workspace/MEMORY.audit.md`, parallel to `MEMORY.archive.md`, and is a canonical document in every structural sense – codec-rendered, validated, inventory member, fingerprint member – whose writes advance the collection revision inside the same S02 transaction as the removal they record; it is never index-eligible by role.
Rationale: Owner-ratified preflight resolution and a direct consequence of S05's audit-as-canonical-document decision – without a role, a path, codec/validator scope, and inventory membership in S01, the only implementable form of a "canonical" deletion audit is the side file that decision forbids.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), item 43 deletion-audit-role (consequence of item 21; consumed by S02/S05/S08/S10); the named surfaces already state it – the closed-roles bullet lists `audit`, the Approach enumeration names `workspace/MEMORY.audit.md`, and the inventory criterion plus TI02/TI03 scope include the audit document; therefore this note carries zero `Old:`/`New:` pairs.

#### DECISION NOTE: verbatim-inventory-member
Decision-Key: verbatim-inventory-member
Altitude: fis-local
Affected surface: ## Structural Criteria (inventory criterion – two member classes); ## Technical Overview (inventory sentence); ## Implementation Tasks TI03 (inventory exposure + Verify byte-equality per class)
Decision: The corpus inventory has TWO member classes under one deterministic ordering – (a) canonical documents (index, topic, archive, observation, learning, audit) whose inventory value is byte-equal to the codec's rendered canonical Markdown and which the validator parses, and (b) verbatim members (preserved opaque legacy files under `memory/legacy/`) whose inventory value is byte-equal to the PRESERVED ORIGINAL bytes and which the canonical validator never parses. Fingerprint membership is the union of (a) and (b), and TI03's Verify asserts the correct byte-equality per class rather than codec-render equality for every member.
Rationale: Owner-ratified preflight resolution and a direct consequence of S03's ratified opaque-content placement – preserved legacy bytes can never equal a codec render, so a single-class inventory criterion made "outside the validator, inside the fingerprint" structurally impossible and left stopped-runtime edits to preserved legacy content undetectable as drift.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), item 44 verbatim-inventory-member (consequence of item 9 opaque-content-placement; consumed by S02/S03); the inventory Structural Criterion, the Technical Overview inventory sentence, and TI03's scope and Verify already state both classes and the per-class byte-equality; therefore this note carries zero `Old:`/`New:` pairs.

### Run: 2026-08-11 18:25 UTC – observations

#### NOTICED BUT NOT TOUCHING

- Quick-review remediation added the missing public contracts and moved the warning threshold to 17,600, preserving useful headroom below the 18,000 hard cap. The final architecture gate passed at 17,457 lines.
