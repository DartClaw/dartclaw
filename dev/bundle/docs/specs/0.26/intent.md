# Intent: 0.26 Preflight Decisions

> **Renumbered**: this milestone was 0.25 when the record was written (2026-07-30) and became 0.26 on 2026-08-18; the released baseline is now 0.25. Decisions below stand unless a dated note says otherwise; the 2026-09-02 re-plan decisions are in `prd.md` § Decisions Log and `plan.json` `sharedDecisions`.

## Summary

This clarification settles four owner-level questions found while preflighting the 0.26 plan (then numbered 0.25). The schema-evolution decision removes an existing milestone requirement and therefore requires the PRD, plan, and affected FIS documents to be re-authored before preflight can resume.

## Scope

### In Scope

- Swedish stemming acceptance for PostgreSQL full-text search.
- Storage behavior while a lost PostgreSQL interlock is being recovered.
- The boundary between CI implementation and branch-protection activation.
- Schema bootstrap and compatibility behavior during DartClaw's experimental stage.

### Out of Scope

- New search algorithms or fuzzy matching.
- A SQL read/write classifier or a new storage API split.
- Repository-settings automation.
- A general migration runner or automatic data-preserving upgrades.

### MVP Boundary

- Preserve the smallest safe behavior already supported by the planned seams and operating model, with current-schema bootstrap instead of migration machinery.

### Not Doing (for now)

- Swedish ablaut/irregular conflation – Snowball's regular-inflection behavior is sufficient for this milestone.
- Partial storage availability during uncertain interlock ownership – the existing seam cannot safely distinguish reads from writes because `query()` can mutate via `RETURNING`.
- Automated branch-protection mutation – this is an operator-owned repository setting, not product code.
- Versioned migration streams, SQL-to-constant generation, migration bookkeeping, rollback directives, extension hooks, and wedged-migration recovery – premature for a pre-alpha, single-user product.

## Functional Requirements

### User Stories

- As an operator, I want predictable Swedish search acceptance, so that the milestone does not promise unsupported linguistic behavior.
- As an operator, I want storage quarantined while database ownership is uncertain, so that a second writer cannot be admitted.
- As a maintainer, I want the PostgreSQL CI job made required without settings automation, so that the merge gate is real and auditable.
- As an experimental user, I want schema handling to stay small and explicit, so that DartClaw does not carry production-grade migration machinery before compatibility is promised.

### Core Flows

1. Swedish acceptance proves `springa` matches regular variants such as `springer` and `springande`; `sprang` remains outside acceptance.
2. On interlock loss, all storage seam operations fail with the existing typed connection error until lock re-acquisition, PostgreSQL version validation, and schema-compatibility validation succeed; normal access then resumes.
3. Story S11 lands the PostgreSQL CI job and exact operator activation instructions; milestone completion requires operator confirmation that the job is a required branch-protection check.
4. A fresh store receives the current schema bootstrap. A compatible store opens normally. An incompatible authoritative store fails loudly with backup/reset/recreate guidance; the derived `search.db` may rebuild automatically.

### Alternate Flows

- If interlock recovery fails, finds a competing holder, or detects a gate mismatch, the existing fail-stop path runs.
- If repository settings cannot be changed when S11 lands, the code work may be complete but the milestone merge-gate requirement remains open.
- Existing narrow SQLite repairs may preserve the 0.26 transition, but no new general upgrade mechanism is introduced. Later incompatible releases may require manual recreation.

### UI Wireframes

- Not applicable – no UI work.

## Design Decisions

### Design Space Decomposition

0.26 preflight decisions
├── Swedish acceptance: regular inflections ← chosen · ablaut/irregular forms ✗
├── Interlock recovery: full storage quarantine ← chosen · partial read availability ✗
├── Merge gate: documented operator activation ← chosen · settings automation ✗
└── Schema evolution: bootstrap + compatibility gate ← chosen · versioned migration runner ✗

### Cross-Consistency Notes

- Full storage quarantine matches the security requirement without adding SQL classification or a second storage seam.
- Operator activation preserves the merge-gate requirement while keeping repository settings outside implementation scope.
- A compatibility gate prevents silent schema drift without promising automatic upgrades; authoritative stores are never deleted automatically.

### Resolved Decisions

| Dimension | Choice | Rationale |
|---|---|---|
| Swedish stemming | Regular Snowball inflections only | Matches the planned implementation; ablaut support would widen scope. |
| Interlock recovery | Refuse all storage seam operations until re-acquisition and re-gating complete | Safest lean contract; the seam cannot reliably classify a generic `query()` as read-only. |
| PostgreSQL merge gate | Documented operator activation after the CI job lands – re-aimed 2026-09-02: the job is also registered in `dev/tools/release_check.sh` gate 10's required list, and operator branch-protection activation stays the recorded external gate (`main` was unprotected on 2026-09-02) | Avoids settings automation while retaining a real milestone gate. |
| Schema evolution | Current-schema bootstrap plus a small schema-compatibility gate; no versioned migration runner | Matches the pre-alpha compatibility posture and avoids unused production machinery. |
| Schema compatibility identity | One current epoch plus backend-owned required table/column/index manifests | Detects structural drift without creating an ordered upgrade history. |
| Supported SQLite transition | Exact 0.23 shape only; transactional bounded repair – rebased to the exact released 0.24 shape on 2026-08-14 and to the exact released 0.25 required structure on 2026-09-02 (orphan `workflow_step_executions.external_artifact_mount` tolerated by the required-object manifest; see `prd.md` § Decisions Log) | Preserves the immediate upgrade path without promising support for arbitrary historical schemas. |
| Database retry boundary | Retry only failures proven before dispatch; never replay an ambiguous dispatched operation | Prevents duplicate mutations after a lost response or uncertain commit. |
| Full-text tenancy | `user_id` required on search, upsert, and delete | Prevents cross-user overwrite/deletion as well as read leakage. |
| Database credential shape | Mutually exclusive env-substituted `database.url` or named generic `database.credential` | Reuses the existing credential registry without a database-specific subsystem. |
| TLS omission | Non-loopback omission resolves to `verify-full`; explicit cleartext/disable refuses | Keeps a safe default and one unambiguous fail-closed rule. |
| Transaction statement lifetime | Transaction-created statements expire with the transaction; later use throws `StateError`; close stays idempotent | Smallest predictable ownership contract; no detach/reprepare machinery. |
| CI execution proof | Explicit required contract-group manifest | Avoids a brittle numeric test-count floor and detects skipped/missing groups. |

### Open Design Questions

- None. The implementation contracts found during PRD review are settled above.

## Edge Cases

| Scenario | Expected Behavior |
|---|---|
| Search input uses `sprang` for indexed `springa` content | No match is required. |
| A seam `query()` uses mutation plus `RETURNING` during interlock recovery | Refused with the same typed recovery error as other seam operations. |
| CI job exists but is not configured as required | Milestone merge-gate requirement remains incomplete (2026-09-02: the in-repo gate is `release_check.sh` gate 10; branch-protection activation is the external gate). |
| Derived `search.db` has an incompatible schema | Rebuild automatically from authoritative sources where supported. |
| `tasks.db` or PostgreSQL has an incompatible schema | Fail before repository use; never silently delete or partially initialize it. |

## Error Handling

| Error | User Message | Recovery |
|---|---|---|
| Storage request during interlock recovery | Existing `StorageConnectionException` with the interlock-recovery-pending catalog message | Retry only after the instance reports successful re-acquisition and re-gating. |
| Interlock recovery reaches a terminal verdict | Existing condition-specific fatal catalog message | Stop the conflicting instance, restore reachability, or correct the gate mismatch before restart. |
| Required-check activation cannot be confirmed | Milestone gate reports the exact PostgreSQL job as not yet required | Operator updates branch protection and records confirmation. |
| Authoritative schema is incompatible | Error identifies the store and incompatibility | Back up, manually export if needed, then reset/recreate with the current schema. |

## Non-Functional Requirements

- **Performance**: No SQL parsing, extra retry layer, or settings service is introduced.
- **Security**: No storage operation succeeds while exclusive database ownership is uncertain.
- **Accessibility**: Not applicable – no UI surface changes.
- **Maintainability**: No migration generator, history, dialect stream, or recovery subsystem is introduced before product compatibility requires it.

## Success Criteria

- [ ] Swedish fixtures require regular-inflection matches and explicitly exclude ablaut matching.
- [ ] Interlock recovery tests prove every seam operation is refused before successful re-gating and resumes afterward.
- [ ] S11 documents the exact required-check activation step, and milestone completion records operator confirmation.
- [ ] Fresh SQLite and PostgreSQL stores bootstrap the current schema; incompatible authoritative stores fail loudly; derived search storage can rebuild.
- [ ] The 0.26 implementation contains no general migration runner, `schema_migrations` history, or migration code generator.
- [ ] The exact released-baseline SQLite repair (0.23 when written; 0.25 since 2026-09-02) and both fresh bootstrap paths are transactional and fault-tested.
- [ ] Ambiguous dispatched database operations are never auto-replayed.
- [ ] Contract CI proves an explicit required group manifest and the `PostgreSQL contract` check is operator-confirmed as required.

## Dependencies

| Dependency | Purpose | Risk |
|---|---|---|
| S09 PostgreSQL FTS implementation | Applies the settled Swedish acceptance scope | Server dictionary behavior remains integration-tested. |
| S10 interlock component and storage gate | Enforces recovery quarantine | Incorrect state transitions could reopen access early. |
| S11 PostgreSQL CI job | Provides the check that branch protection requires | A job that merely exists is not a merge gate. |
| Re-authored 0.26 PRD, plan, and FIS bundle | Removes the migration requirement coherently | The current bundle still mandates and depends on S02. |

## Open Questions

- Whether a future stable release needs automatic data-preserving upgrades is intentionally deferred until the product makes a compatibility commitment.

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Limit Swedish acceptance to regular inflections | Pragmatic scope; no unsupported ablaut promise. | 2026-07-30 |
| Quarantine the full storage seam during interlock recovery | Safe and lean; partial reads require an unsafe classifier or new seam. | 2026-07-30 |
| Make required-check activation an operator milestone gate | Retains enforcement without repository-settings automation. | 2026-07-30 |
| Replace versioned migrations with current-schema bootstrap and a compatibility gate | Breaking storage compatibility is acceptable during pre-alpha; migration machinery is premature. | 2026-07-30 |
| Use one schema epoch plus required-object manifests; repair only the exact released baseline (0.23 when decided; 0.25 since 2026-09-02) | Small, falsifiable compatibility gate without an upgrade framework. | 2026-07-30 |
| Limit automatic retries to proven pre-dispatch failures | Avoid duplicate writes under ambiguous commit outcomes. | 2026-07-30 |
| Scope all full-text operations by user | Mutation isolation is part of the same tenancy boundary as search. | 2026-07-30 |
| Reuse env substitution or the generic credential registry | Avoid a database-specific credential subsystem. | 2026-07-30 |
| Use a required-group manifest for PostgreSQL CI proof | More robust than a numeric test-count floor. | 2026-07-30 |
