# DartClaw Testing — Profiles, Scenarios, and Smoke Tests

This directory hosts everything needed to run DartClaw against pre-configured environments:

- **`profiles/`** — pre-configured DartClaw environments and command runners. Server profiles include seeded data and
  a `run.sh`; Windows-native profiles use PowerShell. Used by `UI-SMOKE-TEST.md`, by the
  `dev/tools/release_check.sh` manual gates, and by scenario files.
- **`scenarios/`** — AI-native acceptance scenarios. Markdown files with YAML frontmatter that describe full-system interactions (browser + API + governance) in natural language. Run via the `test-scenario` skill — see `scenarios/README.md`.
- **`UI-SMOKE-TEST.md`** — the canonical 31-case UI smoke test, run against the `plain` profile.

## Profile Quick Reference

| Profile | Port | Run command | Purpose |
|---|---|---|---|
| `plain` | 3335 | `bash dev/testing/profiles/plain/run.sh` | Minimal seeded data, no channels. Backs `UI-SMOKE-TEST.md` and most `scenarios/session-*` scenarios. |
| `channels` | 3336 | `bash dev/testing/profiles/channels/run.sh` | WhatsApp + Signal channels enabled. Hardware pairing flow is documented in `dartclaw-private/docs/testing/channel-e2e-manual.md`. |
| `governance` | 3337 | `bash dev/testing/profiles/governance/run.sh` | Tight governance limits + budget seeding. Backs the governance-enforcement scenario. |
| `visual` | 3338 | `bash dev/testing/profiles/visual/run.sh` | Desktop visual smoke profile. Feature-visibility flags on so Health/Memory/Tasks/Projects/Workflows all render with seeded content. |
| `workflows` | 3333 | `bash dev/testing/profiles/workflows/run.sh` | Codex-first workflow execution against the `DartClaw/workflow-test-todo-app` fixture repo. Publish runs need a GitHub token; `run.sh` takes `GITHUB_TOKEN`, else the fixture askpass file, else `gh auth token`. |
| `workflow-contract` | n/a | `bash dev/testing/profiles/workflow-contract/run.sh` | Fast deterministic workflow contract checks. Use while iterating on workflow YAML, gates, output contracts, and resolver behavior. |
| `workflow-live` | n/a | `bash dev/testing/profiles/workflow-live/run.sh --canary <name>` | Explicit live workflow integration canaries and full sweep. Codex requires the installed AndThen plugin; the runner copies and enables it in a hermetic `CODEX_HOME`, then runs fail-fast provider/model preflight (`--skip-preflight` to skip). Captures logs and summarizes warning patterns. |
| `container` | 3341 | `bash dev/testing/profiles/container/run.sh` | Real container isolation end to end: a turn runs inside a container, the container holds no provider credential, and a task tool is served over the MCP bridge. Reports a stated skip when no container runtime answers. |
| `container --ci` | 3342 | `bash dev/testing/profiles/container/run.sh --ci` | What CI runs. Boots a config declaring **no** `container:` section and asserts the posture resolved to container isolation, so an advisory downgrade fails instead of passing. An absent runtime is a failure, not a skip. Issues no model turn and needs no credential, so it runs on a fork PR. |
| `windows-runtime` | 3340 | `./dev/testing/profiles/windows-runtime/run.ps1 -ArtifactPath <zip> -SkipProviders` | Native Windows x64 release smoke: server, Web UI, FTS5, and file-watch reload. Claude and Codex turns are optional compatibility layers. Writes the layered report to `.agent_temp/windows-runtime-smoke.md`. |

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

The Windows runtime profile is release-ready only when its artifact-mode verdict is `supported`. `-SkipProviders` stays
explicit and uses a startup-only stub so the deterministic core layers run without credentials. Omit it to revalidate
live Claude and Codex compatibility after relevant integration changes. See `scenarios/windows-runtime-smoke.md`.

`-ArtifactPath` is the supported mode: the release bundle carries `lib/sqlite3.dll` and the profile loads it from
there. **`-SourceDir` additionally requires `.dart_tool/lib/sqlite3.dll` in that checkout, and no repo tooling
provisions it** — neither `dart pub get` nor any build script writes that file, so source mode on a fresh Windows
checkout stops at `source-setup` until the module is supplied. Use artifact mode unless you have a reason not to.
The `windows-x64-host` layer reports `skipped` on an arm64 Windows host, which alone keeps that host from ever
reaching a release-ready verdict.

Scoop qualification is defined separately in `scenarios/windows-scoop.md`. Keep install/update/uninstall audits separate
from the deterministic tag workflow; local reports belong under `.agent_temp/`.

## Scenarios

Scenarios live under `scenarios/` and reference profiles by name and port in their YAML frontmatter. The `test-scenario` skill (at `.claude/skills/test-scenario/`) parses the frontmatter, verifies or starts the required profile, drives browser + API steps, and produces a structured pass/fail report.

Run a scenario by name (resolved under `dev/testing/scenarios/`) or by path:

```
/test-scenario session-lifecycle
/test-scenario dev/testing/scenarios/session-lifecycle.md
```

See `scenarios/README.md` for the scenario file format, sub-scenario conventions, and screenshot evidence layout.

## `.gitignore` Convention

**The `visual` seed is a canonical memory workspace, and must stay one.** It is the only profile that seeds
`workspace/memory/`, so it is the only one a memory-dialect change can break. 0.25 replaced the boot-time
`LegacyMemoryMigrator` with a fail-fast preflight, and the seed — still in the preview dialect, because the
migrator had been silently converting it on every run — stopped booting: `Memory preflight: failed / Stage:
legacy-dialect-detected`. It was converted by running the shipped upgrade path, `v0.24.2` once against a copy,
and the committed workspace is that output. A future change to the memory dialect has to convert this seed in
the same commit, or the profile stops starting.

`dev/testing/.gitignore` strips runtime artifacts (sessions, tasks, kv.json, search.db, etc.) from every profile by default, then re-includes the `visual` profile's seeded corpus because that profile relies on committed fixture data to render scenario-critical pages. New profiles inherit the strip-by-default behavior — add explicit `!profiles/<name>/...` re-includes if a profile needs committed seed data.
