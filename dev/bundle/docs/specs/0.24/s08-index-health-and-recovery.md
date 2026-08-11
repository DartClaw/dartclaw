# Feature Implementation Specification: Index Health and Recovery

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S08

## Feature Overview and Goal

**Intent**: Keep canonical memory trustworthy and usable when its disposable search index is stale, missing, corrupt, or
temporarily unrecoverable, without presenting absence of evidence as health.

**Expected Outcomes**:

- [OC01] Operators and runtime consumers can distinguish `healthy`, `degraded`, `rebuilding`, and `unknown` index state,
  including a genuinely empty healthy index versus unavailable counts.
- [OC02] A successful canonical commit remains durable when indexing fails, persists an actionable degraded result, and
  returns to healthy only after the complete current canonical union validates against the replacement index.
- [OC03] Deleted, corrupt, and stale derived indexes recover through a validated fresh sibling and atomic target swap;
  any failed attempt preserves canonical files and the prior target bytes or prior absence.
- [OC04] Supported stopped-runtime canonical edits are revision-reconciled and indexed before prompt, search, or status
  can describe the current collection as healthy.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.7` – S08 scope, dependency, risk, source references, assets, and
  deleted-index startup note.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` – file-canonical corpus, single revision/mutation authority,
  stable locator, stopped-edit reconciliation, and release-simplicity contracts shared with S08.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints` – applicable FR5 natural-query ownership, FR6
  fresh-sibling replacement, FR8 simplicity, and trusted-host fault boundary.
- `dev/bundle/docs/specs/0.24/prd.md#fr5-retrieval-citation-and-index-integrity` – separate canonical/index outcomes,
  exact live/rebuilt convergence, health clearing, and no fabricated zero status.
- `dev/bundle/docs/specs/0.24/prd.md#fr6-maintenance-limits-and-recovery` – fresh-sibling rebuild, validation, atomic
  replacement, target preservation, missing-index startup, and transition-targeted fault proof.
- `dev/bundle/docs/specs/0.24/prd.md#fr7-operator-control-and-observability` – collection revision, current health,
  last reconciliation, stopped-edit, empty/degraded/zero-result distinctions, and recovery action contract.
- `dev/bundle/docs/specs/0.24/prd.md#user-flows` – canonical-success/index-degraded recovery and stopped-runtime edit
  journeys.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – no new package, database, daemon,
  scheduler, provider abstraction, QMD memory semantics, or wiki/KG write expansion.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – single-isolate runtime, existing lock/atomic-write reuse, trusted
  host, plausible crash, cooperating concurrency, and ordinary resource-failure boundary.
- `dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#architecture-decision` – one reconciled collection revision,
  full-union fingerprint, shared lock, stopped-edit detection, and canonical-before-derived ordering.
- `dev/bundle/docs/specs/0.24/s03-lossless-memory-migration.md#acceptance-scenarios` – canonical migration/reconciliation
  must finish and report before either derived-index boundary activates.
- `dev/bundle/docs/specs/0.24/s05-atomic-memory-apply.md#architecture-decision` – canonical apply success precedes
  derived reconciliation and must report index failure independently.
- `dev/adrs/002-file-based-storage.md#key-design-choices` – canonical files remain authoritative and `search.db` remains
  disposable and reconstructable.
- `dev/architecture/data-model.md#memory-chunk-search-index` – current FTS5 row ownership, owner scope, canonical
  sources, normalization inputs, and rebuild relationship.
- `dev/architecture/data-model.md#backup--recovery` – current `search.db` recovery promise and distinction from
  authoritative databases.
- `dev/architecture/observability-operations-architecture.md#3-health-monitoring` – existing health aggregation seam and
  public status vocabulary that index health must augment truthfully.

## Deeper Context

- `dev/bundle/docs/specs/0.24/memory-architecture-recommendations.md#architecture-fitness-functions-and-tests` – exact
  derivability, corrupt/deleted recovery, degraded-clear, provenance, and portability fitness expectations.
- `dev/guidelines/TESTING-STRATEGY.md#data-integrity` – persistent state transitions require restart and failure coverage.
- `dev/state/learnings/tooling-verification.md#tooling--verification` – injected failures must occur at the claimed
  write, validation, close, and swap transitions.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI05] A validated empty canonical union is healthy with exact zero counts**
  - **Given** a valid reconciled collection containing no indexable canonical rows and a derived index validated against
    that same collection revision and fingerprint
  - **When** runtime and operator status read index health and counts
  - **Then** state is `healthy`, indexed and canonical revisions agree, counts are numeric zero, and zero results remain
    distinguishable from an unavailable status probe

- [ ] **S02 [OC01] [TI01,TI05] Failed health or count collection is unknown rather than healthy zero**
  - **Given** an injected failure reading persisted reconciliation evidence, validating the target, or counting rows
  - **When** status is collected
  - **Then** state or the affected field is `unknown`, counts are absent rather than zero, the reason identifies the
    unavailable evidence and repair action, and no caller derives `healthy` from the fallback

- [ ] **S03 [OC02] [TI01,TI02,TI05] Canonical success with index failure persists degradation until exact repair**
  - **Given** collection revision `41` is healthy and an S05 apply has a controlled index failure after canonical
    revision `42` commits
  - **When** the apply result, a fresh process status read, a partial index retry, and then a complete reconciliation are
    observed
  - **Then** canonical revision `42` and its exact changed IDs remain durable, the result and persisted status report
    canonical success plus `degraded` index with the failing stage and repair action, restart and partial retry remain
    degraded, and only validated parity for the complete revision-`42` union records last success and clears health
  - **Proof**: `packages/dartclaw_storage/test/memory/memory_pruner_test.dart#index failure leaves source retryable and retry creates one archive index row` – green – parity/regression for canonical durability and retry

- [ ] **S04 [OC01,OC03] [TI01,TI02,TI05] An active full reconciliation is rebuilding, never prematurely healthy**
  - **Given** a controlled barrier after a full reconciliation has acquired the shared authority and begun writing its
    fresh sibling while the previous validated target remains available
  - **When** health is observed before validation and swap complete
  - **Then** state is `rebuilding`, the current canonical revision and last validated index revision remain visible, no
    consumer labels the old index current, and success or failure settles to `healthy` or `degraded` respectively;
    an interrupted prior attempt does not reopen as still actively rebuilding

- [ ] **S05 [OC02,OC04] [TI02,TI03] Supported stopped-runtime topic and observation changes reconcile before healthy index use**
  - **Given** collection revision `51` and a healthy matching index, followed independently by a supported manual topic
    edit, a dated observation-partition edit, and deletion of a dated observation partition while the runtime is stopped
  - **When** startup runs the S03/S02 canonical preflight and then initializes derived search for each case
  - **Then** the change validates and advances the canonical collection exactly once to revision `52`, the full derived
    index reconciles to that revision before it can be described as healthy, edited observation rows match the new source,
    deleted-observation rows and locators are absent, and invalid edits instead leave canonical bytes and the previous
    target untouched while reporting non-healthy recovery-required state

- [ ] **S06 [OC03,OC04] [TI02,TI03,TI06] Deleted-index startup cannot manufacture a healthy empty database**
  - **Given** valid canonical revision `61` contains a uniquely locatable entry with exact topic, revision, provenance,
    timestamp, normalized chunks, and owner scope, but `search.db` is absent
  - **When** storage startup runs
  - **Then** absence is detected before any target-opening factory can create an empty database, startup uses the shared
    reconstructive reconciliation path, and health becomes `healthy` only after the replacement contains the exact
    canonical projection at revision `61`; rebuild failure remains non-healthy and actionable

- [ ] **S07 [OC02,OC03] [TI02,TI04,TI06] Corrupt-index rebuild swaps only a closed and completely validated sibling**
  - **Given** `search.db` contains random corrupt bytes or a previously valid older index, plus canonical files whose
    complete expected row multiset is known
  - **When** `dartclaw rebuild-index` runs with failures injected independently after sibling creation, after real row
    population, during database/FTS validation, after validation but before close, and at atomic replacement
  - **Then** the corrupt target is never opened as a prerequisite, success validates database/FTS integrity and exact
    row identity/provenance parity, closes the sibling, atomically swaps it, removes recognizable temporary artifacts,
    and records healthy; every failed run preserves all canonical bytes and the target's exact prior bytes or absence,
    persists degraded recovery guidance, and succeeds without duplicates when retried
  - **Proof**: `packages/dartclaw_storage/test/storage/memory_service_test.dart#rebuildIndex retains the previous index when replacement fails` – green – parity/regression for transactional row preservation

## Structural Criteria

- [ ] Canonical Markdown, S02 collection revision, and S02 full-union fingerprint remain authoritative; index-health
  evidence is derived coordination state and introduces no content store, revision authority, package, or database.
- [ ] Live mutation, pruning, migration, startup reconciliation, and full rebuild use one canonical-to-index projection;
  validation compares the complete scoped row multiset, including every identity, locator, role/topic, entry revision,
  provenance/source reference, timestamp, normalized chunk, and `userId` supplied by the prerequisite contract.
- [ ] Rebuild creates its sibling in the target directory, validates and closes it before replacement, never opens
  corrupt target bytes to construct the replacement, and leaves safely recognizable interrupted artifacts.
- [ ] FTS5 remains the 0.24 derived-index recovery target; QMD receives no health authority, canonical schema,
  reconciliation state, rebuild behavior, or other new semantics.
- [ ] Existing canonical mutation/recovery locking and atomic-file conventions remain the only cooperating-concurrency
  authority; tests do not add POSIX-only commands, timing waits, or Windows skips to prove filesystem safety.

## Scope & Boundaries

### Work Areas

- S02 canonical corpus coordination and derived-index health evidence
- `packages/dartclaw_storage/lib/src/storage/search_db.dart` and `memory_service.dart` – target inspection, fresh-sibling
  construction, exact validation, replacement, and shared reconciliation
- `apps/dartclaw_cli/lib/src/commands/wiring/storage_wiring.dart` – canonical preflight, missing/corrupt/stale detection,
  and startup health gate before ordinary index activation
- `apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart` – offline recovery through the shared reconstructive path
- `packages/dartclaw_server/lib/src/memory/memory_status_service.dart` – truthful health/count status contract for later
  S11 presentation
- Core/storage/server/CLI recovery, startup, status, and portable fault tests

### What We're NOT Doing

- Designing S11's Memory/Knowledge UI, dashboards, CLI presentation, or curation lifecycle – this story supplies the
  truthful state and basic status data those surfaces consume.
- Changing natural-language query encoding, ranking, result composition, or citation consumers – S07 owns search and
  citation convergence; S08 only preserves the prerequisite row projection exactly.
- Adding PostgreSQL, a database abstraction, a new package/database/daemon/scheduler, or changing canonical memory into
  derived storage – those violate the 0.24 boundary and belong to later milestones if accepted.
- Extending QMD health, indexing, schema, fallback, or deprecation behavior – existing compatibility remains unchanged.
- Changing canonical migration, apply, pruning, prompt budgeting, wiki, KG, or observation semantics – their owning
  stories provide inputs to this recovery seam.

## Architecture Decision

**Approach**: Extend S02's existing corpus coordination authority with one persisted derived-index reconciliation result, and make storage startup plus `rebuild-index` share a fresh-sibling builder/validator/swap path keyed to the current collection revision and fingerprint.
**Why this over alternatives**: In-place repair cannot recover unreadable bytes and DB-owned health disappears with the index; a separate store or QMD-specific path would duplicate authority and broaden the release.

## Technical Overview

S03/S02 canonical startup preflight runs before any `search.db` open, yielding the current validated collection revision,
fingerprint, and exact index projection. Index health compares those facts with the last completely validated target;
known divergence is degraded, active reconciliation is rebuilding, and unavailable evidence is unknown. A reconciler
populates a uniquely recognizable sibling beside `search.db`, validates SQLite/FTS integrity plus the complete expected
row multiset, closes it, and atomically replaces the target. The live post-commit hook and offline command use this same
path. Health records canonical success independently, persists failure reason and safe action, and clears only after the
current full union validates – never after a partial write or count succeeds.

## Code Patterns & External References

```
# type | path#anchor | why needed (intent)
file | packages/dartclaw_storage/lib/src/storage/memory_service.dart#MemoryService.rebuildIndex | Reuse canonical normalization and transaction rollback; move full recovery outside an in-place target transaction
file | packages/dartclaw_storage/lib/src/storage/search_db.dart#openSearchDb | Existing injectable DB-open seam for proving target-versus-sibling paths
file | apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand.run | Current three-source offline command and target-in-place behavior to replace with shared recovery
file | apps/dartclaw_cli/lib/src/commands/wiring/storage_wiring.dart#StorageWiring.wire | Current startup opens/creates search.db before canonical/index reconciliation
file | packages/dartclaw_server/lib/src/memory/memory_status_service.dart#MemoryStatusService._getSearchStatus | Current status/count failures collapse to zero and need typed health evidence
file | packages/dartclaw_core/lib/src/concurrency/repo_lock.dart#RepoLock.acquire | Existing normalized cooperating-concurrency authority from S02
file | packages/dartclaw_core/lib/src/storage/atomic_write.dart#secureWriteFile | Existing same-directory sibling/atomic-replacement convention for file-backed coordination evidence
test | apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart | Green three-source normalization, timestamp, empty-corpus, and symlink parity fixtures to retain
test | apps/dartclaw_cli/test/commands/serve_command_test.dart#search database open failure prints clear startup error | Green startup failure-reporting seam to preserve while adding pre-open recovery
test | packages/dartclaw_server/test/memory/memory_status_service_test.dart#search status | Current count/status contract to make truthful without inventing zero
```

## Constraints & Gotchas

- **Health semantics**: `healthy` requires current canonical revision/fingerprint, successful complete row-parity and
  SQLite/FTS validation; `degraded` means a known mismatch/failure; `rebuilding` means work is active now; `unknown`
  means evidence could not be established. A stale interrupted marker is never proof of active rebuilding.
- **Persistent degradation**: Record canonical revision/fingerprint, last validated index revision/fingerprint and time,
  failure stage/reason, and safe next action through S02's coordination seam. If recording or reading evidence fails,
  report unknown – never healthy.
- **Clear rule**: Only complete reconciliation against a newly captured current canonical union may clear degradation.
  Row counts, partial retries, target open success, or a prior revision's validation are insufficient.
- **Pre-open detection**: Check target existence/type and canonical/index evidence before the normal SQLite factory can
  create a missing empty file. A valid empty corpus still reaches healthy through the same reconstruction and validation.
- **Swap portability**: Close every sibling/target handle before replacement and inject filesystem operations for tests;
  use temp directories and Dart APIs rather than shell `stat`, `chmod`, sleeps, or platform-specific skips.
- **Settled failed-startup behavior**: If no usable prior target exists and fresh validation/swap fails, startup fails
  closed after persisting/reporting degraded recovery guidance; this story does not invent an empty fallback backend.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Index health has one truthful and durable state contract
  - Reuse S02's coordination seam for revision/fingerprint evidence and expose exact `healthy`, `degraded`, `rebuilding`,
    and `unknown` semantics, last validated reconciliation, failure stage/reason, and safe action without adding a store.
  - **Verify**: Focused transition/reopen tests prove S01–S04, including valid empty zero, unavailable nullable counts,
    persisted post-commit degradation, interrupted rebuilding recovery, and the complete-reconciliation-only clear rule.

- [ ] **TI02** Canonical reconciliation produces one completely validated current index
  - Consume S02's current revision, fingerprint, and canonical projection plus S05's canonical-commit outcome under the
    shared authority; populate and validate a fresh index before publishing success, preserving every prerequisite
    identity/provenance field exactly.
  - **Verify**: Component tests prove S03–S07 by comparing the complete expected/actual scoped row multiset and health
    evidence after live apply, migration/prune parity, stopped-runtime topic and observation edits, stopped-runtime
    observation deletion with stale-row removal, partial retry, full reconciliation, empty corpus, and validation failure.

- [ ] **TI03** Startup exposes no derived index as healthy before canonical and index reconciliation
  - Order `StorageWiring.wire` after S03/S02 preflight, detect missing/corrupt/stale targets before normal target open,
    and use TI02 recovery before constructing ordinary search consumers or reporting current health.
  - **Verify**: Production-shaped startup tests prove S05–S06 with supported/invalid topic edits, dated-observation edits,
    dated-observation deletion, an absent target plus nonempty canonical corpus, a valid empty corpus, random corrupt
    bytes, exact ordering barriers, and no prompt/search/status consumer observing healthy before reconciliation settles.

- [ ] **TI04** Offline rebuild is reconstructive and preserves prior safe state
  - Make `RebuildIndexCommand` delegate to TI02's sibling/validate/close/swap path and return the canonical revision,
    exact indexed-row outcome, resulting health, and actionable failure while retaining the stopped-runtime precondition.
  - **Verify**: CLI tests prove S07 for corrupt, deleted, older-valid, empty, and archive/learning-inclusive targets;
    success reopens the swapped target at exact parity and failure leaves target/canonical bytes unchanged before retry.

- [ ] **TI05** Runtime and operator status preserve health uncertainty
  - Feed TI01 evidence into the existing memory-status seam so successful zero, stale prior counts, active rebuild, known
    degradation, and unavailable collection/count evidence remain distinct; leave S11 presentation expansion downstream.
  - **Verify**: Service and API tests prove S01–S04: all four states serialize with revisions/reason/action, count/read
    exceptions yield unknown/null rather than zero, and canonical-success/index-degraded survives a service restart.

- [ ] **TI06** Recovery faults prove the real portable transitions
  - Add table-driven temp-workspace seams around sibling create/populate/validate/close/swap and health publication, using
    real file-backed SQLite for parity and injected failures only at the named transitions.
  - **Verify**: The matrix proves S06–S07 without sleeps, shell filesystem commands, or platform skips; each failure
    asserts canonical bytes, target bytes/absence, health, sibling cleanup, retry convergence, closed handles, and exact
    source identity/provenance; dependency/reference scans prove no new package, database, or QMD semantics, and focused
    core/storage/server/CLI plus workspace gates pass on supported CI platforms.

### Testing Strategy

- [TI01] Use focused state-transition tests for exhaustive enum/result serialization and reopen semantics; persisted
  evidence uses a per-test temp workspace, not process-global state.
- [TI02,TI03,TI04,TI06] Use Layer-2 component tests with real canonical files and file-backed SQLite. Inject DB/file
  operations and controlled `Completer` barriers, never time delays; random corrupt bytes must be recovered without a
  target-open call, while a valid older target remains byte-identical after every pre-swap failure.
- [TI05] Use Layer-2 status-service and Layer-3 `/api/memory/status` handler tests for nullable counts, reason/action,
  revision, and all four states. Existing green rebuild, MemoryService rollback, pruner retry, and startup-open tests are
  parity evidence only; new S08 behavior needs red-first assertions.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS mutability contract. Spec
> authors leave this section empty._

_No observations recorded yet._
