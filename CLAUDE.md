# Rules, Guidelines and Project Overview for Coding Agents — DartClaw Workspace

## Project Overview

**DartClaw** — An experimental, security-conscious AI agent runtime built with Dart. Dart orchestrator (AOT-compiled, zero npm) + multiple agent harnesses (Claude Code, Codex, and potentially more). Lineage: openclaw → nanoclaw → dartclaw.

Architecture: 2-layer model — Dart host (state/API/security) → agent harness binaries via control protocols. DartClaw is **multi-harness by design** — Claude Code (JSONL over stdin/stdout) and Codex (JSON-RPC) are both first-class primary harnesses; the `HarnessFactory` creates provider-specific harness instances, and the `HarnessPool` manages a heterogeneous pool of runners with different providers and security profiles. Each harness type has its own binary, protocol adapter, and native conventions.

### Philosophy
A ground-up agent runtime leveraging Dart's strengths. Guiding principles: security by design, security in depth, developer ergonomics, pragmatic lightweight architecture. DartClaw should not only be secure and efficient but also a joy to use and build upon.

### Design Philosophy

- **Minimal attack surface** — No Node.js/npm in the chain. Fewer dependencies = fewer supply chain vulnerabilities. Prefer capable standard libraries over third-party packages
- **Dart as host** — AOT-compiled native binary, complete built-in toolchain (formatter, analyzer, linter, test runner), capable stdlib. No external toolchain dependencies
- **Direct control protocol** — Dart spawns harness binaries (`claude`, `codex`) directly, no intermediate runtime. All state/storage/security lives in Dart
- **Outpost pattern** — purpose-built CLI tools in the best language for the job (Python for ML/NLP, etc.), invoked as subprocesses with structured JSON I/O. No shared runtime, no dependency contamination
- **Auditable** — codebase fits in a context window; dependencies stay minimal

### Repository Layout

This repo splits **end-user-facing** docs from **dev-workflow / contributor** material at the top level:

- `docs/` — end-user reference (`guide/`, `sdk/`). The user guide may legitimately link to `dev/tools/` paths where source-checkout instructions are unavoidable (e.g. `bash dev/tools/build.sh`); not everything users need is published-binary-only.
- `dev/` — contributor and agent working knowledge: state, guidelines, specs, testing profiles, build/CI tooling. Read by humans building from source as well as by AI agents driving workflows.

When in doubt, anything that isn't part of the published end-user reference belongs under `dev/`.

### Development Stage
Early experimental (soft-published). Breaking changes acceptable — correctness and clean design over backward compat. See `dev/state/PRODUCT.md`.

### Current State
See `dev/state/STATE.md` for current version, phase, active stories, blockers, and session continuity notes. (Canonical home is the public repo — see "Public Repo Mirror — Sync Rules" below.)

### Implemented Features

See `dev/state/STATE.md`. For an architecture overview, see `docs/guide/architecture.md` (full deep-dives live in the private repo).


### Package Structure (Dart pub workspace)

```
/
  packages/
    dartclaw/            # Published umbrella — re-exports core + storage + channel packages
    dartclaw_models/     # Shared data types and small cross-package enums/config DTOs
    dartclaw_security/   # Guard framework, classifiers, redaction, audit primitives
    dartclaw_config/     # Typed config loading, metadata, validation, and authoring utilities
    dartclaw_core/       # sqlite3-free runtime primitives: harnesses, channels, events, governance, file services
    dartclaw_storage/    # SQLite-backed repositories, search backends, pruning, trace/event stores
    dartclaw_workflow/   # Workflow definitions, registry, parser/validator, and execution engine
    dartclaw_whatsapp/   # WhatsApp channel integration
    dartclaw_signal/     # Signal channel integration
    dartclaw_google_chat/# Google Chat channel integration
    dartclaw_testing/    # Shared test doubles and fixtures for workspace packages
    dartclaw_server/     # HTTP API + HTMX web UI, task runtime, and container orchestration
  apps/
    dartclaw_cli/        # CLI app (AOT-compilable): serve, status, deploy, rebuild-index commands
```

Dart pub workspace — all packages resolve locally via `pubspec.yaml` workspace declaration.

### Package-Scoped Rules

Each `packages/<name>/` and `apps/<name>/` has an `AGENTS.md` (symlinked to a sibling `CLAUDE.md`) carrying package-specific conventions, gotchas, and internal architecture notes. The symlink convention assumes macOS/Linux — on Windows it requires `git config core.symlinks true`; without it, git materialises the file as a text stub rather than a real symlink.

**Before editing or creating files under `packages/<name>/` or `apps/<name>/`, read that directory's `AGENTS.md` first.** If a task spans multiple packages, repeat per package. Skip if you've already read it earlier in the session.

**Keep these files current.** When you change code in a package, update its `AGENTS.md` in the same edit if the change invalidates a fact there (new/removed boundary, renamed key file, changed convention, retired gotcha). Drift makes the file actively misleading — agents will follow stale rules. Treat updates as part of the change, not a follow-up.

Keep this root file lean — cross-cutting rules here, package-specific ones in the per-package files.


### Documentation Map

| Topic | Location | When to read |
|-------|----------|--------------|
| Getting started | `docs/guide/getting-started.md` | First setup |
| Configuration | `docs/guide/configuration.md` | Editing `dartclaw.yaml` |
| Workspace & behavior files | `docs/guide/workspace.md` | Customizing agent personality, safety rules, user context |
| Security & guards | `docs/guide/security.md` | Hardening, container setup, credential proxy |
| Deployment | `docs/guide/deployment.md` | LaunchDaemon, systemd, AOT compilation, production |
| Customization ladder | `docs/guide/customization.md` | L1 (behavior files) through L5 (Dart source) |
| Recipes | `docs/guide/recipes/` | Personal assistant, briefings, journaling, research, CRM, multi-user channel collaboration |
| WhatsApp channel | `docs/guide/whatsapp.md` | GOWA setup, pairing, access control |
| Signal channel | `docs/guide/signal.md` | signal-cli setup, registration |
| Google Chat channel | `docs/guide/google-chat.md` | GCP service account, Chat app setup |
| Tasks & orchestration | `docs/guide/tasks.md` | Background tasks, review workflow, coding tasks |
| Scheduling | `docs/guide/scheduling.md` | Heartbeat, cron jobs |
| Search & memory | `docs/guide/search.md` | FTS5/QMD search, memory consolidation |
| SDK quick start | `docs/sdk/quick-start.md` | Building on DartClaw programmatically |
| Package guide | `docs/sdk/packages.md` | Which package to depend on |
| Example configs | `examples/` | dev, production, personal-assistant presets |
| Architecture | `docs/guide/architecture.md` | Understanding the 2-layer model |
| Full guide index | `docs/guide/README.md` | Everything else |


---


## Project Document Index

Internal development docs for working on DartClaw itself (as opposed to using it).

<!-- AndThen-style index — workflow commands and the discover-project skill read this table to determine where to find and write project documents. -->

| Topic | Location | When to read |
|-------|----------|--------------|
| Current state | `dev/state/STATE.md` | Check what's in flight before starting work |
| Learnings | `dev/state/LEARNINGS.md` | Before debugging unfamiliar subsystems; append non-obvious discoveries |
| Product (summary) | `dev/state/PRODUCT.md` | Vision and principles |
| Roadmap (current + next) | `dev/state/ROADMAP.md` | Active milestone and what's after |
| Tech stack | `dev/state/STACK.md` | Languages, packages, external services |
| Ubiquitous language | `dev/state/UBIQUITOUS_LANGUAGE.md` | Domain glossary — use these terms in code, docs, naming |
| Tech debt backlog | `dev/state/TECH-DEBT-BACKLOG.md` | Known debt requiring requirements input or architecture decision |
| Spec lifecycle | `dev/state/SPEC-LIFECYCLE.md` | When `dev/specs/` files appear or disappear |
| Specs (active milestone) | `dev/specs/<version>/` | PRD/plan/FIS for the in-flight milestone — transient on the feature branch, removed before squash-merge |
| Changelog | `CHANGELOG.md` | Shipped history per release |
| Built-in workflows | `dev/tools/dartclaw-workflows/README.md` (+ § below) | Running shipped workflows against this checkout |
| Dart style | `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` | Before writing Dart |
| Package boundaries | `dev/guidelines/DART-PACKAGE-GUIDELINES.md` | When touching pubspec or workspace packages |
| HTMX patterns | `dev/guidelines/HTMX-GUIDELINES.md` | Before writing web UI fragments |
| Trellis templates | `dev/guidelines/TRELLIS-GUIDELINES.md` | Before writing templates |
| Testing strategy | `dev/guidelines/TESTING-STRATEGY.md` | Before writing tests |
| Key dev commands | `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` | Before/after modifying code |


---


## Built-in DartClaw Workflows

DartClaw ships three end-to-end YAML workflows — `spec-and-implement`, `plan-and-implement`, `code-review` — in `packages/dartclaw_workflow/lib/src/workflow/definitions/`, executed by `WorkflowExecutor`. They are **not** wrappers around `andthen:*` plugin skills: they orchestrate the **`dartclaw-*` skill namespace** (`dartclaw-prd`, `dartclaw-plan`, `dartclaw-exec-spec`, …) — a distinct surface. Never assume `dartclaw-foo` and `andthen:foo` are interchangeable.

`plan-and-implement` short-circuits PRD/plan/FIS synthesis when artefacts already exist under `dev/specs/<version>/` — this is also the cross-repo handoff seam (see `dev/state/SPEC-LIFECYCLE.md`).

To run from this checkout: `dev/tools/dartclaw-workflows/run.sh` — see `dev/tools/dartclaw-workflows/README.md` for the full surface (workflow inventory, injected variables, worktree isolation, AOT host isolation, escape hatches). The profile is intentionally maintainer-permissive (Codex `sandbox: danger-full-access`, `approval: never`, auto-accept) — **not** a hardened operator profile. Engine internals: `packages/dartclaw_workflow/CLAUDE.md`.


---


## Rules, Guardrails and Guidelines

### Foundational Rules and Guardrails
Adhere to system prompt "CRITICAL RULES and GUARDRAILS" before doing any work.

### Vital Conventions
- Lean dependencies — only what's needed per package
- Single-threaded (add isolates only if profiling shows bottleneck)
- Vendored third-party assets (e.g. highlight.js) live in `packages/dartclaw_server/lib/src/static/` — see `VENDORS.md` in that directory for versions and upgrade instructions
- Never use references to specific story IDs or titles in code, filenames, documentation etc (project/development documents are the exception).
- **Comments — rationale only, never narration.**
  - **Public API** (members re-exported via a package's barrel or otherwise meant for downstream consumers) gets dartdoc that documents the *contract*: behavior, throws, non-obvious preconditions. Don't document consumer behavior or call-site context — that rots independently.
  - **Internal code** (`lib/src/`, private members, inline `//`) defaults to *none*. Write only when a reader would otherwise miss a hidden constraint, invariant, or workaround. Never restate the WHAT.
  - **Drift is worse than absence.** Wrong or outdated comments must be fixed or deleted on sight.
  - **Forbidden patterns**: `// REMOVED …` / `// was: …` markers, references to transient planning artifacts (story IDs, sprint/wave labels, current-PR numbers — those belong in commits and PR descriptions; durable refs like ADRs and TODO issue links are fine), `// TODO` without an owner or issue link, multi-paragraph docstrings on internal helpers.
  - See `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` § Proportionality & Anti-Rot for the full ruleset (also covers control-flow restatement and identifier paraphrasing).
- **Tech debt backlog discipline** — `dev/state/TECH-DEBT-BACKLOG.md` is reserved for items that **cannot** be resolved directly without further requirements input or an architecture decision. If a finding can be fixed now with the current understanding, fix it now (or capture it in an active spec/FIS). The backlog is a last resort, not a default landing zone for follow-ups — entries that just describe known cleanups invite rot and dilute signal.

### Timestamps
**Always** run `date '+%Y-%m-%d %H:%M %Z'` before writing timestamps. Never guess — internal time may be wrong timezone.

### Development Guidelines
Read relevant guidelines before coding, architecture, UX/UI, or review work:

- _`~/.claude/plugins/marketplaces/andthen/docs/guidelines/DEVELOPMENT-ARCHITECTURE-GUIDELINES.md`_ when doing development work (coding, architecture, etc.)
- _`~/.claude/plugins/marketplaces/andthen/docs/guidelines/UX-UI-GUIDELINES.md`_ when doing UX/UI related work
- _`~/.claude/plugins/marketplaces/andthen/docs/guidelines/WEB-DEV-GUIDELINES.md`_ when doing web development work
- _`dev/guidelines/DART-EFFECTIVE-GUIDELINES.md`_ — Effective Dart: style, documentation, usage, API design, async, error handling, Dart 3.x features, linter config
- _`dev/guidelines/DART-PACKAGE-GUIDELINES.md`_ — Package creation: structure, pubspec, versioning, pub.dev scoring, publishing workflow, automated publishing
- _`dev/guidelines/HTMX-GUIDELINES.md`_ — HTMX usage patterns, attributes, server-side rendering best practices, streaming updates, error handling, security considerations
- _`dev/guidelines/TRELLIS-GUIDELINES.md`_ — Trellis template usage, escaping rules, fragment patterns, integration with HTMX, security best practices
- _`dev/guidelines/TESTING-STRATEGY.md`_ — Test philosophy, four-layer pyramid, async patterns, coverage guidance, shared fakes, anti-patterns. **Read before writing tests**


---


## Visual Validation Workflow

The `andthen:visual-validation` skill auto-reads this `## Visual Validation Workflow` section first; follow the linked references.

- `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` — full conventions for visual validation
- `dev/testing/UI-SMOKE-TEST.md` — test cases TC-01…TC-31. Run via `bash dev/testing/profiles/smoke-test/run.sh`. Trigger: _"Run the UI smoke test"_


---


## Release Preparation

Run `bash dev/tools/release_check.sh` before tagging — it runs the automated gates as one command: `dev/specs/` cleanup (must be empty; see `dev/state/SPEC-LIFECYCLE.md`), version pin lockstep (`check_versions.sh`), `dart format --set-exit-if-changed`, `dart analyze --fatal-warnings --fatal-infos`, and `dart test`. Use `--quick` to skip the test suite during iteration. The script's manual gates (still required before tagging) are:
- `dart test -t integration`
- UI smoke test: `bash dev/testing/profiles/smoke-test/run.sh` (requires a running dev server)

Then bump in a single commit:
- `dartclawVersion` in `packages/dartclaw_server/lib/src/version.dart`
- **every** publishable `packages/*/pubspec.yaml` `version:` field plus `apps/dartclaw_cli/pubspec.yaml` (lockstep — see `dev/guidelines/DART-PACKAGE-GUIDELINES.md` § Workspace-Wide Versioning Policy)
- CHANGELOG, `dev/state/STATE.md`, `dev/state/ROADMAP.md`, "Current through" markers in docs

### Release sequence (squash-merge pattern)

1. **Scope-frozen** commit on `feat/<version>` — final version pins, CHANGELOG entry, STATE.md says "release-ready, awaiting tag". Run `release_check.sh` here; manual gates pass.
2. **Squash-merge** to `main` with the release-style message; that commit *is* the release.
3. **Tag** annotated `v<version>` from the squash commit; push tag.
4. **Delete remote** feature branch (keep local as archive if useful).
5. **Branch `feat/<next>`** from the squash commit; first work-in-flight commit there flips STATE.md / ROADMAP.md to mark the previous version as tagged and open the new milestone as Active. No bookkeeping commit is needed on `main` itself — the tag is the source of truth for "released."


---


## Key Development Commands
See `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` — read before/after modifying code.

For local development only, if `dart test` is blocked by `package:sqlite3` failing to codesign its bundled native asset inside `.dart_tool/`, it is acceptable to temporarily point sqlite hooks at the host system library with an uncommitted `pubspec.yaml` edit:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: system
```

This is an escape hatch for local iteration, not the canonical verification path. Do not commit it as the default, and verify the host SQLite build supports the required features (at minimum FTS5) before trusting test results.

#### Example configs
Quick start: `bash examples/run.sh` — defaults to `dev.yaml` (no auth, guards off), stores data in `.dartclaw-dev/`.
Specify a config: `bash examples/run.sh production --port 8080`


---


## Vital External Documentation Resources
- **Dart** — https://dart.dev/guides — Language reference, core libraries, effective Dart
- **Claude Code CLI** — https://code.claude.com/docs/en/headless — JSONL control protocol reference (stream-json format)
- **sqlite3 (Dart)** — https://pub.dev/packages/sqlite3 — Raw SQLite bindings (search index only, no ORM)
- **HTMX** — https://htmx.org/docs/ — Web UI attribute reference

**IMPORTANT**: Always delegate documentation lookups to a background _`andthen:documentation-lookup`_ sub-agent — keep the main context window clean.


---


## Useful Tools and MCP Servers

### Command line file search and code exploration tools
- **ripgrep (rg)**: Fast recursive search. Example: `rg "createServerSupabaseClient"`. _Use instead of grep_ for better search performance.
- **ast-grep**: Search by AST node types. Example: `ast-grep 'import { $X } from "supabase"' routes/`
- **tree**: Directory structure visualization. Example: `tree -L 2 routes/`

### Context7 MCP / Fetch MCP
Both used **only** via the _`andthen:documentation-lookup`_ sub-agent. Context7 fetches version-specific library docs; Fetch converts web pages to markdown.

### Dart MCP Server — NOT USED
Not active. Use Bash for Dart CLI commands (see `KEY_DEVELOPMENT_COMMANDS.md`). For pub.dev searches, use the JSON API.

### Dart LSP Plugin (`https://github.com/tolo/coding-agent-toolkit/tree/main/plugins/dart-lsp`)
Spawns `dart language-server` — diagnostics, hover, goToDefinition, findReferences, call hierarchy across workspace packages. 
**Fix all diagnostics immediately** — run `dart analyze` before declaring work done.

### Visual Validation & UI Testing

**Agent Browser** — `agent-browser` skill. Core: `open <url>` → `snapshot -i` → `click @e1` / `fill @e2 "text"` → re-snapshot.

**Chrome DevTools MCP** — `chrome-devtools` skill. Deeper inspection, JS execution, debugging.
