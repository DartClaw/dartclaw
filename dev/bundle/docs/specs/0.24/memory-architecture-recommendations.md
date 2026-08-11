# Memory Architecture Review Recommendations – 0.24

> **Status:** Supporting architecture evidence and downstream coverage checklist
> **Baseline:** `d24844bbf7a14ea65d27c6fd4b2cc3f5c70765a6`
> **Review date:** 2026-08-11
> **Source trust:** trusted-local

## Coordination Note

A separate conversation owns requirements clarification, PRD authoring, and planning in this directory. This report is a
companion input, not a competing product artifact. The PRD and plan remain authoritative. Use this report later to prove
that the planning flow captured every material architecture finding, verification gate, documentation update, and
0.25/0.27 handoff constraint.

Current companion artifacts: [`requirements-clarification.md`](requirements-clarification.md) and [`prd.md`](prd.md).

## Review Basis and Verdict

The review traced `MEMORY.md` creation, parsing, prompt assembly, retrieval, locking, indexing, pruning, archiving,
journaling, consolidation, scheduled triggers, Context Research, Knowledge Hub, manual recovery, and relevant shutdown
paths. It also compared current official Claude Code, Letta, LangGraph, Mem0, and Zep/Graphiti memory designs and the
local AndThen project-learnings pattern.

The independent findings filter validated nine findings, downgraded two, and withdrew none.

**Verdict: Sound with targeted fixes.** Canonical Markdown, a disposable SQLite index, serialized atomic writes,
conservative parsing, and deterministic pruning are coherent and should remain. The current agent-driven consolidator is
the sole high-severity architectural flaw. Prompt selection, provenance, query ownership, citation identity, index health,
and recovery are material localized gaps.

## Invariants to Preserve

1. Canonical files own durable memory; search databases are derived and rebuildable.
2. A canonical commit is durable before derived-index work begins. Index failure never erases the canonical change.
3. Every in-process memory mutation uses one normalized workspace lock authority.
4. Canonical file replacement remains atomic from cooperating readers' perspective.
5. Unknown, opaque, fenced, and unmigratable user content is preserved rather than guessed or discarded.
6. Semantic decisions belong to the model; identity, revisions, provenance, limits, concurrency, persistence, and recovery
   belong to the host.
7. Personal/experiential memory stays distinct from source-backed wiki synthesis and temporal KG facts.
8. The product remains one logical owner in 0.24. Do not add multi-user or active-active machinery.
9. Host OS/runtime user/filesystem trust remains settled. Do not add hostile pathname/inode-swap defenses.
10. QMD remains on its deprecation path. Do not shape the new memory model around it.
11. Runtime `workspace/learnings.md` remains capped self-improvement knowledge, distinct from contributor
    `dev/state/LEARNINGS.md`. The latter supplies a layout lesson, not a shared store or schema.

## Findings That Planning Must Cover

| Severity | Finding | Required outcome |
|---|---|---|
| High | Consolidation asks a model to deduplicate and reorganize, but the only mutation tool appends. Unique sessions and start-only dispatch allow repeated or overlapping pseudo-consolidation turns. | Remove the consolidator and every automatic trigger. Reintroduce autonomous curation only after the guarded mutation contract is proven. |
| Medium | Prompt assembly reads and encodes the full `MEMORY.md` before truncation. Physical-tail selection is not recency because saves insert within category sections. | Replace bulk/tail injection with the clarified bounded index plus on-demand topics, bounded before allocation. |
| Medium | Journal, tool, user, and model content can become provenance-free prompt-authoritative memory. | Separate observations from curated memory. Journal output remains an observation until a guarded curated mutation promotes it. |
| Medium | FTS syntax conversion lives in one caller. Other callers pass natural text directly to `MATCH`; semantic backends receive FTS-distorted text. | Define search input as natural language and encode inside the lexical backend only. |
| Medium | Memory search results expose generic `memory_save` or `archive` source labels rather than entry locators. | Stable IDs resolve to one exact entry across save, rebuild, archive, Search, Knowledge Hub, and Context Research. |
| Medium | `rebuild-index` opens the target DB in place and cannot reliably recover a corrupt DB; deleting the DB can produce a healthy-looking empty index. | Build and validate a fresh sibling index, atomically replace the target, and detect/reconcile a newly created empty index. |
| Medium | Canonical saves swallow per-chunk index errors and still report unqualified success; dashboard failures collapse to zero counts. | Return and expose saved-but-index-degraded state, repair deterministically, and clear the state after reconciliation. |
| Low | Archive growth can cross its readable ceiling; `memory_read`, recursive wiki scans, daily logs, and archives lack consistent aggregate limits. | Bound each processing path before allocation/mutation, surface limit state, and defer deletion until retention policy exists. |
| Low | Negative memory limit values pass startup parsing despite metadata minimums. | Enforce one range-validation contract across YAML, CLI, API, and runtime config. |
| Low | Context Research scans wiki through the search backend and again as an explicit layer. | Give one component ownership of wiki traversal and preserve per-layer candidate quotas. |
| Low | `searchVector`, `MemoryChunk`, and exact-identity mutation helpers have no production consumers. | Remove obsolete surface unless an accepted 0.25 contract consumes it directly. |

## Ranked Recommended Changes

### Keep

| Rank | Recommendation | Impact | Minimal change | Verification |
|---:|---|---|---|---|
| 1 | Keep canonical Markdown plus a disposable index. | Preserves inspectability, low operational burden, and deterministic recovery. | Extend the format only for stable identity, revision, topic, and provenance. | Full rebuild produces the same canonical result set as live indexing. |
| 2 | Keep the shared lock, atomic-write utility, parser source offsets, and conservative opaque-content handling. | Protects acknowledged changes and manual content under cooperating concurrency. | Reuse these seams for every new observation/apply path. | Concurrent saves, apply, migration, prune, and rebuild never lose or partially expose a canonical change. |
| 3 | Keep exact deduplication and deterministic archival as fallback maintenance. | Supplies cheap, explainable convergence without semantic guessing. | Run below the semantic curation layer; do not infer paraphrase equality. | Randomized duplicate/archive fixtures converge idempotently. |
| 4 | Keep wiki and temporal KG as separate knowledge layers. | Prevents personal memory from becoming an uncited second knowledge authority. | Carry stable cross-layer source references, not shared storage. | Each retrieved item reports one correct layer and resolvable source. |
| 5 | Keep the small `userId` dimension required by accepted 0.25 contracts, but do not market it as current multi-user isolation. | Avoids near-term churn without speculative multi-user work. | No further tenant machinery in 0.24. | All 0.24 production paths remain explicitly single-owner. |

### Fix in 0.24

| Rank | Recommendation | Impact | Minimal change | Verification |
|---:|---|---|---|---|
| 1 | Remove automatic consolidation. | Stops runaway turns, model cost, memory growth, and unsafe replacement pressure. | Delete/disable the consolidator, heartbeat/job invocations, and false docs. Keep explicit on-demand curation only. | Over-threshold memory dispatches zero background curation turns. |
| 2 | Implement progressive-disclosure prompt memory. | Keeps prompt cost bounded without physical-order data loss. | Render a bounded `MEMORY.md` index; read bounded topic files only on demand. Never read the whole store before applying limits. | Every primary turn stays within 150 rendered lines and 32 KiB; topic detail is absent until requested. |
| 3 | Split observation from curated memory. | Prevents untrusted journal/tool content from becoming system-authoritative by persistence alone. | `memory_observe` records immutable provenance-labelled evidence; `memory_apply` is the only curated mutation authority. | Adversarial journal content remains an observation and never appears in prompt-authoritative memory without a valid apply. |
| 4 | Add guarded structured mutation. | Enables safe add, revise, merge, and remove without a broad file-replace tool. | Validate stable IDs, expected snapshot revision, operations, provenance, and resource limits; commit atomically under the shared lock. | Stale or invalid change sets leave canonical and index state unchanged; successful apply is atomic. |
| 5 | Make natural language the search contract. | Eliminates ordinary punctuation failures and keeps semantic input intact. | Move FTS quoting/operator escaping into the FTS adapter. | Shared corpus includes `C++`, quotes, parentheses, `AND`, hyphens, question marks, and Swedish text across every caller. |
| 6 | Add stable, rebuild-safe memory identity. | Makes citations, correction, deletion, and UI navigation meaningful. | Persist ID and revision in canonical memory; propagate locator, timestamp, topic, and provenance through index results. | One result reopens one exact entry before/after rebuild, revision, and active-to-archive movement. |
| 7 | Make rebuild genuinely reconstructive. | Restores the advertised recovery path for deleted and corrupt indexes. | Build a fresh sibling DB, validate it, close it, atomically replace the target, and preserve the existing target on failure. | Random bytes or deletion at `search.db` recover; injected rebuild failure preserves the prior DB and all canonical files. |
| 8 | Expose index degradation explicitly. | Prevents silent missing results after an acknowledged canonical save. | Return canonical-save/index outcome separately; expose health, repair guidance, last success, and clear-on-reconcile behavior. | Injected index failure reports degraded; successful reconcile restores exact parity and clears status. |
| 9 | Enforce resource limits before work. | Prevents oversized reads, unrecoverable archive crossing, and recursive scan amplification. | Bound index, topic, observation, archive, wiki file/count/total bytes, tool output, and migration batches before allocation or mutation. | Boundary and one-over-bound tests fail visibly without partial mutation; unreadable wiki files do not suppress healthy files. |
| 10 | Enforce memory config ranges consistently. | Prevents continuous trigger loops and unintended complete archival. | Reuse field metadata validation for startup YAML/CLI and runtime API changes. | Zero, negative, overflow, wrong type, and valid boundary cases agree across config surfaces. |
| 11 | Give wiki fusion one owner. | Removes duplicate I/O and prevents wiki candidates from consuming raw-memory quotas twice. | Context Research receives memory-only and wiki-only retrievers, then performs one explicit fusion. | One wiki traversal per request; layer quotas and degradation reporting remain correct. |
| 12 | Migrate legacy memory conservatively. | Allows a breaking preview format without losing manual user content. | Convert recognized entries to ID/revision/topic/provenance form; retain unrecognized blocks in a reported opaque section. | Repeated migration is idempotent; unknown input is byte-preserved; no live index references the old identity format. |
| 13 | Correct docs and operator surfaces with the code. | Removes misleading claims about caps, consolidation, triggering, trust, and recovery. | Update workspace, search, configuration, architecture, CLI, recipes, dashboards, and error guidance in the same stories. | Documentation examples and status labels are asserted where practical; review finds no old tool or consolidation wording. |

### Simplify or Remove

| Rank | Recommendation | Impact | Minimal change | Verification |
|---:|---|---|---|---|
| 1 | Replace `memory_save` rather than adding more semantics to it. | Removes the append-only ambiguity at the source. | Migrate callers to observe/search/read/apply; remove the old tool after bounded compatibility handling. | Production and docs contain no old mutation path; exact own-MCP policy mapping remains cross-harness. |
| 2 | Remove unused vector and identity placeholders. | Shrinks public API and misleading tests before the real 0.25 contracts arrive. | Delete only symbols with no production consumer. | Repository reference scan and package API tests remain green. |
| 3 | Keep runtime search contracts out of config after the 0.25 package seam exists. | Restores ownership without interim indirection. | Move once during the planned search-package work; add no temporary facade. | Package graph remains acyclic and architecture fitness passes. |
| 4 | Retire QMD on ADR-050's schedule. | Removes a large external-runtime and repair surface. | Preserve deprecation only; remove manager/backend/config/docs one milestone after Phase B GA. | Retirement gate finds no QMD production/config/doc symbols. |

### Defer

| Recommendation | Reason | Required handoff |
|---|---|---|
| PostgreSQL and native hybrid search | Already owned by 0.25; mixing it into 0.24 would obscure memory semantics with engine work. | 0.25 preserves 0.24 IDs, revisions, provenance, natural-query input, corpus, and degraded-state contracts. |
| Autonomous or idle-time stewardship | Explicit/on-demand curation must prove safe before scheduling it. | 0.27 reuses observation/apply/CAS contracts; it receives no generic replace capability. |
| Automatic raw-observation deletion | Retention and recoverability policy is not yet accepted. | Expose counts/bytes now; add deletion only after product decision and derived-data tests. |
| Aggregate archive/log partitioning | Current usage evidence does not justify another storage abstraction. | Implement only when thresholds are approached; preserve stable IDs across partition movement. |
| Semantic deduplication heuristics | Model curation already owns semantic judgment. | No embedding-distance or decay heuristic without a measured duplicate/recall problem. |
| Multi-user and active-active runtime behavior | Product remains isolated single-user instances. | Do not treat DB tenancy fields as complete authorization or concurrency architecture. |
| Stronger power-loss/native filesystem guarantees | Current atomic writes fit the settled host-trust/product posture. | Revisit only if explicit durability requirements change. |

## Settled Product Decisions to Carry into PRD and Plan

The parallel requirements clarification has resolved the review's former open decisions:

| Dimension | Settled direction |
|---|---|
| Prompt context | Bounded memory index on every primary turn; topic details on demand. |
| Semantic authority | Model proposes importance, topics, conflicts, and summaries; host validates and commits. |
| Trust/provenance | Raw journal/tool/user/model material enters observations, not curated prompt memory. |
| Mutation surface | `memory_observe`, `memory_search`, `memory_read`, and transactional `memory_apply`. |
| Ordinary-turn autonomy | Allowed only through the same host-guarded mutation contract. |
| Curation timing | Explicit/on-demand in 0.24; autonomous stewardship deferred to 0.27. |
| Save outcome | Canonical durability may succeed while indexing is degraded, but that state is explicit. |
| Retention | No automatic raw deletion in 0.24. Bound processing and expose usage. |
| Knowledge boundary | Personal/experiential topics remain distinct from source-backed wiki and temporal KG. |

If the authoritative PRD changes any of these, it should record the replacement decision rather than silently diverge.

## Architecture Fitness Functions and Tests

| Area | Fitness function | Test/gate | Trigger and response |
|---|---|---|---|
| Canonical identity | Every curated entry has a stable ID, monotonic revision, topic, timestamp, and provenance. | Parse/render/reopen property tests and migration fixtures. | Every PR; block on missing, duplicated, or unstable identity. |
| Apply atomicity | An apply either commits its complete canonical/index outcome or no canonical mutation. | Failure injection before validation, after each staged file, and around index commit. | Every PR; block on partial canonical visibility. |
| CAS concurrency | A proposal against a stale snapshot never overwrites a newer valid change. | Parallel apply/save/prune tests using controlled barriers. | Every PR; stale operations must return a specific recoverable result. |
| Canonical union | During prune/archive transition, every pre-operation fact exists in active or archive, never neither. | Crash/failure matrix before/after archive write, source write, and DB commit. | Every PR; block on canonical loss. |
| Index derivability | Rebuild and reconciliation produce the exact normalized rows from supported canonical sources. | Randomized observe/apply/prune/rebuild sequences; compare full row multisets and timestamps. | Every PR; block on extra, missing, or divergent rows. |
| Rebuild recovery | Deleted and corrupt indexes recover without in-place target mutation. | Random-byte DB, deleted DB, failed validation, and atomic replacement fixtures. | Every PR; preserve existing DB on failed rebuild. |
| Degraded health | Index failure is visible and successful repair clears it. | Inject live-index failure, inspect tool/API/dashboard state, reconcile, inspect again. | Every PR; block on false healthy/empty state. |
| Prompt bound | Primary prompt memory is at most 150 rendered lines and 32 KiB, applied before full-store allocation. | Large index/topic fixtures with early/new and late/old entries. | Every PR; block on overflow, raw tail selection, or detail leakage. |
| Trust promotion | Observation content cannot become prompt-authoritative without a valid apply operation. | Adversarial journal/tool/user text with imperative and meta-instruction payloads. | Every PR; block on direct observation injection into curated prompt memory. |
| Learning-role isolation | Runtime `workspace/learnings.md` remains a distinct self-improvement corpus; contributor `dev/state/LEARNINGS.md` is never runtime input. Any promotion into curated personal memory uses `memory_apply` with provenance. | Save, search, rebuild, prompt, and curation fixtures covering both similarly named files. | Every PR; block on cross-corpus leakage, role loss, or unguarded promotion. |
| Query contract | Natural-language queries never expose backend syntax or fail on ordinary punctuation. | Shared contract corpus across MCP, Context Research, Knowledge Hub, FTS, and QMD fallback during deprecation. | Every PR; block on exception or caller-specific result-set divergence. |
| Citation resolution | Each memory locator resolves to one exact live or archived entry. | Save/search/cite/revise/archive/rebuild lifecycle test. | Every PR; unresolved or ambiguous locator marks the result invalid. |
| Resource ceilings | Reads/scans/mutations respect file, count, total-byte, batch, and tool-output bounds. | Exact-boundary and one-over-bound tests; allocation/latency benchmark at supported maxima. | Every PR for correctness; release/profile gate for allocations and latency. |
| Wiki ownership | Context Research traverses wiki exactly once and isolates per-file failures. | Instrumented traversal count, unreadable file, oversized file, and quota tests. | Every PR; block on duplicate traversal or complete-layer loss from one file. |
| Migration | Legacy recognized entries migrate once; opaque content remains recoverable. | Golden fixtures for CRLF, fences, malformed headings, undated entries, duplicates, and repeat migration. | Every PR; block on data loss or non-idempotence. |
| Cooperating shutdown | All acknowledged memory writes drain before index/database shutdown. | Controlled shutdown with queued observe/apply operations. | Every PR; block on an acknowledged-but-missing canonical result. |
| Retrieval quality handoff | 0.25 does not regress the frozen English/Swedish 0.24 lexical result set and materially tests hybrid recall. | Representative recall@k/ranking fixture frozen before 0.25 implementation. | 0.25 spec/release gate; document accepted engine-specific ranking differences. |
| Package structure | Runtime search contracts have one owner; dependency graph stays acyclic with no cross-package `src` imports. | Existing `dev/tools/arch_check.dart` plus package-specific contract placement check. | Every CI run; block on Level-1 failure. |
| QMD retirement | Deprecated QMD integration disappears after the accepted window. | Production/config/docs symbol scan and dependency scan. | Removal milestone; block release while stale integration remains. |

## ADR and Documentation Updates

### Existing ADRs

- **ADR-002:** clarify the 0.24 canonical stores, stable identity/revision format, observation-versus-curated boundary,
  canonical-save/index-visibility semantics, and fresh-index recovery contract.
- **ADR-007:** reconcile provider prompt behavior with the bounded-index/on-demand-topic contract. State what each provider
  receives next turn without relying on native behavior-file assumptions.
- **ADR-029:** preserve the boundary among personal memory, source-backed wiki synthesis, and temporal facts. Add only the
  provenance linkage required by 0.24.
- **ADR-042:** enforce its existing memory-entry-ID locator contract through real production search results and resolver
  tests.
- **ADR-045:** require 0.25 database/search implementations to preserve 0.24 identity, revision, scope, natural-query,
  index-health, and rebuild semantics. Do not pull backend work into 0.24.
- **ADR-050:** pin the native search corpus and QMD migration behavior. Preserve 0.24 locators and provenance. Raw daily
  observations should remain excluded unless an explicit future decision adds them.

No new ADR is required for consolidator removal, FTS normalization, config range validation, duplicate wiki removal, or
fresh-sibling rebuild. These are direct correctness fixes. Add a new decision only if the PRD changes a settled memory
authority, trust, retention, or curation boundary.

### User and Operator Documentation

Update these surfaces in the same implementation stories:

- `docs/guide/workspace.md` – canonical roles, observation/topic/index layout, manual editing, migration, prompt behavior.
- `docs/guide/search.md` – natural-query contract, corpus, stable locators, degraded state, rebuild behavior, QMD window.
- `docs/guide/configuration.md` – true meaning and range of every memory limit; remove false disk-cap language.
- `docs/guide/architecture.md` and `dev/architecture/*` – source-of-truth, mutation, concurrency, crash, and recovery flows.
- `docs/guide/cli-reference.md` – fresh-sibling `rebuild-index`, stopped-server precondition, success/failure outcomes.
- Memory journal, personal-assistant, research-assistant, troubleshooting, and common-pattern recipes – remove automatic
  consolidation claims and explain observation versus curated memory.
- Workspace and contributor guidance – distinguish runtime `workspace/learnings.md` from contributor
  `dev/state/LEARNINGS.md`; do not imply that their caps, identity, sharding, or update contracts are shared.
- Memory Dashboard and Knowledge Hub labels – distinguish empty, degraded, observation, curated, archive, wiki, and KG.

## 0.25 and 0.27 Handoff Constraints

### 0.25 database and native search

- Treat 0.24 IDs, revisions, provenance, topics, and corpus selection as product semantics, not SQLite details.
- Keep search input natural-language; backend adapters own lexical/vector encoding.
- Preserve explicit canonical-save/index-degraded behavior across SQLite and PostgreSQL.
- Preserve citation locators across rebuild and backend switch.
- Build content fingerprints and stale-index reconciliation into the planned search abstraction instead of adding a
  second 0.24 consistency subsystem.
- Do not reproduce QMD's recursive `**/*.md` corpus by accident. Raw daily observations are episodic input, not default
  durable search authority.
- Gate embeddings and ranking with the frozen English/Swedish retrieval fixture before adding expansion or reranking.

### 0.27 steward

- Reuse `memory_observe` and host-validated `memory_apply`; do not introduce generic file replacement.
- Add scheduling only after explicit/on-demand curation proves CAS, provenance, failure, and rollback behavior.
- Keep steward output as structured proposals against a bounded snapshot.
- Decide retention/deletion separately and test every derived representation before removing source evidence.

## Applicable Competitor and Reference Lessons

- **Claude Code:** adopt the concise automatically loaded `MEMORY.md` entrypoint and on-demand topic-file shape. Keep
  DartClaw's settled 150-line/32 KiB projection and stronger IDs, CAS, shared locking, atomic commit, and reconciliation.
  Do not copy Claude Code's current soft-overflow behavior or repository-wide worktree sharing as an integrity or
  concurrency contract. Its rolling documentation currently loads the first 200 lines or 25 KB, whichever comes first,
  rather than imposing a hard persistent-file ceiling. See <https://code.claude.com/docs/en/memory>.
- **AndThen project learnings:** adopt the bounded index, concise pointers, and on-demand topic-shard shape demonstrated by
  [`dev/state/LEARNINGS.md`](../../../../state/LEARNINGS.md). Use it as a layout lesson only. DartClaw runtime memory needs
  stable host-owned IDs and transactional commits, not exact-title identity or instruction-only atomic graduation.

- **Letta:** a small always-visible core plus a larger retrieval tier supports the chosen progressive-disclosure direction.
  Do not copy shared last-write-wins model blocks or sleep-time agents. See
  <https://docs.letta.com/guides/core-concepts/memory/context-hierarchy>.
- **LangGraph:** keep thread state and cross-thread durable memory explicit; make background work idempotent and recovery
  boundaries observable. Do not copy its full checkpoint/time-travel infrastructure for memory. See
  <https://docs.langchain.com/oss/python/concepts/memory> and
  <https://docs.langchain.com/oss/python/langgraph/persistence>.
- **Mem0:** deterministic exact dedup, explicit scope, provenance history, and visible async processing are useful. Do not
  adopt its vector/entity/SQL multi-store burden or extraction on every write. See
  <https://docs.mem0.ai/core-concepts/memory-evaluation> and
  <https://docs.mem0.ai/api-reference/memory/history-memory>.
- **Zep/Graphiti:** derived facts should retain source lineage and deletion tests must cover derived data. Do not add graph
  databases, ontologies, cross-encoders, or observation machinery beyond the accepted 0.24 boundary. See
  <https://help.getzep.com/episodes>, <https://help.getzep.com/searching-the-graph>, and
  <https://help.getzep.com/deleting-data-from-the-graph>.

## Review Verification Record

- Exact baseline commit verified: `d24844bbf7a14ea65d27c6fd4b2cc3f5c70765a6`.
- `dart run dev/tools/arch_check.dart`: 8/8 checks passed.
- Focused core memory parser/file tests: 60 passed.
- 226 directly relevant test declarations were inventoried.
- A direct SQLite FTS5 probe confirmed raw punctuation can fail `MATCH` syntax.
- Storage/server/CLI focused suites could not load in the read-only review worktree because generated
  `embedded_assets.g.dart` files were absent. They were inspected statically, not claimed executed.
- The review did not modify code or project files.

## PRD and Plan Coverage Audit

Before approving the PRD and implementation plan, verify that they include stories and acceptance tests for every item:

- [ ] Remove consolidator, scheduled triggers, and obsolete documentation.
- [ ] Define canonical observation, curated index, topic, archive, runtime-learning, wiki, and KG roles, explicitly
  separating runtime `workspace/learnings.md` from contributor `dev/state/LEARNINGS.md`.
- [ ] Define stable ID, revision, timestamp, topic, provenance, and locator wire shapes.
- [ ] Implement observe/search/read/apply with one guarded mutation authority.
- [ ] Specify ordinary-turn autonomous mutation through the same contract.
- [ ] Specify bounded primary-turn index and on-demand topic retrieval for every provider path.
- [ ] Specify migration and byte-preserving handling of unknown legacy content.
- [ ] Specify CAS, shared locking, atomic multi-file commit, rollback, and cooperating shutdown.
- [ ] Specify live-index parity, explicit degraded state, reconciliation, and fresh-sibling rebuild.
- [ ] Specify natural-query ownership and shared backend/caller contract tests.
- [ ] Specify unique citation resolution through Search, Knowledge Hub, and Context Research.
- [ ] Specify per-file, count, total-byte, batch, prompt, and tool-output limits before allocation/mutation.
- [ ] Specify archive-limit behavior without inventing deletion policy.
- [ ] Remove duplicate wiki traversal and isolate per-file failure.
- [ ] Validate memory config ranges across every configuration surface.
- [ ] Remove unused vector/identity placeholders or explicitly assign them to an accepted 0.25 contract.
- [ ] Update ADR-002, ADR-007, ADR-029, ADR-042, ADR-045, and ADR-050 where described above.
- [ ] Update all user/operator docs and dashboard terminology in the same stories.
- [ ] Preserve QMD deprecation; add no QMD hardening or new dependency on its corpus semantics.
- [ ] Record 0.25 identity/corpus/index-health handoff constraints.
- [ ] Record 0.27 reuse of observe/apply/CAS and the prohibition on generic replacement.
- [ ] Map every architecture fitness function above to a story test, CI gate, release gate, or explicit deferred owner.
- [ ] Carry the review verification caveat forward; run the generated-asset setup and complete focused suites during
  implementation verification.
