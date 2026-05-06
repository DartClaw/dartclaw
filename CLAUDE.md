# Rules, Guidelines and Project Overview for Coding Agents — DartClaw Workspace

## Project Overview

**DartClaw** — An experimental, security-conscious AI agent runtime built with Dart. Dart orchestrator (AOT-compiled, zero npm) + multiple agent harnesses (Claude Code, Codex, and potentially more).
Current milestone: 0.16.5 — Stabilisation & Hardening
> AGENTS.md is the standard instruction file for ALL non-Claude-Code agents, not DartClaw-specific.

Read more in `dev/state/PRODUCT.md` for vision, development stage, and core philosophy.


### Development Stage

Early experimental (soft-published). Breaking changes acceptable — correctness and clean design over backward compat. See `dev/state/PRODUCT.md`.


### Repository Layout

#### Documentation

This repo splits **end-user-facing** docs from **dev-workflow / contributor** material at the top level:

- `docs/` — end-user reference and guides (`guide/`, `sdk/`). 
- `dev/` — contributor and agent working knowledge: state, guidelines, specs, testing profiles, build/CI tooling. 

#### Package Structure (Dart pub workspace)

The functionality is split into focused packages under `packages/` — core runtime, storage, security, config, channels, workflows, testing utilities, and the server. The `apps/` directory holds the CLI app. Each package has its own `lib/`, `test/`, and `pubspec.yaml` declaring its dependencies and version.

```
/
  packages/
    dartclaw/            # Published umbrella — re-exports core + storage + channel packages
    ...
  apps/
    dartclaw_cli/        # CLI app (AOT-compilable): serve, status, deploy, rebuild-index commands
```


### Package-Scoped Rules

Each `packages/<name>/` and `apps/<name>/` has an `AGENTS.md` (symlinked to a sibling `CLAUDE.md`) carrying package-specific conventions, gotchas, and internal architecture notes. The symlink convention assumes macOS/Linux — on Windows it requires `git config core.symlinks true`; without it, git materialises the file as a text stub rather than a real symlink.

**Before editing or creating files under `packages/<name>/` or `apps/<name>/`, read that directory's `AGENTS.md` first.** If a task spans multiple packages, repeat per package. Skip if you've already read it earlier in the session.

**Keep these files current.** When you change code in a package, update its `AGENTS.md` in the same edit if the change invalidates a fact there (new/removed boundary, renamed key file, changed convention, retired gotcha). Drift makes the file actively misleading — agents will follow stale rules. Treat updates as part of the change, not a follow-up.

Keep this root file lean — cross-cutting rules here, package-specific ones in the per-package files.


---


## Project Document Index

Internal development docs for working on DartClaw itself (as opposed to using it).

<!-- AndThen-style index — workflow commands and the discover-project skill read this table to determine where to find and write project documents. -->

| Topic | Location | When to read |
|-------|----------|--------------|
| Current state | `dev/state/STATE.md` | Current version, phase, active stories, blockers, and session continuity notes. Check what's in flight before starting work |
| Learnings | `dev/state/LEARNINGS.md` | Before debugging unfamiliar subsystems; append non-obvious discoveries |
| Product (summary) | `dev/state/PRODUCT.md` | Vision and principles |
| Roadmap (current + next) | `dev/state/ROADMAP.md` | Active milestone and what's after |
| Tech stack | `dev/state/STACK.md` | Languages, packages, external services |
| Ubiquitous language | `dev/state/UBIQUITOUS_LANGUAGE.md` | Domain glossary — use these terms in code, docs, naming |
| Tech debt backlog | `dev/state/TECH-DEBT-BACKLOG.md` | Known debt requiring requirements input or architecture decision |
| Spec lifecycle | `dev/state/SPEC-LIFECYCLE.md` | When exported implementation bundle files appear or disappear |
| Implementation bundle specs | `dev/bundle/docs/specs/` | Transient PRD/plan/FIS copies for public workflow runs; canonical in private |
| Implementation bundle docs | `dev/bundle/docs/` | Transient support docs copied with private `docs/` layout preserved |
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

DartClaw ships three end-to-end YAML workflows — `spec-and-implement`, `plan-and-implement`, `code-review` — in `packages/dartclaw_workflow/lib/src/workflow/definitions/`. These workflows uses a branded version of AndThen, using the **`dartclaw-*` skill namespace**.

To run from this checkout: `dev/tools/dartclaw-workflows/run.sh` — see `dev/tools/dartclaw-workflows/README.md` for the full documentation on running workflows.


---


## Rules, Guardrails and Guidelines

### Foundational Rules and Guardrails
Adhere to system prompt "CRITICAL RULES and GUARDRAILS" before doing any work.

### Vital Conventions
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

See `dev/guidelines/RELEASE_PREPARATION.md` for the release preparation workflow, gates, and sequence.


---


## Key Development Commands
See `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` — read before/after modifying code.

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
