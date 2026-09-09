# Retrieval acceptance decision

Status: approved calibration completed on 2026-09-09; its stop condition is met. A separate mechanism/scope decision is required.
Calibration authorization: "Please proceed with this."
The original frozen evaluator, selected settings and failed release acceptance remain unchanged.
Integration source for the diagnosis: `930f72c4332ea2a06c97f88d64a29b79d678f625`.

## Diagnosis

The original evaluation completed 144 slices and 122 gates. Four gates failed: vector and hybrid no-result
retrieval on SQLite and PostgreSQL each returned empty for 1/10 queries. Keyword returned empty for 10/10.
Owner and corpus isolation passed. The original failed report remains evidence, not a baseline to replace.

The focused production-path probe reconstructs all ten no-result queries through the unchanged SQLite evaluator
pipeline. Nine return results. For every returned vector, a direct cosine over the captured production embeddings
agrees with its stored score within `1.88e-9`. Their maximum irrelevant scores span `0.2265–0.5851`; the one
correctly empty query peaks at `0.1600`. Returned counts match direct scores above the frozen inclusive `0.20`
cutoff. The provider returns 768-dimensional normalized embeddings. Three sampled documents produce identical
vectors individually and in a batch. These measurements diagnose the exposed failure; they select no new setting.

Source inspection found matching query/document prefixes, cosine direction, owner/fingerprint filters, current
content authentication, and cutoff-before-fusion behavior. Calibration and production use the same verified model
and prefixes. All 26 calibration queries produce identical embedding components singly and in a batch, with both
calibration's explicit model parameters and production defaults. All 24 calibration documents likewise agree across
those parameters and batch sizes. The verified GGUF declares mean pooling. No implementation change is justified
by these measured input, native execution, storage and filtering paths.

Calibration's highest negative score was `0.1421`, but its lowest best-relevant positive was `0.2048`.
Consequently a single higher cosine cutoff cannot both retain every original calibration positive and reject all
exposed evaluation negatives. This is an observed limitation of cosine-based relevance filtering, not evidence for
choosing a new threshold. Changing RRF weights cannot make vector-only retrieval empty or eliminate a surviving
vector candidate when the lexical ranking is empty.

## Approved decision

Keep 0.26 release acceptance blocked and explicitly reopen calibration under a second, separately versioned
protocol. Preserve the current relevance and no-result requirements. Permit experiments only on calibration data;
do not authorize a new implementation mechanism, threshold, model, or change to judgments through this decision.

First establish whether the existing cosine filter can satisfy representative positives and hard negatives at all.
If it cannot, stop calibration and present a separate product choice: change the relevance mechanism or narrow the
hybrid feature's release scope. Do not add a reranker, model call, heuristic filter, or per-query cutoff by inference.
Reuse of the original failed evaluation is restricted to a pre-registered causal defect/fix check or one candidate
already selected and sealed using calibration evidence alone. Its result cannot select, modify, replace, or reject
that candidate in favor of another under the same protocol. Changing a candidate after that result requires a new
approved calibration decision and another unseen holdout.

Alternative considered and declined: leave the protocol closed and keep the feature blocked until a causal
implementation defect is found.
Shipping the failed gate, reclassifying its negatives as relevant, or raising the threshold against exposed questions
would change the accepted product contract and is not part of either option.

## Independent unseen holdout protocol

1. **Record authorization first.** The maintainer accepts or rejects this proposal. An accepted decision receives an
   explicit record in the canonical private PRD before revised acceptance assets or evaluator behavior are created.
   Original five frozen inputs, model bytes, failed reports, hashes, and evaluator source stay retained at their
   existing revision. Never overwrite them or report the original gate as passed.
2. **Make calibration representative.** Retain the historical 24-document/16-query fixture and ten negatives as
   regression evidence. Author a separate calibration corpus using the evaluation's existing 32-document/60-query
   shape: 30 owner documents, two foreign-owner documents, ten queries per six families, both corpora and languages
   in every family, and five queries per corpus per family. Include short keyword queries and natural questions,
   weak relevant paraphrases, multilingual matches, and hard negatives with related topics but absent requested
   facts. For its ten no-result queries, include at least one related-topic negative in each corpus/language cell,
   two wrong-entity or wrong-time negatives, two answers present only beyond the requested owner/corpus boundary,
   and two unrelated-topic negatives. A separate reviewer checks the judgments without retrieval scores.
3. **Measure production behavior.** Use the same provider, chunk projections, single-query API, vector indexes,
   authentication, and hybrid search used by the application. Record raw cosine bounds, positives lost, correct-empty
   counts, all existing quality/isolation gates, and source/model/native/input hashes for each calibration experiment.
   Decide feasibility and choose one candidate from calibration alone. Record the candidate and configuration seal
   before running the exposed evaluation. An improvement or failure on that evaluation cannot authorize a second
   candidate, revised configuration, or further candidate development under this protocol. Retain every experiment.
4. **Author an unseen holdout independently.** A fresh authoring session receives only the approved product contract,
   shape and coverage rules in step 2, and the JSON schema. It receives no calibration documents, exposed questions,
   rankings, scores, candidate settings, or inherited task history. Use different documents, entities and facts.
   A second fresh reviewer checks relevance, absence, owner/corpus boundaries and language coverage without scores.
   Each runs under a separate access-controlled identity in a clean sandbox populated only with its whitelisted
   inputs: contract/schema for the author, plus the proposed holdout for its reviewer. Neither may access host home,
   repository/calibration/exposed files, prior transcripts, connectors or network retrieval. Before authoring, retain
   the mounted/copied input inventory and demonstrate denied reads of excluded paths from both identities. These
   environments are prerequisites, not assumed capabilities of a fresh task in the shared checkout.
   The custodian holds the assets outside the implementation identity's accessible filesystem. It alone may compare
   both datasets, without scores: reject exact document/query duplicates by content hash and use a confidential
   reviewer to check reused scenarios, scenario-specific entities and facts. Common vocabulary alone is not overlap.
   Return only structured pass/fail, overlap counts, schema/coverage counts and SHA-256 commitments. A synthetic
   duplicate must fail this audit. Before any scoring, an overlap rejects the affected scenario; the author receives
   its own scenario ID and a generic rejection, then authors a replacement without protected content. Re-audit and
   commit the final hash. If access denial or confidential overlap validation cannot be demonstrated, stop before
   creating acceptance data. Prompt instructions alone are not access isolation.
5. **Seal before evaluation.** Freeze the implementation revision, one selected configuration, complete preprocessing
   contract, model/native hashes, and calibration evidence before the custodian reveals or runs any holdout content.
   Keep the current 32-document/60-query shape and 144-slice/122-gate semantics, including all 10/10 no-result and zero
   isolation-leak requirements, numerical regression tolerances, top 5, candidate 20, and warm-up/repetition counts.
   Any necessary versioned asset binding must reuse the existing evaluator's metric/gate authority. It needs review
   and synthetic pass/fail tests before the unseen run; do not build a second metric implementation or a permissive
   override path. Changed settings or mechanisms require their own explicit approval before this seal.
6. **Run once and preserve the verdict.** An evaluator session receives sealed source and assets and runs both
   backends and all modes. Infrastructure failures remain incomplete with their logs retained; a corrected rerun uses
   identical content and source. A completed quality failure ends this candidate's acceptance attempt. No changing
   labels, tolerances, corpus membership, threshold, or selecting another candidate after viewing its scores. Any
   future reopening requires a new decision and another independently unseen holdout.

## Evidence and release consequences

### Approved calibration outcome

The separately authored calibration contains 32 documents and 60 queries. A reviewer checked all judgments without
scores, corrected one unsupported relationship in a positive question, then approved the revised set. The input was
frozen at 2026-09-09 15:09 CEST with SHA-256
`fb3e0782c2f3334ffa25b5ab120d722058b122abe079072e49737b7782bdb737` before measurement.

One completed run used the unchanged production implementation at `5368a4bec94ac86c3d6b412eb676fec6d2865b15`,
with the original model, settings, projections, backend pipelines and metric/gate authority. It produced 144 slices,
122 gates and 360 rankings. Both backends embedded all 32 documents, with zero unembedded records or owner/corpus
leaks. Of the 122 gates, 118 passed, including every positive-quality and isolation gate. The four vector/hybrid
no-result gates failed:

| Backend | Keyword correct-empty | Vector correct-empty | Hybrid correct-empty |
|---|---:|---:|---:|
| SQLite | 10/10 | 1/10 | 1/10 |
| PostgreSQL | 10/10 | 1/10 | 1/10 |

The weakest positive's best relevant cosine is `0.306599693193539`; the strongest no-result candidate scores
`0.5997379651580476`. These direct bounds are identical on both backends. Keeping at least one relevant result for
every positive requires a cutoff at or below the former; rejecting every no-result candidate requires one above the
latter. No scalar cutoff can do both. All positives have a relevant candidate above the current `0.20` cutoff.
This is a feasibility bound, not a threshold sweep or a proposed setting.

For example, a question asks the colour of train 543. The matching passage gives train 543's departure time and
platform, but no colour. Its high similarity (`0.5997`) reflects the shared topic without supplying the requested
fact. A valid paraphrase about the owner of an accounting-service endpoint migration scores only `0.3066`.

**Stop here under the approved decision.** No candidate was selected; no mechanism, threshold, model or judgment
was changed after scoring. The original exposed evaluation was not rerun in this calibration attempt. No new unseen
holdout was authored or consumed. The original failed report and all five frozen assets remain byte-identical.
The temporary restricted PostgreSQL login was removed and the fixture container restored to stopped state.

The next product choice is separate: investigate an explicit answer-relevance check, or reduce/defer the hybrid
feature's release scope. The recommended next investigation is a bounded relevance check using the existing model
harness, evaluated on calibration before any production commitment. It would add model latency and cost; neither its
quality nor acceptable overhead has been demonstrated. ADR-050 and the Phase B PRD currently exclude additional
retrieval stages, so this investigation requires explicit authorization. The current requirements and release block
remain in force; a successful future candidate still needs the independent unseen holdout protocol above.

Calibration evidence is under `.agent_temp/0.26-recalibration/`: the frozen input and seal, scoreblind judgment review
and closure, native provenance, runner review and failure checks, `run01/receipt.json`, `run01/results/report.json`,
and `measurement-summary.json`. The completed failed report's SHA-256 is
`f8da3720f9963ed6cf429796e3d9642447cce9e0881e6225174ddd8863a66d42`.

### Preserved diagnosis and remaining release gates

Focused artifacts are under `.agent_temp/0.26-search-diagnosis/`: `score_probe.dart`, `score-probe.json`,
`calibration_parity_probe.dart`, `calibration-parity.json`, `score-path.md`, and `embedding-contract.md`.
The unchanged evaluation rerun at `frozen-run02/` completed 144 slices and 122 gates with the same four failures;
its temporary restricted PostgreSQL login was removed. The original report and checksum manifest remain at
`.agent_temp/0.26-final-pg/.agent_temp/0.26-final/retrieval-evaluation/`. Initial native/sandbox and stale-port failures
are retained separately and confer no passing evidence. See the combined manifest for the complete source mappings.

No production code or frozen input changes are proposed. Existing workspace, UI, packaging, workflow, storage,
and native-platform passing receipts remain reusable with their recorded causal mappings. Do not rerun those suites
solely for this decision document. A later implementation change requires focused causal proof, independent review,
the unchanged original evaluation, then one combined final verification covering the affected surfaces.

Native Linux x64, Windows x64, macOS x64 build-only, the complete release/installer matrix, exact-commit remote CI,
and operator ruleset confirmation remain outstanding. No push, workflow dispatch, remote settings change, merge,
tag, or publication is authorized. Bundle pruning and final release signoff wait for acceptance.
