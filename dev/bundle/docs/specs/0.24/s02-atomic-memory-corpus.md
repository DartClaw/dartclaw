# Feature Implementation Specification: Atomic Memory Corpus

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: Let every memory writer and maintenance operation change the file-canonical corpus without lost updates, mixed revisions, or crash-exposed partial state.

**Expected Outcomes**:

- [OC01] Callers receive bounded, internally consistent corpus snapshots carrying one current collection revision.
- [OC02] A valid canonical change set commits every affected document and advances the collection revision exactly once, while stale or invalid work changes nothing.
- [OC03] Plausible write failures, crashes, stopped-runtime edits, and cooperating concurrency never expose a mixed or silently overwritten canonical corpus.
- [OC04] Existing and later observation, memory, runtime-learning, deletion-audit, curation, and maintenance writers use one mutation, serialization, lock, and shutdown authority, and the runtime-learning and deletion-audit roles sit inside the same fingerprint, revision, and validation contract as every other canonical role.

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

- [ ] **S07 [OC01,OC03] [TI01,TI03] Supported stopped-runtime topic, runtime-learning, and observation changes advance the host-owned revision before CAS resumes**
  - **Given** clean committed revision `16`, then independently a manual topic edit, a manual runtime-learning edit, a dated observation-partition edit, and deletion of a dated observation partition while DartClaw is stopped and no transaction journal exists
  - **When** the authority reopens the workspace for each case
  - **Then** it detects the full-corpus fingerprint mismatch, validates the complete resulting S01 corpus, advances the `MEMORY.md` collection revision once to `17` under the shared lock, records the reconciled fingerprint, reports the changed or removed canonical role and locator for later index reconciliation, and rejects a subsequent mutation still expecting revision `16`; an invalid edit instead leaves bytes and revision untouched and reports recovery-required

- [ ] **S08 [OC01,OC02,OC03] [TI01,TI02] A fresh workspace bootstraps at revision `1` and a missing fingerprint sidecar adopts the current corpus**
  - **Given** independently a resolved workspace holding no canonical corpus, no committed-fingerprint sidecar and no transaction journal; a valid committed revision-`17` corpus whose fingerprint sidecar has been deleted; and that same revision-`17` corpus with a present sidecar recording a different fingerprint
  - **When** a fresh authority opens each workspace and then serves a snapshot
  - **Then** the empty workspace holds one minted collection UUID at collection revision `1` committed as the initial canonical state, the sidecar-less corpus keeps every canonical byte at revision `17` with its recomputed fingerprint recorded and no changed-role report, neither of those cases reports a fingerprint mismatch, and only the present-and-differing sidecar takes the stopped-edit reconciliation path

## Structural Criteria

- [ ] `MEMORY.md` metadata remains the only collection-revision source of truth; the committed fingerprint sidecar and transaction artifacts are coordination state, not a second content or revision authority.
- [ ] Canonical Markdown remains authoritative and `search.db` remains derived; post-commit index failure cannot roll back a canonical revision.
- [ ] `dartclaw_core` remains SQLite-free, and no new package, database, daemon, scheduler, provider abstraction, QMD responsibility, or runtime dependency is introduced.
- [ ] All production canonical-file reads and writes that require coherent index/topic/archive/observation/runtime-learning/deletion-audit state cross the same normalized workspace authority, and the runtime-learning and deletion-audit roles participate in the committed fingerprint, collection revision, and corpus validation exactly like the other canonical roles; `errors.md`, wiki, and temporal-KG writes remain outside this corpus contract.
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

Opening the authority resolves the workspace root, acquires one corpus lock key, recovers an unfinished transaction, and streams the complete S01 inventory within finite scan bounds to reconcile the committed fingerprint. That inventory is the union of both S01 member classes – the codec-rendered canonical documents, including the deletion-audit document, and the verbatim members preserving opaque legacy bytes under `memory/legacy/` – so the committed fingerprint covers preserved legacy content as well and a stopped-runtime edit to it is detectable drift. This authority also owns bootstrap: a workspace holding no canonical corpus and no transaction journal mints the collection UUID at collection revision `1` and commits it as the initial canonical state. A missing committed-fingerprint sidecar over an otherwise valid corpus is adopted as current – the recomputed fingerprint is recorded at the unchanged revision – and only a present-and-differing sidecar is a stopped-edit mismatch, so first open never advances a revision by itself. Later snapshots use the reconciled state plus S01's deterministic path ordering and explicit document/count/aggregate-byte limits, without opening omitted documents.

A mutation checks the expected collection revision only after recovery and stopped-edit reconciliation, renders the complete affected S01 documents, validates the resulting corpus, and verifies all bounds before staging. A deletion-audit document is one of those affected canonical documents: it is rendered, validated, staged, and committed inside the same transaction and the same single revision advance as the canonical change it records – never a side file and never a separate write. One small atomically written state sidecar records the committed full-union fingerprint; a transaction journal records base/target revisions, fingerprints, stages, and backups. Every canonical document except `MEMORY.md` is replaced first and revision-bearing `MEMORY.md` last. The journal lets restart recovery roll back a pre-marker interruption or finish a post-marker commit before any reader proceeds. Derived indexing is downstream of that marker and cannot rewrite canonical state.

Supported stopped-runtime content edits and deletions with unchanged valid host metadata are validated and receive one host-owned revision advance; malformed corpus or manual revision tampering fails explicitly for later recovery. Closing the authority drains accepted operations and rejects new ones, reusing the existing bounded-queue discipline rather than adding another scheduler. Existing canonical writers delegate serialization, locking, queueing, shutdown, and atomic-write discipline to this authority in this story, while canonical rendering and validation activate only for a corpus that has passed S03's migration preflight; a pre-migration corpus keeps its current byte output, so the existing writer suites stay valid parity evidence.

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
  - Build the core authority on S01's codec/validator/inventory, one resolved-workspace lock, a streamed committed fingerprint, explicit snapshot limits, fresh-workspace bootstrap that mints the collection UUID at collection revision `1`, adopt-current handling of an absent fingerprint sidecar, and stopped-edit revision reconciliation; export only the shared cross-package contract.
  - **Verify**: Layer-2 temp-workspace tests prove S01, S07, and S08, including unopened omitted files; fresh-workspace bootstrap at collection revision `1` and adopt-current for an absent fingerprint sidecar with no revision advance; exactly one external-change revision advance for a topic edit, runtime-learning edit, dated-observation edit, and dated-observation deletion; changed/removed role and locator reporting; explicit invalid-edit state; stale-CAS rejection after reconciliation; and no SQLite/server/storage dependency in core.

- [ ] **TI02** Canonical mutations are all-or-nothing CAS commits
  - Validate the complete resulting S01 corpus and every bound before writing, then stage and commit all changed canonical documents through one transaction whose last canonical marker is revision-bearing `MEMORY.md`; consume TI01's reconciled revision/fingerprint state.
  - **Verify**: Controlled component tests prove S02–S05 plus S08's initial-commit leg: exactly one revision advance for a multi-file change, no staging for invalid output, one winner under same-revision contention, unchanged bytes/fingerprint/index on every injected pre-marker failure, a successful single-advance retry, and a fresh workspace whose minted initial canonical state is published by this same staged transaction with revision-bearing `MEMORY.md` written last and no second revision advance.

- [ ] **TI03** Interrupted corpus commits recover before any reader or writer proceeds
  - Make the transaction journal, stages, backups, marker, and fingerprint finalization idempotently recoverable; use TI02's commit order and TI01's fingerprint comparison without introducing an independent revision source.
  - **Verify**: A process-reopen fault matrix proves S05–S07 at every real transition: old-complete before the marker, new-complete after it, no mixed snapshot, no invented revision, recognizable artifact cleanup, and valid versus invalid stopped-edit behavior.

- [ ] **TI04** All canonical writers use the shared corpus authority
  - Delegate active-memory/daily-observation, runtime-learning, and prune/archive coherent reads and canonical changes through TI01–TI03; keep derived index replacement post-commit, drain accepted work on shutdown, and synchronize affected barrels and package rules. Serialization, lock, queue, shutdown, and atomic-write delegation lands here for every listed writer; canonical rendering and validation apply only to a corpus that has passed S03's migration preflight, and a pre-migration corpus keeps its current byte output unchanged.
  - **Verify**: Core/storage/server integration tests prove S04 across real-path/symlink instances, queued shutdown preserves acknowledged writes and rejects later work, index failure preserves the committed revision, scans find no bypassing canonical replacement, package/API checks prove the stated boundaries, and focused memory/lock/atomic/queue suites remain green. The existing memory, lock, atomic-write, and queue suites stay green unmodified over a pre-migration corpus and are the parity evidence that delegation preserved byte output; canonical-rendering and validation assertions bind only to a migration-preflighted corpus.

### Testing Strategy

- [TI01,TI02,TI03] Use Layer-2 temp-directory tests with real files, the S01 codec/validator, controlled `Completer` barriers, and an injected transition hook. Table-drive validation failures, each stage/replace/marker crash point, retry, and real-path/symlink aliases; never use real-time waits.
- [TI04] Keep core service behavior at the core layer, then add narrow storage/server integration coverage for pruner index ordering and runtime-learning delegation. Existing suites are parity evidence only; the new CAS/crash scenarios require new red-first tests whose assertions name canonical bytes, revision, fingerprint, and result state.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS mutability contract. Spec authors leave this section empty._

#### DECISION NOTE: empty-workspace-bootstrap

Decision-Key: empty-workspace-bootstrap
Altitude: fis-local
Affected surface: Technical Overview (authority open path), Acceptance Scenarios (new fresh-workspace scenario S08), Implementation Plan TI01 task line and TI01 Verify
Decision: The S02 corpus authority owns bootstrap. Opening a workspace that holds no canonical corpus and no transaction journal mints the collection UUID at collection revision `1` and commits it as the initial canonical state. A MISSING committed-fingerprint sidecar over an otherwise valid corpus is adopt-current – the recomputed fingerprint is recorded at the unchanged revision – and only a PRESENT-and-differing sidecar is a stopped-edit mismatch, so first open never produces a spurious revision advance.
Rationale: Bootstrap and sidecar absence are open-path states of the single revision/mutation authority; leaving them to a consumer story or to each caller would create a second revision source. Treating an absent sidecar as a mismatch would advance the revision on every first open of an untouched corpus, contradicting OC02's exactly-once advance and S07's stopped-edit semantics.
Evidence: dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md#constraints--gotchas – collection revisions start at `1` and only S02 advances the collection revision; dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus – files are canonical, so a fresh workspace must reach a valid canonical state through this authority.

Old:
```
Opening the authority resolves the workspace root, acquires one corpus lock key, recovers an unfinished transaction, and streams the complete S01 inventory within finite scan bounds to reconcile the committed fingerprint.
```
New:
```
Opening the authority resolves the workspace root, acquires one corpus lock key, recovers an unfinished transaction, and streams the complete S01 inventory within finite scan bounds to reconcile the committed fingerprint. This authority also owns bootstrap: a workspace holding no canonical corpus and no transaction journal mints the collection UUID at collection revision `1` and commits it as the initial canonical state. A missing committed-fingerprint sidecar over an otherwise valid corpus is adopted as current – the recomputed fingerprint is recorded at the unchanged revision – and only a present-and-differing sidecar is a stopped-edit mismatch, so first open never advances a revision by itself.
```

Old:
```
and rejects a subsequent mutation still expecting revision `16`; an invalid edit instead leaves bytes and revision untouched and reports recovery-required
```
New:
```
and rejects a subsequent mutation still expecting revision `16`; an invalid edit instead leaves bytes and revision untouched and reports recovery-required

- [ ] **S08 [OC01,OC02,OC03] [TI01,TI02] A fresh workspace bootstraps at revision `1` and a missing fingerprint sidecar adopts the current corpus**
  - **Given** independently a resolved workspace holding no canonical corpus, no committed-fingerprint sidecar and no transaction journal; a valid committed revision-`17` corpus whose fingerprint sidecar has been deleted; and that same revision-`17` corpus with a present sidecar recording a different fingerprint
  - **When** a fresh authority opens each workspace and then serves a snapshot
  - **Then** the empty workspace holds one minted collection UUID at collection revision `1` committed as the initial canonical state, the sidecar-less corpus keeps every canonical byte at revision `17` with its recomputed fingerprint recorded and no changed-role report, neither of those cases reports a fingerprint mismatch, and only the present-and-differing sidecar takes the stopped-edit reconciliation path
```

Old:
```
  - Build the core authority on S01's codec/validator/inventory, one resolved-workspace lock, a streamed committed fingerprint, explicit snapshot limits, and stopped-edit revision reconciliation; export only the shared cross-package contract.
```
New:
```
  - Build the core authority on S01's codec/validator/inventory, one resolved-workspace lock, a streamed committed fingerprint, explicit snapshot limits, fresh-workspace bootstrap that mints the collection UUID at collection revision `1`, adopt-current handling of an absent fingerprint sidecar, and stopped-edit revision reconciliation; export only the shared cross-package contract.
```

Old:
```
  - **Verify**: Layer-2 temp-workspace tests prove S01 and S07, including unopened omitted files; exactly one external-change revision advance for a topic edit, dated-observation edit, and dated-observation deletion; changed/removed role and locator reporting; explicit invalid-edit state; stale-CAS rejection after reconciliation; and no SQLite/server/storage dependency in core.
```
New:
```
  - **Verify**: Layer-2 temp-workspace tests prove S01, S07, and S08, including unopened omitted files; fresh-workspace bootstrap at collection revision `1` and adopt-current for an absent fingerprint sidecar with no revision advance; exactly one external-change revision advance for a topic edit, dated-observation edit, and dated-observation deletion; changed/removed role and locator reporting; explicit invalid-edit state; stale-CAS rejection after reconciliation; and no SQLite/server/storage dependency in core.
```

#### DECISION NOTE: legacy-writer-delegation-interim

Decision-Key: legacy-writer-delegation-interim
Altitude: fis-local
Affected surface: Technical Overview (writer delegation paragraph), Implementation Plan TI04 task line, TI04 Verify
Decision: Every existing canonical writer delegates serialization, locking, queueing, shutdown, and atomic-write discipline to the corpus authority in this story. Canonical rendering and validation activate only for a corpus that has passed S03's migration preflight; a pre-migration corpus keeps its current byte output, so the existing writer suites remain valid parity evidence and new canonical-rendering assertions bind only to migration-preflighted corpora.
Rationale: Serialization and crash discipline are what the single-authority outcome (OC04) buys and they are byte-neutral, so they can land immediately. Forcing canonical rendering onto a corpus that has not been migrated yet would rewrite legacy bytes ahead of the lossless migration that owns that conversion, breaking the existing writer suites as parity evidence and destroying the very content S03 must preserve.
Evidence: dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#scope--boundaries – legacy discovery, backup conversion, and opaque-content migration are explicitly not this story's work and S03 consumes this authority; dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#testing-strategy – existing suites are parity evidence only, which requires their byte expectations to keep holding.

Old:
```
Closing the authority drains accepted operations and rejects new ones, reusing the existing bounded-queue discipline rather than adding another scheduler.
```
New:
```
Closing the authority drains accepted operations and rejects new ones, reusing the existing bounded-queue discipline rather than adding another scheduler. Existing canonical writers delegate serialization, locking, queueing, shutdown, and atomic-write discipline to this authority in this story, while canonical rendering and validation activate only for a corpus that has passed S03's migration preflight; a pre-migration corpus keeps its current byte output, so the existing writer suites stay valid parity evidence.
```

Old:
```
  - Delegate active-memory/daily-observation, runtime-learning, and prune/archive coherent reads and canonical changes through TI01–TI03; keep derived index replacement post-commit, drain accepted work on shutdown, and synchronize affected barrels and package rules.
```
New:
```
  - Delegate active-memory/daily-observation, runtime-learning, and prune/archive coherent reads and canonical changes through TI01–TI03; keep derived index replacement post-commit, drain accepted work on shutdown, and synchronize affected barrels and package rules. Serialization, lock, queue, shutdown, and atomic-write delegation lands here for every listed writer; canonical rendering and validation apply only to a corpus that has passed S03's migration preflight, and a pre-migration corpus keeps its current byte output unchanged.
```

Old:
```
  - **Verify**: Core/storage/server integration tests prove S04 across real-path/symlink instances, queued shutdown preserves acknowledged writes and rejects later work, index failure preserves the committed revision, scans find no bypassing canonical replacement, package/API checks prove the stated boundaries, and focused memory/lock/atomic/queue suites remain green.
```
New:
```
  - **Verify**: Core/storage/server integration tests prove S04 across real-path/symlink instances, queued shutdown preserves acknowledged writes and rejects later work, index failure preserves the committed revision, scans find no bypassing canonical replacement, package/API checks prove the stated boundaries, and focused memory/lock/atomic/queue suites remain green. The existing memory, lock, atomic-write, and queue suites stay green unmodified over a pre-migration corpus and are the parity evidence that delegation preserved byte output; canonical-rendering and validation assertions bind only to a migration-preflighted corpus.
```

#### DECISION NOTE: learnings-fingerprint-membership

Decision-Key: learnings-fingerprint-membership
Altitude: fis-local
Affected surface: Expected Outcomes OC04, Structural Criteria (criterion 4), Acceptance Scenario S07 title and Given, Implementation Plan TI01 Verify
Decision: Runtime learnings are a canonical S01 role, therefore fully inside this story's committed-fingerprint, collection-revision, and corpus-validation contract. Runtime-learning writers are named in the single-authority outcome, the runtime-learning role participates in the fingerprint/revision/validation contract exactly like the other canonical roles, and a stopped-runtime learnings edit is a supported reconciliation case that advances the host-owned revision once, like any other canonical document.
Rationale: The ratified cross-cutting decision makes learnings a canonical role with stable identity, validation, revision, and fingerprint participation, superseding the earlier premise that `learnings.md` retains a native format and identity. Any surface here that enumerates canonical writers, coherent state, or supported stopped-runtime edits without learnings would leave a dual-format special case inside the single mutation authority – the exact failure mode the decision removes – and would let an out-of-band learnings edit escape fingerprint detection.
Evidence: dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md#architecture-decision – the canonical role inventory and codec/validator scope this story consumes; dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus – no canonical content may exist only in a derived database, so every canonical role must be covered by the file-level corpus contract.

Old:
```
Existing and later observation, memory, curation, and maintenance writers use one mutation, serialization, lock, and shutdown authority.
```
New:
```
Existing and later observation, memory, runtime-learning, curation, and maintenance writers use one mutation, serialization, lock, and shutdown authority, and the runtime-learning role sits inside the same fingerprint, revision, and validation contract as every other canonical role.
```

Old:
```
All production canonical-file reads and writes that require coherent index/topic/archive/observation/runtime-learning state cross the same normalized workspace authority; `errors.md`, wiki, and temporal-KG writes remain outside this corpus contract.
```
New:
```
All production canonical-file reads and writes that require coherent index/topic/archive/observation/runtime-learning state cross the same normalized workspace authority, and the runtime-learning role participates in the committed fingerprint, collection revision, and corpus validation exactly like the other canonical roles; `errors.md`, wiki, and temporal-KG writes remain outside this corpus contract.
```

Old:
```
Supported stopped-runtime topic and observation changes advance the host-owned revision before CAS resumes
```
New:
```
Supported stopped-runtime topic, runtime-learning, and observation changes advance the host-owned revision before CAS resumes
```

Old:
```
  - **Given** clean committed revision `16`, then independently a manual topic edit, a dated observation-partition edit, and deletion of a dated observation partition while DartClaw is stopped and no transaction journal exists
```
New:
```
  - **Given** clean committed revision `16`, then independently a manual topic edit, a manual runtime-learning edit, a dated observation-partition edit, and deletion of a dated observation partition while DartClaw is stopped and no transaction journal exists
```

Old:
```
exactly one external-change revision advance for a topic edit, dated-observation edit, and dated-observation deletion;
```
New:
```
exactly one external-change revision advance for a topic edit, runtime-learning edit, dated-observation edit, and dated-observation deletion;
```

#### DECISION NOTE: deletion-audit-role

Decision-Key: deletion-audit-role
Altitude: fis-local
Affected surface: Expected Outcomes OC04; Structural Criteria (coherent-state criterion); Technical Overview (mutation paragraph – audit staging/commit clause)
Decision: The deletion-audit document is an ordinary canonical document of this authority: deletion-audit writers are named in the single-authority outcome, the deletion-audit role participates in the committed fingerprint, collection revision, and corpus validation exactly like every other canonical role, and an audit document is rendered, validated, staged, and committed inside the same transaction and the same single revision advance as the canonical change it records – never a side file and never a separate write.
Rationale: Owner-ratified preflight resolution consuming S01's new `audit` role – any enumeration of coherent canonical state or canonical writers that omits the audit document leaves it outside the fingerprint/revision/validation contract, which is exactly the side-file implementation the ratified audit decision forbids; keeping it inside the transaction makes crash atomicity fall out of the existing marker/journal contract.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), item 43 deletion-audit-role (consequence of item 21) and item 21 deletion-audit-persistence; OC04, the coherent-state Structural Criterion, and the Technical Overview mutation paragraph already state it; therefore this note carries zero `Old:`/`New:` pairs.

#### DECISION NOTE: verbatim-inventory-member

Decision-Key: verbatim-inventory-member
Altitude: fis-local
Affected surface: Technical Overview (authority-open paragraph – fingerprint scope sentence)
Decision: The S01 inventory this authority streams and fingerprints is the union of both S01 member classes – the codec-rendered canonical documents, including the deletion-audit document, and the verbatim members preserving opaque legacy bytes under `memory/legacy/` – so the committed fingerprint covers preserved legacy content and a stopped-runtime edit to it is detectable drift.
Rationale: Owner-ratified preflight resolution consuming S01's two-class inventory – S03's preserved opaque content sits outside the validator but inside the fingerprint, which only holds if this story's fingerprint scope is the union rather than the canonical-document class alone; a canonical-only scope would make the ratified drift detection non-existent.
Evidence: Preflight 0.24 ratified resolutions (owner-approved 2026-08-11), item 44 verbatim-inventory-member (consequence of item 9 opaque-content-placement); the Technical Overview authority-open paragraph already states the union scope and its drift consequence; therefore this note carries zero `Old:`/`New:` pairs.
