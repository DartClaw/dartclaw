# Rules, Guidelines and Project Overview for Coding Agents – DartClaw

## Project Overview

**DartClaw** – an experimental, security-conscious AI agent runtime built with Dart: an AOT-compiled orchestrator (zero npm) driving multiple agent harnesses (Claude Code, Codex, potentially more).

Early experimental, soft-published. Breaking changes acceptable – correctness and clean design over backward compat. Vision and principles: `dev/state/PRODUCT.md`.


### Core Philosophy (Binding)

DartClaw is **pragmatic, lightweight, adaptable, and approachable**. This is a product requirement, not a style preference – violations are defects, not taste. Guard against over-engineering, speculative generality, bloat, misguided workarounds, scope creep.

- **Smallest change that solves the real problem.** No speculative features, abstractions, config knobs, layers, or extension points for imagined futures.
- **Reuse before you build.** Extend an existing seam, type, or package before adding one – prove the existing ones can't carry it first.
- **Root causes over workarounds.** When something fights you, diagnose it or surface it – never paper over it with wrappers, fallbacks, retries, or special cases.
- **Scope is a contract.** Every changed line traces to the request or active spec; adjacent "improvements" get surfaced, not done.
- **Approachable over clever.** Plain, readable code beats elegant indirection – the codebase must stay small, auditable, and easy to pick up.
- **When in doubt, leave it out.** Missing is cheap to add later; bloat is expensive to remove. Cutting scope is a legitimate resolution.
- **Model-first delegation.** Judgment belongs to the model, behind a schema or tool contract. The host validates once, bounds, persists and enforces – and never re-derives, repairs, defaults or overrules a model-supplied value; a value that fails its contract fails the step and is re-asked. No repair ladders, sentinel defaults, or prose scraping over model or user text. Documented templates: `memory_journal.dart`, `heartbeat_job.dart`, `merge_resolve_coordinator.dart` + `dartclaw-merge-resolve/SKILL.md`, `review_artifact_policy.dart`, `content_classifier.dart`/`anthropic_api_classifier.dart`, `execution_envelope_schema.dart`/`prompt_augmenter.dart`.
- **One authority per concern.** Every concern has exactly one owner; a second implementation of an existing seam – parser, validator, resolver, formatter, schema constant, policy evaluator – is a defect, however well written. Two implementations are two answers with no arbiter, and they drift. Templates: `memory_corpus_authority.dart`, `review_artifact_policy.dart`, `execution_envelope_schema.dart`.

Both rules are binding in full text in [ADR-054](dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md), which holds the authoritative **deterministic-keeps carve-out** – no enforcement decision moves behind a model turn – and the single sanctioned exemption (one schema- or enum-driven validation pass with a fail-closed default). The carve-out's test for anything not on its list: a decision stays host-side and deterministic if it is a security boundary, a cost or capacity bound, a persistence invariant, a protocol, channel-exact formatting, or must work when the model is wedged – read the ADR for the binding list before concluding otherwise. Their review-side defect classes are in `dev/guidelines/DEVELOPMENT-ARCHITECTURE-GUIDELINES.md`.


### Repository Layout

- `packages/` – Dart pub workspace: core runtime, ACP provider support (`dartclaw_acp`), storage, security, config, channels, workflows, testing utilities, server, and the client tier. Each has its own `lib/`, `test/`, `pubspec.yaml`. `packages/dartclaw_client/` is the dependency-free HTTP/SSE client for a running server; `packages/dartclaw/` is the umbrella and re-exports the client tier only (client + models), never the runtime.
- `apps/dartclaw_cli/` – CLI app (AOT-compilable): `serve`, `status`, `service`, `rebuild-index`.
- `docs/` – end-user reference and guides. `dev/` – contributor and agent working knowledge: state, architecture, guidelines, specs, testing profiles, build/CI tooling. `dev/fitness/` is also a workspace member (`dartclaw_fitness`): the repo-wide architecture gates, pinned to zero production dependencies – see its `README.md`.


### Package-Scoped Rules

Each `packages/<name>/` and `apps/<name>/` has an `AGENTS.md` (symlinked to a sibling `CLAUDE.md`) carrying package-specific conventions, gotchas, and internal architecture notes.

- **Read it before editing or creating files in that directory** – once per package per session; repeat per package for cross-package tasks.
- **Keep it current in the same edit** when your change invalidates a fact there (new/removed boundary, renamed key file, changed convention, retired gotcha). Drift makes the file actively misleading – agents will follow stale rules.
- Symlinks require `git config core.symlinks true` on Windows; without it git materialises a text stub.

Keep this root file lean – cross-cutting rules here, package-specific ones in the per-package files.


---


## Project Document Index

This table is the main registry of document locations relevant to development and project management. Used by AndThen skills and other skills / commands.

| Topic | Location | When to read |
|-------|----------|--------------|
| Current state | `dev/state/STATE.md` | Current version, phase, active stories, blockers, session continuity notes. Check what's in flight before starting work |
| Learnings | `dev/state/LEARNINGS.md` (bounded index, ≤150 lines) + topic shards in `dev/state/learnings/` | Before debugging unfamiliar subsystems: read the index whole, open only task-relevant shards (`→ learnings/<topic>.md` pointers). Add discoveries via `andthen:ops update-learnings --ceiling 150` (pass the ceiling explicitly – this index table has no `Ceiling` column for the script to read); entries for an already-sharded topic go into the shard file by hand, and shard graduation is a hand operation |
| Product (summary) | `dev/state/PRODUCT.md` | Vision and principles |
| Roadmap (current + next) | `dev/state/ROADMAP.md` | Active milestone and what's after |
| Tech stack | `dev/state/STACK.md` | Languages, packages, external services |
| Ubiquitous language | `dev/state/UBIQUITOUS_LANGUAGE.md` | Domain glossary – use these terms in code, docs, naming |
| Prompt surfaces | `dev/state/PROMPT-SURFACES.md` | Before adding or re-contracting a host-authored model-facing prompt, a schema over model output, or a parser of a model reply: the inventory of every prompt surface with its output contract and validating component. Keep it current in the same change |
| Architecture reference | `dev/architecture/` (`system-`, `security-`, `configuration-`, `control-protocol`, `task-execution-`, `workflow-`, `session-state-`, `data-model`, `channel-messaging-`, `cli-api-`, `observability-operations-architecture.md`) | Canonical deep-dive per subsystem – e.g. `control-protocol.md` for harness spawn/CLI flags/provider protocols, `security-architecture.md` for container/setting isolation + guards, `configuration-architecture.md` for the config schema. Read before changing or reasoning about a subsystem; don't reverse-engineer from source when a doc exists |
| Context Map | `dev/architecture/context-map.md` | Strategic-design view: bounded contexts, subdomain classification, context-mapping patterns. Written by `andthen-some:architecture-analysis --mode strategic-design`; canonical source for context names in models and glossary grouping |
| Architecture Model | `.agent_temp/models/architecture-model.json` | Transient typed projection for atlas rendering; regenerate with `andthen-some:describe --mode codebase --model`, render with `andthen-some:visualize`. The code is the record |
| Domain Model | `.agent_temp/models/domain-model.json` | Transient typed projection of the Ubiquitous Language for atlas rendering; regenerate with `andthen-some:describe --mode domain --model`. The UL document is the record |
| Decisions | `dev/state/DECISIONS.md` | Index of record: ADRs (ID, title, status, scope) + load-bearing non-ADR decisions ("Still Current") + supersession lineage. § Still Current bullets are hand-written (there is no `andthen:ops` verb for them); `andthen:ops close-plan` appends FIS design-change lines |
| ADRs | `dev/adrs/` (+ public-safe research appendices in `dev/adrs/research/`) | Full ADR text; status/scope inventory lives in `DECISIONS.md` |
| Tech debt backlog | `dev/state/TECH-DEBT-BACKLOG.md` | Known debt requiring requirements input or an architecture decision |
| Spec lifecycle | `dev/state/SPEC-LIFECYCLE.md` | When exported implementation bundle files appear or disappear |
| Specs & plans | `dev/bundle/docs/specs/` (support docs in `dev/bundle/docs/`, private `docs/` layout preserved) | PRDs, implementation plans, FIS, story breakdowns per `<version-or-feature>`. Transient copies for public workflow runs; canonical in private. ADRs are not bundled |
| User-facing docs | `docs/guide/` (`getting-started`, `configuration`, `customization`, `security`, `governance`, `agents`, `workflows`, `workflows-reference`, `tasks`, `web-ui-and-api`, `cli-reference`, `deployment`, channel guides, `recipes/`, …) + `docs/sdk/` (`quick-start`, `packages`) | Read the relevant guide before changing user-facing behavior, config keys, CLI, channels, web UI, or the SDK surface – e.g. `configuration.md` documents `providers.*`, `workflows-reference.md` documents workflow YAML fields. **Keep them current** in the same change (same currency discipline as package `AGENTS.md`) |
| Changelog | `CHANGELOG.md` | Shipped history per release |
| Built-in workflows | `dev/tools/dartclaw-workflows/README.md` (+ § below) | Running shipped workflows against this checkout |
| Development & architecture | `dev/guidelines/DEVELOPMENT-ARCHITECTURE-GUIDELINES.md` | Before coding, architecture, UX/UI, or review work: CUPID, DDD, scalability/resilience, coding standards, and § Review Defect Classes – the two named classes every review reports as defects (*prose parsing / repair ladder / sentinel over model or user text*; *second implementation of an existing seam*) |
| Dart style | `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` | Before writing Dart: style, documentation, usage, API design, async, error handling, Dart 3.x features, linter config |
| Package boundaries | `dev/guidelines/DART-PACKAGE-GUIDELINES.md` | When touching pubspec or workspace packages: structure, versioning, pub.dev scoring, publishing |
| Testing strategy | `dev/guidelines/TESTING-STRATEGY.md` | Before writing tests: philosophy, four-layer pyramid, async patterns, coverage, shared fakes, anti-patterns |
| HTMX patterns | `dev/guidelines/HTMX-GUIDELINES.md` | Before writing web UI fragments: attributes, server-side rendering, streaming updates, error handling, security |
| Trellis templates | `dev/guidelines/TRELLIS-GUIDELINES.md` | Before writing templates: escaping rules, fragment patterns, HTMX integration, security |
| Design system | `dev/design-system/DESIGN.md` (+ `tokens.css`, `components.css`, `icons.css`, `showcase.html`) | Single source of truth for visual design; YAML frontmatter follows the [DESIGN.md spec](https://github.com/google-labs-code/design.md). Before any UI/CSS/template work |
| Key dev commands | `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` | Before/after modifying code |


---


## Built-in DartClaw Workflows

DartClaw ships three end-to-end YAML workflows – `spec-and-implement`, `plan-and-implement`, `code-review` – in `packages/dartclaw_workflow/lib/src/workflow/definitions/`. They use a branded version of AndThen with the **`dartclaw-*` skill namespace**.

Run from this checkout: `dev/tools/dartclaw-workflows/run.sh` – full documentation in `dev/tools/dartclaw-workflows/README.md`.


---


## Rules and Guardrails

### Vital Conventions
- Single-threaded – add isolates only if profiling shows a bottleneck.
- Vendored third-party assets (e.g. highlight.js) live in `packages/dartclaw_runtime/lib/src/static/` – see its `VENDORS.md` for versions and upgrade instructions.
- Never reference specific story IDs or titles in code, filenames, or user-facing docs (project/development documents are the exception).
- Tests must run on Linux CI and local macOS – prefer Dart APIs over platform-specific shell flags; see `TESTING-STRATEGY.md` for POSIX file-permission checks.
- **Tech debt backlog is a last resort** – `dev/state/TECH-DEBT-BACKLOG.md` is reserved for items that **cannot** be resolved without further requirements input or an architecture decision. Fixable now with current understanding → fix now, or capture it in an active spec/FIS. Entries describing known cleanups invite rot and dilute signal.
- **Timestamps** – always run `date '+%Y-%m-%d %H:%M %Z'` before writing one. Never guess; internal time may be the wrong timezone.

### Comments – rationale only, never narration
- **Public API** (barrel-exported or otherwise meant for downstream consumers) gets dartdoc documenting the *contract*: behavior, throws, non-obvious preconditions. Don't document consumer behavior or call-site context – that rots independently.
- **Internal code** (`lib/src/`, private members, inline `//`) defaults to *none*. Write only when a reader would otherwise miss a hidden constraint, invariant, or workaround. Never restate the WHAT.
- **Drift is worse than absence** – wrong or outdated comments must be fixed or deleted on sight.
- **Forbidden**: `// REMOVED …` / `// was: …` markers; transient planning refs (story IDs, sprint/wave labels, current-PR numbers – durable ADR and TODO issue links are fine); `// TODO` without an owner or issue link; multi-paragraph docstrings on internal helpers.
- Full ruleset (also control-flow restatement and identifier paraphrasing): `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` § Proportionality & Anti-Rot.


---


## Key Development Commands

See `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` – read before/after modifying code.

**Formatting is a hard CI gate**, and CI stops there before analyze/tests, so format drift hides later failures. Before committing, pushing, or declaring a CI fix done, run `dart format --line-length=120 --output=none --set-exit-if-changed .`. If it reports changed files, run `dart format --line-length=120` on them, include the formatting diff, then rerun the check.

Run the full CI-equivalent gate from `KEY_DEVELOPMENT_COMMANDS.md` before pushing shared branches, before declaring a CI fix done, and after changes touching package boundaries, tests, build tooling, workflow definitions, or cross-package behavior.

Example configs: `bash examples/run.sh` – defaults to `dev.yaml` (no auth, guards off), data in `.dartclaw-example/`. Pick a config with `bash examples/run.sh production --port 8080`.


---


## Visual Validation Workflow

The `andthen:visual-validation` skill auto-reads this `## Visual Validation Workflow` section first; follow the linked references.

- `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – full conventions for visual validation
- `dev/testing/UI-SMOKE-TEST.md` – test cases TC-01…TC-31. Run via `bash dev/testing/profiles/plain/run.sh`. Trigger: _"Run the UI smoke test"_
- `dev/testing/README.md` – testing profiles (`plain`, `channels`, `governance`, `visual`, `workflows`) and AI-native scenarios (`dev/testing/scenarios/`)
- Tooling: `agent-browser` skill (`open <url>` → `snapshot -i` → `click @e1` / `fill @e2 "text"` → re-snapshot); `chrome-devtools` skill for deeper inspection, JS execution, debugging


---


## Release Preparation

See `dev/guidelines/RELEASE_PREPARATION.md` for the release preparation workflow, gates, and sequence.

Treat the existing `HOMEBREW_TAP_TOKEN` scope as an operator-maintained invariant. Do not request reconfirmation during
routine releases; audit it only after token rotation/widening or a relevant environment/repository-protection change.


---


## Tools and External Documentation

### Search and code exploration
- **ripgrep (`rg`)** instead of grep. **ast-grep** for AST-level matches (`ast-grep 'import { $X } from "supabase"' routes/`). **tree** for structure (`tree -L 2`).
- **Deslop** – before adding non-trivial code, search for an existing implementation. For duplicate cleanup run `deslop . --output .deslop/deslop-report --no-fail-over`, inspect worst-first clusters by stable `id` in the JSON report, refactor one semantically valid cluster at a time, test, rescan. Never hide owned code or distort code to silence a finding; `exclude` is for unowned code, `report_hide` for generated code.

### Dart tooling
- **Dart LSP plugin** (`https://github.com/tolo/coding-agent-toolkit/tree/main/plugins/dart-lsp`) spawns `dart language-server` – diagnostics, hover, goToDefinition, findReferences, call hierarchy across workspace packages. **Fix all diagnostics immediately**; run `dart analyze` before declaring work done. In a fresh checkout or git worktree, run `dart run dev/tools/embed_assets.dart` first – the embedded asset libraries are generated, not committed, and `lib/` imports them.
- **Dart MCP server is not active** – use Bash for Dart CLI commands; use the pub.dev JSON API for package searches.

### Parallels VMs (macOS host)
- **Windows** – `dev/tools/parallels_windows.sh` for VM commands, PowerShell scripts, snapshots, captures. Prefer signed-in-user execution; use `*-system` commands only when elevation is required. Usage and prerequisites in `KEY_DEVELOPMENT_COMMANDS.md`.
- **Linux agent desktop** – `dev/guidelines/PARALLELS_LINUX_AGENT_VM.md` is the source of truth for provisioning and customizing the Ubuntu 24 ARM64 VM (Wayland, SSH, Cua Driver, host-sharing restrictions, optional Docker conformance, snapshots, cloning, end-to-end verification). Use `dev/tools/parallels_linux.sh` only for its tested runtime operations, not provisioning.

### External documentation
**Always delegate documentation lookups to a background `worker` sub-agent** using the Context7 MCP tools (version-specific library docs) and the Fetch MCP tool (page → markdown), so the main context window stays clean.

- **Dart** – https://dart.dev/guides – language reference, core libraries, effective Dart
- **Claude Code CLI** – https://code.claude.com/docs/en/headless – JSONL control protocol (stream-json)
- **sqlite3 (Dart)** – https://pub.dev/packages/sqlite3 – raw SQLite bindings (search index only, no ORM)
- **HTMX** – https://htmx.org/docs/ – attribute reference


---


## Spec-Driven Development (e.g. AndThen) process and SDLC guidelines

- **Keep stories package-scoped.** When breaking a plan into many stories, aim for each story to stay within one `packages/<name>/` (or `apps/<name>/`); reach across packages only for genuinely cross-cutting seams. A single-package scope keeps stories focused and keeps the implementing agent's context to one package's `CLAUDE.md` / `AGENTS.md`, source, and tests instead of several.
