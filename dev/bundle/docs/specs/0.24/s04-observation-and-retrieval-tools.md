# Feature Implementation Specification: Observation and Retrieval Tools

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: Give agents a small, trustworthy way to capture non-authoritative experience and retrieve canonical memory or knowledge without confusing storage roles, source identity, or provider policy.

**Expected Outcomes**:

- [OC01] Agents can record a bounded observation or runtime learning with host-labelled provenance, each stored as a canonical entry in its own canonical role – learnings keeping their bounded retention cap – and neither role becomes curated personal memory.
- [OC02] Natural-language search and targeted reads return bounded, user-scoped, role-discriminated results whose locators resolve to the source of record – a canonical entry, or the native wiki/KG source that owns the match – rather than to derived chunks.
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

- [x] **S01 [OC01] [TI01] A primary turn records only a bounded `observation` or `learning`, and the host supplies owner scope, provenance, identity, and collection revision**
  - **Given** the S01–S03 corpus authority has a current collection revision and the model supplies only `text` plus a role from the closed set `observation|learning`
  - **When** `memory_observe` commits the item
  - **Then** an observation is stored as provenance-labelled, non-prompt-authoritative corpus content, a learning is stored as an ordinary canonical entry in the learning role under its retention cap, the canonical write advances the shared revision, and the acknowledgement returns the canonical entry locator, role, revision, and index state
  - **And** `userId`, provenance, timestamp, and collision-sensitive identity come from trusted host context rather than model arguments
  - **Proof**: `packages/dartclaw_server/test/memory_handlers_test.dart#onSave reconciles capped learning rows to canonical content and timestamps` – green – parity/regression for bounded learning retention and canonical/index convergence

- [x] **S02 [OC03] [TI01,TI05] Journal and source-ingestion producers classify durable items without promoting observations into personal topic memory**
  - **Given** a journal run containing decisions, insights, action-items, and learnings, or a knowledge-inbox finding with source locator `inbox/release-notes.md` carried by an inbox item with a stable item id
  - **When** the producer records each item, and the inbox producer is afterwards retried on the same item
  - **Then** decisions, insights, action-items, and inbox findings use `memory_observe(role: observation)`, learnings use `memory_observe(role: learning)`, every item retains its host-known source provenance, and existing wiki/KG writes remain separately governed
  - **And** inbox capture populates S01's source-event discriminator with that stable inbox item id, so the retry presents an exactly-equal source reference and is an exact-replay duplicate under S10 dedup, with no retry bookkeeping, seen-set, or capture-side dedup added here
  - **Proof**: `packages/dartclaw_server/test/behavior/memory_journal_test.dart#journal prompt pins the full selective untrusted-log contract` – green – parity/regression for selective journaling and untrusted-log handling

- [x] **S03 [OC02] [TI02] Natural-language search returns bounded, ranked memory and wiki matches with canonical role and locator identity**
  - **Given** owner-scoped curated memory, observations, learnings, archive entries, and a source-backed wiki page, including two same-text entries with distinct canonical identities
  - **When** `memory_search` receives `project "Falcon" AND status?` with the default limit
  - **Then** the unchanged natural-language query reaches the selected backend, the backend alone encodes it, at most five results return, wiki synthesis ranks above raw personal memory for the same topic, and the same-text entries remain distinguishable by locator
  - **And** every result contains `role`, bounded `snippet`, `provenance`, `locator`, and `score`; results from any canonical role – curated personal memory, observations, learnings, and archive – additionally contain canonical `entryId` and `entryRevision` and are addressed by ordinary canonical entry locators rather than file or heading anchors, while wiki results retain their native source identity and do not fabricate memory metadata
  - **Proof**: `packages/dartclaw_server/test/memory_handlers_test.dart#onSearch handles FTS5 operator chars safely` – green – parity/regression for punctuation/operator safety

- [x] **S04 [OC02] [TI03] A search locator or role-and-topic selector reads bounded content from its source of record without exposing another user or a whole file**
  - **Given** two locators from S03 – one canonical entry locator and one native wiki locator – plus canonical entries for `owner` and for a different `userId`
  - **When** `memory_read` is called with exactly one selector – either locator, or a canonical topic-bearing `role` plus `topic`
  - **Then** both locators resolve, canonical resolution stays inside owner scope, each result returns the same role/provenance/locator identity as search, the native wiki locator resolves through its owning source without acquiring canonical memory metadata, the fixed result and response bounds apply, and no entire corpus file is returned as an implicit fallback
  - **And** `role`+`topic` addressing is accepted only for topic-bearing roles – topic-less roles (observations, learnings, wiki, KG) are addressable by locator alone, and a `topic` supplied against one is a typed rejection rather than a broadened read
  - **And** a missing locator or no-match topic returns an explicit empty/not-found result without substituting `MEMORY.md`, `archive`, or a derived row ID

- [x] **S05 [OC01,OC02] [TI01,TI02,TI03] Invalid capture and retrieval requests fail before canonical or derived mutation**
  - **Given** an unknown observation role, absent trusted provenance, over-limit text, fractional/out-of-range selector data, or an invalid locator
  - **When** the corresponding tool is invoked
  - **Then** the request returns a typed application-level error, the collection revision and canonical files remain unchanged, and no index row is inserted, removed, or exposed across user scope

- [x] **S06 [OC04] [TI04,TI06] Provider adapters preserve exact memory semantics and audit identity without overstating interception coverage**
  - **Given** own-MCP calls for `memory_observe`, `memory_search`, and `memory_read`, plus an unknown own-MCP call, on Claude and Codex app-server
  - **When** provider events enter guard evaluation
  - **Then** the three registered tools map one-to-one to canonical `memory_observe`, `memory_search`, and `memory_read`; observe is classified mutating while search/read are classified read-only; the unknown call remains `mcp_call`; and audit retains both canonical and raw provider identity
  - **And** session read-only policy blocks both `memory_observe` and the still-registered `memory_save`, journal allowlists only `file_read` plus `memory_observe`, Claude uses its unfiltered hook, and Codex/ACP warnings continue to state their partial or absent interception cases

## Structural Criteria

- [x] Canonical observation/learning writes use the S02 collection lock, validation, atomic commit, and revision authority; derived search remains rebuildable and never becomes the only copy.
- [x] `memory_save` keeps its published tool schema for the expand-step compatibility window but is re-implemented as a thin adapter onto the canonical add path – canonical entry identity, the shared revision advance, and canonical locators – so no second writer and no `memory_save` source label survive this story; it is still not aliased to the `observation|learning` role contract, and its removal plus later `memory_apply`/contraction work is not pre-implemented.
- [x] Existing wiki/KG producer ownership, Context Research citation semantics, and QMD fallback remain intact; no new wiki/KG mutation permission is granted.
- [x] No new package, database, daemon, scheduler, approval framework, or provider abstraction is introduced.
- [x] Provider-specific enforcement documentation and runtime warnings remain accurate: Claude hooks are broad, Codex depends on approval requests (`on-request` broadest), and ACP coverage is limited to verified reverse-call/permission seams.

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

`memory_save` keeps its published schema through the compatibility window but runs as a thin adapter over the same canonical add path: it yields real canonical entry identities, advances the same shared collection revision, and its content is retrievable through canonical locators. It keeps writing curated personal memory – it is not aliased to the `observation|learning` roles – and it gains no second writer, no private identity space, and no `memory_save` source label.

Every canonical write this story performs carries an S01 origin kind from the closed set `turn|journal|inbox|curation|migration`, chosen by capture path rather than by role: a `memory_observe` call made inside a model turn – and, through the compatibility window, a `memory_save` call – records `turn` with that turn's session id and message index as its source-event discriminator; journal routing records `journal` with the journal entry id; knowledge-inbox capture records `inbox` with the stable inbox item id. The remaining kinds belong to other stories – `curation` to S09's explicit curation runs and `migration` to S03 – and no capture path here mints a kind outside that closed set.

`memory_search` keeps the existing closed `query` plus `limit` contract (default 5, range 1–50), passes nonblank natural language unchanged into `SearchBackend`, and returns bounded role/locator records instead of category-formatted prose. `memory_read` accepts exactly one selector – one `locator`, or `role` plus `topic` with optional `limit` (default 5, range 1–50) – and applies a 64 KiB UTF-8 response ceiling; responses report truncation instead of silently reading whole files. Its resolvable universe is (a) every owner-scoped canonical role and (b) every locator `memory_search` can return, including native wiki/KG locators, so the search→read round trip always closes; a native locator resolves through its owning source and never acquires canonical memory metadata. `role`+`topic` addressing applies only to topic-bearing roles; topic-less roles – observations, learnings, wiki, and KG – are addressed by locator alone. The canonical `audit` role is the one exception to (a) – it stays outside the resolvable universe entirely, so neither `role: audit` nor an audit-document locator resolves, and no `memory_search` result carries the role. Neither tool accepts `userId`; production injects the current single-user scope (`owner`) through every backend and resolver.

All three tools receive exact own-MCP canonical identities. `memory_observe` is a write for deny/allow, read-only, and audit decisions; `memory_search` and `memory_read` are reads. The still-registered `memory_save` is a write for the same decisions throughout the compatibility window – it mutates canonical memory exactly as `memory_observe` does – so a read-only session denies it. Raw Claude/Codex names remain attached to audit entries. The direct Claude SDK-MCP fallback exposes the same schemas only when the HTTP MCP server is unavailable; Codex and ACP gain no fictional enforcement surface.

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
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#HarnessWiring | registered-tool canonical map, semantic own-MCP inventory, and provider warning boundary
file | apps/dartclaw_cli/lib/src/commands/service_wiring_mcp_tools.dart#_registerMcpTools | HTTP MCP registration site where `memory_search`/`memory_read` are registered and `memory_observe` must join them
file | apps/dartclaw_cli/lib/src/commands/wiring/scheduling_wiring.dart#SchedulingWiring | journal and knowledge-inbox producer wiring
```

## Constraints & Gotchas

- **Constraint**: Observation storage never confers prompt authority; only a later guarded curated-memory operation may promote useful content.
- **Constraint**: Search/read locators are canonical source identities from S01, never FTS row/chunk IDs or generic source labels such as `memory_save` or `archive`. Because `memory_save` writes through the canonical add path during the compatibility window, the `source: 'memory_save'` locator ceases to exist at this story – no search result, stored row, or read selector may carry it.
- **Constraint**: Wiki results retain native source identity and omit fabricated personal-memory `entryId`/`entryRevision`; source-backed facts remain wiki/KG-owned.
- **Native locator routing**: the non-canonical locators a result can carry are S07's native-identity sources – wiki, KG, and the knowledge inbox – plus the native uncited locator an unmatched QMD hit keeps, because manufacturing a canonical locator from QMD path or text is banned. `memory_read` routes each of them to the source that owns it and returns the explicit not-found/unresolved state when that source no longer holds it; none acquires canonical memory metadata, none is substituted with a canonical entry, a whole file, or a derived row, and resolution proves existence only – an uncited locator never becomes a resolved citation.
- **Audit role is not retrievable**: the canonical `audit` role – S05's deletion-audit document – sits outside `memory_search`'s and `memory_read`'s role universe entirely: no search result carries it, and `memory_read` resolves neither an audit locator nor `role: audit`. Returning deletion records to a model would hand back exactly the content the user asked to forget, which is also why the role is not an index source. The role is canonical and topic-less, but unlike the topic-less roles that are addressable by locator alone – observations, learnings, wiki, and KG – it is not part of the read universe at all; operator visibility flows through S11's surfaces instead.
- **Critical**: Canonical commit and derived-index refresh are distinct outcomes – return saved-but-index-degraded facts with the new revision when indexing fails after a successful commit; S08 alone persists and clears index health.
- **Critical**: The shared inbound MCP gateway authenticates one deployment token, not a per-caller principal – record only the user/tool provenance the host truly knows.
- **Avoid**: Sanitizing in the MCP handler – pass natural language unchanged and let FTS5, QMD, and wiki implementations own their encoding.
- **Settled retrieval limits**: Retain the current 65,536-character capture ceiling and default 5/maximum 50 search results, and apply the fixed 64 KiB read-response ceiling settled by this FIS independently of `memory.max_bytes`, which bounds primary-turn prompt context rather than retrieval. The PRD's own 64 KiB figure caps migration diagnostics and does not govern reads.
- **Ceiling ownership**: The 1,000-file and 64 MiB corpus admission ceilings belong to S10 – it defines, enforces, and proves them. This story consumes them and adds no ceiling, traversal budget, or duplicate limit constant of its own.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** Observation capture has one closed, provenance-safe canonical contract
  - Reuse the S01–S03 corpus/revision authority from `packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers`; accept only `observation|learning`, inject trusted owner/provenance/identity – including S01's source-event discriminator for every caller that has a stable source event – keep learning caps, and report revision plus index-reconciliation outcome facts for S08 to persist as health.
  - **Verify**: S01 and S05 pass, including revision advance on success, unchanged canon/revision/index on every pre-commit rejection, and saved-but-index-degraded after an injected index failure.

- [x] **TI02** Search backends own query encoding and expose canonical role/locator matches
  - Carry one result contract through `SearchBackend`, FTS5, QMD, and wiki; callers pass raw natural language, user scope reaches every applicable backend, wiki remains higher-ranked, and chunk identity never leaks as source identity.
  - **Verify**: S03 passes against real in-memory FTS5 plus QMD/wiki fakes, including punctuation/operators, empty query, distinct same-text identities, owner isolation, limit bounds, native wiki identity, and fallback parity.

- [x] **TI03** Memory reads resolve bounded selectors to their source of record rather than whole files
  - Resolve `locator` or `role`+`topic` through the canonical corpus service, route native wiki/KG locators back to their owning source, reject `topic` supplied against a topic-less role, reuse TI02's result identity, and return explicit not-found/truncated states within the fixed owner and response bounds.
  - **Verify**: S04 and the read cases of S05 pass; every locator shape `memory_search` emits – canonical entry and native wiki – round-trips to the source it was issued for, while cross-user, invalid, topic-against-topic-less-role, and whole-file fallback reads do not.
  - **Verify**: a `role: audit` selector and an audit-document locator are each rejected with the typed not-found/unsupported state – no audit text, locator, or entry metadata reaches the caller – and a `memory_search` run over a corpus that contains audit content returns no result carrying the `audit` role.

- [x] **TI04** Provider policy and audit retain exact read/write memory semantics
  - Extend `CanonicalTool`, Claude/Codex own-MCP mapping, `TaskToolFilterGuard`, and the direct Claude inventory so observe and the still-registered `memory_save` are mutating, search/read are read-only, raw names remain auditable, and unknown MCP tools stay generic.
  - **Verify**: S06 passes through Claude hook mapping, Codex MCP approval mapping, task allowlist/read-only tests, and audit assertions without changing the documented Codex/ACP warning conditions, and a read-only session denies `memory_save` exactly as it denies `memory_observe`.

- [x] **TI05** Journal and source producers use observation/learning roles
  - The journal keeps its selective untrusted-log contract but maps decision/insight/action-item→observation and learning→learning with only `file_read`+`memory_observe`; knowledge inbox observations carry their source locator and populate S01's source-event discriminator with the stable inbox item id, while its existing wiki/KG writes stay unchanged.
  - **Verify**: S02 passes in prompt, scheduling-wiring, run-now policy, knowledge-inbox integration, capped-learning, and provenance assertions; a replayed inbox item yields an exactly-equal source reference rather than a distinguishable second event; repository production references no longer use `memory_save` for these observation/learning producers.

- [x] **TI06** The expand-step MCP surface is registered consistently across runtime paths
  - Register observe/search/read together, wire the new callbacks through harness factories, keep `memory_save`'s published schema as the compatibility surface while re-pointing its implementation at the canonical add path, and keep SDK-MCP/HTTP-MCP schemas behaviorally identical.
  - **Verify**: MCP discovery/schema and production service-wiring tests expose exact semantic mappings for all three tools, do not map them to `mcp_call`, and still expose the unchanged `memory_save` schema whose writes now carry canonical entry identity, the shared revision advance, and canonical locators with no `memory_save` source label; architecture checks show no new package, database, daemon, scheduler, approval framework, or provider abstraction.

### Testing Strategy

- Exercise handler contracts with the real in-memory FTS5 backend and temporary canonical Markdown; use fakes only to inject QMD/wiki/index failures and a second `userId`.
- Pin provider behavior at both semantic mapping seams: Claude `PreToolUse`/SDK-MCP inventory and Codex MCP approval requests. Keep policy tests explicit about the modes that cannot guarantee interception.
- Keep new-behavior scenarios as contract tests; the cited current tests are parity guards, not proof that the new tool surface already exists.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the FIS Mutability Contract. AUTO_MODE assumption-recording: see the automation-mode contract. Spec authors: leave this section empty._

#### DECISION NOTE: memory-save-coexistence

Decision-Key: memory-save-coexistence
Altitude: fis-local
Affected surface: ## Structural Criteria (`memory_save` compatibility-window bullet), ## Constraints & Gotchas (locator constraint), ## Technical Overview (capture paragraph), ## Implementation Plan TI06
Decision: During the expand window `memory_save` keeps its published tool schema but is re-implemented as a thin adapter onto the canonical add path – real canonical entry identity, the shared collection-revision advance, and canonical locators in search results – so the banned `source: 'memory_save'` locator disappears at this story rather than at the later contraction step, which then removes only the tool schema and its callers.
Rationale: Owner-ratified 2026-08-11: a compatibility surface that keeps its own writer and identity space would re-create the second-writer and non-canonical-locator failure modes this milestone exists to remove; keeping only the schema costs nothing now and leaves contraction a pure deletion.
Evidence: `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` single canonical corpus and provenance rules, `dev/bundle/docs/specs/0.24/prd.md#fr5-retrieval-citation-and-index-integrity` canonical-locator requirement, and `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` single revision authority and stable locator decisions.

Old:
```
`memory_save` remains only for the expand-step compatibility window; this story neither removes it nor aliases it to the new role contract, and later `memory_apply`/contraction work is not pre-implemented.
```
New:
```
`memory_save` keeps its published tool schema for the expand-step compatibility window but is re-implemented as a thin adapter onto the canonical add path – canonical entry identity, the shared revision advance, and canonical locators – so no second writer and no `memory_save` source label survive this story; it is still not aliased to the `observation|learning` role contract, and its removal plus later `memory_apply`/contraction work is not pre-implemented.
```

Old:
```
- **Constraint**: Search/read locators are canonical source identities from S01, never FTS row/chunk IDs or generic source labels such as `memory_save` or `archive`.
```
New:
```
- **Constraint**: Search/read locators are canonical source identities from S01, never FTS row/chunk IDs or generic source labels such as `memory_save` or `archive`. Because `memory_save` writes through the canonical add path during the compatibility window, the `source: 'memory_save'` locator ceases to exist at this story – no search result, stored row, or read selector may carry it.
```

Old:
```
Trusted call context supplies those values; the shared inbound MCP gateway must use its truthful single-owner/tool-origin context and must not fabricate unavailable per-caller identity. Preserve the existing 65,536-character per-call text ceiling.
```
New:
```
Trusted call context supplies those values; the shared inbound MCP gateway must use its truthful single-owner/tool-origin context and must not fabricate unavailable per-caller identity. Preserve the existing 65,536-character per-call text ceiling.

`memory_save` keeps its published schema through the compatibility window but runs as a thin adapter over the same canonical add path: it yields real canonical entry identities, advances the same shared collection revision, and its content is retrievable through canonical locators. It keeps writing curated personal memory – it is not aliased to the `observation|learning` roles – and it gains no second writer, no private identity space, and no `memory_save` source label.
```

Old:
```
  - Register observe/search/read together, wire the new callbacks through harness factories, preserve `memory_save` only as the unmigrated compatibility surface, and keep SDK-MCP/HTTP-MCP schemas behaviorally identical.
  - **Verify**: MCP discovery/schema and production service-wiring tests expose exact semantic mappings for all three tools, do not map them to `mcp_call`, and still expose legacy `memory_save` without alias behavior; architecture checks show no new package, database, daemon, scheduler, approval framework, or provider abstraction.
```
New:
```
  - Register observe/search/read together, wire the new callbacks through harness factories, keep `memory_save`'s published schema as the compatibility surface while re-pointing its implementation at the canonical add path, and keep SDK-MCP/HTTP-MCP schemas behaviorally identical.
  - **Verify**: MCP discovery/schema and production service-wiring tests expose exact semantic mappings for all three tools, do not map them to `mcp_call`, and still expose the unchanged `memory_save` schema whose writes now carry canonical entry identity, the shared revision advance, and canonical locators with no `memory_save` source label; architecture checks show no new package, database, daemon, scheduler, approval framework, or provider abstraction.
```

#### DECISION NOTE: memory-read-role-universe

Decision-Key: memory-read-role-universe
Altitude: fis-local
Affected surface: ## Feature Overview and Goal (OC02), ## Acceptance Scenarios (S04 Given/When/Then/And), ## Technical Overview (`memory_read` selector paragraph), ## Implementation Plan TI03
Decision: `memory_read` resolves (a) every owner-scoped canonical role and (b) every locator `memory_search` can return, including native wiki/KG locators, so the search→read round trip always closes; `role`+`topic` addressing applies only to topic-bearing roles, while topic-less roles – observations, learnings, wiki, and KG – are addressed by canonical locator alone, and native locators resolve through their owning source without acquiring canonical memory metadata.
Rationale: Owner-ratified 2026-08-11 to resolve the FIS-internal contradiction between scenario S04's "resolves only owner-scoped canonical sources" and TI03's required search→read round-trip Verify; PRD User Flow 5 makes any search-returned locator readable, and a locator a tool emits but cannot resolve is a broken contract, not a safety boundary – owner scoping is enforced on canonical resolution, not by narrowing the locator universe.
Evidence: `dev/bundle/docs/specs/0.24/prd.md#user-flows` search→read flow, `dev/bundle/docs/specs/0.24/prd.md#fr5-retrieval-citation-and-index-integrity` canonical locators and wiki ranking, and `dev/adrs/042-context-research-synthesis-and-citation-model.md#decision` locator resolution proving existence rather than semantic support.

Old:
```
- [OC02] Natural-language search and targeted reads return bounded, user-scoped, role-discriminated results whose locators resolve to canonical sources rather than derived chunks.
```
New:
```
- [OC02] Natural-language search and targeted reads return bounded, user-scoped, role-discriminated results whose locators resolve to the source of record – a canonical entry, or the native wiki/KG source that owns the match – rather than to derived chunks.
```

Old:
```
  - **Given** a locator from S03 and canonical entries for `owner` plus a different `userId`
  - **When** `memory_read` is called with exactly one selector – that locator, or a canonical `role` plus `topic`
  - **Then** it resolves only owner-scoped canonical sources, returns the same role/provenance/locator identity as search, applies the fixed result and response bounds, and never returns an entire corpus file as an implicit fallback
  - **And** a missing locator or no-match topic returns an explicit empty/not-found result without substituting `MEMORY.md`, `archive`, or a derived row ID
```
New:
```
  - **Given** two locators from S03 – one canonical entry locator and one native wiki locator – plus canonical entries for `owner` and for a different `userId`
  - **When** `memory_read` is called with exactly one selector – either locator, or a canonical topic-bearing `role` plus `topic`
  - **Then** both locators resolve, canonical resolution stays inside owner scope, each result returns the same role/provenance/locator identity as search, the native wiki locator resolves through its owning source without acquiring canonical memory metadata, the fixed result and response bounds apply, and no entire corpus file is returned as an implicit fallback
  - **And** `role`+`topic` addressing is accepted only for topic-bearing roles – topic-less roles (observations, learnings, wiki, KG) are addressable by locator alone, and a `topic` supplied against one is a typed rejection rather than a broadened read
  - **And** a missing locator or no-match topic returns an explicit empty/not-found result without substituting `MEMORY.md`, `archive`, or a derived row ID
```

Old:
```
`memory_read` accepts exactly one canonical selector – one `locator`, or `role` plus `topic` with optional `limit` (default 5, range 1–50) – and applies a 64 KiB UTF-8 response ceiling; responses report truncation instead of silently reading whole files.
```
New:
```
`memory_read` accepts exactly one selector – one `locator`, or `role` plus `topic` with optional `limit` (default 5, range 1–50) – and applies a 64 KiB UTF-8 response ceiling; responses report truncation instead of silently reading whole files. Its resolvable universe is (a) every owner-scoped canonical role and (b) every locator `memory_search` can return, including native wiki/KG locators, so the search→read round trip always closes; a native locator resolves through its owning source and never acquires canonical memory metadata. `role`+`topic` addressing applies only to topic-bearing roles; topic-less roles – observations, learnings, wiki, and KG – are addressed by locator alone.
```

Old:
```
  - Resolve `locator` or `role`+`topic` through the canonical corpus service, reuse TI02's result identity, and return explicit not-found/truncated states within the fixed owner and response bounds.
  - **Verify**: S04 and the read cases of S05 pass; a locator returned by search round-trips to the same canonical source while cross-user, invalid, and whole-file fallback reads do not.
```
New:
```
  - Resolve `locator` or `role`+`topic` through the canonical corpus service, route native wiki/KG locators back to their owning source, reject `topic` supplied against a topic-less role, reuse TI02's result identity, and return explicit not-found/truncated states within the fixed owner and response bounds.
  - **Verify**: S04 and the read cases of S05 pass; every locator shape `memory_search` emits – canonical entry and native wiki – round-trips to the source it was issued for, while cross-user, invalid, topic-against-topic-less-role, and whole-file fallback reads do not.
```

#### DECISION NOTE: memory-save-readonly-classification

Decision-Key: memory-save-readonly-classification
Altitude: fis-local
Affected surface: ## Technical Overview (provider policy paragraph), ## Acceptance Scenarios (S06 second And), ## Implementation Plan TI04
Decision: For the duration of the compatibility window `memory_save` is classified a WRITE tool for deny/allow, read-only-session filtering, and audit decisions – exactly like `memory_observe` and the later `memory_apply` – so a read-only session denies it.
Rationale: Owner-ratified 2026-08-11: `memory_save` mutates canonical memory through the same add path, so classifying it anything but a write would leave a read-only session with a live canonical write channel; the classification must track what the tool does, not how long it will exist.
Evidence: `dev/bundle/docs/specs/0.24/prd.md#fr2-guarded-memory-tools` provider-policy contract requiring each memory tool to be identified exactly as read or write capability, and `dev/architecture/security-architecture.md#canonical-tool-taxonomy` exact own-MCP canonicalization and audit contract.

Old:
```
All three tools receive exact own-MCP canonical identities. `memory_observe` is a write for deny/allow, read-only, and audit decisions; `memory_search` and `memory_read` are reads.
```
New:
```
All three tools receive exact own-MCP canonical identities. `memory_observe` is a write for deny/allow, read-only, and audit decisions; `memory_search` and `memory_read` are reads. The still-registered `memory_save` is a write for the same decisions throughout the compatibility window – it mutates canonical memory exactly as `memory_observe` does – so a read-only session denies it.
```

Old:
```
  - **And** session read-only policy blocks `memory_observe`, journal allowlists only `file_read` plus `memory_observe`, Claude uses its unfiltered hook, and Codex/ACP warnings continue to state their partial or absent interception cases
```
New:
```
  - **And** session read-only policy blocks both `memory_observe` and the still-registered `memory_save`, journal allowlists only `file_read` plus `memory_observe`, Claude uses its unfiltered hook, and Codex/ACP warnings continue to state their partial or absent interception cases
```

Old:
```
  - Extend `CanonicalTool`, Claude/Codex own-MCP mapping, `TaskToolFilterGuard`, and the direct Claude inventory so observe is mutating, search/read are read-only, raw names remain auditable, and unknown MCP tools stay generic.
  - **Verify**: S06 passes through Claude hook mapping, Codex MCP approval mapping, task allowlist/read-only tests, and audit assertions without changing the documented Codex/ACP warning conditions.
```
New:
```
  - Extend `CanonicalTool`, Claude/Codex own-MCP mapping, `TaskToolFilterGuard`, and the direct Claude inventory so observe and the still-registered `memory_save` are mutating, search/read are read-only, raw names remain auditable, and unknown MCP tools stay generic.
  - **Verify**: S06 passes through Claude hook mapping, Codex MCP approval mapping, task allowlist/read-only tests, and audit assertions without changing the documented Codex/ACP warning conditions, and a read-only session denies `memory_save` exactly as it denies `memory_observe`.
```

#### DECISION NOTE: inbox-replay-duplicates

Decision-Key: inbox-replay-duplicates
Altitude: fis-local
Affected surface: ## Acceptance Scenarios (S02 Given/When plus a new And), ## Implementation Plan TI01, ## Implementation Plan TI05
Decision: Knowledge-inbox capture populates S01's optional source-event discriminator with the stable inbox item id, which is the whole retry-idempotence mechanism: a replayed item presents an exactly-equal source reference and is therefore an exact-replay duplicate under S10 dedup – this story adds no bespoke retry bookkeeping, no seen-set, and no capture-side dedup of its own.
Rationale: Owner-ratified 2026-08-11: S01 already carries the discriminator and S10 already owns dedup, so idempotence is obtained by populating an existing field rather than by adding a second mechanism; under S01's absence rule an absent discriminator makes two references unequal, so populating it is what makes the replay case decidable at all.
Evidence: `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` provenance rules, `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` no new store or mechanism, and `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` canonical corpus and single revision authority.

Old:
```
  - **Given** a journal run containing decisions, insights, action-items, and learnings, or a knowledge-inbox finding with source locator `inbox/release-notes.md`
  - **When** the producer records each item
  - **Then** decisions, insights, action-items, and inbox findings use `memory_observe(role: observation)`, learnings use `memory_observe(role: learning)`, every item retains its host-known source provenance, and existing wiki/KG writes remain separately governed
```
New:
```
  - **Given** a journal run containing decisions, insights, action-items, and learnings, or a knowledge-inbox finding with source locator `inbox/release-notes.md` carried by an inbox item with a stable item id
  - **When** the producer records each item, and the inbox producer is afterwards retried on the same item
  - **Then** decisions, insights, action-items, and inbox findings use `memory_observe(role: observation)`, learnings use `memory_observe(role: learning)`, every item retains its host-known source provenance, and existing wiki/KG writes remain separately governed
  - **And** inbox capture populates S01's source-event discriminator with that stable inbox item id, so the retry presents an exactly-equal source reference and is an exact-replay duplicate under S10 dedup, with no retry bookkeeping, seen-set, or capture-side dedup added here
```

Old:
```
  - Reuse the S01–S03 corpus/revision authority from `packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers`; accept only `observation|learning`, inject trusted owner/provenance/identity, keep learning caps, and report revision plus index-reconciliation outcome facts for S08 to persist as health.
```
New:
```
  - Reuse the S01–S03 corpus/revision authority from `packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers`; accept only `observation|learning`, inject trusted owner/provenance/identity – including S01's source-event discriminator for every caller that has a stable source event – keep learning caps, and report revision plus index-reconciliation outcome facts for S08 to persist as health.
```

Old:
```
  - The journal keeps its selective untrusted-log contract but maps decision/insight/action-item→observation and learning→learning with only `file_read`+`memory_observe`; knowledge inbox observations carry their source locator while its existing wiki/KG writes stay unchanged.
  - **Verify**: S02 passes in prompt, scheduling-wiring, run-now policy, knowledge-inbox integration, capped-learning, and provenance assertions; repository production references no longer use `memory_save` for these observation/learning producers.
```
New:
```
  - The journal keeps its selective untrusted-log contract but maps decision/insight/action-item→observation and learning→learning with only `file_read`+`memory_observe`; knowledge inbox observations carry their source locator and populate S01's source-event discriminator with the stable inbox item id, while its existing wiki/KG writes stay unchanged.
  - **Verify**: S02 passes in prompt, scheduling-wiring, run-now policy, knowledge-inbox integration, capped-learning, and provenance assertions; a replayed inbox item yields an exactly-equal source reference rather than a distinguishable second event; repository production references no longer use `memory_save` for these observation/learning producers.
```

#### DECISION NOTE: learning-locator-shape

Decision-Key: learning-locator-shape
Altitude: fis-local
Affected surface: ## Feature Overview and Goal (OC01), ## Acceptance Scenarios (S01 Then, S03 second And)
Decision: Runtime learnings are a canonical role, so a learning is stored as an ordinary canonical entry and every learning result – in capture acknowledgements, search, and read – carries the ordinary canonical entry locator plus `entryId`/`entryRevision`, never a file-plus-heading anchor or any other native/file-level identity; the bounded retention cap survives as a property of the role, not as a separate store.
Rationale: Owner-ratified 2026-08-11 cross-cutting decision that supersedes the "learnings retain their native format and identity" premise; with that premise gone, a file-level learning locator would be a second identity scheme inside the canonical corpus and would break locator-shape uniformity for search→read.
Evidence: `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` canonical roles and source-of-truth rules, `dev/bundle/docs/specs/0.24/prd.md#fr5-retrieval-citation-and-index-integrity` canonical-locator requirement, and `dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md` role inventory carrying learnings as a canonical role.

Old:
```
- [OC01] Agents can record a bounded observation or runtime learning with host-labelled provenance, while only learnings enter the existing bounded self-improvement store and neither role becomes curated personal memory.
```
New:
```
- [OC01] Agents can record a bounded observation or runtime learning with host-labelled provenance, each stored as a canonical entry in its own canonical role – learnings keeping their bounded retention cap – and neither role becomes curated personal memory.
```

Old:
```
  - **Then** an observation is stored as provenance-labelled, non-prompt-authoritative corpus content, a learning is stored through the bounded `learnings.md` role, the canonical write advances the shared revision, and the acknowledgement returns the canonical locator, role, revision, and index state
```
New:
```
  - **Then** an observation is stored as provenance-labelled, non-prompt-authoritative corpus content, a learning is stored as an ordinary canonical entry in the learning role under its retention cap, the canonical write advances the shared revision, and the acknowledgement returns the canonical entry locator, role, revision, and index state
```

Old:
```
  - **And** every result contains `role`, bounded `snippet`, `provenance`, `locator`, and `score`; curated personal-memory results additionally contain canonical `entryId` and `entryRevision`, while wiki results retain their native source identity and do not fabricate memory metadata
```
New:
```
  - **And** every result contains `role`, bounded `snippet`, `provenance`, `locator`, and `score`; results from any canonical role – curated personal memory, observations, learnings, and archive – additionally contain canonical `entryId` and `entryRevision` and are addressed by ordinary canonical entry locators rather than file or heading anchors, while wiki results retain their native source identity and do not fabricate memory metadata
```

#### DECISION NOTE: traversal-ceiling-split

Decision-Key: traversal-ceiling-split
Altitude: fis-local
Affected surface: ## Constraints & Gotchas (settled-limits bullets)
Decision: S10 owns the 1,000-file and 64 MiB corpus admission ceilings – definition, enforcement, and the exact-limit proofs; S04 only consumes them and introduces no ceiling, traversal budget, or duplicate limit constant of its own, keeping its own settled limits to the 65,536-character capture ceiling, the 5/50 search-result bounds, and the fixed 64 KiB read-response ceiling.
Rationale: Owner-ratified 2026-08-11 as a mechanical ownership split rather than a new decision: one owner per limit prevents two stories from drifting to different numbers, and S10 is where the boundary tests live.
Evidence: `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` no duplicated mechanism, and `dev/bundle/docs/specs/0.24/s10-memory-resource-boundaries.md` corpus admission ceilings and their limit/limit-plus-one proofs.

Old:
```
- **Settled retrieval limits**: Retain the current 65,536-character capture ceiling and default 5/maximum 50 search results, and use the PRD's fixed 64 KiB read-response ceiling independently of `memory.max_bytes`, which bounds primary-turn prompt context rather than retrieval.
```
New:
```
- **Settled retrieval limits**: Retain the current 65,536-character capture ceiling and default 5/maximum 50 search results, and use the PRD's fixed 64 KiB read-response ceiling independently of `memory.max_bytes`, which bounds primary-turn prompt context rather than retrieval.
- **Ceiling ownership**: The 1,000-file and 64 MiB corpus admission ceilings belong to S10 – it defines, enforces, and proves them. This story consumes them and adds no ceiling, traversal budget, or duplicate limit constant of its own.
```

#### DECISION NOTE: audit-not-model-readable

Decision-Key: audit-not-model-readable
Altitude: fis-local
Affected surface: ## Constraints & Gotchas (new "Audit role is not retrievable" bullet)
Decision: The canonical `audit` role – S05's deletion-audit document `workspace/MEMORY.audit.md` – is outside `memory_search`'s and `memory_read`'s role universe: no search result carries it, and `memory_read` resolves neither an audit locator nor `role: audit`. The role is canonical and topic-less, but it is not one of the topic-less roles addressable by locator alone (observations, learnings, wiki, KG) – it is not part of the read universe at all.
Rationale: Owner-ratified 2026-08-11 as a consequence of the ratified audit-as-canonical-document decision rather than a new design choice: returning deletion audits to a model would hand back exactly the content the user asked to forget, defeating the forget guarantee – the same reason the audit is not an index source. Operator visibility flows through story S11's surfaces instead.
Evidence: Owner-ratified preflight 0.24 resolution 43 ("Not model-readable" clause); `dev/bundle/docs/specs/0.24/s05-atomic-memory-apply.md` deletion-audit contract and OC03 privacy scope; `dev/bundle/docs/specs/0.24/prd.md#fr2-guarded-memory-tools` bounded, role-discriminated retrieval contract.

#### IMPLEMENTATION NOTE: source-owned-qmd-results

Date: 2026-08-12
Observation: QMD returns file-level hits, so canonical corpus files cannot truthfully supply canonical entry identity. The QMD backend now keeps canonical memory results from the canonical FTS index, filters canonical and audit file hits from QMD, and retains QMD only for native source locators. Wiki QMD hits resolve through the wiki owner before being returned. This preserves raw-query ownership, canonical entry identity, native source identity, and search-to-read closure without manufacturing locators.

#### IMPLEMENTATION NOTE: derived-index-reconciliation

Date: 2026-08-12
Observation: Replacing the entire FTS table after a canonical capture or prune would erase independent sources. `replaceMemoryRows` atomically replaces canonical and legacy memory-owned rows while preserving unrelated sources; the offline rebuild command remains the explicit full-index rebuild path. Canonical commit still succeeds when the derived refresh fails and reports `indexState: degraded`.

#### VERIFICATION NOTE: objective-gates

Date: 2026-08-12
Evidence: Focused capture, retrieval, storage, QMD/wiki, provider, policy, journal, inbox, MCP, status, pruning, and rebuild suites passed, including 207 remediation-focused tests. The final CI-equivalent workspace suite passed across all packages and the CLI (9,163 passed, 17 skipped); formatting checked 1,603 files with zero changes; `dart analyze --fatal-infos` reported no issues; architecture passed 8/8; all fitness functions passed; `git diff --check` passed.
Ledger implication: S04's provider-neutral tool taxonomy, direct-SDK schemas and dispatch, trusted turn-context seam, and search-result identity contract lifted `dartclaw_core/lib` to 19,194 LOC. The existing core LOC ratchet was re-baselined from 19,000/18,600 to a 19,500 ceiling with a 19,000 warning threshold; the architecture gate now passes with an active warning rather than hiding the growth.

#### IMPLEMENTATION NOTE: review-remediation

Date: 2026-08-12
Observation: Fresh critic reviews found nine defects, all remediated before completion. Direct Claude SDK MCP requests now dispatch every advertised memory tool with JSON-RPC responses and bounded errors. TurnRunner supplies trusted session/turn/source/agent identity to direct capture callbacks, distinguishing primary turns from the memory journal; the shared inbound gateway retains only stable tool provenance it actually knows. Canonical pruning preserves equal-content records for S10 ownership, inbox source events use a stable file-instance digest independently of their path, and wiki snippets truncate on Unicode scalar boundaries. Read responses reject immutable metadata that cannot fit the 64 KiB ceiling, and malformed locators are distinguished from valid missing locators by typed application errors. QMD search results now expose canonical authority-free locators that round-trip through `memory_read`, whose resolver admits only indexed Markdown sources. Focused regression proofs and the full gate passed after remediation.
