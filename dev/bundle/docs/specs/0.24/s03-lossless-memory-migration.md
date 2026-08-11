# Feature Implementation Specification: Lossless Memory Migration

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: Preserve the user's existing memory while moving the preview-format corpus onto the canonical 0.24
contract before any derived index can observe or publish mixed-format state.

**Expected Outcomes**:

- [OC01] Recognized legacy active memory, archive entries, and daily activity records retain their semantic text and
  acquire S01 canonical identity, revision, provenance, and role; runtime learnings retain their native bounded role.
- [OC02] Opaque or ambiguous legacy Markdown remains byte-recoverable under its original store role and is explicitly
  reported without guessed meaning, provenance, or topic.
- [OC03] Migration and current-format reconciliation are idempotent and interruption-safe, with the exact pre-migration
  state recoverable and no mixed-format canonical state exposed.
- [OC04] Startup reports migration or reconciliation outcome before FTS5 or QMD activation; failure cannot appear as a
  healthy, empty, or partially migrated memory subsystem.
- [OC05] Migration processes large legacy corpora in fixed-size parsed-record batches, publishes them through one final
  atomic corpus commit, and reports bounded diagnostics with truthful truncation counts.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories` – S03 scope, dependency order, risk, and the requirement to finish
  canonical migration before derived indexing.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` – apply the canonical-corpus, single-mutation-authority, and
  stopped-runtime-edit decisions assigned to S03.
- `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` – authoritative legacy role mapping, semantic-text and
  opaque-content preservation, idempotency, and migration error contract.
- `dev/bundle/docs/specs/0.24/prd.md#fr2-guarded-memory-tools` – all canonical changes, including migration, use one
  validation/mutation authority and existing workspace lock/atomic-write discipline.
- `dev/bundle/docs/specs/0.24/prd.md#fr3-on-demand-semantic-curation` – migration stays deterministic and does not become
  autonomous semantic curation.
- `dev/bundle/docs/specs/0.24/prd.md#fr6-maintenance-limits-and-recovery` – the 256-record in-memory migration batch,
  one-final-commit rule, 100-diagnostic/64-KiB report caps, prior-state preservation, and recovery reporting.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – no new package, database, daemon,
  scheduler, approval framework, QMD responsibility, or later-release knowledge mutation semantics.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – retain the settled host-filesystem trust model while covering
  plausible crashes, cooperating concurrency, semantic content, and ordinary limits.
- `dev/bundle/docs/specs/0.24/prd.md#user-flows` – legacy startup migration and stopped-runtime edit behavior.
- `dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md#architecture-decision` – consume S01's roles, identities,
  provenance vocabulary, locators, and deterministic Markdown codec without redefining them.
- `dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#architecture-decision` – run migration and reconciliation through
  S02's single snapshot, collection-revision, lock, validation, recovery, and canonical commit authority.
- `dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#technical-overview` – reuse the committed fingerprint,
  revision-bearing `MEMORY.md` marker, transaction recovery, stopped-edit reconciliation, and post-commit derived hook.
- `dev/adrs/002-file-based-storage.md#decision` – canonical memory remains file-authoritative and derived indexes remain
  disposable.
- `dev/architecture/data-model.md#write-safety` – existing atomic-write and shared serialization patterns migration must
  reuse rather than shadow.
- `docs/guide/workspace.md#how-the-knowledge-layer-fills` – current legacy file roles and writer behavior that fixtures
  must represent accurately.

## Deeper Context

- `dev/bundle/docs/specs/0.24/memory-architecture-recommendations.md#architecture-fitness-functions-and-tests` – use the
  migration, canonical-union, and crash-recovery matrices when expanding fixtures.
- `dev/architecture/data-model.md#backup--recovery` – current operator recovery expectations and why canonical files,
  not `search.db`, own recovery.
- `dev/state/PRODUCT.md#core-philosophy` – prefer the smallest reuse of existing corpus/startup seams; no speculative
  migration framework.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01] Recognized content enters its canonical role without semantic rewriting**
  - **Given** legacy `MEMORY.md` contains a categorized dated memory, `MEMORY.archive.md` contains a dated cold-memory
    entry, `memory/YYYY-MM-DD.md` contains a recognized daily activity record, and `learnings.md` contains a runtime learning
  - **When** the first upgraded startup runs the canonical corpus preflight
  - **Then** active memory becomes a topic detail plus bounded index entry using its existing category as topic, archive
    remains archived cold memory, daily activity becomes an observation outside the prompt index, and learning remains
    native bounded runtime self-improvement knowledge
  - **And** migrated personal-memory, archive, and observation records have S01 identity/revision/provenance metadata;
    every source retains its timestamp and semantic text
  - **Proof**: `apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart#rebuild-restores-learnings-with-live-source-and-category`
    – green – parity/regression
  - **Proof**: `packages/dartclaw_server/test/turn_runner_test.dart#daily-logs-retain-complete-human-turns-and-exclude-every-system-session-type`
    – green – parity/regression

- [ ] **S02 [OC01,OC02] [TI01] Opaque bytes survive beside migrated recognized entries**
  - **Given** each legacy source contains recognized entries adjacent to CRLF text, fenced examples, malformed headings,
    undated blocks, or other opaque valid UTF-8 Markdown
  - **When** migration classifies only content recognized by the S01 codec
  - **Then** recognized entries migrate and every opaque byte sequence remains in a clearly identified, original-role
    legacy area outside structured mutation
  - **And** the bounded report identifies each preserved source/locator and reason without copying its content or
    inventing provenance, topic, or authority
  - **Proof**: `packages/dartclaw_storage/test/memory/memory_pruner_test.dart#preserves-fenced-examples-and-crlf-while-removing-adjacent-parsed-entries`
    – green – parity/regression

- [ ] **S03 [OC03] [TI02] A completed migration is a byte-stable no-op on every rerun**
  - **Given** migration previously committed a valid canonical corpus and retained its recoverable legacy snapshot
  - **When** startup preflight runs again without external edits
  - **Then** canonical files, backup bytes, entry identities, and collection revision remain unchanged
  - **And** the report says the corpus is already current and records no newly migrated or duplicated content

- [ ] **S04 [OC03,OC04] [TI02,TI03] A supported stopped-runtime edit reconciles before indexing**
  - **Given** a user makes a supported current-format canonical Markdown edit while DartClaw is stopped
  - **When** the next startup preflight validates the corpus
  - **Then** S02 reconciles the edit and advances the collection revision exactly once without semantic rewriting
  - **And** the reconciled revision and report are available before any derived-index factory or QMD activation runs

- [ ] **S05 [OC02,OC03,OC04] [TI02,TI03] Interrupted migration exposes neither loss nor mixed canonical state**
  - **Given** fault injection terminates or fails migration during snapshot creation, staging, validation, or any
    canonical commit transition
  - **When** the operator inspects the reported recovery path or restarts DartClaw
  - **Then** S02 recovery exposes either the complete prior corpus or the complete validated migrated corpus, never a
    mixture, and the original bytes remain recoverable from the retained snapshot
  - **And** the report names the exact failing/recovered stage and safe next action while no derived index was activated
  - **Proof**: `packages/dartclaw_storage/test/memory/memory_pruner_test.dart#source-write-failure-retries-without-duplicate-archive-or-index-entries`
    – green – parity/regression

- [ ] **S06 [OC02,OC03,OC04] [TI02,TI03] Unreadable input fails closed before canonical or index mutation**
  - **Given** a legacy source is invalid UTF-8, non-regular, over the applicable S02/read ceiling, or current-format
    metadata is invalid
  - **When** startup preflight attempts validation
  - **Then** no canonical file, backup, or collection revision is partially changed and the original source remains
    recoverable
  - **And** the bounded report identifies the source, failing stage, enforced limit or validation error, and recovery
    action before startup aborts without opening FTS5, activating QMD, or starting harness/server traffic

- [ ] **S07 [OC04] [TI03] Successful startup publishes its migration report before derived indexing**
  - **Given** injectable FTS5 and QMD startup boundaries observe the workspace and captured startup messages
  - **When** storage wiring starts against a legacy or externally edited corpus
  - **Then** each boundary sees only the validated current-format corpus and reconciled collection revision
  - **And** the operator-readable migrated, reconciled, or already-current report was emitted before the first boundary
    may run

- [ ] **S08 [OC03,OC04,OC05] [TI01,TI02,TI03] Migration batches records without publishing partial corpus state or an unbounded report**
  - **Given** boundary fixtures with 256 and 257 parsed legacy records, plus diagnostics at 100 and 101 entries and
    rendered diagnostic output at 64 KiB and 64 KiB+1 byte
  - **When** canonical preflight migrates and reports each fixture
  - **Then** no in-memory parsed-record batch exceeds 256 records, every record contributes to one staged resulting
    corpus, and the completed migration performs exactly one final S02 atomic commit and one collection-revision advance
    rather than committing per batch
  - **And** the operator report contains at most 100 diagnostics and at most 64 KiB UTF-8, reports total, returned, and
    omitted diagnostic counts whenever either cap truncates it, and never includes raw memory content

## Structural Criteria

- [ ] Canonical files plus the retained pre-migration snapshot are sufficient for recovery; no migration-only content is
  authoritative solely in `search.db` or another derived store.
- [ ] Migration uses S01's codec and S02's lock/revision/commit/recovery authority; it introduces no second parser,
  workspace lock, migration ledger database, or bespoke multi-file rollback path.
- [ ] A fresh or already-current workspace with no supported external edit remains byte- and revision-stable.
- [ ] Migration holds at most 256 parsed records per in-memory batch, commits the complete resulting corpus once, and
  caps diagnostics at 100 entries and 64 KiB UTF-8 with total/returned/omitted counts.
- [ ] The story adds no package, database, daemon, scheduler, approval flow, migration config toggle, `memory_save`
  compatibility alias, or 0.25/0.27 abstraction.

## Scope & Boundaries

### Work Areas

- S01 canonical Markdown recognition and role mapping for legacy `MEMORY.md`, `MEMORY.archive.md`, `memory/` daily
  activity records, and `learnings.md`
- S02 corpus snapshot, collection revision, single final atomic commit, retained prior state, and bounded recovery reporting
- CLI storage startup sequencing before FTS5 and optional QMD activation
- Focused codec/golden fixtures and temp-workspace fault/restart/startup-order tests

### What We're NOT Doing

- Semantically curating, merging, promoting, or choosing topics for legacy/opaque content – the first explicit S09
  curation may reorganize it.
- Implementing derived-index health, reconciliation, corrupt-index replacement, or fresh-sibling rebuild – S08 owns
  those outcomes.
- Adding archive/topic/wiki/observation traversal limits, retention, or pruning policy – S10 owns those resource surfaces;
  S03 owns only the settled migration batch and report ceilings.
- Adding dashboards, status APIs, or documentation migration guidance – S11 and S12 own those broader operator and
  documentation surfaces; S03 supplies a bounded startup result they can consume.
- Implementing 0.25 database/hybrid search or 0.27 autonomous stewardship – those releases must consume this story's
  identities and semantics unchanged.

## Architecture Decision

**Approach**: Run one deterministic canonical-corpus preflight under S02's authority, using S01's codec in batches of at
most 256 parsed records to stage and validate role-preserving output plus one no-clobber recoverable legacy snapshot;
publish the complete result through one final atomic commit and bounded report before derived-index activation.
**Why this over alternatives**: It makes the format transition lossless and restart-safe while reusing the two preceding
stories instead of creating a migration framework, ledger, lock, or database.

## Technical Overview

Legacy classification is role-preserving and non-semantic: recognized `MEMORY.md` entries become active topic/index
memory using their existing category, archive stays archive, recognized daily activity becomes `MemoryObservation`,
runtime learning keeps its native format, and opaque Markdown stays attached to its source `MemoryRole`. S01's
`MemoryMarkdownCodec`, `MemoryCorpusValidator`, `CanonicalMemoryEntry`, `MemoryIndexEntry`, and `MemorySourceRef` own the
canonical shapes; S02's one corpus service owns capture, persisted fingerprint, collection revision, commit, and
recovery. Migration classifies at most 256 parsed records in memory at once, accumulates their complete staged corpus,
and performs one final S02 atomic commit rather than exposing per-batch revisions. It retains one no-clobber snapshot of
the exact pre-migration presence/bytes, then reports status, per-role counts, opaque locators, snapshot location, stage,
and next action using at most 100 diagnostics and 64 KiB UTF-8, with total/returned/omitted counts when truncated and no
memory content. `StorageWiring.wire()` must finish this
preflight and emit its result before calling the FTS5 factory or activating QMD. A preflight failure aborts startup at
that boundary; richer degraded health and repair surfaces remain S08/S11 scope.

## Code Patterns & External References

```
# type | path#anchor                                                          | why needed (intent)
file   | packages/dartclaw_core/lib/src/memory/memory_entry_parser.dart#parseMemoryEntries | Current conservative recognition, source offsets, fences, and opaque boundaries – supersede through S01, do not fork
file   | packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService.readRegularFile | Existing bounded regular-file behavior for canonical workspace input
file   | packages/dartclaw_core/lib/src/concurrency/repo_lock.dart#RepoLock.acquire | Existing normalized cooperating lock pattern; S02 remains the sole corpus authority
file   | packages/dartclaw_core/lib/src/storage/atomic_write.dart#secureWriteFile | Existing atomic file replacement primitive consumed by S02
file   | packages/dartclaw_storage/lib/src/memory/memory_pruner.dart#MemoryPruner._pruneLocked | Current opaque preservation and retry parity; do not copy its manual multi-file rollback
file   | packages/dartclaw_server/lib/src/turn_runner_memory.dart#_appendDailyLog | Current recognized daily activity record shape and available legacy provenance
file   | packages/dartclaw_server/lib/src/behavior/self_improvement_service.dart#SelfImprovementService.appendLearning | Native bounded runtime-learning format migration must retain
file   | apps/dartclaw_cli/lib/src/commands/wiring/storage_wiring.dart#StorageWiring.wire | Current FTS5-before-memory/QMD-later startup order that the preflight must gate
test   | packages/dartclaw_storage/test/memory/memory_pruner_test.dart#prune() integration | Existing CRLF/fence/opaque/failure fixture patterns
test   | apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart | Existing three-source active/archive/learning fixtures
```

## Constraints & Gotchas

- **Dependency**: Execute only after S01 and S02 are complete; consume their shipped seams and vocabulary even if their
  final symbols differ from today's parser/lock patterns.
- **Role fidelity**: A source file supplies only its canonical role and migration provenance; an explicit valid legacy
  category may carry forward as topic. Migration does not infer another topic, source-backed claim, or promotion from
  observation/learning/archive into curated active memory.
- **Duplicate fidelity**: Equal text at distinct legacy source spans remains distinct because its source identity is
  distinct; only rerunning the same migrated source is a no-op. Migration performs no semantic or text-only deduplication.
- **Byte contract**: Byte preservation applies to opaque valid UTF-8 spans and the complete retained prior snapshot.
  Invalid UTF-8 is unreadable input: preserve it untouched, report it, and fail before mutation rather than decoding
  with replacement characters.
- **Recovery**: The retained snapshot is created with no-clobber semantics and records absent source files as absent;
  reruns neither rotate nor overwrite it. An existing snapshot with a different source fingerprint fails explicitly
  instead of being reused. S02 recovery, not handwritten compensating writes, resolves interrupted commits.
- **Startup boundary**: FTS5 `search.db` and QMD are both derived memory indexes. Neither may be opened/activated before
  preflight success; `tasks.db` is unrelated authoritative task storage and gains no migration responsibility.
- **Canonical-only preflight**: Complete S02's canonical commit/recovery with its derived hook deferred; the migrator
  never constructs `MemoryService`, opens `search.db`, or activates QMD itself. Its result tells later indexing whether
  the corpus changed.
- **Settled startup behavior**: Until S08/S11 provide richer degraded operation, validation or migration failure aborts
  storage/server startup after emitting the bounded failure/recovery report. Continuing with stale derived rows is not a
  safe fallback.
- **Bounded migration**: Hold at most 256 parsed records per in-memory batch and publish the complete migration through
  one final S02 atomic commit; batching must not create intermediate canonical revisions.
- **Bounded reporting**: Return at most 100 diagnostics and 64 KiB UTF-8 with total, returned, and omitted counts when
  truncated; report role, stable locator, stage, and paths, never raw memory text.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Legacy corpus content has canonical, lossless role mapping
  - Consume S01's `MemoryMarkdownCodec`, `MemoryCorpusValidator`, closed `MemoryRole`, `MemoryObservation`,
    `CanonicalMemoryEntry`, `MemoryIndexEntry`, and `MemorySourceRef` through S02's corpus service; use current
    parser/pruner fixtures only as legacy recognition and opaque-byte parity references; process at most 256 parsed
    records per in-memory batch without publishing a batch as canonical state.
  - **Verify**: S01/S02 fixtures prove active memory → topic/index, archive → archive, daily activity → observation, native
    learning-role retention, unchanged semantic text, stable canonical metadata, source-role opaque
    preservation/reporting, 256/257-record batching, and recovery without a derived DB.

- [ ] **TI02** Migration retries and interruptions preserve one recoverable prior state
  - Use S02's commit/recovery transitions for the complete staged corpus and one no-clobber exact legacy snapshot;
    perform one final atomic corpus commit and return a migrated/already-current/reconciled/failed report capped at 100
    diagnostics and 64 KiB UTF-8 with total/returned/omitted counts.
  - **Verify**: S03–S06 fault/restart fixtures prove byte- and revision-stable reruns, no duplicate backup/identity/content,
    complete prior-or-new visibility at every injected transition, untouched unreadable/over-limit input, exactly one
    commit/revision advance for multi-batch migration, and exact 100/101-diagnostic and 64-KiB/64-KiB+1 report boundaries.

- [ ] **TI03** Storage startup exposes only a current canonical corpus to derived indexes
  - Gate `StorageWiring.wire()` at its FTS5 factory and QMD activation boundaries on TI01/TI02 preflight success; emit the
    bounded result first and abort on failure rather than continuing with stale rows.
  - **Verify**: S04/S06–S08 component tests prove supported stopped-runtime edits reconcile once, bounded success/report
    precede both index boundaries, failure invokes neither boundary nor harness/server traffic, and current/fresh
    workspaces stay stable.

- [ ] **TI04** Migration stays inside existing corpus and startup boundaries
  - Keep implementation in the S01/S02 owning packages plus existing CLI storage wiring; do not add a migration framework,
    alternate authority, config switch, new store, or later-release behavior.
  - **Verify**: architecture/package gates and the final diff show no new package, DB, daemon, scheduler, approval flow,
    compatibility alias, second lock/commit path, or migration-only authority outside canonical files and their backup.

### Testing Strategy

- **Layer 1 [TI01]**: table-driven S01 codec/migration goldens for recognized and adjacent opaque active, archive, daily
  observation, and learning content, including LF/CRLF, fences, malformed headings, undated entries, duplicates, missing
  files, repeat migration, and 256/257-record batch instrumentation.
- **Layer 2 [TI02,TI03]**: isolated temp workspaces with real S02 corpus collaborators and injected write/validation/commit
  failures, restart recovery, unreadable/boundary inputs, stopped-runtime edits, and FTS5/QMD startup sentinels. No live
  provider, network, real-time wait, or process-wide working-directory mutation is needed. Assert one final commit for
  multiple batches and report truncation independently at 100/101 diagnostics and 64 KiB/64 KiB+1 UTF-8.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS Mutability Contract.
> Spec authors: leave this section empty._

_No observations recorded yet._
