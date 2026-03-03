# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**DartClaw** — Security-hardened agent runtime. Dart orchestrator (AOT-compiled, zero npm) + native Claude Code CLI (Bun standalone binary, zero Node.js). Lineage: openclaw → nanoclaw → dartclaw.

Architecture: 2-layer model — Dart host (state/API/security) → native `claude` binary (agent harness via JSONL control protocol). Dart spawns the `claude` binary as a subprocess, communicating via bidirectional JSONL over stdin/stdout.

## Design Philosophy

- **Minimal attack surface** — No Node.js/npm in the chain. Fewer dependencies = fewer supply chain vulnerabilities. Prefer capable standard libraries over third-party packages
- **Dart as host** — AOT-compiled native binary, complete built-in toolchain (formatter, analyzer, linter, test runner), capable stdlib. No external toolchain dependencies
- **Direct control protocol** — Dart spawns the native `claude` binary directly, no intermediate runtime. All state/storage/security lives in Dart
- **Outpost pattern** — purpose-built CLI tools in the best language for the job (Python for ML/NLP, etc.), invoked as subprocesses with structured JSON I/O. No shared runtime, no dependency contamination
- **Auditable** — codebase fits in a context window; dependencies stay minimal

## Package Structure (Dart pub workspace)

```
packages/
  dartclaw_core/       # Shared lib: file-based storage, search index (raw sqlite3), control protocol,
                       # models, services. No Flutter deps — shareable with future Flutter app
  dartclaw_server/     # HTTP API + HTMX web UI (shelf). Server-only, not Flutter-compatible
apps/
  dartclaw_cli/        # CLI app (AOT-compilable): chat REPL, serve, status commands
```

## Key Architecture Patterns

- **Cursor-based crash recovery**: Messages in NDJSON files use line number as cursor — "give me all messages after cursor X" for resuming after crashes
- **JSONL control protocol**: Dart↔claude binary communication via bidirectional JSONL over stdin/stdout. Dart sends user messages + control responses, claude sends stream events + control requests (tool approval, hook callbacks, MCP messages)
- **Filesystem IPC**: JSON files with atomic writes (temp file + rename) for agent→host communication when containerized
- **Two-tier privilege model**: Main group = admin, other groups = sandboxed with per-group isolation
- **Trellis HTML templates**: `.html` files in `packages/dartclaw_server/lib/src/templates/` using `tl:text` for auto-escaping and `tl:utext` for trusted HTML. Inline Dart string constants with `tl:fragment` for fragment-based rendering. HTMX + SSE for streaming, zero JS build toolchain
- **SSE streaming**: Implemented directly in shelf (`Response.ok(eventStream, headers: {'Content-Type': 'text/event-stream'})`)

## Security Model (Core Principle)

Defense-in-depth: OS-level isolation + application-level SDK features:
- Docker container isolation (kernel namespaces, `network:none` + Dart proxy) — primary boundary
- Credential isolation — API keys injected via credential proxy on Unix socket (never in container env)
- SDK hooks — `PreToolUse`/`PostToolUse` for bash sanitization, audit logging
- External mount allowlist (never exposed to agent)
- Symlink resolution + blocked patterns (`.ssh`, `.aws`, credentials)

## Documentation

### User Guide
- `docs/guide/` — getting started, architecture, configuration, workspace, security, WhatsApp, scheduling, search, deployment, customization, web UI & API reference.

### Technical Backlog
Deferred issues, tech debt, and improvement items: see `docs/TECH-DEBT-BACKLOG.md` in the parent (private) repository.

## Conventions

- Lean dependencies — only what's needed per package (see dependency matrix in plan)
- Control protocol: Bidirectional JSONL over stdin/stdout for Dart↔claude binary communication
- Storage: file-based (NDJSON + JSON) for sessions/messages/kv; raw `sqlite3` for search index only (ADR-002)
- Memory search: FTS5 default; QMD hybrid search opt-in (`search.backend: qmd` in config)
- In-memory SQLite for search index tests; temp directories for file-based service tests
- Single-threaded (add isolates only if profiling shows bottleneck)
- CLI via `package:args`, HTTP via `package:shelf`
- Vendored third-party assets (e.g. highlight.js) live in `packages/dartclaw_server/lib/src/static/` — see `VENDORS.md` in that directory for versions and upgrade instructions


---


## Vital Documentation Resources
- **Dart** — https://dart.dev/guides — Language reference, core libraries, effective Dart
- **Claude Code CLI** — https://code.claude.com/docs/en/headless — JSONL control protocol reference (stream-json format)
- **sqlite3 (Dart)** — https://pub.dev/packages/sqlite3 — Raw SQLite bindings (search index only, no ORM)
- **HTMX** — https://htmx.org/docs/ — Web UI attribute reference

**IMPORTANT**: When lookup of documentation (such as API documentation, user guides, language references, etc.) is needed, or when user asks to lookup documentation directly, _always_ execute the documentation lookup in a separate background sub task (use the _`cc-workflows:documentation-lookup`_ agent). This is **CRITICAL** to reduce the load on the main context window and ensure that the main agent can continue working without interruptions.


---


## Useful Tools and MCP Servers

### Command line file search and code exploration tools
- **ripgrep (rg)**: Fast recursive search. Example: `rg "createServerSupabaseClient"`. _Use instead of grep_ for better search performance.
- **ast-grep**: Search by AST node types. Example: `ast-grep 'import { $X } from "supabase"' routes/`
- **tree**: Directory structure visualization. Example: `tree -L 2 routes/`

### Context7 MCP - Library and Framework Documentation Lookup (https://github.com/upstash/context7)
Context7 MCP pulls up-to-date, version-specific documentation and code examples straight from the source.
**Only** use Context7 MCP via the _`cc-workflows:documentation-lookup`_ sub-agent for documentation retrieval tasks.

### Fetch (https://github.com/modelcontextprotocol/servers/tree/main/src/fetch)
Retrieves and processes content from web pages, converting HTML to markdown for easier consumption.
**Only** use Fetch MCP via the _`cc-workflows:documentation-lookup`_ sub-agent for documentation retrieval tasks.

### Dart and Flutter MCP Server (https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)
The Dart Tooling MCP Server exposes Dart and Flutter development tool actions to compatible AI-assistant clients.
Contains tools such as `pub`, `run_tests`, `dart_format`, `dart_fix` etc.

### Dart LSP Plugin (`.claude/plugins/dart-lsp/`)

Project-scoped LSP plugin that spawns `dart language-server` (Dart analysis server). Provides real-time code intelligence **complementing** the Dart MCP server (`mcp__dart__*` tools). Instant diagnostics after edits, hover/type info, goToDefinition, findReferences, call hierarchy — resolves symbols across pub workspace package boundaries.

**Analyzer hygiene**: When the LSP reports diagnostics (errors, warnings, lints) on files you're editing, fix them immediately — don't leave analyzer issues behind. Run `dart analyze` on affected packages to verify clean output before declaring work done.

### MCP Servers for visual validation and UI testing/exploration
Use the `chrome-devtools` for visual validation and UI testing/exploration.


---


## Visual Validation Workflow
- **`docs/guidelines/VISUAL-VALIDATION-WORKFLOW.md`** — project-specific conventions: server setup, auth, chrome-devtools usage, viewports, screenshot naming, report format. Read by `cc-workflows:visual-validation-specialist` automatically.
- **`docs/testing/UI-SMOKE-TEST.md`** — concrete numbered test cases (TC-01…TC-18) with steps and pass/fail criteria. Run this to smoke-test core UI functionality.

To trigger a full smoke test: _"Run the UI smoke test"_ or _"smoke test the web UI"_.


---


## Key Development Commands

See `<repository_root>/docs/guidelines/KEY_DEVELOPMENT_COMMANDS.md` for key commands related to development, running, deployment, testing, formatting, linting, and UI testing.

**Always** read this file before or after modifying code, to make sure you use the correct commands.


---
