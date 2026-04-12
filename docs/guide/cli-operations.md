# CLI Operations

The CLI now has two execution modes for workflow operations:

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
dart run dartclaw_cli:dartclaw workflow run spec-and-implement --standalone --force --var FEATURE="Add alerts"
dart run dartclaw_cli:dartclaw workflow status <run-id> --standalone
```

Use standalone mode when:

- no server is running
- you want a one-off local workflow execution
- you intentionally want direct local-database inspection

`workflow run --standalone` performs a safety check. If the server is already running on the resolved loopback port, the CLI aborts unless you add `--force`.

## Authentication

Connected commands resolve auth in this order:

1. `gateway.token` from config
2. persisted `gateway_token` in the data directory
3. no auth header when `gateway.auth_mode: none`

The CLI never prints the raw gateway token in user-facing error output.

## Global Flags

Two global flags matter for operational usage:

```bash
dart run dartclaw_cli:dartclaw --config /path/to/dartclaw.yaml status
dart run dartclaw_cli:dartclaw --server localhost:4000 workflow runs
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
dart run dartclaw_cli:dartclaw workflow run spec-and-implement --var FEATURE="Add project commands"

# Inspect and control active workflow runs
dart run dartclaw_cli:dartclaw workflow runs
dart run dartclaw_cli:dartclaw workflow pause <run-id>
dart run dartclaw_cli:dartclaw workflow resume <run-id>
dart run dartclaw_cli:dartclaw workflow cancel <run-id> --feedback "Needs rework"

# Use the CLI as a headless operations surface for a running instance
dart run dartclaw_cli:dartclaw tasks list
dart run dartclaw_cli:dartclaw projects list
dart run dartclaw_cli:dartclaw config show
dart run dartclaw_cli:dartclaw sessions list
```
