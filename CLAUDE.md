# Rules, Guidelines and Project Overview for Coding Agents — DartClaw Workspace

## Project Overview

**DartClaw** — An experimental, security-conscious AI agent runtime built with Dart. Dart orchestrator (AOT-compiled, zero npm) + multiple agent harnesses (Claude Code, Codex, and potentially more). Lineage: openclaw → nanoclaw → dartclaw.

Architecture: 2-layer model — Dart host (state/API/security) → agent harness binaries via control protocols. The primary harness is the native `claude` binary (JSONL over stdin/stdout), but DartClaw is **multi-harness by design** — the `HarnessFactory` creates provider-specific harness instances, and the `HarnessPool` manages a heterogeneous pool of runners with different providers and security profiles. Each harness type has its own binary, protocol adapter, and native conventions.

### Philosophy
A ground-up agent runtime leveraging Dart's strengths. Guiding principles: security by design, security in depth, developer ergonomics, pragmatic lightweight architecture. DartClaw should not only be secure and efficient but also a joy to use and build upon.

### Design Philosophy

- **Minimal attack surface** — No Node.js/npm in the chain. Fewer dependencies = fewer supply chain vulnerabilities. Prefer capable standard libraries over third-party packages
- **Dart as host** — AOT-compiled native binary, complete built-in toolchain (formatter, analyzer, linter, test runner), capable stdlib. No external toolchain dependencies
- **Direct control protocol** — Dart spawns the native `claude` binary directly, no intermediate runtime. All state/storage/security lives in Dart
- **Outpost pattern** — purpose-built CLI tools in the best language for the job (Python for ML/NLP, etc.), invoked as subprocesses with structured JSON I/O. No shared runtime, no dependency contamination
- **Auditable** — codebase fits in a context window; dependencies stay minimal

### Development Stage
Early experimental (soft-published). Breaking changes acceptable — correctness and clean design over backward compat. See `docs/PRODUCT.md`.

### Current State
See `/docs/dev/STATE.md` for current version, phase, active stories, blockers, and session continuity notes. (Canonical home is the public repo — see "Public Repo Mirror — Sync Rules" below.)

### Implemented Features

See `/docs/dev/STATE.md`

> For architecture details, see the 12 deep-dive docs in `docs/architecture/`.


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
| Current state | `docs/dev/STATE.md` | Check what's in flight before starting work |
| Learnings | `docs/dev/LEARNINGS.md` | Before debugging unfamiliar subsystems; append non-obvious discoveries |
| Product (summary) | `docs/dev/PRODUCT.md` | Vision and principles |
| Roadmap (current + next) | `docs/dev/ROADMAP.md` | Active milestone and what's after |
| Tech stack | `docs/dev/STACK.md` | Languages, packages, external services |
| Ubiquitous language | `docs/dev/UBIQUITOUS_LANGUAGE.md` | Domain glossary — use these terms in code, docs, naming |
| Tech debt backlog | `docs/dev/TECH-DEBT-BACKLOG.md` | Known debt requiring requirements input or architecture decision |
| Spec lifecycle | `docs/dev/SPEC-LIFECYCLE.md` | When `docs/specs/` files appear or disappear |
| Dart style | `docs/guidelines/DART-EFFECTIVE-GUIDELINES.md` | Before writing Dart |
| Package boundaries | `docs/guidelines/DART-PACKAGE-GUIDELINES.md` | When touching pubspec or workspace packages |
| HTMX patterns | `docs/guidelines/HTMX-GUIDELINES.md` | Before writing web UI fragments |
| Trellis templates | `docs/guidelines/TRELLIS-GUIDELINES.md` | Before writing templates |
| Testing strategy | `docs/guidelines/TESTING-STRATEGY.md` | Before writing tests |
| Key dev commands | `docs/guidelines/KEY_DEVELOPMENT_COMMANDS.md` | Before/after modifying code |


---


## Rules, Guardrails and Guidelines

### Foundational Rules and Guardrails
Adhere to system prompt "CRITICAL RULES and GUARDRAILS" before doing any work.

### Conventions
- Lean dependencies — only what's needed per package
- Single-threaded (add isolates only if profiling shows bottleneck)
- Vendored third-party assets (e.g. highlight.js) live in `packages/dartclaw_server/lib/src/static/` — see `VENDORS.md` in that directory for versions and upgrade instructions
- Never use references to specific story IDs or titles in code, filenames, documentation etc (project/development documents are the exception).
- **Code is source of truth, not comments**: To avoid documentation rot, keep code documentation/comments minimal and focused on rationale (why, not what). If comments are outdated or incorrect, fix or remove them — do not let them mislead. Always strive for self-explanatory and readable code that minimizes (or eliminates) the need for comments.
- **Tech debt backlog discipline** — `docs/dev/TECH-DEBT-BACKLOG.md` is reserved for items that **cannot** be resolved directly without further requirements input or an architecture decision. If a finding can be fixed now with the current understanding, fix it now (or capture it in an active spec/FIS). The backlog is a last resort, not a default landing zone for follow-ups — entries that just describe known cleanups invite rot and dilute signal.

### Timestamps
**Always** run `date '+%Y-%m-%d %H:%M %Z'` before writing timestamps. Never guess — internal time may be wrong timezone.

### Development Guidelines
Read relevant guidelines before coding, architecture, UX/UI, or review work:

- _`~/.claude/plugins/marketplaces/andthen/docs/guidelines/DEVELOPMENT-ARCHITECTURE-GUIDELINES.md`_ when doing development work (coding, architecture, etc.)
- _`~/.claude/plugins/marketplaces/andthen/docs/guidelines/UX-UI-GUIDELINES.md`_ when doing UX/UI related work
- _`~/.claude/plugins/marketplaces/andthen/docs/guidelines/WEB-DEV-GUIDELINES.md`_ when doing web development work
- _`docs/guidelines/DART-EFFECTIVE-GUIDELINES.md`_ — Effective Dart: style, documentation, usage, API design, async, error handling, Dart 3.x features, linter config
- _`docs/guidelines/DART-PACKAGE-GUIDELINES.md`_ — Package creation: structure, pubspec, versioning, pub.dev scoring, publishing workflow, automated publishing
- _`docs/guidelines/HTMX-GUIDELINES.md`_ — HTMX usage patterns, attributes, server-side rendering best practices, streaming updates, error handling, security considerations
- _`docs/guidelines/TRELLIS-GUIDELINES.md`_ — Trellis template usage, escaping rules, fragment patterns, integration with HTMX, security best practices
- _`docs/guidelines/TESTING-STRATEGY.md`_ — Test philosophy, four-layer pyramid, async patterns, coverage guidance, shared fakes, anti-patterns. **Read before writing tests**


---


## Visual Validation Workflow

- `docs/guidelines/VISUAL-VALIDATION-WORKFLOW.md` — conventions for visual validation (auto-read by `andthen:visual-validation-specialist`)
- `docs/testing/UI-SMOKE-TEST.md` — test cases TC-01…TC-18. Trigger: _"Run the UI smoke test"_


---


## Release Preparation

Before tagging: all tests (incl. `-t integration`), `dart analyze` (zero warnings), format check, UI smoke test.
Then bump `dartclawVersion`, update CHANGELOG, `STATE.md`, `ROADMAP.md`, "Current through" markers in docs.


---


## Key Development Commands
See `docs/guidelines/KEY_DEVELOPMENT_COMMANDS.md` — read before/after modifying code.

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
