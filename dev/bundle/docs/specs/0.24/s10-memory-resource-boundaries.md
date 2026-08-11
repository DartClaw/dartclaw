# Feature Implementation Specification: Memory Resource Boundaries

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S10

## Feature Overview and Goal

**Intent**: Make exact replay deduplication, archive mutation, canonical reads, recursive wiki/observation scans, and raw-observation usage reporting deterministic and bounded without semantic deletion, silent truncation, or a new resource framework.

**Expected Outcomes**:

- [OC01] Only a replay with the same normalized role, topic, content, and provenance source-event identity is an exact no-op; equal text from a different event and semantic similarity remain distinct.
- [OC02] Topic, archive, observation, wiki, and recursive operations enforce the fixed file-byte, regular-file, result, and aggregate-byte ceilings before unbounded work and report explicit degradation.
- [OC03] Archive limit rejection and injected commit failures leave one complete pre-change or post-change canonical revision, never a half-applied active/archive/index state.
- [OC04] `memory.max_bytes` and archive age use one positive-integer validation contract across startup, legacy, override, persisted-write, and runtime construction paths; fixed safety ceilings are constants, not configuration.
- [OC05] Operators can see aggregate raw-observation usage and time coverage, with a warning at or above 64 MiB and truthful incomplete/degraded coverage, without automatic deletion or aggregate blocking.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.9` – exact S10 scope, dependencies, medium-risk classification, parallelism, provenance-event dedup note, and named architecture assets.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions.0` – canonical-corpus contract inherited by every resource boundary.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions.1` – single revision and mutation authority for pruning, archive, and migration commits.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions.5` – authoritative source, partition, scan, best-50 output, migration batch/report, and warning ceilings plus the no-config-knob decision.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions.7` – release boundary and no-new-package/database/daemon/scheduler decision.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.0` – FR1 file-canonical authority constraint.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.1` – FR2 shared validation/mutation/lock constraint.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.5` – FR6 partition, traversal, result, and degradation bounds.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.6` – FR8 no-new-infrastructure constraint.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.7` – FR8 wiki/KG write-boundary constraint.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.8` – settled host-trust and resource-threat constraint.
- `dev/bundle/docs/specs/0.24/prd.md#fr6-maintenance-limits-and-recovery` – normative exact-dedup identity, archive/canonical preflight, fixed ceilings, raw-retention, configuration-validation, and boundary/fault requirements.
- `dev/bundle/docs/specs/0.24/prd.md#fr7-operator-control-and-observability` – aggregate observation usage/coverage and degraded-not-zero reporting contract.
- `dev/bundle/docs/specs/0.24/prd.md#edge-cases` – equal-text/different-event preservation, exact-limit/limit-plus-one behavior, unbounded raw growth, and oversized-source behavior.
- `dev/bundle/docs/specs/0.24/prd.md#data-requirements` – observation origin, caller/session reference, trust/provenance, recorded time, and truncation metadata required for identity and coverage.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – trusted-host boundary, plausible-crash atomicity, normal-operation resource limits, and prohibition on broadening wiki/KG writes.
- `dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md#architecture-decision` – canonical role/topic identity, Markdown codec, structured entry identity/revision, and provenance source-reference seam.
- `dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#architecture-decision` – sole lock/revision/atomic commit/recovery authority and bounded-snapshot contract this story must extend, not duplicate.
- `dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#implementation-plan` – preflight-before-staging, canonical commit marker, rollback/recovery, and derived-index ordering.
- `dev/bundle/docs/specs/0.24/s03-lossless-memory-migration.md#architecture-decision` – sole production owner of the 256-record migration batch, one final atomic commit, and bounded report contract that S10 consumes without reimplementation.
- `dev/bundle/docs/specs/0.24/s03-lossless-memory-migration.md#implementation-plan` – owned migration behavior tasks and tests that S10's fitness check reruns rather than duplicates.
- `dev/bundle/docs/specs/0.24/s04-observation-and-retrieval-tools.md#technical-overview` – observation provenance and the settled 65,536-character observe input, 64 KiB read response, and 5-default/50-maximum retrieval-result contracts.
- `dev/bundle/docs/specs/0.24/s05-atomic-memory-apply.md#architecture-decision` – whole-request validation, exact no-op accounting, one atomic mutation authority, and canonical-before-derived outcomes.
- `dev/bundle/docs/specs/0.24/s07-search-and-citation-convergence.md#architecture-decision` – one deterministic wiki traversal per request, per-layer degradation, best-50-after-ranking contract, and no-QMD-semantics boundary.
- `dev/bundle/docs/specs/0.24/s08-index-health-and-recovery.md#architecture-decision` – derived-index health/recovery ownership and post-canonical index-failure semantics; S10 does not build a second index recovery path.
- `dev/architecture/data-model.md#storage-mechanisms` – current memory file layout, source ownership, byte ceilings, and persistence access patterns.
- `dev/architecture/configuration-architecture.md#4-config-validation--field-metadata` – `FieldMeta`, `ConfigValidator`, API/CLI write, startup YAML, legacy key, and override validation paths.
- `dev/architecture/observability-operations-architecture.md#3-health-monitoring` – truthful status/degradation vocabulary and the existing operator health seam.
- `dev/bundle/docs/specs/0.24/memory-architecture-recommendations.md#fix-in-024` – pre-allocation bounds, deterministic dedup, isolated bad wiki files, bounded migration/reporting, and no-automatic-deletion recommendations.
- `dev/guidelines/TESTING-STRATEGY.md#data-integrity` – intent-first storage/configuration boundary test requirements.
- `dev/state/learnings/tooling-verification.md#tooling--verification` – failure injection must strike the real transition and configuration inputs arrive through multiple representations.

## Fixed Resource Contract

These are inclusive safety constants. They are not new configuration keys and are not silently clamped.

| Boundary | Exact contract |
|---|---:|
| One canonical Markdown source, including topic/archive/wiki/observation sources | 64 MiB |
| One dated raw-observation partition | 8 MiB; a limit-plus-one append rejects without trimming prior records |
| One recursive request | 1,000 regular files and 64 MiB aggregate |
| One search response | Best 50 after ranking every candidate admitted by the request's scan budget |
| One migration working batch | 256 parsed records; batches never become separately visible corpus commits |
| One migration operator report | 100 diagnostics and 64 KiB UTF-8, with total and omitted counts when truncated |
| Aggregate raw-observation usage warning | warning begins at 64 MiB; it never blocks or deletes |
| One `memory_observe` input | preserve S04's 65,536-character ceiling |
| One `memory_read` response | preserve S04's 64 KiB UTF-8 response ceiling |

`memory.max_bytes` remains a separate prompt-index budget with its 32 KiB default. Archive age retains its 90-day default. Both configurable values accept positive integers only through every load/write/construction path; the fixed ceilings above do not become config fields.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01] An exact replay is a canonical no-op only when its complete normalized identity matches**
  - **Given** topic entry E at revision `12` with role `topic`, canonical topic `project-falcon`, content `Project  Falcon\nlaunched`, and provenance `{origin: user-turn, locator: session/sess-7, caller: chat, session: sess-7, sourceEventId: turn-42/message-3}`
  - **When** the same operation is replayed with content `  Project Falcon launched  ` and every other identity component unchanged
  - **Then** normalization trims outer whitespace and replaces every internal whitespace run matched by `RegExp(r'\s+')` with one ASCII space, comparison remains case-sensitive, E keeps its ID/revision/bytes, the collection revision does not advance, and no index write occurs
  - **And** the result reports E as an exact no-op rather than as a newly created or deleted entry

- [ ] **S02 [OC01] [TI01] Equal or semantically similar content from a distinct source event remains distinct**
  - **Given** E from S01 plus otherwise identical candidates that change, one at a time, the role, canonical topic, provenance origin/locator/caller/session, or `sourceEventId`, and a candidate that paraphrases E
  - **When** pruning or apply evaluates those candidates
  - **Then** none is exact-deduplicated against E, deterministic ordering retains each distinct entry, and semantic equivalence is left exclusively to explicit model curation
  - **And** timestamps, generated IDs, or equal normalized text alone never substitute for provenance-event identity or authorize deletion

- [ ] **S03 [OC02,OC03] [TI02] Archive capacity is preflighted before the sole atomic corpus commit**
  - **Given** an active entry selected for archive and snapshots of active bytes, archive bytes, collection revision, and derived-index rows
  - **When** the complete prospective archive is exactly 64 MiB
  - **Then** one S02 commit may move the entry, advance the revision once, and update the derived index only after canonical success
  - **But when** the prospective archive is 64 MiB+1 byte
  - **Then** the request fails before staging or replacing any canonical file, identifies the archive's current/projected/limit bytes, and leaves every captured byte, revision, and index row unchanged
  - **And when** faults strike the real commit transition after staging, after the first canonical replacement, and after the canonical commit marker but before index convergence
  - **Then** recovery exposes one complete old or new canonical revision, never a split active/archive state; only the post-commit index fault reports committed canonical state with S08 degraded/rebuild guidance

- [ ] **S04 [OC02] [TI03] Direct and recursive readers enforce file, count, aggregate, and output boundaries before body allocation**
  - **Given** canonical topic, archive, observation, and wiki sources at exactly 64 MiB and matching sources at 64 MiB+1 byte
  - **When** each direct reader validates them
  - **Then** exact-limit sources are eligible, limit-plus-one sources are rejected or skipped before body allocation, and the result identifies role, locator, observed bytes, 64 MiB limit, and degraded/partial coverage
  - **And given** a deterministic recursive request with 1,000 regular files whose admitted bodies total exactly 64 MiB, at least 51 matches, and the highest-ranked match at the last admitted path
  - **When** wiki search, wiki lint/validation, observation/status traversal, or another named memory-recursive consumer processes it
  - **Then** at most 1,000 bodies and 64 MiB are processed, every admitted candidate is ranked with the final comparator, the highest-ranked late-path match remains in the best 50 returned results, and exact scan-budget exhaustion carries explicit coverage truncation rather than healthy completeness
  - **But when** a 1,001st regular file or one additional aggregate byte is present
  - **Then** that work is not body-read, traversal stops at the breached ceiling, and the outcome reports the exhausted limit, processed files/bytes/results, and omitted count when knowable
  - **And** an unreadable or oversized wiki file degrades only the wiki layer and does not discard accepted healthy results or fail other retrieval layers

- [ ] **S05 [OC04] [TI04] Configurable memory integers are validated identically through every path**
  - **Given** `memory.max_bytes` with default 32 KiB and `memory.pruning.archive_after_days` with default 90 days
  - **When** either is supplied as `1`, its existing default, `0`, `-1`, a fraction, wrong type, or a numeric representation outside the accepted integer domain through nested startup YAML, legacy `memory_max_bytes`, CLI override, API/CLI config-set write, and direct typed runtime service construction
  - **Then** positive integers are accepted identically, every invalid value returns the same field-specific positive-integer/range error, config-set leaves the file byte-for-byte unchanged, and startup/runtime construction does not silently clamp or fall back
  - **And** defaults apply only when a field is absent, never when it is present but invalid
  - **And** canonical/partition/recursive/result/warning constants are absent from writable config metadata and attempts to write invented keys are rejected as unknown

- [ ] **S06 [OC02,OC05] [TI05] Raw observations stop at partition limits and expose truthful aggregate usage without deletion**
  - **Given** a dated raw-observation partition exactly at 8 MiB, older partitions, and snapshots of every raw file
  - **When** another accepted-size S04 observation would make the current partition 8 MiB+1 byte
  - **Then** the append is rejected before mutation with current/projected/limit bytes; no oldest record or partition is trimmed, rotated away, or deleted
  - **And given** aggregate observation files totalling 64 MiB-1 byte, exactly 64 MiB, and 64 MiB+1 byte in separate cases
  - **When** status scans them within the 1,000-file/64-MiB per-request traversal budget
  - **Then** the first reports no usage warning, the latter two report a warning, none blocks later writes solely because of aggregate usage, and exact coverage reports aggregate bytes plus oldest/newest recorded time
  - **But when** more than 1,000 files, more than 64 MiB to inspect, an unreadable file, or a malformed record prevents exact coverage
  - **Then** status reports degraded/incomplete lower-bound usage, scanned versus omitted/failed coverage, known oldest/newest bounds, and the warning whenever known usage has reached 64 MiB instead of `0` or a fabricated exact total
  - **And** status inspection itself never deletes or rewrites observations; user deletion remains explicit and is documented by S12

## Structural Criteria

- [ ] Exact replay identity is the tuple `(canonical role, canonical topic-or-absence, case-sensitive whitespace-normalized content, complete provenance source-event identity)`; semantic similarity, equal text alone, timestamp, and generated ID are excluded.
- [ ] Pruning and archive mutation call S02's one corpus service, lock, revision, preflight, atomic commit, recovery, and derived-index outcome seam; no direct multi-file writer or second transaction protocol remains.
- [ ] Fixed constants have one existing-layer definition reused by topic/archive/observation/wiki consumers where semantics match; S10 introduces no configurable ceiling fields, generic quota framework, package, database, daemon, scheduler, or QMD integration.
- [ ] Every body read is preceded by regular-file/type/file-byte/count/aggregate admission; counters use UTF-8 bytes, inclusive limits, deterministic canonical ordering, and overflow-safe arithmetic.
- [ ] Result ceilings are separate from scan ceilings: 50 is an output top-K ceiling applied only after every candidate admitted by the 1,000-file/64-MiB scan budget reaches the final comparator; only scan-budget exhaustion stops traversal, and errors or exhausted scan budgets report degraded coverage rather than healthy emptiness.
- [ ] S03 alone implements and behavior-tests migration's maximum 256 parsed records per in-memory batch, one final atomic corpus commit, and 100-diagnostic/64-KiB UTF-8 report with total/omitted counts; S10 only verifies that delivered contract as a fitness dependency.
- [ ] Numeric validation is authoritative for nested YAML, legacy YAML, overrides, API/CLI writes, and runtime constructors; zero, negative, malformed, fractional, and out-of-domain values never default, clamp, or persist.
- [ ] Observation status distinguishes exact from lower-bound/incomplete aggregate usage, warns at known usage `>= 64 MiB`, and preserves all raw files. Current drop-oldest-at-8-MiB behavior is removed, not retained behind a fallback.
- [ ] Wiki traversal/lint/search use the same fixed wiki boundaries and isolate bad files; wiki/KG write scope and S07 query semantics remain unchanged.
- [ ] QMD experiments, semantic deduplication, autonomous curation, automatic raw retention/deletion policy, and S08 index rebuild/repair implementation remain absent from this story.

## Scope & Boundaries

### Work Areas

- Core canonical identity normalization, deterministic replay classification, fixed corpus budget/preflight, and archive mutation through the S02 authority
- Storage pruner/archive integration plus bounded wiki traversal/search/lint consumers
- Configuration metadata, parsing, override, persisted-write, and runtime-constructor validation for the two existing numeric settings
- Server raw-observation append behavior and aggregate usage/coverage status
- Boundary, limit-plus-one, distinct-provenance, real-transition fault, and structural fitness tests

### What We're NOT Doing

- Adding configuration knobs for canonical, partition, recursive, result, migration, report, or warning ceilings – the plan fixes them as constants.
- Implementing migration batching/reporting, editing `StorageWiring`, or duplicating migration behavior fixtures – S03 solely owns that production seam and its tests; S10 consumes them through resource fitness.
- Semantically merging, rewriting, or deleting similar memories – S09 model curation owns semantic judgment.
- Automatically deleting, compacting, rotating away, or scheduling retention for raw observations – 0.27 stewardship policy owns retention.
- Rebuilding or repairing the derived index – S08 owns health, recovery, and rebuild; S10 only preserves its outcome contract.
- Changing natural-language memory/knowledge query semantics, broadening wiki/KG writes, or productionizing QMD – S07 and later-release boundaries remain authoritative.
- Adding a cross-product quota subsystem or a replacement traversal/index framework – extend small existing seams only.

## Architecture Decision

**Approach**: Extend the S02 bounded corpus/commit seam with pre-read fixed-budget admission and exact provenance-event replay identity, pass the same small typed limit/degradation contract into existing wiki, observation, configuration, and status consumers, and consume S03's shipped migration limits only as a fitness invariant.
**Why this over alternatives**: Existing services already own regular-file metadata checks, atomic canonical commits, configuration metadata, and layered degradation. Extending them keeps behavior auditable and avoids a second writer, QMD dependency, configurable quota system, or speculative resource-management framework.

## Technical Overview

The host canonicalizes role/topic through S01, normalizes content exactly as the current `MemoryEntry.normalizedText` contract (`trim`, then collapse `RegExp(r'\s+')` to one ASCII space, case-sensitive), and compares the complete S01/S04 provenance source reference including its stable source-event discriminator. Only equality of that full tuple is replay deduplication. The implementation checks regular-file metadata and admits the 64 MiB per-source, 1,000-file, and 64 MiB aggregate costs before opening/decoding a body. Deterministic traversal ranks every candidate admitted by those scan budgets, then returns the best 50 under the final comparator; the output ceiling never stops traversal at the first 50 matches.

Archive mutation renders the complete prospective archive and validates its final UTF-8 bytes against 64 MiB before S02 stages any canonical file. S02 then remains responsible for one revision, commit marker/recovery, and canonical-before-derived ordering. S03 alone implements and behavior-tests migration's 256-record batches, one final S02 atomic commit, and 100-diagnostic/64-KiB report; S10's fitness check only consumes that delivered contract and never edits the migration or startup seam. Raw observation appends preserve S04's 65,536-character input boundary, preflight the prospective dated partition against 8 MiB, and reject rather than evict on overflow. Status accumulates aggregate usage with overflow-safe counters, warns at known usage of 64 MiB or more, and distinguishes exact totals from known lower bounds. Existing configurable integers share one positive-domain validator; fixed safety ceilings never enter writable configuration. No resource failure is translated to healthy empty or zero state.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_storage/lib/src/memory/memory_pruner.dart#MemoryPruner.removeDuplicates | Current text-only dedup and direct multi-file archive transaction to replace with complete identity and S02 authority
file | packages/dartclaw_core/lib/src/memory/memory_entry.dart#MemoryEntry.normalizedText | Existing exact whitespace normalization to preserve and narrow within the full identity tuple
file | packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService | Existing regular-file stat-before-read seam and settled 64 MiB/8 MiB boundaries; drop-oldest behavior must become rejection
file | packages/dartclaw_storage/lib/src/search/wiki_search_source.dart#WikiSearchSource.search | Current unbounded recursive enumeration/body read and S07 per-layer result/provenance contract
file | packages/dartclaw_server/lib/src/knowledge/knowledge_inbox_service.dart#WikiPageStore.lint | Additional recursive wiki consumer that must share the fixed wiki budgets
file | packages/dartclaw_server/lib/src/knowledge/knowledge_inbox_service.dart#KnowledgeInboxReadService | Lean pre-read file/count/result/preview admission pattern only; its values are not memory safety constants
file | packages/dartclaw_config/lib/src/memory_config.dart#MemoryConfig | Existing 32 KiB/90-day defaults and direct typed construction path
file | packages/dartclaw_config/lib/src/config_parser.dart#_parseMemory | Nested/legacy/CLI precedence and permissive integer parsing to unify with positive validation
file | packages/dartclaw_config/lib/src/config_meta.dart#ConfigMeta.fields | Existing minimum/range metadata contract and writable-key inventory
file | packages/dartclaw_config/lib/src/config_validator.dart#ConfigValidator | Existing API/CLI write validation seam to reuse for startup and runtime validation
file | packages/dartclaw_config/lib/src/config_writer.dart#ConfigWriter | Persisted write boundary that must never store present-invalid numeric values
file | packages/dartclaw_server/lib/src/memory/memory_status_service.dart#MemoryStatusService | Current unbounded daily-file aggregate/recent reads and zero-like failure reporting to replace with exact/incomplete usage
file | packages/dartclaw_server/lib/src/memory/workspace_file_reader.dart#WorkspaceFileReader | Existing direct workspace reader and directory-metadata paths needing fixed admission where they expose these roles
```

## Constraints & Gotchas

- **Critical – identity is complete and stable**: provenance-event identity includes origin kind, source locator, caller/session reference when available, and stable source-event discriminator. If S01/S04 has not yet materialized that discriminator, extend their prerequisite value object; do not hash text or use recorded time as a substitute.
- **Critical – normalization is intentionally non-semantic**: trim plus whitespace-run collapse only, case-sensitive. Do not lowercase, Unicode-fold, stem, embed, fuzzy-match, or strip provenance. Semantic dedup remains explicit S09 curation.
- **Critical – limit before allocation/mutation**: stat and admit before body reads; validate prospective UTF-8 output before staging. Exact limit succeeds; limit+1 rejects/skips with typed context and no partial mutation.
- **Critical – archive is one canonical transaction**: source removal and archive addition share one S02 revision. A derived-index failure after commit is degraded success, not canonical rollback; any pre-commit failure is no effect.
- **Critical – no automatic data loss**: the current daily-log routine removes oldest records to fit 8 MiB. S10 must instead reject the new append and preserve existing bytes; the 64 MiB aggregate warning is informational, never a write/deletion trigger.
- **Critical – incomplete is not zero**: once a status scan cannot prove the full set, totals are lower bounds and coverage is partial. Preserve known count/byte/time facts and failed/omitted locators without pretending completeness.
- **Critical – paths agree**: startup YAML, legacy YAML, CLI overrides, API/config-set writes, and typed constructors must share the same positive-integer rules and error vocabulary. Avoid parser-local defaults for present-invalid values.
- **Fixed policy – no config expansion**: 64 MiB source, 8 MiB partition, 1,000 files, 64 MiB request aggregate, best 50 results, 256 parsed migration records per batch, 100 report diagnostics, 64 KiB report output, and the 64 MiB observation warning are code constants with boundary/limit-plus-one tests, not user-tunable fields.
- **Single migration owner**: S03 owns the migration constants, production enforcement, startup wiring, and behavior tests; S10 may rerun and reference that contract only through TI06 fitness coverage.
- **Avoid – false reuse**: knowledge-inbox limits demonstrate the correct admission sequence, but its 200-file/16 KiB preview values govern a different product surface and must not leak into memory/wiki policy.
- **Avoid – scope expansion**: do not add QMD guards, a quota service, automatic cleanup, new config keys, or a replacement traversal/index framework.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Exact replay identity preserves every distinct memory event
  - Replace text-only pruning identity with the normalized role/topic/content/provenance-event tuple, routed through the canonical S01/S05 identity and no-op result seams; keep selection/order deterministic when entries are distinct.
  - **Verify**: Table-driven unit and real-corpus component tests prove S01–S02 for every tuple component, whitespace boundaries, case difference, paraphrase, same-event replay, stable IDs/revisions, and absence of canonical/index writes on an exact no-op.

- [ ] **TI02** Archive admission and commit are bounded and atomic
  - Render and byte-check the complete prospective archive against 64 MiB before staging, then delegate the active/archive revision to S02's one lock/commit/recovery authority and preserve S08 post-commit index-degradation semantics.
  - **Verify**: Temp-corpus exact-limit/64-MiB-plus-one tests plus real-transition failure hooks prove S03 by comparing active/archive bytes, revision/marker, and index rows before recovery and after retry.

- [ ] **TI03** Every direct and recursive memory reader spends one fixed request budget
  - Apply the 64 MiB direct-source, 1,000 regular-file, 64 MiB aggregate, and best-50 output constants to topic/archive/observation/wiki consumers, including wiki search/lint and status traversal, with deterministic scan order, stat-before-read admission, overflow-safe counters, full ranking of scan-admitted candidates, and typed partial/degraded outcomes.
  - **Verify**: Instrumented temp files and read spies prove S04 at each exact boundary and limit+1, including no body read after scan-budget exhaustion, isolated unreadable/oversized wiki files, a highest-ranked late-path match retained in the best 50, stable ordering, output truncation, and other-layer continuity.

- [ ] **TI04** Existing numeric memory settings have one positive validation contract
  - Make nested/legacy parsing, overrides, config-set/API persistence, and runtime service construction share authoritative validation for `memory.max_bytes` and archive age; reject present-invalid values before persisted or operational side effects and keep fixed ceilings out of config metadata.
  - **Verify**: One parameterized matrix drives every field/path in S05 through `1`, default, zero, negative, fractional, wrong-type, out-of-domain, and absent cases while asserting identical errors, unchanged config bytes on rejection, and unknown-key rejection for invented ceiling fields.

- [ ] **TI05** Raw observation growth is visible and never automatically destructive
  - Preserve S04's observe input ceiling, change 8 MiB partition overflow to preflight rejection, and report bounded aggregate bytes, oldest/newest coverage, exact versus lower-bound completeness, failures/omissions, and the `>= 64 MiB` warning through the existing status model.
  - **Verify**: Partition exact/limit-plus-one, aggregate warning-minus-one/exact/plus-one, unreadable/malformed file, and traversal-budget component tests prove S06 with byte-for-byte raw-file snapshots and no deletion/rewrite of existing records.

- [ ] **TI06** Resource-boundary fitness prevents alternate unbounded paths
  - Cover the assembled production graph and all recursive consumers named in this FIS; ensure S02/config/status contracts are used, consume S03's shipped migration limits as a read-only dependency, and leave no direct archive transaction, drop-oldest fallback, configurable ceiling, QMD integration, quota framework, automatic retention path, or duplicate migration enforcement.
  - **Verify**: Focused production reference/constructor tests plus a scoped repository scan prove every Structural Criterion; rerun S03's owned migration boundary suites without adding S10 fixtures or editing `StorageWiring`; run the affected package suites, analyzer, formatter gate, and CI-equivalent gate required by `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`.

### Testing Strategy

- [TI01] Use table-driven canonical identities with explicit role/topic/content/provenance fields; prove tests fail if any required tuple component is removed or if semantic/case folding is added.
- [TI02,TI05] Use real temp files and the S02 commit service. Inject failures at actual staging, canonical replacement/marker, and derived-index transitions; compare bytes and revision state, not mocks of helper calls.
- [TI03] Use sparse/stat-only fixtures or injectable production budget constants where allocating 64 MiB adds no value, plus one real UTF-8 boundary integration case. Instrument body-open/read calls and independently exercise per-file bytes, 1,000/1,001 files, aggregate bytes, and 50/51 results with the best match last.
- [TI04] Reuse one expected metadata table across nested YAML, legacy YAML, overrides, API/CLI write, and direct construction so divergent validation cannot pass path-local tests.
- [TI05] Create multiple dated partitions with known UTF-8 byte sizes and record times. Assert exact and lower-bound coverage separately, including malformed/unreadable members, and snapshot the directory to prove no automatic deletion.
- [TI06] Treat S03's 256/257/513-record and oversized-diagnostic suites as prerequisite fitness evidence; do not recreate their fixtures or production enforcement in S10.
- [TI01–TI06] Keep tests portable and deterministic: Dart filesystem APIs, `Completer`/explicit fault hooks where coordination is needed, no wall-clock sleeps, no platform-specific shell flags, and no alternate production constants hidden in fixtures.

## Implementation Observations

_No observations recorded yet._
