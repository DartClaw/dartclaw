# S10 frozen runtime and proof review notes

Intent Context: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-public/dev/bundle/docs/specs/0.26/s10-startup-interlock-and-backend-switch-semantics.md`

This is the staged runtime/documentation/live-proof segment only. It omits the final `Story-Gate:` line and snapshot pending the frozen full manifest and the core guard remediation.

## Fix

### SQLite startup calls the inactive-PostgreSQL probe with no retained reference

- reviewer: `reviewer_s10_gate`
- severity: `LOW`
- confidence: `100`
- location: `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart:489-496`; `packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart:311-342`
- scope_relation: `primary`
- finding: The SQLite branch always invokes `inactivePostgresProbe` or `probeInactivePostgresStore`, including when both `database.url` and `database.credential` are absent. The production helper returns `empty` before resolution or connection, but the probe call itself still occurs. The injected live case demonstrates this: its callback runs for the absent configuration and only the nested connection counter remains zero.
- threatened_assumption_or_invariant: The S10 Technical Overview step 8a specifies “neither reference → no call”, and TI05 says the suite proves no call when neither reference is present.
- evidence: `_noticeInactiveStore` has no reference guard before lines 490-496. `runCase('absent', const DatabaseConfig())` passes an injected `inactivePostgresProbe` and asserts only `connections == 0`; therefore a callback-side counter would be one while the current test remains green.
- impact: Serving startup executes a probe seam the selected configuration did not request, and the proof claims a stronger absence property than it asserts. Production currently avoids a socket only because the callee repeats the guard.
- suggested_fix: In the SQLite branch, return `notice = null` without invoking either probe when `config.database.url == null && config.database.credential == null`. Add a callback invocation counter to the absent composition case and assert zero.
- verification_needed: Run the focused runtime interlock suite without the integration tag for analysis, plus the existing core absent-reference test; in the live source, prove the absent callback counter remains zero.
- Class: `code-defect`
- Routing: `Fix` – primary, certain, bounded, and uniquely determined by the explicit no-call branch.

## Note

### Failed runtime assembly can leak the acquired interlock before a runtime exists

- reviewer: `reviewer_s10_gate`
- severity: `HIGH`
- confidence: `100`
- location: `packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart:683-729,735-852,858-865,1445-1453`
- scope_relation: `primary`
- finding: `wireBase()` opens storage and acquires the serving PostgreSQL interlock at line 720, then can still fail while wiring the workflow registry. `wire()` then performs the much larger pre-runtime portion of `completeWithExecution`. The only startup cleanup catch begins after `_assembleRuntime` at line 852. A failure in the registry, security, harness, task, channel, provider-status, or other pre-assembly steps throws before any `DartclawRuntime` is returned and before any cleanup runs. `disposeBase()` cannot cover the registry case as written because `_baseWired` is set only after the registry succeeds.
- threatened_assumption_or_invariant: S10 owns the interlock for the serving runtime lifetime and states that failures after acquisition close the interlock and backend. A failed `DartclawRuntime.build` must not leave a hidden owner that blocks the next serving build.
- evidence: Static control-flow trace from `_wireStorage` through `wireBase` and `completeWithExecution` shows no enclosing catch/finally until after runtime assembly. The existing catch at 858 can call `runtime.shutdown()` only after a runtime exists. Tests cover a failure after runtime assembly (`postMcpStartupHook`) and active-store failures, but no failure between successful storage acquisition and `_assembleRuntime`.
- impact: In an embedded or test process, an ordinary later startup failure leaks the pool and dedicated lock with no handle available to the caller. A retry against the same database is refused by the leaked serving owner. The CLI process will usually exit, but `DartclawRuntime.build` is a public composition API and the process-exit side effect is not its resource owner.
- suggested_fix: Give `_RuntimeAssembly` one exception-safe partial-assembly cleanup path covering storage acquisition through runtime creation. Track initialized components rather than relying only on `_baseWired`, close in dependency order, preserve the original startup error, and make cleanup idempotent so the existing post-runtime catch can share it.
- verification_needed: Add a focused composition test with an injected failure immediately after storage wiring and another in pre-runtime completion; assert the backend closes and the same interlock key can be acquired immediately afterwards while the original error is preserved.
- Class: `code-defect`
- Routing: `Note` – the HIGH primary defect blocks a clean gate, but the uniquely safe partial-initialization ownership shape requires a lifecycle decision rather than a mechanical edit.

## Coverage evidence

Reviewed files:

- `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart`
- `packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart`
- `packages/dartclaw_runtime/lib/src/turn_runner_cancellation.dart`
- `packages/dartclaw_runtime/test/runtime/storage_wiring_recovery_order_test.dart`
- `packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_interlock_live_test.dart`
- `packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart`
- `packages/dartclaw_runtime/test/integration/postgres_serve_run_probe_test.dart`
- `apps/dartclaw_cli/test/commands/postgres_sanctioned_clients_live_test.dart`
- `packages/dartclaw_core/test/storage/postgres_live_support.dart`
- `dev/architecture/data-model.md`
- `dev/architecture/control-protocol.md`
- `dev/architecture/system-architecture.md`
- `CHANGELOG.md`

Immediate callers and ports read: `DartclawRuntime.build`, `stageHeadless`, `_RuntimeAssembly.wireBase`/`completeWithExecution`/`disposeBase`, `DartclawRuntime.shutdown`, `ServeCommand`, CLI standalone workflow staging, `TurnRunner`/`TurnManager` recovery calls, and existing startup-cleanup tests.

Falsifiers checked:

- Serving selection: `build(headless: false)` threads `serving: true`; stage/headless paths thread false; direct maintenance commands never use `StorageWiring` or `PostgresInterlock`. The live runtime and CLI suites drive real composition/command boundaries rather than constructing only the unit under test.
- Acquisition and refusal order: task backend opens, serving interlock acquires, then schema preparation and repository construction. The contender live proof checks the target namespace remains untouched and the refused backend is closed. Conflict output contains the remedy and distinctive DSN/userinfo fixtures are absent.
- Shutdown: the live proof holds a real transaction, observes the advisory lock during the blocked pool close, then proves lock removal and immediate reacquisition. Shutdown calls `beginShutdown`, closes the task backend, then releases the direct connection. Exceptional pre-runtime ownership is the HIGH finding above.
- Recovery: fatal loss is observed through a real terminated lock session and reaches the injected fatal path once. Core quarantine/re-gate mechanics remain outside this segment and await targeted closure after remediation.
- Orphan ordering: serving storage scans before the active-store factory; failed PostgreSQL and incompatible SQLite starts preserve bytes; successful gate leaves deletion and one-shot notice seeding to the runner; scan failure remains warning-only; headless composition preserves bytes and does not acknowledge.
- Backend switch: PostgreSQL selection checks populated current, populated legacy, ambiguous, and empty local stores and compares bytes. SQLite selection checks real current/empty/in-use PostgreSQL state and safe unresolved/posture/unreachable outcomes. The neither-reference no-call falsifier fails as recorded above.
- SQLite-free serve run: the suite installs a non-vacuous global open observer before `DartclawRuntime.build`, drives session creation, one actual harness turn, signed webhook handling, and shutdown, then asserts zero opens and no `.db` artifacts.
- Documentation: all three architecture pages and the changelog state ownership, recovery gates, shutdown order, no-transfer switch semantics, pre-gate scan/post-gate acknowledgement, and headless/one-shot exclusions. No story/task IDs or retired component names were introduced.

Verification evidence:

- Root-supplied focused runtime evidence: 104 tests PASS plus one headless preservation test PASS.
- `dart analyze --fatal-infos` over all frozen runtime/test/helper source paths – PASS, no issues.
- Live suites were source-reviewed only in this segment; execution remains deferred to the final combined gate by owner instruction, with no environment-based BLOCKED claim.
- Runtime proof patch identity supplied by root: `1a5e7d40f0e4d91083a36f2be137231a9f0dd30e79409230688eed1a93dfde76`.

Guardrails Coverage: 12 checked, 0 findings. Checked scope traceability, composition-root wiring, resource ownership, serve/headless boundary, one-shot exclusion, comments/dartdoc proportionality, no story IDs, safe output fixtures, integration tagging/no skipped tests, service-wiring and test-file ceilings, retired-name absence, and architecture/changelog synchronization. Accepted defects are reported once against their FIS/lifecycle roots rather than duplicated as guardrail findings.
