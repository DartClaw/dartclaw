# ADR-008: SDK Publishing Strategy

**Status:** Accepted (revised 2026-03-12)
**Date:** 2026-03-01 (revised 2026-03-12)
**Deciders:** DartClaw team

## Context

DartClaw's `dartclaw_core` package has clean abstraction-first design — `AgentHarness`, `Guard`, `Channel`, `SearchBackend` are abstract interfaces with injected implementations. The architecture supports SDK use, but the package is unpublished (`publish_to: none`), has no README/CHANGELOG/example, over-exports ~90 symbols without `show` filtering, and has sparse doc comments.

The Dart agent runtime ecosystem is nascent and uncrowded. No official Anthropic Dart SDK exists. The only architectural analog is `codex` (pub.dev) which wraps the OpenAI Codex CLI over JSONL — the same subprocess-harness pattern DartClaw uses with the `claude` binary. Key ecosystem packages: `langchain` (pre-1.0 indefinitely), `mcp_dart` (de facto MCP SDK), `anthropic_sdk_dart` (best Claude REST client).

Two interconnected decisions needed resolution:
1. **When** to publish — balancing API stability vs. namespace positioning
2. **How** to package — balancing dependency footprint vs. maintenance burden

### Constraints

- Single maintainer — multi-package coordination cost must be justified
- S18/S19 (search/memory) not yet implemented — will change `SearchBackend` and memory service interfaces
- 0.5 planned additions (InputSanitizer, MessageRedactor, UsageTracker) are additive, not interface-breaking
- Verified publisher already available
- `sqlite3` native dependency is friction for consumers who only want harness + guards

### Revised Context (2026-03-12)

The original decision kept `dartclaw_server` and `dartclaw_cli` as `publish_to: none` — internal application code not intended for external use. This has been revised based on evolving project philosophy:

- **"Build your own agent" philosophy** — Inspired by Cole Medin's approach: DartClaw provides composable building blocks for developers to build purpose-built agents. The server and CLI are not just internal tooling — they are *one way* to compose DartClaw's building blocks, and a valuable one for developers to study, fork, and extend.
- **Project cohesion** — Keeping all packages in one public repo and publishing them all avoids an artificial private/public boundary within a cohesive codebase. The server and CLI depend on the same SDK packages as external consumers do — they *are* consumption examples.
- **Private customization layer** — Proprietary integrations, custom channels, custom guards, and deployment configs belong in a separate private repo (`dartclaw-private` or similar) as overlays on top of the public packages, not as modifications to them.

## Decision

### Package naming: Start with `dartclaw`

**We will publish a single `dartclaw` package initially to claim the prime namespace.** This is the most appealing and discoverable name on pub.dev.

The current `dartclaw_core` package is the source of the published API surface. For the name-squat, we publish it as `dartclaw`. If a core/storage split is warranted later (at 0.4), `dartclaw` becomes the convenience umbrella re-exporting `dartclaw_core` + `dartclaw_storage` — the same pattern `langchain` uses with `langchain_core`.

### Timeline: Name-squat now, real publish at 0.5

**We will publish `dartclaw` as `0.0.1-dev.1` immediately to establish pub.dev presence, with the first real release at `0.5.0` after security hardening and agent intelligence types are part of the API surface.**

Name-squat published 2026-03-01. Publisher transfer to verified publisher complete.

Originally planned for 0.4, but 0.5 is a better release point: it adds `InputSanitizer`, `MessageRedactor`, and `UsageTracker` to the public API — types that belong in an SDK. Publishing at 0.5 means a more complete API surface in the first real release, at the cost of ~1 milestone delay.

Pre-release dev versions are excluded from default dependency resolution — consumers must explicitly opt in via version constraint. This reduces (but does not eliminate) accidental adoption risk. The `genkit` ecosystem uses this exact `0.0.1-dev.N` pattern. Prereleases are immutable once published and remain visible on pub.dev — the README quality matters even for dev releases.

### Granularity: Single package now, evaluate split at 0.5

**We will publish `dartclaw` as a single package for the name-squat.** The core/storage split (separating sqlite3-dependent services into `dartclaw_storage`) is deferred to the SDK package split work and will be evaluated then — it may or may not be warranted depending on how the API evolves.

Investigation (2026-03-02) confirms clean split boundary: sqlite3 isolated to 2 files (`memory_service.dart`, `search_db.dart`), zero cross-imports from outside `storage/`+`search/`. Split is feasible with minimal refactoring.

If the split happens at 0.5:
- `dartclaw` — convenience umbrella re-exporting core + storage
- `dartclaw_core` — models, security, bridge, harness, channels, config. **No sqlite3.**
- `dartclaw_storage` — sqlite3-backed services (SessionService, MessageService, etc.)

If the split is not needed, `dartclaw` remains the single published package.

### All packages published (revised 2026-03-12)

~~The `publish_to: none` on `dartclaw_server` and `dartclaw_cli` signals "not for external use."~~ **Revised: all packages will be published**, including `dartclaw_server` and `dartclaw_cli`. This supersedes the original decision to keep server and CLI as internal-only.

`dartclaw_server` and `dartclaw_cli` are published as **reference implementations** — working, production-quality examples of how to compose DartClaw's SDK packages into a complete agent runtime. They serve multiple purposes:

- **Learning resource** — developers study the server and CLI to understand how to wire harness, guards, channels, events, and storage together
- **Fork-and-customize starting point** — developers can fork the server or CLI as a foundation for their own agent applications
- **Proof of pattern** — the server and CLI validate that DartClaw's abstractions actually compose into a working system
- **Dependency example** — they consume the same published SDK packages that external developers would, serving as living documentation of the consumption pattern

This aligns with DartClaw's "build your own agent" philosophy: the SDK packages (`dartclaw_core`, `dartclaw_models`, `dartclaw_storage`) are composable building blocks; the server and CLI are *one composition* of those blocks. Publishing them invites developers to build different compositions for their own use cases.

### Private customization layer

Proprietary extensions live outside the public repo:

- **Custom channels** — private messaging integrations (proprietary protocols, internal chat systems)
- **Custom guards** — organization-specific security policies, compliance filters
- **Deployment configs** — infrastructure-specific configuration, secrets management
- **Custom tools** — domain-specific MCP tools, internal API integrations

These are implemented as *overlays* — separate Dart packages that depend on the published DartClaw packages. They do not modify the public packages; they extend them via the existing abstract interfaces (`Channel`, `Guard`, `SearchBackend`, etc.).

```
my-private-repo/
├── packages/
│   ├── my_custom_channel/      # implements Channel
│   ├── my_compliance_guard/    # implements Guard
│   └── my_agent_app/           # depends on dartclaw + custom packages
└── configs/
    └── production.yaml         # deployment-specific config
```

### Repository structure

The existing GitHub repo (`tolo/dartclaw`) stays as-is — a pub workspace mono-repo. All packages are published from this repo.

The repo is currently private. It does not need to be public for the name-squat — pub.dev accepts a `repository` URL that doesn't resolve yet. The repo should be made public before the first real publish at latest. When ready to publish, `publish_to: none` will be removed from all packages.

```
tolo/dartclaw/                    # public GitHub repo
├── packages/
│   ├── dartclaw/                 # published — umbrella re-export
│   ├── dartclaw_core/            # published — SDK core (harness, guards, channels, events, config)
│   ├── dartclaw_models/          # published — zero-dep data types
│   ├── dartclaw_storage/         # published — sqlite3 persistence
│   ├── dartclaw_server/          # published — reference implementation (HTTP API + web UI)
│   └── dartclaw_testing/         # published (when consumers exist)
├── apps/
│   └── dartclaw_cli/             # published — reference implementation (CLI)
├── pubspec.yaml                  # workspace root
└── README.md                     # project-level overview
```

### Versioning: Dart pre-1.0 convention

Follow `0.BREAKING.FEATURE` (Dart community convention for pre-1.0). Do not mirror the `claude` CLI version — DartClaw has its own API surface. Reach `1.0.0` only when API is genuinely stable. All packages in the workspace share the same version number — coordinated releases.

## Consequences

### Positive

- Claims the prime `dartclaw` namespace on pub.dev
- Establishes presence in an uncrowded niche before competitors
- Pre-release dev publish reduces default adoption risk while claiming namespace
- Single package to maintain initially — simplest possible approach
- Natural upgrade path to umbrella package if split is needed later
- Mono-repo keeps development friction low (same-PR changes across packages)
- Publishing server + CLI as reference implementations gives developers a complete, working example to study and fork
- "Build your own agent" philosophy differentiates DartClaw from closed-source agent runtimes
- Private customization layer pattern keeps the public repo clean while supporting proprietary extensions

### Negative

- Dev release README on pub.dev for 3-4 months — must be high quality to avoid negative first impression
- First publish requires two-step flow (personal account → transfer to verified publisher)
- If split happens later, `dartclaw` transitions from "the package" to "umbrella re-export" — minor conceptual shift for early adopters
- Publishing server + CLI means their APIs become part of the project's public contract — breaking changes require semver coordination
- Server and CLI dependencies (shelf, args, etc.) become visible in the published dependency graph

### Neutral

- `dartclaw_testing` package (fakes/mocks) deferred until SDK consumers exist
- Channel split (WhatsApp/Signal as separate packages) deferred until external contributors emerge
- GitHub repo visibility is independent of pub.dev publishing
- Server and CLI are published but not expected to be used as library dependencies — they are standalone applications published for transparency and forkability

## Alternatives Considered

### A: Publish full API now at 0.1.0

- **Pros**: Maximum feedback speed, immediate namespace capture
- **Cons**: S18/S19 will break interfaces within months; sparse docs damage pub.dev score
- **Rejected because**: API stability risk too high (weighted score 6.15 vs 7.51 for chosen approach)

### B: Publish at 0.4 without name-squatting

- **Pros**: Balanced quality and timing; proven interfaces
- **Cons**: 3-4 months of pub.dev invisibility; misses early namespace positioning
- **Rejected because**: Name-squat captures positioning benefit at near-zero cost (weighted score 6.54 vs 7.51)

### C: Publish post-0.5

- **Pros**: Maximum API stability; all interfaces battle-tested
- **Cons**: 6-9 months invisible in an emerging niche; over-optimizes for stability
- **Rejected because**: 0.5 additions are additive (not interface-breaking) — waiting doesn't meaningfully reduce API churn but carries significant positioning cost (weighted score 5.95)

### Publish as `dartclaw_core` only (skip `dartclaw` name)

- **Pros**: Name directly reflects contents
- **Cons**: Leaves the prime `dartclaw` namespace unclaimed; someone else could register it
- **Rejected because**: `dartclaw` is the most discoverable name and should be controlled by the project

### Separate SDK repo from application repo

- **Pros**: Clean separation of public SDK from private application code
- **Cons**: Cross-repo dependency management (publish-then-update cycle for every core change), two CI configs, split PRs for interface changes
- **Rejected because**: Mono-repo keeps all packages cohesive and avoids development friction. With the revised decision to publish all packages, there is no private application code to separate — `dartclaw_server`/`dartclaw_cli` are published reference implementations. Proprietary extensions live in separate private repos as overlays

### Full split (5 packages)

- **Pros**: Maximum flexibility; consumers pick exactly what they need
- **Cons**: 5-package version coordination is punishing for single maintainer; no external channel contributors to justify the split
- **Rejected because**: Maintenance burden outweighs flexibility gains (weighted score 255 vs 291 for Core+Storage)

## Implementation Notes

### Phase 1 — Name-squat ✅ (2026-03-01)

- Created `packages/dartclaw/` with zero-dependency placeholder (library doc comment only, no exports — `dartclaw_core` is `publish_to: none`)
- Preview README with architecture diagram, core abstractions, pre-alpha status
- Published `0.0.1-dev.1` via personal account, transferred to verified publisher

**Gate**: ✅ Published on pub.dev, verified publisher shown.

### Phase 2 — Keep alive (during 0.4)

- Publish `0.0.N-dev.M` on meaningful API or documentation milestones (not on cadence)
- If prerelease sits >2 months without update, publish a docs-only bump to signal active development

**Gate**: At least one dev release published before Phase 3.

### Phase 3 — Real publish (0.5 release)

- F08: API surface audit — narrow barrel to ~35 symbols with `show` clauses
- F09: Core/storage split evaluation + execution (clean boundary confirmed)
- F10: Full README, CHANGELOG, doc comments (80%+), example, LICENSE, `pana` validation
- F11: Publish `0.5.0`

**Gate**: `pana` score >=130/160, example compiles and runs, `dart analyze` clean, `dart pub publish --dry-run` passes.

### Phase 4 — Post-publish

- Add `dartclaw_testing` when consumers exist
- Consider channel split only if external contributors emerge

### Contingencies

- **Bad publish**: Use `dart pub retract` to mark a version as retracted (prevents new resolution but doesn't delete). If fundamentally broken, mark package as discontinued and re-publish under corrected version.
- **0.4 slips significantly**: If prerelease sits stale >3 months, publish a docs/README update release to maintain activity signal.

## Split Evaluation Result (0.5)

**Decision: Split executed.** (2026-03-03)

### Rationale

- sqlite3 isolation confirmed: exactly 2 source files (`memory_service.dart`, `search_db.dart`) directly import `package:sqlite3`. Zero cross-imports from non-storage code.
- Split cost was low: 7 source files moved, 6 test files moved, import updates in 5 consuming files.
- `SearchBackend` abstract interface stays in `dartclaw_core` — the sqlite3-free contract consumers program against.
- `MemoryEntry` data model stays in `dartclaw_core` — used by both core and storage.
- `dartclaw` umbrella re-exports both `dartclaw_core` and `dartclaw_storage` — zero breaking change for umbrella consumers.

### Package Structure After Split

```
packages/
  dartclaw/                   # Published umbrella — re-exports core + models + storage
  dartclaw_models/            # Published — zero-dep data types
  dartclaw_core/              # Published — harness, guards, channels, events, config. NO sqlite3
  dartclaw_storage/           # Published — sqlite3-backed: MemoryService, SearchDb, Fts5/QMD backends, MemoryPruner
  dartclaw_server/            # Published — reference implementation: HTTP API + web UI
apps/
  dartclaw_cli/               # Published — reference implementation: CLI app
```

### Files Moved to `dartclaw_storage`

| Source (dartclaw_core) | Destination (dartclaw_storage) |
|---|---|
| `lib/src/storage/memory_service.dart` | `lib/src/storage/memory_service.dart` |
| `lib/src/storage/search_db.dart` | `lib/src/storage/search_db.dart` |
| `lib/src/search/fts5_search_backend.dart` | `lib/src/search/fts5_search_backend.dart` |
| `lib/src/search/search_backend_factory.dart` | `lib/src/search/search_backend_factory.dart` |
| `lib/src/search/qmd_search_backend.dart` | `lib/src/search/qmd_search_backend.dart` |
| `lib/src/search/qmd_manager.dart` | `lib/src/search/qmd_manager.dart` |
| `lib/src/memory/memory_pruner.dart` | `lib/src/memory/memory_pruner.dart` |

### Verification

- `dart pub deps` on `dartclaw_core`: no sqlite3 (direct or transitive)
- `dart analyze` clean across all 4 packages + CLI app
- All tests pass: core (770), storage (64), server (444)

## Revision History

### 2026-03-12: All packages published + reference implementation model

**Superseded aspects of the original decision:**
- ~~`dartclaw_server` and `dartclaw_cli` use `publish_to: none`~~ → all packages will be published
- ~~Server and CLI are "not for external use"~~ → they are reference implementations, published for study, forking, and extension
- ~~Private packages coexist with published packages in the same repo~~ → all packages are published; proprietary extensions use separate private repos as overlays

**Preserved aspects (still valid):**
- Name-squat strategy and timeline
- `dartclaw` as prime namespace / umbrella package
- Pre-1.0 versioning convention
- Mono-repo structure
- Core/storage split rationale and execution
- `dartclaw_testing` deferred until consumer demand

**Relationship to ADR-014:** [ADR-014 (SDK Package Decomposition)](014-sdk-package-decomposition.md) refines this ADR's packaging strategy. ADR-014's barrel export narrowing strategy and decomposition trigger points remain valid — they apply to the SDK packages regardless of whether server/CLI are published. ADR-014's package table listing server/CLI as "Not published" is superseded by this revision; the barrel export strategy itself is not affected.

## References

- [ADR-014: SDK Package Decomposition](014-sdk-package-decomposition.md) — barrel narrowing, decomposition triggers
- [Dart package guidelines](../guidelines/DART-PACKAGE-GUIDELINES.md) — publishing checklist
- Dart pre-1.0 versioning: https://dart.dev/tools/pub/versioning
- Dart publishing (verified publisher flow): https://dart.dev/tools/pub/publishing
- Research sources are summarized in the linked research appendix.
