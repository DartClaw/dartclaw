# S36 — Public API Naming Batch (`k`-prefix + `get*` renames)

**Plan**: ../plan.md
**Story-ID**: S36

## Feature Overview and Goal

Mechanical Effective-Dart naming pass across the workspace public API: drop the Hungarian `k`-prefix from 6 public constants in `dartclaw_security` + `dartclaw_workflow`; drop the `get` prefix (or convert to getter) on 10 `get*` methods of public service interfaces. Both parts ship under S22's already-open "Breaking API Changes" CHANGELOG banner so consumers see one coherent migration. Risk is low — analyzer catches every call site. `getOrCreate*` factories intentionally retain their prefix because Effective Dart's rule targets accessor-style `get`, and `getOrCreate` communicates the side effect.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S36 — Public API Naming Batch" entry under Story-Scoped File Map; Shared Decisions #6, #18; Binding PRD Constraints #2, #36, #54, #71)_

## Required Context

### From `plan.md` — "S36: Public API Naming Batch (`k`-prefix + `get*` renames)" (scope + AC)
<!-- source: ../plan.md#s36-public-api-naming-batch-k-prefix--get-renames -->
<!-- extracted: e670c47 -->
> **Scope**: Batch two Effective-Dart naming corrections into one CHANGELOG break, piggy-backing on S22's already-breaking API migration. **Part A — drop `k`-prefix from 6 public constants**: Effective Dart explicitly bans Hungarian/prefix notation. Rename: `kDefaultBashStepEnvAllowlist` → `defaultBashStepEnvAllowlist`; `kDefaultGitEnvAllowlist` → `defaultGitEnvAllowlist`; `kDefaultSensitivePatterns` → `defaultSensitivePatterns` (all in `packages/dartclaw_security/lib/src/safe_process.dart:5,27,41` + re-exports in `dartclaw_security.dart:23-25`); `kWorkflowContextTag/Open/Close` and `kStepOutcomeTag/Open/Close` → `workflowContextTag/Open/Close` and `stepOutcomeTag/Open/Close` (in `packages/dartclaw_workflow/lib/src/workflow/workflow_output_contract.dart:12,15,18,25,28,31`). Update 7 call sites in `apps/dartclaw_cli/lib/src/commands/wiring/{harness,task}_wiring.dart`, `workflow_executor.dart:53,2218`, `security_config.dart:9`, `prompt_augmenter.dart:40-113`. **Part B — drop `get` prefix from 10 public methods**: Rename per Effective Dart guidance. `ProjectService.getDefaultProject` → `defaultProject` (convert to getter if side-effect-free); `ProjectService.getLocalProject` → `localProject` (getter); `SessionService.getOrCreateMain` → `getOrCreateMainSession` (keeping `getOrCreate` prefix is acceptable — it communicates side effect; Effective Dart bans `get` not `getOrCreate`); `ProviderStatusService.getAll` → `all` (getter); `.getSummary` → `summary` (getter); `GowaManager.getLoginQr` → `loginQr` / `.getStatus` → `status`; `PubsubHealthReporter.getStatus` → `status`. Update every call site. **Part C — add CHANGELOG migration note** under a shared "Breaking API Changes" section that also houses S22's model migration, so consumers see one coherent break.
>
> **Acceptance Criteria**:
> - [ ] Zero `k[A-Z]` public identifiers in `dartclaw_security` + `dartclaw_workflow` barrel exports (`rg '^const k[A-Z]|^final k[A-Z]' packages/dartclaw_{security,workflow}` returns empty) (must-be-TRUE)
> - [ ] `get[A-Z]*` methods on public service interfaces renamed or converted to getters per scope list (must-be-TRUE)
> - [ ] Every call site updated; `dart analyze` workspace-wide clean (must-be-TRUE)
> - [ ] `dart test` workspace-wide passes (must-be-TRUE)
> - [ ] CHANGELOG entry ships under the S22 "Breaking API Changes" banner — single user-facing migration note
> - [ ] `getOrCreateMain` intentionally retained with its prefix to communicate "factory with side effect"; decision recorded in the FIS

### From `prd.md` — "FR10: API Polish & Readability (delta-review additions)"
<!-- source: ../prd.md#fr10-api-polish--readability-delta-review-additions -->
<!-- extracted: e670c47 -->
> **Description**: Batch of Effective-Dart and readability improvements surfaced by the 2026-04-21 delta review. Not new features — renames, enums for stringly-typed flags, helper extraction, and small readability wins. Breaking public-API renames batch with FR5 (S22) for one coherent CHANGELOG migration entry.
>
> **Acceptance Criteria** (S36 row):
> - [ ] **S36 — public naming batch**: zero `k`-prefix public identifiers in `dartclaw_security` + `dartclaw_workflow` barrels; `get*` methods on public service interfaces renamed or converted to getters (`getDefaultProject` → getter `defaultProject`, `getLocalProject` → getter `localProject`, etc.); CHANGELOG under S22 banner

### From `.technical-research.md` — Shared Decision #6 (S22 → S36 CHANGELOG batching)
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **6. S22 → S36 — Public-API CHANGELOG break batching** — Single "Breaking API Changes" CHANGELOG section housing both S22 model moves and S36 renames. `getOrCreateMain*` retains `getOrCreate` prefix (factory-with-side-effect). `kDefault*` constants drop `k`. `getDefaultProject`/`getLocalProject` → getters; `ProviderStatusService.getAll`/`.getSummary` → getters; `GowaManager.getLoginQr`/`.getStatus`, `PubsubHealthReporter.getStatus` → renamed. PRODUCER: S22 (opens CHANGELOG section). CONSUMER: S36. WHY: One coherent migration entry per Decisions Log.

### From `.technical-research.md` — Shared Decision #18 (Naming conventions)
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **18. Naming conventions** — Effective Dart: zero `k`-prefix on public consts; zero `get*` accessors (getters preferred); `getOrCreate*` retains prefix. S36 enforces. Verification: `rg '^const k[A-Z]|^final k[A-Z]' packages/dartclaw_{security,workflow}` empty.

### From `.technical-research.md` — Binding PRD Constraints (S36-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #2 (Constraint): "No new dependencies in any package." — Pure rename pass; no pubspec deltas.
> #36 (FR5): "CHANGELOG entry notes the public-API migration." — Shared banner with S22; S36 appends rows, never opens its own banner.
> #54 (FR10): "Public naming batch: zero `k`-prefix public identifiers in `dartclaw_security` + `dartclaw_workflow` barrels; `get*` methods on public service interfaces renamed or converted to getters; CHANGELOG under S22 banner."
> #71 (NFR Reliability): "Behavioural regressions post-decomposition: Zero — every existing test remains green." — Mechanical renames must be call-site-complete; analyzer is the regression net.

### From S22 FIS — CHANGELOG banner contract (Constraint #36 carrier)
<!-- source: ./s22-dartclaw-models-grab-bag-migration.md#implementation-tasks -->
<!-- extracted: e670c47 -->
> **TI13** CHANGELOG updated: `CHANGELOG.md` 0.16.5 section gains a `### Breaking API Changes` subsection (single banner — S36 + S23 R-L2 will append here when they land). Subsection contains an import-path migration table covering every migrated symbol grouping. … Format reference: rows of the form `WorkflowDefinition`, `WorkflowStep`, `WorkflowRun`, `WorkflowExecutionCursor` (and node subtypes, output/git strategies) — moved from `package:dartclaw_models/dartclaw_models.dart` to `package:dartclaw_workflow/dartclaw_workflow.dart`.
>
> _Implication for S36_: append rename rows under the same `### Breaking API Changes` heading; do **not** create a sibling/parallel banner.

## Deeper Context

- `packages/dartclaw_security/lib/src/safe_process.dart:5,27,41` — three Part A const declarations (`kDefaultBashStepEnvAllowlist`, `kDefaultGitEnvAllowlist`, `kDefaultSensitivePatterns`).
- `packages/dartclaw_security/lib/dartclaw_security.dart:23-25` — barrel re-exports the three Part A consts under one `show` clause.
- `packages/dartclaw_security/CLAUDE.md` — "Process safety" + "Conventions" sections name the three constants verbatim; update in the same edit (Boy-Scout / per-package CLAUDE.md mandate).
- `packages/dartclaw_workflow/lib/src/workflow/workflow_output_contract.dart:11-26` — six Part A consts (`kWorkflowContextTag/Open/Close`, `kStepOutcomeTag/Open/Close`) and the regex builders that interpolate them (lines 19, 30).
- `packages/dartclaw_workflow/lib/src/workflow/prompt_augmenter.dart:40-113` — references `kWorkflowContextTag`/`Open`/`Close` and `kStepOutcomeTag`/`Open`/`Close` when augmenting prompts.
- `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart:53,2218` — context-extractor wiring that imports the workflow_output_contract symbols.
- `packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart` — also imports `kDefaultBashStepEnvAllowlist` (rg-confirmed); update import + reference.
- `packages/dartclaw_config/lib/src/security_config.dart:9` — references `kDefaultBashStepEnvAllowlist` / `kDefaultGitEnvAllowlist` / `kDefaultSensitivePatterns` to seed defaults from config; this and the matching test file `packages/dartclaw_config/test/dartclaw_config_test.dart` are part of the Part A worklist.
- `apps/dartclaw_cli/lib/src/commands/wiring/{harness,task}_wiring.dart` — final two Part A call sites.
- `packages/dartclaw_workflow/test/workflow/merge_resolve_plumbing_test.dart` and `test/workflow/component/merge_resolve_e2e_test.dart` — additional rg-confirmed test references to the workflow_output_contract consts; included in the Part A sweep so analyzer stays clean.
- `packages/dartclaw_core/lib/src/project/project_service.dart:98,104` — `abstract class ProjectService` declares `Future<Project> getDefaultProject()` and `Project getLocalProject()`; convert per Part B (`getDefaultProject` is async with no observable side effect → convert to getter `Future<Project> get defaultProject`; `getLocalProject` is pure → convert to getter `Project get localProject`).
- `packages/dartclaw_server/lib/src/project/project_service_impl.dart` and `packages/dartclaw_testing/lib/src/fake_project_service.dart` — the two `ProjectService` implementations; both update method signatures together with the abstract class.
- `packages/dartclaw_core/lib/src/storage/session_service.dart:47` — `Future<Session> getOrCreateMain()`; rename to `getOrCreateMainSession()` (keep `getOrCreate` prefix). Plan note explicitly retains the prefix because the method creates a session if absent (factory-with-side-effect).
- `packages/dartclaw_testing/lib/src/in_memory_session_service.dart:45` — fake mirror of `getOrCreateMain` (now `getOrCreateMainSession`).
- `packages/dartclaw_server/lib/src/provider_status_service.dart:99,103` — `List<ProviderStatus> getAll()` + `Map<String, dynamic> getSummary()`; both pure → convert to getters `all` / `summary`.
- `packages/dartclaw_server/lib/src/api/provider_routes.dart:12,13` — only production call site outside tests for `providerStatus.getAll()` / `.getSummary()`.
- `packages/dartclaw_whatsapp/lib/src/gowa_manager.dart:232,244` — `Future<GowaLoginQr> getLoginQr()` and `Future<GowaStatus> getStatus()`; both perform HTTP calls. Plan instructs rename to `loginQr` / `status` while keeping them as `Future`-returning methods. Note Effective Dart still permits a `Future`-returning method named without the `get` prefix; per plan we do NOT convert to a getter (avoids implying synchronous access). Class-level dartdocs at `:10,13,36` reference the old method names — update.
- `packages/dartclaw_google_chat/lib/src/pubsub_health_reporter.dart:36` — `Map<String, dynamic> getStatus()`; pure → rename to `status` getter (`Map<String, dynamic> get status`).
- `packages/dartclaw_server/lib/src/health/health_service.dart:49,82` — call sites for `pubsubReporter.getStatus()`.
- `CHANGELOG.md` — single `### Breaking API Changes` subsection under 0.16.5, opened by S22. S36 appends rename rows under the same heading; no new banner.
- `dev/specs/0.16.5/.technical-research.md` lines 561-579 — story-scoped file map for S36 (Parts A/B/C primary files, all 7 Part A call sites, all 10 Part B targets).

## Success Criteria (Must Be TRUE)

- [ ] `rg '^const k[A-Z]|^final k[A-Z]' packages/dartclaw_security packages/dartclaw_workflow` returns zero matches across `lib/` (Part A, plan AC line 819) (must-be-TRUE)
- [ ] `dartclaw_security` barrel (`packages/dartclaw_security/lib/dartclaw_security.dart`) exports `defaultBashStepEnvAllowlist`, `defaultGitEnvAllowlist`, `defaultSensitivePatterns` (no `k`-prefixed names remain in `show` clauses) (must-be-TRUE)
- [ ] `packages/dartclaw_workflow/lib/src/workflow/workflow_output_contract.dart` declares `workflowContextTag`/`workflowContextOpen`/`workflowContextClose` and `stepOutcomeTag`/`stepOutcomeOpen`/`stepOutcomeClose`; the embedded `workflowContextRegExp` and `stepOutcomeRegExp` definitions interpolate the renamed consts (must-be-TRUE)
- [ ] `ProjectService.defaultProject` is a `Future<Project>` getter; `ProjectService.localProject` is a `Project` getter; both implementations (`project_service_impl.dart`, `fake_project_service.dart`) match the new signatures (must-be-TRUE)
- [ ] `SessionService.getOrCreateMainSession()` exists; `getOrCreateMain` is removed; both implementations (`session_service.dart`, `in_memory_session_service.dart`) carry the renamed method (must-be-TRUE)
- [ ] `ProviderStatusService.all` is a `List<ProviderStatus>` getter and `.summary` is a `Map<String, dynamic>` getter; `getAll()` / `getSummary()` no longer exist (must-be-TRUE)
- [ ] `GowaManager.loginQr` and `.status` exist (still `Future`-returning methods); `getLoginQr()` and `getStatus()` no longer exist (must-be-TRUE)
- [ ] `PubsubHealthReporter.status` is a `Map<String, dynamic>` getter; `getStatus()` no longer exists (must-be-TRUE)
- [ ] All 7 Part A call sites updated (`apps/dartclaw_cli/.../wiring/{harness,task}_wiring.dart`, `workflow_executor.dart:53,2218`, `security_config.dart:9`, `prompt_augmenter.dart:40-113`) plus `bash_step_runner.dart` import + the two `dartclaw_workflow` test files referenced in Deeper Context — `rg "\bk(Default(Bash|Git|Sensitive)|Workflow(Context|Step)|StepOutcome)" packages apps` returns zero matches (must-be-TRUE)
- [ ] All Part B call sites updated — `rg "\.(getDefaultProject|getLocalProject|getOrCreateMain\b|getAll\(\)|getSummary\(\)|getLoginQr|getStatus)\b" packages apps` returns zero hits against the renamed targets (must-be-TRUE)
- [ ] `dart analyze --fatal-warnings --fatal-infos` workspace-wide exits 0 (Constraint #71; plan AC line 821) (must-be-TRUE)
- [ ] `dart test` workspace-wide green (plan AC line 822) (must-be-TRUE)
- [ ] `CHANGELOG.md` 0.16.5 `### Breaking API Changes` subsection (opened by S22 TI13) contains rename rows for: (a) the 6 `k`-prefixed consts; (b) all 10 method renames; (c) explicit "single migration note — see also S22 model migration above" framing — no separate S36 banner (Constraint #36, Shared Decision #6) (must-be-TRUE)
- [ ] Architecture Decision section of this FIS records the `getOrCreateMain` retention rationale (factory-with-side-effect; Effective Dart targets accessor-style `get` only) — plan AC line 824 (must-be-TRUE)
- [ ] No new pubspec deps added (Constraint #2) (must-be-TRUE)

### Health Metrics (Must NOT Regress)
- [ ] Existing test suite stays green; integration suite (`dart test -t integration`) not regressed
- [ ] JSON wire formats unchanged — renames touch identifiers only, not serialized field names or HTTP/SSE payload shapes (Constraint #1; relevant for `ProviderStatusService.summary` JSON, `PubsubHealthReporter.status` JSON, `GowaStatus` / `GowaLoginQr`)
- [ ] S10 fitness functions remain green (`barrel_show_clauses_test.dart`, `max_file_loc_test.dart`, `package_cycles_test.dart`, …) — pure renames don't shift LOC, dep direction, or barrel export count
- [ ] Per-package CLAUDE.md drift fixed in same edit: `packages/dartclaw_security/CLAUDE.md` references to `kDefaultBashStepEnvAllowlist`/`kDefaultGitEnvAllowlist`/`kDefaultSensitivePatterns` updated to the unprefixed names

## Scenarios

### Consumer reads `localProject` as a getter — old call sites fail loudly
- **Given** `packages/dartclaw_server/lib/src/web/pages/projects_page.dart` previously called `projectService.getLocalProject()`
- **When** S36 lands and `ProjectService.localProject` is a getter
- **Then** the call site reads `projectService.localProject` (no parentheses) AND `dart analyze` exits 0 AND any consumer that retains `getLocalProject()` fails analyzer with `The method 'getLocalProject' isn't defined for the class 'ProjectService'` pointing directly at the rename — every internal call site is updated by this story so the analyzer never reports against `packages/`/`apps/` after TI11

### `getOrCreate*` factory keeps its prefix because Effective Dart targets accessor-style `get`
- **Given** `SessionService.getOrCreateMain()` creates a `Session` row when absent (side-effecting factory)
- **When** S36 renames it
- **Then** the new name is `getOrCreateMainSession()` (still a method, still `Future<Session>`-returning) AND the `getOrCreate` prefix is preserved AND the Architecture Decision section of this FIS records the rationale (Effective Dart bans `get` as accessor-style, not `getOrCreate`) AND `rg "getOrCreateMain\b" packages apps` matches only against `getOrCreateMainSession`

### Async HTTP-calling methods drop the `get` prefix without becoming getters
- **Given** `GowaManager.getLoginQr()` and `.getStatus()` perform HTTP calls and return `Future`
- **When** S36 renames them
- **Then** the new names are `loginQr()` / `status()` — still methods, still `Future`-returning (NOT converted to getters because a getter implies cheap synchronous access AND `Future`-returning getters are an Effective Dart anti-pattern) AND every call site reads `await whatsAppChannel.gowa.status()` / `await whatsAppChannel.gowa.loginQr()` AND `dart analyze` exits 0

### Single CHANGELOG break — no per-rename banner
- **Given** S22 TI13 has already opened a `### Breaking API Changes` subsection under the 0.16.5 `CHANGELOG.md` entry
- **When** S36 lands its rename rows
- **Then** `CHANGELOG.md` contains exactly one `### Breaking API Changes` heading under 0.16.5 (no `### Breaking API Changes (Renames)` or `### S36` sub-banner) AND the subsection contains S22 model-migration rows + S36 rename rows + (when it lands) S23 R-L2 deprecation-removal rows under the same heading AND `rg "^### Breaking API Changes" CHANGELOG.md` matches exactly once per release section

### JSON wire format stays byte-identical for the renamed accessors
- **Given** existing API consumers hit `/api/providers` (driven by `provider_routes.dart:12,13` which currently reads `providerStatus.getAll()` / `.getSummary()`) and `/health` (driven by `health_service.dart:82` which reads `pubsubReporter.getStatus()`)
- **When** S36 renames the accessors to getters
- **Then** the response bodies are byte-identical pre/post (the rename touches the in-process method name only — no JSON keys change, no field types change, no nullability shifts) AND `provider_status_service_test.dart` + `pubsub_health_reporter_test.dart` exercise the same `Map<String, dynamic>` shapes after the rename

### Negative path — analyzer pins every missed call site
- **Given** a developer accidentally leaves one `kWorkflowContextTag` reference in a file outside the rg sweep
- **When** they run `dart analyze --fatal-warnings --fatal-infos`
- **Then** the analyzer fails with `Undefined name 'kWorkflowContextTag'` pointing at the missed line — this proves Constraint #71 (zero behavioural regression) is enforced by the compiler, not a runtime test, and the story cannot land green without every call site fixed

## Scope & Boundaries

### In Scope
- **Part A — `k`-prefix drop on 6 consts** in `packages/dartclaw_security/lib/src/safe_process.dart` and `packages/dartclaw_workflow/lib/src/workflow/workflow_output_contract.dart`; update the two barrel re-exports (`dartclaw_security.dart:23-25`); update all 7 plan-listed call sites plus the rg-confirmed test/import sites in `bash_step_runner.dart`, `merge_resolve_plumbing_test.dart`, `merge_resolve_e2e_test.dart`, `dartclaw_config_test.dart`.
- **Part B — `get*` rename on 10 methods**:
  - `ProjectService.getDefaultProject` → getter `defaultProject` (`Future<Project>`-returning getter)
  - `ProjectService.getLocalProject` → getter `localProject` (`Project`-returning getter)
  - `SessionService.getOrCreateMain` → method `getOrCreateMainSession` (prefix retained, factory-with-side-effect)
  - `ProviderStatusService.getAll` → getter `all`; `.getSummary` → getter `summary`
  - `GowaManager.getLoginQr` → method `loginQr`; `.getStatus` → method `status` (kept as methods because `Future`-returning)
  - `PubsubHealthReporter.getStatus` → getter `status`
  - Update every call site (production + test) until `dart analyze` exits 0.
- **Part C — CHANGELOG entry** appended under S22's already-opened `### Breaking API Changes` subsection: one rename row per Part A const grouping (3 rows: `kDefault*` consts in `safe_process.dart`; `kWorkflowContext*` consts; `kStepOutcome*` consts) + one row per Part B target (10 rows). Single user-facing migration note framing the two parts as one rename pass.
- **Per-package CLAUDE.md updates** — `packages/dartclaw_security/CLAUDE.md` (Process safety + Conventions sections name the three consts; rename in place); any other CLAUDE.md that references the renamed identifiers (rg-driven sweep).

### What We're NOT Doing
- **Renaming any non-listed types or methods** — out-of-list `get*` methods (e.g. on internal helpers, private members, or types not on the plan's Part B list) stay untouched. Reason: the scope is delta-review-driven; expanding it dilutes the CHANGELOG signal.
- **Renaming workflow types** — S22 owns model relocations; S36 must not touch class names, JSON field names, or workflow YAML keys. Reason: S22's diff is the regression-net target; mixing renames into S22's already-large diff weakens reviewability.
- **Renaming enum names or string-typed-flag identifiers** — S35 owns that surface (`WorkflowTaskType`, `WorkflowExternalArtifactMountMode`, `WorkflowGitWorktreeMode`, `IdentifierPreservationMode`). Reason: S35 is also under FR10 but a separate story to keep the rename scope auditable.
- **Changing JSON wire format or field names** — Constraint #1. Reason: external persistence + REST/SSE/JSONL consumers depend on byte stability.
- **Creating a separate CHANGELOG banner** — every S36 row appends under S22's `### Breaking API Changes` heading. Reason: Shared Decision #6 (one coherent migration entry per Decisions Log).
- **Converting `GowaManager.getLoginQr` / `.getStatus` to getters** — kept as `Future`-returning methods named `loginQr` / `status`. Reason: getters imply cheap synchronous access; HTTP-calling accessors are an Effective Dart anti-pattern as getters.
- **Renaming `getOrCreateMain` to drop the `getOrCreate` prefix** — only the trailing `Main` becomes `MainSession` for clarity; `getOrCreate` stays. Reason: factory-with-side-effect signal is what Effective Dart preserves.

### Agent Decision Authority
- **Autonomous**:
  - Per Part A: choose to keep regex names (`workflowContextRegExp`, `stepOutcomeRegExp`) — they were never `k`-prefixed and are out of scope.
  - Per Part B: where a rename causes a member-name conflict in a subclass or fake (e.g. existing `summary` field on a different type in the same file), prefer the renamed accessor and add an `import as` or local rename in the consumer rather than reverting the rename.
  - Decide the exact CHANGELOG row wording, as long as each renamed identifier appears once with the old + new name and the package path.
- **Escalate**:
  - If a Part B rename causes a JSON-shape change (e.g. a `toJson()` builder reflectively reads the Dart field name and the rename leaks into the wire format), stop and document — this would breach Constraint #1 and require either a `@JsonKey` annotation or reverting that specific rename.
  - If `dart analyze` surfaces an analyzer-level issue that cannot be closed without an enum or class rename outside the Part A/B scope list, raise to plan owner rather than expanding scope.

## Architecture Decision

**We will**:
1. Batch Part A (`k`-prefix drop on 6 consts) and Part B (`get*` rename on 10 methods) into S22's already-open `### Breaking API Changes` CHANGELOG subsection so external consumers see one coherent 0.16.5 public-API migration.
2. Convert side-effect-free `get*` methods to **getters** (`ProjectService.defaultProject`/`.localProject`, `ProviderStatusService.all`/`.summary`, `PubsubHealthReporter.status`); keep `Future`-returning HTTP-calling accessors as **methods** with the `get` prefix dropped (`GowaManager.loginQr`/`.status`).
3. Retain the `getOrCreate` prefix on `SessionService.getOrCreateMain` → `getOrCreateMainSession`.

**Rationale**:
- **Single CHANGELOG break** per Shared Decision #6 — splitting model migration (S22) and naming pass (S36) into separate breaking-change banners would force consumers to read two migration sections for what is conceptually one 0.16.5 public-API churn. S22 opens the section in TI13; S36 appends rows under the same heading.
- **`getOrCreate*` retention** — Effective Dart's "AVOID using `get` accessor in method names" rule explicitly targets accessor-style `get` (i.e. functions that simulate a getter). `getOrCreate` communicates a **factory-with-side-effect** semantic (returns existing or creates one), which is precisely what the prefix is signalling — not vestigial Hungarian. Stripping it would lose that signal at every call site. Plan AC line 824 makes this rationale a hard requirement to record in this FIS.
- **Method vs getter shape per call** — `Project`/`List<ProviderStatus>`/`Map<String, dynamic>` accessors on services with no async work and no observable side effect convert to getters (cheap, synchronous, Effective-Dart canonical shape). HTTP-calling accessors stay as methods (cheap-synchronous-access expectation broken by `Future`).

**Alternatives considered**:
1. **Open a separate `### Breaking API Changes (Renames)` banner under 0.16.5** — rejected: violates Shared Decision #6; consumers parse two sections; future stories (S23 R-L2 deprecation removals) would need a third banner, fragmenting the migration story.
2. **Drop `getOrCreate` prefix on `SessionService.getOrCreateMain`** — rejected: loses the factory-with-side-effect signal at the call site; Effective Dart's rule does not target it; renaming to plain `mainSession()` would suggest a pure accessor that is in fact mutating workspace state.
3. **Convert `GowaManager.getLoginQr` / `.getStatus` to getters** — rejected: `Future`-returning getters are an Effective Dart anti-pattern (getters imply cheap synchronous access); HTTP-calling accessors must remain visibly callable.
4. **Defer Part B to a later story** — rejected: S22's CHANGELOG banner is open in 0.16.5; piggy-backing S36 is the cheapest moment. Deferring forces a fresh `### Breaking API Changes` heading in 0.16.6 for what is mechanically trivial today.

No ADR required — packaging-style refactor with the rationale above. The S22+S36 `### Breaking API Changes` subsection is the durable artefact.

## Technical Overview

### Data Models (no shape changes)
Pure identifier renames. Every `toJson()` / `fromJson()` definition in scope (`Project`, `Session`, `ProviderStatus`, `GowaStatus`, `GowaLoginQr`, pubsub status `Map`) keeps its JSON keys byte-identical pre/post. Constraint #1 is enforced by the existing test suites for these types staying green.

### Integration Points
- **`dartclaw_security` barrel** — three `show` clause entries renamed; consumers route through unchanged.
- **`dartclaw_workflow` internal cohesion** — `workflow_output_contract.dart` renames are workflow-internal (not in the workflow barrel; consumed via direct file import). The internal regex builders (`workflowContextRegExp`, `stepOutcomeRegExp`) at lines 19/30 interpolate the renamed consts — verify by reading post-rename and confirming the produced regex strings are byte-identical to pre-rename.
- **Service interfaces** — `ProjectService` (abstract class in `dartclaw_core`), `SessionService` (concrete in `dartclaw_core`), `ProviderStatusService` (concrete in `dartclaw_server`), `GowaManager` (concrete in `dartclaw_whatsapp`), `PubsubHealthReporter` (concrete in `dartclaw_google_chat`). Each rename hits exactly one declaration site + every call site.
- **HTTP/SSE/JSONL wire formats** — unchanged; the renames touch in-process member names only.

## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_security/lib/src/safe_process.dart:5,27,41              | Part A const declarations (3 of 6)
file   | packages/dartclaw_security/lib/dartclaw_security.dart:23-25               | Barrel re-export of Part A consts; rename `show` entries
file   | packages/dartclaw_security/CLAUDE.md                                      | Per-package CLAUDE.md references to kDefault* — rename in same edit
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_output_contract.dart:11-26 | Part A const declarations (6 of 6) + regex builders that interpolate them
file   | packages/dartclaw_workflow/lib/src/workflow/prompt_augmenter.dart:40-113  | Part A call sites for kWorkflow*Tag/Open/Close + kStepOutcome*Tag/Open/Close
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart:53,2218 | Part A call sites
file   | packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart         | rg-confirmed import of kDefaultBashStepEnvAllowlist
file   | packages/dartclaw_config/lib/src/security_config.dart:9                   | Part A call site
file   | packages/dartclaw_config/test/dartclaw_config_test.dart                   | Test reference (rg-confirmed)
file   | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart             | Part A call site
file   | apps/dartclaw_cli/lib/src/commands/wiring/task_wiring.dart                | Part A call site
file   | packages/dartclaw_workflow/test/workflow/merge_resolve_plumbing_test.dart | rg-confirmed test reference
file   | packages/dartclaw_workflow/test/workflow/component/merge_resolve_e2e_test.dart | rg-confirmed test reference
file   | packages/dartclaw_core/lib/src/project/project_service.dart:98,104        | Part B abstract class — convert getDefaultProject/getLocalProject to getters
file   | packages/dartclaw_server/lib/src/project/project_service_impl.dart        | Concrete impl of ProjectService — match new signatures
file   | packages/dartclaw_testing/lib/src/fake_project_service.dart               | Test fake of ProjectService — match new signatures
file   | packages/dartclaw_core/lib/src/storage/session_service.dart:47            | Part B getOrCreateMain → getOrCreateMainSession
file   | packages/dartclaw_testing/lib/src/in_memory_session_service.dart:45       | Test fake of SessionService — match rename
file   | packages/dartclaw_server/lib/src/provider_status_service.dart:99,103      | Part B getAll/getSummary → getters all/summary
file   | packages/dartclaw_server/lib/src/api/provider_routes.dart:12,13           | Production call site for getAll/getSummary
file   | packages/dartclaw_whatsapp/lib/src/gowa_manager.dart:10,13,232,244        | Part B getLoginQr/getStatus → loginQr/status (kept as methods)
file   | packages/dartclaw_whatsapp/lib/src/whatsapp_channel.dart:53               | Production call site for gowa.getStatus()
file   | packages/dartclaw_server/lib/src/web/page_support.dart:35                 | Production call site for gowa.getStatus()
file   | packages/dartclaw_server/lib/src/web/whatsapp_pairing_routes.dart:49,63,95,116 | Production call sites for gowa.getStatus()/getLoginQr()
file   | packages/dartclaw_google_chat/lib/src/pubsub_health_reporter.dart:36      | Part B getStatus → getter status
file   | packages/dartclaw_server/lib/src/health/health_service.dart:49,82         | Production call sites for pubsubReporter.getStatus()
file   | CHANGELOG.md                                                              | Append rename rows under S22's `### Breaking API Changes` subsection (no new banner)
doc    | dev/specs/0.16.5/.technical-research.md#shared-architectural-decisions    | Decisions #6 (S22→S36 banner), #18 (Naming conventions)
doc    | dev/specs/0.16.5/fis/s22-dartclaw-models-grab-bag-migration.md            | TI13 opens the shared CHANGELOG banner
```

## Constraints & Gotchas

- **Constraint**: No new pubspec deps in any package (Constraint #2). — Workaround: pure rename pass; no `pubspec.yaml` edits expected. Verify with `git diff packages apps -- '**/pubspec.yaml'` returns empty.
- **Constraint**: JSON wire formats unchanged (Constraint #1). — Workaround: renames touch in-process member names only. If an automated `toJson()` reflectively reads the Dart field name (e.g. `json_serializable`-style codegen), add a `@JsonKey(name: 'old_name')` to preserve the wire key — but verify by reading the relevant `toJson` impls; in this scope every JSON serializer is hand-written, so the issue should not arise.
- **Constraint**: CHANGELOG must be batched (Shared Decision #6, plan AC line 823). — Workaround: append-only edit under S22's TI13 `### Breaking API Changes` heading. Do NOT add a sibling heading; do NOT add per-rename child headings.
- **Critical**: Plan AC line 824 (`getOrCreateMain` retains prefix; decision recorded in FIS) — recorded in Architecture Decision section of this FIS. Verify by `rg "getOrCreate" packages apps` matching only `getOrCreateMainSession` and not the bare `getOrCreateMain`.
- **Avoid**: Converting `GowaManager.getLoginQr` / `.getStatus` to getters. — Instead: rename to method `loginQr()` / `status()` (HTTP-calling, `Future`-returning). Effective Dart getters imply cheap synchronous access.
- **Gotcha**: `workflow_output_contract.dart:19,30` — the regex builders interpolate the const names directly inside the regex string template (e.g. `RegExp('$kWorkflowContextOpen\\s*([\\s\\S]*?)\\s*$kWorkflowContextClose')`). After renaming the consts, the **template variables** must be renamed in lockstep but the **produced regex string** must stay byte-identical (the actual `<workflow-context>` tag is not changing). Verify by reading the post-rename file: the produced regex must match the same wire-level tag.
- **Gotcha**: `getStatus` / `getAll` / `getSummary` are common names. The rename targets `ProviderStatusService.getAll`, `ProviderStatusService.getSummary`, `PubsubHealthReporter.getStatus`, `GowaManager.getStatus` — but other classes may have unrelated `getAll()` / `getStatus()` methods (e.g. `MemoryStatusService`, `HealthService`). Rg-driven sweeps must be **target-class-scoped** (e.g. `rg "providerStatus\.getAll\b"`, not `rg "\.getAll\b"`) to avoid stomping unrelated members.
- **Gotcha**: `GowaStatus` (return type) and `GowaManager.status` (renamed accessor) share the word "status"; this is fine — the type lives in a different identifier namespace. But the dartdoc comments at `gowa_manager.dart:10,13,36` reference `GowaManager.getStatus`/`.getLoginQr` by name; update those comment references in the same edit.
- **Gotcha**: The S22 FIS's `### Breaking API Changes` row format is `WorkflowDefinition, WorkflowStep, … — moved from package:dartclaw_models to package:dartclaw_workflow`. S36 rows take a different shape — `kDefaultBashStepEnvAllowlist (package:dartclaw_security) → defaultBashStepEnvAllowlist (rename, no path change)`. Use a clear delimiter (em-dash + arrow) so the table reads as one logical migration despite the two row shapes.

## Implementation Plan

> **Vertical slice ordering**: Part A (consts) → Part B (methods) → Part C (CHANGELOG) → workspace verification. Each task is mechanical and analyzer-driven. Land Part A first because it's the smaller diff and lets `dart analyze` confirm the workspace is fully aware of the unprefixed const names before the larger Part B sweep starts. CHANGELOG appends after the renames are green to avoid CHANGELOG-rot if a rename gets reverted.

### Implementation Tasks

- [ ] **TI01** Part A: rename `kDefaultBashStepEnvAllowlist` → `defaultBashStepEnvAllowlist` in `packages/dartclaw_security/lib/src/safe_process.dart:5`. Update the dartdoc comment if it references the old name. The const stays a `const List<String>`.
  - **Verify**: `Test: rg "kDefaultBashStepEnvAllowlist" packages/dartclaw_security/lib returns zero matches AND rg "defaultBashStepEnvAllowlist" packages/dartclaw_security/lib/src/safe_process.dart matches one definition`.

- [ ] **TI02** Part A: rename `kDefaultGitEnvAllowlist` → `defaultGitEnvAllowlist` in `packages/dartclaw_security/lib/src/safe_process.dart:27`. Preserve the existing dartdoc that explains the SSH-agent allowlist rationale.
  - **Verify**: `Test: rg "kDefaultGitEnvAllowlist" packages/dartclaw_security/lib returns zero matches AND rg "defaultGitEnvAllowlist" packages/dartclaw_security/lib/src/safe_process.dart matches one definition`.

- [ ] **TI03** Part A: rename `kDefaultSensitivePatterns` → `defaultSensitivePatterns` in `packages/dartclaw_security/lib/src/safe_process.dart:41`. The declaration stays `final List<Pattern>`.
  - **Verify**: `Test: rg "kDefaultSensitivePatterns" packages/dartclaw_security/lib returns zero matches`.

- [ ] **TI04** Part A: update `packages/dartclaw_security/lib/dartclaw_security.dart:23-25` `show` clause to export the unprefixed names; update `packages/dartclaw_security/CLAUDE.md` Process-safety / Conventions sections to drop `k` from the three identifiers (Boy-Scout per-package mandate).
  - **Verify**: `Test: rg "kDefault" packages/dartclaw_security returns zero matches AND rg "defaultBashStepEnvAllowlist|defaultGitEnvAllowlist|defaultSensitivePatterns" packages/dartclaw_security/lib/dartclaw_security.dart matches the three barrel exports`.

- [ ] **TI05** Part A: rename the 6 consts in `packages/dartclaw_workflow/lib/src/workflow/workflow_output_contract.dart` — `kWorkflowContextTag/Open/Close` → `workflowContextTag/Open/Close` (lines 11-15) and `kStepOutcomeTag/Open/Close` → `stepOutcomeTag/Open/Close` (lines 22-26). The interpolated regex builders at lines 19 and 30 update in lockstep — verify the produced regex strings are byte-identical to pre-rename (the tag wire-spelling is unchanged).
  - **Verify**: `Test: rg "kWorkflowContext|kStepOutcome" packages/dartclaw_workflow/lib returns zero matches AND the produced workflowContextRegExp matches the same '<workflow-context>...</workflow-context>' wire pattern as pre-rename (verify by reading the file post-rename)`.

- [ ] **TI06** Part A: update all call sites — `apps/dartclaw_cli/lib/src/commands/wiring/{harness,task}_wiring.dart`, `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart:53,2218`, `packages/dartclaw_config/lib/src/security_config.dart:9`, `packages/dartclaw_workflow/lib/src/workflow/prompt_augmenter.dart:40-113`, `packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart` (rg-confirmed import), `packages/dartclaw_config/test/dartclaw_config_test.dart` (rg-confirmed test), `packages/dartclaw_workflow/test/workflow/merge_resolve_plumbing_test.dart`, `packages/dartclaw_workflow/test/workflow/component/merge_resolve_e2e_test.dart`. Drive via `dart analyze` until zero unresolved-identifier errors.
  - **Verify**: `Test: rg "\bk(DefaultBashStepEnvAllowlist|DefaultGitEnvAllowlist|DefaultSensitivePatterns|WorkflowContext(Tag|Open|Close)|StepOutcome(Tag|Open|Close))" packages apps returns zero matches AND dart analyze packages/dartclaw_security packages/dartclaw_workflow packages/dartclaw_config apps/dartclaw_cli exits 0`.

- [ ] **TI07** Part B: convert `ProjectService.getDefaultProject` (`packages/dartclaw_core/lib/src/project/project_service.dart:98`) and `ProjectService.getLocalProject` (`:104`) to getters: `Future<Project> get defaultProject` and `Project get localProject`. Update both implementations: `packages/dartclaw_server/lib/src/project/project_service_impl.dart` and `packages/dartclaw_testing/lib/src/fake_project_service.dart`. Update every call site (e.g. `packages/dartclaw_server/lib/src/web/pages/projects_page.dart`, `tasks_page.dart`, `task_executor.dart`, CLI wiring, tests) — drop the `()` so `projectService.localProject` reads as a getter.
  - **Verify**: `Test: rg "\.(getDefaultProject|getLocalProject)\b" packages apps returns zero matches AND rg "Project>? get (defaultProject|localProject)" packages/dartclaw_core/lib/src/project/project_service.dart matches both getter declarations AND dart analyze workspace exits 0`.

- [ ] **TI08** Part B: rename `SessionService.getOrCreateMain` → `getOrCreateMainSession` in `packages/dartclaw_core/lib/src/storage/session_service.dart:47`; mirror in `packages/dartclaw_testing/lib/src/in_memory_session_service.dart:45`. Update every call site in `dartclaw_core` test, `dartclaw_testing` test, `dartclaw_workflow` tests (`step_dispatcher_test.dart`, `context_extractor_test.dart`, all `scenarios/*` tests), `dartclaw_server` tests (`turn_runner*_test.dart`, `project_service_impl_test.dart`, `github_webhook_test.dart`), and CLI wiring (`storage_wiring.dart`, `cli_workflow_wiring.dart`).
  - The `getOrCreate` prefix is intentionally retained (factory-with-side-effect signal — see Architecture Decision).
  - **Verify**: `Test: rg "getOrCreateMain\b" packages apps returns zero matches (only getOrCreateMainSession matches) AND dart analyze workspace exits 0`.

- [ ] **TI09** Part B: convert `ProviderStatusService.getAll` and `.getSummary` to getters `all` and `summary` in `packages/dartclaw_server/lib/src/provider_status_service.dart:99,103`. Update production call site `packages/dartclaw_server/lib/src/api/provider_routes.dart:12,13`; update test file `packages/dartclaw_server/test/provider_status_service_test.dart` (10+ references). Drop the `()` at every call site.
  - **Verify**: `Test: rg "providerStatus\.(getAll|getSummary)\b" packages apps returns zero matches AND rg "List<ProviderStatus> get all|Map<String, dynamic> get summary" packages/dartclaw_server/lib/src/provider_status_service.dart matches both AND the JSON response of /api/providers stays byte-identical (provider_routes_test or equivalent stays green)`.

- [ ] **TI10** Part B: rename `GowaManager.getLoginQr` → `loginQr` and `.getStatus` → `status` in `packages/dartclaw_whatsapp/lib/src/gowa_manager.dart:232,244`. Both stay `Future`-returning **methods** (NOT getters — see Architecture Decision). Update dartdoc references at lines 10, 13, 36, 322, 365 (any `getStatus` / `getLoginQr` mentions in comments). Update production call sites: `packages/dartclaw_whatsapp/lib/src/whatsapp_channel.dart:53`, `packages/dartclaw_server/lib/src/web/page_support.dart:35`, `packages/dartclaw_server/lib/src/web/whatsapp_pairing_routes.dart:49,63,95,116`.
  - **Verify**: `Test: rg "gowa(Manager)?\.(getLoginQr|getStatus)\b" packages apps returns zero matches AND rg "Future<GowaLoginQr> loginQr|Future<GowaStatus> status" packages/dartclaw_whatsapp/lib/src/gowa_manager.dart matches both method declarations`.

- [ ] **TI11** Part B: convert `PubsubHealthReporter.getStatus` to getter `status` in `packages/dartclaw_google_chat/lib/src/pubsub_health_reporter.dart:36`. Update production call sites: `packages/dartclaw_server/lib/src/health/health_service.dart:49,82`. Update `packages/dartclaw_google_chat/test/pubsub_health_reporter_test.dart` (15+ references) and `packages/dartclaw_server/test/health/pubsub_health_integration_test.dart`. The JSON map shape returned by the getter is unchanged.
  - **Verify**: `Test: rg "pubsubReporter\.getStatus\b|reporter\.getStatus\b" packages apps returns zero matches against PubsubHealthReporter (rg may match unrelated GowaManager.getStatus pre-TI10 — TI10 must precede or this verify is post-TI10) AND rg "Map<String, dynamic> get status" packages/dartclaw_google_chat/lib/src/pubsub_health_reporter.dart matches`.

- [ ] **TI12** Workspace-wide analyzer + per-package CLAUDE.md drift sweep: run `dart analyze --fatal-warnings --fatal-infos` and resolve every undefined-identifier error introduced by Parts A+B until zero. `rg` for any other CLAUDE.md files referencing the renamed identifiers and update in place.
  - **Verify**: `Test: dart analyze --fatal-warnings --fatal-infos workspace exits 0 AND rg "kDefaultBashStepEnvAllowlist|kDefaultGitEnvAllowlist|kDefaultSensitivePatterns|kWorkflowContext|kStepOutcome|getDefaultProject|getLocalProject|\bgetOrCreateMain\b|providerStatus\.getAll|providerStatus\.getSummary|gowa(Manager)?\.getLoginQr|gowa(Manager)?\.getStatus|pubsubReporter\.getStatus" packages apps returns zero matches against renamed targets`.

- [ ] **TI13** Part C: append rename rows to `CHANGELOG.md` under S22's already-opened `### Breaking API Changes` subsection (under the 0.16.5 entry). Add a "Public API renames" sub-bullet group containing: 3 rows for the Part A const groupings (`kDefault*` consts in `safe_process.dart`; `kWorkflowContext*` consts; `kStepOutcome*` consts) + 10 rows for the Part B method renames (one per target). Frame as one coherent migration alongside S22's relocations.
  - Do NOT create a new heading. Do NOT split into multiple `### …` sections.
  - **Verify**: `Test: rg "^### Breaking API Changes" CHANGELOG.md matches exactly once under the 0.16.5 section AND the subsection contains rows for kDefault*, kWorkflowContext*, kStepOutcome*, defaultProject getter, localProject getter, getOrCreateMainSession, ProviderStatusService.all, ProviderStatusService.summary, GowaManager.loginQr, GowaManager.status, PubsubHealthReporter.status`.

- [ ] **TI14** Workspace-wide validation: `dart test` workspace green; `dart format --set-exit-if-changed packages apps` exits 0; `bash dev/tools/release_check.sh --quick` exits 0.
  - **Verify**: `Test: dart test workspace + dart format --set-exit-if-changed + release_check.sh --quick all exit 0`.

### Testing Strategy
- [TI01-TI06] Part A scenario "Single CHANGELOG break — no per-rename banner" indirectly verified post-TI13; identifier-level verification via rg sweep + analyzer.
- [TI07] Scenario "Consumer reads `localProject` as a getter" → existing `project_service_impl_test.dart` and `fake_project_service` tests stay green after the getter conversion (no parens at call site).
- [TI08] Scenario "`getOrCreate*` factory keeps its prefix" → existing `session_service_test.dart` exercises `getOrCreateMainSession()`; analyzer-level verification (`rg "getOrCreateMain\b"` empty).
- [TI09] Scenario "JSON wire format stays byte-identical" → `provider_status_service_test.dart` exercises `service.all` / `.summary` post-rename; `provider_routes` HTTP test (or equivalent) confirms response body unchanged.
- [TI10] Scenario "Async HTTP-calling methods drop `get` prefix without becoming getters" → existing whatsapp pairing tests + `whatsapp_channel.dart` integration paths stay green; methods remain `Future`-returning.
- [TI11] Scenario "JSON wire format stays byte-identical" → `pubsub_health_reporter_test.dart` (15+ tests exercising `reporter.status` JSON shape) + `health_service_test.dart` stay green.
- [TI12] Negative-path scenario "Analyzer pins every missed call site" → workspace-wide `dart analyze --fatal-warnings --fatal-infos` exits 0.
- [TI13] Scenario "Single CHANGELOG break" → manual: `rg "^### Breaking API Changes" CHANGELOG.md` matches exactly once per release section.
- [TI14] Workspace `dart test` green; integration suite (`dart test -t integration`) not regressed.

### Validation
> Standard validation (build/test/lint-analysis + 1-pass remediation) is handled by exec-spec.
- Pure rename pass — no extra feature-specific gates beyond the standard set. After TI14, run `bash dev/tools/release_check.sh --quick` once to confirm the release-prep gate stays green.

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- TI06 and TI07-TI11 are sweep tasks — drive via `dart analyze` errors as the worklist. The tree may be uncompilable mid-task; commit only when the task's Verify passes.
- TI13 must NOT create a new `### Breaking API Changes` heading; rows append under S22's existing one. If S22 has not yet landed locally, `git log --grep "S22"` confirms the prerequisite commit chain or stop and resolve dependency order.
- TI10 must precede TI11 to avoid the rg pattern in TI11's verify line catching unrelated `GowaManager.getStatus` references.
- The `getOrCreateMain` retention (TI08) is intentional — do not rename to plain `mainSession()` even if the analyzer would accept it.
- After all tasks: `dart analyze --fatal-warnings --fatal-infos`, `dart test`, `dart format --set-exit-if-changed packages apps`, `bash dev/tools/release_check.sh --quick` — all must exit 0.
- Keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately on completion — do not batch.

## Final Validation Checklist

- [ ] **All success criteria** met (every "Must Be TRUE" line above checked)
- [ ] **All tasks** TI01–TI14 fully completed, verified, checkboxes checked
- [ ] **No regressions** — `dart test` workspace + `dart test -t integration` smoke green; SSE/REST/JSONL response bodies byte-identical for `/api/providers` and `/health` (pubsub block)
- [ ] **Plan-spec alignment** — every plan AC line 819-824 maps to a Success Criterion or task Verify line above; nothing dropped silently
- [ ] **Reverse coverage** — every Success Criterion above appears in plan AC line 819-824 OR is a derived structural assertion required to satisfy a plan AC (e.g. JSON-shape preservation → "no behavioural regression")
- [ ] **`getOrCreateMain` prefix retention** decision recorded in the Architecture Decision section (plan AC line 824)
- [ ] **CHANGELOG batched with S22** under one `### Breaking API Changes` heading (plan AC line 823, Shared Decision #6)
- [ ] **CLAUDE.md drift** — `packages/dartclaw_security/CLAUDE.md` no longer references `kDefault*` identifiers; any other CLAUDE.md hits resolved

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only. Tag semantics: see [`data-contract.md`](${CLAUDE_PLUGIN_ROOT}/references/data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](${CLAUDE_PLUGIN_ROOT}/references/automation-mode.md). Spec authors: leave this section empty._

_No observations recorded yet._
