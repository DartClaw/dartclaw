# DartClaw — Codex Agent Context

## Project Overview

**DartClaw** — Security-focused AI agent runtime. Dart orchestrator (AOT-compiled, zero npm) + native Claude Code CLI (Bun standalone binary). Architecture: Dart host (state/API/security) → native `claude` binary (agent harness via JSONL control protocol).

**Current milestone**: DartClaw 0.9 — Package Decomposition + SDK Publish-Readiness + Channel-to-Task Integration.

## Two-Repo Workspace

| Repo | Path | Contents |
|------|------|----------|
| **dartclaw-public** (THIS repo) | `/Users/tobias/Repos/Libs/dartclaw/dartclaw-public/` | Application code (Dart pub workspace) |
| **dartclaw-private** | `/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/` | Specs, PRDs, ADRs, architecture docs, FIS files |

**IMPORTANT**: All Feature Implementation Specifications (FIS) live in:
`/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/specs/0.9/fis/`

Always use **absolute paths** when referencing FIS files from this repo context.

## Package Structure (Dart pub workspace)

```
packages/
  dartclaw/            # Published umbrella — re-exports dartclaw_core + dartclaw_models + dartclaw_storage
  dartclaw_core/       # Shared lib: security, bridge, harness, channels, config, memory, behavior
  dartclaw_models/     # Pure data classes: Session, Message, MemoryChunk, SessionKey. Zero deps
  dartclaw_storage/    # SQLite3-backed services: memory storage, search index, memory pruning
  dartclaw_server/     # HTTP API + HTMX web UI (shelf). Server-only, not Flutter-compatible
apps/
  dartclaw_cli/        # CLI app: serve, status, deploy commands
```

**New packages being created in 0.9 Phase A**:
- `packages/dartclaw_security/` — Extract guard framework from dartclaw_core
- `packages/dartclaw_whatsapp/` — Extract WhatsApp channel from dartclaw_core
- `packages/dartclaw_signal/` — Extract Signal channel from dartclaw_core
- `packages/dartclaw_google_chat/` — Extract Google Chat channel from dartclaw_core

## Key Development Commands

```bash
# Run all tests in a package
dart test packages/dartclaw_core

# Run tests across entire workspace
dart test

# Analyze a package
dart analyze packages/dartclaw_core

# Analyze entire workspace
dart analyze

# Format code
dart format packages/dartclaw_core/lib

# Get dependencies
dart pub get

# Run the server
dart run dartclaw_cli:dartclaw serve --port 3333
```

## Architecture

- **Design philosophy**: Minimal attack surface, single-threaded, AOT-compilable, no Node.js/npm
- **Control protocol**: Bidirectional JSONL over stdin/stdout (Dart↔claude binary)
- **Storage**: File-based (NDJSON + JSON) for sessions/messages/kv in `dartclaw_core`; raw `sqlite3` for search index in `dartclaw_storage`
- **Templates**: Trellis HTML templates in `dartclaw_server/lib/src/templates/` (Dart string interpolation with `tl:text`/`tl:utext`)
- **Security model**: Defense-in-depth: OS-level isolation + application-level SDK features

## Key Architecture Documents (in private repo)

- System architecture: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/architecture/system-architecture.md`
- Security architecture: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/architecture/security-architecture.md`
- Data model: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/architecture/data-model.md`
- Control protocol: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/architecture/control-protocol.md`

## PRD and Plan (in private repo)

- PRD: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/specs/0.9/prd.md`
- Plan: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/specs/0.9/plan.md`
- Decomposition research: `/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/research/sdk-package-decomposition/decomposition-synthesis-2026-03-12.md`

## Conventions

- Dart effective style: see `/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/guidelines/DART-EFFECTIVE-GUIDELINES.md`
- Lean dependencies — only what's needed per package
- `dartclaw_core`: NO sqlite3, NO server-only deps (must be shareable with future Flutter app)
- `dartclaw_storage`: SQLite3 is OK here
- `dartclaw_server`: HTTP, shelf, HTMX web UI
- Single-threaded (add isolates only if profiling shows bottleneck)
- All packages use `publish_to: none` for now (publish decision is separate)

## 0.9 Phase A: Package Decomposition (current work)

The primary goal of Phase A is to extract subsystems from `dartclaw_core` into separate packages:

1. **S01** (foundation): Break config↔channel circular dependency via `ChannelConfigProvider` interface
2. **S06** (parallel): Move leaf services (behavior/, workspace/, maintenance/, observability/) to dartclaw_server
3. **S02** (after S01): Extract guard framework → `dartclaw_security`
4. **S03, S04, S05** (parallel after S01): Extract channel packages
5. **S07** (after S02-S06): Wire umbrella, update pubspecs, fix barrel exports
6. **S08** (after S07): Full test suite verification + architecture doc updates
7. **S09** (after S08, Tier 2): dartclaw_config, extension points, dartclaw_testing

## FIS Implementation Notes

After implementing a story, update:
`/Users/tobias/Repos/Libs/dartclaw/dartclaw-private/docs/specs/fis-implementation-notes.md`

## Workflow Rules

- Always run `dart analyze` after making changes — fix all errors and warnings
- Run `dart test` to verify tests pass
- Follow existing naming conventions, patterns, and file organization
- When creating new packages: create `pubspec.yaml`, `lib/<package_name>.dart` barrel, `lib/src/` directory structure, `test/` directory
- Pub workspace: add new packages to root `pubspec.yaml` workspace list
- Never skip tests — fix them if they break during refactoring
