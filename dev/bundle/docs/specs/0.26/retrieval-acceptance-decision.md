# Retrieval acceptance decision

## Current investigation: no-match failures

On 2026-09-11 the owner requested deeper investigation and an attempted fix, including independent agents, rather
than accepting semantic no-match failures as a release limitation. No acceptance requirement has been relaxed.

The independent evaluation at `1f68bee6` completed both backends: 118/122 gates passed. The four failing gates were
vector/hybrid no-match on SQLite/PostgreSQL; all four original empty probes returned passages. All 56 positive
queries found a relevant passage within five results, and isolation gates passed. Original fixture SHA-256:
`0525b5b309495a7f553973324f97c9a87d992a46d75d008e84344e865177744c`. Original report SHA-256:
`d5adb29eaa7e4caaaa2981467c2ba0d347af633d7d76c22577817c6e35b9343b`. That failed result remains unchanged.

Independent label review and a separate architecture challenge found one ground-truth defect: `q-aa-09` demands
empty results for a bank-account question about FJORD-82, although authorized conversation `doc-23` provides context
about that exact return transaction. Under the existing passage contract, it is relevant without supplying the
account. A separate exposed diagnostic copy changes only that query to relevant `doc-23`, `expectEmpty: false`
(SHA-256 `b80a6402d94c47f1cdbea8b9f626109b88114bd3717bce49de2cb68f157b486f`). The other three empty probes are valid
and still fail at the selected cutoff. This correction is not a new unseen acceptance result.

The original cutoff calibration used ten distant-topic English keyword lists. It omitted natural-language,
Swedish and same-topic wrong-entity negatives. Production-path checks found unchanged projected text, correct
model prefixes, normalized 768-dimensional vectors and SQLite/direct-cosine agreement within `3.75e-9`.
Primary-source review found no EmbeddingGemma inference-contract discrepancy.

A score-blind passage-label review of the separately authored representative calibration retained all 32 documents
and 60 query texts, with 54 context-positive queries and six genuine no-matches. Diagnostic cutoff comparisons:

| Cutoff | Positive queries losing all relevant vectors | Correctly empty no-match queries |
|---|---:|---:|
| 0.20 | 0/54 | 1/6 |
| 0.25 | 0/54 | 2/6 |
| 0.50 | 20/54 | 5/6 |

The wrong-train negative reaches `0.54564`, above a valid positive at `0.30660`. Four proposed wrong-entity
controls score `0.41479–0.58203`. A controlled comparison with the already-local Qwen3-Embedding-0.6B likewise
finds overlapping positive/negative scores (`0.25689` minimum positive; `0.55338` maximum negative). Neither a
cutoff change nor that alternate embedder resolves the measured issue without losing useful results.

One local cross-encoder experiment used `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1` at revision
`1427fd652930e4ba29e8149678df786c240d8825`, its 118,620,017-byte ARM64 INT8 ONNX artifact and a predeclared raw-logit
cutoff of zero. That cutoff is a diagnostic choice, not a model-certified probability or decision boundary. It
retained 41/54 calibration positives and 44/57 corrected independent positives within five results; no-match
emptiness was 6/6 and 2/3 respectively. Three of four wrong-entity controls still passed its filter. The complete
1,808-pair CPU experiment took 2.71 seconds with approximately 815 MB peak process RSS; it does not qualify the
model for DartClaw, and Swedish is not among its documented training languages. No thresholds were tuned.
This standalone experiment scores all scoped passages without the existing cosine filter; its empty counts are not
results from an integrated hybrid-plus-reranker pipeline. The positive losses and wrong-entity controls remain
disqualifying evidence for this candidate.

Further native feasibility checks reproduced the distinction between ranking and rejection. The multilingual
`BAAI/bge-reranker-v2-m3` retained all 111 positives within five results before filtering, but its predeclared
diagnostic zero-logit cutoff retained only 81/111. It rejected all nine explicit-empty queries. Calibration still
has overlapping scores: weakest best-relevant `-10.854168`, strongest no-match `-5.254712`. Its 1,808-pair CPU run
took 29.59 seconds with approximately 2.23 GB peak RSS. This does not support integrating its scalar filter.

`Qwen3-Reranker-0.6B` was tested through the existing pinned native generation API with one exact `yes`/`no`
output, neutral sampling and the official prompt. The verified Q8 artifact SHA-256 is
`22c9979ce4fbcdc5acdc310c6641c32797eff1aa980b8f7a2db8a8ea23429a48`. The stock instruction retained 99/111 positives
and rejected eight of nine no-matches; one separately frozen context-oriented instruction retained 96/111 and
rejected seven of nine. Both accepted two of three unambiguous wrong-entity controls. All 3,618 outputs, including
the two smoke checks, satisfied the strict enum. Neither condition qualifies as a runtime fix.

An independent `llama-server` executable reproduced all ten selected native labels using the same model and
prompts. Its pre-sampling yes/no margins confirmed confident wrong-project/train acceptance and a paraphrase
false negative. The failures are not explained by the Dart binding, grammar, or a numerical tie. These diagnostic
artifacts are under `.agent_temp/reviews/0.26/no-match-fix/`; none is independent release acceptance.
Both sweeps classified all scoped passages outside the production candidate lifecycle; no integrated
hybrid-plus-reranker candidate was tested. The Qwen false accepts' reachability through the current cosine filter
was checked against previously recorded production-path evidence, without another integrated run.

The supplementary architecture review also found an ambiguity in the proposed `return-code-sv` control: the query
names a case ID while the passage names a support code. Those fields need not be identical. Preserve that original
row and its measurements, but exclude it from decisive wrong-entity claims. The other three controls remain
usable; the key-location pair changes both name and object type, so its success alone does not isolate name
recognition. This qualification does not remove the observed wrong-project and wrong-train failures.

A final bounded capability probe used the instruction-following `Qwen3-4B-Q4_K_M.gguf`, SHA-256
`7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5`, through its embedded non-thinking chat template
and the same native strict-enum seam. One prompt and 16 exposed cases were fixed before inference. It rejected all
four negative cases but retained only eight of twelve positives: three omitted-answer context cases and one
paraphrase were rejected. All outputs were valid enums. Model load took 1.27 seconds; the capsule run took 18.23
seconds with approximately 3.17 GB peak process RSS. The verified model file is 2,497,280,256 bytes. The capsule
failure ended that candidate: no prompt variants, full fixture sweep, or unseen evaluation followed it.

The final three candidate approaches in this investigation failed their bounded qualification: BGE scalar
filtering, the Qwen reranker decision, and an instruction-following classifier. None was integrated into the
runtime. The independently authored replacement fixture remains unscored; its reviewed labels and all original
failed diagnostic evidence are preserved.

The label defects are recorded separately from the original diagnostic fixtures. No investigated candidate has
qualified for a runtime implementation under the passage contract. Production parameters, model selection
and dependencies remain unchanged. Release acceptance remains unresolved; the earlier limitation-acceptance
proposal was not adopted.

## Current independent-evaluation procedure

Owner approved a pragmatic evaluation on 2026-09-10: keep search parameters fixed, use fresh author and reviewer sessions without prior fixtures or results, check overlap before scoring, and run the existing evaluator once. Record the tested code revision for traceability; do not freeze unrelated development. This supersedes the earlier administrator-exclusion, inaccessible-custodian and hard-isolation prerequisites below. Session separation is procedural rather than a claim that the coordinator cannot administer the environment. Preserve all original evidence and the first completed new result; do not tune parameters or revise judgments against its scores.

Earlier exposed-regression result: the owner approved the [search contract correction](search-contract-correction.md). Ordinary
hybrid retrieval and RRF remain; the answer judge and Claude calibration are superseded. Protocol-2 regression
judgments were independently reviewed before measurement. All 122 gates across 144 slices pass; 11,931 workspace
tests pass with 44 configured skips, PostgreSQL integration and both AOT builds pass. Independent code/security
review is Ready. See `final-combined-verification.json`, `searchContractCorrection`. The records below describe earlier decisions, whose
original failures remain valid under their original contract. Unseen and platform acceptance remain separate.

Status: root-cause relevance fix authorized on 2026-09-09 after calibration reached its stop condition.
Authorization: "Ok, please proceed with this and fix the root problem so all this works as intended."
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

## Approved calibration decision

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

## Authorized relevance correction

After calibration proved that no scalar cutoff can meet the existing requirements, the maintainer authorized
fixing the root problem. This supersedes the preceding calibration decision's prohibition on investigating and
implementing a new relevance mechanism. It does not relax the frozen quality gates or the holdout protocol.

The correction adds one bounded model judgment over authenticated candidate passages, before selecting the top
results. It asks whether each passage contains the requested information, preserves candidate order, and uses the
existing runtime execution and output-schema authorities. ADR-050 records the mechanism and its additional model
latency, cost and provider trust boundary. Existing embeddings and retrieval settings remain unchanged.

Local verification completed on 2026-09-09: 11,953 workspace tests passed with 44 configured skips; PostgreSQL
contracts and both-corpus relevance wiring, formatting, analysis, architecture/fitness gates and both AOT builds passed.
The source stayed unchanged during the final run. Code and security reviews closed with zero findings after two
remediation rounds. Earlier failed runs remain retained, including a shared-catalog DDL race resolved by serializing
the destructive PostgreSQL test suites without removing tests or assertions.

Runtime refuses providers without complete tool interception before starting an empty-policy worker. Claude supports
the guarded turn, while current Codex and ACP harnesses refuse it. Lexical fallback re-authenticates current content;
evaluation requires explicit model/auth selection and seals terminal outcomes and complete reported-cost evidence.
The maintainer approved Claude-only relevance routing: "Go ahead and use claude". The explicit
`search.relevance_model` route keeps Codex primary and pins Claude without inheriting Codex effort. A synthetic live
canary passed all three checks (answer present, answer absent, Swedish), with complete accounting and unchanged source.
The first canary exposed a sequential-worker release race; the corrected path awaits the existing settlement and lease
release before returning. The passing canary took 17.8–20.7 seconds per check and reported $0.146263 across three turns.
The routed implementation then passed 11,964 workspace tests with 44 configured skips, PostgreSQL integration,
formatting, analysis, architecture/fitness gates and both AOT builds. Source bytes stayed unchanged during verification.
Code and security reviews found no remaining defects. Runtime measures 67,399 lines; the reviewed proportional-band
ceiling is 68,899 after safe in-scope reduction was exhausted.
No representative live relevance calibration, candidate seal, exposed rerun or new unseen holdout has run yet.
Automatic approval review blocked the calibration command before execution twice. It requires a new explicit
approval to send calibration queries and candidate passages to Claude; it declined the recovered preceding approval
question as authorization evidence. No calibration payload was sent. The verified implementation is `994620af`.

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
