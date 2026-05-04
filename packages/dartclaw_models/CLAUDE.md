# Package Rules — `dartclaw_models`

**Role**: Zero-dependency value types shared across the workspace — `Session`/`Message`, `SessionKey`, `Project`, `WorkflowDefinition`/`WorkflowRun`, `TaskEvent` (+`TaskEventKind` sealed class), `TurnTrace`, `ToolCallRecord`, `AgentDefinition`, `ContainerConfig`, `ChannelConfig`/`ChannelType`/`SessionScopeConfig`, `SkillInfo`. Barrel: `lib/dartclaw_models.dart` with explicit `show` clauses.

## Boundaries
- Runtime dependencies: `collection` only. Do not add `path`, `yaml`, `sqlite3`, `dart:io`, or anything pulling them in transitively. These types must be importable from any environment (server, CLI, future Flutter clients).
- Services, repositories, parsers, validators, and persistence logic do **not** live here. Models own data shape + JSON/Map (de)serialization only. Service layer = `dartclaw_core`. SQLite repositories = `dartclaw_storage`. Parsing/validation of YAML config = `dartclaw_config`.
- Do not import from any other `dartclaw_*` package. This is the bottom of the DAG.

## Conventions
- Classes are immutable: `final` fields, `const` constructor where possible, `copyWith(...)` for mutation. Equality via `==`/`hashCode` if used as map key or compared by `ConfigNotifier`.
- Provide both `toJson()` (`Map<String, dynamic>`) and a `fromJson` factory. Omit nullable fields from the map when null (see `Session.toJson`) — wire-compatible omission, not `null` literals.
- New entries in the barrel use explicit `show` lists. Don't dump-export new files.
- Sealed class hierarchies (e.g. `TaskEvent` / `TaskEventKind`, workflow `WorkflowNode` subtypes) — extend by adding a new subtype + case, never by adding `dynamic` payloads.

## Gotchas
- `SessionKey` factories pre-encode identifier components with `Uri.encodeComponent`. Do not double-encode at call sites; do not bypass factories and build `agent:...:...` strings by hand. The `.session_keys.json` index assumes deterministic, idempotent keys.
- `Message.cursor` is the 1-based line number in `messages.ndjson` — assigned on read, never persisted. Don't add `cursor` to the JSON payload.
- `WorkflowDefinition` carries prompt-bearing data; full definitions are not used in discovery surfaces — use `WorkflowSummary` for discovery contexts.

## Testing
- Pure value-type tests, one file per model in `test/`. No fakes needed (no I/O, no async). When changing a `toJson`/`fromJson` shape, add a round-trip test alongside the field-level assertions.

## Key files
- `lib/dartclaw_models.dart` — barrel; canonical export surface.
- `lib/src/models.dart` — `Session` / `Message` / `MemoryChunk` / `MemorySearchResult` value types.
- `lib/src/session_key.dart` — encoding contract; touch with care.
- `lib/src/task_event.dart` — sealed `TaskEventKind` hierarchy; `task_events` schema mirror.
- `lib/src/workflow_definition.dart`, `lib/src/workflow_run.dart` — workflow domain models (large, evolving).
- `lib/src/project.dart`, `lib/src/turn_trace.dart` — cross-store reference targets.
