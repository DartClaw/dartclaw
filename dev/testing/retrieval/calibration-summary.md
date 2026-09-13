# Phase B calibration measurements

This is calibration-only evidence from the historical 24-document/16-query fixture and 10 separately authored no-result queries. No held-out data was opened or run, and no acceptance setting is selected here.

Settings: candidate limit 20, top 5, cosine over normalized EmbeddingGemma vectors, RRF k=60, fixed document timestamp, one warm-up pass, and one measured repetition per query. Recall@5 is the macro mean of per-query recall. Precision@5 uses a denominator of five for every query. MRR@5 considers the returned top five.

The highest cosine for any calibration negative was 0.1421. The lowest best-relevant cosine for a positive was 0.2048. Threshold 0.20 retained every positive judgment while returning no vector hit for all 10 negatives. Threshold 0.25 clipped q02 at 0.2287 and q13 at 0.2048; threshold 0.30 produced the same aggregate metrics because q01 remained just above it at 0.3001. Exact per-query positive and negative cosine bounds are in `out/measurements.json`.

## Constituents

| Mode | Threshold | Hit@1 | Recall@5 | Precision@5 | MRR@5 | No-result empty | Warm p95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| SQLite FTS5 keyword | – | 0.1875 | 0.1875 | 0.0375 | 0.1875 | 1.0000 | 0.149 |
| PostgreSQL English keyword | – | 0.2500 | 0.2500 | 0.0500 | 0.2500 | 1.0000 | 2.420 |
| PostgreSQL Swedish keyword | – | 0.3750 | 0.3750 | 0.0750 | 0.3750 | 1.0000 | 2.547 |
| Vector | 0.20 | 1.0000 | 1.0000 | 0.2375 | 1.0000 | 1.0000 | backend probe below |
| Vector | 0.25 | 0.8750 | 0.8750 | 0.2000 | 0.8750 | 1.0000 | backend probe below |
| Vector | 0.30 | 0.8750 | 0.8750 | 0.2000 | 0.8750 | 1.0000 | backend probe below |
| Vector | 0.40 | 0.7500 | 0.7188 | 0.1500 | 0.7500 | 1.0000 | backend probe below |
| Vector | 0.50 | 0.4375 | 0.4063 | 0.0875 | 0.4375 | 1.0000 | backend probe below |
| Vector | 0.60 | 0.1250 | 0.1250 | 0.0250 | 0.1250 | 1.0000 | backend probe below |
| Vector | 0.70 | 0.0625 | 0.0625 | 0.0125 | 0.0625 | 1.0000 | backend probe below |

## RRF candidates

All three requested keyword/vector weight pairs, 0.5/0.5, 0.25/0.75, and 0.1/0.9, produced the same aggregate top-five metrics at every threshold on this fixture. Every row therefore reports each of those three candidates. Keyword results were retained regardless of vector threshold.

| Backend | Threshold | Hit@1 | Recall@5 | Precision@5 | MRR@5 | No-result empty |
|---|---:|---:|---:|---:|---:|---:|
| SQLite | 0.20 | 1.0000 | 1.0000 | 0.2375 | 1.0000 | 1.0000 |
| SQLite | 0.25 | 0.8750 | 0.8750 | 0.2000 | 0.8750 | 1.0000 |
| SQLite | 0.30 | 0.8750 | 0.8750 | 0.2000 | 0.8750 | 1.0000 |
| SQLite | 0.40 | 0.7500 | 0.7188 | 0.1500 | 0.7500 | 1.0000 |
| SQLite | 0.50 | 0.4375 | 0.4063 | 0.0875 | 0.4375 | 1.0000 |
| SQLite | 0.60 | 0.2500 | 0.2500 | 0.0500 | 0.2500 | 1.0000 |
| SQLite | 0.70 | 0.1875 | 0.1875 | 0.0375 | 0.1875 | 1.0000 |
| PostgreSQL English | 0.20 | 1.0000 | 1.0000 | 0.2375 | 1.0000 | 1.0000 |
| PostgreSQL English | 0.25 | 0.8750 | 0.8750 | 0.2000 | 0.8750 | 1.0000 |
| PostgreSQL English | 0.30 | 0.8750 | 0.8750 | 0.2000 | 0.8750 | 1.0000 |
| PostgreSQL English | 0.40 | 0.7500 | 0.7188 | 0.1500 | 0.7500 | 1.0000 |
| PostgreSQL English | 0.50 | 0.4375 | 0.4063 | 0.0875 | 0.4375 | 1.0000 |
| PostgreSQL English | 0.60 | 0.3125 | 0.3125 | 0.0625 | 0.3125 | 1.0000 |
| PostgreSQL English | 0.70 | 0.2500 | 0.2500 | 0.0500 | 0.2500 | 1.0000 |
| PostgreSQL Swedish | 0.20 | 1.0000 | 1.0000 | 0.2375 | 1.0000 | 1.0000 |
| PostgreSQL Swedish | 0.25 | 0.8750 | 0.8750 | 0.2000 | 0.8750 | 1.0000 |
| PostgreSQL Swedish | 0.30 | 0.8750 | 0.8750 | 0.2000 | 0.8750 | 1.0000 |
| PostgreSQL Swedish | 0.40 | 0.8125 | 0.7813 | 0.1625 | 0.8125 | 1.0000 |
| PostgreSQL Swedish | 0.50 | 0.5625 | 0.5313 | 0.1125 | 0.5625 | 1.0000 |
| PostgreSQL Swedish | 0.60 | 0.4375 | 0.4375 | 0.0875 | 0.4375 | 1.0000 |
| PostgreSQL Swedish | 0.70 | 0.3750 | 0.3750 | 0.0750 | 0.3750 | 1.0000 |

At threshold 0.20, hybrid vocabulary-mismatch Hit@1 and MRR@5 were 1.0 for both the one-query Swedish family and two-query English family on all three backends; keyword-only was 0.0 for both families. At 0.25 and above, the Swedish vocabulary-mismatch query was clipped.

Warm p95 milliseconds for keyword/vector/hybrid were 0.149/7.317/7.827 on SQLite, 2.420/18.062/27.040 on PostgreSQL English, and 2.547/16.592/25.581 on PostgreSQL Swedish. The latency probe used threshold 0.5 and equal weights; threshold and weights only change the in-process filtering and fusion after keyword and embedding work.

The successful rerun used already materialized native assets: model load 420 ms, 24-document embedding 187 ms, and the 26-query batch 145 ms. The original cold run is preserved under `out/run01/` and recorded model initialization at 11,915 ms.

Full per-language, per-family, per-query score-bound, and per-candidate measurements are in `out/measurements.json`. Exact top-five rankings are in `out/rankings.json`. `artifact-sha256.txt` contains machine-generated fingerprints for these results, the runner, fixture, model, native archive, lockfiles, and production index sources.

Runtime: public production sources at HEAD `3c4a82256c98392c93ce00185d311e70e03b8cc8`, LlamaDart 0.8.22, native 0.3.0, SQLite package 3.3.1, PostgreSQL package 3.5.12, Dart 3.13.2, macOS 26.6.2 arm64. Hardware: Mac mini (Mac16,11), Apple M4 Pro, 14 cores, 48 GB memory.

The runner created one unique `dc_calibration_*` PostgreSQL schema, evaluated English then Swedish after reindexing the same 24 documents, and dropped the schema in `finally`. The credential stayed in the mode-0600 local `postgres.env`; no DSN is present in captured output.
