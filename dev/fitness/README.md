# Level-1 Fitness Functions

Dart test files that run in ≤30 seconds on every commit, catching the architectural drift classes surfaced in 0.16.4.
They live in the `dartclaw_fitness` workspace member at `dev/fitness/`, which declares no production dependencies and
imports none - every gate scans source as text. Run with:

```
bash dev/tools/run-fitness.sh
```

Intentional exceptions are committed as plain-text allowlists under `test/allowlist/<test-name>.txt`. Each non-comment line must follow the format:

```
<pattern>  # <non-empty rationale>
```

The two-space, hash, space separator (`  # `) is mandatory and machine-validated by the tests themselves.

Entries also have to stay live. A gate that consults its allowlist by key records which keys it looked up and fails at
teardown on any entry it never reached — a path that moved or was deleted, a `path:line` whose position shifted, an
edge that no longer exists. Without that, a stale entry stops guarding silently: the exception it granted survives a
rename while the thing it excused is gone. Remove the entry, or re-key it to what the gate now sees. Three allowlists
(`bridge_package_deps.txt`, `testing_package_deps.txt`, `package_cycles.txt`) are mandated empty and their gates decide
on a hard-coded exact set or on the resolved package graph, so those assert emptiness instead.

Gates that read a pubspec block (`dependency_direction`, `testing_package_deps`, `no_app_dependency`,
`fitness_suite_deps`) share one parser in `test/_internal/fitness_test_utils.dart`. It reads the block at whatever
indentation the file uses — YAML fixes no width, and a two-space-only reader hands a gate an empty set for a
four-space pubspec, which reads as compliance — and it **fails** on a block whose entries it cannot parse rather than
returning nothing.

A gate consults a key only once it has found a real violation, so **run a gate file whole**. A name-filtered run
(`dart test -n '<one test>'`) skips the scan that does the consulting and will report every live entry as stale.

---

## `config_key_consumers_test.dart`

**What it enforces**: Every leaf in `schemas/dartclaw.schema.json` has an accessor-shaped identifier in production
code outside config declarations and serialization, or an entry in `allowlist/config_key_consumers.txt` whose
rationale names the real indirect consumer. The allowlist is stale-checked.

**Why**: A published key with no behavioral consumer advertises a feature the runtime no longer implements. The
declaration exclusions keep the field registry, DTO parsing and API serializer from satisfying their own gate while
behavioral files in those packages remain visible.

### How to resolve a failure

**Option A (preferred)**: Restore or identify the production behavior that reads the key.

**Option B (indirect consumption)**: Add `<yaml path>  # <consumer rationale>` to
`test/allowlist/config_key_consumers.txt`, naming the concrete class or function through which the value reaches
behavior. Do not add a placeholder rationale or allowlist a key that has a direct accessor.

The shell-side config-reference checks live in `dev/tools/fitness/`: `test_render_config_reference.sh` exercises
idempotence, invalid core lists and both drift directions; `check_config_reference_drift.sh` runs the renderer's
`--check` mode against the committed guide. Both run from `dev/tools/fitness/run_all.sh`, outside `dart test`.

---

## `barrel_show_clauses_test.dart`

**What it enforces**: Every `export 'src/...'` line in a package barrel file (`packages/<X>/lib/<X>.dart`) must carry an explicit `show` clause.

**Why**: Wholesale barrel exports silently surface every public symbol of the re-exported file, making it impossible to tell at a glance what a package advertises. Explicit `show` clauses act as a machine-checkable API surface: any new unexplained symbol causes a CI failure.

### How to resolve a failure

**Option A (preferred)**: Add a `show SymbolA, SymbolB` clause to the failing export line in the barrel file.

**Option B (intentional exception)**: Add an entry to `test/allowlist/barrel_show_clauses.txt`:
```
packages/dartclaw_foo/lib/dartclaw_foo.dart:42  # <rationale explaining why show is impractical here>
```
The rationale is mandatory and will be reviewed at code-review time.

---

## `max_file_loc_test.dart`

**What it enforces**: Every `.dart` file under `packages/<X>/lib/src/**` must have ≤ 1,500 lines.

**Why**: Files over 1,500 LOC reliably signal insufficient decomposition. The ceiling forces the conversation about splitting at design time rather than after the file has grown organically to 3,000 lines.

### How to resolve a failure

**Option A (preferred)**: Decompose the file into smaller focused modules so each stays under 1,500 lines.

**Option B (intentional exception with shrink target)**: Add an entry to `test/allowlist/max_file_loc.txt`:
```
packages/dartclaw_foo/lib/src/big_module.dart  # 1620 LOC; shrink to ≤1200 by S99 (extract FooStrategy)
```
The current LOC count, target, and a named remediation story or deadline are mandatory.

---

## `max_test_file_loc_test.dart`

**What it enforces**: Every `*_test.dart` file under `packages/`, `apps/` and this suite's own `test/` tree must have <= 1300 lines unless it is explicitly allowlisted.

**Why**: Mega-tests hide duplicated setup and weak assertions. This ceiling prevents new large test files while existing over-limit suites are reduced through table-driving and shared fixtures.

### How to resolve a failure

**Option A (preferred)**: Table-drive repeated cases, extract shared fixtures, split by behavior, or delete weak implementation-detail assertions.

**Option B (baseline exception with shrink target)**: Add an entry to `test/allowlist/max_test_file_loc.txt`:
```
packages/dartclaw_foo/test/big_suite_test.dart  # 1420 LOC; shrink under 1300 via <plan/spec>
```

The current LOC count and shrink target are mandatory.

---

## `no_duplicate_local_fakes_test.dart`

**What it enforces**: A local fake/stub/mock/recording class name may not be redeclared across multiple test files under `packages/`, `apps/` or this suite's own `test/` tree unless allowlisted.

**Why**: Duplicate fakes drift from each other and from the real external boundary. Shared test support keeps setup lean and makes interface changes fail in one place.

### How to resolve a failure

Move the fake to `dartclaw_testing` when it represents a reusable external boundary, or to a package-local `*_test_support.dart` file when the type is package-owned and not barrel-eligible. Temporary baseline duplicates require:
```
_FakeHarness  # migrate to FakeAgentHarness or package-local harness test support
```

---

## `package_cycles_test.dart`

**What it enforces**: The production dependency graph of workspace packages must be a directed acyclic graph (DAG). Zero cycles are permitted; the allowlist `test/allowlist/package_cycles.txt` must remain empty.

**Why**: Cycles cause build instability, break incremental compilation, and signal a failure to maintain clean architectural layers. The tier order in `dev/package_tiers.txt` defines the intended DAG; this test catches deviations at PR time.

### How to resolve a failure

Cycles must be **broken**, not allowlisted. Identify which import is the "wrong direction":

1. Extract a shared interface into a lower-level package (e.g. `dartclaw_core`) and depend on the interface.
2. Remove the dependency entirely if the coupling is incidental.
3. Reference `dev/package_tiers.txt` for the intended dependency DAG — a cycle always means at least one edge points at the wrong tier.

Do **not** add cycle entries to `test/allowlist/package_cycles.txt`.

---

## `constructor_param_count_test.dart`

**What it enforces**: Every public constructor in `packages/<X>/lib/**` and `apps/<X>/lib/**` must have ≤ 12 parameters (named + positional combined).

**Why**: Constructors with more than 12 parameters are a reliable signal of a missing parameter-object or dependency-group struct. They accumulate as a tax on every call site and make testing painful.

### How to resolve a failure

**Option A (preferred)**: Introduce a parameter-object struct to group related parameters (e.g. `_ServerCoreDeps`, `_ServerTurnDeps`) so each constructor stays ≤ 12 arguments.

**Option B (intentional exception)**: Add an entry to `test/allowlist/constructor_param_count.txt`:
```
FooService._internal  # 15 named params; reduces to ≤12 via S99 dep-group struct
```
The format is `<ClassName>.<ctorName>` for named/private ctors or `<ClassName>` for the default constructor. Rationale and a remediation story are mandatory.

---

## `no_cross_package_env_plan_duplicates_test.dart`

**What it enforces**: Any class that `implements ProcessEnvironmentPlan` must live inside `packages/dartclaw_kernel/`. Cross-package duplicates are a regression risk for security-sensitive environment isolation.

**Why (Shared Decision #12)**: `InlineProcessEnvironmentPlan` and `ProcessEnvironmentPlan.empty` are the canonical concrete types. Duplicating them across packages causes behavioural divergence and makes security auditing harder. S32 promoted all non-security impls; this test prevents re-introduction.

### How to resolve a failure

**Option A (preferred)**: Delete the cross-package implementation and use `InlineProcessEnvironmentPlan` from `package:dartclaw_kernel/dartclaw_kernel.dart` instead.

**Option B (genuine credential-carrying implementation)**: Add an entry to `test/allowlist/no_cross_package_env_plan_duplicates.txt`:
```
MyCredentialPlan@packages/dartclaw_foo/lib/src/credential.dart  # carries X credentials; cannot live in dartclaw_kernel because Y
```
The `@` separator distinguishes class name from file path. The rationale must explain why the impl cannot live in `dartclaw_kernel`.

---

## `safe_process_usage_test.dart`

Two gates share this file and its allowlist.

### Gate 1 — no raw git subprocesses

**What it enforces**: Production code under `packages/<X>/lib/` and `apps/<X>/lib/` must not call `Process.run('git', ...)` or `Process.start('git', ...)` directly.

**Why**: Raw git subprocesses bypass `SafeProcess`'s environment isolation (credential stripping, path sanitisation). This test freezes the post-0.16.4 baseline where zero production files invoke git directly, acting as a regression guard.

### Gate 2 — one git-runner seam

**What it enforces**: Production code must reach git through `runGit(...)` from `package:dartclaw_kernel/dartclaw_kernel.dart`, not through `SafeProcess.git` directly. Only the canonical runner (`packages/dartclaw_kernel/lib/src/process/git_runner.dart`) may call it.

**Why**: `GIT_CONFIG_NOSYSTEM` is a security-relevant spawn policy. With one owner the safe posture is the default and every opt-out is enumerable; with one copy per call site the policy drifts invisibly — which is how the task-accept path staged and committed with system hooks in band until 0.24.2.

### How to resolve a failure

Route the call through the seam:
```dart
// Before
await Process.run('git', ['status'], workingDirectory: dir);
await SafeProcess.git(['status'], plan: plan, workingDirectory: dir);

// After
await runGit(['status'], workingDirectory: dir, plan: plan, noSystemConfig: false);
```
`plan` defaults to `const EmptyProcessEnvironmentPlan()` and `noSystemConfig` to `true`; pass `noSystemConfig: false` only for user-visible or remote-transport git, and name the classification at the call site (see `dev/architecture/security-architecture.md` § Git Subprocess Centralization).

Each gate holds its own allowlist — `test/allowlist/safe_process_raw_git.txt` for gate 1,
`test/allowlist/safe_process_git_seam.txt` for gate 2:
```
packages/dartclaw_foo/lib/src/git_wrapper.dart  # canonical SafeProcess equivalent for X; must spawn git directly
```
They were one file until the split, and a rationale written for a raw spawn silenced the seam gate in the same
file — the two gates ask different questions, so a file that genuinely owns both spawns needs an entry in both, each
saying why.

---

# Level-2 Fitness Functions

## `memory_architecture_test.dart`

**What it enforces**: Memory curation remains explicit-only; system actions stay outside timer/retry/delivery/YAML;
locators identify canonical entries or native sources; FTS5 encoding stays inside the backend; and retired public memory
placeholders do not return. Every core or storage memory symbol exported through its package barrel must have a named
production consumer outside its declaration and barrel. The same test scans only current normative documents for retired
operational vocabulary and paths.

### How to resolve a failure

Follow the remediation printed by the failing invariant. Describe curation as the scheduled prompt job it is, keep
natural-language queries at caller boundaries, and use canonical entry IDs or native source locators. These are
zero-baseline rules and have no allowlist. Unexport a corpus implementation detail with no production consumer, or add
the concrete production use that justifies its public contract.

## `dependency_direction_test.dart`

**What it enforces**: Four things, all derived from the declared tier order in `dev/package_tiers.txt`:

1. every workspace member in the root pubspec's `workspace:` list carries a tier, and every name in the tier file is a member;
2. every production `import`/`export` of a DartClaw package points at a **strictly lower** tier — same-tier edges included;
3. every DartClaw dependency a member declares is imported by one of its libraries;
4. every DartClaw package a library imports is declared in that member's pubspec.

**Why**: One declared order replaces the two hand-maintained tables that used to enforce this — `arch_check`'s expected-dependency map and this suite's per-edge allowlist. A per-edge table has to be edited for every legitimate dependency, so it approves whatever the code already does. A tier order states the rule once and derives every edge from it. Checks 3 and 4 close the two ways an edge hides: a dependency nothing imports survives a move unnoticed, and an undeclared import rides in on the workspace resolver.

`dev_dependencies` are out of scope: a test-only edge is not a shipped dependency. That, plus the import scan reading
`lib/` only, is what lets the order forbid a production dependency on `dartclaw_testing`: it shares the top tier with
`dartclaw_fitness`, above everything that ships, so a `dependencies:` entry or a `lib/` import naming either is an
upward edge, while the `dev_dependencies:` entry every consumer uses is not an edge at all.

Three further assertions pin the shipped tier file against ADR-056's three forbidden edges — the adapter on the
runtime's own tier, the client on core's, and an exact set of members above the runtime — so a placement change that
re-legalises one of them fails here instead of passing with the suite green.

### How to resolve a failure

There is **no allowlist**. A wrong-direction or same-tier edge means the shared type is in the wrong place: move it down to a package both sides already depend on, or split a tier in `dev/package_tiers.txt` if the edge really does describe a new layer. An exception entry would recreate the table this gate deleted.

A declared-but-unimported edge is a dead dependency — delete it from the pubspec. An imported-but-undeclared one needs the declaration added, then its direction re-checked. An unassigned member needs a tier.

---

## `no_app_dependency_test.dart`

**What it enforces**: No pubspec under `packages/` names an application package (a workspace member under `apps/`) in `dependencies:` or in `dev_dependencies:`. The app set is read from `apps/*/pubspec.yaml`, never hardcoded, so renaming the app cannot disarm the gate.

**Why**: An application composes libraries; the reverse edge means a library-owned concern is living in an app directory. `dependency_direction_test.dart` cannot see it — it reads `dependencies:` and `lib/` imports only — and `package_cycles_test.dart` resolves the production graph, so a `dev_dependencies:` edge from a test tree was invisible to both. That gap is how the workflow package came to reach into the CLI for its git support.

### How to resolve a failure

**Option A (the fix)**: Move the declaration the library needs into a library package that can own it, then delete the edge.

**Option B (last resort)**: Add `packages/<name>/pubspec.yaml:<block>:<app package>  # <rationale>` to `test/allowlist/no_app_dependency.txt`, where `<block>` is `dependencies` or `dev_dependencies`. The rationale must name why the app is the only possible owner — which is usually an argument for Option A.

---

## `src_import_hygiene_test.dart`

**What it enforces**: Production code must not import another workspace package's `src/` implementation files.

**Why**: Cross-package `src/` imports bypass public API boundaries and make internal refactors breaking changes.

### How to resolve a failure

Use the target package barrel. If the symbol is not public, add a narrow explicit `show` export in the owning package.

---

## `fitness_suite_deps_test.dart`

**What it enforces**: The suite's own pubspec carries an exact set of top-level keys - which admits
`dev_dependencies:` and nothing else that can name a package - with exactly `path` + `test` under it, and no `.dart`
file under `dev/fitness/` imports or exports any `package:dartclaw*` library.

**Why**: The suite is a workspace member, so a production import would resolve. Gates that read production types couple
repo-wide governance to one package's build and re-create the dependency edge that moving the suite out of
`dartclaw_testing` removed.

### How to resolve a failure

There is no allowlist. A check that genuinely needs production types belongs in a `tool/` script in the package that owns
them, registered as a `dart run` step in `dev/tools/fitness/run_all.sh` beside `check_task_executor_workflow_refs.dart`.

---

## `testing_package_deps_test.dart`

**What it enforces**: `dartclaw_testing` production dependencies are exactly `dartclaw_core` and `dartclaw_kernel` - an exact-set pin that fails on a missing entry as well as an unexpected one, narrower than the tier order's rule because this package's doubles may only implement contracts from core and below.

**Why**: The shared-fake package is a leaf every suite consumes, so any edge it carries lands in that suite's dependency closure. Keeping it at core-and-below means a package can take one shared double without acquiring an upper-tier package it does not otherwise use.

### How to resolve a failure

A double whose port is owned above core belongs to the package that owns the port: put it in that package's `lib/src/testing/` and serve it from an opt-in `lib/testing.dart` the package barrel does not re-export — only `lib/` crosses a package boundary, so the port's owner is the one home every consumer already depends on. A helper with one consuming package belongs in that package's test tree. Move test-only needs to `dev_dependencies`. Do not add entries to `test/allowlist/testing_package_deps.txt`; it is expected to stay empty.

---

## `bridge_package_deps_test.dart`

**What it enforces**: `dartclaw_bridge` has no production dependencies, and its development dependencies are exactly
`async`, `test`, and `lints`.

**Why**: `dev/tools/build_bridge.sh` uses `dart compile exe` to cross-compile both Linux targets from one host. A
dependency can bring a native-asset build hook into the bridge graph, causing compilation to refuse or emit an
incomplete artifact. The exact pubspec shape makes ADR-051's hook-free packaging contract structural.

### How to resolve a failure

Remove the dependency. There is no allowlist: move the proposed behavior behind the existing framed protocol so the
host owns it, or use a `dart:` library inside the bridge. `test/allowlist/bridge_package_deps.txt` is committed empty
to make the zero-exception posture explicit.

---

## `enum_exhaustive_consumer_test.dart`

**What it enforces**: Selected `WorkflowRunStatus`, `TaskStatus` and `WorkerState` consumers name every value the enum
declares, and the alert classifier names every concrete `DartclawEvent` subtype. Two registered files — the alert
classifier and the worker-state health projection — additionally carry no `_ =>` arm, and the alert formatter may not
name an event type at all. Both value sets are **derived**, not listed: the enum
values are read from the declaration file the target names, and the event subtypes by transitive closure over
`packages/dartclaw_core/lib/src/events/` (a `sealed`/`abstract` link is an intermediate, anything else reached from
`DartclawEvent` is a leaf). Consumer source is scanned with comments and string literals stripped.

**Why**: Adding an enum value or alertable event type should fail until UI, CLI, SSE, health and alert rendering
surfaces are updated. A gate that carried its own copy of the values stopped noticing the value added next, and a
whole-file substring scan accepted a value named only in a doc comment — a dropped `switch` arm passed on both counts.
A wildcard arm is what lets a new value take a fallback with no compile error, so a file whose exhaustiveness *is* the
guarantee may not carry one. The scan itself is exercised against a planted gap, not only against the passing tree.

**What it still cannot see**: the *consumer* lists are by name. A file removed from a target's `consumers` stops being
checked, and a consumer that is never listed is never checked. Closing that needs a parse of every switch in the tree,
which needs `package:analyzer`; this suite is pinned dependency-free (see `fitness_suite_deps_test.dart`), so the
compiler is the primary guard wherever the switch is over a sealed type or a non-nullable enum, and this gate is the
secondary one for the surfaces where a wildcard arm is legal.

### How to resolve a failure

Update the named consumer to handle the missing value. If a consumer is deliberately value-derived and does not enumerate values, add:
```
packages/dartclaw_foo/lib/src/file.dart:WorkflowRunStatus  # <rationale>
```
The key for the event target is `<file>:DartclawEvent`.

---

## `config_section_tier_coverage_test.dart`

**What it enforces**: Every section field composed on `DartclawConfig` is named exactly once in `ConfigNotifier`'s reload-tier table (a duplicate declaration fails), with a tier of `reloadable` or `restart`, and no table or allowlist entry names a section that no longer exists.

**Why**: The declared tier is what decides whether a config change is delivered to a hot-reload watcher or reported as restart-required. A section left out of the table is silently skipped at reload — the operator is told nothing, and a `reloadable` field registered under it would be reported as applied when nothing applied it.

### How to resolve a failure

**Option A (preferred)**: Add the section to the table in `packages/dartclaw_kernel/lib/src/config_notifier.dart`. Choose `reloadable` only when a registered `Reconfigurable` genuinely applies the change; otherwise `restart`.

**Option B (intentional exception)**: Add an entry to `test/allowlist/config_section_tier_coverage.txt`:
```
extensions  # <rationale explaining why the section cannot be compared at all>
```

---

## `config_load_seam_test.dart`

**What it enforces**: No production file under `packages/<X>/lib/` or `apps/<X>/lib/` calls `DartclawConfig.load(...)`. The only allowed site is the canonical `loadDartclawConfig` seam in `packages/dartclaw_runtime/lib/src/config/config_load.dart`.

**Why**: Channel sections are parsed outside `dartclaw_kernel` — the three channel packages depend on it, so a switch naming their config types there would invert ADR-034 — which means `load()` cannot prime them. A config obtained straight from `load()` carries none of their parse warnings: they vanish from `config.warnings` (so `status`/`serve`/`cleanup`/`rebuild-index` stop printing them) and from `reloadBlockingWarnings` (so an unparseable channel section stops blocking a hot reload). `loadDartclawConfig` loads *and* primes.

### How to resolve a failure

**Option A (preferred)**: Call `loadDartclawConfig(...)` from `package:dartclaw_runtime/dartclaw_runtime.dart` — its parameters are identical to `DartclawConfig.load`'s.

**Option B (intentional exception)**: Add an entry to `test/allowlist/config_load_seam.txt`:
```
packages/dartclaw_foo/lib/src/other_loader.dart  # <rationale explaining why this file is a canonical loader>
```

---

## `structured_output_refusal_test.dart`

**What it enforces**: Every concrete `AgentHarness` implementation in any workspace member's `lib/` — `extends *Harness` or `implements AgentHarness` — calls `AgentHarness.requireStructuredOutputSupport`. A file declaring N harnesses must carry at least N calls.

**Why**: `supportsStructuredOutput` defaults to `false`, which is fail-closed, but the refusal itself is a static helper each `turn()` has to call, because an `implements` adopter inherits no body. A harness that overrides neither accepts an `outputSchema` and drops it silently — a declared output that never reaches the provider and never fails. `packages/dartclaw_core/test/harness/structured_output_contract_test.dart` proves observed behaviour, and discovers harnesses from `package:dartclaw_core/src/harness/` alone, so an adapter package's harness sits outside it. This gate is the workspace-wide half.

### How to resolve a failure

Call `AgentHarness.requireStructuredOutputSupport(this, outputSchema);` as the first statement of the harness's `turn(...)`, before any provider work. The allowlist (`test/allowlist/structured_output_refusal.txt`) is committed empty and has no wanted use: there is no configuration under which dropping a declared schema is the intended behaviour.

---

## `no_second_implementation_test.dart`

**What it enforces**: A public production type name — `class`, `enum`, `mixin`, `typedef`, `extension` or
`extension type` — declared in one workspace member's `lib/` is not declared in another's. Scope is every member with
a `lib/`, **apps included**: scanning `packages/` alone missed a duplicate that had landed in the CLI.

**Why**: Two declarations of one name are two answers with no arbiter, and they drift. This is the
second-implementation defect class in [ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md)
and in `dev/guidelines/DEVELOPMENT-ARCHITECTURE-GUIDELINES.md` § Review Defect Classes.

A `typedef X = other.X;` re-alias is a re-export under the owner's own name, not a second declaration. The scan skips
it by rule, so it needs no allowlist entry and cannot be used to claim a legitimacy it does not need.

### How to resolve a failure

**Option A (preferred)**: rename one of the two, or move the shared type down to the member both already depend on.

**Option B (rare)**: add an entry to `test/allowlist/no_second_implementation.txt`:
```
SharedName  # <why two declarations of this name are legitimate>
```

The allowlist is a ratchet, not a budget. `_recordedExemptionCount` in the gate is the file's **actual** size, and the
gate fails if the file grows past it — lower the constant in the change that resolves a duplicate. It started at ten
cross-package duplicates when the 0.25 milestone opened and stands at two, both of them a port and its adapter sharing
the port's name. The four collisions the file carried as PENDING were closed by production rename, which is the only
way an entry is meant to leave.

**Both current entries are legitimate**: `TurnManager` and `TurnRunner` are a port and its adapter sharing the port's
name, per [ADR-034](../adrs/034-enforced-package-dependency-direction.md). The four the file carried as `PENDING` —
`HarnessConfig`, `ReservedCommandHandler`, `ValidationError` and `WindowsProcessTreeTerminator` — were closed in 0.25 by
the production renames the entries themselves named, which is how a PENDING entry is meant to leave.

---

## `check_no_prose_parsing.sh` (not a Dart fitness test)

**What it enforces**: the prose-parsing, repair-ladder and sentinel constructs the 0.25 milestone deleted stay
deleted. Registered as a `bash` step in `dev/tools/fitness/run_all.sh`, beside its own planted-violation self-test.
Three groups: the retired workflow-output recovery and review-count derivation symbols, the retired `@advisor`
mention and review chat grammars, and the literal `'null'` path sentinel in the two workflow files that carried it.

**Why**: values come from the validated execution envelope and from typed fields, never from model or user prose
(ADR-054). The gate does **not** ask "is this a prose parser?" — that question needs an exemption list larger than the
defect, because code-fence and prefix handling is legitimate in the chunking and Markdown paths. It asks the narrower
question a pattern can answer: has one of the *named* retired constructs come back?

**Why it is not in this suite**: it ships no allowlist, so it needs none of the Dart suite's allowlist machinery, and
it is a plain `rg` scan.

### How to resolve a failure

The construct named in the failure was deleted for a reason — take the value from the schema, the envelope or the
typed field that replaced it. **Do not add an exemption; there is no allowlist file, deliberately.** Every pattern in
the gate was measured at zero before it was added, and a pattern that already matches is a finding against the story
that owned the deletion.

---

## Config schema drift (not a Dart fitness test)

**What it enforces**: `schemas/dartclaw.schema.json` is byte-identical to what `ConfigMeta.toJsonSchema()` emits.
Registered as a `dart run` step in `dev/tools/fitness/run_all.sh`:

```
dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check
```

**Why**: The committed artifact is a third representation of the same field metadata the parser and the write path read.
It may only ever be generated — a hand-edit, or a `ConfigMeta` change left unregenerated, publishes a schema that flags
config an operator's DartClaw loads happily, or accepts config it refuses. `--check` also fails when the artifact is
absent, which is the first-run and bad-merge case.

**Why it is not in this suite**: it reads production types, and `fitness_suite_deps_test.dart` pins the suite
import-free. The `tool/`-script route is the one that pin points at.

### How to resolve a failure

Run the command the failure names:

```
dart run packages/dartclaw_kernel/tool/generate_config_schema.dart
```

and commit the regenerated artifact. There is no allowlist: a schema that disagrees with the registry has no correct
form to be excepted into.
