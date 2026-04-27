# Technology Stack

## Languages

| Language | Version | Notes |
|----------|---------|-------|
| Dart | `^3.11.0` | AOT-compiled host runtime. Built-in formatter, analyzer, test runner |

## Dart SDK Packages

> Version constraints are in each package's `pubspec.yaml`. See `packages/` at the repo root.

### Core

| Package | Purpose |
|---------|---------|
| `stream_channel` | Bidirectional communication channels (JSONL bridge) |
| `uuid` | Session and entity UUID generation |
| `collection` | Collection utilities |
| `logging` | Structured logging framework |
| `meta` | Annotation metadata |
| `path` | Platform-independent path utilities |
| `yaml` | YAML config parsing |
| `yaml_edit` | YAML round-trip editing (preserves comments) |

### Server

| Package | Purpose |
|---------|---------|
| `shelf` | HTTP server framework |
| `shelf_router` | Declarative routing |
| `shelf_static` | Static file serving |
| `http` | HTTP client (outbound API calls) |
| `crypto` | Hashing, HMAC (webhook verification) |
| `dart_jsonwebtoken` | JWT creation and verification |
| `trellis` | HTML template engine (`tl:text` auto-escaping, `tl:fragment` partials) |
| `qr` | QR code generation (WhatsApp/Signal pairing) |
| `html2md` | HTML to Markdown conversion |

### Storage

| Package | Purpose |
|---------|---------|
| `sqlite3` | Raw SQLite3 bindings — search index (FTS5), tasks, state. No ORM |

### Google Chat

| Package | Purpose |
|---------|---------|
| `googleapis_auth` | Google Cloud service account authentication |

### CLI

| Package | Purpose |
|---------|---------|
| `args` | Command-line argument parsing |
| `archive` | Tar/tar.gz extraction for asset downloads and release archive handling |

### Dev Dependencies

| Package | Purpose |
|---------|---------|
| `test` | Dart test framework |
| `lints` | Recommended lint rules |
| `fake_async` | Deterministic async testing |
| `async` | Additional async utilities |

## Frontend (Vendored Assets)

All frontend assets are vendored in `packages/dartclaw_server/lib/src/static/`. See `VENDORS.md` there for versions and upgrade instructions. HTMX is loaded via CDN (see `layout.html`).

| Library | License | Purpose |
|---------|---------|---------|
| HTMX | BSD-2 | Server-driven reactive UI |
| htmx-ext-sse | BSD-2 | SSE extension for real-time streaming |
| highlight.js | BSD-3 | Syntax highlighting (core + Dart grammar) |
| DOMPurify | Apache-2.0 / MPL-2.0 | Client-side HTML sanitization |

Themes: Catppuccin Mocha (dark) + Catppuccin Latte (light) for highlight.js.

## AndThen Installation

**AndThen `>= 0.14.3` is a runtime prerequisite.** DartClaw's built-in workflows (`plan-and-implement`, `spec-and-implement`, `code-review`) resolve non-discover-project steps against the user's AndThen install via the `andthen-` prefix. DartClaw does not vendor these skills.

AndThen offers two install modes; DartClaw consumes the **standalone install** only. The Claude Code plugin form of AndThen (under `~/.claude/plugins/marketplaces/...`) is not scanned by DartClaw's skill registry — users must run `install-skills.sh` even if they already have the plugin enabled.

### Install

```bash
# From the AndThen repo checkout:
<path-to-andthen-repo>/scripts/install-skills.sh
```

Skills are installed into:
- `~/.claude/skills/andthen-*/` — Claude harness
- `~/.agents/skills/andthen-*/` — Codex harness

The `andthen-` prefix is expected by default. Custom prefixes are not supported.

### Verify

```bash
test -d ~/.claude/skills/andthen-spec && test -d ~/.agents/skills/andthen-spec && echo "OK"
```

If AndThen is missing or older than `0.14.3`, `dart run dartclaw_cli:dartclaw workflow validate` exits with an explicit missing-prerequisite error naming the expected install roots and the install command.

**Architecture Decision**: ADR-025 (AndThen as runtime prerequisite) — recorded in the private design repo.

## External Services & Binaries

| Service | Role | Communication |
|---------|------|---------------|
| Claude CLI (`claude`) | Primary LLM agent binary (Bun standalone) | JSONL over stdin/stdout |
| Codex CLI (`codex`) | Secondary LLM agent binary (0.13+) | JSON-RPC JSONL over stdin/stdout |
| GOWA | WhatsApp bridge (Go binary, wraps whatsmeow) | Outpost pattern: subprocess + webhook |
| signal-cli-rest-api | Signal bridge (Docker container) | SSE inbound, JSON-RPC outbound |
| Google Chat API | Google Chat integration | REST API + webhook inbound |

## Infrastructure

| Service | Purpose | Notes |
|---------|---------|-------|
| Docker | Agent container isolation | `debian:bookworm-slim`, `network:none`, `cap-drop=ALL`, non-root user |
| SQLite3 | Embedded database | `search.db` (FTS5, derived), `tasks.db` (authoritative), `state.db` (transient) |

## Analyzer Configuration

Workspace-wide `analysis_options.yaml`:
- `strict-casts: true`, `strict-raw-types: true`
- Page width: 120 characters
- Key custom rules: `prefer_single_quotes`, `require_trailing_commas`, `unawaited_futures`, `cancel_subscriptions`, `always_declare_return_types`

## Dev Tools

| Tool | Purpose | Config |
|------|---------|--------|
| `dart format` | Code formatting | 120-char page width |
| `dart analyze` | Static analysis | Strict mode enabled |
| `dart test` | Test runner | Four-layer pyramid (unit/integration/acceptance/E2E) |
| `dart compile exe` | AOT compilation | Produces single native binary |
| `dart pub` | Package management | Workspace-aware |
