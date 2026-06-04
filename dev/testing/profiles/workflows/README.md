# Workflow Testing Profile

Run generic DartClaw workflows against the dedicated workflow-test-todo-app repository:
`https://github.com/DartClaw/workflow-test-todo-app`.
This profile provides a pre-configured environment with custom workflow workspace, governance budgets, guard rails, and a Codex-first workflow configuration.

The `run.sh` script handles config templating (absolute paths for `data_dir` and `workflow.workspace_dir`) and supports both CLI and server modes.

## Built-In Workflow Source

This profile uses the built-in workflow definitions materialized at runtime into `data/workspace/workflows/`.

- Do not treat `dev/testing/profiles/workflows/data/workspace/workflows/` as an authored source directory.
- The runtime copies built-in workflow YAMLs into that directory when missing.
- The directory is ignored in `dev/testing/.gitignore` so generic built-ins do not need to be checked in here.
- If you need profile-specific workflow behavior, add a separate profile with intentional checked-in overrides instead of editing the generic fixture snapshot.

## Fixture Preflight

The `workflow-test-todo-app` repository lives under `dev/testing/profiles/workflows/data/projects/` as a nested git checkout. Reset it before every smoke or publish run:

```bash
bash dev/testing/profiles/workflows/fixture.sh reset
```

That command removes known smoke-generated artifacts, verifies the fixture-local `AGENTS.md` and `CLAUDE.md` boundary instructions, allows those two files to exist as local boundary overlays when they are untracked in the nested fixture repo, and fails if any other fixture drift remains. Treat unexpected fixture drift as a setup problem, not as workflow evidence.

## Provider Setup

This testing profile is configured to use Codex explicitly:

- `agent.provider: codex` with `agent.model: gpt-5.4`
- `workflow.defaults.*` pinned to Codex models for workflow/planner/executor/reviewer roles
- `providers.codex.approval: never` to avoid Codex approval deadlocks on non-interactive workflow turns
- `providers.codex.sandbox: danger-full-access` so Codex-side sandboxing does not block the workflow profile

Before running the profile, make sure Codex is available and authenticated:

```bash
codex --version
export CODEX_API_KEY="sk-..."
export GITHUB_TOKEN="ghp_..."
```

`credentials.openai.api_key` in the profile reads `CODEX_API_KEY`.
`credentials.github-main` reads `GITHUB_TOKEN` and is the supported path for clone/fetch/push/PR automation against the workflow-test-todo-app repository.

## CLI Mode

Current CLI behavior is split:

- `workflow list`, `workflow validate`, and `workflow run --standalone` are local CLI execution paths
- `workflow run` without `--standalone`, plus `workflow runs`, `workflow status`, `workflow pause`, `workflow resume`, and `workflow cancel`, are server-backed operations

If you want lifecycle controls and the `/workflows/<run-id>` UI, start the server first and use the connected commands against that live instance.

### Capture mode guidance

When you need `workflow run ... --json` output for a scenario, prefer a dedicated foreground shell plus `tee`:

```bash
workflow_cli run spec-and-implement ... --json | tee /tmp/workflow-run.jsonl
```

Background redirection from the agent shell is currently non-authoritative. Use it only after you have reproduced it in a normal terminal outside the agent shell.

### CLI helper

Use `run.sh workflow ...` directly. It already renders the temporary runtime config and launches the CLI in source mode:

```bash
workflow_cli() {
  bash dev/testing/profiles/workflows/run.sh workflow "$@"
}
```

### List available workflows

```bash
workflow_cli list
workflow_cli list --json
```

### Validate a workflow definition

```bash
workflow_cli validate path/to/workflow.yaml
```

### Execute a workflow locally

Use `--standalone` when you explicitly want an in-process local run with no server dependency:

```bash
workflow_cli run spec-and-implement --standalone \
  -v 'FEATURE=Add a small note to the workflow-test-todo-app fixture README'
```

### Execute A Single Feature (`spec-and-implement`)

The `spec-and-implement` workflow is the right choice for implementing a single feature in the fixture repository. It runs: discover project → spec → review spec → implement → validate → integrated review → remediation loop → update state, with deterministic publish handled by `gitStrategy`.

```bash
workflow_cli run spec-and-implement \
  -v 'FEATURE=<description of the small fixture-repo change to build>'
```

**Example — small fixture change:**

```bash
workflow_cli run spec-and-implement \
  -v 'FEATURE=Add a short release note section to the fixture README and a matching note under docs/'
```

The workflow no longer relies on a manual spec approval checkpoint. Spec review/remediation is automated in-flow.

### Execute a plan (`plan-and-implement`)

The `plan-and-implement` workflow is for implementing a multi-story scope in the fixture repository. It runs: discover project → plan stories → spec-plan (refine story set and produce per-story specs) → per-story foreach pipeline (implement → refactor-validate → quick-review for each story) → plan-level review → remediation loop → update state, with deterministic publish handled by `gitStrategy`. All orchestration is declared in the workflow definition; no hidden runtime steps are synthesized.

```bash
workflow_cli run plan-and-implement \
  -v 'REQUIREMENTS=<small multi-step fixture-repo scope>'
```

**Example — small batch scope:**

```bash
workflow_cli run plan-and-implement \
  -v 'REQUIREMENTS=Add a tiny release note, a follow-up docs page, and one consistency cleanup in the workflow-test-todo-app fixture repo.'
```

### Review a PR (`code-review`)

```bash
workflow_cli run code-review \
  -v 'TARGET=Review pull request #42 for workflow trigger surface regressions and missing tests' \
  -v 'PR_NUMBER=42' \
  -p workflow-test-todo-app
```

### With project scoping

Add `-p <project-id>` to run coding steps in a project worktree:

```bash
workflow_cli run spec-and-implement \
  -v 'FEATURE=...' \
  -p my-project-id
```

### CLI exit codes

| Code | Meaning |
|------|---------|
| 0 | Workflow completed successfully |
| 1 | Workflow failed |
| 2 | Workflow paused for approval or manual recovery, or was cancelled |

Press `Ctrl+C` once to cancel gracefully, twice to force exit.

## Server Mode (Web UI + API)

Start the server for web UI monitoring, approval handling, or API-based triggering:

```bash
bash dev/testing/profiles/workflows/run.sh
```

Opens on port 3333 (override with `--port <N>`). Auth token: `devtoken0` (in `data/gateway_token`).

### Verify

```bash
TOKEN=$(cat dev/testing/profiles/workflows/data/gateway_token)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:3333/api/workflows/definitions | jq 'length'   # expect 3
```

### Connected CLI against the running server

With the server running, these commands use the live instance state:

```bash
workflow_cli run spec-and-implement \
  -v 'FEATURE=Add a tiny documentation note under dev/testing/profiles/workflows/'

workflow_cli runs
workflow_cli runs --definition spec-and-implement
workflow_cli status <run-id>
workflow_cli pause <run-id>
workflow_cli resume <run-id>
workflow_cli cancel <run-id>
```

### Web UI

Open http://localhost:3333 — navigate to the **Workflows** page for:
- Run list with status filters and progress bars
- Run detail with step pipeline, shared context viewer, and approval controls when a workflow definition uses approval steps
- Per-step expansion with conversation transcripts and artifacts

### API trigger

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  http://localhost:3333/api/workflows/run \
  -d '{"definition": "spec-and-implement", "variables": {"FEATURE": "..."}}' | jq
```

### Workflow controls

```bash
# Pause / Resume / Cancel
curl -sX POST -H "Authorization: Bearer $TOKEN" http://localhost:3333/api/workflows/runs/<id>/pause
curl -sX POST -H "Authorization: Bearer $TOKEN" http://localhost:3333/api/workflows/runs/<id>/resume
curl -sX POST -H "Authorization: Bearer $TOKEN" http://localhost:3333/api/workflows/runs/<id>/cancel
```

## Scenario Coverage

There is one live scenario per built-in workflow. Each drives a real run to a clean `completed` state with the smallest possible documentation-only prompt, then closes the published PR as cleanup. Their job is the operator-facing surface — the Web UI and the connected CLI → server → SSE path — not the engine mechanics:

- `dev/testing/scenarios/workflow-spec-and-implement-publish.md` — runs `spec-and-implement` end to end, verifies the workflows list, the run detail page, live progress and a clean completion state, then closes the published PR
- `dev/testing/scenarios/workflow-plan-and-implement-publish.md` — runs `plan-and-implement` end to end (`MAX_PARALLEL=2`, two thin stories so the parallel per-story path executes), verifies the same UI surface, then closes the published PR

Engine mechanics — per-task/per-story worktree creation, branch push, GitHub PR creation and PR diff contents — are **not** re-asserted here. They are owned by the automated integration test `packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart` (TI03 spec-and-implement, TI04 plan-and-implement), which runs the same workflows against this same repository with a real harness, distinct per-story worktrees, real `gh pr create`, and automatic PR cleanup. Run it with `dart test --run-skipped -t integration`.

Cancellation and operator-interruption coverage should live in explicit, named cancellation scenarios rather than in the live completion scenario.

All of these scenarios use deliberately tiny documentation-only prompts so the authored workflow output stays narrow and repeatable.

The workflow testing profile sets `tasks.completion_action: accept` so workflow-owned coding tasks do not stall in manual review during unattended scenario runs.
It also sets `projects.workflow-test-todo-app.credentials: github-main`, so publish scenarios require `GITHUB_TOKEN` instead of `gh auth login`.

## Available Workflows

| Workflow | Use case | Required variables | Optional variables |
|----------|----------|--------------------|--------------------|
| `spec-and-implement` | Single feature / FIS | `FEATURE` | `PROJECT`, `BRANCH` |
| `plan-and-implement` | Multi-story milestone / PRD | `REQUIREMENTS` | `PROJECT`, `BRANCH`, `MAX_PARALLEL` |
| `code-review` | PR or branch review | `TARGET` | `BRANCH`, `PR_NUMBER`, `BASE_BRANCH`, `PROJECT` |
| `research-and-evaluate` | Research with evaluation | See definition | |

## Configuration

- **Token budget**: 5M daily tokens
- **Loop detection**: Enabled
- **Guards**: Enabled
- **Workflow workspace**: `data/workflow-workspace/` — fixture-specific agent instructions injected into workflow steps

## Directory Structure

```
data/
  dartclaw.yaml           # Config template (paths templated at runtime by run.sh)
  gateway_token           # Auth token (server mode only)
  workflow-workspace/     # Behavior files injected into workflow step execution
    AGENTS.md             # Fixture-specific instructions for workflow agents
    TOOLS.md              # Tool/command reference
  workspace/              # Behavior files for interactive chat sessions
    workflows/            # Runtime-materialized built-in workflows (not authored here)
  sessions/               # Session data (auto-created)
```
