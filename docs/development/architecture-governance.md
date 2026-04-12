# Architecture Governance

> Current through: **0.16.3**

This document is for contributors, maintainers, and fork authors.

DartClaw uses a small executable governance layer to keep core architectural
boundaries from drifting after a refactor or milestone lands.

The source of truth is:

- [`tool/arch_check.dart`](../../tool/arch_check.dart)

Run it from the repo root:

```bash
dart run tool/arch_check.dart
```

## What It Protects

This script is not a replacement for tests or `dart analyze`. It covers
structural rules that those tools do not fully express.

Today it verifies:

1. The workspace dependency graph resolves cleanly and matches the documented
   internal layering.
2. `dartclaw_core` has no production `sqlite3` dependency.
3. Production libraries do not import another package's `src/` internals.
4. `dartclaw_core` stays under its agreed LOC ceiling.
5. Package barrel files stay under the agreed export ceiling.
6. The workspace package count stays under the agreed ceiling.

## Why This Exists

The 0.16.3 architecture cleanup changed the package graph in important ways:

- config loading moved into `dartclaw_config`
- workflow execution moved into `dartclaw_workflow`
- `dartclaw_core` returned to sqlite3-free runtime primitives
- server-only container orchestration moved into `dartclaw_server`

Those are architectural decisions, not just code moves. The fitness-function
script makes regressions visible immediately.

## What It Does Not Replace

You still need:

- `dart analyze`
  For unresolved imports, stale re-exports, and type/lint issues.

- tests
  For behavioral correctness.

- docs and ADRs
  For the rationale behind the boundary.

Treat `arch_check.dart` as a boundary guardrail, not a full quality gate by
itself.

## When To Care

If you are:

- forking DartClaw
- changing package dependencies
- moving code between packages
- widening a barrel export surface
- adding a new workspace package

run `dart run tool/arch_check.dart` before considering the change complete.

## Related Reading

- [Architecture](../guide/architecture.md)
- [SDK Package Guide](../sdk/packages.md)
- [README](../../README.md)

The private development repo contains the full architecture-governance deep
dive and ADR history used to derive these checks.
