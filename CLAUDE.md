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

- `packages/` – Dart pub workspace: kernel, core runtime, ACP provider support (`dartclaw_acp`), search, channels, workflows, the hosted runtime, the container bridge, testing utilities, and the client tier. Each has its own `lib/`, `test/`, `pubspec.yaml`. `packages/dartclaw_client/` is the dependency-free HTTP/SSE client for a running server; `packages/dartclaw/` is the umbrella and re-exports the client tier only (client + kernel), never the runtime.
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

Documents here are read whole when their trigger matches, so keep them short and trim stale entries when you append. Split one that grows too long into topic files beside it, leaving a pointer line per file in it; open a topic file only when the task names its topic. Skills refer to documents by entry name, so keep names stable.

Create a document that does not exist yet, and its entry here, from `project-document-templates.md`, or through a subagent that invokes the `andthen:init` skill with `seed <name>` when that file is not loaded. Planning documents (PRDs, plans, FIS, roadmap, research, wireframes) are canonical in the private repo `../dartclaw-private/`, absent from a public-only checkout; public work sees them only as exported bundles.

- **Product** – `dev/state/PRODUCT.md`: vision, philosophy, scope, non-goals (firmly rejected concepts included), Proportionality facts. Read before proposing a feature, a design, or new machinery, or triaging a request: features anchor to it, and its stage and scale size what gets built.
- **Roadmap** – `../dartclaw-private/docs/ROADMAP.md` (private): the sole roadmap – active milestone, follow-ups, future scope. Read when sequencing work across milestones; maintainers update it when a milestone opens or ships. Public-only work uses its assigned requirements or exported plan; never create a public mirror.
- **Specs & Plans** – `dev/bundle/docs/specs/<version-or-feature>/` (support docs in `dev/bundle/docs/`, private `docs/` layout preserved): transient exported copies of the `prd.md`, `plan.json`, and one FIS per story (`s01-*.md`, …) that are canonical in private `docs/specs/`; ADRs are not bundled, and `dev/state/SPEC-LIFECYCLE.md` says when bundle files appear and disappear. Read the governing FIS before implementing; update the FIS and its story's `plan.json` row as execution proceeds. `plan.json` has one writer per copy at a time, so a `plan` breakdown's story subagents never write it. An oversized FIS is a story too big: decompose it (`OVERSIZE:`), never trim it.
- **Decisions** – `dev/state/DECISIONS.md`: ADR index, Still Current notes, supersession lineage. Read before proposing or changing a design or architecture choice; settled decisions are not relitigated without new evidence.
- **ADRs** – `dev/adrs/` (public-safe research appendices in `dev/adrs/research/`). Read the ADR a decision cites before revisiting it; add one per new decision.
- **Architecture** – `dev/architecture/system-architecture.md`, plus one deep-dive per subsystem beside it (e.g. `control-protocol.md` for harness spawn, CLI flags and provider protocols, `security-architecture.md` for container and setting isolation and guards, `configuration-architecture.md` for the config schema) and `architecture-governance.md`. Hand-written SVG figures in `dev/architecture/diagrams/` (recipe figures: `docs/guide/recipes/diagrams/`) are the source of truth; conventions and the render check are in its `README.md`. Read before changing or reasoning about a component, a boundary, or data flow, rather than reverse-engineering from source; update the doc and its figure in the same change.
- **Context Map** – `dev/architecture/context-map.md`: bounded contexts, subdomain classification, integration patterns; the canonical source for context names in models and glossary grouping. Read before placing a feature, boundary, or integration; update when a context or its relationships change.
- **Ubiquitous Language** – `dev/state/UBIQUITOUS_LANGUAGE.md`: canonical terms and the synonyms to avoid. Read before naming, renaming, or describing domain concepts; add a row when a term settles.
- **Prompt Surfaces** – `dev/state/PROMPT-SURFACES.md`: every host-authored model-facing prompt, schema over model output, and parser of a model reply, with its output contract and validating component. Read before adding or re-contracting one; keep it current in the same change.
- **Guidelines** – `dev/guidelines/`. Read a guideline when its condition under Project Guidelines and Standards matches the task.
- **Design System** – `dev/design-system/`: `DESIGN.md` is canonical (tokens and rationale; YAML frontmatter per the [DESIGN.md spec](https://github.com/google-labs-code/design.md)), with `tokens.css`, `components.css`, `icons.css`, and `showcase.html` rendering it. Read before writing UI markup, styles, or templates; update when a token or component is added.
- **Visual Validation** – `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md`: how the UI is served, authenticated, and captured, viewports, the UI smoke test (`dev/testing/UI-SMOKE-TEST.md`), and the testing profiles. Read before capturing a screen.
- **Learnings** – `dev/state/LEARNINGS.md`. Read at task start; add a bullet when bitten by a non-obvious failure that passes its admission test.
- **Tech Debt** – `dev/state/TECH-DEBT-BACKLOG.md`: only debt that needs a requirements input or an architecture decision. Read when working in an area that has a listed item; add an entry when deferring such a fix.
- **Key Dev Commands** – `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`: run, build, CI-equivalent gate, and the `fast`, `full`, and run-one-test tiers. Read before running verification; update when a command changes.
- **Testing Strategy** – `dev/guidelines/TESTING-STRATEGY.md`: philosophy, four-layer pyramid, async patterns, coverage, shared fakes, anti-patterns. Read before authoring tests; update when a convention changes.
- **User Guide** – `docs/guide/` (`getting-started`, `configuration`, `customization`, `security`, `governance`, `agents`, `workflows`, `workflows-reference`, `tasks`, `web-ui-and-api`, `cli-reference`, `deployment`, channel guides, `recipes/`, …) and `docs/sdk/` (`quick-start`, `packages`). Read the relevant guide before changing user-facing behavior, config keys, CLI, channels, web UI, or the SDK surface – e.g. `configuration.md` documents `providers.*`, `workflows-reference.md` documents workflow YAML fields; keep it current in the same change.
- **Changelog** – `CHANGELOG.md`: shipped history per release. Add an entry on every user-facing change.
- **Built-in Workflows** – `dev/tools/dartclaw-workflows/README.md` (and § Built-in DartClaw Workflows below). Read before running a shipped workflow against this checkout.
- **Agent Temp** – `.agent_temp/`: scratch workspace for reviews, research, and QA; never ship from it.


---


## Built-in DartClaw Workflows

DartClaw ships three end-to-end YAML workflows – `story-and-implement`, `plan-and-implement`, `code-review` – in `packages/dartclaw_workflow/lib/src/workflow/definitions/`. They call skills from the AndThen 1.0 `andthen` plugin and use `dartclaw-*` only for four bundled discovery, validation, and merge skills.

Run from this checkout: `dev/tools/dartclaw-workflows/run.sh` – full documentation in `dev/tools/dartclaw-workflows/README.md`.


---


## Rules and Guardrails

### Project Guidelines and Standards
- **Read** `dev/guidelines/DEVELOPMENT-ARCHITECTURE-GUIDELINES.md` before coding, architecture, UX/UI, or review work: CUPID, DDD, scalability/resilience, coding standards, and § Review Defect Classes – the two named classes every review reports as defects (*prose parsing / repair ladder / sentinel over model or user text*; *second implementation of an existing seam*).
- **Read** `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` before writing Dart: style, documentation, usage, API design, async, error handling, Dart 3.x features, linter config.
- **Read** `dev/guidelines/DART-PACKAGE-GUIDELINES.md` when touching a pubspec or workspace package: structure, versioning, pub.dev scoring, publishing.
- **Read** `dev/guidelines/HTMX-GUIDELINES.md` before writing web UI fragments: attributes, server-side rendering, streaming updates, error handling, security.
- **Read** `dev/guidelines/TRELLIS-GUIDELINES.md` before writing templates: escaping rules, fragment patterns, HTMX integration, security.
- **Read** `dev/guidelines/RELEASE_PREPARATION.md` when preparing or shipping a release (§ Release Preparation below).

### Vital Conventions
- Single-threaded – add isolates only if profiling shows a bottleneck.
- Vendored third-party assets (e.g. highlight.js) live in `packages/dartclaw_runtime/lib/src/static/` – see its `VENDORS.md` for versions and upgrade instructions.
- Never reference specific story IDs or titles in code, filenames, or user-facing docs (project/development documents are the exception).
- Version-specific documents (qualification ledgers, milestone runbooks) live in the plan bundle `dev/bundle/docs/specs/<version>/` and canonically in private `docs/specs/<version>/`, never elsewhere in the public tree.
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
For release preparation, the evidence-reuse procedure in `RELEASE_PREPARATION.md` satisfies this gate: retain completed
review proof, verify unchanged inputs, and run affected checks. GitHub CI runs on the final squash commit.

Example configs: `bash examples/run.sh` – defaults to `dev.yaml` (no auth, guards off), data in `.dartclaw-example/`. It needs `DARTCLAW_DATABASE_URL` pointing at a PostgreSQL 14+ database whose schema `doctor --fix` has bootstrapped once (`examples/README.md`). Pick a config with `bash examples/run.sh production --port 8080`.


---


## Release Preparation

See `dev/guidelines/RELEASE_PREPARATION.md` for the release preparation workflow, gates, and sequence.

**Shipping a version branch is releasing it.** `andthen:ship` on `feat/<version>` runs release preparation through the
scope-frozen commit (release sequence step 1) before it publishes, because that branch merges only as the release.
Its bundle deletion is the exported-bundle cleanup, done after the private PRD is consolidated
(`dev/state/SPEC-LIFECYCLE.md`), and live or owner checks it cannot run are reported as holds.

Treat the existing `HOMEBREW_TAP_TOKEN` scope as an operator-maintained invariant. Do not request reconfirmation during
routine releases; audit it only after token rotation/widening or a relevant environment/repository-protection change.


---


## Tools and External Documentation

### Search and code exploration
- **ripgrep (`rg`)** instead of grep. **ast-grep** for AST-level matches (`ast-grep 'import { $X } from "supabase"' routes/`). **tree** for structure (`tree -L 2`).
- **Deslop** – before adding non-trivial code, search for an existing implementation. For duplicate cleanup run `deslop . --output .deslop/deslop-report --no-fail-over`, inspect worst-first clusters by stable `id` in the JSON report, refactor one semantically valid cluster at a time, test, rescan. Never hide owned code or distort code to silence a finding; `exclude` is for unowned code, `report_hide` for generated code.

### Dart tooling
- **Dart LSP plugin** (`https://github.com/tolo/coding-agent-toolkit/tree/main/plugins/dart-lsp`) spawns `dart language-server` – diagnostics, hover, goToDefinition, findReferences, call hierarchy across workspace packages. **Fix all diagnostics immediately**; run `dart analyze` before declaring work done. In a fresh checkout or git worktree, run `dart run dev/tools/embed_assets.dart` first – the embedded asset libraries are generated, not committed, and `lib/` imports them – and `dart pub get --directory dev/tools/mascot_favicon --enforce-lockfile`, or `dart analyze` reports a missing `package:image` in that standalone tool.
- **Dart MCP server is not active** – use Bash for Dart CLI commands; use the pub.dev JSON API for package searches.

### Parallels VMs (macOS host)
- **Windows** – `dev/tools/parallels_windows.sh` for VM commands, PowerShell scripts, snapshots, captures. Prefer signed-in-user execution; use `*-system` commands only when elevation is required. Usage and prerequisites in `KEY_DEVELOPMENT_COMMANDS.md`.
- **Linux agent desktop** – `dev/guidelines/PARALLELS_LINUX_AGENT_VM.md` is the source of truth for provisioning and customizing the Ubuntu 24 ARM64 VM (Wayland, SSH, Cua Driver, host-sharing restrictions, optional Docker conformance, snapshots, cloning, end-to-end verification). Use `dev/tools/parallels_linux.sh` only for its tested runtime operations, not provisioning.

### External documentation
**Always delegate documentation lookups to a background `worker` sub-agent** using the Context7 MCP tools (version-specific library docs) and the Fetch MCP tool (page → markdown), so the main context window stays clean.

- **Dart** – https://dart.dev/guides – language reference, core libraries, effective Dart
- **Claude Code CLI** – https://code.claude.com/docs/en/headless – JSONL control protocol (stream-json)
- **HTMX** – https://htmx.org/docs/ – attribute reference


---


## Spec-Driven Development (e.g. AndThen) process and SDLC guidelines

- **Release gates are never story scope.** Release preparation owns candidate-wide gate coverage and retains receipts or eligible review evidence with input comparisons (`dev/guidelines/RELEASE_PREPARATION.md`). A story proves itself with its own tests plus the `fast`/`full` tiers in `KEY_DEVELOPMENT_COMMANDS.md`; a plan task that re-runs a release gate is duplicated scope.
- **Keep stories package-scoped.** When breaking a plan into many stories, aim for each story to stay within one `packages/<name>/` (or `apps/<name>/`); reach across packages only for genuinely cross-cutting seams. A single-package scope keeps stories focused and keeps the implementing agent's context to one package's `CLAUDE.md` / `AGENTS.md`, source, and tests instead of several.
