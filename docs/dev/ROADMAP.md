# DartClaw Roadmap — Current & Next

> Trimmed to the active milestone and what comes next. Full milestone history (MVP onward) and unscheduled drafts are maintained separately.

## Active Milestone

### 0.16.4 — CLI Operations & Connected Workflows (Release Prep)

S01–S42 are code-complete; S43 is Spec Ready. Release tagging is blocked by a `plan-and-implement` live-suite integration test failure (see `STATE.md`).

## Planned

### 0.16.5 — Stabilisation & Hardening (Planned)

Consolidation sprint covering the full public codebase and user-facing docs. Closes a safety gap in alert routing, decomposes the top god files (`workflow_executor.dart`, `task_executor.dart`, `config_parser.dart`, `service_wiring.dart`, `server.dart`), formalises barrel-hygiene discipline (`dartclaw_workflow` narrowed), extracts turn/pool/harness interfaces to `dartclaw_core`, wires 7 orphan observability events, installs 10 fitness functions (6 Level-1 + 4 Level-2), refreshes `AGENTS.md` and the user guide. Zero new user-facing features. 21+ stories.

### 0.16.6 — Web UI Stimulus Adoption (Planned)

Standardize the browser interaction layer on Stimulus across the Web UI while preserving HTMX + Trellis and the zero-Node toolchain. Covers shared shell behavior, page/controller migration across the main browser surfaces, legacy page-global pattern removal, and post-migration doc/spec synchronization.

### 0.17 — Personal AI & Developer Experience (Planned)

Structured `USER.md` identity context, conversational onboarding bootstrapping, inbox-drop knowledge ingestion, LLM-maintained knowledge wiki, temporal knowledge graph (SQLite-based structured facts with time-validity), guard config editor, SDK docs Phase 2, chat input redesign (composable input, slash command palette, file attachments, @-mention context references), interrupted-turn retry UX, automated kill/restart crash-recovery validation.
