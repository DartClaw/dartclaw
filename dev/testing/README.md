# DartClaw Testing — Profiles, Scenarios, and Smoke Tests

This directory hosts everything needed to run DartClaw against pre-configured environments:

- **`profiles/`** — pre-configured DartClaw environments and command runners. Server profiles include seeded data and
  a `run.sh`; Windows-native profiles use PowerShell. Used by `UI-SMOKE-TEST.md`, by the
  `dev/tools/release_check.sh` manual gates, and by scenario files.
- **`scenarios/`** — AI-native acceptance scenarios. Markdown files with YAML frontmatter that describe full-system interactions (browser + API + governance) in natural language. Run via the `test-scenario` skill — see `scenarios/README.md`.
- **`UI-SMOKE-TEST.md`** — the canonical 31-case UI smoke test, run against the `plain` profile.
- **`docker/`** — container-related test scaffolding.

## Profile Quick Reference

| Profile | Port | Run command | Purpose |
|---|---|---|---|
| `plain` | 3335 | `bash dev/testing/profiles/plain/run.sh` | Minimal seeded data, no channels. Backs `UI-SMOKE-TEST.md` and most `scenarios/session-*` scenarios. |
| `channels` | 3336 | `bash dev/testing/profiles/channels/run.sh` | WhatsApp + Signal channels enabled. Hardware pairing flow is documented in `dartclaw-private/docs/testing/channel-e2e-manual.md`. |
| `governance` | 3337 | `bash dev/testing/profiles/governance/run.sh` | Tight governance limits + budget seeding. Backs the governance-enforcement scenario. |
| `visual` | 3338 | `bash dev/testing/profiles/visual/run.sh` | Desktop visual smoke profile. Feature-visibility flags on so Health/Memory/Tasks/Projects/Workflows all render with seeded content. |
| `workflows` | 3333 | `bash dev/testing/profiles/workflows/run.sh` | Codex-first workflow execution against the `DartClaw/workflow-test-todo-app` fixture repo. Requires `GITHUB_TOKEN` for publish runs. |
| `workflow-contract` | n/a | `bash dev/testing/profiles/workflow-contract/run.sh` | Fast deterministic workflow contract checks. Use while iterating on workflow YAML, gates, output contracts, and resolver behavior. |
| `workflow-live` | n/a | `bash dev/testing/profiles/workflow-live/run.sh --canary <name>` | Explicit live workflow integration canaries and full sweep. Runs a fail-fast provider preflight (version, codex bundled-tool quarantine check, one pinned-model round-trip; `--skip-preflight` to skip) and exports a hermetic codex `CODEX_HOME` so operator dotfiles can't override fixture models. Captures logs and summarizes warning patterns. |
| `windows-runtime` | 3340 | `./dev/testing/profiles/windows-runtime/run.ps1 -ArtifactPath <zip>` | Native Windows x64 release smoke: server, Web UI, FTS5, file-watch reload, Claude, and Codex. Writes the stable layered report to `dev/testing/evidence/windows-runtime-smoke.md`. |

Each Unix server profile resolves the repo root from `dev/testing/profiles/<name>/run.sh`, copies its seed data to a
writable temp directory by default, and starts `dartclaw_cli` in `--dev` mode. Set `DARTCLAW_<PROFILE>_DATA_DIR`
(e.g. `DARTCLAW_VISUAL_DATA_DIR=/tmp/visual`) to persist those server-profile states across runs. Command and
Windows-native profiles document their own inputs in the table and linked scenario.

The `workflow-contract` and `workflow-live` profiles are command profiles rather than server profiles. They do not bind a port. Use them as the workflow validation ladder:

```bash
bash dev/testing/profiles/workflow-contract/run.sh
bash dev/testing/profiles/workflow-live/run.sh --canary step-isolation
bash dev/testing/profiles/workflow-live/run.sh --canary plan-and-implement
bash dev/testing/profiles/workflow-live/run.sh --full
```

Do not use the workspace-root `dart test -t integration` command as a workflow gate. The root has no default `test/` directory, and integration-tagged suites are skipped by default unless run with `--run-skipped` against explicit files.

The Windows runtime profile is release-ready only when its verdict is `supported`. A credential-only CI skip must stay
explicit. In that mode, a compiled startup-only stub lets core layers run without provider credentials; provider turns
remain skipped and are covered only by fresh, matching manual evidence for both Claude and Codex. See
`scenarios/windows-runtime-smoke.md`; ARM64 provider evidence cannot replace native x64 artifact, SQLite, installer, or
core-runtime proof.

## Scenarios

Scenarios live under `scenarios/` and reference profiles by name and port in their YAML frontmatter. The `test-scenario` skill (at `.claude/skills/test-scenario/`) parses the frontmatter, verifies or starts the required profile, drives browser + API steps, and produces a structured pass/fail report.

Run a scenario by name (resolved under `dev/testing/scenarios/`) or by path:

```
/test-scenario session-lifecycle
/test-scenario dev/testing/scenarios/session-lifecycle.md
```

See `scenarios/README.md` for the scenario file format, sub-scenario conventions, and screenshot evidence layout.

## `.gitignore` Convention

`dev/testing/.gitignore` strips runtime artifacts (sessions, tasks, kv.json, search.db, etc.) from every profile by default, then re-includes the `visual` profile's seeded corpus because that profile relies on committed fixture data to render scenario-critical pages. New profiles inherit the strip-by-default behavior — add explicit `!profiles/<name>/...` re-includes if a profile needs committed seed data.
