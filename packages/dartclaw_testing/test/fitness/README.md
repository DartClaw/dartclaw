# Level-1 Fitness Functions

Six Dart test files that run in ≤30 seconds on every commit, catching the architectural drift classes surfaced in 0.16.4. Run with:

```
bash dev/tools/run-fitness.sh
```

Intentional exceptions are committed as plain-text allowlists under `allowlist/<test-name>.txt`. Each non-comment line must follow the format:

```
<pattern>  # <non-empty rationale>
```

The two-space, hash, space separator (`  # `) is mandatory and machine-validated by the tests themselves.

---

## `barrel_show_clauses_test.dart`

**What it enforces**: Every `export 'src/...'` line in a package barrel file (`packages/<X>/lib/<X>.dart`) must carry an explicit `show` clause.

**Why**: Wholesale barrel exports silently surface every public symbol of the re-exported file, making it impossible to tell at a glance what a package advertises. Explicit `show` clauses act as a machine-checkable API surface: any new unexplained symbol causes a CI failure.

### How to resolve a failure

**Option A (preferred)**: Add a `show SymbolA, SymbolB` clause to the failing export line in the barrel file.

**Option B (intentional exception)**: Add an entry to `allowlist/barrel_show_clauses.txt`:
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

**Option B (intentional exception with shrink target)**: Add an entry to `allowlist/max_file_loc.txt`:
```
packages/dartclaw_foo/lib/src/big_module.dart  # 1620 LOC; shrink to ≤1200 by S99 (extract FooStrategy)
```
The current LOC count, target, and a named remediation story or deadline are mandatory.

---

## `max_test_file_loc_test.dart`

**What it enforces**: Every `*_test.dart` file under `packages/` and `apps/` must have <= 800 lines unless it is explicitly allowlisted.

**Why**: Mega-tests hide duplicated setup and weak assertions. This ceiling prevents new large test files while existing over-limit suites are reduced through table-driving and shared fixtures.

### How to resolve a failure

**Option A (preferred)**: Table-drive repeated cases, extract shared fixtures, split by behavior, or delete weak implementation-detail assertions.

**Option B (baseline exception with shrink target)**: Add an entry to `allowlist/max_test_file_loc.txt`:
```
packages/dartclaw_foo/test/big_suite_test.dart  # 920 LOC; shrink under 800 via <plan/spec>
```

The current LOC count and shrink target are mandatory.

---

## `no_duplicate_local_fakes_test.dart`

**What it enforces**: A local fake/stub/mock/recording class name may not be redeclared across multiple test files unless allowlisted.

**Why**: Duplicate fakes drift from each other and from the real external boundary. Shared test support keeps setup lean and makes interface changes fail in one place.

### How to resolve a failure

Move the fake to `dartclaw_testing` when it represents a reusable external boundary, or to a package-local `*_test_support.dart` file when the type is package-owned and not barrel-eligible. Temporary baseline duplicates require:
```
_FakeHarness  # migrate to FakeAgentHarness or package-local harness test support
```

---

## `package_cycles_test.dart`

**What it enforces**: The production dependency graph of workspace packages must be a directed acyclic graph (DAG). Zero cycles are permitted; the allowlist `allowlist/package_cycles.txt` must remain empty.

**Why**: Cycles cause build instability, break incremental compilation, and signal a failure to maintain clean architectural layers. The expected-deps contract in `dev/tools/arch_check.dart` defines the intended DAG; this test catches deviations at PR time.

### How to resolve a failure

Cycles must be **broken**, not allowlisted. Identify which import is the "wrong direction":

1. Extract a shared interface into a lower-level package (e.g. `dartclaw_core`) and depend on the interface.
2. Remove the dependency entirely if the coupling is incidental.
3. Reference `_expectedWorkspaceDependencies` in `dev/tools/arch_check.dart` for the intended dependency DAG.

Do **not** add cycle entries to `allowlist/package_cycles.txt`.

---

## `constructor_param_count_test.dart`

**What it enforces**: Every public constructor in `packages/<X>/lib/**` and `apps/<X>/lib/**` must have ≤ 12 parameters (named + positional combined).

**Why**: Constructors with more than 12 parameters are a reliable signal of a missing parameter-object or dependency-group struct. They accumulate as a tax on every call site and make testing painful.

### How to resolve a failure

**Option A (preferred)**: Introduce a parameter-object struct to group related parameters (e.g. `_ServerCoreDeps`, `_ServerTurnDeps`) so each constructor stays ≤ 12 arguments.

**Option B (intentional exception)**: Add an entry to `allowlist/constructor_param_count.txt`:
```
FooService._internal  # 15 named params; reduces to ≤12 via S99 dep-group struct
```
The format is `<ClassName>.<ctorName>` for named/private ctors or `<ClassName>` for the default constructor. Rationale and a remediation story are mandatory.

---

## `no_cross_package_env_plan_duplicates_test.dart`

**What it enforces**: Any class that `implements ProcessEnvironmentPlan` must live inside `packages/dartclaw_security/`. Cross-package duplicates are a regression risk for security-sensitive environment isolation.

**Why (Shared Decision #12)**: `InlineProcessEnvironmentPlan` and `ProcessEnvironmentPlan.empty` are the canonical concrete types. Duplicating them across packages causes behavioural divergence and makes security auditing harder. S32 promoted all non-security impls; this test prevents re-introduction.

### How to resolve a failure

**Option A (preferred)**: Delete the cross-package implementation and use `InlineProcessEnvironmentPlan` from `package:dartclaw_security/dartclaw_security.dart` instead.

**Option B (genuine credential-carrying implementation)**: Add an entry to `allowlist/no_cross_package_env_plan_duplicates.txt`:
```
MyCredentialPlan@packages/dartclaw_foo/lib/src/credential.dart  # carries X credentials; cannot live in dartclaw_security because Y
```
The `@` separator distinguishes class name from file path. The rationale must explain why the impl cannot live in `dartclaw_security`.

---

## `safe_process_usage_test.dart`

**What it enforces**: Production code under `packages/<X>/lib/` and `apps/<X>/lib/` must not call `Process.run('git', ...)` or `Process.start('git', ...)` directly. All git subprocess invocations must go through `SafeProcess.git(...)`.

**Why**: Raw git subprocesses bypass `SafeProcess`'s environment isolation (credential stripping, path sanitisation). This test freezes the post-0.16.4 baseline where zero production files invoke git directly, acting as a regression guard.

### How to resolve a failure

Replace the raw call:
```dart
// Before
await Process.run('git', ['status']);

// After
await SafeProcess.git(['status'], workingDirectory: dir, environment: env);
```

If the call site genuinely must spawn git directly (e.g. a new canonical wrapper), add an entry to `allowlist/safe_process_usage.txt`:
```
packages/dartclaw_foo/lib/src/git_wrapper.dart  # canonical SafeProcess equivalent for X; must spawn git directly
```

---

# Level-2 Fitness Functions

## `dependency_direction_test.dart`

**What it enforces**: Workspace package imports under `packages/<X>/lib/**` and `apps/<X>/lib/**` must match `allowlist/dependency_direction.txt`.

**Why**: The edge table makes dependency direction reviewable as data and prevents architectural drift such as `dartclaw_workflow` importing concrete storage.

### How to resolve a failure

If the edge is intentional, add:
```
dartclaw_foo -> dartclaw_bar  # <rationale>
```
The rationale is mandatory. Do not allowlist `dartclaw_workflow -> dartclaw_storage`; extract or use a lower-level interface instead.

---

## `src_import_hygiene_test.dart`

**What it enforces**: Production code must not import another workspace package's `src/` implementation files.

**Why**: Cross-package `src/` imports bypass public API boundaries and make internal refactors breaking changes.

### How to resolve a failure

Use the target package barrel. If the symbol is not public, add a narrow explicit `show` export in the owning package.

---

## `testing_package_deps_test.dart`

**What it enforces**: `dartclaw_testing` production dependencies stay limited to shared interface/fake packages and never include shipped implementation packages such as `dartclaw_server` or `dartclaw_storage`.

**Why**: Test doubles should depend on stable interfaces, not drag server/storage implementation layers into consumers.

### How to resolve a failure

Move server/storage-only needs to `dev_dependencies`, or extract the required fake target interface into a lower-level package. Do not add entries to `allowlist/testing_package_deps.txt`; it is expected to stay empty.

---

## `barrel_export_count_test.dart`

**What it enforces**: Top-level package barrels stay under public export-count ceilings: core ≤80, config ≤50, workflow ≤35, others ≤25.

**Why**: Large barrels hide public API growth. The cap forces explicit discussion when package surface area expands.

### How to resolve a failure

Prefer narrower exports or sub-barrels. Temporary breaches require:
```
packages/dartclaw_foo/lib/dartclaw_foo.dart  # <count> exports; shrink to <=<limit> by <story/version>
```

---

## `enum_exhaustive_consumer_test.dart`

**What it enforces**: Selected `WorkflowRunStatus` and `TaskStatus` consumers textually handle every enum value, and alert classifier/formatter consumers mention every `DartclawEvent` subtype.

**Why**: Adding an enum value or alertable event type should fail until UI, CLI, SSE, and alert rendering surfaces are updated.

### How to resolve a failure

Update the named consumer to handle the missing value. If a consumer is deliberately value-derived and does not enumerate values, add:
```
packages/dartclaw_foo/lib/src/file.dart:WorkflowRunStatus  # <rationale>
```

---

## `max_method_count_per_file_test.dart`

**What it enforces**: Production source files under `lib/src/**` stay at ≤40 public/private methods, getters, setters, and operators.

**Why**: Method count catches tangled responsibilities even when LOC has already been reduced.

### How to resolve a failure

Split the file by responsibility. Temporary breaches require:
```
packages/dartclaw_foo/lib/src/large_file.dart  # 43 methods; shrink to <=40 by <story/version>
```
