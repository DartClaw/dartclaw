# Retrieval evaluation fixtures

`retrieval-v2.json` is the built-in exposed regression fixture. Its hash and the selected search settings remain
unchanged. The original calibration, held-out results and failed independent evaluation remain historical evidence.

The reviewed fixtures below preserve the 32 documents and 60 query texts from the later exposed diagnostic sets.
A score-blind passage review removed five ambiguous mandatory-positive judgments. They use the existing
answer-absent diagnostic representation: `relevantDocumentIds: []`, `expectEmpty: false`. Such a query requires
neither a hit nor an empty result. All nine previously justified no-match declarations remain labelled negatives.
Under the owner-approved protocol 3, their actual returns and correct-empty rates are quality diagnostics rather
than perfect-rejection gates. Ownership, corpus boundaries and current-source exclusion remain strict.

| Exposed fixture | Positive queries | Semantic no-match probes | Other diagnostics | SHA-256 |
|---|---:|---:|---:|---|
| `calibration-reviewed.json` | 50 | 6 | 4 | `c44fd3008ed42cac2e21e6a283a0daa6f81e1f6036af601183c457172637141f` |
| `retrieval-reviewed.json` | 56 | 3 | 1 | `917a268b5dea6c7ed3a5f52188d569717e971e8b1d6c44bd959223d86fbace83` |

The five diagnostics retain related context without treating subject identity as proof of relevance:

| Query | Available context | Requested detail |
|---|---|---|
| Calibration `nr01` | Starter feeding quantities and cadence | Storage temperature |
| Calibration `nr02` | Bicycle tyre model and size | Frame size |
| Calibration `nr03` | The same Olive Yard lunch and its time | Tip percentage |
| Calibration `nr04` | Train 543 departure and platform | Train colour |
| Evaluation `q-aa-09` | The same FJORD-82 return and parcel handoff | Refund bank account |

The retained no-match IDs are calibration `nr05`–`nr10` and evaluation `q-aa-02`, `q-aa-05`, `q-aa-07`.
They include wrong-entity distractors and queries whose exact answer exists only outside the required owner or
corpus. Similarity does not turn these passages into relevant judgments. Returning an unrelated authorized
passage is a relevance error; returning an unauthorized passage is a separate isolation violation.

These corrected assets are exposed regression inputs, not new independent acceptance evidence. Earlier classifier
experiments required perfect retention of selected positives as a screening criterion; that was stricter than
FR7's aggregate and slice tolerances. See [ADR-050](../../adrs/050-native-hybrid-search.md#amendment-026-retrieval-and-answer-sufficiency)
for the approved quality tradeoff and the preserved experiment history.

The 2026-09-13 comparison retained cutoff 0.20. At 0.25 all positive rankings in the three modern fixtures were
unchanged and no-match returns decreased, but two historical vocabulary/cross-language queries lost their relevant
results on both backends. The original selected-settings asset therefore remains the active parameter set.

## Running the evaluator

From the repository root, validate a reviewed fixture with the existing schema and checksum checks:

```bash
dart run apps/dartclaw_cli/tool/retrieval_evaluation.dart --check-assets \
  --fixture-path dev/testing/retrieval/calibration-reviewed.json \
  --fixture-sha256 c44fd3008ed42cac2e21e6a283a0daa6f81e1f6036af601183c457172637141f \
  --fixture-status exposed-regression
```

For a measured run, replace `--check-assets` with `--model-path <verified-model.gguf> --output-dir <new-output-directory>`.
Set `DARTCLAW_TEST_POSTGRES_URL` to a test database provisioned with pgvector as described in the
[PostgreSQL guide](../../../docs/guide/postgresql.md#provisioning). Local connections without TLS need the explicit
`sslmode=disable` setting shown in the [test commands](../../guidelines/KEY_DEVELOPMENT_COMMANDS.md#ci-equivalent-gate).
The supplied model must match `modelSha256` in [selected-settings.json](selected-settings.json); native libraries
are supplied by the repository's Dart build hooks.

Every external fixture requires all three fixture arguments. `--fixture-status` accepts only `exposed-regression`
or `independent-evaluation`; built-in fixtures are always exposed. The status is an operator declaration, not proof
of independent authorship or review. A file path and checksum establish which bytes were used. Independent
acceptance additionally requires the author/reviewer separation and pre-scoring procedure in the acceptance
record; relabelling an exposed input does not satisfy it.

## Independent evaluation (2026-09-13)

The first completed protocol-3 evaluation at `e9e5892d` used 32 independently authored documents and 60 queries:
55 positive, four semantic no-match and one other diagnostic. Parameters were selected before scoring. All 116
blocking gates passed across 144 slices, with zero ownership/corpus violations. SQLite and PostgreSQL hybrid
ranked a relevant document first for 54/55 positive queries and within the top five for all 55 (MRR@5 0.9909).
Vocabulary-mismatch hit@1 and MRR@5 were 1.0 versus keyword-only 0.0 on both corpora and backends.

Keyword retrieval returned no results for all four no-match probes. Vector and hybrid each returned no results for
one of four; the other three returned 5, 9 and 5 irrelevant passages on each backend. All 24 backend/mode/probe
observations, including those errors, are retained in the completed report. Passing the approved gates does not
mean perfect semantic rejection or establish accuracy beyond this fixture.

| Evidence | SHA-256 |
|---|---|
| Independent fixture | `c88c64f674cd757b9d2b035fc9f6d50e3f40f863644411baf47a115e5b1a1401` |
| First completed report | `82e910eda87c062feed0e28185b57ddeaeca9b4bbbbd31bb304e39e5e20ff5cf` |
| Selected settings | `32bf711292532f51313404072d61ff6443660a5c578cd0095574de94a8303a1a` |

The fixture, authorship review and first report are retained with the local release evidence under
`.agent_temp/reviews/0.26/quality-pass/independent-20260913/` and `.agent_temp/reviews/0.26/no-match-fix/unseen/`.
This fixture is now exposed and must not be reused as unseen evidence.

## Public benchmarks for the search follow-up

Public retrieval sets can supplement the memory/conversation fixtures. Keep any selected sample and its split
fixed before comparison; record that a sampled corpus changes retrieval difficulty. Missing relevance judgments
are not proof that a passage is irrelevant or that a query is unanswerable.

- [FineWeb2-IR](https://huggingface.co/datasets/hotchpotch/FineWeb2-IR) includes Swedish and English, generated
  passage-based questions and mined hard negatives. Small pinned validation/test samples could broaden language
  coverage for expansion/reranking work. Its web-domain and synthetic questions are a different distribution from
  personal memory; its hard negatives are not human-judged no-match questions. Follow the upstream dataset and
  Common Crawl license terms before copying a sample.
- [BEIR/MS MARCO](https://huggingface.co/datasets/BeIR/msmarco) provides English corpus/query/relevance files for
  ranking evaluation. It is useful for broader retrieval regressions, not Swedish or owner/corpus isolation. Its
  dataset card declares CC-BY-SA-4.0; retain attribution and verify source terms for any redistribution.
- [QMD's example fixture](https://github.com/tobi/qmd/blob/04e4dbd8245c527a88f1a8f0bda547aef9ca81fb/src/bench/fixtures/example.json)
  is a small MIT-licensed English ranking example with ten positive queries. It has no judged no-match cases and
  cannot establish semantic-empty behavior.

These are future benchmark inputs, not additional 0.26 release gates or runtime dependencies. The completed quality
pass used the retained local fixtures and the independent evaluation recorded above.
