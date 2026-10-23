# Architecture Governance

How DartClaw keeps package boundaries and structural constraints from drifting: the executable checks, what each
enforces, the thresholds, and how to change them. This document owns the fitness functions. The topology they protect
is in [System Architecture](system-architecture.md); the rationale for the mechanism is
[ADR-033](../adrs/033-architectural-governance-via-fitness-functions.md). Per-gate failure guidance lives in
[`dev/fitness/README.md`](../fitness/README.md).

**Current through**: 0.28.0

---

## Why This Exists

ADRs record why a boundary exists but do not stop it eroding. Package decomposition
([ADR-020](../adrs/020-package-decomposition-phase-2.md), then [ADR-056](../adrs/056-package-topology-consolidation.md))
only holds if a regression fails a build. Governance therefore pairs descriptive docs with executable checks that run
locally and in CI.

## Governance Layers

[![Governance layers](diagrams/governance-layers.svg)](diagrams/governance-layers.svg)

Layers 1 to 3 run in that order in the CI Check job (format check first, workspace tests between layers 1 and 2), and
the same commands run locally; a failing layer fails the build. `run_all.sh` stops at the first failing gate. It
includes the schema and config-reference drift checks, version lockstep (`dev/tools/check_versions.sh`) and the Dart
fitness tests (`bash dev/tools/run-fitness.sh`, i.e. `dart test dev/fitness/test/`). Layer 4 explains why a boundary
exists and when it may change.

The scripts complement the analyzer and tests; they do not replace them.

## Dependency Direction

Dependency direction is governed by the tier order in [`dev/package_tiers.txt`](../package_tiers.txt), not by
`arch_check.dart`:

[![Package topology: tier order](diagrams/system-package-topology.svg)](diagrams/system-package-topology.svg)

An import or re-export may point only at a **strictly lower** tier. Same-tier edges are forbidden, which keeps channel
packages from reaching each other, keeps `dartclaw_client` off core, and keeps the runtime and the ACP adapter apart.
`dev/fitness/test/dependency_direction_test.dart` derives the allowed edges from this file, reconciles each member's
declared pubspec dependencies against what its libraries import (declared-but-unimported and imported-but-undeclared
both fail), and fails on a workspace member with no tier. There is no per-edge table and no exception mechanism: an edge
that cannot be a downward step is resolved by splitting a tier ([ADR-034](../adrs/034-enforced-package-dependency-direction.md)).

Related dependency gates, all in `dev/fitness/test/`:

| Gate | Enforces |
|---|---|
| `package_cycles_test.dart` | The workspace package graph is acyclic. Allowlist mandated empty |
| `no_app_dependency_test.dart` | No `packages/` member depends on an `apps/` member, including via `dev_dependencies:` |
| `workflow_task_boundary_test.dart` | `dartclaw_workflow/lib/src` imports only `dart:*`, siblings, `dartclaw_kernel`, `dartclaw_core` and its declared third-party set ([ADR-023](../adrs/023-workflow-task-boundary.md)). No allowlist |
| `bridge_package_deps_test.dart` | `dartclaw_bridge` stays dependency-free. Allowlist mandated empty |
| `testing_package_deps_test.dart` | `dartclaw_testing` depends on no shipped implementation package. Allowlist mandated empty |
| `fitness_suite_deps_test.dart` | `dev/fitness` imports and depends on no DartClaw package; every gate scans source as text |
| `src_import_hygiene_test.dart` | No production import of another package's `src/` |
| `barrel_show_clauses_test.dart` | Every `export 'src/...'` in a package barrel carries a `show` clause |

## `arch_check.dart`

[`dev/tools/arch_check.dart`](../tools/arch_check.dart) enforces what the tier order does not:

| Check | Rule |
|---|---|
| L1 core barrel | `dartclaw_core.dart` does not re-export the whole kernel barrel. Targeted `show` re-exports are allowed |
| L1 Claude provider options | Raw `['inherit_user_settings']` lookups appear only in `dartclaw_kernel` (`claude_provider_options.dart`, `config_parser.dart`) |
| L2 per-package LOC target | One recorded target per workspace member with a `lib/` (`_libLocCeilings`). Fails at measured lines >= 110% of target (`locExceedsTarget` in `dev/tools/loc_target.dart`). A member without a target fails; a target for a member without `lib/` fails. `lib/src/generated/` is not counted |
| L2 package count | `packages/` holds at most 14 directories (`_workspacePackageCeiling`). The root `workspace:` list also holds `apps/dartclaw_cli` and `dev/fitness` |

The script prints one line per check plus a summary and exits non-zero on any failure.

## Fitness Suite Gates

Shell and Dart scripts under [`dev/tools/fitness/`](../tools/fitness/), run by `run_all.sh`:

| Script | Enforces |
|---|---|
| `check_no_workflow_private_config.sh` | `_workflow*` task-config keys are read only from an allowlist of workflow-package files, behind `WorkflowTaskConfig` |
| `check_no_framework_coupling.sh` | Zero `andthen` literals in `dartclaw_workflow/lib/src` outside built-in definition YAML ([ADR-041](../adrs/041-framework-agnostic-workflow-engine-generic-output-validation.md)) |
| `check_no_prose_parsing.sh` | The retired prose-parsing constructs stay deleted (below) |
| `check_css_comment_state.sh` | Served CSS has balanced comments |
| `check_no_external_origins.sh` | Served templates, CSS and CSP load no subresource from an external origin |
| `check_task_executor_workflow_refs.dart` | `task_executor.dart` mentions `_workflow*`, `workflowRunId` or `stepIndex` only at allowlisted sites, and the active workflow path spawns no CLI process |
| `generate_config_schema.dart --check`, `generate_workflow_schema.dart --check` | Committed JSON schemas match their generators |
| `test_render_config_reference.sh`, `check_config_reference_drift.sh` | The guide's config reference matches the renderer |

Dart gates in `dev/fitness/test/` beyond the dependency set above:

| Gate | Enforces |
|---|---|
| `max_file_loc_test.dart` | Each `packages/*/lib/src/**/*.dart` file below 1,650 lines (1,500 target); allowlist entries carry a shrink target |
| `max_test_file_loc_test.dart` | Each `*_test.dart` below 1,430 lines (1,300 target); an allowlisted file may not reach 110% of its recorded baseline, and an entry for a file that dropped below the limit or vanished fails |
| `constructor_param_count_test.dart` | No public constructor over 12 parameters |
| `safe_process_usage_test.dart` | No raw `Process.run/start('git', ...)` in production; git goes through `runGit` from the kernel |
| `no_cross_package_env_plan_duplicates_test.dart` | `ProcessEnvironmentPlan` implementations live in `dartclaw_kernel` |
| `no_duplicate_local_fakes_test.dart` | A local fake/stub/mock class name is declared in one test file |
| `no_second_implementation_test.dart` | A public production type name is declared in one workspace member only (below) |
| `structured_output_refusal_test.dart` | Every production `AgentHarness` calls `requireStructuredOutputSupport` |
| `enum_exhaustive_consumer_test.dart` | Named consumers enumerate every value of their enum |
| `config_key_consumers_test.dart` | Every leaf in the config schema has a production consumer or a reasoned allowlist entry |
| `config_load_seam_test.dart` | `DartclawConfig.load` is called only from `loadDartclawConfig` in `dartclaw_runtime` |
| `config_section_tier_coverage_test.dart` | Every config section declares a `ConfigNotifier` reload tier |
| `memory_architecture_test.dart` | Memory curation writes go through `MemoryApplyService.apply` with no durable run record, every exported memory API has a production consumer, and normative docs carry no retired memory model |

Two gates hold the defect classes that [ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md)
names:

- **`check_no_prose_parsing.sh`** asks whether a named retired construct is back, not whether code "is a prose parser":
  the retired workflow-output recovery and review-count derivation symbols, the `ReviewCommand*` grammar, the
  `@advisor` mention detector and `AdvisorMentionEvent`/`AdvisorInsightEvent`, and the literal `'null'` path sentinel in
  `context_extractor.dart` and `produced_artifact_resolver.dart`. It ships no allowlist; each pattern was measured at
  zero before being added, so a match is a finding against the change that reintroduced it, never an exemption. It
  catches only the listed constructs.
- **`no_second_implementation_test.dart`** scans every member with a `lib/`, apps included. A `typedef X = other.X;`
  re-alias is skipped rather than exempted. Its allowlist is a ratchet that may shrink and not grow, and holds two
  entries (`TurnManager`, `TurnRunner`), each a runtime class implementing the port core owns.

**Allowlist rules.** Exceptions are plain-text files under `dev/fitness/test/allowlist/`, one `<key>  # <rationale>`
line each. A gate that consults its allowlist by key also fails on a stale entry it never looked up, because the path,
position or edge it named is gone. Run a gate file whole: a name-filtered `dart test -n` skips the scan that does the
consulting and reports live entries as stale.

## Thresholds

| Constraint | Value | Where it lives |
|---|---|---|
| Per-package `lib/` LOC | One target per member; fails at >= 110% | `_libLocCeilings` in `arch_check.dart` |
| Production file LOC | 1,500 target, fails at 1,650 | `max_file_loc_test.dart` |
| Test file LOC | 1,300 target, fails at 1,430 | `max_test_file_loc_test.dart` |
| Constructor parameters | <= 12 | `constructor_param_count_test.dart` |
| Workspace package count | <= 14 under `packages/` | `_workspacePackageCeiling` in `arch_check.dart` |

Targets are executable policy, so the numbers live in code. Shrinkage never fails and a change below the 10% margin needs
no edit. When growth reaches the margin, decompose or record a deliberate target change; the amendment in ADR-033 sets
the policy. A target change that admits growth beyond the margin records the measured value and rationale next to the
number in `arch_check.dart` and in `CHANGELOG.md`. If the margin changes, update this document and the gates together.

## Scope

In scope: stable, high-signal boundaries that are cheap to check: dependency direction, forbidden production
dependencies, package and API surface size, public-vs-private import hygiene, and seams a milestone closed that would be
easy to regress mechanically.

Out of scope, handled elsewhere: behavioral correctness (tests), style and unused code (formatter, analyzer),
refactoring preferences (review), and semantic architecture inference (too brittle for a regex script).

Add or change a check when a shipped decision introduces a boundary that should stay true after the milestone closes:
a new package (package-count impact), a deliberately revised LOC target, or a regression-prone seam. Do not encode
one-off cleanups.

## Change Process

1. Change the code: `arch_check.dart`, `package_tiers.txt`, or the gate.
2. Update this document and any affected ADR or architecture doc in the same change.
3. Run `dart analyze` and `dart run dev/tools/arch_check.dart`; for fitness-suite changes also `bash dev/tools/fitness/run_all.sh`.
4. State the rationale in the change. Do not silently loosen a threshold.

## CI

`.github/workflows/ci.yml` runs four jobs:

| Job | Runs |
|---|---|
| **Check** | Embedded-asset generation, format, `dart analyze --fatal-infos`, `dev/tools/test_workspace.sh`, `arch_check.dart`, `dev/tools/fitness/run_all.sh` |
| **PowerShell scripts** | `dev/tools/check_powershell.ps1` on Windows |
| **Container boundary** | Builds the in-container bridge and runs `dev/testing/profiles/container/run.sh --ci`, which boots a config declaring no `container:` section and asserts the posture resolved to container isolation. An absent runtime fails the job: the server's advisory downgrade exits zero and would otherwise read as a pass. It has no fork-PR condition because it needs no secret and issues no model turn |
| **PostgreSQL contract** | `dev/tools/postgres_contract.sh` |

**Check** is skipped for same-repo `pull_request` events, since the push already ran it.

## Related Documents

- [System Architecture](system-architecture.md)
- [Data Model](data-model.md)
- [Workflow Architecture](workflow-architecture.md)
- [ADR-014: SDK Package Decomposition Strategy](../adrs/014-sdk-package-decomposition.md)
- [ADR-020: Package Decomposition Phase 2](../adrs/020-package-decomposition-phase-2.md)
- [ADR-033: Architectural Governance via Fitness Functions](../adrs/033-architectural-governance-via-fitness-functions.md)
- [ADR-056: Package Topology Consolidation](../adrs/056-package-topology-consolidation.md)
