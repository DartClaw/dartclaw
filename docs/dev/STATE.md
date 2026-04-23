# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages, not here. Keep this file lean — when in doubt, cut.

Last Updated: 2026-04-23 11:16 CEST

## Current Phase

**0.16.4** — release prep, reopened mid-milestone for workflow step semantics redesign. S01–S47 are code-complete.

## Active Stories

- None.

## Next Planned

0.16.5 — Stabilisation & Hardening → 0.16.6 — Web UI Stimulus Adoption. See `docs/dev/ROADMAP.md`.

## Blockers

- `plan-and-implement` live-suite integration failure in `workflow_e2e_integration_test.dart` blocks tagging 0.16.4.

## Recent Decisions

- S46 task_executor.dart decomposition completed: task executor reduced to 771 LOC with extracted task config, workflow turn extraction, read-only guard, budget policy, runner-pool coordination, workflow worktree binding, and one-shot workflow runner seams.
- S47 git integration hardening completed: WorkflowGitPort seam, pre-merge invariants, RepoLock, fake-git parity tests, and fatal load-bearing artifact commit failures.
- Stabilisation sprint inserted as 0.16.5 ahead of Stimulus adoption (0.16.6).
- Workflow project binding declared once at the top level; built-in YAMLs no longer repeat per-step `project:` boilerplate. Workflow-created tasks persist uniformly as `TaskType.coding`.
- Two-step CLI onboarding: deterministic wizard for infrastructure config + conversational agent for personalization.
- TUI/CLI package: `mason_logger` for the wizard; richer TUI libraries deferred until a REPL is in scope.
- Multi-project architecture: project model, worktree integration, PR strategy.
