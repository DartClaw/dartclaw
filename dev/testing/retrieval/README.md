# Retrieval evaluation fixtures

`retrieval-v2.json` is the built-in exposed regression fixture. Its hash and the selected search settings remain
unchanged. The original calibration, held-out results and failed independent evaluation remain historical evidence.

The reviewed fixtures below preserve the 32 documents and 60 query texts from the later exposed diagnostic sets.
A score-blind passage review removed five ambiguous mandatory-positive judgments. They use the existing
answer-absent diagnostic representation: `relevantDocumentIds: []`, `expectEmpty: false`. Such a query requires
neither a hit nor an empty result. All nine previously justified no-match declarations remain hard-empty probes.

| Exposed fixture | Positive queries | Hard-empty probes | Other diagnostics | SHA-256 |
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

The retained hard-empty IDs are calibration `nr05`–`nr10` and evaluation `q-aa-02`, `q-aa-05`, `q-aa-07`.
They include wrong-entity distractors and queries whose exact answer exists only outside the required owner or
corpus. Similarity does not exempt them from the current acceptance rule. Returning an unrelated authorized
passage is a relevance error; returning an unauthorized passage is a separate isolation violation.

These corrected assets are exposed regression inputs, not new independent acceptance evidence. Earlier classifier
experiments required perfect retention of selected positives as a screening criterion; that was stricter than
FR7's aggregate and slice tolerances. See the [acceptance decision](../../bundle/docs/specs/0.26/retrieval-acceptance-decision.md)
for the unresolved semantic no-match failures and the preserved experiment history.

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
decision; relabelling an exposed input does not satisfy it.
