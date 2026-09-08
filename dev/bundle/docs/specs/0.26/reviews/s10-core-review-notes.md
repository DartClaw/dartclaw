# S10 frozen core review notes

Intent Context: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-public/dev/bundle/docs/specs/0.26/s10-startup-interlock-and-backend-switch-semantics.md`

This is the staged core-segment result only. It deliberately omits the final `Story-Gate:` line and snapshot because the runtime, documentation, live-proof, and full-manifest surfaces were not frozen for review yet.

## Fix

### Focused analyzer proof is red

- reviewer: `reviewer_s10_gate`
- severity: `LOW`
- confidence: `100`
- location: `packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart:8`
- scope_relation: `primary`
- finding: The live suite imports `src/storage/postgres_interlock.dart` even though the core barrel now exports every symbol it uses. The exact TI01 focused analyzer command exits 1 under `--fatal-infos` with `unnecessary_import`.
- threatened_assumption_or_invariant: TI01's proof-bearing live test must analyze cleanly, and project verification requires zero analyzer diagnostics.
- evidence: `dart analyze --fatal-infos packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart` returned exit 1 and identified line 8. The broader frozen-file analyzer invocation failed for the same single diagnostic.
- impact: TI01's declared verification cannot pass on the reviewed bytes, despite the supplied clean-analyzer attestation.
- suggested_fix: Remove the redundant `package:dartclaw_core/src/storage/postgres_interlock.dart` import.
- verification_needed: Re-run the exact focused analyzer command and the frozen-file analyzer command.
- Class: `code-defect`
- Routing: `Fix` – primary, certain, and mechanically resolved by deleting one redundant import; promoted by TI01's explicit Verify criterion.

## Note

### Exported backend exposes the quarantine release and a general guard bypass

- reviewer: `reviewer_s10_gate`
- severity: `HIGH`
- confidence: `100`
- location: `packages/dartclaw_core/lib/src/storage/postgres_backend.dart:201-216`; `packages/dartclaw_core/lib/dartclaw_core.dart:39`
- scope_relation: `primary`
- finding: `PostgresBackend` is barrel-exported, while `quarantine`, `releaseQuarantine`, and `runInInterlockRecovery(Future<T> Function())` are public instance methods. `@internal` produces analyzer guidance for external-package use but does not restrict calls. A downstream holder can invoke `releaseQuarantine()` directly or execute arbitrary backend operations inside `runInInterlockRecovery`, where `_ensureOpen` explicitly ignores the quarantine.
- threatened_assumption_or_invariant: FIS SC02/SC03 and the Technical Overview require one backend-owned private guard reached only by the interlock, with quarantine clearing only after reacquisition, version validation, and schema validation. The Execution Contract expressly says never to add a public `unquarantined` API. The project rule “One authority per concern” likewise assigns ownership recovery to the interlock.
- evidence: The barrel exports `PostgresBackend`; Dart exports all public members of a shown class. At lines 245-246 `_ensureOpen` permits every call in the recovery zone, and lines 209-216 expose both direct release and arbitrary zone entry. The unit/live suites exercise ordinary callers during quarantine, but none attempts either public bypass, so the green 23-test evidence does not falsify this path.
- impact: Code with a backend reference can dispatch while ownership is uncertain or reopen dispatch without any recovery gate. This defeats the central split-brain/data-integrity guarantee of S10 even though all normal-path guard tests pass.
- suggested_fix: Make the quarantine controls language-enforced package-private to the interlock/backend implementation, and expose only the bounded schema re-gate needed by recovery. Reasonable mechanisms include placing the collaborating implementation in one Dart library (`part`) or moving the orchestration behind a private backend-owned collaborator. Do not retain a public arbitrary callback that disables the guard.
- verification_needed: Add a compile-time/API-surface assertion or external-package analyzer fixture proving consumers cannot invoke quarantine controls; retain behavior tests showing the interlock alone can quarantine, run the schema gate, and release after all three gates.
- Class: `code-defect`
- Routing: `Note` – the defect is primary and blocking at HIGH, but choosing the language-enforced collaboration shape is not a uniquely mechanical edit.

## Coverage evidence

Reviewed files:

- `packages/dartclaw_core/lib/src/storage/postgres_interlock.dart`
- `packages/dartclaw_core/lib/src/storage/postgres_backend.dart`
- `packages/dartclaw_core/lib/src/storage/abandoned_store_probe.dart`
- `packages/dartclaw_core/lib/src/storage/authoritative_store_adoption.dart`
- `packages/dartclaw_core/lib/src/storage/sqlite_backend.dart`
- `packages/dartclaw_core/lib/dartclaw_core.dart`
- `packages/dartclaw_core/test/storage/postgres_interlock_test.dart`
- `packages/dartclaw_core/test/storage/postgres_interlock_live_test.dart`
- `packages/dartclaw_core/test/storage/abandoned_store_probe_test.dart`

Immediate context read: `DatabaseBackend`/`DatabaseStatement`, storage exception contracts, `PostgresSchemaGate`, posture and dispatch-policy references/callers, S10 FIS acceptance scenarios S01-S06 and SC01-SC08, relevant Dart/testing guidelines, and storage/tooling Learnings.

Falsifiers checked:

- TI01 ownership lifecycle: false acquisition closes the candidate; dual loss signals converge; shutdown suppresses recovery; candidates close on terminal paths; a session-pinned direct connection and fixed key are used. No independent lifecycle defect accepted.
- TI02 complete-seam quarantine: backend entry points, owner statements, transaction handles, and transaction statements reach `_ensureOpen`; pool dispatch is checked both before and after lease acquisition; successful recovery clears only after lock, version, schema, budget, open-session, and shutdown checks. The public bypass above falsifies exclusivity of that authority.
- TI05 probe: absent references open no socket; posture rejection occurs before connection; current-marker, content, holder, malformed marker, connection, query, audit, and close paths collapse to safe verdicts; local probes use the shared four-table predicate and preserve bytes. No independent probe defect accepted.
- Proof quality: secret fixtures are present in ownership and probe tests, so redaction assertions are non-vacuous; the real-boundary live suite is correctly integration-tagged and statically covers real advisory-lock ownership/release and termination recovery. Actual PostgreSQL execution remains part of the later final evidence by caller instruction.
- Wrong-reason-green focus: ordinary dispatch-count tests would remain green even with the exported bypass because they never call it; this is recorded in the HIGH finding. The local probe tests materially vary marker/content/holder/failure state rather than returning one constant verdict.

Verification evidence:

- `dart test --reporter=failures-only packages/dartclaw_core/test/storage/postgres_interlock_test.dart packages/dartclaw_core/test/storage/postgres_dispatch_policy_test.dart packages/dartclaw_core/test/storage/abandoned_store_probe_test.dart` – PASS, 23 tests.
- `git diff --quiet HEAD -- packages/dartclaw_core/lib/src/storage/postgres_dispatch_policy.dart` – PASS; file is tracked and unchanged.
- Focused frozen-file analyzer – FAIL, one `unnecessary_import` at `postgres_interlock_live_test.dart:8`.
- Live PostgreSQL tests were source-reviewed only in this segment; no environment-based BLOCKED claim is made.

Guardrails Coverage: 11 checked, 0 findings. Checked scope traceability, lean/no speculative config, one-authority intent, comments/dartdoc proportionality, no story IDs in code/tests, safe output construction, direct non-pooled lock, unchanged dispatch policy, integration tag/no skip, file ceilings, and retired-name absence. The authority failure is reported once as the FIS-anchored HIGH root cause rather than duplicated as a guardrail finding.

## Targeted closure – core guard remedy

The HIGH public quarantine-bypass finding is resolved on the frozen remedy:

- `postgres_interlock.dart` is a `part` of `postgres_backend.dart`, so `_quarantine`, `_releaseQuarantine`, `_validateRecoverySchema`, and the recovery-zone key are language-private within one Dart library.
- The production privileged zone contains only `PostgresSchemaGate.validateCurrent`; the method refuses an empty namespace and cannot bootstrap or write.
- The injectable interlock `schemaGate` hook runs before the privileged zone. The `forTesting` recovery validator substitute also runs outside it, and both assert that backend dispatch remains quarantined.
- Dynamic regressions prove the former public method names are absent. The repository-wide import scan found no direct import/export of the part file.
- Root evidence: focused analyzer clean and `postgres_interlock_test.dart` 10 tests PASS. Targeted source review and `git diff --check` found no residual issue.

The earlier LOW redundant-import finding is also resolved: the live suite now imports only the core barrel for interlock symbols.
