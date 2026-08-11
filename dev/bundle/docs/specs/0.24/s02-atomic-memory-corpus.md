# Feature Implementation Specification: Atomic Memory Corpus

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: Let every memory writer and maintenance operation change the file-canonical corpus without lost updates, mixed revisions, or crash-exposed partial state.

**Expected Outcomes**:

- [OC01] Callers receive bounded, internally consistent corpus snapshots carrying one current collection revision.
- [OC02] A valid canonical change set commits every affected document and advances the collection revision exactly once, while stale or invalid work changes nothing.
- [OC03] Plausible write failures, crashes, stopped-runtime edits, and cooperating concurrency never expose a mixed or silently overwritten canonical corpus.
- [OC04] Existing and later observation, memory, curation, and maintenance writers use one mutation, serialization, lock, and shutdown authority.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.1` – S02 scope, dependency, risk, and the justified single-authority enabler boundary.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` – canonical corpus, single revision/mutation authority, stopped-runtime reconciliation, and release-simplicity contracts.
- `dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md#architecture-decision` – canonical files, revision placement, roles, and the core-owned codec/validator boundary this story must consume.
- `dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md#implementation-plan` – `MemoryMarkdownCodec`, `MemoryCorpusValidator`, and deterministic relative-path-to-bytes inventory delivered by the prerequisite story.
- `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` – file authority and the rule that no canonical content may exist only in a derived database.
- `dev/bundle/docs/specs/0.24/prd.md#fr2-guarded-memory-tools` – one validation/mutation authority, shared revision CAS, pre-write rejection, and canonical-before-index outcome contract.
- `dev/bundle/docs/specs/0.24/prd.md#fr3-on-demand-semantic-curation` – bounded snapshots and stale-proposal rejection through the same host commit seam.
- `dev/bundle/docs/specs/0.24/prd.md#fr6-maintenance-limits-and-recovery` – shared maintenance lock/revision authority, no half-applied active/archive state, and transition-targeted fault proof.
- `dev/bundle/docs/specs/0.24/prd.md#non-functional-requirements` – zero partial canonical change, crash consistency, portability, and reuse requirements.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – single-isolate, trusted-host threat model and prohibition on a competing lock, queue, package, database, daemon, or scheduler.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – 0.24 scope exclusions, including no new package/database or wiki/KG write expansion.
- `dev/adrs/002-file-based-storage.md#decision` – plain files remain canonical and SQLite remains a rebuildable search index.
- `dev/architecture/data-model.md#write-safety` – current atomic replacement and shared workspace-lock patterns to consolidate rather than duplicate.

## Deeper Context

- `dev/architecture/data-model.md#backup--recovery` – current recovery promises and the distinction between canonical files and rebuildable `search.db`.
- `dev/guidelines/TESTING-STRATEGY.md#data-integrity` – storage-CAS/crash-recovery tests are vital-core coverage and must retain malformed, boundary, and compatibility cases.
- `dev/state/learnings/tooling-verification.md#tooling--verification` – fault injection must hit the claimed transition, not merely fail before work begins.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01] A selected corpus snapshot stops at its supplied file and byte budgets without reading omitted documents**
  - **Given** an already reconciled 80-byte index and two requested 120-byte topic documents at collection revision `12`
  - **When** a caller requests the index followed by both topics, once with a two-document/1-KiB limit and once with a three-document/250-byte limit
  - **Then** each snapshot contains the complete index and first topic at revision `12`, reports the second topic under the correct document-count or aggregate-byte limit, and its file-read trace proves the omitted file was not opened or allocated during snapshot assembly

- [ ] **S02 [OC02,OC03] [TI02] A multi-document canonical change commits as one revision**
  - **Given** a validated revision-`12` corpus with an index, topic `preferences`, and an archive, plus a change set that revises the index and topic while leaving the archive untouched
  - **When** the authority applies the change set with expected collection revision `12`
  - **Then** the complete new index and topic become visible together at revision `13`, the archive is byte-identical, the committed fingerprint matches the full canonical union, and the revision advanced once regardless of the number of changed files

- [ ] **S03 [OC02] [TI02] One invalid resulting document rejects the whole change set before staging**
  - **Given** collection revision `13` and a two-document change set whose index is valid but whose topic duplicates a canonical entry ID already present in the archive
  - **When** the authority validates and applies the change set with expected revision `13`
  - **Then** it reports the cross-document validation failure, stages or replaces no file, invokes no derived-index work, and leaves every canonical byte, fingerprint, and revision unchanged

- [ ] **S04 [OC02,OC03,OC04] [TI02,TI04] Two cooperating mutations from one snapshot cannot both commit**
  - **Given** a curation-style change and a maintenance change both captured from revision `13`, with controlled barriers making them contend on the same resolved workspace through real-path and symlink aliases
  - **When** both submit with expected revision `13`
  - **Then** one complete change commits at revision `14`, the other returns a stale-revision result carrying current revision `14`, no content from the rejected change is visible, and neither operation overlaps the other's canonical critical section

- [ ] **S05 [OC03] [TI02,TI03] An injected I/O failure at each pre-commit transition restores the prior corpus**
  - **Given** revision `14`, a change affecting three canonical documents, and a table-driven fault injector targeting each stage write, backup transition, and target replacement before the revision-bearing `MEMORY.md` commit marker
  - **When** each fault is exercised independently
  - **Then** the operation returns failure only after recovering the complete revision-`14` corpus, leaves the committed fingerprint and derived index untouched, and a retry without the fault commits exactly once at revision `15`

- [ ] **S06 [OC03] [TI03] Restart recovery exposes either the complete old revision or the complete committed revision, never a mixture**
  - **Given** a revision-`15` multi-document change and simulated process death after each target replacement, immediately before the revision-bearing commit marker, immediately after it, and before transaction cleanup
  - **When** a fresh authority opens the workspace and recovers before serving a snapshot or mutation
  - **Then** pre-marker deaths restore the complete revision-`15` corpus, post-marker deaths finish the complete revision-`16` corpus and its fingerprint state, and every case removes or safely retains recognizable recovery artifacts without inventing another revision

- [ ] **S07 [OC01,OC03] [TI01,TI03] Supported stopped-runtime topic and observation changes advance the host-owned revision before CAS resumes**
  - **Given** clean committed revision `16`, then independently a manual topic edit, a dated observation-partition edit, and deletion of a dated observation partition while DartClaw is stopped and no transaction journal exists
  - **When** the authority reopens the workspace for each case
  - **Then** it detects the full-corpus fingerprint mismatch, validates the complete resulting S01 corpus, advances the `MEMORY.md` collection revision once to `17` under the shared lock, records the reconciled fingerprint, reports the changed or removed canonical role and locator for later index reconciliation, and rejects a subsequent mutation still expecting revision `16`; an invalid edit instead leaves bytes and revision untouched and reports recovery-required

## Structural Criteria

- [ ] `MEMORY.md` metadata remains the only collection-revision source of truth; the committed fingerprint sidecar and transaction artifacts are coordination state, not a second content or revision authority.
- [ ] Canonical Markdown remains authoritative and `search.db` remains derived; post-commit index failure cannot roll back a canonical revision.
- [ ] `dartclaw_core` remains SQLite-free, and no new package, database, daemon, scheduler, provider abstraction, QMD responsibility, or runtime dependency is introduced.
- [ ] All production canonical-file reads and writes that require coherent index/topic/archive/observation/runtime-learning state cross the same normalized workspace authority; `errors.md`, wiki, and temporal-KG writes remain outside this corpus contract.
- [ ] Core public exports and affected package `AGENTS.md` files describe the implemented authority accurately without pre-empting S04/S05 tool semantics or S08 index-health policy.

## Scope & Boundaries

### Work Areas

- `packages/dartclaw_core/lib/src/memory/` – bounded snapshot, committed-fingerprint, CAS mutation, staged commit, recovery, and stopped-edit reconciliation authority over S01 documents.
- `packages/dartclaw_core/lib/src/memory/memory_file_service.dart` – existing active-memory and daily-observation writes delegate to the corpus authority.
- `packages/dartclaw_server/lib/src/behavior/self_improvement_service.dart` – runtime-learning writes delegate while `errors.md` retains its separate behavior.
- `packages/dartclaw_storage/lib/src/memory/memory_pruner.dart` – archive/dedup maintenance supplies a validated corpus change and performs derived-index reconciliation only after canonical commit.
- Core, storage, and server memory tests plus explicit barrel/package-rule updates – portable concurrency, fault, restart, delegation, and public-contract proof.

### What We're NOT Doing

- Tool schemas, guard/provider mappings, or removal of `memory_save` – S04 and S05 own the model-facing contracts and migration.
- Legacy discovery, backup conversion, or opaque-content migration – S03 consumes this authority and the S01 codec.
- Search-index rebuild, health/status state machines, or healthy-use gating – S08 owns those outcomes; this story exposes canonical commit/reconciliation facts only.
- Semantic curation, model dispatch, operator/job scheduling, or automatic stewardship – S09 owns explicit curation and 0.27 owns autonomy.
- Final resource-policy configuration, pruning semantics, wiki/KG mutation, QMD changes, or broad documentation convergence – S10–S12 own those slices.

## Architecture Decision

**Approach**: One core-owned, resolved-workspace corpus service consumes S01's codec/validator, owns bounded snapshots plus the committed fingerprint, and serializes CAS mutations through the existing `RepoLock`; it stages recoverable sibling files, replaces revision-bearing `MEMORY.md` last as the commit marker, then runs derived-index reconciliation.
**Why this over alternatives**: It makes the existing file, lock, and atomic-write seams one authority and provides multi-file crash recovery without a database, package, generic transaction framework, or second revision counter.

## Technical Overview

Opening the authority resolves the workspace root, acquires one corpus lock key, recovers an unfinished transaction, and streams the complete S01 inventory within finite scan bounds to reconcile the committed fingerprint. Later snapshots use the reconciled state plus S01's deterministic path ordering and explicit document/count/aggregate-byte limits, without opening omitted documents.

A mutation checks the expected collection revision only after recovery and stopped-edit reconciliation, renders the complete affected S01 documents, validates the resulting corpus, and verifies all bounds before staging. One small atomically written state sidecar records the committed full-union fingerprint; a transaction journal records base/target revisions, fingerprints, stages, and backups. Every canonical document except `MEMORY.md` is replaced first and revision-bearing `MEMORY.md` last. The journal lets restart recovery roll back a pre-marker interruption or finish a post-marker commit before any reader proceeds. Derived indexing is downstream of that marker and cannot rewrite canonical state.

Supported stopped-runtime content edits and deletions with unchanged valid host metadata are validated and receive one host-owned revision advance; malformed corpus or manual revision tampering fails explicitly for later recovery. Closing the authority drains accepted operations and rejects new ones, reusing the existing bounded-queue discipline rather than adding another scheduler.

## Code Patterns & External References

```
# type | path#anchor                                                                 | why needed (intent)
file   | packages/dartclaw_core/lib/src/concurrency/repo_lock.dart#RepoLock.acquire | Reuse normalized, reentrant per-workspace serialization
file   | packages/dartclaw_core/lib/src/storage/atomic_write.dart#secureWriteFile    | Reuse flushed sibling-file replacement and randomized temp cleanup
file   | packages/dartclaw_core/lib/src/storage/write_op.dart#BoundedWriteQueue      | Reuse bounded FIFO admission and drain-on-close behavior
file   | packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService.appendMemory | Delegate the current active-memory writer without retaining a second lock/queue
file   | packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService.appendDailyLog | Route the current daily observation writer through the same authority
file   | packages/dartclaw_server/lib/src/behavior/self_improvement_service.dart#SelfImprovementService.appendLearning | Delegate only runtime-learning corpus writes
file   | packages/dartclaw_storage/lib/src/memory/memory_pruner.dart#MemoryPruner.prune | Replace bespoke multi-file rollback with the shared canonical commit
file   | packages/dartclaw_storage/lib/src/storage/memory_service.dart#MemoryService.replaceSourceRows | Preserve transactional derived-row replacement after canonical commit
test   | packages/dartclaw_core/test/memory/memory_file_service_test.dart#workspace write lock resolves symlink aliases | Green parity for normalized workspace contention
test   | packages/dartclaw_storage/test/memory/memory_pruner_test.dart#source write failure retries without duplicate archive or index entries | Green parity for retry-safe canonical maintenance
```

## Constraints & Gotchas

- **S01 is authoritative**: Reuse `MemoryMarkdownCodec`, `MemoryCorpusValidator`, deterministic path-to-bytes inventory, roles, and document values; do not invent parallel entry/revision/serialization types.
- **One revision, two identities**: The positive collection revision in `MEMORY.md` is distinct from per-entry revisions. A changed multi-file commit advances the collection once; transaction state and fingerprints never become counters.
- **Marker ordering is load-bearing**: Every other target must be durable before revision-bearing `MEMORY.md`; committed fingerprint state follows while the journal still permits idempotent finalization.
- **Lock scope includes callbacks and recovery**: Snapshot, revision check, stage/commit/recovery, and stopped-edit advancement share the resolved-root key. Reentrant composition is allowed; a second queue/lock in a delegating writer is not.
- **Canonical before derived**: Index reconciliation starts after the canonical marker. Later stories may expose saved-but-index-degraded health, but must never reinterpret index failure as canonical rollback.
- **Threat boundary**: Handle cooperating concurrency, process crashes, ordinary I/O errors, bounded resources, symlink aliases, and stopped-runtime edits. Do not add descriptor-bound hostile-path/inode defenses or stronger power-loss guarantees.
- **Fault fidelity**: Inject after real stage/replace/marker transitions and at restart boundaries; a pre-work exception does not prove rollback or crash recovery.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Corpus snapshots are bounded and carry one reconciled collection revision
  - Build the core authority on S01's codec/validator/inventory, one resolved-workspace lock, a streamed committed fingerprint, explicit snapshot limits, and stopped-edit revision reconciliation; export only the shared cross-package contract.
  - **Verify**: Layer-2 temp-workspace tests prove S01 and S07, including unopened omitted files; exactly one external-change revision advance for a topic edit, dated-observation edit, and dated-observation deletion; changed/removed role and locator reporting; explicit invalid-edit state; stale-CAS rejection after reconciliation; and no SQLite/server/storage dependency in core.

- [ ] **TI02** Canonical mutations are all-or-nothing CAS commits
  - Validate the complete resulting S01 corpus and every bound before writing, then stage and commit all changed canonical documents through one transaction whose last canonical marker is revision-bearing `MEMORY.md`; consume TI01's reconciled revision/fingerprint state.
  - **Verify**: Controlled component tests prove S02–S05: exactly one revision advance for a multi-file change, no staging for invalid output, one winner under same-revision contention, unchanged bytes/fingerprint/index on every injected pre-marker failure, and a successful single-advance retry.

- [ ] **TI03** Interrupted corpus commits recover before any reader or writer proceeds
  - Make the transaction journal, stages, backups, marker, and fingerprint finalization idempotently recoverable; use TI02's commit order and TI01's fingerprint comparison without introducing an independent revision source.
  - **Verify**: A process-reopen fault matrix proves S05–S07 at every real transition: old-complete before the marker, new-complete after it, no mixed snapshot, no invented revision, recognizable artifact cleanup, and valid versus invalid stopped-edit behavior.

- [ ] **TI04** All canonical writers use the shared corpus authority
  - Delegate active-memory/daily-observation, runtime-learning, and prune/archive coherent reads and canonical changes through TI01–TI03; keep derived index replacement post-commit, drain accepted work on shutdown, and synchronize affected barrels and package rules.
  - **Verify**: Core/storage/server integration tests prove S04 across real-path/symlink instances, queued shutdown preserves acknowledged writes and rejects later work, index failure preserves the committed revision, scans find no bypassing canonical replacement, package/API checks prove the stated boundaries, and focused memory/lock/atomic/queue suites remain green.

### Testing Strategy

- [TI01,TI02,TI03] Use Layer-2 temp-directory tests with real files, the S01 codec/validator, controlled `Completer` barriers, and an injected transition hook. Table-drive validation failures, each stage/replace/marker crash point, retry, and real-path/symlink aliases; never use real-time waits.
- [TI04] Keep core service behavior at the core layer, then add narrow storage/server integration coverage for pruner index ordering and runtime-learning delegation. Existing suites are parity evidence only; the new CAS/crash scenarios require new red-first tests whose assertions name canonical bytes, revision, fingerprint, and result state.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS mutability contract. Spec authors leave this section empty._

_No observations recorded yet._
