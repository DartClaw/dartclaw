# Phase B Cross-Cutting Plan Bundle Review

## Summary

- **Readiness:** READY
- **Remaining readiness-affecting findings:** 0
- **Resolved during review:** 4 HIGH, 2 MEDIUM, 1 LOW
- **Documented residuals:** 1 LOW, justified authoring-size exception
- **FIS files needing updates:** none
- **Reviewed surface:** `prd.md`, `plan.json`, S01–S09, `implementation-context.md`, `native-artifacts.json`, `selected-settings.json`, the deferred Phase A proof inventory, and the public source seams pinned at `3396754b6501`.
- **Mechanical evidence:** final `validate-plan` passed; all nine final FIS parsed as `kind: fis` with empty `nonrunnable`, `unbound`, and `violations`. Heavy, live, native-platform, and held-out commands remain assigned to the final combined A+B gate.

## Step 6 Coverage

| Check | Evidence and result |
|---|---|
| 1. Overlapping scope | Compared every FIS Work Areas/Architecture Decision against `plan.json#sharedDecisions`. Shared files and abstractions have one named owner; score, health, config, inspection, build, evaluation, and release handoffs are explicit. Pass after Findings 1–4. |
| 2. Architectural consistency | Checked ADR-050/056 references, package tiers, derived-store lifetime, mapper ownership, score direction, provider lifecycle, and release ownership against public code and implementation context. Pass after Findings 1–4. |
| 3. Integration seams | Traced S01 contracts → S02 stores/S03 providers → S04 fusion/sync → S05 runtime → S06 inspection, S07 platform harness, S08 evaluator → S09 combined manifest. All consumed outputs now exist with matching signatures and semantics. Pass. |
| 4. Dependency gaps | Compared plan dependencies, FIS Required Context, task prerequisites, and execution contracts. No missing dependency or impossible task order remains. Pass. |
| 5. Naming/patterns | Checked vector identity, corpus/source-layer names, embedding config keys, diagnostics, status counts, CLI/API names, manifest terms, and evidence paths. Pass. |
| 6. Duplicate work | Verified one canonical memory mapper, conversation service, synchronizer inventory, provider instance, current-index guard, connected CLI policy, and transient final manifest. Pass after Findings 2 and 4. |
| 7. Plan/FIS alignment | Mapped every story scope and binding constraint to scenarios, structural criteria, tasks, and Proof. No silent narrowing remains. Pass. |
| 8. Intra-story contradictions | Compared every What We're NOT Doing section with scenarios and criteria. Pass after Finding 7. |
| 9. Scenario gaps | Checked fused-score composition, semantic fallback, stale/changed index health, HTTP secret-bearing URIs, delayed synchronization, owner/corpus isolation, native failure evidence, and pending-release state. Pass after Findings 1–3 and 5–6. |
| 10. PRD traceability | Traced FR1–FR8 and their acceptance clauses across S01–S09. Every PRD criterion has at least one tagged FIS scenario. Pass. |
| 11. Chain connectivity | Composed the acquisition/configuration/search chain, source-persist/project/synchronize chain, deletion/retirement chain, guarded inspection/trace chain, and platform/evaluation/manifest/final-acceptance chain. Inputs and outputs connect without orphan evidence. Pass. |
| 12. Riskiest-claim falsification | Checked one external risk per FIS against public source or pinned artifacts: FTS contract/package boundary; SQLite/PostgreSQL schema and pgvector posture; llamadart lifecycle and HTTP validation; composer score ordering; runtime lifecycle/config; trace correlation/current-index health; two-binary native build graph; evaluator Cartesian matrix and real composition; transient release lifecycle. Pass after Findings 1–6. |
| 13. Mechanical validity | Final plan validation and nine-FIS parsing are clean. Required sections, anchors, tags, and task bindings are present. S02's eight scenarios are the documented proportional exception below. Pass. |

## Resolved Findings

### 1. HIGH – Successful hybrid scores would sort in reverse under the existing composer

- **Affected stories:** S04, S05, S06, S08
- **Classification:** readiness-affecting, resolved
- **Location:** `s04-hybrid-fusion-and-incremental-synchronization.md:93-96,139-147,270-282`; `s05-runtime-activation-for-memory-and-conversations.md:113-115,215-223,292-294,320-324`; `s06-retrieval-inspection-and-turn-source-provenance.md:119-133,201-205,264-269`; `s08-sealed-retrieval-evaluation-harness.md:145-153,182-190,236-243,294-306`; public `packages/dartclaw_core/lib/src/search/composed_search_backend.dart:141,163-167`; public `packages/dartclaw_core/lib/src/search/qmd_search_backend.dart:79-91`.
- **Description:** The original contract ranked positive fused scores descending and mapped them unchanged, while the shipped composer sorts ascending. Multiple personal hits could therefore reverse when combined with wiki results.
- **Recommendation:** Make only successful hybrid `SearchResult.score` the negative of positive `fusedScore`; keep diagnostics positive, preserve pure lexical fallback scores/order, and forbid downstream negation or score sorting.
- **Resolution:** Applied to the shared decision and all consumers. S08 now proves at least two differently ranked personal hits plus wiki and semantic-failure fallback through the real composer.
- **FIS sections updated:** S04 Pinned Consumer API, Acceptance Scenarios, Constraints, TI01; S05 downstream surface, scenarios, overview, constraints, TI04; S06 scenarios, overview, TI03; S08 scenarios, overview, constraints, TI02–TI03.

### 2. HIGH – Memory inspection bypassed current-index health authentication

- **Affected stories:** S05, S06
- **Classification:** readiness-affecting, resolved
- **Location:** `plan.json:56`; `s05-runtime-activation-for-memory-and-conversations.md:73-88,102-111,234-240,293-306,377-382`; `s06-retrieval-inspection-and-turn-source-provenance.md:36-43,135-141,201-205,245-269`; public `packages/dartclaw_core/lib/src/search/composed_search_backend.dart:40-95`.
- **Description:** The original public raw-hybrid getter let the inspection route return stale personal hits even though ordinary composition rejects stale-before, changed-after, unavailable-health, and failed-query results.
- **Recommendation:** Extract the existing before/query/after logic into one `ComposedSearchBackend.queryCurrentIndex<T>` helper and make guarded `StorageWiring.inspectMemorySearch` buffer diagnostics until successful authentication; map null to the existing 503 response.
- **Resolution:** The plan and both FIS now bind one shared helper, preserve the existing reason/revision semantics, and require stale-before, changed-after, health-unavailable, and query-failure route proofs without releasing hits or diagnostics.
- **FIS sections updated:** S05 Pinned Configuration and Downstream Surface, S08 scenario, Technical Overview, Code Patterns, TI05; S06 endpoint contract, Required Context, S03 scenario, Technical Overview, Constraints, TI03.

### 3. HIGH – HTTP embedding endpoints could carry credentials outside the named credential seam

- **Affected stories:** S03, S05
- **Classification:** readiness-affecting, resolved
- **Location:** `plan.json:45`; `s03-native-and-http-embedding-providers.md:70-76,127-142,226-230,254-259`; `s05-runtime-activation-for-memory-and-conversations.md:91-100,184-194,244-246,330-332,353-363`.
- **Description:** Requiring only an absolute HTTP(S) URI left URI userinfo and query credentials available to fingerprints, serialized config, policy errors, or requests despite the named-credential-only contract.
- **Recommendation:** Require an absolute HTTP(S) URI with a nonempty host and no userinfo, query, or fragment in both config and provider construction. Reject before retention, fingerprinting, policy, or I/O, and never echo the rejected URI.
- **Resolution:** Both ownership layers and their focused tests now bind the full validation and hostile-output contract.
- **FIS sections updated:** S03 Pinned Consumer Surface, S03–S04 scenarios, Constraints, TI02; S05 downstream config surface, S03 scenario, SC01, Constraints, TI01–TI02.

### 4. HIGH – S09 made transient release bookkeeping and prose into permanent test machinery

- **Affected stories:** S09
- **Classification:** readiness-affecting, resolved
- **Location:** `s09-hybrid-operations-and-milestone-release-preparation.md:155-174,178-190,242-263`.
- **Description:** The original FIS added permanent Dart suites for documentation prose and a transient verification-manifest schema. Those suites would outlive the milestone bundle they referenced and create a second maintained release authority.
- **Recommendation:** Reuse generated config, architecture, version, and workflow checks; keep documentation and manifest assertions bounded to S09 task-local commands; retain the manifest only as transient combined-gate input.
- **Resolution:** Permanent suites were removed. TI01–TI04 now use existing authorities plus bounded `rg`/`awk`/`jq`/`cmp` checks, and Testing Strategy explicitly leaves no permanent suite.
- **FIS sections updated:** S09 Work Areas, What We're NOT Doing, Architecture Decision, TI01–TI04, Testing Strategy.

### 5. MEDIUM – Release-candidate proof did not exclude premature acceptance claims

- **Affected stories:** S09
- **Classification:** readiness-affecting coverage gap, resolved
- **Location:** `s09-hybrid-operations-and-milestone-release-preparation.md:251-263`.
- **Description:** The original TI04 checked version and release content but did not prove that both roadmap records still marked combined verification pending or that the changelog avoided held-out/platform/combined-pass claims.
- **Recommendation:** Extract the exact 0.26 roadmap and changelog sections and assert pending state while rejecting release-ready, released, tagged, held-out-pass, platform-pass, and combined-accepted language.
- **Resolution:** TI04 now performs those bounded negative and positive checks and retains the pre-existing 0.25.2 PRD byte-for-byte.
- **FIS sections updated:** S09 TI04 and Testing Strategy.

### 6. MEDIUM – Manifest checks did not prove exact S07/S08 command identity

- **Affected stories:** S09
- **Classification:** readiness-affecting coverage gap, resolved
- **Location:** `s07-native-packaging-and-platform-proof-harness.md:24-34`; `s08-sealed-retrieval-evaluation-harness.md:30-43`; `s09-hybrid-operations-and-milestone-release-preparation.md:242-249`.
- **Description:** The earlier substring checks could accept a command with extra arguments or a wrong evidence path while claiming the deferred harness contract was copied exactly.
- **Recommendation:** Compare each complete normalized command for equality and require exactly one matching obligation.
- **Resolution:** TI03 now checks all four complete platform commands and the complete held-out command exactly once, alongside the unchanged 19 Phase A entries and required evidence fields.
- **FIS sections updated:** S09 TI03.

### 7. LOW – S04 assigned runtime-status ownership to S06

- **Affected stories:** S04, S05, S06
- **Classification:** residual wording inconsistency folded into an active repair, resolved
- **Location:** `s04-hybrid-fusion-and-incremental-synchronization.md:211-218`; `s05-runtime-activation-for-memory-and-conversations.md:102-111`; `s06-retrieval-inspection-and-turn-source-provenance.md:188-190`.
- **Description:** The original exclusion grouped runtime status with S06 even though S05 owns the existing status payload and S06 explicitly excludes a new status route/page.
- **Recommendation:** State S05 status ownership separately and limit S06 to trace persistence and inspection/CLI presentation.
- **Resolution:** The ownership wording now matches the plan and consuming FIS.
- **FIS sections updated:** S04 What We're NOT Doing.

## Residual

### LOW – S02 has eight acceptance scenarios

- **Affected stories:** S02
- **Classification:** residual, no readiness effect
- **Location:** `s02-sqlite-and-postgresql-vector-projections.md:102-163,271-278`.
- **Description:** Eight scenarios exceed the authoring guideline's usual 3–7 range.
- **Disposition:** Accepted as a proportional size exception. The scenarios separately prove two backend round trips, atomic mutation, invalid/corrupt data, isolated SQLite schema, PostgreSQL extension preflight, optional projection bootstrap, and lexical-only extension independence. Combining them would create multi-behavior scenarios and reduce proof clarity. No implementation or acceptance scope is added.
