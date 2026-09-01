# ADR-008: SDK Publishing Strategy

**Status:** Accepted (revised 2026-03-12; narrowed 2026-08-06; client-tier-first 2026-08-20)
**Date:** 2026-03-01 (revised 2026-03-12, 2026-08-06, 2026-08-20)
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

The current `dartclaw_core` package is the source of the published API surface. For the namespace reservation, we publish it as `dartclaw`. If a core/storage split is warranted later (at 0.4), `dartclaw` becomes the convenience umbrella re-exporting `dartclaw_core` + `dartclaw_storage` — the same pattern `langchain` uses with `langchain_core`.

### Timeline: Namespace reservation now, real publish at 0.5

**We will publish `dartclaw` as `0.0.1-dev.1` immediately to establish pub.dev presence, with the first real release at `0.5.0` after security hardening and agent intelligence types are part of the API surface.**

Namespace reservation published 2026-03-01. Publisher transfer to verified publisher complete.

Originally planned for 0.4, but 0.5 is a better release point: it adds `InputSanitizer`, `MessageRedactor`, and `UsageTracker` to the public API — types that belong in an SDK. Publishing at 0.5 means a more complete API surface in the first real release, at the cost of ~1 milestone delay.

Pre-release dev versions are excluded from default dependency resolution — consumers must explicitly opt in via version constraint. This reduces (but does not eliminate) accidental adoption risk. The `genkit` ecosystem uses this exact `0.0.1-dev.N` pattern. Prereleases are immutable once published and remain visible on pub.dev — the README quality matters even for dev releases.

### Granularity: Single package now, evaluate split at 0.5

**We will publish `dartclaw` as a single package for the namespace reservation.** The core/storage split (separating sqlite3-dependent services into `dartclaw_storage`) is deferred to the SDK package split work and will be evaluated then — it may or may not be warranted depending on how the API evolves.

Investigation (2026-03-02) confirms clean split boundary: sqlite3 isolated to 2 files (`memory_service.dart`, `search_db.dart`), zero cross-imports from outside `storage/`+`search/`. Split is feasible with minimal refactoring.

If the split happens at 0.5:
- `dartclaw` — convenience umbrella re-exporting core + storage
- `dartclaw_core` — models, security, bridge, harness, channels, config. **No sqlite3.**
- `dartclaw_storage` — sqlite3-backed services (SessionService, MessageService, etc.)

If the split is not needed, `dartclaw` remains the single published package.

### All packages published (revised 2026-03-12; narrowed 2026-08-06)

> **Narrowed 2026-08-06** — the blanket "all packages will be published" claim below no longer holds. Publication intent is now per-package; `dartclaw_server` and `dartclaw_workflow` are undecided. See [Per-package publication intent](#per-package-publication-intent-2026-08-06).
>
> **Narrowed further 2026-08-20** — the publishable set is now the *client tier* only, and the runtime packages are deferred rather than "Planned". See [Client-tier-first publication](#client-tier-first-publication-2026-08-20).

~~The `publish_to: none` on `dartclaw_server` and `dartclaw_cli` signals "not for external use."~~ **Revised: all packages will be published**, including `dartclaw_server` and `dartclaw_cli`. This supersedes the original decision to keep server and CLI as internal-only.

`dartclaw_server` and `dartclaw_cli` are published as **reference implementations** — working, production-quality examples of how to compose DartClaw's SDK packages into a complete agent runtime. They serve multiple purposes:

- **Learning resource** — developers study the server and CLI to understand how to wire harness, guards, channels, events, and storage together
- **Fork-and-customize starting point** — developers can fork the server or CLI as a foundation for their own agent applications
- **Proof of pattern** — the server and CLI validate that DartClaw's abstractions actually compose into a working system
- **Dependency example** — they consume the same published SDK packages that external developers would, serving as living documentation of the consumption pattern

This aligns with DartClaw's "build your own agent" philosophy: the SDK packages (`dartclaw_core`, `dartclaw_models`, `dartclaw_storage`) are composable building blocks; the server and CLI are *one composition* of those blocks. Publishing them invites developers to build different compositions for their own use cases.

### Per-package publication intent (2026-08-06)

The 2026-03-12 revision asserted that every package ships to pub.dev. That is no longer the plan, and it had drifted out of sync with `docs/sdk/packages.md`, which labels four packages "Repo-only". Publication intent is per-package:

| Package | Intent | Note |
|---|---|---|
| `dartclaw` (umbrella), `dartclaw_core`, `dartclaw_models`, `dartclaw_storage`, `dartclaw_security`, `dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat` | **Planned** | Unchanged. The SDK surface external consumers depend on. |
| `dartclaw_workflow` | **Undecided** | Possible. Decide when the workflow API surface is stable enough to support externally. |
| `dartclaw_server` | **Undecided** | Possibly repo-only. The reference-implementation rationale above still argues for publishing; weigh it against supporting a large surface (HTTP + web UI + task runtime) as public API. |
| `dartclaw_cli`, `dartclaw_testing` | **Repo-only (leaning)** | Owner position 2026-08-06: publish a conservative core set first and keep these two repo-only. This supersedes the 2026-03-12 listing of `dartclaw_cli` as published. Stated as a leaning, not ratified — revisit before the first publish wave. |
| `dartclaw_config` | **Undecided** | Owner position 2026-08-06: possible. |

`publish_to: none` is currently set on every package and is a pre-publication placeholder, not a statement of intent — do not read it as evidence either way. It is removed per-package at first publish.

**Consequence for generated assets ([ADR-047](047-embedded-binary-assets.md))**: ADR-047 originally justified committing `embedded_assets.g.dart` with "pub.dev doesn't run generators; SDK consumers need them present" — a rationale that only holds for packages that ship. Since nothing is published today and both owning packages are undecided, ADR-047 was amended the same day: the generated libraries are now gitignored and emitted by the build. The publish-time requirement does not disappear — a published package must physically contain its generated library — so whichever of these two packages ships first must verify inclusion with `dart pub publish --dry-run` before its first release. See the ADR-047 amendment for the procedure.

### Client-tier-first publication (2026-08-20)

The 2026-08-06 table listed `dartclaw_core`, `dartclaw_storage`, `dartclaw_security` and the three channel packages as **Planned**. That was the wrong shape of promise: those packages are the *runtime*, and embedding the DartClaw runtime in a foreign process is not something the project can support at a pub.dev compatibility promise today. Meanwhile the surface external consumers actually use — a running server's HTTP API and SSE streams — had no package at all: the only client was buried in `apps/dartclaw_cli/lib/src/`, so every consumer had to fork the runtime or copy a file.

**Decision: publish the client tier first, and only the client tier.**

Two tiers, and only one of them is a product:

1. **Client tier** — `dartclaw_client` (HTTP + SSE transport, zero dependencies) and the `dartclaw` umbrella, which re-exports `dartclaw_client` plus `dartclaw_models`. This is the publishable set. A consumer holding a base URI and a token can drive a running server with no runtime package, no server package, and no DartClaw data directory.
2. **Fork the runtime** — everything else. Clone the repository, depend on `dartclaw_core` / `dartclaw_security` / `dartclaw_storage` by path, and own the fork. No publication, no compatibility promise.

There is deliberately no third "embeddable orchestration runtime" tier. It stays out until a real consumer asks for it; "fork the runtime" is the documented answer until then.

Revised publication intent, superseding the 2026-08-06 table:

| Package | Intent | Note |
|---|---|---|
| `dartclaw_client` | **Planned (first wave)** | The client tier. Zero dependencies by construction — no `dartclaw_*` package, nothing from pub — which is both its selling point and what keeps it free of build hooks and so `dart compile exe`-safe. |
| `dartclaw` (umbrella) | **Planned (first wave)** | Re-cut to the client tier: re-exports `dartclaw_client` and `dartclaw_models` only. It no longer re-exports `dartclaw_core`, `dartclaw_storage`, or the channel packages. |
| `dartclaw_models` | **Planned (first wave)** | The DTO types the endpoints carry. Reached through the umbrella; publishable in its own right. |
| `dartclaw_core`, `dartclaw_storage`, `dartclaw_security`, `dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat` | **Deferred** | Was "Planned". Fork-the-runtime tier: available in the repo, not shipped, no compatibility promise. Revisit when a consumer needs the runtime in-process and the surface is stable enough to support. |
| `dartclaw_workflow`, `dartclaw_server`, `dartclaw_config` | **Undecided** | Unchanged from 2026-08-06. |
| `dartclaw_cli`, `dartclaw_testing`, `dartclaw_bridge` | **Repo-only (leaning)** | Unchanged from 2026-08-06; `dartclaw_bridge` is the in-container bridge executable and joins the same category. |

**Breaking change for umbrella consumers**: `import 'package:dartclaw/dartclaw.dart'` no longer yields `AgentHarness`, `Guard`, `MemoryService`, or the channel types. Code that used the umbrella for runtime types depends on `dartclaw_core` (and `dartclaw_security` / `dartclaw_storage`) directly — which is what the four projects under `examples/sdk/` now do.

**Export-count ceilings retired.** The barrel export-count gates went with this change: `arch_check.dart`'s `L2 barrel export ceiling`, the `barrel_export_count_test.dart` fitness function and its allowlist, and `dartclaw_core`'s `barrel_export_test.dart`. They were sized for a world where the umbrella advertised the whole runtime; the umbrella now has two export lines and never had an allowlist entry. The cost is real and is recorded here rather than lost: `dartclaw_core`'s barrel sat at 100 allowlisted exports against a nominal 80 ceiling, and that ceiling was the only numeric gate on its public-surface growth. The replacement is the per-package downward-only LOC ceilings this milestone's package-topology work introduces (the runtime-rename and thin-CLI stories, S36/S37, own that gate), plus `barrel_show_clauses_test.dart`, which is retained: it enforces export *hygiene* (every export line carries a `show` clause) rather than a count, and is not what this change retires.

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

The repo is currently private. It does not need to be public for the namespace reservation — pub.dev accepts a `repository` URL that doesn't resolve yet. The repo should be made public before the first real publish at latest. When ready to publish, `publish_to: none` will be removed from all packages.

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

### B: Publish at 0.4 without reserving the namespace

- **Pros**: Balanced quality and timing; proven interfaces
- **Cons**: 3-4 months of pub.dev invisibility; misses early namespace positioning
- **Rejected because**: Namespace reservation captures positioning benefit at near-zero cost (weighted score 6.54 vs 7.51)

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

### Phase 1 — Namespace reservation ✅ (2026-03-01)

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

### 2026-08-20: Client-tier-first publication

**Superseded aspects of the 2026-08-06 revision:**
- ~~`dartclaw_core`, `dartclaw_storage`, `dartclaw_security` and the three channel packages are **Planned**~~ → **Deferred**; they are the fork-the-runtime tier, not a published product
- ~~The `dartclaw` umbrella re-exports the full SDK surface~~ → it re-exports the client tier only (`dartclaw_client` + `dartclaw_models`)

**Added:**
- `dartclaw_client` — the extracted HTTP/SSE transport, zero dependencies, first publish wave alongside the umbrella and `dartclaw_models`
- The export-count ceilings are retired; `barrel_show_clauses_test.dart` is retained

**Preserved aspects (still valid):**
- Per-package intent as the mechanism; `publish_to: none` as a placeholder that signals nothing
- Namespace reservation, versioning, mono-repo structure, the `dartclaw` umbrella as the prime namespace
- The ADR-047 generated-asset consequence

**Trigger:** the 0.25 packaging audit — every package `publish_to: none`, `docs/sdk/` conceding the strategy was unratified, and the umbrella re-exporting an incoherent surface — against the one consumer contract that was concrete: an external app composing typed DTOs and a client against a running `dartclaw serve`.

### 2026-08-06: Per-package publication intent

**Superseded aspects of the 2026-03-12 revision:**
- ~~All packages will be published~~ → intent is per-package; `dartclaw_server` and `dartclaw_workflow` are undecided
- ~~`publish_to: none` signals intent~~ → it is a pre-publication placeholder on every package and signals nothing

**Preserved aspects (still valid):**
- The reference-implementation rationale for publishing server/CLI — it remains the argument *for* shipping them, now weighed against public-API support cost rather than treated as settled
- Namespace reservation, umbrella package, versioning, mono-repo structure
- Everything in the 2026-03-12 revision not listed as superseded above

**Trigger:** `docs/sdk/packages.md` labels `dartclaw_server` and `dartclaw_workflow` "Repo-only", contradicting this ADR's blanket claim. Surfaced while auditing whether ADR-047's checked-in generated assets are still justified.

### 2026-03-12: All packages published + reference implementation model

**Superseded aspects of the original decision:**
- ~~`dartclaw_server` and `dartclaw_cli` use `publish_to: none`~~ → all packages will be published
- ~~Server and CLI are "not for external use"~~ → they are reference implementations, published for study, forking, and extension
- ~~Private packages coexist with published packages in the same repo~~ → all packages are published; proprietary extensions use separate private repos as overlays

**Preserved aspects (still valid):**
- Namespace reservation strategy and timeline
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

## Amendment (2026-08-21) – core absorbs storage

[ADR-056](056-package-topology-consolidation.md) supersedes the split that kept SQLite outside `dartclaw_core`.
`dartclaw_core` now owns the SQLite repositories, search backends, memory services and knowledge graph previously
packaged as `dartclaw_storage`; the runtime tier remains deferred from publication. The earlier `No sqlite3` rule and
its `dart pub deps` verification step are retired. Because `sqlite3` carries a native-asset build hook, a
`dart compile exe` target cannot live in core. The standalone, dependency-free bridge remains outside core, and S89
owns the corresponding ADR-051 amendment and binary proof.
