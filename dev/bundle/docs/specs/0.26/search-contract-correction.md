# 0.26 search contract correction

## Current amendment: measured semantic quality (protocol 3)

Authorized 2026-09-13: “Sounds good, I'll go with your recommendations here.” The owner accepts inherent semantic
retrieval errors while requiring a bounded quality comparison before release. This amendment supersedes protocol
2's mandatory perfect semantic no-match gate below; it does not change passage judgments or isolation boundaries.

- Keep every independently justified `expectEmpty` query and its labels. Report its returned document IDs and
  correct-empty rate as semantic-quality diagnostics, including errors. Do not turn no-match cases into positives.
- Keep the existing positive ranking tolerances, vocabulary-lift gates and hard-zero owner/corpus leakage gates.
  Empty-corpus, owner/model/dimension mismatch, and stale/deleted-source exclusion remain exact structural tests.
- Compare only cutoff 0.20 with 0.25 through the real hybrid pipeline on both backends, using the existing exposed
  and historical calibration fixtures. Retain the same model, weights and candidate limits. Select 0.25 only if
  it reduces representative-calibration no-match returns, passes the existing positive gates, and remains within
  0.10 full-family / 0.20 corpus-family positive regression against baseline hybrid. Report historical per-query
  losses explicitly. If the tradeoff is not supported, retain 0.20; do not expand the parameter search.
- Freeze the selected parameters before the fresh independently authored fixture is scored. Run that evaluation
  once and retain its first completed result. Passing the numeric gates does not mean semantic perfection:
  the release record must disclose observed no-match errors alongside the positive results.
- Report protocol version 3 and `semanticNoMatchPolicy: diagnostic`, with 116 blocking gates and 144 slices.
  Fixture schema version 2, original asset bytes and earlier failed reports remain unchanged. A parameter change,
  if selected, uses a separately named settings artifact and preserves the original frozen settings.

Query expansion and reranking are future-version work, not part of the 0.26 quality pass.

## Historical protocol-2 correction

Authorized 2026-09-09 20:41 CEST: “Great, please proceed. And make use of subagents as needed.”
Supersedes the answer-relevance amendment in ADR-050 and the original FR7/S08 implication that absence of an
answer-bearing passage requires an empty retrieval result. Existing v1 evidence remains historical and unchanged.

## Runtime boundary

Hybrid search embeds the query, retrieves at most 20 lexical and 20 vector candidates, verifies canonical source
identity/content, fuses one-based ranks with `0.25/(60+keywordRank) + 0.75/(60+vectorRank)`, and returns top-K.
The vector cutoff remains 0.20. Neither cosine nor RRF scores certify answer sufficiency. Retrieval creates no
agent session or generative model turn. Embedding failure retains freshly authenticated lexical fallback.

Keep local EmbeddingGemma, explicit HTTP embedding support, incremental fingerprints/content hashes, PostgreSQL
pgvector exact cosine with owner/model/dimension lookup, PostgreSQL native GIN FTS, SQLite FTS5/exact vectors,
and strict owner/corpus boundaries. No new reranking stage, ANN index, tunable score or compatibility wrapper.

## Evaluation protocol 2

`dev/testing/retrieval/retrieval-v2.json` is a separately versioned, exposed regression fixture, not an unseen holdout.
Its 32 documents and 60 query texts are unchanged. Its first five families retain their meaning; `answer-absent`
replaces v1 `no-result`. Labels identify directly useful passage context, which can lack the requested answer.
A shared name alone does not establish usefulness. All judgments receive independent review before measurement.

Each query explicitly declares `expectEmpty`. It is true only for a fixed, independently justified no-match probe,
requires an empty relevant-document set, and contributes to the no-match gate. An empty relevance set alone never
implies this flag. Other unanswered cases remain visible diagnostics; they are not silently converted into positives.
Owner/corpus leakage remains hard zero for every case. Structural empty-corpus, owner/model/dimension mismatch and
deleted-source tests continue to establish exact empty-result behavior without a semantic answer classifier.

Ranking metrics use only queries with nonempty relevance judgments. Each slice records `queryCount`,
`positiveQueryCount` and `expectedEmptyQueryCount`; absent denominators yield null metrics, not fabricated success.
The no-match gate uses only explicit `expectEmpty` probes and their actual count. Existing hit@1, recall@5,
precision@5, MRR@5, vocabulary-lift and 0.10/0.20 comparative tolerances remain unchanged for positive families.
Report all 144 backend/mode/corpus/language/family slices, hardware, cold initialization, warm p95 and artifact hashes.

The existing evaluator is the sole implementation. It requires a native embedding model and both database backends,
not generative-agent configuration or credentials. Incomplete native/backend execution is not a successful result.
The original five frozen assets, source revisions, failed reports and hashes remain unchanged. Revised reports name
protocol 2 and the exposed-regression scope. No result from this fixture establishes independent unseen acceptance.
