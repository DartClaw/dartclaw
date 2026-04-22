# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages, not here. Keep this file lean — when in doubt, cut.

Last Updated: 2026-04-22

## Current Phase

**0.16.4** — release prep, reopened mid-milestone for workflow step semantics redesign. S01–S42 are code-complete; S43 is Spec Ready.

## Active Stories

- **S43 — Token Tracking Cross-Harness Consistency** (Spec Ready) — workflow-CLI path normalization, KV writer semantics alignment, Codex CLI field-name contract verification.

## Next Planned

0.16.5 — Stabilisation & Hardening → 0.16.6 — Web UI Stimulus Adoption. See `docs/dev/ROADMAP.md`.

## Blockers

- `plan-and-implement` live-suite integration failure in `workflow_e2e_integration_test.dart` blocks tagging 0.16.4.

## Recent Decisions

- Stabilisation sprint inserted as 0.16.5 ahead of Stimulus adoption (0.16.6).
- Workflow project binding declared once at the top level; built-in YAMLs no longer repeat per-step `project:` boilerplate. Workflow-created tasks persist uniformly as `TaskType.coding`.
- Two-step CLI onboarding: deterministic wizard for infrastructure config + conversational agent for personalization.
- TUI/CLI package: `mason_logger` for the wizard; richer TUI libraries deferred until a REPL is in scope.
- Multi-project architecture: project model, worktree integration, PR strategy.
