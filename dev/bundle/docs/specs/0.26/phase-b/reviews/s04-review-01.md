Intent Context: dev/bundle/docs/specs/0.26/phase-b/s04-hybrid-fusion-and-incremental-synchronization.md

Independent reviewer_b_s04_gate reported four Fix findings:
- MEDIUM: Missing inclusive cutoff and equal-score tie regression proof.
- MEDIUM: Fake lexical/vector ports ignored owner and fingerprint arguments, leaving boundary propagation unproved.
- LOW: README and CHANGELOG kernel-only dependency wording omitted crypto.
- LOW: Architecture-tool comment named a transient story ID.

Root closure: changed the existing cutoff fixture to exactly0.20, added genuine equal-score rank pairs(6,6)/(17,3), recorded boundary arguments and added non-default owner/model tests across search/authentication/diagnostics/sync/rebuild/counts, corrected dependency wording and removed the transient reference. Focused23PASS. Isolated mutations all failed on their owning behavioral assertions; see b-s04-mutations/results.json and logs.

Guardrails Coverage: 14 checked, 1 finding

Files: CHANGELOG.md, dev/tools/arch_check.dart, packages/dartclaw_search/README.md, packages/dartclaw_search/lib/dartclaw_search.dart, packages/dartclaw_search/lib/src/current_corpus_inventory.dart, packages/dartclaw_search/lib/src/hybrid_search.dart, packages/dartclaw_search/lib/src/hybrid_search_backend.dart, packages/dartclaw_search/lib/src/vector_synchronizer.dart, packages/dartclaw_search/pubspec.yaml, packages/dartclaw_search/test/hybrid_search_test.dart, packages/dartclaw_search/test/public_api_test.dart, packages/dartclaw_search/test/search_test_support.dart, packages/dartclaw_search/test/vector_synchronizer_test.dart

Story-Gate: FAIL @ cfd4e17bb7c9+3067c38afb27
