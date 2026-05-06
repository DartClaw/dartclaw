# S11 — Turn/Pool/Harness Interface Extraction to dartclaw_core

**Plan**: ../plan.md
**Story-ID**: S11

## Feature Overview and Goal

Extract abstract interfaces for `TurnManager`, `TurnRunner`, `HarnessPool`, and `GoogleJwtVerifier` from `dartclaw_server` into `dartclaw_core` (`src/turn/`, `src/auth/`). Concrete implementations stay in `dartclaw_server`; the `dartclaw_testing` fakes (`FakeTurnManager`, `FakeGoogleJwtVerifier`) rebind to the new core-owned interfaces, enabling the `dartclaw_testing → dartclaw_server` pubspec edge to be removed (TD-063) and unblocking S25's `testing_package_deps_test.dart` Level-2 fitness function.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S11" entry under per-story File Map; binding constraints #14, #15, #16, #21, #71, #72, #73, #75)_

## Required Context

### From `prd.md` — "FR3: Package Boundary Corrections"
<!-- source: ../prd.md#fr3-package-boundary-corrections -->
<!-- extracted: e670c47 -->
> **Description**: Extract abstractions that currently sit in the server package's concrete implementation so stable packages depend on interfaces, not volatile impls. **Note (2026-05-04 reconciliation)**: TD-063's pubspec edge was already removed during 0.16.4 (`dartclaw_testing/pubspec.yaml` lists only `dartclaw_core` under `dependencies:`); the entry will be deleted at sprint close as 0.16.4-closure backlog hygiene rather than counting toward 0.16.5 closure. The actual interface-extraction work (the substantive part of FR3) is unchanged.
>
> **S11-applicable Acceptance Criteria** (verbatim):
> - `TurnManager`, `TurnRunner`, `HarnessPool`, `GoogleJwtVerifier` interfaces in `dartclaw_core` (`src/turn/`, `src/auth/`); concrete impls stay in server
> - `FakeTurnManager`, `FakeGoogleJwtVerifier` in `dartclaw_testing` bind to the interfaces
> - `dartclaw_testing/pubspec.yaml` drops `dartclaw_server` dependency (closes TD-063) — *already met by 0.16.4*; verify still met at sprint close and delete TD-063 entry

### From `plan.md` — "S11: Turn/Pool/Harness Interface Extraction to dartclaw_core"
<!-- source: ../plan.md#p-s11-turnpoolharness-interface-extraction-to-dartclaw_core -->
<!-- extracted: e670c47 -->
> **Risk**: High — cross-package surface move; consumer compatibility risk
> **Scope**: Extract abstract interfaces for `TurnManager`, `TurnRunner`, `HarnessPool`, and `GoogleJwtVerifier` from `dartclaw_server` into `dartclaw_core` (`src/turn/`, `src/auth/`). Concrete implementations remain in `dartclaw_server`. `dartclaw_testing` `FakeTurnManager` + `FakeGoogleJwtVerifier` rebind their `implements` clauses to the new interfaces. **Note (2026-05-04 reconciliation)**: `dartclaw_testing/pubspec.yaml`'s `dartclaw_server` dependency was already removed during 0.16.4 release prep — only `dartclaw_core` is listed under `dependencies:`. TD-063 is therefore effectively closed; the entry will be deleted at sprint close as backlog hygiene rather than counting toward 0.16.5 closure. The actual interface-extraction work is unchanged. Verify every consumer's expectations are met by the derived interface surface (grep + Dart LSP call-hierarchy over each type to enumerate method use).
>
> **Acceptance Criteria**:
> - Four abstract interfaces live in `dartclaw_core` with matching method signatures (must-be-TRUE)
> - `dartclaw_testing/pubspec.yaml` no longer declares `dartclaw_server` — already met by 0.16.4; verify still met at sprint close
> - `FakeTurnManager` / `FakeGoogleJwtVerifier` implement the new interfaces (must-be-TRUE)
> - `dart analyze` and `dart test` workspace-wide pass
> - `testing_package_deps_test.dart` fitness function (S25) will validate this invariant; in this story, a minimal assertion in `dartclaw_testing/test/fitness_smoke_test.dart` or similar confirms the dep is gone
>
> **Key Scenarios**:
> - Happy: every consumer of `TurnManager` (production + fakes + tests) still works via the interface
> - Edge: a consumer depends on a concrete method not captured by the interface — FIS discovery phase surfaces this and either widens the interface or narrows the consumer

### From `.technical-research.md` — "Binding PRD Constraints" (S11-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #2 (Constraint): "No new dependencies in any package." — Applies to all stories; this story adds no deps.
> #14 (FR3): "`TurnManager`, `TurnRunner`, `HarnessPool`, `GoogleJwtVerifier` interfaces in `dartclaw_core` (`src/turn/`, `src/auth/`); concrete impls stay in server." — S11.
> #15 (FR3): "`FakeTurnManager`, `FakeGoogleJwtVerifier` in `dartclaw_testing` bind to the interfaces." — S11.
> #16 (FR3): "`dartclaw_testing/pubspec.yaml` drops `dartclaw_server` dependency (closes TD-063) — already met by 0.16.4; verify still met at sprint close." — S11.
> #21 (FR3): "`testing_package_deps_test.dart` + `no_cross_package_env_plan_duplicates_test.dart` fitness functions pass." — S10, S25, S32 (S25 produces the L2 file; S11 produces the post-extraction state it asserts).
> #71 (NFR Compatibility): "All existing JSONL/REST/SSE protocols stable; no protocol changes." — S11.
> #72 (NFR Security): "No regression in guard chain, credential proxy, audit logging — all existing security tests pass." — S11, S32, S33.
> #73 (NFR DX): "`dart analyze` workspace-wide: 0 warnings (maintained)." — Applies to all code-touching stories.
> #75 (Constraint): "Workspace-wide strict-casts + strict-raw-types must remain on." — Applies to all code-touching stories.

### From `plan.md` — "2026-05-04 reconciliation: discovery-time correction"
<!-- source: ../plan.md#feasibility-fundamentals -->
<!-- extracted: e670c47 -->
> The plan and PRD both record TD-063 as "already met by 0.16.4 — only `dartclaw_core` is listed under `dependencies:`." **Discovery at FIS time (commit `e670c47`) contradicts this**: `packages/dartclaw_testing/pubspec.yaml` still lists `dartclaw_server: path: ../dartclaw_server` under `dependencies:`; both fakes still `import 'package:dartclaw_server/dartclaw_server.dart';`; and the testing barrel still re-exports `BusyTurnException, GoogleJwtVerifier, HarnessPool, TurnManager, TurnOutcome, TurnRunner, TurnStatus` from `package:dartclaw_server/dartclaw_server.dart`. `arch_check.dart` (`dev/tools/arch_check.dart:44-51`) still permits the edge. Treat removal of the pubspec edge + barrel re-export migration as in-scope work for this FIS, not as verify-only — the reconciliation note proves to be an aspirational pre-write, not a completed state.

## Deeper Context

- `packages/dartclaw_testing/CLAUDE.md` § "Boundaries" — currently asserts `dartclaw_server` as an *allowed* prod dep for this package; must be updated as part of this story.
- `packages/dartclaw_core/CLAUDE.md` § "Boundaries" — `dartclaw_core` may depend on `dartclaw_config`, `dartclaw_models`, `dartclaw_security` only. New `src/turn/` and `src/auth/` interface files must respect that.
- `dev/state/TECH-DEBT-BACKLOG.md#td-063--dartclaw_testing-depends-on-dartclaw_server` — the entry is not yet deleted; sprint-close hygiene step removes it once this story lands.
- `packages/dartclaw_core/lib/src/storage/task_repository.dart` (and `goal_repository.dart`) — reference pattern for how `dartclaw_core` defines an abstract repository interface that storage-layer concretes implement; mirror the file layout (one type per file, no I/O at the abstract level).
- `packages/dartclaw_config/lib/src/reconfigurable.dart:12` — existing core-side interface (`abstract interface class Reconfigurable`) that `TurnManager` implements today. The new `TurnManager` interface in `dartclaw_core` MUST keep `implements Reconfigurable` semantics intact for the concrete impl — see Constraints & Gotchas.

## Success Criteria (Must Be TRUE)

> Each criterion has a proof path: a Scenario (S-n) or task Verify line (TI-n).

- [ ] `packages/dartclaw_core/lib/src/turn/turn_manager.dart` exists and declares `abstract interface class TurnManager` whose method signatures cover every method invoked on `TurnManager` by any consumer in `packages/dartclaw_server/lib/`, `apps/dartclaw_cli/lib/`, and the existing `FakeTurnManager` consumers. **Proof**: TI02, S-Happy.
- [ ] `packages/dartclaw_core/lib/src/turn/turn_runner.dart` exists and declares `abstract interface class TurnRunner` whose method signatures cover every method invoked on `TurnRunner` by `HarnessPool`, `TurnManager`, `TaskExecutor`, and the existing `_FakeTurnRunner`. **Proof**: TI03.
- [ ] `packages/dartclaw_core/lib/src/harness/harness_pool.dart` exists and declares `abstract interface class HarnessPool` whose method signatures cover every method invoked by `TurnManager`, `TaskExecutor`, `ServerBuilder`, and the existing `_FakeHarnessPool`. **Proof**: TI04.
- [ ] `packages/dartclaw_core/lib/src/auth/google_jwt_verifier.dart` exists and declares `abstract interface class GoogleJwtVerifier` whose surface covers `verify(String? authHeader)` and `invalidateCache()` — every method invoked on `GoogleJwtVerifier` by `google_chat_webhook.dart` and `pubsub_health_integration_test.dart`. **Proof**: TI05.
- [ ] `packages/dartclaw_server/lib/src/turn_manager.dart` (concrete) `implements TurnManager` (alongside existing `Reconfigurable`); `turn_runner.dart` (concrete) `implements TurnRunner`; `harness_pool.dart` (concrete) `implements HarnessPool`; `security/google_jwt_verifier.dart` is renamed/refactored so the existing concrete class is repositioned as `GoogleJwtVerifierImpl` (or equivalent) implementing the new abstract `GoogleJwtVerifier`. **Proof**: TI06.
- [ ] `FakeTurnManager` `implements TurnManager` from `package:dartclaw_core/dartclaw_core.dart` (no `package:dartclaw_server` import); `FakeGoogleJwtVerifier` `implements` (or `extends`) the new core-owned `GoogleJwtVerifier` from `package:dartclaw_core` (no `package:dartclaw_server` import). **Proof**: TI07, S-FakeRebind.
- [ ] `packages/dartclaw_testing/pubspec.yaml` no longer lists `dartclaw_server` under `dependencies:` (it may remain under `dev_dependencies:` only if a *test* in `dartclaw_testing/test/` legitimately needs it; otherwise removed entirely). **Proof**: TI08, S-DepGone.
- [ ] `packages/dartclaw_testing/lib/dartclaw_testing.dart` barrel no longer re-exports `BusyTurnException, GoogleJwtVerifier, HarnessPool, TurnManager, TurnOutcome, TurnRunner, TurnStatus` from `package:dartclaw_server`; instead it re-exports the equivalent symbols from `package:dartclaw_core` (and any value types like `BusyTurnException`/`TurnOutcome`/`TurnStatus` either move with the interfaces or stay in server with consumers re-pointed). **Proof**: TI08.
- [ ] `dev/tools/arch_check.dart`'s `dartclaw_testing` allowed-deps set drops `'dartclaw_server'` and gains `'dartclaw_core'` only (other entries unchanged); `arch_check.dart` passes. **Proof**: TI09.
- [ ] `packages/dartclaw_testing/test/fitness/fitness_smoke_test.dart` exists and asserts that `dartclaw_testing/pubspec.yaml`'s top-level `dependencies:` map contains no key `dartclaw_server`. **Proof**: TI10, S-DepGone.
- [ ] `packages/dartclaw_testing/CLAUDE.md` "Boundaries" section updated — drops `dartclaw_server` from allowed prod deps; the explanatory paragraph that begins "This package's own `dependencies:` block intentionally pulls in `dartclaw_server`…" is rewritten or removed to match the post-S11 state. **Proof**: TI09.
- [ ] `dev/state/TECH-DEBT-BACKLOG.md`'s TD-063 entry is deleted (or marked Resolved with a 0.16.5 date stamp pointing to this FIS), per sprint-close hygiene rules. **Proof**: TI11.
- [ ] `dart analyze --fatal-warnings --fatal-infos` workspace-wide is clean. **Proof**: TI12.
- [ ] `dart test` workspace-wide passes (zero pre-existing test changes other than import-source rewrites where a test happened to import a re-exported symbol from the testing barrel via the old `package:dartclaw_server` path). **Proof**: TI12.

### Health Metrics (Must NOT Regress)
- [ ] All existing `dartclaw_server` turn-lifecycle tests continue to pass without behavioral changes (turn reservation, busy-exception, cancellation, completion, recent-outcome eviction).
- [ ] All existing `google_chat_webhook` JWT-verification tests continue to pass without behavioral changes.
- [ ] No new `pubspec.yaml` entries under `dependencies:` in any package (PRD Constraint #2).
- [ ] `arch_check.dart` continues to pass after its allowed-deps map is updated (no other allowed-deps entries change).

## Scenarios

### S-Happy: Production turn dispatch via the new interface
- **Given** `dartclaw_server`'s `ServerBuilder` constructs a concrete `TurnManager` (the impl class) wired to a concrete `HarnessPool` and `TurnRunner` chain
- **When** an inbound chat request reaches `session_routes.dart` and calls `TurnManager.startTurn(sessionId, messages, …)` through a `TurnManager` reference whose static type is the `dartclaw_core` interface
- **Then** the turn reserves, executes, completes, and returns a `TurnOutcome` with the same status, token counts, and event emissions as before — verified by the existing `session_routes_test.dart` and `restart_service_test.dart` suites passing without behavioral changes.

### S-FakeRebind: FakeTurnManager drives a route handler test
- **Given** a `FakeTurnManager` configured with `addActiveSession('s1', turnId: 't1')` and a recorded `TurnOutcome` for `t1`
- **When** a route handler calls `manager.recentOutcome('s1', 't1')` through a parameter typed as the `dartclaw_core` `TurnManager` interface
- **Then** the fake returns the configured `TurnOutcome` and the handler renders the expected response — verified by re-running `web_routes_test.dart`, `task_routes_test.dart`, `session_routes_test.dart`, `canvas_routes_test.dart`, `task_executor_test.dart` etc. unchanged. The fake's import of `package:dartclaw_server/dartclaw_server.dart` is gone; only `package:dartclaw_core/dartclaw_core.dart` (and `package:dartclaw_models`/`dartclaw_security` if needed) remain.

### S-DepGone: Pubspec edge removed and asserted
- **Given** the workspace at `e670c47` where `packages/dartclaw_testing/pubspec.yaml` still declares `dartclaw_server: path: ../dartclaw_server` under `dependencies:` (lines 27-28)
- **When** S11 lands
- **Then** running `dart test packages/dartclaw_testing/test/fitness/fitness_smoke_test.dart` parses the pubspec and asserts the absence of the `dartclaw_server` key under `dependencies:`; the test passes only because the line has been deleted; `dart pub deps --json` for `dartclaw_testing` shows no transitive `dartclaw_server` resolution.

### S-Edge: Discovery surfaces a concrete-only method on the interface
- **Given** during TI01 discovery a consumer is found that calls a `TurnManager` method *not* present on the abstract surface (e.g. an internal-only governance hook, a logger getter, or a private-by-convention method like `_reservedTurnRunners`)
- **When** the FIS author / executor decides per the **Architecture Decision** rule (derive from observed consumer use)
- **Then** the resolution is one of: (a) widen the interface — add the method if it's a legitimate part of the contract used by an out-of-package consumer; (b) narrow the consumer — refactor the call site to use a public method that *is* on the interface; (c) leave the method on the concrete only and downcast at one composition-root site, recording the downcast in a code comment with a TODO link to a backlog entry. The decision is captured as an Implementation Observation entry in this FIS.

### S-Edge-NoOpVerifier: Health integration test still works
- **Given** `dartclaw_server/test/health/pubsub_health_integration_test.dart` defines `class _AlwaysValidJwtVerifier extends GoogleJwtVerifier` (the concrete) and constructs the server with `jwtVerifier: _AlwaysValidJwtVerifier()`
- **When** S11 introduces an abstract `GoogleJwtVerifier` in `dartclaw_core` and renames the concrete to `GoogleJwtVerifierImpl` (or keeps the name and lifts the abstract above it)
- **Then** the test continues to compile by either (a) `extends GoogleJwtVerifierImpl` against the concrete, or (b) `implements GoogleJwtVerifier` against the abstract — choice recorded in TI05/TI06; test passes without any other change.

## Scope & Boundaries

### In Scope
_Every In Scope item is exercised by at least one scenario or task Verify line._
- Author four abstract interface files in `dartclaw_core` (TI02-TI05).
- Repoint concrete impls in `dartclaw_server` to `implements` the new interfaces (TI06).
- Rebind `FakeTurnManager` and `FakeGoogleJwtVerifier` to the core interfaces; remove their `package:dartclaw_server` imports (TI07).
- Migrate the `dartclaw_testing` barrel to re-export the symbols from `package:dartclaw_core` instead of `package:dartclaw_server` (TI08).
- Remove the `dartclaw_server` entry from `packages/dartclaw_testing/pubspec.yaml` (TI08).
- Update `dev/tools/arch_check.dart` allowed-deps map for `dartclaw_testing` (TI09); update `packages/dartclaw_testing/CLAUDE.md` boundaries (TI09).
- Author `packages/dartclaw_testing/test/fitness/fitness_smoke_test.dart` asserting the dep is gone (TI10).
- Delete TD-063 entry from `dev/state/TECH-DEBT-BACKLOG.md` (TI11).
- Verify `dart analyze` + `dart test` workspace-wide pass (TI12).

### What We're NOT Doing
- **Moving the concrete impls.** Concrete `TurnManager`/`TurnRunner`/`HarnessPool` stay in `dartclaw_server` (server is the only package allowed all-channel + storage + sqlite3 wiring). Moving them would violate the package boundary contract documented in `packages/dartclaw_server/CLAUDE.md`. Only abstract surfaces move.
- **Refactoring consumer code beyond rebinding to the interface.** If a consumer compiles unchanged once the concrete `implements` the new interface, leave it. This story is a surface-extraction, not a consumer-rewrite.
- **Renaming any of the four target types.** `TurnManager`/`TurnRunner`/`HarnessPool`/`GoogleJwtVerifier` keep their names. Concrete-class renaming (e.g. `GoogleJwtVerifier` → `GoogleJwtVerifierImpl`) is acceptable *only* where required to avoid an abstract-vs-concrete name collision; recorded in TI06. Broader naming work belongs to S36.
- **Fixing the existing 2 `dartclaw_storage` violations** (`workflow_service.dart:26`, `workflow_executor.dart:54`). Owned by S12.
- **Authoring `testing_package_deps_test.dart` itself.** That Level-2 fitness function is owned by S25; this story produces only the minimal `fitness_smoke_test.dart` assertion that S25 will later supersede or extend.
- **Lifting value types like `TurnContext`, `TurnOutcome`, `TurnStatus`, `BusyTurnException`, `TurnProgressEvent` to `dartclaw_core` *unless* a method on one of the four interfaces references them.** The minimum-surface principle: if `TurnManager.waitForOutcome` returns `TurnOutcome`, then `TurnOutcome` must be importable from where the abstract lives — so it travels too. Discovery (TI01) enumerates which value types must move; the rest stay in `dartclaw_server`.

### Agent Decision Authority
- **Autonomous**: For each consumer-method call surfaced in TI01, decide whether the method belongs on the abstract surface (production usage outside the concrete's owning package) or stays on the concrete only (internal lifecycle / private bookkeeping). Decide whether to rename `GoogleJwtVerifier` concrete → `GoogleJwtVerifierImpl` or keep the name with `implements`-only refactor. Decide which value types (e.g. `TurnContext`, `TurnOutcome`, `BusyTurnException`) ride along to `dartclaw_core` based on interface signatures.
- **Escalate**: If TI01 surfaces a consumer call that cannot be cleanly resolved by either widen-interface or narrow-consumer (e.g. a workflow plug-in pattern requiring a downcast deep inside core) — record as an Implementation Observation and pause for review before committing to a downcast.

## Architecture Decision

**We will**: Derive each interface from observed consumer use, not from intuition or from the existing class declaration. The discovery step (TI01) enumerates every method invocation on `TurnManager`/`TurnRunner`/`HarnessPool`/`GoogleJwtVerifier` from outside the type's defining file via grep + Dart LSP call-hierarchy, then the abstract surface is the union of those invocations (less internal-lifecycle plumbing).

**Rationale**: Cross-package surface moves carry consumer-incompatibility risk (plan: "High" risk). The interface must satisfy two constituencies — production callers (server routes, `TaskExecutor`, `ServerBuilder`) and test fakes (existing `FakeTurnManager`/`_FakeHarnessPool`/`_FakeTurnRunner`/`FakeGoogleJwtVerifier`). Deriving from observed use captures both, minimises future test breakage, and avoids both the "too-narrow interface, fake works but production doesn't" failure and the "too-wide interface, leaks implementation" failure.

**Alternatives considered**:
1. **Derive from class declaration** — list every public method on the existing concrete and put them all on the abstract. *Rejected*: likely over-exposes internal lifecycle (e.g. `_reservedTurnRunners` getters, governance reconfigure hooks) that no out-of-package consumer calls; locks the contract too wide and cements current implementation choices into a stable-package interface.
2. **Reverse-engineer from existing fakes** — let `FakeTurnManager`'s already-overridden surface define the abstract. *Rejected*: existing fakes use `noSuchMethod` fallback (`fake_turn_manager.dart:362-363`) which means they may already be narrower than real consumers need. A consumer that today calls a concrete method the fake silently no-ops via `noSuchMethod` would compile-error against a fake-derived interface — surfacing real coverage gaps but doing so as an undirected blast radius rather than a guided extraction.

## Technical Overview

### Integration Points

- **`dartclaw_core` ↔ `dartclaw_server`**: today server depends on core; nothing changes. After S11, server's concrete classes `implements` core's abstract interfaces (server gains a stronger compile-time obligation, no new dep).
- **`dartclaw_testing` ↔ `dartclaw_core`**: testing already depends on core; this story relies on that edge for fakes to reach the new abstract types.
- **`dartclaw_testing` ↔ `dartclaw_server`**: this edge is removed under `dependencies:`. If any *test* file in `dartclaw_testing/test/` directly imports `package:dartclaw_server` (audit during TI08), either move it to a `dev_dependency` or remove the dependency on the server entirely.
- **`arch_check.dart`**: data-only update to the allowed-deps map.

### Data Models

No new data models. Existing value types (`TurnContext`, `TurnOutcome`, `TurnStatus`, `BusyTurnException`, `TurnProgressEvent`, `LoopDetection`, etc.) may *move* from `dartclaw_server` to `dartclaw_core` only when they appear on an abstract method signature — in which case the move is mechanical (file relocation + import updates), not a redesign.

## Code Patterns & External References

```
# type | path/url                                                                            | why needed
file   | packages/dartclaw_core/lib/src/storage/task_repository.dart                         | Reference pattern: abstract repo interface in core, no I/O at the abstract level (mirrored by the new abstract interfaces here)
file   | packages/dartclaw_core/lib/src/storage/goal_repository.dart                         | Same pattern, second example
file   | packages/dartclaw_config/lib/src/reconfigurable.dart:12                             | Existing core-owned `abstract interface class` — keeps `TurnManager implements Reconfigurable` semantics intact post-extraction
file   | packages/dartclaw_server/lib/src/turn_manager.dart:138                              | Concrete class today; will gain `implements TurnManager` from core in TI06
file   | packages/dartclaw_server/lib/src/turn_runner.dart:32                                | Concrete `TurnRunner`
file   | packages/dartclaw_server/lib/src/harness_pool.dart:17                               | Concrete `HarnessPool`
file   | packages/dartclaw_server/lib/src/security/google_jwt_verifier.dart:10               | Concrete `GoogleJwtVerifier`; subclassed by `FakeGoogleJwtVerifier` (extends) and `_AlwaysValidJwtVerifier` (extends, in test)
file   | packages/dartclaw_testing/lib/src/fake_turn_manager.dart:75                         | `FakeTurnManager implements TurnManager`; rebind import
file   | packages/dartclaw_testing/lib/src/fake_google_jwt_verifier.dart:8                   | `FakeGoogleJwtVerifier extends GoogleJwtVerifier`; consider switch to `implements` once abstract exists
file   | packages/dartclaw_testing/lib/dartclaw_testing.dart:36-37                           | Barrel re-exports from `package:dartclaw_server` — must repoint to `package:dartclaw_core`
file   | packages/dartclaw_testing/pubspec.yaml:27-28                                        | The line to delete: `dartclaw_server: path: ../dartclaw_server`
file   | dev/tools/arch_check.dart:44-51                                                     | Allowed-deps map for `dartclaw_testing` — drop `dartclaw_server`
file   | packages/dartclaw_testing/CLAUDE.md                                                 | "Boundaries" section requires update to match new state
```

## Constraints & Gotchas

- **Constraint**: The concrete `TurnManager` already `implements Reconfigurable` (from `dartclaw_config`). The new core-side abstract `TurnManager` MUST NOT also `implements Reconfigurable` (mixing the two creates a redundant-implements diagnostic). The concrete keeps both: `class TurnManagerImpl implements TurnManager, Reconfigurable` (or unchanged class name with `implements TurnManager, Reconfigurable`). Workaround: leave `Reconfigurable` purely on the concrete; do not promote it onto the abstract.
- **Constraint**: `FakeTurnManager` currently uses `noSuchMethod` fallback (`fake_turn_manager.dart:362-363`) to silently no-op uncovered methods. Once the interface is abstract, every method on it must be overridden by the fake — `noSuchMethod` works for `dynamic`-typed fallbacks but breaks at compile time for typed abstract methods. Audit during TI07: any abstract method not currently overridden by `FakeTurnManager` either (a) gets an explicit override returning a sensible default, or (b) is judged not part of the public contract and removed from the abstract. The same audit applies to `_FakeHarnessPool` and `_FakeTurnRunner`.
- **Avoid**: Adding methods to the abstract that exist solely for one concrete-class internal use (e.g. private bookkeeping turned package-public). Instead: keep them on the concrete and downcast at the single composition-root site if absolutely required.
- **Critical**: `BusyTurnException` is currently defined alongside `TurnManager` in `turn_manager.dart`. If any abstract method `throws BusyTurnException` (e.g. `reserveTurn`), the exception type rides along to `dartclaw_core` — otherwise it stays in server. Discovery (TI01) determines this.
- **Critical**: The `dartclaw_testing` barrel currently re-exports `BusyTurnException, GoogleJwtVerifier, HarnessPool, TurnManager, TurnOutcome, TurnRunner, TurnStatus` from `package:dartclaw_server`. After S11 those must come from `package:dartclaw_core`. Any test in any package that consumes these via the testing barrel keeps compiling unchanged; tests that imported `package:dartclaw_server` directly are unchanged.
- **Discovery callout (`packages/dartclaw_testing/CLAUDE.md`)**: that file currently states `dartclaw_server` is an allowed prod dep AND that the dep is "intentionally" pulled in. Both statements become false post-S11. The CLAUDE.md edit is part of TI09, not a follow-up.

## Implementation Plan

> **Vertical slice ordering**: TI01 produces the discovery artefact that constrains every later task. TI02-TI05 author the four abstract interfaces in core (independent of each other). TI06 retargets the concretes (depends on TI02-TI05). TI07 retargets the fakes. TI08 cuts the pubspec edge + barrel. TI09-TI11 update governance/docs. TI12 validates.

### Implementation Tasks

- [ ] **TI01** Discovery artefact enumerating, per type (`TurnManager`, `TurnRunner`, `HarnessPool`, `GoogleJwtVerifier`), every method/getter invoked from a file *outside* the type's defining file. Capture as a markdown note appended to this FIS's Implementation Observations section (one table per type). Use `rg` for textual call sites and Dart LSP `find-references` (via the `dart-lsp` plugin) to confirm. Also list every value type referenced by those signatures (`TurnContext`, `TurnOutcome`, `TurnStatus`, `BusyTurnException`, `LoopDetection`, `TurnProgressEvent`, etc.) so TI02-TI06 know which ride along to core.
  - **Verify**: An "S11 — Discovery" section is appended to Implementation Observations with four tables, each listing ≥1 row. The note explicitly resolves the `Reconfigurable` / `BusyTurnException` / value-type ride-along questions raised under Constraints & Gotchas.

- [ ] **TI02** `packages/dartclaw_core/lib/src/turn/turn_manager.dart` declares `abstract interface class TurnManager` with the surface derived in TI01. Any value types riding along (e.g. `TurnContext`, `TurnOutcome`, `TurnStatus`, `BusyTurnException`) move to a sibling file in `lib/src/turn/` (one type per file, mirroring `task_repository.dart` style). The `dartclaw_core` barrel `lib/dartclaw_core.dart` exports the new symbols with explicit `show` clauses.
  - **Verify**: `dart analyze packages/dartclaw_core` is clean. A test file `packages/dartclaw_core/test/turn/turn_manager_surface_test.dart` (or equivalent existing fitness pattern) asserts the abstract has the discovered method names; `grep -E '^  [a-zA-Z]' packages/dartclaw_core/lib/src/turn/turn_manager.dart` matches the TI01 row count ±0.

- [ ] **TI03** `packages/dartclaw_core/lib/src/turn/turn_runner.dart` declares `abstract interface class TurnRunner`. Mirror TI02 process. No `dartclaw_storage` imports may appear in this file (production callers like `TurnRunner` impl import storage, but the abstract MUST NOT).
  - **Verify**: `dart analyze packages/dartclaw_core` clean; `rg 'dartclaw_storage' packages/dartclaw_core/lib/src/turn/turn_runner.dart` returns no matches; the `dartclaw_core` barrel exports `TurnRunner` via `show`.

- [ ] **TI04** `packages/dartclaw_core/lib/src/harness/harness_pool.dart` declares `abstract interface class HarnessPool`. Surface includes (from TI01 expectations) at minimum `primary`, `runners`, `tryAcquire`, `tryAcquireForProfile`, `tryAcquireForProvider`, `tryAcquireForProviderAndProfile`, `release`, `addRunner`, `availableCount`, `activeCount`, `size`, `maxConcurrentTasks`, `spawnableCount`, `taskProfiles`, `taskProviders`, `hasTaskRunnerForProfile`, `hasTaskRunnerForProvider`, `indexOf`, `dispose` — final list reconciled to TI01.
  - **Verify**: `dart analyze packages/dartclaw_core` clean; barrel exports `HarnessPool` via `show`; no agent-harness lifecycle methods leak from the abstract (the abstract returns/accepts only `TurnRunner`, never `AgentHarness` directly — the latter stays a `TurnRunner` implementation detail).

- [ ] **TI05** `packages/dartclaw_core/lib/src/auth/google_jwt_verifier.dart` declares `abstract interface class GoogleJwtVerifier` with surface `Future<bool> verify(String? authHeader)` and `void invalidateCache()`. Static constants on the existing concrete (`googleCertsUrl`, `googleOidcCertsUrl`, `chatServiceAccountCertsUrl`, `expectedIssuer`, `oidcIssuer`) STAY on the concrete in `dartclaw_server` — they're implementation detail, not contract. Resolve any name collision with the concrete by renaming the concrete (e.g. `GoogleJwtVerifierImpl`) IF and only if a downstream consumer needs to refer to the concrete by name; otherwise keep both names identical with the abstract in core and the concrete in server.
  - **Verify**: `dart analyze packages/dartclaw_core` clean; `rg 'googleCertsUrl|googleOidcCertsUrl|expectedIssuer' packages/dartclaw_core/lib/` returns no matches.

- [ ] **TI06** Repoint concrete impls in `dartclaw_server` to `implements` the new core interfaces. `turn_manager.dart` becomes `class TurnManager implements TurnManager, Reconfigurable` if name kept (name collision via the import alias — workaround: `import 'package:dartclaw_core/dartclaw_core.dart' as core; class TurnManager implements core.TurnManager, Reconfigurable {`). Same approach for `turn_runner.dart`, `harness_pool.dart`, and the `GoogleJwtVerifier` concrete in `security/`. Update `host_exports.dart` if any of the moved value types must no longer be re-exported from the server barrel (the rule: if a value type moved to core, the server barrel either drops the export or re-exports from core for source-compat).
  - **Verify**: `dart analyze packages/dartclaw_server` clean; existing turn-lifecycle tests pass (`dart test packages/dartclaw_server/test/`); concrete classes' files import `package:dartclaw_core/dartclaw_core.dart` (or `as core`).

- [ ] **TI07** Rebind `FakeTurnManager` and `FakeGoogleJwtVerifier` to the new core abstracts. `fake_turn_manager.dart`'s `import 'package:dartclaw_server/dartclaw_server.dart';` becomes `import 'package:dartclaw_core/dartclaw_core.dart';` (with possibly additional core imports as needed); `_FakeHarnessPool implements HarnessPool` and `_FakeTurnRunner implements TurnRunner` resolve from core. Audit each abstract method (per TI02-TI04 contract) for fake coverage — add explicit overrides where `noSuchMethod` previously hid the gap. `fake_google_jwt_verifier.dart` switches `extends GoogleJwtVerifier` → `implements GoogleJwtVerifier` (the abstract has no constructor). The `_NoopHttpClient` becomes unnecessary if the abstract contract has no HTTP knobs — delete.
  - **Verify**: `dart analyze packages/dartclaw_testing` clean; both fake source files contain zero matches for `'package:dartclaw_server'`; existing fake tests (`fake_turn_manager_test.dart` if present, plus `public_api_test.dart`) pass.

- [ ] **TI08** Update the testing barrel and pubspec. `packages/dartclaw_testing/lib/dartclaw_testing.dart` line 36-37 (`export 'package:dartclaw_server/dartclaw_server.dart' show BusyTurnException, GoogleJwtVerifier, HarnessPool, TurnManager, TurnOutcome, TurnRunner, TurnStatus;`) is rewritten to `export 'package:dartclaw_core/dartclaw_core.dart' show <same symbols, those that moved>;` and any symbols that did NOT move stay re-exported from server only if that import path is still legitimate — preferred: drop them from the testing barrel and let consumers import from core or server directly. `packages/dartclaw_testing/pubspec.yaml` deletes lines 27-28 (the `dartclaw_server: path: ../dartclaw_server` entry). Audit `packages/dartclaw_testing/test/` for any direct `package:dartclaw_server` import — if any, either move to `dev_dependencies:` (server stays out of `dependencies:` regardless) or rewrite the import to use `dartclaw_core`.
  - **Verify**: `rg "package:dartclaw_server" packages/dartclaw_testing/lib/` returns zero matches; `rg "^  dartclaw_server:" packages/dartclaw_testing/pubspec.yaml` returns zero matches; `dart pub get` in `dartclaw_testing` succeeds; barrel `public_api_test.dart` continues to assert the expected exported symbols.

- [ ] **TI09** Update governance + boundary docs. `dev/tools/arch_check.dart` lines 44-51 (`'dartclaw_testing'` allowed-deps set) drop `'dartclaw_server'` (keep `'dartclaw_core', 'dartclaw_google_chat', 'dartclaw_models', 'dartclaw_security', 'dartclaw_workflow'`). `packages/dartclaw_testing/CLAUDE.md` § "Boundaries": delete `dartclaw_server` from the allowed-prod-deps list; rewrite or delete the paragraph explaining "This package's own `dependencies:` block intentionally pulls in `dartclaw_server`…" so it reflects the post-S11 reality (fakes implement core-owned interfaces; server-only fakes — if any remain — must be `dev_dependency` consumers, not prod deps).
  - **Verify**: `dart run dev/tools/arch_check.dart` exits 0; CLAUDE.md grep `rg "dartclaw_server" packages/dartclaw_testing/CLAUDE.md` returns zero matches in the boundaries paragraph (some matches in unrelated text are acceptable but should be reviewed).

- [ ] **TI10** Add `packages/dartclaw_testing/test/fitness/fitness_smoke_test.dart` asserting `dartclaw_testing/pubspec.yaml`'s top-level `dependencies:` map does NOT contain a `dartclaw_server` key. Use `package:yaml` (already a transitive dep of the workspace) or a literal-string regex check on the pubspec content. Mark the test with a comment that it is a stop-gap until S25's `testing_package_deps_test.dart` Level-2 fitness function lands.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/fitness_smoke_test.dart` passes; the test fails with a clear error if a `dartclaw_server: path: ../dartclaw_server` line is reintroduced under `dependencies:`.

- [ ] **TI11** Backlog hygiene. Delete the TD-063 entry from `dev/state/TECH-DEBT-BACKLOG.md` (or mark it `Resolved: 2026-05-04 (S11, 0.16.5)` per the project's resolution-record convention used elsewhere in that file).
  - **Verify**: `rg "TD-063" dev/state/TECH-DEBT-BACKLOG.md` returns zero matches OR returns only a single Resolved-record line dated 2026-05-04.

- [ ] **TI12** Workspace-wide validation. Run `dart format --set-exit-if-changed packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test`, and `dart run dev/tools/arch_check.dart`. Fix any analyzer/test fallout from the move (expected: zero, but transient import-path corrections possible).
  - **Verify**: All four commands exit 0. The S25 deferred test contract is captured: confirm in this story's Implementation Observations that `testing_package_deps_test.dart` (S25) will read green against the post-S11 state — i.e., the allowed-deps assertion table for `dartclaw_testing` will include `dartclaw_core, dartclaw_google_chat, dartclaw_models, dartclaw_security, dartclaw_workflow` and exclude `dartclaw_server`.

### Testing Strategy

- [TI02-TI05] Scenario S-Happy → existing `dartclaw_server` turn-lifecycle tests pass unchanged once concretes `implements` core abstracts (regression safety net).
- [TI07] Scenario S-FakeRebind → re-run every test that uses `FakeTurnManager`/`FakeGoogleJwtVerifier` (existing call sites: 44 across server + workflow tests); zero test edits expected beyond import rewrites where a test imported a re-exported symbol via the old `package:dartclaw_server` path through the testing barrel.
- [TI08, TI10] Scenario S-DepGone → `fitness_smoke_test.dart` is the proof; running it before TI08 fails, after TI08 passes.
- [TI01] Scenario S-Edge → if a non-resolvable consumer call surfaces during discovery, it gets recorded as Implementation Observation entry and either widens the interface (TI02-TI05) or narrows the consumer (separate small refactor inside this FIS).
- [TI06] Scenario S-Edge-NoOpVerifier → `pubsub_health_integration_test.dart`'s `_AlwaysValidJwtVerifier extends GoogleJwtVerifier` either continues to extend the *concrete* (with a possibly-renamed name) or switches to `implements` the abstract — choice recorded in TI06.

### Validation
- Standard build/test/lint validation handled by exec-spec.
- Feature-specific: confirm `dart pub deps -s list packages/dartclaw_testing` no longer reports `dartclaw_server` in the dependency list.

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (column names, format strings, file paths, error messages) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, architectural advice, build troubleshooting — spawn in background when possible and do not block progress unnecessarily.
- After all tasks: run `dart format --set-exit-if-changed packages apps`, `dart analyze --fatal-warnings --fatal-infos`, `dart test`, `dart run dev/tools/arch_check.dart`. Keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] **All success criteria** met
- [ ] **All tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** or breaking changes introduced (turn lifecycle, JWT verification, fake-driven route tests all green)
- [ ] **`dartclaw_testing → dartclaw_server` pubspec edge gone** and `arch_check.dart` enforces it

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only. Tag semantics: see [`data-contract.md`](${CLAUDE_PLUGIN_ROOT}/references/data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](${CLAUDE_PLUGIN_ROOT}/references/automation-mode.md). Spec authors: leave this section empty._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: Extract abstract interfaces for `TurnManager`, `TurnRunner`, `HarnessPool`, and `GoogleJwtVerifier` from `dartclaw_server` into `dartclaw_core` (`src/turn/`, `src/auth/`). Concrete implementations remain in `dartclaw_server`. `dartclaw_testing` `FakeTurnManager` + `FakeGoogleJwtVerifier` rebind their `implements` clauses to the new interfaces. **Note (2026-05-04 reconciliation)**: `dartclaw_testing/pubspec.yaml`'s `dartclaw_server` dependency was already removed during 0.16.4 release prep — only `dartclaw_core` is listed under `dependencies:`. TD-063 ([linked](../../state/TECH-DEBT-BACKLOG.md#td-063--dartclaw_testing-depends-on-dartclaw_server)) is therefore effectively closed; the entry will be deleted at sprint close as backlog hygiene rather than counting toward 0.16.5 closure. The actual interface-extraction work is unchanged. Verify every consumer's expectations are met by the derived interface surface (grep + Dart LSP call-hierarchy over each type to enumerate method use).

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [ ] Four abstract interfaces live in `dartclaw_core` with matching method signatures (must-be-TRUE)
- [x] `dartclaw_testing/pubspec.yaml` no longer declares `dartclaw_server` — **already met by 0.16.4**; verify still met at sprint close
- [ ] `FakeTurnManager` / `FakeGoogleJwtVerifier` implement the new interfaces (must-be-TRUE)
- [ ] `dart analyze` and `dart test` workspace-wide pass
- [ ] `testing_package_deps_test.dart` fitness function (S25) will validate this invariant; in this story, a minimal assertion in `dartclaw_testing/test/fitness_smoke_test.dart` or similar confirms the dep is gone

### From plan.md — Key Scenarios addendum (migrated from old plan format)

**Key Scenarios**:
- Happy: every consumer of `TurnManager` (production + fakes + tests) still works via the interface
- Edge: a consumer depends on a concrete method not captured by the interface — FIS discovery phase surfaces this and either widens the interface or narrows the consumer
