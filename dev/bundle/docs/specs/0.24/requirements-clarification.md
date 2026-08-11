# Requirements Clarification: 0.24 Memory Model

> **Source Trust**: trusted-local

## Summary

DartClaw 0.24 will replace its append-only, loosely consolidated memory stream with a bounded, inspectable memory model for a single-user personal assistant. Models retain semantic judgment over what is worth remembering and how knowledge should be organized; the Dart host owns identity, provenance, limits, concurrency, atomic persistence, indexing, and recovery.

## Scope

### In Scope

- Reopen 0.24 and treat the complete memory model as release scope.
- Separate raw observations from curated, prompt-relevant memory.
- Keep a bounded `MEMORY.md` index and retrieve detailed topic memory on demand.
- Keep personal/experiential memory distinct from source-backed `wiki/` synthesis and temporal facts.
- Replace the ambiguous append-only `memory_save` surface with `memory_observe`, `memory_search`, `memory_read`, and transactional `memory_apply` capabilities; `memory_observe` preserves bounded observation and runtime-learning roles without turning either into personal topic memory.
- Permit ordinary turns to add or revise curated memory through guarded structured mutations.
- Support explicit on-demand semantic curation without autonomous background consolidation.
- Add stable identity, revisions, provenance, recovery, resource bounds, index-health visibility, migration, and operational documentation.
- Resolve all actionable memory-review findings that do not depend on the 0.25 PostgreSQL or hybrid-search work.

### Out of Scope

- PostgreSQL, database-backend abstraction, vector embeddings, hybrid ranking, or native search packaging.
- New QMD capabilities or QMD-specific hardening beyond preserving ADR-050's 0.25 Phase B deprecation and one-milestone-later removal path.
- Multi-user product behavior, active-active runtimes, or hostile filesystem race defenses.
- Autonomous or idle-time stewardship, OKF interoperability, and general caller-aware MCP dispatch work unrelated to memory.

### MVP Boundary

- A user can let DartClaw remember useful context during ordinary turns, inspect and retrieve it, explicitly request semantic curation, and recover a derived index without risking silent overwrite or append-only pseudo-consolidation.

### Not Doing (for now)

- Autonomous scheduled curation – deferred to 0.27 until the on-demand mutation contract is proven.
- Automatic deletion of raw observations – deferred until an explicit retention policy is accepted; 0.24 bounds processing and exposes usage.
- Search-backend redesign – remains 0.25 scope under ADR-045 and ADR-050.

## Functional Requirements

### User Stories

- As a user, I want DartClaw to remember durable preferences and context during ordinary conversations, so that later turns improve without requiring repeated explanation.
- As a user, I want a concise memory index with details available on demand, so that prompt cost stays bounded without losing useful depth.
- As a user, I want explicit curation to merge, revise, and remove stale memory safely, so that memory improves rather than growing forever.
- As an operator, I want provenance, health, limits, and deterministic recovery, so that I can understand and repair the memory subsystem without inspecting an opaque database.
- As a developer, I want one coherent mutation and indexing contract, so that 0.25 can change database/search implementations without redefining memory semantics.

### Core Flows

1. During an ordinary turn, the model may append a provenance-labelled observation or propose a guarded curated-memory change.
2. The host validates the structured operation, expected revision, identities, provenance, and resource limits, then atomically commits canonical files and reconciles the derived index.
3. Each primary turn receives a bounded memory index and current collection revision; detailed topic content is retrieved only when relevant.
4. An explicit curation action snapshots bounded memory and observations, asks the model for a structured change set, and commits it only if the snapshot revision still matches.
5. Search and Context Research return stable, resolvable memory locators and disclose degraded index layers.
6. Rebuild creates and validates a fresh derived index before replacing the active index.

### Alternate Flows

- Journal jobs remain opt-in and write provenance-labelled observations rather than authoritative prompt memory.
- Explicit curation is a registered host system action on the existing run-now surface. Its descriptor is read-only through scheduling configuration surfaces, and it is excluded from timers, retries, and YAML mutation while sharing the existing overlap guard and list/show/operator entry points.
- Registered system-action IDs are reserved. A configured job with a colliding ID is rejected before scheduling starts or list/show publishes an ambiguous descriptor.
- A user may edit canonical Markdown while DartClaw is stopped; startup validates it and reconciles collection revision and derived index before reporting healthy, while preserving invalid content for recovery rather than overwriting it.
- When semantic curation is unavailable or rejected, deterministic exact deduplication, parsing, bounds, and archival still operate.
- When indexing fails after a canonical commit, the save remains durable but returns and exposes an index-degraded state until reconciliation succeeds.

## Design Decisions

### Design Space Decomposition

Memory model
├── Prompt context: bounded index + on-demand topics ← chosen · retrieval only · chronological tail ✗
├── Knowledge boundary: personal memory topics + source-backed wiki ← chosen · one mixed corpus ✗
├── Journal trust: observations before promotion ← chosen · direct authoritative promotion ✗ · approval per observation
├── Mutation autonomy: guarded ordinary-turn writes ← chosen · approval for every write · scheduled-only writes ✗
├── Curation: explicit/on-demand model proposal + host commit ← chosen · deterministic semantics only ✗ · background autonomous rewrite
├── Raw retention: no automatic deletion in 0.24 ← chosen · post-curation deletion · fixed-age deletion
└── Tool surface: observe/search/read/apply ← chosen · append-only save ✗ · separate tool per mutation

### Cross-Consistency Notes

- Prompt-loaded memory must be curated and bounded; raw journal/tool content cannot enter it merely because it was observed.
- Model autonomy requires host-enforced provenance, compare-and-swap revisions, resource limits, and atomic index reconciliation.
- Source-backed claims remain in `wiki/` or the temporal knowledge graph; personal topic memory must not become a second wiki authority.
- 0.24 guarded mutation writes personal memory only; guarded wiki/KG write policy and semantics remain 0.27 scope.
- 0.24 may define stable source identity, but 0.25 must preserve it across both database backends and hybrid indexing.

### Resolved Decisions

| Dimension | Choice | Rationale |
|-----------|--------|-----------|
| Release | Reopen 0.24 | Avoid indexing and migrating the wrong memory abstraction in 0.25. |
| Prompt context | Bounded `MEMORY.md` index plus on-demand topics | Mirrors proven progressive-disclosure patterns while keeping context small. |
| Semantic authority | Model proposes; host validates and commits | Preserves reasoning while making integrity deterministic. |
| Tool contract | `memory_observe`, `memory_search`, `memory_read`, `memory_apply` | Covers evidence, retrieval, and atomic mutation without a broad CRUD toolbox. |
| Learning writes | Bounded `memory_observe` learning role | Replaces `memory_save(category: learning)` without adding another tool or mixing runtime learnings with personal topics. |
| Curation timing | Explicit/on-demand in 0.24 | Proves the contract before autonomous stewardship in 0.27. |
| Retention | No automatic raw deletion in 0.24 | Avoids irreversible loss before retention policy and steward behavior are proven. |

### Open Design Questions

- None. Implementation placement and provider-specific prompt delivery remain downstream architecture/spec concerns, but must satisfy the settled next-turn bounded-context outcome.

## Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| Memory changes after a curation snapshot | Reject the stale change set without a partial write; a later run may retry from a fresh snapshot. |
| Duplicate or conflicting semantic facts | Model proposes merge/revision; host never guesses semantic equivalence. |
| Unknown or opaque legacy Markdown | Preserve it during migration and report any content that cannot become structured memory. |
| Oversized index, topic, archive, wiki page, or raw observation | Reject or bound the operation before partial canonical mutation and expose the affected limit. |
| Punctuation or FTS operators in a natural-language query | Complete as a literal user query; backend-specific encoding never leaks to callers. |
| Corrupt or deleted search index | Rebuild from canonical sources using a fresh sibling and atomic replacement. |
| Canonical save succeeds but indexing fails | Return saved-but-index-degraded status; expose repair guidance and clear it after reconciliation. |
| Two cooperating runtime operations mutate memory concurrently | The shared lock and revision check serialize valid commits; stale proposals are rejected. |
| Journal contains prompt injection or tool-authored instructions | Store as provenance-labelled observation; never treat it as authoritative prompt instruction. |
| Canonical Markdown changed while DartClaw was stopped | Validate and reconcile collection revision/index before healthy use; preserve invalid content and report recovery steps. |

## Error Handling

| Error | User Message | Recovery |
|-------|--------------|----------|
| Stale revision | Memory changed; review a fresh snapshot before applying this change. | Re-read and resubmit against the new revision. |
| Invalid mutation | Identify the invalid operation and leave canonical/index state unchanged. | Correct the structured change set. |
| Resource limit | Identify the store and enforced limit; do not partially write. | Curate, archive, or adjust an approved configuration limit. |
| Index update failure | Memory saved, search index degraded. | Retry reconciliation or run `dartclaw rebuild-index`. |
| Rebuild failure | Existing index preserved; show the failing validation stage. | Correct source/resource problem and rerun. |
| Unmigratable legacy content | Content preserved but excluded from structured operations. | User reviews or explicitly rewrites the reported section. |

## Non-Functional Requirements

- **Performance**: The prompt-loaded index defaults to at most 150 rendered lines and the configured 32 KiB memory budget, whichever is reached first. A canonical Markdown file is accepted through 64 MiB inclusive, each dated observation partition through 8 MiB inclusive, and recursive traversal through 1,000 regular files and 64 MiB aggregate per request; search returns the best 50 results after ranking all admitted candidates. Migration processes at most 256 parsed records per in-memory batch and reports at most 100 diagnostics within 64 KiB UTF-8. Limit-plus-one is rejected without partial mutation or deletion. Aggregate observation usage warns at 64 MiB without blocking writes or deleting records.
- **Reliability**: Canonical changes are serialized, compare-and-swap protected, and atomically written. No acknowledged change may be silently lost; derived-index health is observable and recoverable from deleted or corrupt state.
- **Security**: Continue trusting the host OS/runtime user/filesystem. Treat model, user, journal, tool, wiki, and imported content as semantically untrusted until routed with provenance. Do not introduce descriptor-bound hostile-path defenses.
- **Usability**: Canonical memory remains plain Markdown and manually inspectable. Tool and operator responses distinguish observation, curated memory, archive, wiki, and index health using project terminology.
- **Operational simplicity**: Reuse existing workspace locks, atomic-write utilities, MCP registration, search/index services, and status surfaces. Add no new database, package, daemon, or background scheduler.
- **Compatibility**: Breaking preview-format changes are allowed, but migration must preserve unknown user-authored content and explain manual action.

## Success Criteria

- [ ] The former consolidator cannot dispatch an append-only pseudo-consolidation turn.
- [ ] Every curated memory entry has a stable ID, revision, topic, timestamp, and provenance.
- [ ] `memory_apply` atomically supports add, revise, merge, and remove against an expected snapshot revision.
- [ ] Every production caller, prompt, recipe, provider mapping, and allowlist is migrated from `memory_save` to the correct observation, learning, or curated-memory contract.
- [ ] Ordinary turns can autonomously record and curate memory through the guarded contract.
- [ ] Journal output cannot become prompt-authoritative without an explicit curated-memory mutation.
- [ ] Every primary turn receives only the bounded index; topic detail remains on demand.
- [ ] Memory citations resolve uniquely through Search, Knowledge Hub, and Context Research.
- [ ] Natural-language queries containing FTS syntax or punctuation work across all current callers.
- [ ] Index-degraded state is visible and clears after successful reconciliation.
- [ ] Rebuild recovers from deleted and corrupt index files without mutating the target in place.
- [ ] Archive, wiki, observation, prompt, and recursive-search paths enforce documented resource bounds.
- [ ] Current negative memory configuration values fail validation consistently.
- [ ] Live-save and rebuild paths produce equivalent normalized index rows.
- [ ] Dead vector/identity placeholders and duplicate wiki scanning are removed unless consumed by an accepted 0.25 contract.
- [ ] Documentation and architecture records describe the same code-backed memory roles, prompt behavior, recovery, and 0.25/0.27 boundary.

## Dependencies

| Dependency | Purpose | Risk |
|------------|---------|------|
| ADR-002 | Canonical files and derived-index boundary | Must remain compatible with the accepted file-first model. |
| ADR-007 | Provider prompt-injection semantics | Status and current implementation/docs disagree; 0.24 must reconcile them. |
| ADR-029 | Wiki/KG provenance and ranking | Memory topics must not duplicate or weaken source-backed knowledge. |
| ADR-042 | Citation locator contract | Current generic locators violate the accepted memory-entry-ID requirement. |
| ADR-045 and ADR-050 | 0.25 backend/search seams | 0.24 identity and corpus semantics must be preserved, not redesigned, by 0.25. |
| Existing workspace lock and atomic-write utilities | Mutation integrity | All memory writers must use the same authority. |

## Open Questions

- None.

## Decisions Log

| Decision | Rationale | Date |
|----------|-----------|------|
| Reopen 0.24 for the complete memory model | The release is not tagged; fixing the abstraction before 0.25 avoids rework and migration churn. | 2026-08-11 |
| Use progressive disclosure | A bounded index plus topic details balances persistent context and prompt cost. | 2026-08-11 |
| Preserve model semantic judgment | Importance, topic choice, conflicts, and summaries require reasoning; the host owns only deterministic integrity. | 2026-08-11 |
| Replace `memory_save` with four coherent tools | Append-only save cannot revise or consolidate; one atomic apply primitive avoids mutation-tool sprawl. | 2026-08-11 |
| Preserve learnings through `memory_observe` | A closed bounded learning role retains self-improvement writes without adding a fifth tool or promoting learnings into personal memory. | 2026-08-11 |
| Keep autonomous stewardship in 0.27 | 0.24 proves explicit/on-demand curation before adding scheduling and policy. | 2026-08-11 |
| Respect the settled host-trust threat model | Ordinary failures and untrusted semantic content matter; hostile pathname swapping does not. | 2026-08-11 |
