# CLI Operations

The CLI now has two execution modes for workflow operations:

Examples in this page use `dartclaw` as the command name. If you are running from a source checkout, use `build/dartclaw` after `bash tool/build.sh`, or replace `dartclaw` with `dart run dartclaw_cli:dartclaw`.

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

Standalone mode is available for workflow execution and status inspection:

```bash
dartclaw workflow run spec-and-implement --standalone --force --var FEATURE="Add alerts"
dartclaw workflow run spec-and-implement --standalone --json --var FEATURE="Add alerts"
dartclaw workflow status <run-id> --standalone
```

Use standalone mode when:

- no server is running
- you want a one-off local workflow execution
- you intentionally want direct local-database inspection

`workflow run --standalone` performs a safety check. If the server is already running on the resolved loopback port, the CLI aborts unless you add `--force`.

## Headless CI Usage

`workflow run` is already blocking and headless-friendly:

- exit `0` = completed
- exit `1` = failed
- exit `2` = paused for approval or cancelled

Use `--json` when you want machine-readable progress. Connected mode streams server-backed SSE events; standalone mode emits the same high-value lifecycle events directly from the local executor.

### Standalone one-shot run

Use this when your CI job only needs a single local run and does not need a long-lived server:

```bash
dartclaw workflow run code-review \
  --standalone \
  --json \
  --var PR_NUMBER=42 \
  --var REPO=owner/repo
```

### Connected mode in automation

Use this when the pipeline needs server-backed lifecycle control (`workflow runs`, `pause`, `resume`, `cancel`) or when multiple commands should share the same live runtime state:

```bash
dartclaw serve >dartclaw.log 2>&1 &
dartclaw workflow run code-review --json --var PR_NUMBER=42
```

### Approval steps

Standalone mode auto-accepts normal step review gates, but explicit workflow `approval` steps still pause the run and return exit code `2`. For CI:

- avoid `approval` steps in non-interactive workflows
- or run the server and use connected `workflow resume` / `workflow cancel`

### GitHub Actions example

Configure `codex-exec` with an explicit sandbox before using it in CI:

```yaml
agent:
  provider: codex-exec

providers:
  codex-exec:
    executable: codex
    sandbox: workspace-write
```

```yaml
- name: Run DartClaw workflow
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    CODEX_API_KEY: ${{ secrets.OPENAI_API_KEY }}
  run: |
    dartclaw workflow run code-review \
      --standalone \
      --json \
      --var PR_NUMBER="${{ github.event.pull_request.number }}" \
      --var REPO="${{ github.repository }}"
```

When using the `codex-exec` provider in CI, prefer `CODEX_API_KEY` and set the least-permissive sandbox that still fits the workflow. When using the persistent `codex` provider, use the Codex CLI's normal login/auth flow or a compatible API-key setup for that binary.

## Authentication

Connected commands resolve auth in this order:

1. `gateway.token` from config
2. persisted `gateway_token` in the data directory
3. no auth header when `gateway.auth_mode: none`

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
