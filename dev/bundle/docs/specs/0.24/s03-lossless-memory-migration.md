# Feature Implementation Specification: Lossless Memory Migration

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: Preserve the user's existing memory while moving the preview-format corpus onto the canonical 0.24
contract before any derived index can observe or publish mixed-format state.

**Expected Outcomes**:

- [OC01] Recognized legacy active memory, archive entries, daily activity records, and runtime learnings retain their
  semantic text and acquire S01 canonical identity, revision, role, and provenance whose origin kind is `migration`.
- [OC02] Opaque or ambiguous legacy Markdown is preserved byte-for-byte in a sibling `memory/legacy/<source>.md` file
  that canonical validation never parses and the corpus fingerprint always covers, and is explicitly reported without
  guessed meaning, provenance, or topic.
- [OC03] Migration and current-format reconciliation are idempotent and interruption-safe, with the exact pre-migration
  state recoverable and no mixed-format canonical state exposed.
- [OC04] Startup reports migration or reconciliation outcome before FTS5 or QMD activation; failure cannot appear as a
  healthy, empty, or partially migrated memory subsystem.
- [OC05] Migration processes large legacy corpora in fixed-size parsed-record batches, publishes them through one final
  atomic corpus commit, and reports bounded diagnostics with truthful truncation counts.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.2` – S03 scope, dependency order, risk, and the requirement to finish
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

- [x] **S01 [OC01] [TI01] Recognized content enters its canonical role without semantic rewriting**
  - **Given** legacy `MEMORY.md` contains a categorized dated memory, `MEMORY.archive.md` contains a dated cold-memory
    entry, `memory/YYYY-MM-DD.md` contains a recognized daily activity record, and `learnings.md` contains a runtime learning
  - **When** the first upgraded startup runs the canonical corpus preflight
  - **Then** active memory becomes a topic detail plus bounded index entry under its slugified category topic, archive
    remains archived cold memory, daily activity becomes an observation outside the prompt index, and the runtime
    learning becomes a canonical learning-role entry with a host-assigned identity
  - **And** migrated personal-memory, archive, observation, and learning records have S01 identity/revision/provenance
    metadata whose origin kind is `migration`;
    every source retains its semantic text, and naive `[YYYY-MM-DD HH:MM]` stamps are read as host-local time and
    stored as UTC
  - **Proof**: `apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart#rebuild restores learnings with live source and category`
    – green – parity/regression for the pre-migration legacy `learnings.md` recognition this migration must read. It cannot
    hold after migration, where learnings are a canonical role, so the post-migration learning-role outcome is new behavior
    proved by TI01's fixtures
  - **Proof**: `packages/dartclaw_server/test/turn_runner_test.dart#daily logs retain complete human turns and exclude every system session type`
    – green – parity/regression

- [x] **S02 [OC01,OC02] [TI01] Opaque bytes survive beside migrated recognized entries**
  - **Given** each legacy source contains recognized entries adjacent to CRLF text, fenced examples, malformed headings,
    undated blocks, or other opaque valid UTF-8 Markdown
  - **When** migration classifies only content the retained legacy parser contract recognizes and that is representable
    in S01's canonical model
  - **Then** recognized entries migrate and every opaque byte sequence is copied verbatim into
    `memory/legacy/<source>.md`, named for the legacy source it came from and never structurally mutated
  - **And** `memory/legacy/` is excluded from S01 canonical validation but included in the S02 corpus fingerprint, so a
    later external edit to a preserved file is detected as drift
  - **And** the bounded report identifies each preserved source/locator and reason without copying its content or
    inventing provenance, topic, or authority
  - **Proof**: `packages/dartclaw_storage/test/memory/memory_pruner_test.dart#preserves fenced examples and CRLF while removing adjacent parsed entries`
    – green – parity/regression

- [x] **S03 [OC03] [TI02] A completed migration is a byte-stable no-op on every rerun**
  - **Given** migration previously committed a valid canonical corpus and retained its recoverable legacy snapshot
  - **When** startup preflight runs again without external edits
  - **Then** canonical files, backup bytes, entry identities, and collection revision remain unchanged
  - **And** the report says the corpus is already current and records no newly migrated or duplicated content
  - **And** when the retained snapshot's recorded source fingerprint no longer matches the current sources, the preflight
    halts with the workspace unchanged and reports the snapshot path plus the instruction to inspect and delete it
    before retrying, never restoring, rotating, or archiving it automatically

- [x] **S04 [OC03,OC04] [TI02,TI03] A supported stopped-runtime edit reconciles before indexing**
  - **Given** a user makes a supported current-format canonical Markdown edit while DartClaw is stopped
  - **When** the next startup preflight validates the corpus
  - **Then** S02 reconciles the edit and advances the collection revision exactly once without semantic rewriting
  - **And** the reconciled revision and report are available before any derived-index factory or QMD activation runs

- [x] **S05 [OC02,OC03,OC04] [TI02,TI03] Interrupted migration exposes neither loss nor mixed canonical state**
  - **Given** fault injection terminates or fails migration during snapshot creation, staging, validation, or any
    canonical commit transition
  - **When** the operator inspects the reported recovery path or restarts DartClaw
  - **Then** S02 recovery exposes either the complete prior corpus or the complete validated migrated corpus, never a
    mixture, and the original bytes remain recoverable from the retained snapshot
  - **And** the report names the exact failing/recovered stage and safe next action while no derived index was activated
  - **Proof**: `packages/dartclaw_storage/test/memory/memory_pruner_test.dart#source write failure retries without duplicate archive or index entries`
    – green – parity/regression

- [x] **S06 [OC02,OC03,OC04] [TI02,TI03] Unreadable input fails closed before canonical or index mutation**
  - **Given** a legacy source is invalid UTF-8, non-regular, over the applicable S02/read ceiling, or current-format
    metadata is invalid
  - **When** startup preflight attempts validation
  - **Then** no canonical file, backup, or collection revision is partially changed and the original source remains
    recoverable
  - **And** the bounded report identifies the source, failing stage, enforced limit or validation error, and recovery
    action before startup aborts without opening FTS5, activating QMD, or starting harness/server traffic

- [x] **S07 [OC04] [TI03] Successful startup publishes its migration report before derived indexing**
  - **Given** injectable FTS5 and QMD startup boundaries observe the workspace and captured startup messages
  - **When** storage wiring starts against a legacy or externally edited corpus
  - **Then** each boundary sees only the validated current-format corpus and reconciled collection revision
  - **And** the operator-readable migrated, reconciled, or already-current report was emitted before the first boundary
    may run

- [x] **S08 [OC03,OC04,OC05] [TI01,TI02,TI03] Migration batches records without publishing partial corpus state or an unbounded report**
  - **Given** boundary fixtures with 256 and 257 parsed legacy records, plus diagnostics at 100 and 101 entries and
    rendered diagnostic output at 64 KiB and 64 KiB+1 byte
  - **When** canonical preflight migrates and reports each fixture
  - **Then** no in-memory parsed-record batch exceeds 256 records, every record contributes to one staged resulting
    corpus, and the completed migration performs exactly one final S02 atomic commit and one collection-revision advance
    rather than committing per batch
  - **And** the operator report contains at most 100 diagnostics and at most 64 KiB UTF-8, reports total, returned, and
    omitted diagnostic counts whenever either cap truncates it, and never includes raw memory content

## Structural Criteria

- [x] Canonical files plus the retained pre-migration snapshot are sufficient for recovery; no migration-only content is
  authoritative solely in `search.db` or another derived store.
- [x] Migration uses S01's codec and S02's lock/revision/commit/recovery authority; it introduces no second parser,
  workspace lock, migration ledger database, or bespoke multi-file rollback path.
- [x] A workspace with an existing corpus and no supported external edit remains byte- and revision-stable across
  preflight reruns; minting the canonical skeleton for a workspace that has none is S02's bootstrap, not S03's.
- [x] Migration holds at most 256 parsed records per in-memory batch, commits the complete resulting corpus once, and
  caps diagnostics at 100 entries and 64 KiB UTF-8 with total/returned/omitted counts.
- [x] The story adds no package, database, daemon, scheduler, approval flow, migration config toggle, `memory_save`
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
- Bootstrapping a workspace that has no legacy sources and no canonical corpus – S02's authority mints the collection
  and commits the initial canonical state; S03 runs only where a corpus already exists.
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
stories instead of creating a migration framework, ledger, lock, or database. Migration stays proportionate –
preserve-and-report only, with no reconciliation machinery beyond what the settled decisions require – because a
single-owner workspace makes an explicit manual retry an acceptable outcome.

## Technical Overview

Legacy classification is role-preserving and non-semantic: recognized `MEMORY.md` entries become active topic/index
memory whose topic is their legacy category run through S01's topic-slug rule – parser-defaulted `general` entries land
on topic `general` – archive stays archive, recognized daily activity becomes `MemoryObservation`,
runtime learning becomes canonical learning-role entries, and opaque Markdown is copied verbatim into a sibling
`memory/legacy/<source>.md` file that canonical validation never parses and the corpus fingerprint always covers. S01's
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
file   | packages/dartclaw_server/lib/src/behavior/self_improvement_service.dart#SelfImprovementService.appendLearning | Legacy runtime-learning format migration must parse and convert into canonical learning-role entries
file   | apps/dartclaw_cli/lib/src/commands/wiring/storage_wiring.dart#StorageWiring.wire | Current FTS5-before-memory/QMD-later startup order that the preflight must gate
test   | packages/dartclaw_storage/test/memory/memory_pruner_test.dart#prune() integration | Existing CRLF/fence/opaque/failure fixture patterns
test   | apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart | Existing three-source active/archive/learning fixtures
```

## Constraints & Gotchas

- **Dependency**: Execute only after S01 and S02 are complete; consume their shipped seams and vocabulary even if their
  final symbols differ from today's parser/lock patterns.
- **Role fidelity**: A source file supplies only its canonical role and migration provenance; a legacy category carries
  forward as its slugified S01 topic. Migration does not infer another topic, source-backed claim, or promotion from
  observation/learning/archive into curated active memory.
- **Duplicate fidelity**: Equal text at distinct legacy source spans remains distinct because its source identity is
  distinct; only rerunning the same migrated source is a no-op. Migration performs no semantic or text-only deduplication.
- **Timestamp normalization**: naive `[YYYY-MM-DD HH:MM]` legacy stamps carry no zone; migration interprets them as
  host-local time and converts them to the UTC instants S01 requires. Reading the wall-clock digits as UTC is wrong and
  would shift every legacy timestamp by the host offset.
- **Byte contract**: Opaque valid UTF-8 spans are copied verbatim into `memory/legacy/<source>.md`, named for the legacy
  source they came from and never structurally mutated; the complete retained prior snapshot is byte-preserved too.
  `memory/legacy/` sits outside S01 validation but inside the S02 corpus fingerprint, so an external edit to a preserved
  file surfaces as drift. Invalid UTF-8 is unreadable input: preserve it untouched, report it, and fail before mutation
  rather than decoding with replacement characters.
- **Recovery**: The retained snapshot is created with no-clobber semantics and records absent source files as absent;
  reruns neither rotate nor overwrite it. An existing snapshot whose recorded source fingerprint differs from the
  current sources halts the preflight, changes nothing, and reports the snapshot path plus the instruction to inspect
  and delete it before retrying – never an automatic restore, rotation, or archive. S02 recovery, not handwritten
  compensating writes, resolves interrupted commits.
- **Startup boundary**: FTS5 `search.db` and QMD are both derived memory indexes. Neither may be opened/activated before
  preflight success; `tasks.db` is unrelated authoritative task storage and gains no migration responsibility.
- **Canonical-only preflight**: Complete S02's canonical commit/recovery with its derived hook deferred; the migrator
  never constructs `MemoryService`, opens `search.db`, or activates QMD itself. Its result tells later indexing whether
  the corpus changed.
- **Settled startup behavior**: A canonical-corpus validation or migration failure aborts storage/server startup after
  emitting the bounded failure/recovery report. Continuing with stale derived rows is not a safe fallback. S08's
  boot-degraded behavior applies to derived-index faults only – an unreadable or unmigrated canonical corpus still aborts,
  and no later story relaxes that. On success the preflight only emits its changed/unchanged result and takes no
  derived-index action of its own; reconciling the index against that result is S08's, per this story's Non-Goals.
- **Bounded migration**: Hold at most 256 parsed records per in-memory batch and publish the complete migration through
  one final S02 atomic commit; batching must not create intermediate canonical revisions.
- **Bounded reporting**: Return at most 100 diagnostics and 64 KiB UTF-8 with total, returned, and omitted counts when
  truncated; report role, stable locator, stage, and paths, never raw memory text.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** Legacy corpus content has canonical, lossless role mapping
  - Consume S01's `MemoryMarkdownCodec`, `MemoryCorpusValidator`, closed `MemoryRole`, `MemoryObservation`,
    `CanonicalMemoryEntry`, `CanonicalMemoryLearning`, `MemoryIndexEntry`, and `MemorySourceRef` through S02's corpus
    service; use current parser/pruner fixtures only as legacy recognition and opaque-byte parity references; process at
    most 256 parsed records per in-memory batch without publishing a batch as canonical state.
  - Derive each entry topic from its legacy category with S01's topic-slug rule (lowercase, whitespace runs → one
    hyphen, other characters dropped, repeated hyphens collapsed, leading/trailing hyphens trimmed); colliding slugs
    merge into one topic, entries the legacy parser defaulted to category `general` land on topic `general`, and the
    report states how many entries took that default.
  - Truncate a slugified legacy category longer than S01's 64-character topic ceiling at 64 characters and trim any
    resulting trailing hyphen; a truncation that lands on an existing slug merges like any other slug collision.
    Truncation is a migration-only affordance – S01's runtime topic contract rejects an over-length topic rather than
    normalizing it.
  - **Verify**: S01/S02 fixtures prove active memory → topic/index, archive → archive, daily activity → observation,
    `learnings.md` converted to canonical learning-role entries with origin kind `migration`, unchanged semantic text,
    stable canonical metadata, byte-identical opaque preservation in `memory/legacy/<source>.md` that S01 validation
    ignores and the corpus fingerprint covers, per-source opaque reporting, 256/257-record batching, and recovery
    without a derived DB.

- [x] **TI02** Migration retries and interruptions preserve one recoverable prior state
  - Use S02's commit/recovery transitions for the complete staged corpus and one no-clobber exact legacy snapshot;
    perform one final atomic corpus commit and return a migrated/already-current/reconciled/failed report capped at 100
    diagnostics and 64 KiB UTF-8 with total/returned/omitted counts.
  - On a retained snapshot whose recorded source fingerprint no longer matches the current sources, halt before any
    staging or commit, mutate nothing, and report the snapshot path with the inspect-and-delete retry instruction
    instead of restoring, rotating, or archiving it.
  - **Verify**: S03–S06 fault/restart fixtures prove byte- and revision-stable reruns, no duplicate backup/identity/content,
    complete prior-or-new visibility at every injected transition, untouched unreadable/over-limit input, exactly one
    commit/revision advance for multi-batch migration, a fingerprint-mismatched snapshot halting with an unchanged
    workspace and an inspect-and-delete instruction, and exact 100/101-diagnostic and 64-KiB/64-KiB+1 report boundaries.

- [x] **TI03** Storage startup exposes only a current canonical corpus to derived indexes
  - Gate `StorageWiring.wire()` at its FTS5 factory and QMD activation boundaries on TI01/TI02 preflight success; emit the
    bounded result first and abort on failure rather than continuing with stale rows.
  - **Verify**: S04/S06–S08 component tests prove supported stopped-runtime edits reconcile once, bounded success/report
    precede both index boundaries, failure invokes neither boundary nor harness/server traffic, and an already-current
    workspace with an existing corpus stays byte- and revision-stable.

- [x] **TI04** Migration stays inside existing corpus and startup boundaries
  - Keep implementation in the S01/S02 owning packages plus existing CLI storage wiring; do not add a migration framework,
    alternate authority, config switch, new store, or later-release behavior.
  - **Verify**: architecture/package gates and the final diff show no new package, DB, daemon, scheduler, approval flow,
    compatibility alias, second lock/commit path, or migration-only authority outside canonical files and their backup.

### Testing Strategy

- **Layer 1 [TI01]**: table-driven S01 codec/migration goldens for recognized and adjacent opaque active, archive, daily
  observation, and learning content, including LF/CRLF, fences, malformed headings, undated entries, duplicates, missing
  files, repeat migration, naive host-local `[YYYY-MM-DD HH:MM]` stamps converted to UTC under a fixed test zone, and
  256/257-record batch instrumentation.
- **Layer 2 [TI02,TI03]**: isolated temp workspaces with real S02 corpus collaborators and injected write/validation/commit
  failures, restart recovery, unreadable/boundary inputs, stopped-runtime edits, and FTS5/QMD startup sentinels. No live
  provider, network, real-time wait, or process-wide working-directory mutation is needed. Assert one final commit for
  multiple batches and report truncation independently at 100/101 diagnostics and 64 KiB/64 KiB+1 UTF-8.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS Mutability Contract.
> Spec authors: leave this section empty._

#### DECISION NOTE: opaque-content-placement
Decision-Key: opaque-content-placement
Altitude: fis-local
Affected surface: Expected Outcomes OC02; Acceptance Scenario S02 (When/Then/And); Technical Overview classification sentence; Constraints & Gotchas "Byte contract"; TI01 Verify
Decision: Preserved opaque legacy content is copied byte-for-byte into a sibling `memory/legacy/<source>.md` file named for the legacy source it came from and is never structurally mutated; that directory sits outside the S01 canonical validator but inside the S02 corpus fingerprint, so later external edits to it surface as drift. Recognition for migration is defined by the retained legacy parser contract restricted to what is representable in S01's canonical model – not by the S01 canonical codec.
Rationale: One byte-exact holding area keeps preservation auditable without teaching the canonical validator a second dialect, and fingerprint membership keeps drift detection honest instead of leaving a silent blind spot. The prior scenario wording was also impossible: the S01 codec rejects non-canonical input, so it can never be the classifier for legacy bytes.
Evidence: Owner-ratified preflight resolution 2026-08-11, S03 item 9 and reconciliation (b); `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` opaque-content preservation; `dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md#constraints--gotchas` version-boundary rejection of non-canonical Markdown; `dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#technical-overview` committed fingerprint.

Old:
```
- [OC02] Opaque or ambiguous legacy Markdown remains byte-recoverable under its original store role and is explicitly
  reported without guessed meaning, provenance, or topic.
```
New:
```
- [OC02] Opaque or ambiguous legacy Markdown is preserved byte-for-byte in a sibling `memory/legacy/<source>.md` file
  that canonical validation never parses and the corpus fingerprint always covers, and is explicitly reported without
  guessed meaning, provenance, or topic.
```
Old:
```
  - **When** migration classifies only content recognized by the S01 codec
  - **Then** recognized entries migrate and every opaque byte sequence remains in a clearly identified, original-role
    legacy area outside structured mutation
  - **And** the bounded report identifies each preserved source/locator and reason without copying its content or
    inventing provenance, topic, or authority
```
New:
```
  - **When** migration classifies only content the retained legacy parser contract recognizes and that is representable
    in S01's canonical model
  - **Then** recognized entries migrate and every opaque byte sequence is copied verbatim into
    `memory/legacy/<source>.md`, named for the legacy source it came from and never structurally mutated
  - **And** `memory/legacy/` is excluded from S01 canonical validation but included in the S02 corpus fingerprint, so a
    later external edit to a preserved file is detected as drift
  - **And** the bounded report identifies each preserved source/locator and reason without copying its content or
    inventing provenance, topic, or authority
```
Old:
```
runtime learning keeps its native format, and opaque Markdown stays attached to its source `MemoryRole`. S01's
```
New:
```
runtime learning keeps its native format, and opaque Markdown is copied verbatim into a sibling
`memory/legacy/<source>.md` file that canonical validation never parses and the corpus fingerprint always covers. S01's
```
Old:
```
- **Byte contract**: Byte preservation applies to opaque valid UTF-8 spans and the complete retained prior snapshot.
  Invalid UTF-8 is unreadable input: preserve it untouched, report it, and fail before mutation rather than decoding
  with replacement characters.
```
New:
```
- **Byte contract**: Opaque valid UTF-8 spans are copied verbatim into `memory/legacy/<source>.md`, named for the legacy
  source they came from and never structurally mutated; the complete retained prior snapshot is byte-preserved too.
  `memory/legacy/` sits outside S01 validation but inside the S02 corpus fingerprint, so an external edit to a preserved
  file surfaces as drift. Invalid UTF-8 is unreadable input: preserve it untouched, report it, and fail before mutation
  rather than decoding with replacement characters.
```
Old:
```
  - **Verify**: S01/S02 fixtures prove active memory → topic/index, archive → archive, daily activity → observation, native
    learning-role retention, unchanged semantic text, stable canonical metadata, source-role opaque
    preservation/reporting, 256/257-record batching, and recovery without a derived DB.
```
New:
```
  - **Verify**: S01/S02 fixtures prove active memory → topic/index, archive → archive, daily activity → observation, native
    learning-role retention, unchanged semantic text, stable canonical metadata, byte-identical opaque preservation in
    `memory/legacy/<source>.md` that S01 validation ignores and the corpus fingerprint covers, per-source opaque
    reporting, 256/257-record batching, and recovery without a derived DB.
```

#### DECISION NOTE: snapshot-mismatch-next-action
Decision-Key: snapshot-mismatch-next-action
Altitude: fis-local
Affected surface: Acceptance Scenario S03 (new And leg); Constraints & Gotchas "Recovery"; TI02 task body and TI02 Verify
Decision: When a retained pre-migration snapshot exists but its recorded source fingerprint differs from the current legacy sources, the preflight halts before any staging or commit, changes nothing, and reports the snapshot path plus the instruction to inspect and delete it before retrying. It never auto-restores, auto-rotates, or auto-archives the snapshot.
Rationale: A fingerprint mismatch means the operator's assumption about what the snapshot protects is already wrong, so any automatic recovery action risks destroying the one byte-exact copy of the prior state. A single-owner workspace makes an explicit manual step the cheapest safe resolution.
Evidence: Owner-ratified preflight resolution 2026-08-11, S03 item 10, applying standing directive D-A (manual steps acceptable); `dev/bundle/docs/specs/0.24/prd.md#fr6-maintenance-limits-and-recovery` prior-state preservation and recovery reporting.

Old:
```
  - **Then** canonical files, backup bytes, entry identities, and collection revision remain unchanged
  - **And** the report says the corpus is already current and records no newly migrated or duplicated content
```
New:
```
  - **Then** canonical files, backup bytes, entry identities, and collection revision remain unchanged
  - **And** the report says the corpus is already current and records no newly migrated or duplicated content
  - **And** when the retained snapshot's recorded source fingerprint no longer matches the current sources, the preflight
    halts with the workspace unchanged and reports the snapshot path plus the instruction to inspect and delete it
    before retrying, never restoring, rotating, or archiving it automatically
```
Old:
```
- **Recovery**: The retained snapshot is created with no-clobber semantics and records absent source files as absent;
  reruns neither rotate nor overwrite it. An existing snapshot with a different source fingerprint fails explicitly
  instead of being reused. S02 recovery, not handwritten compensating writes, resolves interrupted commits.
```
New:
```
- **Recovery**: The retained snapshot is created with no-clobber semantics and records absent source files as absent;
  reruns neither rotate nor overwrite it. An existing snapshot whose recorded source fingerprint differs from the
  current sources halts the preflight, changes nothing, and reports the snapshot path plus the instruction to inspect
  and delete it before retrying – never an automatic restore, rotation, or archive. S02 recovery, not handwritten
  compensating writes, resolves interrupted commits.
```
Old:
```
    diagnostics and 64 KiB UTF-8 with total/returned/omitted counts.
```
New:
```
    diagnostics and 64 KiB UTF-8 with total/returned/omitted counts.
  - On a retained snapshot whose recorded source fingerprint no longer matches the current sources, halt before any
    staging or commit, mutate nothing, and report the snapshot path with the inspect-and-delete retry instruction
    instead of restoring, rotating, or archiving it.
```
Old:
```
    commit/revision advance for multi-batch migration, and exact 100/101-diagnostic and 64-KiB/64-KiB+1 report boundaries.
```
New:
```
    commit/revision advance for multi-batch migration, a fingerprint-mismatched snapshot halting with an unchanged
    workspace and an inspect-and-delete instruction, and exact 100/101-diagnostic and 64-KiB/64-KiB+1 report boundaries.
```

#### DECISION NOTE: parser-general-category-fate
Decision-Key: parser-general-category-fate
Altitude: fis-local
Affected surface: Technical Overview classification sentence; Acceptance Scenario S01 Then; Constraints & Gotchas "Role fidelity"; TI01 task body (new category-mapping bullet)
Decision: Legacy categories become S01 topics through S01's topic-slug rule – lowercase, whitespace runs collapse to one hyphen, other characters are dropped, repeated hyphens collapse, leading/trailing hyphens are trimmed – and colliding slugs merge into one topic. Entries the legacy parser defaulted to category `general` migrate to topic `general`, and the migration report states how many entries took that default.
Rationale: `general` is a parser default, not a statement of intent, so inventing a different destination for it would be exactly the semantic guessing this story forbids; a mechanical slug mapping plus an explicit default count preserves the preserve-and-report contract and leaves the owner one number to judge whether a later curation pass is worth running.
Evidence: Owner-ratified preflight resolution 2026-08-11, S03 item 11 and reconciliation (e); S01 topic-validity contract (preflight item 2) defining the slug rule, the 64-character ceiling, and slug-collision merging; `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` legacy role mapping.

Old:
```
Legacy classification is role-preserving and non-semantic: recognized `MEMORY.md` entries become active topic/index
memory using their existing category, archive stays archive, recognized daily activity becomes `MemoryObservation`,
```
New:
```
Legacy classification is role-preserving and non-semantic: recognized `MEMORY.md` entries become active topic/index
memory whose topic is their legacy category run through S01's topic-slug rule – parser-defaulted `general` entries land
on topic `general` – archive stays archive, recognized daily activity becomes `MemoryObservation`,
```
Old:
```
  - **Then** active memory becomes a topic detail plus bounded index entry using its existing category as topic, archive
```
New:
```
  - **Then** active memory becomes a topic detail plus bounded index entry under its slugified category topic, archive
```
Old:
```
- **Role fidelity**: A source file supplies only its canonical role and migration provenance; an explicit valid legacy
  category may carry forward as topic. Migration does not infer another topic, source-backed claim, or promotion from
```
New:
```
- **Role fidelity**: A source file supplies only its canonical role and migration provenance; a legacy category carries
  forward as its slugified S01 topic. Migration does not infer another topic, source-backed claim, or promotion from
```
Old:
```
    records per in-memory batch without publishing a batch as canonical state.
```
New:
```
    records per in-memory batch without publishing a batch as canonical state.
  - Derive each entry topic from its legacy category with S01's topic-slug rule (lowercase, whitespace runs → one
    hyphen, other characters dropped, repeated hyphens collapsed, leading/trailing hyphens trimmed); colliding slugs
    merge into one topic, entries the legacy parser defaulted to category `general` land on topic `general`, and the
    report states how many entries took that default.
```

#### DECISION NOTE: legacy-timestamp-utc-rule
Decision-Key: legacy-timestamp-utc-rule
Altitude: fis-local
Affected surface: Acceptance Scenario S01 And; Constraints & Gotchas (new "Timestamp normalization" bullet after "Duplicate fidelity"); Testing Strategy Layer 1
Decision: Naive `[YYYY-MM-DD HH:MM]` legacy stamps carry no zone. Migration interprets them as host-local time and converts them to the UTC instants S01 requires, rather than reading the wall-clock digits as if they were already UTC.
Rationale: The stamps were written by a process running in the host's local zone, so host-local is the only reading that preserves the recorded moment; treating them as UTC would silently shift every legacy timestamp by the host offset and corrupt ordering against post-migration entries.
Evidence: Owner-ratified preflight resolution 2026-08-11, S03 item 12; legacy stamp recognition in `packages/dartclaw_core/lib/src/memory/memory_entry_parser.dart#parseMemoryEntries`; UTC timestamp requirement in `dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md#acceptance-scenarios` scenario S01.

Old:
```
    every source retains its timestamp and semantic text
```
New:
```
    every source retains its semantic text, and naive `[YYYY-MM-DD HH:MM]` stamps are read as host-local time and
    stored as UTC
```
Old:
```
- **Duplicate fidelity**: Equal text at distinct legacy source spans remains distinct because its source identity is
  distinct; only rerunning the same migrated source is a no-op. Migration performs no semantic or text-only deduplication.
```
New:
```
- **Duplicate fidelity**: Equal text at distinct legacy source spans remains distinct because its source identity is
  distinct; only rerunning the same migrated source is a no-op. Migration performs no semantic or text-only deduplication.
- **Timestamp normalization**: naive `[YYYY-MM-DD HH:MM]` legacy stamps carry no zone; migration interprets them as
  host-local time and converts them to the UTC instants S01 requires. Reading the wall-clock digits as UTC is wrong and
  would shift every legacy timestamp by the host offset.
```
Old:
```
  files, repeat migration, and 256/257-record batch instrumentation.
```
New:
```
  files, repeat migration, naive host-local `[YYYY-MM-DD HH:MM]` stamps converted to UTC under a fixed test zone, and
  256/257-record batch instrumentation.
```

#### DECISION NOTE: learnings-canonical-role
Decision-Key: learnings-canonical-role
Altitude: fis-local
Affected surface: Expected Outcomes OC01; Acceptance Scenario S01 Then and And; Technical Overview classification sentence; Code Patterns row for `self_improvement_service.dart`; TI01 Verify
Decision: Migration converts `learnings.md` into canonical learning-role entries. Each recognized learning receives a host-assigned canonical identity, revision, and provenance whose origin kind is `migration`, and thereafter participates in validation, revision, and the corpus fingerprint exactly like every other canonical role. This supersedes the "runtime learnings retain their native bounded role" premise everywhere it appeared in this FIS.
Rationale: The owner's cross-cutting ratification makes learnings a canonical role in S01, so a migration that left them in a native format would reintroduce the permanent dual-format special case inside the single mutation authority that the 0.24 model exists to remove. Single-owner scope makes the one-time conversion cost acceptable.
Evidence: Owner-ratified preflight resolution 2026-08-11, cross-cutting learnings-canonical-role decision plus S01 items 4 and 5 and S03 item 13; origin-kind vocabulary `turn|journal|inbox|curation|migration` from S01 item 1. Note: the TI01 pair carries the trailing blank line and the unmodified `- [ ] **TI02**` heading line verbatim in both `Old:` and `New:` purely as a uniqueness anchor – the TI02 heading text is not altered.

Old:
```
- [OC01] Recognized legacy active memory, archive entries, and daily activity records retain their semantic text and
  acquire S01 canonical identity, revision, provenance, and role; runtime learnings retain their native bounded role.
```
New:
```
- [OC01] Recognized legacy active memory, archive entries, daily activity records, and runtime learnings retain their
  semantic text and acquire S01 canonical identity, revision, role, and provenance whose origin kind is `migration`.
```
Old:
```
    remains archived cold memory, daily activity becomes an observation outside the prompt index, and learning remains
    native bounded runtime self-improvement knowledge
```
New:
```
    remains archived cold memory, daily activity becomes an observation outside the prompt index, and the runtime
    learning becomes a canonical learning-role entry with a host-assigned identity
```
Old:
```
  - **And** migrated personal-memory, archive, and observation records have S01 identity/revision/provenance metadata;
```
New:
```
  - **And** migrated personal-memory, archive, observation, and learning records have S01 identity/revision/provenance
    metadata whose origin kind is `migration`;
```
Old:
```
runtime learning keeps its native format, and opaque Markdown is copied verbatim into a sibling
`memory/legacy/<source>.md` file that canonical validation never parses and the corpus fingerprint always covers. S01's
`MemoryMarkdownCodec`, `MemoryCorpusValidator`, `CanonicalMemoryEntry`, `MemoryIndexEntry`, and `MemorySourceRef` own the
```
New:
```
runtime learning becomes canonical learning-role entries, and opaque Markdown is copied verbatim into a sibling
`memory/legacy/<source>.md` file that canonical validation never parses and the corpus fingerprint always covers. S01's
`MemoryMarkdownCodec`, `MemoryCorpusValidator`, `CanonicalMemoryEntry`, `MemoryIndexEntry`, and `MemorySourceRef` own the
```
Old:
```
file   | packages/dartclaw_server/lib/src/behavior/self_improvement_service.dart#SelfImprovementService.appendLearning | Native bounded runtime-learning format migration must retain
```
New:
```
file   | packages/dartclaw_server/lib/src/behavior/self_improvement_service.dart#SelfImprovementService.appendLearning | Legacy runtime-learning format migration must parse and convert into canonical learning-role entries
```
Old:
```
  - **Verify**: S01/S02 fixtures prove active memory → topic/index, archive → archive, daily activity → observation, native
    learning-role retention, unchanged semantic text, stable canonical metadata, byte-identical opaque preservation in
    `memory/legacy/<source>.md` that S01 validation ignores and the corpus fingerprint covers, per-source opaque
    reporting, 256/257-record batching, and recovery without a derived DB.

- [ ] **TI02** Migration retries and interruptions preserve one recoverable prior state
```
New:
```
  - **Verify**: S01/S02 fixtures prove active memory → topic/index, archive → archive, daily activity → observation,
    `learnings.md` converted to canonical learning-role entries with origin kind `migration`, unchanged semantic text,
    stable canonical metadata, byte-identical opaque preservation in `memory/legacy/<source>.md` that S01 validation
    ignores and the corpus fingerprint covers, per-source opaque reporting, 256/257-record batching, and recovery
    without a derived DB.

- [ ] **TI02** Migration retries and interruptions preserve one recoverable prior state
```

#### DECISION NOTE: migration-proportionality
Decision-Key: migration-proportionality
Altitude: fis-local
Affected surface: Architecture Decision "Why this over alternatives"; Scope & Boundaries "What We're NOT Doing" (new bootstrap bullet); Structural Criteria fresh/already-current stability criterion; TI03 Verify
Decision: Migration stays proportionate to a single-owner workspace – preserve and report, with no reconciliation, rollback, or legacy-format machinery beyond what the settled S03 decisions require. S03 also never mints the canonical skeleton: bootstrapping a workspace that has no legacy sources and no canonical corpus is S02's authority, so S03's byte- and revision-stability criterion is carved to a workspace with an existing corpus.
Rationale: Standing directive D-A makes manual steps and re-import acceptable, so elaborate migration machinery buys nothing a single owner needs. Keeping the fresh-workspace claim would additionally assert behavior S03 does not own and contradict S02's mint-at-revision-1 bootstrap path, leaving two stories claiming the same first-open outcome.
Evidence: Owner-ratified preflight resolution 2026-08-11, S03 item 14 (standing directive D-A) and reconciliation (a) against S02 item 6 empty-workspace-bootstrap; `dev/state/PRODUCT.md#core-philosophy` smallest-change and no-speculative-framework rules.

Old:
```
**Why this over alternatives**: It makes the format transition lossless and restart-safe while reusing the two preceding
stories instead of creating a migration framework, ledger, lock, or database.
```
New:
```
**Why this over alternatives**: It makes the format transition lossless and restart-safe while reusing the two preceding
stories instead of creating a migration framework, ledger, lock, or database. Migration stays proportionate –
preserve-and-report only, with no reconciliation machinery beyond what the settled decisions require – because a
single-owner workspace makes an explicit manual retry an acceptable outcome.
```
Old:
```
- Semantically curating, merging, promoting, or choosing topics for legacy/opaque content – the first explicit S09
  curation may reorganize it.
```
New:
```
- Semantically curating, merging, promoting, or choosing topics for legacy/opaque content – the first explicit S09
  curation may reorganize it.
- Bootstrapping a workspace that has no legacy sources and no canonical corpus – S02's authority mints the collection
  and commits the initial canonical state; S03 runs only where a corpus already exists.
```
Old:
```
- [ ] A fresh or already-current workspace with no supported external edit remains byte- and revision-stable.
```
New:
```
- [ ] A workspace with an existing corpus and no supported external edit remains byte- and revision-stable across
  preflight reruns; minting the canonical skeleton for a workspace that has none is S02's bootstrap, not S03's.
```
Old:
```
    precede both index boundaries, failure invokes neither boundary nor harness/server traffic, and current/fresh
    workspaces stay stable.
```
New:
```
    precede both index boundaries, failure invokes neither boundary nor harness/server traffic, and an already-current
    workspace with an existing corpus stays byte- and revision-stable.
```

#### DECISION NOTE: topic-slug-length-overflow
Decision-Key: topic-slug-length-overflow
Altitude: fis-local
Affected surface: ## Implementation Tasks TI01 (migration slug bullet – over-length truncation, trailing-hyphen trim, and collision merge)
Decision: Migration truncates a slugified legacy category longer than S01's 64-character topic ceiling at 64 characters, trims any trailing hyphen the cut leaves behind, and merges a slug that collides after truncation exactly like any other slug collision; truncation is a migration-only affordance and never a runtime normalization, because S01's runtime contract rejects an over-length topic instead.
Rationale: Owner-ratified preflight resolution – truncate-and-merge keeps every migrated entry inside structured memory (consistent with routing parser-defaulted `general` to topic `general`) rather than failing or quarantining a legacy category for its length, and reuses the already-ratified collision-merge rule instead of inventing a second disambiguation mechanism.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), item 42 topic-slug-length-overflow, applying item 2's slug-collision merging; TI01's slug bullet already states it – "Truncate a slugified legacy category longer than S01's 64-character topic ceiling at 64 characters and trim any resulting trailing hyphen; a truncation that lands on an existing slug merges like any other slug collision. Truncation is a migration-only affordance – S01's runtime topic contract rejects an over-length topic rather than normalizing it."; therefore this note carries zero `Old:`/`New:` pairs.

#### IMPLEMENTATION NOTE: final-verification

- The initial S03 implementation review failed and was superseded by an AUTO_MODE retry. That retry remediated all seven original findings plus four fresh-review findings, then received a fresh inline quick-review verdict of GREEN with 11 guardrails checked and zero findings.
- Current integrated-tree verification at 2026-08-12 06:25 CEST: migration suite 22 passed with one intentional fixed-zone child skip; CLI preflight/recovery suite 8 passed; fatal-info analysis clean; architecture 8/8; fitness 31/31; `git diff --check` clean.
