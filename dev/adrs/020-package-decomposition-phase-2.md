# ADR-020: Package Decomposition Phase 2

**Status:** Accepted
**Date:** 2026-04-11
**Deciders:** DartClaw team
**Supersedes:** None
**Related:** ADR-014, 0.16.3 PRD

## Context

ADR-014 explicitly deferred further decomposition until the codebase showed hard structural pressure. By 0.16.3 those triggers had fired:

- `dartclaw_core` had grown beyond a runtime-primitives package.
- config parsing and metadata were still owned by core
- workflow definitions and workflow execution were split across packages without a clean ownership boundary
- container orchestration still lived in core even though it is server-only deployment infrastructure
- the 0.16.3 architecture review identified a critical dependency-cycle risk in the original config-extraction plan

The 0.16.3 milestone therefore focused on structural extraction and documentation, not behavior change.

## Decision

### 1. Expand `dartclaw_models`

Move small shared types into `dartclaw_models` so they can sit at the bottom of the package graph:

- `ChannelType`
- `ChannelConfig`, `RetryPolicy`, `GroupAccessMode`
- `ChannelConfigProvider`
- `SessionScopeConfig`, `DmScope`, `GroupScope`, `ChannelScopeConfig`
- `AgentDefinition`
- `ContainerConfig`
- `TaskType`

### 2. Reverse the config dependency direction

Move config parsing, metadata, validation, and YAML authoring into `dartclaw_config`, then make `dartclaw_core` depend on `dartclaw_config`.

This is the key Phase 2 decision. The alternative, keeping config below core but still dependent on core types, recreated a cycle once shared runtime types were accounted for. The accepted shape is:

```text
dartclaw_models
  ↑
dartclaw_security
  ↑
dartclaw_config
  ↑
dartclaw_core
```

`ScopeReconciler` moved to `dartclaw_server` because it is a live subscriber, not a config primitive.

### 3. Move container orchestration to `dartclaw_server`

Keep `ContainerConfig` in `dartclaw_models`, but move Docker lifecycle, credential proxy, security profiles, and profile dispatching into `dartclaw_server`.

Core now owns only the `ContainerExecutor` seam needed by harness code.

### 4. Create `dartclaw_workflow`

Unify the workflow subsystem into a dedicated package that owns:

- workflow definitions
- parsing and validation
- built-in workflow assets
- registry/discovery
- execution/runtime orchestration

`dartclaw_workflow` depends on `dartclaw_config`, `dartclaw_core`, `dartclaw_models`, and `dartclaw_storage`. Both `dartclaw_server` and `dartclaw_cli` consume it.

### 5. Do not proceed with premature server splits

The 0.16.3 architecture review explicitly rejected extractions for templates, scheduling, canvas, and MCP. Those concerns remain inside `dartclaw_server` until a real consumer profile or operational need justifies additional packages. _(Update 2026-06-09: canvas was later removed from core entirely — see the `remove-canvas-feature` FIS — so it is no longer one of these in-server concerns; it may return as an opt-in add-on package.)_

### 6. Add architecture fitness functions

Add `tool/arch_check.dart` to codify the boundaries introduced in this phase:

- dependency graph resolves cleanly
- no sqlite3 in `dartclaw_core`
- no cross-package `src/` imports in production libraries
- core LOC stays within the agreed ceiling
- barrel export counts stay within the agreed ceiling
- workspace package count stays within the agreed ceiling

## Final Package Inventory

### Published or publish-intended packages

| Package | Role |
|---|---|
| `dartclaw` | Umbrella SDK entry point |
| `dartclaw_models` | Shared data types and cross-package enums/config DTOs |
| `dartclaw_security` | Guard framework and security primitives |
| `dartclaw_core` | sqlite3-free runtime primitives |
| `dartclaw_storage` | SQLite-backed repositories and search |
| `dartclaw_whatsapp` | WhatsApp channel integration |
| `dartclaw_signal` | Signal channel integration |
| `dartclaw_google_chat` | Google Chat integration |

### Repo-only support and host packages

| Package | Role |
|---|---|
| `dartclaw_config` | Config loading, metadata, validation, YAML authoring |
| `dartclaw_workflow` | Workflow definitions, registry, validation, execution |
| `dartclaw_testing` | Shared test doubles and helpers |
| `dartclaw_server` | Reference HTTP server, task runtime, web UI, container orchestration |

### Repo-only application

| App | Role |
|---|---|
| `dartclaw_cli` | Operational CLI and local host entry point |

Phase 2 therefore ends with **12 packages plus 1 app** in the workspace. This is lower than earlier decomposition sketches because the review deliberately kept premature server-side splits out of scope.

## Consequences

### Positive

- `dartclaw_core` returns to a runtime-focused role and stays sqlite3-free.
- The config cycle risk is eliminated by the dependency reversal through `dartclaw_models`.
- Workflow ownership is explicit and reusable from both CLI and server hosts.
- Container orchestration is no longer presented as a core primitive.
- Architecture boundaries are now enforced by an executable governance script.

### Negative

- Import paths changed across the workspace.
- `dartclaw_config` and `dartclaw_workflow` are support packages, not polished public SDK packages yet.
- Documentation had to be updated across multiple private and public sources to reflect the new package graph.

### Neutral

- `dartclaw_server` remains large by design; 0.16.3 intentionally chose not to split it further.
- The fitness functions are local governance tooling first; CI integration remains a future step.

## Alternatives Considered

### A. Keep config parsing in `dartclaw_core`

Rejected because it preserved the main source of architectural drift and blocked a clean lower-level config package.

### B. Make `dartclaw_config` depend on `dartclaw_core`

Rejected because the architecture review showed this recreated a dependency cycle once shared types and config consumers were accounted for.

### C. Extract more of `dartclaw_server` in the same milestone

Rejected because the review found no independent consumer profile for templates, scheduling, canvas, or MCP. That decomposition would have increased package count without reducing real coupling. _(Update 2026-06-09: canvas was later removed from core — see the `remove-canvas-feature` FIS — and may return as an opt-in add-on package.)_

## Implementation Notes

The 0.16.3 rollout was deliberately staged:

1. absorb shared types into `dartclaw_models`
2. move config into `dartclaw_config`
3. relocate container implementation to `dartclaw_server`
4. unify workflow code in `dartclaw_workflow`
5. verify the workspace and codify the new boundaries in `tool/arch_check.dart`

This sequencing is part of the decision. The config dependency reversal only works cleanly because the shared types moved first.

## References

- [ADR-014: SDK Package Decomposition Strategy](014-sdk-package-decomposition.md)
- 0.16.3 PRD
