# Phase B PRD document review 01

**Readiness: Ready**

Review mode used: `doc`

Intent Context: `docs/specs/0.26/hybrid-search-prd-brief.md` (approved Phase B brief), `../dartclaw-public/dev/state/PRODUCT.md` (product philosophy and proportionality), and `.agent_temp/0.26-execution/phase-b-evaluation-protocol.md` (frozen pre-held-out evaluation contract). Technical claims were checked only where needed against `.agent_temp/0.26-execution/phase-b-runtime-seams.md`. The held-out dataset and scores were not read.

Project Rules Context: loaded repository instructions; no separate Review Policy was discoverable. Relevant checks covered lean scope, one authority per concern, current package topology, source-truth boundaries, real verification rather than historical proof, explicit deferral handling, and private-repository write restrictions.

## Coverage proof

| Surface | Evidence read | Positive proof | Falsifier attempted | Result |
|---|---|---|---|---|
| Both required corpora and isolation | Draft FR1/FR3, brief lines 7 and 52–53, seam map lines 21–41 | Memory and conversations are independently required across query, mutation, deletion, rebuild and empty-corpus paths | Looked for a memory-only fallback, merged identifiers, or a dropped conversation lifecycle | Covered |
| Local native and opt-in HTTP embedding | Draft FR2/FR8, brief lines 28 and 34–37 | Local model acquisition is explicit; FTS remains default; HTTP endpoint and credential references are opt-in; the guide must disclose query/content transfer across the trust boundary and backend-specific lexical behavior | Looked for automatic cloud fallback, implicit download, malformed-batch acceptance, credential exposure, or undisclosed remote content transfer | Covered |
| Incremental/rebuild equality | Draft FR3 and edge cases, brief lines 30 and 32–33, seam map lines 25–41 | Hash/fingerprint reuse, stale retirement, late-result protection, empty clearing, and both corpus lifecycles are stated | Tried deletion during embedding, model/dimension change, deleted-session rebuild, empty one-corpus rebuild, and unchanged-content re-embedding | Covered |
| SQLite/PostgreSQL vector storage and schema atomicity | Draft FR4/FR8, brief line 29, seam map lines 43–58 | Base PostgreSQL FTS remains pgvector-free; hybrid extension is administrator-provisioned; both schema authorities and transactional derived setup are named | Looked for unconditional pgvector, silent extension install, partial authoritative bootstrap, one-manifest-only validation, or automatic migration | Covered |
| Diagnostics and turn traces | Draft FR5, brief line 31, seam map lines 60–81 | Opt-in constituent ranks/contributions and exact returned locators correlated by invocation ID are required; normal payloads remain compact | Tried missing ranks, malformed tool output, old trace decode, requery-as-proof, raw snippet/vector retention, and the conversation corpus with no current tool caller | Covered |
| Native packaging and failure behavior | Draft FR6/FR8, brief lines 17–22 and 54–56 | Actual macOS arm64, Linux arm64/x64 and Windows probes, two binary builds, bounded failure paths and the broader final platform obligations are required | Looked for historical-spike substitution, mock/platform substitution, unverified archives, missing OpenMP, hung load/dispose, or unnamed final proof sets | Covered |
| Frozen held-out evaluation | Draft FR7, frozen protocol, brief lines 36 and 59–66 | Dataset hash, allowed weight pairs, settings freeze, identical per-backend run settings, macro averaging, MRR@5, constituent comparison, no-result failure and both corpus/backend slices are stated | Looked for score observation before freeze, wider tuning space, micro/macro ambiguity, unequal mode settings, hidden corpus regression, denominator drift, or post-hoc tolerance change | Covered |
| Final combined A+B acceptance | Draft FR8, execution strategy lines 7–13 and 242–250, `deferred-live-platform-proofs.json` | FR8 binds all 19 manifest commands, enumerates the combined gate families, requires release-document consolidation, and distinguishes local evidence from external actions | Tried to omit a Phase A deferred proof, live PostgreSQL/pgvector, full-suite, security, platform, retrieval, release-doc or UI-smoke obligation while still satisfying FR8 | Covered |
| Scope proportionality and plan handoff | Draft scope/NFR/constraints/decisions, brief lines 39–57, Product Proportionality | Excluded infrastructure remains excluded; neither corpus nor load-bearing gate can be cut; planning is capped at ten stories | Looked for speculative infrastructure, a reopened owner decision, an unbounded plan, or size reduction by dropping required scope | Covered |

Guardrails Coverage: 7 checked, 0 findings.

## Findings

No open findings.

Four actionable gaps found in the initial pass were corrected during review and narrowly rechecked:

| Initial gap | Corrected requirement | Closure evidence |
|---|---|---|
| Final combined acceptance relied on unnamed obligation sets | FR8 binds all 19 entries in `docs/specs/0.26/deferred-live-platform-proofs.json` and enumerates the remaining A+B gate families and release-record updates | Draft line 209; falsified against execution strategy lines 10–12 and B3/B4 |
| Frozen evaluation omitted the allowed weight search space and equal-run controls | FR7 limits weights to `0.5/0.5`, `0.25/0.75`, or `0.1/0.9` and fixes model/candidate/cutoff/warm-up/repetitions across modes per backend | Draft lines 184 and 190; matches frozen protocol lines 12–14 |
| HTTP operator guidance omitted affirmative disclosure and language semantics | FR8 requires query/indexed-content trust-boundary disclosure plus semantic-versus-backend-specific lexical behavior | Draft line 205; matches brief line 37 |
| The approved plan-size limit was absent | Constraints/assumptions cap the plan at ten stories without dropping Must criteria | Draft line 262; matches brief line 57 |

Applied inline severity calibration (Findings Filter skipped: no Critical findings and <=5 initial findings). All four corrections were bounded and source-determined; no clarification or architecture decision remains.

## Critic coverage

Attacked ambiguous completion quantifiers, missing unhappy paths, schema-authority overlap, optional pgvector versus base FTS, conversation-without-tool-call wiring, late/stale embedding publication, empty-corpus rebuild, malformed HTTP batches, trace-result authenticity, platform substitution, held-out tuning leakage, slice masking and scope-cut pressure. No weakness remains after the four closure edits.

## Recommended next action

None for PRD requirements. Proceed to plan/FIS authoring after the accepted Phase A checkpoint; the plan review should prove each Must criterion and every final-gate obligation has a runnable owner and proof.
