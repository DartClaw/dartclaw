# ADR-056: Package Topology Consolidation

## Status

Accepted – 2026-08-21

**Related:** [ADR-010](010-package-split-models.md), [ADR-014](014-sdk-package-decomposition.md),
[ADR-020](020-package-decomposition-phase-2.md), [ADR-034](034-enforced-package-dependency-direction.md),
[ADR-051](051-container-bridge-binary-packaging.md).

## Context

The bottom of the package graph had three nominal boundaries that no longer matched ownership. `dartclaw_models` was
consumed with configuration, `dartclaw_security` carried an unused models dependency, and `dartclaw_config` already
held the shared runtime utilities that made it the de-facto kernel. The split added dependency edges and re-export
paths without giving consumers an independently useful boundary.

The milestone also needs one target for its remaining topology changes. That target must preserve the bridge as a
standalone, dependency-free package: absorbing it into the future SQLite-bearing core would put a build hook in the
bridge binary's package graph and break its packaging contract.

## Decision

The milestone converges on this package topology. Arrows list allowed workspace dependencies; ordinary third-party
dependencies are omitted.

| Package | Responsibility | Allowed workspace dependencies at milestone close |
|---------|----------------|----------------------------------------------------|
| `dartclaw_kernel` | Models, configuration, guards, audit primitives, shared utilities | none |
| `dartclaw_core` | Runtime primitives, storage, shared channel bases | `dartclaw_kernel` |
| `dartclaw_whatsapp` | WhatsApp integration | `dartclaw_kernel`, `dartclaw_core` |
| `dartclaw_signal` | Signal integration | `dartclaw_kernel`, `dartclaw_core` |
| `dartclaw_google_chat` | Google Chat integration | `dartclaw_kernel`, `dartclaw_core` |
| `dartclaw_runtime` | Hosted runtime and server | kernel, core, the channel packages, workflow and bridge |
| `dartclaw_bridge` | Hook-free container bridge binary | none |
| `dartclaw_workflow` | Framework-agnostic workflow engine | `dartclaw_kernel`, `dartclaw_core` |
| `dartclaw_acp` | ACP adapter and composition registrar | `dartclaw_kernel`, `dartclaw_core` |
| `dartclaw_client` | HTTP/SSE client and transport DTOs | `dartclaw_kernel` only |
| `dartclaw` | Client-tier umbrella | `dartclaw_client`, `dartclaw_kernel` |
| `dartclaw_testing` | Shared test doubles | only the packages whose public contracts its doubles implement |
| `dartclaw_cli` | Thin application composition root | the packages it composes, including `dartclaw_acp` and `dartclaw_runtime` |

The core tier absorbs storage only. `dartclaw_bridge` remains a standing top-level package with zero dependencies;
ADR-051's amendment and the executable packaging proof belong to the bridge-destination work.

Three edges are forbidden and enforced:

1. No package **production-**depends on `dartclaw_runtime` except the CLI application. This is what
   `dependency_direction_test` enforces, and the qualifier is load-bearing: `dartclaw_workflow` and the
   `dartclaw` umbrella both keep a `dev_dependencies` edge on the runtime for suites that need a composed
   runtime, and a dev edge forms no pubspec cycle. The engine stays framework-agnostic in its `lib/`; its
   *tests* are not.
2. `dartclaw_client` depends on nothing except `dartclaw_kernel`.
3. `dartclaw_runtime` does not depend on `dartclaw_acp`. Registration is inverted through
   `DartclawRuntime.build(..., harnessRegistrars:)`; the CLI supplies `AcpHarnessRegistrar`, so the runtime never
   discovers the adapter.

The S29 graph is transitional: `dartclaw_acp` currently implements the generic `HarnessRegistrar` contract owned by
today's `dartclaw_server`, so the adapter declares that downward composition-contract edge while the server carries no
ACP edge. Before S36 enforces the milestone-close tiers, it relocates that generic contract below the runtime tier;
the adapter then depends on kernel and core only. This relocation preserves the approved inversion while making the
first and third forbidden edges simultaneously true at milestone close.

The executable dependency map and production-import fitness check reject additions to these sets. They are exact
contracts, not allowlists intended to grow casually.

### Move protocol

Topology changes use expand → migrate → contract:

1. S33 expands the bottom tier by forming `dartclaw_kernel` from models, config and security.
2. S34 migrates storage into core.
3. S35 migrates channel-owned tendrils into the three channel packages.
4. S36 relocates the generic harness-registration contract below the runtime tier, then contracts the host tier by
   renaming the server package to runtime and leaving a thin CLI.
5. S89 confirms the bridge's standing destination and packaging contract.

Every relocation is a behaviour-preserving `git mv`. A move is not mixed with functional changes. Each landed slice
runs the full CI-equivalent gate, including formatting, analysis, tests, architecture checks and fitness checks.

## Consequences

### Positive

- Consumers have one bottom-tier dependency and one public owner for shared types, configuration and guards.
- Dead and laundering edges disappear from the graph.
- The remaining topology stories share one citable end state and migration protocol.
- Runtime-to-ACP inversion and bridge packaging remain explicit, enforced constraints.

### Negative

- Import paths change throughout the workspace.
- The kernel is deliberately broader than a parsing-only configuration package.
- Lockstep publishing coordinates a larger public surface in one package.

## Alternatives Considered

1. **Keep three bottom packages.** Rejected because their actual consumers and re-exports do not support three
   independently useful ownership boundaries.
2. **Create a fresh kernel and move all three packages into it.** Rejected because renaming `dartclaw_config` preserves
   history for the largest tree and achieves the same boundary.
3. **Keep a compatibility shim for each retired package.** Rejected because it preserves the duplicate authorities and
   dependency edges the consolidation removes.
4. **Absorb the bridge into core.** Rejected because SQLite's build hook would enter the bridge binary's package graph.

## Amendment (2026-08-21) – storage absorption landed

The storage half of the core consolidation has landed. `dartclaw_core` now carries sqlite3 and owns the former
storage package's repositories, search backends, memory services and knowledge graph. `SqliteWorkflowRunRepository`
moved to `dartclaw_workflow`; the storage-agnostic `WorkflowStepExecutionRepository` port moved beside its existing
kernel value type while its SQLite adapter stayed with the shared aggregate row mapper. These two prerequisite moves
removed every storage → workflow import before absorption without duplicating persistence decoding or creating a
package cycle.

SQLite's native-asset build hook means `dart compile exe` cannot produce a supported, self-contained runtime artifact
from a package graph rooted in core. In this workspace it may silently emit a binary without SQLite's native-asset
mapping rather than refusing the build (ADR-048, dart-lang/sdk#62593). The bridge therefore remains a standing
top-level package with zero dependencies. S89 owns the ADR-051 amendment and the byte-comparable bridge-binary proof;
switching the bridge to `dart build` or introducing a compatibility package is not part of this consolidation.

## Amendment (2026-08-22) – the tier order replaces the per-edge tables

The topology is now declared once, as a package tier order in
[`dev/package_tiers.txt`](../package_tiers.txt), and enforced by
`dev/fitness/test/dependency_direction_test.dart`. An edge may only point at a strictly lower tier; same-tier edges
are forbidden. The two hand-maintained tables that used to state the same rule twice —
`arch_check.dart`'s `_expectedWorkspaceDependencies` and the fitness suite's per-edge
`allowlist/dependency_direction.txt` — are deleted. There is no exception mechanism: an edge that cannot be expressed
as a downward step is resolved by splitting a tier. A per-edge table has to be edited for every legitimate
dependency, so it approves whatever the code already does.

The three forbidden edges above are now consequences of the order rather than named special cases:

1. `dartclaw_cli` is the only member above the runtime tier that ships code, so no shipping package can depend on
   `dartclaw_runtime`. The two members that outrank it, `dartclaw_fitness` and `dartclaw_testing`, are placed there so
   that nothing which ships can take a production dependency on *them*; that they take no runtime edge themselves is
   held by `fitness_suite_deps_test.dart` and `testing_package_deps_test.dart`, which pin their dependency sets
   exactly, not by tier position.
2. `dartclaw_client` sits one tier above the kernel, alongside core and the bridge, so the kernel is the only
   workspace package it can reach — a same-tier edge to core is forbidden as surely as an upward one.
3. `dartclaw_acp` sits on the **same tier as** `dartclaw_runtime`. Same-tier edges are forbidden in both directions,
   so the runtime cannot depend on the adapter and the adapter cannot depend on the runtime. This is the only
   placement that makes the first and third forbidden edges true at once: putting the adapter *below* the runtime
   would legalise a runtime → acp edge, and putting it *above* would legalise an acp → runtime edge and give the
   runtime a second member above it. The relocation that makes the placement possible is the one the S29 note above
   anticipated: the generic `HarnessRegistrar` / `HarnessRegistration` contract moved from the runtime down into
   `dartclaw_core`, so the adapter now depends on kernel and core only and the runtime consumes the same contract
   from below.

The gate additionally reconciles each member's declared pubspec dependencies against what its libraries import, in
both directions, so a dead edge cannot survive a move and an undeclared import cannot ride in on the workspace
resolver. `dev_dependencies` are out of scope: a test-only edge is not a shipped dependency.

The same two properties are what let the order forbid a production dependency on `dartclaw_testing`. It is placed on
the top tier beside `dartclaw_fitness`, above everything that ships, so a `dependencies:` entry or a `lib/` import
naming it from any shipping package is an upward edge and fails. A `dev_dependencies:` entry is not an edge at
all and stays legal, which is how all nine of its consumers already reach it. The table above says only that
`dartclaw_testing` may depend on the packages whose contracts its doubles implement; it never said what may
depend on `dartclaw_testing`, and the per-edge table it replaced enforced that by enumeration. Placement now
carries it, with no exception entry.

The workspace holds **12 packages under `packages/` plus one application** at this milestone's close, and the
package-count ceiling records that number — it counts `packages/` alone. The root `workspace:` list holds **14**
members, because `dev/fitness` (`dartclaw_fitness`) is a member and sits outside `packages/`. `dartclaw_bridge` is counted as its own package: S89 is unresolved, so this records the actual
state rather than assuming the combined core+bridge target.

`dartclaw_server` is renamed `dartclaw_runtime` throughout, including the barrel, the release version file and every
gate key; only the package identifier changed, and no Dart symbol was renamed.
