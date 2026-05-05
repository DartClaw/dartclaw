# S32 — Promote `InlineProcessEnvironmentPlan` + `ProcessEnvironmentPlan.empty` to `dartclaw_security`

**Plan**: ../plan.md
**Story-ID**: S32

## Feature Overview and Goal

Eliminate two confirmed cross-package `ProcessEnvironmentPlan` duplicates by promoting `InlineProcessEnvironmentPlan` to a public class in `dartclaw_security` and adding a canonical empty-plan singleton (`ProcessEnvironmentPlan.empty` or `const EmptyProcessEnvironmentPlan()`). Also promote the duplicated `_buildRemoteOverrideArgs` helper to a top-level function so server-side git callers stop reinventing it. Locks in Shared Decision #12 and is the prerequisite that lets S10's `no_cross_package_env_plan_duplicates_test.dart` allowlist auto-shrink.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S32" entry under per-story File Map; Shared Decision #12; Binding PRD Constraints #2/#19/#21/#71/#72/#75)_

## Required Context

### From `prd.md` — "FR3: Package Boundary Corrections" (S32-applicable)
<!-- source: ../prd.md#fr3-package-boundary-corrections -->
<!-- extracted: e670c47 -->
> **`InlineProcessEnvironmentPlan` + `ProcessEnvironmentPlan.empty` promoted to `dartclaw_security`**; the 2 confirmed cross-package duplicates (`_InlineProcessEnvironmentPlan` in `project_service_impl.dart:48` and `remote_push_service.dart:181`) deleted (the third originally-cited duplicate `_EmptyProcessEnvironmentPlan` in `workflow_executor.dart` is already gone post-0.16.4 S45/S47 + WorkflowGitPort).
>
> `testing_package_deps_test.dart` + `no_cross_package_env_plan_duplicates_test.dart` fitness functions pass.

### From `plan.md` — "S32: Promote `ProcessEnvironmentPlan.empty` + `InlineProcessEnvironmentPlan` to `dartclaw_security`"
<!-- source: ../plan.md#s32-promote-processenvironmentplanempty--inlineprocessenvironmentplan-to-dartclaw_security -->
<!-- extracted: e670c47 -->
> **Scope**: `SafeProcess.git(..., plan: ProcessEnvironmentPlan)` lives in `dartclaw_security`, but every caller that wants an "empty environment" currently has to reach for a sentinel that's stuck in `dartclaw_server` (`GitCredentialPlan` at `packages/dartclaw_server/lib/src/task/git_credential_env.dart:13`) or reinvent it. This has produced **two confirmed duplicates** (verified 2026-04-30): `_InlineProcessEnvironmentPlan` at `project_service_impl.dart:48`; `_InlineProcessEnvironmentPlan` at `remote_push_service.dart:168`. Promote `InlineProcessEnvironmentPlan` as a public class in `dartclaw_security/lib/src/process/inline_process_environment_plan.dart` (or `safe_process.dart`), and add a `ProcessEnvironmentPlan.empty` factory (or a `const EmptyProcessEnvironmentPlan()` singleton). Promote `buildRemoteOverrideArgs` to a top-level function. Delete the two duplicates; retarget call sites at the new public API. Credential *resolution* (`resolveGitCredentialPlan` + `CredentialsConfig` + askpass scripting) legitimately stays in `dartclaw_server` — this story moves only the adapter/sentinel, not the credential logic.
>
> **Acceptance Criteria**:
> - `InlineProcessEnvironmentPlan` exists as public class in `dartclaw_security`
> - `ProcessEnvironmentPlan.empty` (or equivalent singleton) exists in `dartclaw_security`
> - Zero `_InlineProcessEnvironmentPlan` private declarations remain outside `dartclaw_security` — both confirmed duplicates at `project_service_impl.dart:48` and `remote_push_service.dart:168` deleted
> - `buildRemoteOverrideArgs` exists as top-level function in a neutral library; `project_service_impl.dart` + `remote_push_service.dart` both import it
> - S10's `no_cross_package_env_plan_duplicates_test.dart` fitness test passes
> - `dart analyze` and `dart test` workspace-wide pass

### From `.technical-research.md` — "Shared Architectural Decision #12"
<!-- source: ../.technical-research.md#cross-cutting-non-arrow-shared-decisions -->
<!-- extracted: e670c47 -->
> **12. Process Environment Plan canonical types** — `InlineProcessEnvironmentPlan` (public class) and `ProcessEnvironmentPlan.empty` (factory or `const EmptyProcessEnvironmentPlan()` singleton) live in `dartclaw_security/lib/src/process/inline_process_environment_plan.dart` (or `safe_process.dart`) post-S32. `buildRemoteOverrideArgs` becomes top-level. Stories must not reinvent — `no_cross_package_env_plan_duplicates_test.dart` (S10) catches regressions; allowlist exempts only `GitCredentialPlan` in `dartclaw_server` (genuine credential-carrying impl).

### From `.technical-research.md` — "Binding PRD Constraints" (S32-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #2 (Constraint): "No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`." — Applies to all stories; S32 adds zero deps.
> #19 (FR3): "`InlineProcessEnvironmentPlan` + `ProcessEnvironmentPlan.empty` promoted to `dartclaw_security`; the 2 confirmed cross-package duplicates deleted." — Applies to S32.
> #21 (FR3): "`testing_package_deps_test.dart` + `no_cross_package_env_plan_duplicates_test.dart` fitness functions pass." — Applies to S10, S25, S32. (S10 ships the test; S32 makes the allowlist auto-shrink in the same PR.)
> #71 (NFR Reliability): "Behavioural regressions post-decomposition: Zero — every existing test remains green." — Applies to S32.
> #72 (NFR Security): "No regression in guard chain, credential proxy, audit logging — all existing security tests pass." — Applies to S32.
> #75 (FR8): refers to `SidebarDataBuilder` extraction (S24) — flagged in the story brief but does not bind S32; recorded here for traceability without inlining.

### From S10's FIS — `no_cross_package_env_plan_duplicates_test.dart` baseline allowlist
<!-- source: s10-level-1-governance-checks.md#testing-strategy -->
<!-- extracted: e670c47 -->
> Baseline allowlist `allowlist/no_cross_package_env_plan_duplicates.txt` has three entries:
> - `_InlineProcessEnvironmentPlan@packages/dartclaw_server/lib/src/project/project_service_impl.dart  # S32 promotion: delete in same PR`
> - `_InlineProcessEnvironmentPlan@packages/dartclaw_server/lib/src/task/remote_push_service.dart  # S32 promotion: delete in same PR`
> - `GitCredentialPlan@packages/dartclaw_server/lib/src/task/git_credential_env.dart  # credential-carrying impl, exempt — see Shared Decision #12`
>
> S32 deletes the first two duplicates and the corresponding allowlist lines in the same PR; the `GitCredentialPlan` exception remains.

## Deeper Context

- `packages/dartclaw_security/CLAUDE.md` § "Boundaries" — leaf package; allowed deps are `dartclaw_models`, `logging`, `path` only. The new public file ships under `lib/src/process/` (new subdirectory) with no extra deps. Reinforces that any helper relocated here cannot pull in `dartclaw_config` (which `git_credential_env.dart` imports for `CredentialsConfig`); credential resolution stays in server. -- read before deciding the home of `buildRemoteOverrideArgs`.
- `packages/dartclaw_server/CLAUDE.md` § "Workflow glue" — `MergeExecutor` / `RemotePushService` / `PrCreator` (git ops) live under `lib/src/task/` and are injected into `WorkflowGitPort`. Reinforces that the duplicate sentinel sites are server-internal git helpers, not workflow-package concerns.
- `dev/state/UBIQUITOUS_LANGUAGE.md` — canonical term `ProcessEnvironmentPlan` (no rename). S36 explicitly does not touch this type.
- `packages/dartclaw_security/test/safe_process_test.dart:4` — existing test pattern declares a private `_FakePlan implements ProcessEnvironmentPlan` for its own scope; that local fake is **not** a duplicate (test-only, not a production impl) and is not in the S10 fitness scope. Reuse-style reference, not a relocation target.

## Success Criteria (Must Be TRUE)

- [ ] `InlineProcessEnvironmentPlan` exists as a public class in the `dartclaw_security` package — declared either in `packages/dartclaw_security/lib/src/process/inline_process_environment_plan.dart` (preferred) or appended to `safe_process.dart`, and re-exported from `packages/dartclaw_security/lib/dartclaw_security.dart` via `show`-clause
- [ ] A canonical empty `ProcessEnvironmentPlan` is reachable from `dartclaw_security` callers — either via a `ProcessEnvironmentPlan.empty` factory on the existing interface OR a `const EmptyProcessEnvironmentPlan()` public singleton (or both); the chosen surface is exported through the `dartclaw_security` barrel
- [ ] Zero `_InlineProcessEnvironmentPlan` private declarations remain anywhere outside `dartclaw_security`. Specifically, both confirmed duplicates are deleted: `packages/dartclaw_server/lib/src/project/project_service_impl.dart:48` and `packages/dartclaw_server/lib/src/task/remote_push_service.dart:181`
- [ ] `buildRemoteOverrideArgs` exists as a top-level (non-method) function with the same `(String originalRemoteUrl, String resolvedRemoteUrl, List<String> gitArgs) → List<String>` shape as the two existing `_buildRemoteOverrideArgs` private methods, in a neutral library — preferred home `packages/dartclaw_server/lib/src/task/git_credential_env.dart` (next to `resolveGitCredentialPlan`, since both are server-side git-credential glue and `dartclaw_security` may not depend on server types). Both `project_service_impl.dart` and `remote_push_service.dart` import and call it; their two private `_buildRemoteOverrideArgs` methods are deleted
- [ ] S10's `packages/dartclaw_testing/test/fitness/no_cross_package_env_plan_duplicates_test.dart` passes after the same PR shrinks `allowlist/no_cross_package_env_plan_duplicates.txt` (the two `_InlineProcessEnvironmentPlan@…` lines are removed; only the `GitCredentialPlan@…` exemption survives)
- [ ] `dart analyze` workspace-wide: 0 warnings, 0 errors
- [ ] `dart test` workspace-wide: passes (no behavioural regressions; existing `safe_process_test.dart`, `project_service_impl` tests, `remote_push_service` tests, workflow-task tests all green)
- [ ] CHANGELOG `0.16.5 - Unreleased` section gains a single bullet under `### Changed`: notes that `InlineProcessEnvironmentPlan` + the empty-plan canonical surface are now public in `dartclaw_security`. (Wording exact-form not prescribed; mention both promoted symbols and the duplicate-elimination outcome.)

### Health Metrics (Must NOT Regress)

- [ ] `packages/dartclaw_server/test/project/project_service_impl_test.dart` (or equivalent existing test files) remain green — no behavioural change in fetch/push paths
- [ ] `packages/dartclaw_server/test/task/remote_push_service_test.dart` (or equivalent) remain green
- [ ] `packages/dartclaw_security/test/safe_process_test.dart` remains green
- [ ] No new dependency added to any `pubspec.yaml` (Constraint #2)
- [ ] Guard chain, credential proxy, audit logging, askpass scripting behaviour unchanged (Constraint #72) — `git_credential_env.dart` `resolveGitCredentialPlan` + `_buildLegacyAskPassEnv` + `_buildGitHubTokenEnv` are not touched beyond the new top-level helper sitting alongside them
- [ ] `dartclaw_security` barrel export count remains within Shared Decision #20's "others ≤25" cap (the two new public symbols — `InlineProcessEnvironmentPlan` plus the empty-plan surface — fit comfortably; verify post-edit)

## Scenarios

### Server fetch path uses the canonical inline plan
- **Given** `ProjectServiceImpl._isolateGitRunner` (the production `GitRunner`) currently constructs a private `_InlineProcessEnvironmentPlan(envCopy)` at `project_service_impl.dart:41` to pass into `SafeProcess.git`
- **When** S32 lands
- **Then** `_isolateGitRunner` constructs `InlineProcessEnvironmentPlan(envCopy)` (public, imported from `package:dartclaw_security/dartclaw_security.dart`) AND the private class declaration at `project_service_impl.dart:48` is deleted AND `dart analyze packages/dartclaw_server` reports zero issues AND existing project-service tests stay green

### Server push path uses the canonical inline plan
- **Given** `RemotePushService.push` constructs `_InlineProcessEnvironmentPlan(envCopy)` at `remote_push_service.dart:137` and declares the private class at `:181`
- **When** S32 lands
- **Then** the call site uses public `InlineProcessEnvironmentPlan` AND the private declaration at `:181` is deleted AND `RemotePushService` tests pass with no environment/argument behavioural change

### `buildRemoteOverrideArgs` is shared, not duplicated
- **Given** `_buildRemoteOverrideArgs` is implemented identically as a private method in `project_service_impl.dart:658` and `remote_push_service.dart:173`
- **When** S32 lands
- **Then** a single top-level `buildRemoteOverrideArgs(...)` exists (preferred location: `packages/dartclaw_server/lib/src/task/git_credential_env.dart`) AND both files import and call the top-level function AND both private methods are deleted AND `rg "_buildRemoteOverrideArgs" packages/dartclaw_server/lib/` returns zero matches

### Empty-plan callers stop allocating throwaways
- **Given** any server-side caller that needs `SafeProcess.git(..., plan: <empty>)` for a no-credential git invocation today must construct a fresh `_InlineProcessEnvironmentPlan(const <String, String>{})` or `GitCredentialPlan.none()`
- **When** the caller is migrated to use the canonical empty surface
- **Then** the call reads `SafeProcess.git(..., plan: ProcessEnvironmentPlan.empty)` (or `const EmptyProcessEnvironmentPlan()`) AND the same git command is spawned with the same `kDefaultGitEnvAllowlist` sanitisation as before AND the existing test suite remains green

### Edge: `GitCredentialPlan` continues to implement `ProcessEnvironmentPlan` directly
- **Given** `packages/dartclaw_server/lib/src/task/git_credential_env.dart:13` declares `final class GitCredentialPlan implements ProcessEnvironmentPlan` and carries credential fields (`remoteUrl`, askpass-derived `environment`)
- **When** S32 lands
- **Then** `GitCredentialPlan` remains in `dartclaw_server` unchanged AND it stays on the `no_cross_package_env_plan_duplicates_test.dart` allowlist (rationale: "credential-carrying impl, exempt — see Shared Decision #12") AND no attempt is made to fold its credential resolution into `dartclaw_security`

### Edge: S10 fitness allowlist auto-shrinks in the same PR
- **Given** S10 lands with `allowlist/no_cross_package_env_plan_duplicates.txt` containing the two `_InlineProcessEnvironmentPlan@…` shrink-target entries (rationale "S32 promotion: delete in same PR")
- **When** S32 lands
- **Then** the same PR removes those two allowlist lines AND `dart test packages/dartclaw_testing/test/fitness/no_cross_package_env_plan_duplicates_test.dart` passes against the new tree (only `GitCredentialPlan@…` survives the allowlist)

### Negative: no other server file silently reintroduces a private impl
- **Given** the migration moves call sites at `project_service_impl.dart:41` and `remote_push_service.dart:137`
- **When** the post-edit search runs: `rg "implements\s+ProcessEnvironmentPlan" packages/ apps/`
- **Then** only `GitCredentialPlan` (server) and the canonical impl(s) inside `packages/dartclaw_security/` appear AND no production file declares a class named `_InlineProcessEnvironmentPlan` or `_EmptyProcessEnvironmentPlan` anywhere in the workspace

## Scope & Boundaries

### In Scope

- Promote `InlineProcessEnvironmentPlan` to a public class in `dartclaw_security` (location: `lib/src/process/inline_process_environment_plan.dart` preferred; `safe_process.dart` acceptable)
- Add a canonical empty-plan surface: `ProcessEnvironmentPlan.empty` factory on the existing interface, or a `const EmptyProcessEnvironmentPlan()` public singleton, or both
- Update the `dartclaw_security` barrel (`lib/dartclaw_security.dart`) to `show`-export the new public symbols
- Promote `_buildRemoteOverrideArgs` to a top-level `buildRemoteOverrideArgs` function in `packages/dartclaw_server/lib/src/task/git_credential_env.dart` (preferred neutral home — already shared between project + push paths)
- Delete the two `_InlineProcessEnvironmentPlan` private declarations at `project_service_impl.dart:48` and `remote_push_service.dart:181`
- Delete the two `_buildRemoteOverrideArgs` private methods at `project_service_impl.dart:658` and `remote_push_service.dart:173`
- Retarget every existing call site (4 known: `project_service_impl.dart:41`/`:364`/`:623`; `remote_push_service.dart:137`/`:122`/`:130`)
- Shrink S10's `no_cross_package_env_plan_duplicates.txt` allowlist (drop the two pre-S32 shrink-target lines) in the same PR
- Add CHANGELOG `0.16.5 - Unreleased` `### Changed` bullet
- Verify with `dart analyze` + `dart test` workspace-wide and the S10 fitness test

### What We're NOT Doing

- **Moving credential resolution** (`resolveGitCredentialPlan`, `resolveGitCredentialEnv`, `_buildLegacyAskPassEnv`, `_buildGitHubTokenEnv`) into `dartclaw_security` — these are legitimate server-side credential logic that depends on `dartclaw_config` `CredentialsConfig` and writes askpass scripts to `dataDir`; pulling them into the security leaf would violate the leaf invariant and `dartclaw_security`'s no-`dartclaw_config`-dep boundary
- **Refactoring `CredentialsConfig`** or `GitHubRepositoryRef` — out of scope; this story does not touch the credential type surface
- **Touching askpass scripting** (`.git-askpass-*` script generation in `git_credential_env.dart`) — same rationale; not duplicated, not a security primitive
- **Renaming any types** — Shared Decision #12 names them as `InlineProcessEnvironmentPlan` / `EmptyProcessEnvironmentPlan`; S36 (naming batch) explicitly does not touch this type
- **Adding a `dartclaw_security` dep on anything new** — Constraint #2; the new file uses only existing imports
- **Migrating `GitCredentialPlan.none()`** to `EmptyProcessEnvironmentPlan` — `GitCredentialPlan.none()` carries `remoteUrl: ''` (a `GitCredentialPlan` shape, not a generic plan); call sites that already use it stay on it. Only sites that constructed throwaway `_InlineProcessEnvironmentPlan` migrate

## Architecture Decision

**We will**: keep credential *resolution* (`resolveGitCredentialPlan` + `CredentialsConfig` + askpass scripting) in `dartclaw_server`; this story moves only the adapter/sentinel + arg-building helper, not the credential logic. The new `buildRemoteOverrideArgs` lands in `git_credential_env.dart` (server) — not in `dartclaw_security` — because it composes git argv, not env policy, and `dartclaw_security` should not absorb server-side git-CLI conventions. — Avoids pulling `dartclaw_security` into credential-management concerns and preserves the leaf-package invariant in `packages/dartclaw_security/CLAUDE.md` (no dep on `dartclaw_config`).

**Alternatives considered**:
1. **Move `buildRemoteOverrideArgs` into `dartclaw_security`** — rejected: the helper composes git CLI flags (`-c remote.origin.url=…`), not env policy; pollutes the security leaf with transport-layer git argv conventions and offers no reuse outside the two server call sites.
2. **Move `GitCredentialPlan` itself down to `dartclaw_security`** — rejected: depends on `CredentialsConfig` (in `dartclaw_config`) and writes askpass scripts to `dataDir`; would break the leaf-package boundary in `packages/dartclaw_security/CLAUDE.md` and trigger a `dartclaw_security` → `dartclaw_config` cycle. Shared Decision #12 explicitly allowlists `GitCredentialPlan` as a credential-carrying impl that stays in server.
3. **Add `ProcessEnvironmentPlan.empty` only as a static factory, no `EmptyProcessEnvironmentPlan` class** — viable; spec leaves the implementation choice open ("factory OR singleton"). A `const EmptyProcessEnvironmentPlan()` is slightly cleaner because it's a `const` value with no allocation per call, but a `static const empty` field on the interface (or a factory delegating to the const singleton) is equivalent in practice. Implementation chooses based on what reads best.

## Technical Overview

### Data Models

The promoted `InlineProcessEnvironmentPlan` is a thin value adapter implementing `ProcessEnvironmentPlan` (existing interface in `packages/dartclaw_security/lib/src/safe_process.dart:50-52`). Single field: `Map<String, String> environment` (defaults to `const <String, String>{}` when constructed from a nullable map). No state, no logic — just a `const` constructor that can be passed to `SafeProcess.git(..., plan: …)`.

The empty-plan surface is one of (implementation-author's choice, both acceptable):
- `class EmptyProcessEnvironmentPlan implements ProcessEnvironmentPlan { const EmptyProcessEnvironmentPlan(); @override Map<String, String> get environment => const <String, String>{}; }` — exported alongside, used as `const EmptyProcessEnvironmentPlan()`
- A `static const ProcessEnvironmentPlan empty = …` field on the existing `ProcessEnvironmentPlan` interface (Dart abstract interface classes can carry `static` members), backed by the same const singleton

`buildRemoteOverrideArgs` keeps the exact existing private signature: `List<String> buildRemoteOverrideArgs(String originalRemoteUrl, String resolvedRemoteUrl, List<String> gitArgs)`. Behaviour: returns `gitArgs` unchanged when `originalRemoteUrl` is empty/whitespace OR equals `resolvedRemoteUrl`; otherwise prepends `['-c', 'remote.origin.url=$resolvedRemoteUrl', …]`.

### Integration Points

- `SafeProcess.git(..., required ProcessEnvironmentPlan plan, …)` consumes the plan unchanged (`packages/dartclaw_security/lib/src/safe_process.dart:162-180`); no change to its signature.
- `_isolateGitRunner` in `project_service_impl.dart:38-46` constructs the plan inside `Isolate.run`; the public class must be importable across the isolate boundary (it already is — pure Dart class, no `Sendable` constraints needed).
- `GitCredentialPlan` continues to implement `ProcessEnvironmentPlan` and remains the only allowlisted exception in S10's fitness test.

## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_security/lib/src/safe_process.dart:50-52       | Existing `ProcessEnvironmentPlan` abstract interface — extend with `.empty`/singleton; no shape change
file   | packages/dartclaw_security/lib/src/safe_process.dart:162-198     | `SafeProcess.git` / `gitStart` consumers of the plan — unchanged
file   | packages/dartclaw_security/lib/dartclaw_security.dart:18-25      | Existing `safe_process.dart` `show` block — add `InlineProcessEnvironmentPlan` (and `EmptyProcessEnvironmentPlan` if used) here, or add a new `export 'src/process/inline_process_environment_plan.dart' show …`
file   | packages/dartclaw_server/lib/src/task/git_credential_env.dart:13 | `GitCredentialPlan` — genuine credential-carrying impl that stays in server; allowlisted exemption in S10
file   | packages/dartclaw_server/lib/src/task/git_credential_env.dart:24-85 | `resolveGitCredentialPlan` — preferred neighbour location for top-level `buildRemoteOverrideArgs`
file   | packages/dartclaw_server/lib/src/project/project_service_impl.dart:38-54 | First duplicate site: `_isolateGitRunner` + `_InlineProcessEnvironmentPlan` declaration
file   | packages/dartclaw_server/lib/src/project/project_service_impl.dart:364,623,658 | Three call sites of `_buildRemoteOverrideArgs` (lines 364, 623) plus its declaration (658)
file   | packages/dartclaw_server/lib/src/task/remote_push_service.dart:122,130,137,173,181 | Second duplicate site: two `_buildRemoteOverrideArgs` calls (122, 130), one inline-plan call (137), the `_buildRemoteOverrideArgs` method (173), the `_InlineProcessEnvironmentPlan` declaration (181)
file   | packages/dartclaw_security/test/safe_process_test.dart:4         | Existing test pattern: `final class _FakePlan implements ProcessEnvironmentPlan` — test-only, not a duplicate; reference for adding new public-class tests
file   | packages/dartclaw_testing/test/fitness/no_cross_package_env_plan_duplicates_test.dart | (Lands in S10) — the regression guard; allowlist must shrink in the same S32 PR
file   | packages/dartclaw_testing/test/fitness/allowlist/no_cross_package_env_plan_duplicates.txt | (Lands in S10) — drop the two `_InlineProcessEnvironmentPlan@…` shrink-target lines in S32's PR
```

## Constraints & Gotchas

- **Constraint** (Constraint #2 / no new deps): the new file in `dartclaw_security` may import only `dart:core` and existing in-package types. Do **not** import `dartclaw_config` or any server-side type. Workaround: the helper truly is just a `Map<String, String>` adapter; nothing else is needed.
- **Constraint** (`packages/dartclaw_security/CLAUDE.md` boundaries): security is a leaf — no upstream-package imports beyond `dartclaw_models`, `logging`, `path`. The `EmptyProcessEnvironmentPlan` / `InlineProcessEnvironmentPlan` types are pure value classes and respect the leaf rule.
- **Avoid** placing `buildRemoteOverrideArgs` in `dartclaw_security` — it composes git argv, not env policy. Instead, place it in `git_credential_env.dart` next to `resolveGitCredentialPlan`, where both projects + remote-push imports already converge.
- **Avoid** introducing a new `dartclaw_security` subdirectory and forgetting the barrel export — verify with `rg "InlineProcessEnvironmentPlan" packages/dartclaw_security/lib/dartclaw_security.dart` after edit.
- **Critical** (S10 ordering): if S10 has not yet landed when this story executes, `no_cross_package_env_plan_duplicates_test.dart` does not exist yet — verify whichever order they land in by checking the file's existence; either way, after both have landed, the allowlist contains only the `GitCredentialPlan@…` entry. Plan dependency graph (`plan.md:948`) places both in W3 `[P]` — they may merge in either order; the executing agent must check what's on disk before editing the allowlist file.
- **Critical** (`project_service_impl.dart:38` `_isolateGitRunner` runs inside `Isolate.run`): the public `InlineProcessEnvironmentPlan` must be importable + sendable across the isolate boundary. It already is (plain `Map<String, String>` field). No behavioural change expected.
- **Avoid** changing `GitCredentialPlan.none()` semantics — its `remoteUrl: ''` shape is depended on by `_resolveCredentialPlan` callers; do not replace it with `EmptyProcessEnvironmentPlan` even where the empty form is logically equivalent. Out of scope per Architecture Decision rationale #2.

## Implementation Plan

> **Vertical slice ordering**: TI01–TI03 stand up the public API in `dartclaw_security`; TI04–TI06 migrate the two server duplicates one file at a time so each step keeps the workspace green; TI07 promotes the arg-builder helper; TI08 closes the S10 allowlist; TI09 runs the workspace verifications.

### Implementation Tasks

- [ ] **TI01** Public `InlineProcessEnvironmentPlan` is declared in `dartclaw_security` and re-exported from the package barrel
  - Preferred location: new file `packages/dartclaw_security/lib/src/process/inline_process_environment_plan.dart` containing `final class InlineProcessEnvironmentPlan implements ProcessEnvironmentPlan { @override final Map<String, String> environment; const InlineProcessEnvironmentPlan(Map<String, String>? environment) : environment = environment ?? const <String, String>{}; }` — match the existing private impl shape at `project_service_impl.dart:48-54` exactly. Acceptable alternative: append to `safe_process.dart`. Add a `show InlineProcessEnvironmentPlan` clause to `packages/dartclaw_security/lib/dartclaw_security.dart`. Public dartdoc per `packages/dartclaw_security/CLAUDE.md` conventions (rationale-only, contract-focused).
  - **Verify**: `rg "class InlineProcessEnvironmentPlan" packages/dartclaw_security/lib/` returns exactly one match in `lib/src/`; `rg "InlineProcessEnvironmentPlan" packages/dartclaw_security/lib/dartclaw_security.dart` returns exactly one `show`-clause match; `dart analyze packages/dartclaw_security` reports zero issues.

- [ ] **TI02** Canonical empty `ProcessEnvironmentPlan` is reachable from the `dartclaw_security` barrel
  - Choose either: (a) a `const EmptyProcessEnvironmentPlan()` public class in the same file as TI01, OR (b) a `static const ProcessEnvironmentPlan empty = …` field on the existing interface in `safe_process.dart:50` backed by a const singleton, OR both. Whichever surface ships, export it via `show` in `packages/dartclaw_security/lib/dartclaw_security.dart`. Prefer the concrete `const EmptyProcessEnvironmentPlan()` form for callers that want a `const` value with no allocation; if `ProcessEnvironmentPlan.empty` is also added, it must delegate to that singleton (no two empty constants).
  - **Verify**: a fresh test asserts `EmptyProcessEnvironmentPlan().environment` returns an empty map AND (if added) `ProcessEnvironmentPlan.empty == const EmptyProcessEnvironmentPlan()` (or equivalent identity); `dart analyze packages/dartclaw_security` clean.

- [ ] **TI03** Add unit coverage for the promoted types in `packages/dartclaw_security/test/safe_process_test.dart` (or a new `test/inline_process_environment_plan_test.dart` next to it, matching the existing flat-test layout convention from `packages/dartclaw_security/CLAUDE.md`)
  - Cover: (1) `InlineProcessEnvironmentPlan(null).environment` is `const <String, String>{}`; (2) `InlineProcessEnvironmentPlan({'A':'1'}).environment` round-trips; (3) the empty-plan surface returns an empty map; (4) `SafeProcess.sanitize` output when fed the empty plan via `EnvPolicy.credentialPlan(plan: EmptyProcessEnvironmentPlan())` is equivalent to feeding an empty `_InlineProcessEnvironmentPlan` (smoke — exercises the call path in `safe_process.dart:216-220`).
  - **Verify**: `dart test packages/dartclaw_security/test/safe_process_test.dart` (or the new file) green; existing tests in that file unaffected.

- [ ] **TI04** `project_service_impl.dart` migrates to public `InlineProcessEnvironmentPlan` and the private declaration is deleted
  - Edit `packages/dartclaw_server/lib/src/project/project_service_impl.dart`: change `_InlineProcessEnvironmentPlan(envCopy)` at line 41 to `InlineProcessEnvironmentPlan(envCopy)` (public class is already available via the existing `import 'package:dartclaw_security/dartclaw_security.dart'` at line 9 once TI01's `show` clause lands); delete the private `_InlineProcessEnvironmentPlan` class declaration at lines 48-54. Behavioural diff: zero.
  - **Verify**: `rg "_InlineProcessEnvironmentPlan" packages/dartclaw_server/lib/src/project/project_service_impl.dart` returns zero matches; `dart analyze packages/dartclaw_server` clean; existing project-service tests pass.

- [ ] **TI05** `remote_push_service.dart` migrates to public `InlineProcessEnvironmentPlan` and the private declaration is deleted
  - Same migration as TI04 against `packages/dartclaw_server/lib/src/task/remote_push_service.dart`: change `_InlineProcessEnvironmentPlan(envCopy)` at line 137 to `InlineProcessEnvironmentPlan(envCopy)`; delete the private class declaration at lines 181-187. Verify the file already imports `package:dartclaw_security/dartclaw_security.dart` (it does — line check); add the import if absent.
  - **Verify**: `rg "_InlineProcessEnvironmentPlan" packages/dartclaw_server/lib/src/task/remote_push_service.dart` returns zero matches; `rg "_InlineProcessEnvironmentPlan" packages/ apps/` returns zero matches workspace-wide; `dart analyze packages/dartclaw_server` clean.

- [ ] **TI06** Promote `_buildRemoteOverrideArgs` to a top-level `buildRemoteOverrideArgs` in `git_credential_env.dart` and migrate both call-site files
  - In `packages/dartclaw_server/lib/src/task/git_credential_env.dart`, add a top-level public function `List<String> buildRemoteOverrideArgs(String originalRemoteUrl, String resolvedRemoteUrl, List<String> gitArgs)` with the exact body from `project_service_impl.dart:658-663` (identical behaviour: empty/equal-URL short-circuit returns `gitArgs` unchanged; otherwise prepends `['-c', 'remote.origin.url=$resolvedRemoteUrl', …]`). Add brief dartdoc per package conventions. Then delete the private `_buildRemoteOverrideArgs` methods at `project_service_impl.dart:658` and `remote_push_service.dart:173`, and replace each call site (`project_service_impl.dart:364`, `:623`; `remote_push_service.dart:122`, `:130`) with a call to the top-level function (it's reachable via the existing `import '../task/git_credential_env.dart'` in `project_service_impl.dart:14`; `remote_push_service.dart` is in the same directory, so it imports from `'git_credential_env.dart'` if not already).
  - **Verify**: `rg "_buildRemoteOverrideArgs" packages/dartclaw_server/lib/` returns zero matches; `rg "buildRemoteOverrideArgs" packages/dartclaw_server/lib/` returns exactly one definition (in `git_credential_env.dart`) plus the migrated call sites; `dart analyze packages/dartclaw_server` clean; existing server tests pass.

- [ ] **TI07** S10 fitness allowlist auto-shrinks in the same PR
  - If `packages/dartclaw_testing/test/fitness/allowlist/no_cross_package_env_plan_duplicates.txt` exists (i.e. S10 has already merged), delete the two `_InlineProcessEnvironmentPlan@…` shrink-target lines; the only surviving line is `GitCredentialPlan@packages/dartclaw_server/lib/src/task/git_credential_env.dart  # credential-carrying impl, exempt — see Shared Decision #12`. If S10 has not yet merged, this task collapses to a no-op (record in Implementation Observations) and the S10 author authors the file with the post-S32 baseline.
  - **Verify**: `dart test packages/dartclaw_testing/test/fitness/no_cross_package_env_plan_duplicates_test.dart` passes (if S10 landed); `cat packages/dartclaw_testing/test/fitness/allowlist/no_cross_package_env_plan_duplicates.txt` shows exactly one entry (the `GitCredentialPlan` exemption).

- [ ] **TI08** Workspace verification + CHANGELOG entry
  - Run `dart analyze` workspace-wide and `dart test` workspace-wide; both must report 0 errors / 0 warnings and all-pass. Add a single bullet under `### Changed` in the `0.16.5 - Unreleased` section of `CHANGELOG.md` summarising: (a) `InlineProcessEnvironmentPlan` and the empty-plan canonical surface are now public in `dartclaw_security`; (b) two cross-package duplicates removed; (c) `buildRemoteOverrideArgs` promoted to a top-level helper. Wording exact-form not prescribed.
  - **Verify**: `dart analyze` exit 0; `dart test` exit 0; `rg "InlineProcessEnvironmentPlan|EmptyProcessEnvironmentPlan|buildRemoteOverrideArgs" CHANGELOG.md` matches the new bullet.

### Testing Strategy

- [TI03] Scenario: "Empty-plan callers stop allocating throwaways" → `safe_process_test.dart` (or new sibling) asserts the empty-plan surface returns an empty map and produces the same `_resolveEnvironment` output as the legacy throwaway path
- [TI04] Scenario: "Server fetch path uses the canonical inline plan" → existing project-service tests stay green; assertion is the absence of `_InlineProcessEnvironmentPlan` post-edit (`rg` check in TI04 Verify)
- [TI05] Scenario: "Server push path uses the canonical inline plan" → existing remote-push tests stay green; same `rg` check in TI05 Verify
- [TI06] Scenario: "`buildRemoteOverrideArgs` is shared, not duplicated" → behavioural coverage from existing fetch/push tests; structural coverage via the `rg "_buildRemoteOverrideArgs"` zero-match check in TI06 Verify
- [TI07] Scenario: "S10 fitness allowlist auto-shrinks in the same PR" → `dart test packages/dartclaw_testing/test/fitness/no_cross_package_env_plan_duplicates_test.dart` passes
- [TI04,TI05,TI06] Scenario: "Negative: no other server file silently reintroduces a private impl" → workspace-wide `rg "implements\s+ProcessEnvironmentPlan" packages/ apps/` verification at TI06 close-out
- [TI04] Scenario: "Edge: `GitCredentialPlan` continues to implement `ProcessEnvironmentPlan` directly" → S10 fitness test allowlists it; existing `git_credential_env_test.dart` (or equivalent) coverage stays green; no edits to the class

### Validation

- The S10 fitness test (`no_cross_package_env_plan_duplicates_test.dart`) is the canonical regression guard; if S10 has landed, it must be green at TI08. If S10 has not yet landed, run a manual `rg "implements\s+ProcessEnvironmentPlan" packages/ apps/` check and confirm only `dartclaw_security/lib/src/...` and `dartclaw_server/lib/src/task/git_credential_env.dart` (`GitCredentialPlan`) match.

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (file paths, class names, allowlist entries) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, architectural advice, build troubleshooting — spawn in background when possible and do not block progress unnecessarily.
- After all tasks: run `dart analyze` + `dart test` workspace-wide; keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] **All success criteria** met
- [ ] **All tasks** fully completed, verified, and checkboxes checked
- [ ] **No regressions** or breaking changes introduced
- [ ] `rg "_InlineProcessEnvironmentPlan|_EmptyProcessEnvironmentPlan|_buildRemoteOverrideArgs" packages/ apps/` returns zero matches workspace-wide

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only. Tag semantics: see [`data-contract.md`](${CLAUDE_PLUGIN_ROOT}/references/data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](${CLAUDE_PLUGIN_ROOT}/references/automation-mode.md). Spec authors: leave this section empty._

_No observations recorded yet._
