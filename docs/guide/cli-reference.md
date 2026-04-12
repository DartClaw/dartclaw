# DartClaw CLI Reference

Reference for the `dartclaw` command-line interface.

The CLI is organized around a small number of top-level command families:

- `serve`
- `status`
- `token`
- `sessions`
- `workflow`
- `rebuild-index`
- `deploy`
- `init`
- `service`
- `google-auth`

## Serve and Status

### `serve`

Start the HTTP server, web UI, and background runtime wiring.

```bash
dart run dartclaw_cli:dartclaw serve
dart run dartclaw_cli:dartclaw serve --port 3333
```

### `status`

Print a compact runtime status summary.

```bash
dart run dartclaw_cli:dartclaw status
```

## Tokens

### `token show`

Show the current auth token or token metadata.

```bash
dart run dartclaw_cli:dartclaw token show
```

### `token rotate`

Generate a replacement token.

```bash
dart run dartclaw_cli:dartclaw token rotate
```

## Sessions

### `sessions cleanup`

Remove stale or archived sessions.

```bash
dart run dartclaw_cli:dartclaw sessions cleanup
```

## Workflows

### `workflow list`

List built-in and custom workflows.

```bash
dart run dartclaw_cli:dartclaw workflow list
dart run dartclaw_cli:dartclaw workflow list --json
```

### `workflow run`

Run a workflow by name.

```bash
dart run dartclaw_cli:dartclaw workflow run spec-and-implement --var FEATURE="Add search"
```

### `workflow status`

Inspect a workflow run.

```bash
dart run dartclaw_cli:dartclaw workflow status <run-id>
```

### `workflow validate`

Validate a workflow YAML file locally. Exit `0` for clean or warnings-only files; exit `1` for parse or validation errors.

```bash
dart run dartclaw_cli:dartclaw workflow validate path/to/workflow.yaml
```

## Index Rebuild

### `rebuild-index`

Rebuild the search index from memory sources.

```bash
dart run dartclaw_cli:dartclaw rebuild-index
```

## Deployment

### `deploy setup`

Set up deployment prerequisites.

```bash
dart run dartclaw_cli:dartclaw deploy setup
```

### `deploy config`

Write or validate deployment configuration.

```bash
dart run dartclaw_cli:dartclaw deploy config
```

### `deploy secrets`

Manage deployment secrets wiring.

```bash
dart run dartclaw_cli:dartclaw deploy secrets
```

## Onboarding and Services

### `init`

Initialize a new DartClaw instance.

```bash
dart run dartclaw_cli:dartclaw init
dart run dartclaw_cli:dartclaw init --non-interactive
```

### `service`

Install, start, stop, or inspect the service wrapper.

```bash
dart run dartclaw_cli:dartclaw service status
dart run dartclaw_cli:dartclaw service install
dart run dartclaw_cli:dartclaw service start
dart run dartclaw_cli:dartclaw service stop
dart run dartclaw_cli:dartclaw service uninstall
```

## Google Auth

### `google-auth`

Manage Google service authorization for Gmail and related integrations.

```bash
dart run dartclaw_cli:dartclaw google-auth
```

## Notes

- Command names and flags are documented by the CLI source in `apps/dartclaw_cli/lib/src/commands/`.
- Examples above favor the public `dartclaw` launcher and the most common flows.
- `workflow validate` is the deterministic validation surface for workflow YAML before execution.
