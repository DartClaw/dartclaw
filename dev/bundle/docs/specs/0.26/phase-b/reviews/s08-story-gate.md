Intent Context: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-public/dev/bundle/docs/specs/0.26/phase-b/s08-sealed-retrieval-evaluation-harness.md`

## Fix

None.

## Note

None.

Coverage evidence: reviewed the two-mode argument boundary and asset-only isolation; all five pinned SHA-256 values and frozen fixture/settings shape checks; unique-document ranking, fixed-denominator hit/recall/precision/MRR formulas, raw-microsecond nearest-rank p95, stable 144-row slice matrix and 122-row strict-lift/regression/no-result/owner/corpus gates; production SQLite and PostgreSQL schema/index/vector/projection/synchronizer/provider/hybrid composition; target-owner and corpus isolation accounting; lazy first-document embedding timing; safe failure output, source/environment protocol, atomic report and sorted checksum manifest without DSN, query, document, vector or exception content; exact wiki-first, memory-only, fused-score and lexical-fallback composition. The supplied focused evidence covers TI01 5 tests plus asset preflight, TI02 3 tests plus scoped analyzer success, TI03 2 tests, clean formatting, and successful falsification of both positive-fusion-score and second-negation mutants. Held-out scoring, native/model execution, PostgreSQL execution, full suites and the fast tier were not run in this review.

Targeted closure: the analyzer-only delta applies 15 mechanical constructor/interpolation lint fixes, removes the unused lexical-backend field while the existing closure retains and closes the lexical handle, declares the directly imported `crypto` development dependency, and renames the immutable historical calibration fixture to `.dart.txt`. Its bytes and pinned SHA-256 remain unchanged; only the three evaluator lookup/manifest labels follow the new filename.

Applied inline severity calibration and the critic pass (Findings Filter skipped: no Critical findings and <=5 total).

Guardrails Coverage: 12 checked, 0 findings

Files: apps/dartclaw_cli/pubspec.yaml, apps/dartclaw_cli/test/tool/retrieval_evaluation_pipeline_test.dart, apps/dartclaw_cli/test/tool/retrieval_evaluation_test.dart, apps/dartclaw_cli/tool/retrieval_evaluation.dart, apps/dartclaw_cli/tool/retrieval_evaluation/evaluation.dart, apps/dartclaw_cli/tool/retrieval_evaluation/pipeline.dart, dev/testing/retrieval/calibration-fixture.dart.txt, dev/testing/retrieval/calibration-negatives.json, dev/testing/retrieval/calibration-summary.md, dev/testing/retrieval/heldout.json, dev/testing/retrieval/selected-settings.json, packages/dartclaw_runtime/test/search/hybrid_wiki_composition_test.dart

Story-Gate: PASS @ 1c41ebb6e823+2e913c808669
