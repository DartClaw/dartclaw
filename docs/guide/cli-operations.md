# CLI Operations

The CLI has two execution modes for workflow operations:

Examples in this page use `dartclaw` as the command name. If you are running from a source checkout, use `build/bin/dartclaw` after `bash dev/tools/build.sh`, or replace `dartclaw` with `dart run dartclaw_cli:dartclaw`.

- `connected mode` is the default. Commands talk to a running DartClaw server over the loopback API.
- `standalone mode` is explicit. Commands run local logic in-process without using the server API.

## Connected Mode

Connected mode is the default for `workflow run`, `workflow status`, `workflow runs`, `workflow pause`, `workflow resume`, and `workflow cancel`.

How it works:

- The CLI resolves the server address from `--server`, then the configured port, then `localhost:3333`.
- It authenticates with `gateway.token` or the persisted `gateway_token` file.
- It uses the HTTP API for command execution and SSE for workflow progress streaming.

Connected mode is the right choice when you are already running `dartclaw serve` and want the CLI to match the server’s workflow, project, task, and session state.

## Standalone Mode

Standalone mode is available for workflow execution, lifecycle control, and status inspection:

```bash
dartclaw workflow run spec-and-implement --standalone --force --var FEATURE="Add alerts"
dartclaw workflow run spec-and-implement --standalone --json --var FEATURE="Add alerts"
dartclaw workflow resume <run-id> --standalone
dartclaw workflow cancel <run-id> --standalone --feedback "wrong approach"
dartclaw workflow status <run-id> --standalone
```

Use standalone mode when:

- no server is running
- you want a one-off local workflow execution
- you intentionally want direct local-database inspection

`workflow run --standalone` performs a safety check. If the server is already running on the resolved loopback port, the CLI aborts unless you add `--force`.

### Standalone lifecycle control

`resume`, `cancel`, `pause`, and `retry` also accept `--standalone`, driving a run's lifecycle in-process against the local task DB — no `dartclaw serve` required. The headline flow takes an approval-paused `workflow run --standalone` to completion server-less: when the run pauses at an `approval` step (exit `2`), `dartclaw workflow resume <run-id> --standalone` records the approval and drives the run to its next settle point (completed / failed / next pause), rendering the same step-progress output as the original run. `cancel --standalone` records the optional `--feedback` as an approval rejection and transitions the run to `cancelled`.

These commands reuse `workflow run --standalone`'s safety guard: they abort against a reachable server unless `--force` is added. The engine's state-transition guards apply — resuming a `running` run or retrying a non-`failed` run prints a clean one-line reason and exits non-zero, never a Dart stack trace. A stale `running` run (left by an abruptly killed standalone process) is **not** auto-reconciled; the guard surfaces it and you re-run once it is back in a resumable state.

### Settle-time digest and step outcomes

A standalone run is legible at the console. When a step fails or holds, the live progress line carries its reason inline — `failed — <reason>` for a hard failure, `blocked (recoverable): <reason>` for a recoverable hold — so you never have to open `context.json` to learn why a step stopped. In `--json` mode the `workflow_step_completed` and `map_iteration_completed` payloads carry additive `outcome` and `reason` fields alongside the existing keys.

When a run settles (completed / paused / awaiting-approval / failed / cancelled), a per-story digest prints: one row per step with its final status, reason, tokens and duration, followed by the concrete next-action commands for this run id (`resume` / `cancel` / `retry --standalone`). In `--json` mode the same digest is emitted as a single structured `workflow_run_digest` object — a per-story array plus `nextActions`, parseable without scraping human text.

**Blocked vs failed.** A `foreach` story that emits `needsInput` (for example, "Docker Desktop must be started…") is recorded as **blocked** — a recoverable, retryable hold — distinct from a hard **failed**. When a still-open story depends on a blocked or failed story, the run pauses for a human (exit `2`) and the pause message names both the blocker and the blocked-on dependent. When nothing still-open depends on it, independent stories continue and the blocked/failed item is reported in the settle-time digest rather than pausing the whole run.

### Inline runs (`--inline`)

`workflow run --inline <name>` runs any existing definition on the **current branch** — no workflow-owned integration branch, no worktree, no merge-back. It overrides the definition's git strategy at run time (`integrationBranch: false` + `worktree: inline`), so you don't need a separate `*-inline` copy of a workflow just to flip the git behavior.

```bash
# Standalone: run on the checked-out branch, work lands directly there
dartclaw workflow run spec-and-implement --standalone --inline --var FEATURE="Add alerts"

# Connected: the CLI sends inline:true; the server applies the same override
dartclaw workflow run spec-and-implement --inline --var FEATURE="Add alerts"
```

- `--inline` applies identically in standalone and connected mode (one shared seam in `WorkflowService.start`).
- Multi-story workflows (`plan-and-implement --inline`) run stories **sequentially** in the shared checkout — concurrency is clamped to 1 automatically, so you never have to pin a parallelism variable by hand.
- `--inline` is **orthogonal** to `--allow-dirty-localpath`: it only changes git strategy and does not relax the dirty-tree guard. Inline mutates the live checkout by design, so the guard still refuses a tree that is already dirty unless you also pass `--allow-dirty-localpath`.
- In connected mode the run mutates the **server's** project checkout on its current branch — be deliberate about where the server is pointed.

## Headless CI Usage

`workflow run` is already blocking and headless-friendly:

- exit `0` = completed
- exit `1` = failed
- exit `2` = paused or cancelled

Use `--json` when you want machine-readable progress. Connected mode streams server-backed SSE events; standalone mode emits the same high-value lifecycle events directly from the local executor.

### Standalone one-shot run

Use this when your CI job only needs a single local run and does not need a long-lived server:

```bash
dartclaw workflow run code-review \
  --standalone \
  --json \
  --var TARGET="Review pull request #42 for regressions and missing tests" \
  --var PR_NUMBER=42 \
  --var PROJECT=my-project-id
```

### Connected mode in automation

Use this when the pipeline needs server-backed lifecycle control (`workflow runs`, `pause`, `resume`, `cancel`) or when multiple commands should share the same live runtime state:

```bash
dartclaw serve >dartclaw.log 2>&1 &
dartclaw workflow run code-review --json \
  --var TARGET="Review pull request #42 for regressions and missing tests" \
  --var PR_NUMBER=42 \
  --var PROJECT=my-project-id
```

### Pause conditions

Standalone mode auto-accepts normal step review gates, but explicit workflow `approval` steps still pause the run and return exit code `2`. Runs can also pause for runtime-managed recovery paths such as `promotion-conflict` or deterministic publish recovery, and cancelled runs also return exit code `2`. For CI:

- avoid `approval` steps in non-interactive workflows
- clear the gate server-less with `dartclaw workflow resume <run-id> --standalone` / `dartclaw workflow cancel <run-id> --standalone`
- or run the server and use connected `workflow resume` / `workflow cancel`

### GitHub Actions example

Configure the provider and sandbox before using Codex in CI:

```yaml
agent:
  provider: codex

providers:
  codex:
    executable: codex
    sandbox: workspace-write
```

```yaml
- name: Run DartClaw workflow
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    CODEX_API_KEY: ${{ secrets.CODEX_API_KEY }}
  run: |
    dartclaw workflow run code-review \
      --standalone \
      --json \
      --var TARGET="Review pull request #${{ github.event.pull_request.number }} for regressions and missing tests" \
      --var PR_NUMBER="${{ github.event.pull_request.number }}" \
      --var PROJECT="${{ vars.DARTCLAW_PROJECT_ID }}"
```

When using Codex in CI, prefer `CODEX_API_KEY` and set the least-permissive sandbox that still fits the workflow.

## Authentication

Connected commands resolve auth in this order:

1. the `--token` global flag, when provided
2. no auth header when `gateway.auth_mode: none`
3. `gateway.token` from config
4. persisted `gateway_token` in the data directory

The CLI never prints the raw gateway token in user-facing error output.

## Global Flags

Two global flags matter for operational usage:

```bash
dartclaw --config /path/to/dartclaw.yaml status
dartclaw --server localhost:4000 workflow runs
```

- `--config` overrides config discovery.
- `--server` overrides the connected loopback server address for API-backed commands.

Per-command `--json` remains local to individual command surfaces.

## Decision Guide

| Situation | Recommended mode |
|---|---|
| Server already running and you want live runtime state | Connected |
| You need workflow SSE progress and lifecycle control | Connected |
| You want task/config/project/session/trace/job operations | Connected |
| No server is running and you want a local workflow run | Standalone |
| You need direct local workflow DB inspection | Standalone |

## Common Flows

```bash
# Run a workflow against the live server
dartclaw workflow run spec-and-implement --var FEATURE="Add project commands"

# Inspect and control active workflow runs
dartclaw workflow runs
dartclaw workflow pause <run-id>
dartclaw workflow resume <run-id>
dartclaw workflow cancel <run-id> --feedback "Needs rework"

# Use the CLI as a headless operations surface for a running instance
dartclaw tasks list
dartclaw projects list
dartclaw config show
dartclaw sessions list
```
