All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw`.

## Unreleased

### Changed
- **The umbrella is the client tier (breaking)** – `import 'package:dartclaw/dartclaw.dart'` now yields `dartclaw_client` + `dartclaw_models` and nothing else: the API/SSE client, its error envelope, its transport seam, and the shared DTO types a running server's endpoints carry.

### Removed
- **Runtime and channel re-exports (breaking)** – `AgentHarness`, `Guard`, `MemoryService` and the channel types are no longer reachable through this package. **Migration:** depend on `dartclaw_core` plus the needed channel package directly; that tier is unpublished and carries no compatibility promise. See ADR-008.

## 0.9.0

### Added
- Re-exported the core, storage, and channel packages from a single umbrella import
- Completed pub.dev metadata with homepage, issue tracker, and package topics

### Changed
- Expanded the umbrella package to cover the decomposed 0.9 package layout

### Removed
- Removed the placeholder `0.0.1-dev.1` release as the latest entry

## 0.0.1-dev.1

- Initial pre-alpha development release
- Exposes core interfaces: `AgentHarness`, `Guard`, `Channel`, `BridgeEvent`
- Namespace reservation on pub.dev — API will change
