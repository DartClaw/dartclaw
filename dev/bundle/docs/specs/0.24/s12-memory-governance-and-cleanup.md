# Feature Implementation Specification: Memory Governance and Cleanup

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S12

## Feature Overview and Goal

**Intent**: Leave 0.24 with one lean, enforceable, and accurately documented memory architecture that later storage,
search, and stewardship work can extend without inheriting obsolete or contradictory contracts.

**Expected Outcomes**:

- [OC01] Obsolete vector, chunk, and exact-row identity placeholders no longer inflate the public or runtime memory
  surface, while every API retained has a demonstrated production consumer.
- [OC02] Cheap continuous checks – repository scans plus the consumed behavioral suites of stories S05/S07/S09 – catch
  reintroduction of automatic consolidation, a system action entering timer/retry/YAML mutation, an accepted
  reserved-ID collision or precedence/compatibility path, generic memory locators, caller-owned FTS encoding,
  obsolete public memory symbols, or duplicate wiki composition.
- [OC03] Contributors and users can follow code-backed memory-role, mutation, prompt, resource, recovery, and lifecycle
  documentation without encountering a stale competing model.
- [OC04] The 0.24 contract hands stable semantics to 0.25 and 0.27 while QMD remains only the supported transitional
  backend described by its exact deprecation and removal schedule.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.11` – final-wave scope, dependencies, risk, and cleanup/documentation
  boundary.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` – canonical roles, locator/query ownership, prompt freshness,
  fixed ceilings, stopped-edit recovery, immutable host system actions, and later-release decisions shared across this story.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – exact removal candidates,
  KISS/YAGNI constraint, QMD schedule, and 0.25/0.27 ownership.
- `dev/bundle/docs/specs/0.24/prd.md#fr9-architecture-governance-and-documentation` – required fitness, ADR,
  architecture, package, and user-document convergence.
- `dev/bundle/docs/specs/0.24/prd.md#architecture-review-coverage` – finding-to-requirement inventory that this
  final wave must close or leave with an explicit later owner.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – file authority, package boundaries, fixed threat model, and
  prohibition on new packages, stores, daemons, or QMD responsibility.
- `dev/bundle/docs/specs/0.24/s05-atomic-memory-apply.md#implementation-plan` – owns `memory_save` and consolidator
  removal, producer migration, policy mapping, and current tool documentation; S12 consumes and governs those outcomes.
- `dev/bundle/docs/specs/0.24/s07-search-and-citation-convergence.md#implementation-plan` – owns query/locator
  convergence and single wiki composition; S12 consumes its behavioral proof rather than reimplementing retrieval.
- `dev/bundle/docs/specs/0.24/s10-memory-resource-boundaries.md#fixed-resource-contract` – exact fixed ceilings and
  non-destructive observation policy that documentation and fitness must preserve.
- `dev/bundle/docs/specs/0.24/s11-operator-visible-memory-lifecycle.md#architecture-decision` – existing status and
  operator surfaces whose names, states, and recovery actions are the presentation source of truth.
- `dev/bundle/docs/specs/0.24/s09-on-demand-memory-curation.md#architecture-decision` – the only host-callback
  system-action seam, its read-only scheduling projection, and its timer/retry/YAML exclusion to govern, not recreate.
- `dev/adrs/002-file-based-storage.md#decision` – file-canonical, derived-index storage decision to amend for the
  bounded index plus topic corpus.
- `dev/adrs/029-temporal-knowledge-graph-durable-knowledge-loop.md#decision` – personal memory versus source-backed
  wiki/KG boundary and wiki ranking to preserve.
- `dev/adrs/033-architectural-governance-via-fitness-functions.md#decision` – existing cheap Dart-native fitness
  mechanism and no-silent-waiver discipline.
- `dev/adrs/042-context-research-synthesis-and-citation-model.md#decision` – stable layer-owned citation contract to
  reconcile with canonical personal-memory locators.
- `dev/adrs/045-pluggable-database-backend.md#what-the-file-layer-already-handles-well` – 0.25 database boundary that
  must keep canonical personal memory file-based.
- `dev/adrs/050-native-hybrid-search.md#decision` – Phase B QMD deprecation and one-milestone-later removal schedule.

## Deeper Context

- `dev/bundle/docs/specs/0.24/memory-architecture-recommendations.md#architecture-fitness-functions-and-tests` –
  complete review-era fitness inventory and trigger/owner guidance.
- `dev/bundle/docs/specs/0.24/memory-architecture-recommendations.md#adr-and-documentation-updates` – affected ADR and
  normative-document inventory.
- `dev/adrs/007-system-prompt-architecture.md#decision` – the story S05/S06 prompt amendment to verify against the final
  provider behavior, not independently redesign here.
- `dev/adrs/016-multi-provider-harness-architecture.md#decision` – the harness/provider tool contract behind story S05's
  ADR-007/016 migration that S12 verifies rather than re-amends.
- `dev/adrs/010-package-split-models.md#decision` – public shared-kernel lineage affected by retiring `MemoryChunk`.
- `dev/adrs/044-workflow-orchestration-agent-architecture.md#decision` – § D2's planned `orchestration` `PromptScope`
  value and its characterization of `evaluator`, both to reconcile against the consolidated `primary` vocabulary.
- `dev/architecture/data-model.md#memory-chunk-search-index` – current derived-row model and stale generic source
  identity to replace in documentation, including its pre-0.24 native-format `learnings.md` description.
- `docs/guide/workspace.md#how-the-knowledge-layer-fills` – user-facing workspace file inventory that still describes
  the pre-0.24 native-format `learnings.md` and its writer.
- `dev/guidelines/TESTING-STRATEGY.md#fitness-functions` – static-check proportionality and existing fitness runner.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01] Reference-proven dead memory surface is absent while live contracts remain usable**
  - **Given** stories S01–S11 have landed and a production-reference census covers package barrels, declarations,
    callers, tests, package guidance, and accepted 0.25 seams, counting as a production consumer only a reference from
    `packages/*/lib/` – including `dartclaw_testing/lib/`, which ships to users – or from `apps/*/lib/`, and never a
    reference from `examples/`, `dev/tools/`, or any `test/` tree
  - **When** the workspace is analyzed and the public memory API is exercised through its package barrels
  - **Then** `MemoryChunk`, `MemoryService.searchVector`, `insertChunkIfAbsent`, `deleteChunkIdentity`, and any
    superseded legacy identity helper with no production caller are absent together with tests/docs that existed only
    to assert them, while canonical entries, typed search results, locators, and index projections remain available
  - **And** no placeholder is retained merely because historical prose or a self-referential test names it, and each
    removal is an un-export from the package barrel or a relocation into `lib/src/` plus deletion of the now-dead code
    – never a deleted repository file, test, or history entry used to clear the census

- [ ] **S02 [OC02] [TI02] Memory fitness rejects each prohibited architecture without rejecting the canonical one**
  - **Given** isolated static-scan negative fixtures for an automatic curation dispatch, a system action entering
    timer/retry/YAML mutation, a locator constructed with a generic `memory_save`/`archive` source instead of a canonical
    entry locator, FTS query encoding in a caller, and a re-exported retired placeholder; plus three classes proven by
    consumed behavioral tests rather than by scanning – a configured job collision accepted through startup or config
    create/edit and precedence/compatibility handling for a reserved action ID (story S09's tests), and a duplicated
    wiki composition owner (story S07's counting retriever, exercised by scenario S03)
  - **When** the memory-specific fitness checks evaluate each static-scan fixture and the assembled production tree, and
    the named behavioral suites are consumed rather than restated as string scans
  - **Then** every static-scan negative fixture fails with the violated invariant and resolution guidance, each consumed
    behavioral suite fails for its own class, and the canonical architecture delivered by stories S05/S07/S09 passes
    without an allowlist, runtime dependency, or full semantic duplicate of behavioral tests

- [ ] **S03 [OC02,OC03] [TI02,TI04] Context Research performs one wiki traversal and documentation names one owner**
  - **Given** one Context Research request whose personal backend and explicit wiki source can both return the same
    source-backed page, plus a counting wiki retriever
  - **When** the assembled story S07 retrieval path produces its citation packet
  - **Then** the wiki source is traversed exactly once, wiki precedence and native provenance remain intact, healthy
    personal results survive wiki failure, and architecture/user docs describe that same single-owner flow

- [ ] **S04 [OC03] [TI03,TI04] Normative documents describe one code-backed 0.24 memory lifecycle**
  - **Given** the implemented corpus, tools, prompt, curation, limits, status, and rebuild behavior from stories S01–S11
  - **When** a contributor or operator follows the current ADR index, architecture references, package guidance,
    workspace/search/configuration/architecture/CLI guides, and memory-related recipes
  - **Then** each role, stable identity, revision, provenance, prompt budget, fixed safety ceiling, system-action contract –
    read-only through every scheduling configuration surface, visible through list/show, and executed by run-now – curation
    state, canonical-versus-index outcome, stopped-edit rule, and recovery action agrees with code and tests
  - **And** runtime `workspace/learnings.md` is described as a canonical role – stable identity, revision, validation,
    and fingerprint participation, canonical Markdown at that same path, newest-50 retention cap unchanged – and is
    never confused with contributor `dev/state/LEARNINGS.md`
  - **And** the deletion-audit document `workspace/MEMORY.audit.md` is described as a canonical role of the same kind –
    codec-rendered, validated, an inventory and fingerprint member whose writes advance the collection revision inside
    the same canonical transaction as the removal – and as a content-free operational record that the derived index
    never projects, so it is not searchable memory content

- [ ] **S05 [OC04] [TI03,TI05] Later-release documentation preserves exact ownership without acting early**
  - **Given** a 0.24 deployment using FTS5 or the current opt-in QMD backend
  - **When** current decisions, roadmap, architecture, search, configuration, and recovery guidance are inspected
  - **Then** QMD remains usable and gains no canonical-memory semantics in 0.24, 0.25 Phase B owns its deprecation,
    the following milestone owns implementation removal, and no 0.24 fitness check rejects current QMD symbols
  - **And** 0.25 must preserve 0.24 identity/provenance/query/index-health semantics, while 0.27 owns autonomous
    stewardship and guarded wiki/KG writes without gaining a generic file-replacement tool

- [ ] **S06 [OC01,OC02,OC03,OC04] [TI01,TI02,TI03,TI04,TI05] Final governance closes every review item without new machinery**
  - **Given** the final implementation diff and the architecture-review coverage inventory
  - **When** focused contracts, full workspace validation, fitness, analyzer/barrel checks, and normative-reference scans run
  - **Then** every review item maps to a passing behavior/fitness proof or its explicit 0.25/0.27/removal-milestone owner,
    no dead export or contradictory current document remains, and no package, database, daemon, scheduler, approval
    framework, compatibility alias, or speculative provider/search abstraction was added by S12

## Structural Criteria

- [ ] S12 does not recreate the work of prerequisite stories S05 (tool/consolidator migration), S07 (retrieval
  composition), S10 (limit handling), S09 (system-action seam), or S11 (operator projection); it removes dead residue,
  adds governance backstops, and repairs only remaining integration contradictions after consuming their tests and
  contracts.
- [ ] A public memory symbol remains only with a non-test production consumer; a binding accepted later-release
  contract justifies retention only when that contract also has a concrete production consumer, never on its own.
  Test-only use, documentation, and historical references do not justify public surface. A production
  consumer is a reference from `packages/*/lib/` – including `dartclaw_testing/lib/`, which ships to users – or from
  `apps/*/lib/`; references from `examples/`, `dev/tools/`, and any `test/` tree never justify retained public
  surface. "Removal" means un-exporting the symbol from its package barrel or moving it into `lib/src/`, plus
  deleting genuinely dead code – it never means deleting repository files, tests, or history to clear the census;
  only tests whose sole subject is the deleted dead code follow it out.
- [ ] Fitness is narrow and semantic enough to prevent the named regression: no broad prose lint, no historical rewrite,
  no allowlist for the new zero-baseline rules, and no brittle exact file/line counts. Generated Dart output is excluded
  by rule – `*.g.dart` and the `lib/src/generated/` embedded-asset libraries are git-ignored build products, absent from
  a clean checkout, and never scanned. Any current-prose scan is bounded to the normative document set named below; no
  other path is scanned for operational prose.
- [ ] Reserved system-action identity is governed as one invariant: startup and config create/edit reject configured-job
  collisions before scheduling/list-show-run publication or mutation, with no precedence, shadowing, renaming, alias, or compatibility exception.
- [ ] Canonical Markdown remains authoritative; derived databases contain no irrecoverable memory and can be rebuilt
  without changing stable source identity.
- [ ] Fixed resource ceilings remain inclusive constants exactly as
  `dev/bundle/docs/specs/0.24/s10-memory-resource-boundaries.md#fixed-resource-contract` states them: 64 MiB canonical
  source, 8 MiB observation partition, 1,000 regular files and 64 MiB aggregate per recursive request, best 50 results,
  256 parsed records per migration batch, 100 diagnostics and 64 KiB per migration report, 65,536 characters per
  `memory_observe` input, 64 KiB per `memory_read` response, and the observation usage warning beginning at 64 MiB.
- [ ] Current normative docs are `README.md`, `docs/`, `dev/architecture/`, `dev/state/DECISIONS.md`,
  `dev/state/ROADMAP.md`, `dev/state/UBIQUITOUS_LANGUAGE.md`, and package/app `AGENTS.md`; `CHANGELOG.md`, superseded
  decisions, and this planning bundle may retain clearly historical migration names without advertising them as current
  behavior.

## Scope & Boundaries

### Work Areas

- Obsolete memory values/methods, their package barrels, tests, and current package guidance
- Memory architecture fitness tests, negative fixtures, resolution guidance, and existing runner
- Accepted ADR amendments plus `dev/state/DECISIONS.md` lineage
- Contributor architecture and package `AGENTS.md` synchronization
- User workspace/search/configuration/architecture/CLI and memory-recipe synchronization
- Roadmap and 0.25/QMD/0.27 handoff wording

### What We're NOT Doing

- Repeating the `memory_save`, consolidator, producer, provider-policy, or prompt migration – story S05 owns it; S12
  only makes the completed absence durable.
- Rebuilding story S09's system-action registration, lifecycle persistence, merged list/show/run, or story S11's
  presentation – S12 only guards their explicit-only and read-only boundaries and corrects residual documentation drift.
- Reworking query/ranking/citation behavior or wiki fusion – story S07 owns it; S12 consumes its one-traversal proof.
- Removing, deprecating, or hardening QMD in 0.24 – deprecation starts at 0.25 Phase B and removal is one milestone later.
- Adding hybrid/vector search, PostgreSQL, autonomous stewardship, retention policy, or guarded wiki/KG write semantics –
  their accepted later milestones remain responsible.
- Rewriting immutable release history or adding a new ADR when precise amendments to existing decisions capture the
  settled model.

## Architecture Decision

**Approach**: Use one final reference census to delete only demonstrated dead surface, add a small set of Dart-native
fitness backstops for settled seams, and amend existing ADRs/normative docs from the contract implemented by stories
S01–S11.
**Why this over alternatives**: A new governance framework, compatibility layer, or memory umbrella abstraction would
duplicate accepted seams and make the 0.25 handoff harder rather than safer.

## Technical Overview

S12 begins only after every prerequisite story is complete. It classifies each remaining public memory symbol by real
production consumption, removes the known test-only placeholders, then runs analyzer and barrel gates to catch residue.
The fitness additions guard only stable zero-baseline architecture and reuse the behavioral contracts of stories
S05/S07/S09 for semantic proof, including one wiki traversal and one immutable explicit-only system action whose
reserved ID cannot collide at startup or config mutation. ADR amendments record the canonical corpus and later-release
lineage; current architecture, package, and user docs derive their facts from the final code/status schemas rather than
from older prose.
QMD remains operational in 0.24, so retirement is documented as a later gate and is not enforced prematurely.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_models/lib/src/models.dart#MemoryChunk | Public value with no production consumer to retire
file | packages/dartclaw_storage/lib/src/storage/memory_service.dart#MemoryService.searchVector | Unused vector stub superseded by ADR-050's later package seam
file | packages/dartclaw_storage/lib/src/storage/memory_service.dart#MemoryService.insertChunkIfAbsent | Test-only derived-row identity helper superseded by canonical identity/projection
file | packages/dartclaw_models/lib/dartclaw_models.dart#MemoryChunk | Explicit public barrel export that must lose the dead value without widening others
file | packages/dartclaw_testing/test/fitness/_internal/fitness_test_utils.dart#findRepoRoot | Existing portable repository-scan utilities for narrow fitness checks
file | packages/dartclaw_server/lib/src/mcp/context_research_tool.dart#ContextResearchTool._retrieve | Current duplicate wiki composition site replaced by story S07 and verified here
file | packages/dartclaw_server/test/mcp/context_research_tool_test.dart#main | Existing behavior suite to carry the single-wiki-owner integration proof
file | packages/dartclaw_testing/test/fitness/fitness_smoke_test.dart#main | Existing lightweight fitness-test pattern; extend tests, not infrastructure
```

## Constraints & Gotchas

- **Critical – consume prerequisites**: inspect the completed stories S01–S11 diff and tests before editing. A symbol
  or document already removed or corrected requires no replacement work; do not recreate it to satisfy this FIS's
  baseline inventory.
- **Critical – production evidence**: baseline `MemoryChunk`, `searchVector`, `insertChunkIfAbsent`, and
  `deleteChunkIdentity` are declaration/test/document-only. If a prerequisite introduces a real use, remove that use in
  favor of the accepted canonical projection rather than preserving an obsolete pre-0.25 contract.
- **Critical – prompt-scope census item**: `PromptScope.evaluator` has zero production construction sites under the
  production-consumer rule, so the census owns its wire-or-remove disposition; whichever way it lands, the same pass
  reconciles ADR-044's planned `orchestration` value against the consolidation of `interactive` and `conversational`
  into `primary`. `PromptScope` is SDK-surface only, so neither outcome touches YAML, config schema, or user docs.
- **Critical – current versus historical prose**: current instructions must converge, but changelog entries, superseded
  ADR rationale, and migration requirements remain truthful history. Fitness exclusions must be path-based and minimal.
- **Critical – QMD timing**: do not emit a 0.24 deprecation warning or ban QMD names. Document Phase B deprecation and
  the following milestone's implementation removal; the future removal gate is owned there.
- **ADR ownership**: story S05 owns ADR-007/016 prompt/tool migration. S12 verifies them, amends ADR-002, ADR-010,
  ADR-029, ADR-033, ADR-042, ADR-044, ADR-045, and ADR-050 only where final code changes their current contract, and
  synchronizes the decisions index. ADR-044 is in scope solely for its planned `orchestration` `PromptScope` value and
  its `evaluator` characterization, which must be restated against the consolidated `primary` vocabulary. Prefer
  concise addenda over rewriting decision history.
- **Documentation ownership**: behavior-local stories may already have corrected files. S12 performs one residual
  cross-document audit and changes only stale claims, broken examples, and missing later-release lineage.
- **Reserved-ID governance**: the accepted rule is rejection before scheduling/list-show-run publication or config
  mutation. Fitness and docs must not introduce action/job precedence, shadowing, auto-rename, aliases, or compatibility exceptions.
- **Fitness proportionality**: repository scans may prove absence/ownership, but behavior tests remain authoritative for
  query pass-through, locator resolution, and wiki traversal. Each scanner needs an in-memory negative fixture proving
  it detects the intended regression and a clear remediation message.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** The public and runtime memory surface contains only consumed contracts
  - Remove the four reference-proven placeholders and any superseded legacy identity helper left production-unconsumed
    after stories S01–S11; tighten barrels/tests/current package docs without moving the accepted search contract
    between packages.
    Census scope is `packages/*/lib/` (including `dartclaw_testing/lib/`) and `apps/*/lib/`; hits in `examples/`,
    `dev/tools/`, or any `test/` tree are not production consumers. "Remove" is un-export or relocation into `lib/src/`
    plus deletion of the genuinely dead code, never deletion of repository files, tests, or history to clear the census.
  - **Verify**: A declaration/export/caller census, analyzer, package barrel tests, and focused storage tests prove
    scenario S01; every retained public memory symbol has a named production consumer under `packages/*/lib/` or
    `apps/*/lib/`, and no removed symbol remains outside history.

- [ ] **TI02** Settled memory seams have cheap continuous regression guards
  - Extend the existing fitness suite with focused zero-baseline scans for automatic curation/consolidation, system
    actions entering timer/retry/YAML mutation, generic locators, caller-side FTS encoding, and retired
    placeholders/current operational prose; consume story S09's behavioral tests for reserved-ID collisions and
    precedence/compatibility handling and story S07's for duplicate wiki composition, rather than restating their
    semantics as string scans. The generic-locator scan anchors on locator-CONSTRUCTION sites, not on the bare
    `'archive'` token, which survives as legal store vocabulary (for example
    `packages/dartclaw_server/lib/src/api/memory_routes.dart`).
  - **Verify**: Scenarios S02–S03 are proven when each isolated static-scan negative fixture fails for its intended
    reason, the compliant fixture and production tree pass, story S09's tests prove startup/list/show/run and config
    create/edit reject collisions before publication/mutation with no winner or compatibility path, scenario S03's
    counting-retriever integration proves one traversal, and the full fitness suite stays within its cheap gate.

- [ ] **TI03** Accepted decisions describe the implemented corpus and exact release lineage
  - Amend the ADRs listed in the ownership constraint plus `dev/state/DECISIONS.md`: bounded index/topic corpus,
    identity/revision/provenance, prompt and mutation authority, stable locators, wiki/KG boundary, derived index health,
    0.25 preservation duties, and exact QMD timing must agree with final code; verify story S05's ADR-007/016
    amendments.
    The same pass records the `PromptScope` census outcome – `evaluator` wired or removed – and reconciles ADR-044's
    planned `orchestration` value against the consolidated `primary` vocabulary.
  - **Verify**: A decision-link/status audit and code/test cross-check prove scenarios S04–S05 with no contradictory
    current ADR, no lost supersession lineage, and no new ADR or premature QMD deprecation/removal.

- [ ] **TI04** Contributor and user references teach one recoverable memory model
  - Audit final code first, then correct only residual drift across the normative surfaces in Structural Criteria:
    architecture/package roles plus workspace, search, configuration, architecture, CLI/recovery, and memory recipes must
    use the stories S01–S11 vocabulary, reserved collision-free system-action list/show/run contract, status schema,
    fixed ceilings, stopped-runtime rules, and role-appropriate tool examples.
    `dev/architecture/data-model.md` and `docs/guide/workspace.md` are named members of this sync scope: both still
    describe the pre-0.24 native-format `learnings.md`, which must instead read as the canonical learning role – stable
    identity, revision, validation, and fingerprint participation, canonical Markdown at `workspace/learnings.md`,
    newest-50 retention cap unchanged.
    The same sync covers the canonical role vocabulary – `index`, `topic`, `archive`, `observation`, `learning`,
    `audit`, `wiki`, `kg` – including the deletion-audit document `workspace/MEMORY.audit.md`: a canonical, validated,
    fingerprint-participating role whose content-free entries the derived index never projects.
    `dev/state/UBIQUITOUS_LANGUAGE.md` is a third named member: it is the project's binding naming source of truth, still
    defines `Memory Chunk` as a first-class current term, and still describes the pre-0.24 search model over `MEMORY.md`,
    `MEMORY.archive.md`, and `learnings.md`, so its entries must converge on the canonical roles, entry/locator identity,
    and derived-index vocabulary the code ships.
  - **Verify**: Scenarios S03–S04 pass through link/example checks and a current-document scan bounded to the Structural
    Criteria normative set; every behavioral claim is tied to a production symbol or passing test, and old
    tool/consolidation prose remains only in explicit history.

- [ ] **TI05** Future owners can extend memory without redefining 0.24
  - Synchronize `dev/state/ROADMAP.md` and affected handoff sections so 0.25 preserves canonical identity, provenance,
    natural-query input, locators, corpus, index-health/rebuild semantics, and 0.27 reuses observe/apply/CAS for governed
    autonomy and guarded knowledge writes; map every review fitness item to its current test/gate or named later owner.
  - **Verify**: Scenarios S05–S06 pass via the coverage inventory, full CI-equivalent validation, and a release-boundary
    scan that finds no premature QMD/steward implementation, no unowned review item, and no S12-added runtime mechanism.

### Testing Strategy

- [TI01] Treat analyzer/barrel/reference evidence as public-API proof; delete tests that only assert the dead placeholder
  and retain behavior tests for the canonical replacement. Do not substitute a string scan for search behavior.
- [TI02] Keep fitness pure, deterministic, and repository-local. Test scan rules against small in-memory source/path
  fixtures, then scan production/current-doc scopes; use story S07's counting retriever for duplicate-composition
  behavior.
- [TI03,TI04,TI05] Validate links and named symbols, then sample each changed claim against the corresponding component,
  API, CLI, or recovery test. Historical exclusions are explicit and reviewed, never a blanket `dev/` exclusion.
- [TI01–TI05] Run focused core/models/storage/server/CLI tests, the complete fitness suite, analyzer, formatter, and the
  CI-equivalent workspace gate because this final story touches public APIs, package guidance, tests, and architecture.

## Implementation Observations

#### DECISION NOTE: production-consumer-definition

Decision-Key: production-consumer-definition
Altitude: fis-local
Affected surface: Acceptance Scenario S01, Structural Criteria (public-symbol retention bullet), Implementation Task TI01
Decision: A production consumer is a reference from `packages/*/lib/` – including `dartclaw_testing/lib/`, which ships to users – or from `apps/*/lib/`; references from `examples/`, `dev/tools/`, and any `test/` tree never justify retained public surface, and "removal" means un-exporting from the package barrel or moving the symbol into `lib/src/` plus deleting genuinely dead code, never deleting repository files, tests, or history.
Rationale: The census needs one mechanical, path-based rule so both retention and removal are checkable, and naming the removal mechanics stops an executor reading "remove" as "delete the file, the test suite, or the history".
Evidence: Owner-ratified preflight resolution 39 (2026-08-11); `dartclaw_testing` is a published package, so its `lib/` is shipped production surface while its `test/` tree is not.

Old:
```
  - **Given** S01–S11 have landed and a production-reference census covers package barrels, declarations, callers,
    tests, package guidance, and accepted 0.25 seams
```
New:
```
  - **Given** S01–S11 have landed and a production-reference census covers package barrels, declarations, callers,
    tests, package guidance, and accepted 0.25 seams, counting as a production consumer only a reference from
    `packages/*/lib/` – including `dartclaw_testing/lib/`, which ships to users – or from `apps/*/lib/`, and never a
    reference from `examples/`, `dev/tools/`, or any `test/` tree
```

Old:
```
  - **And** no placeholder is retained merely because historical prose or a self-referential test names it
```
New:
```
  - **And** no placeholder is retained merely because historical prose or a self-referential test names it, and each
    removal is an un-export from the package barrel or a relocation into `lib/src/` plus deletion of the now-dead code
    – never a deleted repository file, test, or history entry used to clear the census
```

Old:
```
- [ ] A public memory symbol remains only with a non-test production consumer or a binding accepted later-release
  contract; test-only use, documentation, and historical references do not justify public surface.
```
New:
```
- [ ] A public memory symbol remains only with a non-test production consumer or a binding accepted later-release
  contract; test-only use, documentation, and historical references do not justify public surface. A production
  consumer is a reference from `packages/*/lib/` – including `dartclaw_testing/lib/`, which ships to users – or from
  `apps/*/lib/`; references from `examples/`, `dev/tools/`, and any `test/` tree never justify retained public
  surface. "Removal" means un-exporting the symbol from its package barrel or moving it into `lib/src/`, plus
  deleting genuinely dead code – it never means deleting repository files, tests, or history to clear the census;
  only tests whose sole subject is the deleted dead code follow it out.
```

Old:
```
  - Remove the four reference-proven placeholders and any superseded legacy identity helper left production-unconsumed
    after S01–S11; tighten barrels/tests/current package docs without moving the accepted search contract between packages.
```
New:
```
  - Remove the four reference-proven placeholders and any superseded legacy identity helper left production-unconsumed
    after S01–S11; tighten barrels/tests/current package docs without moving the accepted search contract between packages.
    Census scope is `packages/*/lib/` (including `dartclaw_testing/lib/`) and `apps/*/lib/`; hits in `examples/`,
    `dev/tools/`, or any `test/` tree are not production consumers. "Remove" is un-export or relocation into `lib/src/`
    plus deletion of the genuinely dead code, never deletion of repository files, tests, or history to clear the census.
```

Old:
```
  - **Verify**: A declaration/export/caller census, analyzer, package barrel tests, and focused storage tests prove S01;
    every retained public memory symbol has a named production consumer and no removed symbol remains outside history.
```
New:
```
  - **Verify**: A declaration/export/caller census, analyzer, package barrel tests, and focused storage tests prove S01;
    every retained public memory symbol has a named production consumer under `packages/*/lib/` or `apps/*/lib/`, and no
    removed symbol remains outside history.
```

#### DECISION NOTE: prompt-scope-census-consequence

Decision-Key: prompt-scope-census-consequence
Altitude: fis-local
Affected surface: Deeper Context (ADR references), Constraints & Gotchas (production-evidence and ADR-ownership bullets), Implementation Task TI03
Decision: Record as S12 scope that `PromptScope.evaluator` has zero production construction sites under the ratified production-consumer rule, so S12's census owns its wire-or-remove disposition, and that ADR-044's planned `orchestration` scope value is reconciled against S06's consolidation of `interactive` and `conversational` into `primary` in the same ADR/documentation convergence pass.
Rationale: S06 deferred both items rather than deciding them, and S12 already owns the final production-reference census and the ADR reconciliation pass, so recording them here is the only placement that prevents an orphaned scope value and a stale planned ADR value.
Evidence: Owner-ratified preflight resolution 40 and the deferral in resolution 27 (2026-08-11); `dev/adrs/044-workflow-orchestration-agent-architecture.md` § D2 proposes a new `orchestration` `PromptScope` and describes `evaluator` as the minimal review-step scope.

Old:
```
- `dev/adrs/010-package-split-models.md#decision` – public shared-kernel lineage affected by retiring `MemoryChunk`.
```
New:
```
- `dev/adrs/010-package-split-models.md#decision` – public shared-kernel lineage affected by retiring `MemoryChunk`.
- `dev/adrs/044-workflow-orchestration-agent-architecture.md#decision` – § D2's planned `orchestration` `PromptScope`
  value and its characterization of `evaluator`, both to reconcile against the consolidated `primary` vocabulary.
```

Old:
```
- **Critical – production evidence**: baseline `MemoryChunk`, `searchVector`, `insertChunkIfAbsent`, and
  `deleteChunkIdentity` are declaration/test/document-only. If a prerequisite introduces a real use, remove that use in
  favor of the accepted canonical projection rather than preserving an obsolete pre-0.25 contract.
```
New:
```
- **Critical – production evidence**: baseline `MemoryChunk`, `searchVector`, `insertChunkIfAbsent`, and
  `deleteChunkIdentity` are declaration/test/document-only. If a prerequisite introduces a real use, remove that use in
  favor of the accepted canonical projection rather than preserving an obsolete pre-0.25 contract.
- **Critical – prompt-scope census item**: `PromptScope.evaluator` has zero production construction sites under the
  production-consumer rule, so the census owns its wire-or-remove disposition; whichever way it lands, the same pass
  reconciles ADR-044's planned `orchestration` value against the consolidation of `interactive` and `conversational`
  into `primary`. `PromptScope` is SDK-surface only, so neither outcome touches YAML, config schema, or user docs.
```

Old:
```
- **ADR ownership**: S05 owns ADR-007/016 prompt/tool migration. S12 verifies them, amends ADR-002, ADR-010, ADR-029,
  ADR-033, ADR-042, ADR-045, and ADR-050 only where final code changes their current contract, and synchronizes the
  decisions index. Prefer concise addenda over rewriting decision history.
```
New:
```
- **ADR ownership**: S05 owns ADR-007/016 prompt/tool migration. S12 verifies them, amends ADR-002, ADR-010, ADR-029,
  ADR-033, ADR-042, ADR-044, ADR-045, and ADR-050 only where final code changes their current contract, and
  synchronizes the decisions index. ADR-044 is in scope solely for its planned `orchestration` `PromptScope` value and
  its `evaluator` characterization, which must be restated against the consolidated `primary` vocabulary. Prefer
  concise addenda over rewriting decision history.
```

Old:
```
  - Amend the ADRs listed in the ownership constraint plus `dev/state/DECISIONS.md`: bounded index/topic corpus,
    identity/revision/provenance, prompt and mutation authority, stable locators, wiki/KG boundary, derived index health,
    0.25 preservation duties, and exact QMD timing must agree with final code; verify S05's ADR-007/016 amendments.
```
New:
```
  - Amend the ADRs listed in the ownership constraint plus `dev/state/DECISIONS.md`: bounded index/topic corpus,
    identity/revision/provenance, prompt and mutation authority, stable locators, wiki/KG boundary, derived index health,
    0.25 preservation duties, and exact QMD timing must agree with final code; verify S05's ADR-007/016 amendments.
    The same pass records the `PromptScope` census outcome – `evaluator` wired or removed – and reconciles ADR-044's
    planned `orchestration` value against the consolidated `primary` vocabulary.
```

#### DECISION NOTE: learnings-canonical-role

Decision-Key: learnings-canonical-role
Altitude: fis-local
Affected surface: Deeper Context (normative document references), Acceptance Scenario S04, Implementation Task TI04
Decision: S12's documentation-convergence set must describe runtime learnings as a canonical role – stable identity, revision, validation, and fingerprint participation – stored at `workspace/learnings.md` in canonical Markdown with the newest-50 retention cap unchanged, and `dev/architecture/data-model.md` plus `docs/guide/workspace.md` are explicitly inside that sync scope because both still describe the pre-0.24 native-format shape.
Rationale: S01 promotes learnings from a native-format special case to a canonical role, so leaving the two documents that define the old shape unnamed would ship exactly the stale competing model OC03 forbids.
Evidence: Cross-cutting owner-ratified resolution plus resolution 41 (2026-08-11); `dev/architecture/data-model.md` still lists `learnings.md` as a `MemoryChunk` FTS5 source with a native write path, and `docs/guide/workspace.md` still documents it as written by `memory_save` with `category='learning'`.

Old:
```
- `dev/architecture/data-model.md#memory-chunk-search-index` – current derived-row model and stale generic source
  identity to replace in documentation.
```
New:
```
- `dev/architecture/data-model.md#memory-chunk-search-index` – current derived-row model and stale generic source
  identity to replace in documentation, including its pre-0.24 native-format `learnings.md` description.
- `docs/guide/workspace.md#how-the-knowledge-layer-fills` – user-facing workspace file inventory that still describes
  the pre-0.24 native-format `learnings.md` and its writer.
```

Old:
```
  - **And** runtime `workspace/learnings.md` is never confused with contributor `dev/state/LEARNINGS.md`
```
New:
```
  - **And** runtime `workspace/learnings.md` is described as a canonical role – stable identity, revision, validation,
    and fingerprint participation, canonical Markdown at that same path, newest-50 retention cap unchanged – and is
    never confused with contributor `dev/state/LEARNINGS.md`
```

Old:
```
  - Audit final code first, then correct only residual drift across the normative surfaces in Structural Criteria:
    architecture/package roles plus workspace, search, configuration, architecture, CLI/recovery, and memory recipes must
    use the S01–S11 vocabulary, reserved collision-free system-action list/show/run contract, status schema, fixed ceilings,
    stopped-runtime rules, and role-appropriate tool examples.
```
New:
```
  - Audit final code first, then correct only residual drift across the normative surfaces in Structural Criteria:
    architecture/package roles plus workspace, search, configuration, architecture, CLI/recovery, and memory recipes must
    use the S01–S11 vocabulary, reserved collision-free system-action list/show/run contract, status schema, fixed ceilings,
    stopped-runtime rules, and role-appropriate tool examples.
    `dev/architecture/data-model.md` and `docs/guide/workspace.md` are named members of this sync scope: both still
    describe the pre-0.24 native-format `learnings.md`, which must instead read as the canonical learning role – stable
    identity, revision, validation, and fingerprint participation, canonical Markdown at `workspace/learnings.md`,
    newest-50 retention cap unchanged.
```
