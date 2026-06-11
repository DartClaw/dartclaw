# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages, not here. Keep this file lean — when in doubt, cut.

Last Updated: 2026-06-11 07:32 CEST

### Implemented Features (through 0.18)

- **Runtime**: 2-layer model (Dart host → Claude Code JSONL + Codex JSON-RPC binaries). Multi-provider `HarnessPool` with per-task provider override. Task orchestrator: lifecycle state machine, parallel execution, optimistic locking. Coding tasks: worktree isolation, diff, merge, PR creation. Standalone AOT binary with embedded templates, static assets, and skills (`dev/tools/build.sh`)
- **CLI**: `dartclaw init` onboarding wizard (interactive + non-interactive), `dartclaw service` management (LaunchAgent/systemd), connected-by-default workflow execution with SSE lifecycle control (`workflow run/status/pause/resume/cancel`), operational command groups (`tasks`, `config`, `projects`, `sessions`, `agents`, `traces`, `jobs`). Unified instance directory (`~/.dartclaw/`)
- **Workflows**: Deterministic YAML-defined engine — sequential, parallel, loops (exit gates), map/fan-out. Step types: agent, bash, approval, hybrid, multi-prompt. Skill registry with DC-native discovery/validation skills plus AndThen-provided workflow skills, schema presets, crash recovery. Workflow workspace isolation with dedicated `AGENTS.md` guardrails. Trigger surfaces: web launch forms, `/workflow` chat commands, GitHub PR webhooks. Connected server-backed execution with `--standalone` fallback
- **Channels**: 4 types (WhatsApp/GOWA, Signal/signal-cli, Google Chat/Pub/Sub, Web). Normalized message abstraction, deduplication, mention gating. Google Chat: Cards v2, slash commands, workspace events. Alert routing with severity-aware formatting, per-target throttling, and burst summaries
- **Crowd coding** (0.12): Multi-user steering via Spaces, sender attribution, thread binding for task-thread routing, channel-based task creation/review
- **Sessions**: Multi-scope model (web/dm/group/cron/task/heartbeat), deterministic `SessionKey` routing, event bus (30+ events), cursor-based crash recovery, automated maintenance
- **Security**: Guard chain (command/file/network/content guards) with hot-reload, Docker container isolation (`network:none` + proxy), credential proxy (Unix socket), governance (rate limiting, token budgets, loop detection), emergency `/stop`/`/pause`/`/resume`
- **Configuration**: 3-tier (ephemeral/persistent/hot-reload), 25+ typed sections, `ConfigNotifier`/`Reconfigurable` with SIGUSR1/file-watch reload triggers, extension system, settings UI
- **Observability**: Alert routing to channels, health monitoring, date-partitioned audit logging, usage/token tracking, turn traces, SSE streaming (tasks/chat/workflows), context monitoring, compaction observability (Claude + Codex lifecycle signals)
- **Web UI & API**: HTMX+SSE UI (Trellis, zero JS build) with Stimulus `dc-*` controllers for browser behavior: dashboard, chat, tasks, workflows (with launch forms), projects, scheduling, memory, settings, health. REST API + MCP server. Multi-project support with PR creation. API read surfaces for sessions, traces, and scheduled jobs
- **Personal AI & SDK docs (0.17)**: Structured behavior-file scaffolding, web-only personalization onboarding, curated inbox ingestion, wiki provenance/search/lint, temporal KG MCP tools, YAML-backed guard editor, SDK Concepts/Architecture/Security docs, runnable SDK examples, rich chat composer payload metadata, and automated kill/restart crash-recovery smoke validation
- **Universal agent harness (0.18)**: ACP subprocess harness for JSON-RPC/stdio agents, Goose and Mistral Vibe target validation, provider-scoped harness pools, stuck-turn status and early cancel, guard-mediated ACP reverse calls, `delegate_to_agent` MCP delegation, versioned release assets, automated Homebrew tap publication, and refreshed architecture/user guides
- **Storage**: Files as source of truth (YAML/JSON/NDJSON) + SQLite indexes (tasks.db, search.db, state.db). Workspace behavior files (SOUL/USER/TOOLS/AGENTS/MEMORY.md). FTS5 search with QMD hybrid opt-in
- **Governance** (0.16.5): 13 fitness checks in CI (7 Level-1 every commit + 6 Level-2 every PR) — barrel `show`-clauses, file-LOC ceilings, package cycles, constructor param counts, `ProcessEnvironmentPlan` boundary, safe-process usage, format gate; plus dependency direction, cross-package `src/` import hygiene, testing-package deps, barrel export counts, enum/event consumer exhaustiveness, per-file method-count ceilings. `public_member_api_docs` lint flipped on in `dartclaw_models/_storage/_security/_config`. Alert classifier closes the `LoopDetectedEvent` / `EmergencyStopEvent` safety gap via compiler-enforced exhaustive switch over `sealed DartclawEvent`. All 7 orphan sealed events wired to SSE + alerts


## Current Phase

**0.18 Universal Agent Harness — release-ready, awaiting tag.**

**Status**: All stories S01-S09 implemented on `feat/0.18`; release-prep version pins, changelog, state, roadmap, Homebrew template, and bundle cleanup applied. Automated release gate (`bash dev/tools/release_check.sh`) passed on 2026-06-11. Not yet tagged or merged to `main`.

**Before release/merge**: run/confirm manual gates in `dev/guidelines/RELEASE_PREPARATION.md`; tag + squash-merge.

**Previous**: 0.17 — Personal AI & Developer Experience (tagged `v0.17.0` on 2026-06-04).

**Next**: TBD. See `dev/state/ROADMAP.md`.

## Active Stories

None.

## Blockers

None.

## Recent Decisions

- 0.17 released and tagged `v0.17.0` on 2026-06-04 (squash-merged to `main`). Shipped scope lives in `CHANGELOG.md`.
- 0.18 plan bundle created from `dev/bundle/docs/specs/0.18/prd.md` on 2026-06-07.
- S01 implemented stuck-turn status, task SSE, early cancel, UI affordances, monitor config, docs, and provider/tool/unknown wait-reason derivation on 2026-06-08.
- S02 implemented provider-scoped harness pool capacity, provider-local lazy spawning, unknown-provider fail-closed routing, and standalone capacity normalization on 2026-06-07.
- S03 implemented ACP config registration, minimal `json_rpc_2` subprocess lifecycle, auth/failure/cancel cleanup, provider identity wiring, and ACP security classification on 2026-06-07.
- S04 implemented ACP session/update adapter mapping, harness bridge-event routing, session metadata/usage propagation, and cancellation normalization on 2026-06-07.
- S05 implemented guard-mediated ACP file, terminal, lifecycle, permission, and handler-level canonical mapping behavior on 2026-06-07.
- S06 implemented Goose/Vibe verified ACP target profiles, operation-level validation evidence, guard-proof gating, optional-binary outcomes, provider status exposure, and opt-in live probe coverage on 2026-06-07.
- S07 implemented typed delegation config, `delegate_to_agent` MCP registration, allowlist/security/work-dir preflight, provider-scoped delegation execution, strict/post-run budget semantics, rate limiting, terminal JSON result serialization, and focused wiring/non-regression coverage on 2026-06-07.
- S08 implemented versioned release-asset CI (`release-binaries.yml`), the `package/homebrew/` formula, Homebrew-first deployment/getting-started docs, and release/formula tests on 2026-06-07.
- S09 updated architecture and public guide documentation for ACP harness mechanics, topology-scoped security, delegation, retention, API-key posture, and Homebrew-first install guidance on 2026-06-07.
- 0.18 completed and committed (`85674e6`) on 2026-06-08 after the workflow run stopped at the remediation cap. Post-cap fixes (outside the per-story scope): claude one-shot streaming for stall-monitor liveness (`--output-format stream-json`) + `usage.*` token mapping; workflow review-report output resolution (bare-key alias, runtime-artifacts root precedence, reviews-dir backstop); standalone provisioning of workflow-requested built-in providers + growable `HarnessPool` capacity; `config_parser`/`session_routes` decomposition under fitness ceilings; 3 MEDIUM review findings (turn-monitor docs, chat-Stop affordance, terminal `global_timeout_at`).
- Workflow review output-key prefixing standardized (2026-06-08, post-0.18): every parallel review source step now uses `<stepId>.review_findings` (replacing the prior bare `review_findings` / distinct `architecture_review_findings` / step-prefixed-council split); the aggregate's own outputs stay bare. Convention documented in `docs/guide/workflows.md` + `packages/dartclaw_workflow/CLAUDE.md` and contract-locked in `built_in_workflow_contracts_test.dart`. Closes the prior follow-up and the path-key half of TD-077.
- Homebrew tap publication automated (2026-06-09, post-0.18, fulfills FR14): the `Release Binaries` workflow's new `homebrew` job renders the canonical formula template (`package/homebrew/dartclaw.rb`, via `dev/tools/render_homebrew_formula.dart`) with the verified per-platform digests and pushes `Formula/dartclaw.rb` to the `DartClaw/homebrew-dartclaw` tap on every `v*` tag. Formula is in-repo canonical / tap is generated mirror; rationale in ADR-038. Also fixed the formula license (Apache-2.0 → MIT). **Prerequisite:** the `HOMEBREW_TAP_TOKEN` repo secret (fine-grained PAT, `contents:write` on the tap) must be created before the next tag, else the job skips.
