# Package Rules — `dartclaw_models`

**Role**: Zero-dependency shared kernel — `Session`/`Message`/`MemoryChunk`, `SessionKey`, `AgentDefinition`, `ContainerConfig`, `ChannelConfig`/`ChannelType`/`SessionScopeConfig`, `TaskType`. All domain-specific models live in their owning packages (see CHANGELOG 0.16.5 Breaking API Changes). Barrel: `lib/dartclaw_models.dart` with explicit `show` clauses.

## Boundaries
- Runtime dependencies: `collection` only. Do not add `path`, `yaml`, `sqlite3`, `dart:io`, or anything pulling them in transitively. These types must be importable from any environment (server, CLI, future Flutter clients).
- Services, repositories, parsers, validators, and persistence logic do **not** live here. Models own data shape + JSON/Map (de)serialization only. Service layer = `dartclaw_core`. SQLite repositories = `dartclaw_storage`. Parsing/validation of YAML config = `dartclaw_config`.
- Do not import from any other `dartclaw_*` package. This is the bottom of the DAG.

## Conventions
- Classes are immutable: `final` fields, `const` constructor where possible, `copyWith(...)` for mutation. Equality via `==`/`hashCode` if used as map key or compared by `ConfigNotifier`.
- Provide both `toJson()` (`Map<String, dynamic>`) and a `fromJson` factory. Omit nullable fields from the map when null (see `Session.toJson`) — wire-compatible omission, not `null` literals.
- New entries in the barrel use explicit `show` lists. Don't dump-export new files.
- Sealed class hierarchies (e.g. `ChannelConfig` subtypes) — extend by adding a new subtype + case, never by adding `dynamic` payloads.

## Gotchas
- `SessionKey` factories pre-encode identifier components with `Uri.encodeComponent`. Do not double-encode at call sites; do not bypass factories and build `agent:...:...` strings by hand. The `.session_keys.json` index assumes deterministic, idempotent keys.
- `Message.cursor` is the 1-based line number in `messages.ndjson` — assigned on read, never persisted. Don't add `cursor` to the JSON payload.

## Testing
- Pure value-type tests, one file per model in `test/`. No fakes needed (no I/O, no async). When changing a `toJson`/`fromJson` shape, add a round-trip test alongside the field-level assertions.

## Key files
- `lib/dartclaw_models.dart` — barrel; canonical export surface.
- `lib/src/models.dart` — `Session` / `Message` / `MemoryChunk` / `MemorySearchResult` value types.
- `lib/src/session_key.dart` — encoding contract; touch with care.
- `lib/src/agent_definition.dart`, `lib/src/container_config.dart` — runtime-adjacent shared value types.
- `lib/src/channel_config.dart`, `lib/src/channel_type.dart`, `lib/src/session_scope_config.dart` — channel/scoping shared types.
