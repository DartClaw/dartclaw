# ADR-010: Package Split — dartclaw_models

**Status:** Accepted
**Date:** 2026-03-04
**Deciders:** DartClaw team

## Context

DartClaw 0.6 (F21) required evaluating `dartclaw_core` (~67 source files) for warranted package splits. This builds on the successful `dartclaw_storage` split from 0.5 (ADR-008). Four candidate packages were evaluated against consistent criteria.

### Evaluation Criteria

For each candidate:
- **(a) Zero deps beyond dart:core/dart:io**: Can the package have zero external package dependencies?
- **(b) Independent consumer use case**: Would an external developer plausibly import this package alone?
- **(c) Acyclic dependency graph**: Does the split maintain a clean DAG?
- **(d) Acceptable breaking change cost**: Is the migration mechanical and low-risk?

Split threshold: execute if **(a) + (b) + (c)** all met. Defer if **(d)** outweighs benefit.

## Decision

### Execute: `dartclaw_models`

| Criterion | Result |
|-----------|--------|
| (a) Zero deps | YES — pure data classes, no dart:io, no external packages |
| (b) Consumer | YES — Session, Message, MemoryChunk, SessionKey are generic data types for any DartClaw-compatible tool |
| (c) Acyclic | YES — zero inbound dependencies; clean DAG: models -> core -> storage/server |
| (d) Cost | LOW — 2 source files, 4 internal importers updated mechanically |

Files moved: `models/models.dart`, `models/session_key.dart`. Backward compatibility maintained via `dartclaw_core` barrel re-export (`export 'package:dartclaw_models/dartclaw_models.dart'`).

### Defer: `dartclaw_channel`

Fails (a) and (c). `message_queue.dart` depends on `MessageRedactor` from `security/` — creates circular dependency risk. 16 files, external deps on `uuid` and `logging`. Refactoring `MessageRedactor` into an injectable interface is out of scope for 0.6.

### Defer: `dartclaw_memory`

Fails (b). Independent consumer use case is too narrow (parsing MEMORY.md entries). Only 3 files — negligible weight in `dartclaw_core`. External deps on `logging` and `path`.

### Defer: `dartclaw_harness`

Fails (a) and (c). Strong consumer use case (b) — developers wanting only the `claude` binary harness. But `ClaudeCodeHarness` depends on `Guard`, `ContainerManager`, and `WorkerState` — substantial refactoring needed. 10+ files. Worthwhile for 0.7+ when the harness interface stabilizes.

### Summary

| Candidate | (a) Zero deps | (b) Consumer | (c) Acyclic | (d) Cost | Decision |
|-----------|:---:|:---:|:---:|:---:|----------|
| `dartclaw_models` | YES | YES | YES | LOW | **EXECUTE** |
| `dartclaw_channel` | NO | PARTIAL | NO | MED-HIGH | DEFER |
| `dartclaw_memory` | PARTIAL | WEAK | YES | LOW | DEFER |
| `dartclaw_harness` | NO | YES | NO | HIGH | DEFER |

## Consequences

### Package Structure After Split

```
packages/
  dartclaw/           # Published umbrella — re-exports core + storage (models flow through)
  dartclaw_models/    # NEW — Session, Message, MemoryChunk, SessionKey, enums (zero deps)
  dartclaw_core/      # Models removed, re-exports from dartclaw_models
  dartclaw_storage/   # sqlite3-backed services (unchanged)
  dartclaw_server/    # HTTP API + web UI (unchanged)
apps/
  dartclaw_cli/       # CLI app (unchanged)
```

### Dependency Graph

```
dartclaw_models  (zero deps)
     ^
     |
dartclaw_core  (depends on dartclaw_models + stream_channel, uuid, etc.)
     ^            ^
     |            |
     |      dartclaw_storage  (depends on dartclaw_core, sqlite3)
     |            ^
     |            |
dartclaw_server  (depends on core + storage + shelf + ...)
     ^
     |
dartclaw_cli  (depends on server)
```

### Positive

- Zero-dependency models package enables lightweight consumers (viewers, analytics, migration tools)
- Validates the split process for future candidates
- No downstream consumer needs import changes (barrel re-export)

### Negative / Risks

- Additional package coordination during publishing (mitigated by single-maintainer workspace)
- `dartclaw_models` is small (2 files) — some may consider it over-split (justified by zero-dep consumer use case)

### Future Reconsideration Conditions

- **`dartclaw_channel`**: Reconsider when `MessageRedactor` is refactored into an injectable interface
- **`dartclaw_memory`**: Reconsider if `MemoryEntry` becomes a shared type with external consumers
- **`dartclaw_harness`**: Reconsider in 0.7+ when harness interface stabilizes and `Guard`/`ContainerManager` dependencies can be injected

## Amendment (0.16.5) — `dartclaw_models` confirmed as the true shared kernel

Recorded retroactively 2026-05-31. The "small (2 files), possibly over-split" concern above is resolved in the opposite direction: 0.16.5's model grab-bag migration moved domain-specific models *out* of `dartclaw_models` (and `dartclaw_core`) into their canonical owning packages, leaving `dartclaw_models` as a deliberate, true shared kernel (`Session`, `Message`, `SessionKey`, `ChannelType`, `AgentDefinition`, `MemoryChunk`). The `dartclaw_core` LOC ceiling was ratcheted 13 000 → 12 500 as part of the same sweep (closes TD-102). The enforced dependency direction that keeps the kernel clean is recorded in [ADR-034](034-enforced-package-dependency-direction.md). See CHANGELOG `[0.16.5]`.
