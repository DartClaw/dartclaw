# Feature Implementation Specification: Observation and Retrieval Tools

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: Give agents a small, trustworthy way to capture non-authoritative experience and retrieve canonical memory or knowledge without confusing storage roles, source identity, or provider policy.

**Expected Outcomes**:

- [OC01] Agents can record a bounded observation or runtime learning with host-labelled provenance, while only learnings enter the existing bounded self-improvement store and neither role becomes curated personal memory.
- [OC02] Natural-language search and targeted reads return bounded, user-scoped, role-discriminated results whose locators resolve to canonical sources rather than derived chunks.
- [OC03] Existing journal and source-ingestion producers route observations and learnings through the new capture contract without broadening wiki/KG write semantics.
- [OC04] Claude and Codex policy/audit paths identify each memory tool exactly as read or write capability, while documented interception gaps remain explicit.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.3` – story scope, P2/W4 placement, S03 dependency, and expand-before-contract sequencing.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` – canonical corpus, single revision authority, prompt-authority boundary, stable locator, and natural-language query decisions inherited from S01–S03.
- `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` – canonical roles, source-of-truth rules, provenance, and the separation between personal memory, observations, learnings, archive, wiki, and KG.
- `dev/bundle/docs/specs/0.24/prd.md#fr2-guarded-memory-tools` – closed capture roles, bounded retrieval, user scope, validation, revision, indexing, and provider-policy contract.
- `dev/bundle/docs/specs/0.24/prd.md#fr5-retrieval-citation-and-index-integrity` – backend-owned query encoding, canonical locators, wiki ranking, and derived-index behavior.
- `dev/bundle/docs/specs/0.24/prd.md#user-flows` – observation capture and search→read flows this story must make executable.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – no new package/store/daemon and no broadened wiki/KG write contract.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – single-user runtime, Markdown canon, package boundaries, and shared serialization requirements.
- `dev/adrs/029-temporal-knowledge-graph-durable-knowledge-loop.md#decision` – wiki precedence, native provenance, and the existing knowledge-write boundary.
- `dev/adrs/042-context-research-synthesis-and-citation-model.md#decision` – shared source-reference shape and the rule that locator resolution proves existence, not semantic support.
- `dev/architecture/security-architecture.md#canonical-tool-taxonomy` – exact own-MCP canonicalization and raw provider-name audit contract.
- `dev/architecture/security-architecture.md#guard-chain-interception-per-provider` – Claude, Codex, and ACP enforcement limits that must remain truthful.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01] A primary turn records only a bounded `observation` or `learning`, and the host supplies owner scope, provenance, identity, and collection revision**
  - **Given** the S01–S03 corpus authority has a current collection revision and the model supplies only `text` plus a role from the closed set `observation|learning`
  - **When** `memory_observe` commits the item
  - **Then** an observation is stored as provenance-labelled, non-prompt-authoritative corpus content, a learning is stored through the bounded `learnings.md` role, the canonical write advances the shared revision, and the acknowledgement returns the canonical locator, role, revision, and index state
  - **And** `userId`, provenance, timestamp, and collision-sensitive identity come from trusted host context rather than model arguments
  - **Proof**: `packages/dartclaw_server/test/memory_handlers_test.dart#onSave reconciles capped learning rows to canonical content and timestamps` – green – parity/regression for bounded learning retention and canonical/index convergence

- [ ] **S02 [OC03] [TI01,TI05] Journal and source-ingestion producers classify durable items without promoting observations into personal topic memory**
  - **Given** a journal run containing decisions, insights, action-items, and learnings, or a knowledge-inbox finding with source locator `inbox/release-notes.md`
  - **When** the producer records each item
  - **Then** decisions, insights, action-items, and inbox findings use `memory_observe(role: observation)`, learnings use `memory_observe(role: learning)`, every item retains its host-known source provenance, and existing wiki/KG writes remain separately governed
  - **Proof**: `packages/dartclaw_server/test/behavior/memory_journal_test.dart#journal prompt pins the full selective untrusted-log contract` – green – parity/regression for selective journaling and untrusted-log handling

- [ ] **S03 [OC02] [TI02] Natural-language search returns bounded, ranked memory and wiki matches with canonical role and locator identity**
  - **Given** owner-scoped curated memory, observations, learnings, archive entries, and a source-backed wiki page, including two same-text entries with distinct canonical identities
  - **When** `memory_search` receives `project "Falcon" AND status?` with the default limit
  - **Then** the unchanged natural-language query reaches the selected backend, the backend alone encodes it, at most five results return, wiki synthesis ranks above raw personal memory for the same topic, and the same-text entries remain distinguishable by locator
  - **And** every result contains `role`, bounded `snippet`, `provenance`, `locator`, and `score`; curated personal-memory results additionally contain canonical `entryId` and `entryRevision`, while wiki results retain their native source identity and do not fabricate memory metadata
  - **Proof**: `packages/dartclaw_server/test/memory_handlers_test.dart#onSearch handles FTS5 operator chars safely` – green – parity/regression for punctuation/operator safety

- [ ] **S04 [OC02] [TI03] A search locator or role-and-topic selector reads bounded canonical content without exposing another user or a whole file**
  - **Given** a locator from S03 and canonical entries for `owner` plus a different `userId`
  - **When** `memory_read` is called with exactly one selector – that locator, or a canonical `role` plus `topic`
  - **Then** it resolves only owner-scoped canonical sources, returns the same role/provenance/locator identity as search, applies the fixed result and response bounds, and never returns an entire corpus file as an implicit fallback
  - **And** a missing locator or no-match topic returns an explicit empty/not-found result without substituting `MEMORY.md`, `archive`, or a derived row ID

- [ ] **S05 [OC01,OC02] [TI01,TI02,TI03] Invalid capture and retrieval requests fail before canonical or derived mutation**
  - **Given** an unknown observation role, absent trusted provenance, over-limit text, fractional/out-of-range selector data, or an invalid locator
  - **When** the corresponding tool is invoked
  - **Then** the request returns a typed application-level error, the collection revision and canonical files remain unchanged, and no index row is inserted, removed, or exposed across user scope

- [ ] **S06 [OC04] [TI04,TI06] Provider adapters preserve exact memory semantics and audit identity without overstating interception coverage**
  - **Given** own-MCP calls for `memory_observe`, `memory_search`, and `memory_read`, plus an unknown own-MCP call, on Claude and Codex app-server
  - **When** provider events enter guard evaluation
  - **Then** the three registered tools map one-to-one to canonical `memory_observe`, `memory_search`, and `memory_read`; observe is classified mutating while search/read are classified read-only; the unknown call remains `mcp_call`; and audit retains both canonical and raw provider identity
  - **And** session read-only policy blocks `memory_observe`, journal allowlists only `file_read` plus `memory_observe`, Claude uses its unfiltered hook, and Codex/ACP warnings continue to state their partial or absent interception cases

## Structural Criteria

- [ ] Canonical observation/learning writes use the S02 collection lock, validation, atomic commit, and revision authority; derived search remains rebuildable and never becomes the only copy.
- [ ] `memory_save` remains only for the expand-step compatibility window; this story neither removes it nor aliases it to the new role contract, and later `memory_apply`/contraction work is not pre-implemented.
- [ ] Existing wiki/KG producer ownership, Context Research citation semantics, and QMD fallback remain intact; no new wiki/KG mutation permission is granted.
- [ ] No new package, database, daemon, scheduler, approval framework, or provider abstraction is introduced.
- [ ] Provider-specific enforcement documentation and runtime warnings remain accurate: Claude hooks are broad, Codex depends on approval requests (`on-request` broadest), and ACP coverage is limited to verified reverse-call/permission seams.

## Scope & Boundaries

### Work Areas

- Canonical observation/learning handler and result contracts in core/server memory services
- Search result identity plus FTS5/QMD/wiki query and ranking seams
- Bounded MCP `memory_observe`, `memory_search`, and `memory_read` tools
- Canonical provider mapping, read-only classification, and guard/audit identity
- CLI/service wiring for the journal, knowledge inbox, and direct Claude SDK-MCP fallback
- Focused contract, storage, provider-adapter, and production-wiring tests

### What We're NOT Doing

- `memory_apply`, structured curated-memory changes, CAS conflict UX, or `memory_save` removal – the plan deliberately places replacement capture/retrieval before contraction.
- Primary-turn bounded-index prompt delivery – this story exposes revision-aware tools but does not change provider prompt composition.
- Broad Knowledge Hub/Context Research/UI convergence – this story supplies canonical role/locator results; downstream presentation and orchestration remain separate work.
- Autonomous curation, scheduling, or approval workflows – 0.24 keeps curation explicit and reuses existing operator/job surfaces.
- New wiki/KG writes or ownership policy – ADR-029 behavior remains unchanged and richer guarded knowledge writes remain 0.27 scope.

## Architecture Decision

**Approach**: Extend the existing memory handler, MCP, search-backend, and provider-canonicalization seams, but route canonical capture through the S01–S03 corpus/revision authority and carry one role/locator result shape end to end.
**Why this over alternatives**: It preserves Markdown canon and current provider boundaries without a second writer, store, generic MCP fallback, or speculative abstraction.

## Technical Overview

`memory_observe` has a closed model-facing payload: required `text` and required `role` (`observation` or `learning`), with no model-set `userId`, provenance, revision, timestamp, or identity fields. Trusted call context supplies those values; the shared inbound MCP gateway must use its truthful single-owner/tool-origin context and must not fabricate unavailable per-caller identity. Preserve the existing 65,536-character per-call text ceiling.

`memory_search` keeps the existing closed `query` plus `limit` contract (default 5, range 1–50), passes nonblank natural language unchanged into `SearchBackend`, and returns bounded role/locator records instead of category-formatted prose. `memory_read` accepts exactly one canonical selector – one `locator`, or `role` plus `topic` with optional `limit` (default 5, range 1–50) – and applies a 64 KiB UTF-8 response ceiling; responses report truncation instead of silently reading whole files. Neither tool accepts `userId`; production injects the current single-user scope (`owner`) through every backend and resolver.

All three tools receive exact own-MCP canonical identities. `memory_observe` is a write for deny/allow, read-only, and audit decisions; `memory_search` and `memory_read` are reads. Raw Claude/Codex names remain attached to audit entries. The direct Claude SDK-MCP fallback exposes the same schemas only when the HTTP MCP server is unavailable; Codex and ACP gain no fictional enforcement surface.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_server/lib/src/mcp/memory_tools.dart#MemorySaveTool | MCP schema/callback/result pattern to evolve
file | packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers | current capture/search/read bridge and validation seam
file | packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService | shared workspace lock, bounded files, and canonical file safety
file | packages/dartclaw_config/lib/src/search_backend.dart#SearchBackend | backend-owned natural-language query boundary
file | packages/dartclaw_storage/lib/src/storage/memory_service.dart#MemoryService | user-scoped FTS5 and canonical-row normalization pattern
file | packages/dartclaw_storage/lib/src/search/wiki_search_source.dart#WikiSearchSource | native wiki identity, provenance labels, and precedence
file | packages/dartclaw_storage/lib/src/search/qmd_search_backend.dart#QmdSearchBackend | raw QMD query ownership and FTS5 fallback
file | packages/dartclaw_core/lib/src/harness/canonical_tool.dart#CanonicalTool | stable provider-independent policy/audit identity
file | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#_buildMemorySdkMcpServers | direct-Claude fallback inventory and schema parity
file | packages/dartclaw_security/lib/src/task_tool_filter_guard.dart#TaskToolFilterGuard | per-session allowlist and read-only classification
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#HarnessWiring | registered-tool canonical map and provider warning boundary
file | apps/dartclaw_cli/lib/src/commands/wiring/scheduling_wiring.dart#SchedulingWiring | journal and knowledge-inbox producer wiring
```

## Constraints & Gotchas

- **Constraint**: Observation storage never confers prompt authority; only a later guarded curated-memory operation may promote useful content.
- **Constraint**: Search/read locators are canonical source identities from S01, never FTS row/chunk IDs or generic source labels such as `memory_save` or `archive`.
- **Constraint**: Wiki results retain native source identity and omit fabricated personal-memory `entryId`/`entryRevision`; source-backed facts remain wiki/KG-owned.
- **Critical**: Canonical commit and derived-index refresh are distinct outcomes – return saved-but-index-degraded facts with the new revision when indexing fails after a successful commit; S08 alone persists and clears index health.
- **Critical**: The shared inbound MCP gateway authenticates one deployment token, not a per-caller principal – record only the user/tool provenance the host truly knows.
- **Avoid**: Sanitizing in the MCP handler – pass natural language unchanged and let FTS5, QMD, and wiki implementations own their encoding.
- **Settled retrieval limits**: Retain the current 65,536-character capture ceiling and default 5/maximum 50 search results, and use the PRD's fixed 64 KiB read-response ceiling independently of `memory.max_bytes`, which bounds primary-turn prompt context rather than retrieval.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Observation capture has one closed, provenance-safe canonical contract
  - Reuse the S01–S03 corpus/revision authority from `packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers`; accept only `observation|learning`, inject trusted owner/provenance/identity, keep learning caps, and report revision plus index-reconciliation outcome facts for S08 to persist as health.
  - **Verify**: S01 and S05 pass, including revision advance on success, unchanged canon/revision/index on every pre-commit rejection, and saved-but-index-degraded after an injected index failure.

- [ ] **TI02** Search backends own query encoding and expose canonical role/locator matches
  - Carry one result contract through `SearchBackend`, FTS5, QMD, and wiki; callers pass raw natural language, user scope reaches every applicable backend, wiki remains higher-ranked, and chunk identity never leaks as source identity.
  - **Verify**: S03 passes against real in-memory FTS5 plus QMD/wiki fakes, including punctuation/operators, empty query, distinct same-text identities, owner isolation, limit bounds, native wiki identity, and fallback parity.

- [ ] **TI03** Memory reads resolve bounded canonical selectors rather than whole files
  - Resolve `locator` or `role`+`topic` through the canonical corpus service, reuse TI02's result identity, and return explicit not-found/truncated states within the fixed owner and response bounds.
  - **Verify**: S04 and the read cases of S05 pass; a locator returned by search round-trips to the same canonical source while cross-user, invalid, and whole-file fallback reads do not.

- [ ] **TI04** Provider policy and audit retain exact read/write memory semantics
  - Extend `CanonicalTool`, Claude/Codex own-MCP mapping, `TaskToolFilterGuard`, and the direct Claude inventory so observe is mutating, search/read are read-only, raw names remain auditable, and unknown MCP tools stay generic.
  - **Verify**: S06 passes through Claude hook mapping, Codex MCP approval mapping, task allowlist/read-only tests, and audit assertions without changing the documented Codex/ACP warning conditions.

- [ ] **TI05** Journal and source producers use observation/learning roles
  - The journal keeps its selective untrusted-log contract but maps decision/insight/action-item→observation and learning→learning with only `file_read`+`memory_observe`; knowledge inbox observations carry their source locator while its existing wiki/KG writes stay unchanged.
  - **Verify**: S02 passes in prompt, scheduling-wiring, run-now policy, knowledge-inbox integration, capped-learning, and provenance assertions; repository production references no longer use `memory_save` for these observation/learning producers.

- [ ] **TI06** The expand-step MCP surface is registered consistently across runtime paths
  - Register observe/search/read together, wire the new callbacks through harness factories, preserve `memory_save` only as the unmigrated compatibility surface, and keep SDK-MCP/HTTP-MCP schemas behaviorally identical.
  - **Verify**: MCP discovery/schema and production service-wiring tests expose exact semantic mappings for all three tools, do not map them to `mcp_call`, and still expose legacy `memory_save` without alias behavior; architecture checks show no new package, database, daemon, scheduler, approval framework, or provider abstraction.

### Testing Strategy

- Exercise handler contracts with the real in-memory FTS5 backend and temporary canonical Markdown; use fakes only to inject QMD/wiki/index failures and a second `userId`.
- Pin provider behavior at both semantic mapping seams: Claude `PreToolUse`/SDK-MCP inventory and Codex MCP approval requests. Keep policy tests explicit about the modes that cannot guarantee interception.
- Keep new-behavior scenarios as contract tests; the cited current tests are parity guards, not proof that the new tool surface already exists.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the FIS Mutability Contract. AUTO_MODE assumption-recording: see the automation-mode contract. Spec authors: leave this section empty._

_No observations recorded yet._
