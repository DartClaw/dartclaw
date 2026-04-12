# DartClaw CLI Reference

Reference for the `dartclaw` command-line interface.

Global flags:

```bash
dart run dartclaw_cli:dartclaw --config /path/to/dartclaw.yaml status
dart run dartclaw_cli:dartclaw --server localhost:4000 workflow runs
```

Top-level command families:

- `agents`
- `config`
- `deploy`
- `google-auth`
- `init`
- `jobs`
- `projects`
- `rebuild-index`
- `service`
- `sessions`
- `serve`
- `status`
- `tasks`
- `token`
- `traces`
- `workflow`

## Serve and Status

### `serve`

```bash
dart run dartclaw_cli:dartclaw serve
dart run dartclaw_cli:dartclaw serve --port 3333
```

### `status`

```bash
dart run dartclaw_cli:dartclaw status
```

## Agents

### `agents list`

```bash
dart run dartclaw_cli:dartclaw agents list
dart run dartclaw_cli:dartclaw agents list --json
```

### `agents show`

```bash
dart run dartclaw_cli:dartclaw agents show 0
dart run dartclaw_cli:dartclaw agents show 0 --json
```

## Config

### `config show`

```bash
dart run dartclaw_cli:dartclaw config show
dart run dartclaw_cli:dartclaw config show --json
```

### `config get`

```bash
dart run dartclaw_cli:dartclaw config get agent.model
dart run dartclaw_cli:dartclaw config get alerts.enabled
```

### `config set`

```bash
dart run dartclaw_cli:dartclaw config set alerts.enabled false
dart run dartclaw_cli:dartclaw config set tasks.max_concurrent 3
dart run dartclaw_cli:dartclaw config set alerts.enabled false --json
```

## Jobs

### `jobs list`

```bash
dart run dartclaw_cli:dartclaw jobs list
dart run dartclaw_cli:dartclaw jobs list --json
```

### `jobs create`

```bash
dart run dartclaw_cli:dartclaw jobs create --name daily-summary --schedule "0 8 * * *" --prompt "Summarize yesterday"
dart run dartclaw_cli:dartclaw jobs create --name nightly-review --schedule "0 22 * * *" --type task --title "Review backlog" --description "Inspect stale tasks" --task-type analysis
```

### `jobs show`

```bash
dart run dartclaw_cli:dartclaw jobs show daily-summary
dart run dartclaw_cli:dartclaw jobs show daily-summary --json
```

### `jobs delete`

```bash
dart run dartclaw_cli:dartclaw jobs delete daily-summary
dart run dartclaw_cli:dartclaw jobs delete daily-summary --json
```

## Projects

### `projects list`

```bash
dart run dartclaw_cli:dartclaw projects list
dart run dartclaw_cli:dartclaw projects list --json
```

### `projects add`

```bash
dart run dartclaw_cli:dartclaw projects add --name dartclaw --remote-url git@github.com:DartClaw/dartclaw.git
dart run dartclaw_cli:dartclaw projects add --name docs --remote-url https://github.com/org/docs.git --branch main --credentials-ref github-main
```

### `projects show`

```bash
dart run dartclaw_cli:dartclaw projects show <project-id>
dart run dartclaw_cli:dartclaw projects show <project-id> --json
```

### `projects fetch`

```bash
dart run dartclaw_cli:dartclaw projects fetch <project-id>
dart run dartclaw_cli:dartclaw projects fetch <project-id> --json
```

### `projects remove`

```bash
dart run dartclaw_cli:dartclaw projects remove <project-id>
dart run dartclaw_cli:dartclaw projects remove <project-id> --yes
```

## Sessions

### `sessions list`

```bash
dart run dartclaw_cli:dartclaw sessions list
dart run dartclaw_cli:dartclaw sessions list --type task
```

### `sessions show`

```bash
dart run dartclaw_cli:dartclaw sessions show <session-id>
dart run dartclaw_cli:dartclaw sessions show <session-id> --json
```

### `sessions messages`

```bash
dart run dartclaw_cli:dartclaw sessions messages <session-id>
dart run dartclaw_cli:dartclaw sessions messages <session-id> --limit 20 --full
```

### `sessions archive`

```bash
dart run dartclaw_cli:dartclaw sessions archive <session-id>
dart run dartclaw_cli:dartclaw sessions archive <session-id> --json
```

### `sessions delete`

```bash
dart run dartclaw_cli:dartclaw sessions delete <session-id>
dart run dartclaw_cli:dartclaw sessions delete <session-id> --json
```

### `sessions cleanup`

```bash
dart run dartclaw_cli:dartclaw sessions cleanup
```

## Tasks

### `tasks list`

```bash
dart run dartclaw_cli:dartclaw tasks list
dart run dartclaw_cli:dartclaw tasks list --status running --type coding --limit 10
```

### `tasks show`

```bash
dart run dartclaw_cli:dartclaw tasks show <task-id>
dart run dartclaw_cli:dartclaw tasks show <task-id> --json
```

### `tasks create`

```bash
dart run dartclaw_cli:dartclaw tasks create --title "Fix alerts" --description "Review 0.16.4 alert routing" --type analysis
dart run dartclaw_cli:dartclaw tasks create --title "Review PR" --description "Inspect project state" --type coding --project <project-id> --provider codex --auto-start
```

### `tasks start`

```bash
dart run dartclaw_cli:dartclaw tasks start <task-id>
dart run dartclaw_cli:dartclaw tasks start <task-id> --json
```

### `tasks cancel`

```bash
dart run dartclaw_cli:dartclaw tasks cancel <task-id>
dart run dartclaw_cli:dartclaw tasks cancel <task-id> --json
```

### `tasks review`

```bash
dart run dartclaw_cli:dartclaw tasks review <task-id> --action accept
dart run dartclaw_cli:dartclaw tasks review <task-id> --action push_back --comment "Tighten the API error handling"
```

## Tokens and Index

### `token show`

```bash
dart run dartclaw_cli:dartclaw token show
```

### `token rotate`

```bash
dart run dartclaw_cli:dartclaw token rotate
```

### `rebuild-index`

```bash
dart run dartclaw_cli:dartclaw rebuild-index
```

## Traces

### `traces list`

```bash
dart run dartclaw_cli:dartclaw traces list
dart run dartclaw_cli:dartclaw traces list --provider claude --since 1h --limit 20
```

### `traces show`

```bash
dart run dartclaw_cli:dartclaw traces show <turn-id>
dart run dartclaw_cli:dartclaw traces show <turn-id> --json
```

## Workflows

### `workflow list`

```bash
dart run dartclaw_cli:dartclaw workflow list
dart run dartclaw_cli:dartclaw workflow list --json
```

### `workflow run`

```bash
dart run dartclaw_cli:dartclaw workflow run spec-and-implement --var FEATURE="Add search"
dart run dartclaw_cli:dartclaw workflow run spec-and-implement --json
dart run dartclaw_cli:dartclaw workflow run spec-and-implement --standalone --force --var FEATURE="Local run"
```

### `workflow runs`

```bash
dart run dartclaw_cli:dartclaw workflow runs
dart run dartclaw_cli:dartclaw workflow runs --status running --definition code-review --json
```

### `workflow pause`

```bash
dart run dartclaw_cli:dartclaw workflow pause <run-id>
dart run dartclaw_cli:dartclaw workflow pause <run-id> --json
```

### `workflow resume`

```bash
dart run dartclaw_cli:dartclaw workflow resume <run-id>
dart run dartclaw_cli:dartclaw workflow resume <run-id> --json
```

### `workflow cancel`

```bash
dart run dartclaw_cli:dartclaw workflow cancel <run-id>
dart run dartclaw_cli:dartclaw workflow cancel <run-id> --feedback "Reject current review"
```

### `workflow status`

```bash
dart run dartclaw_cli:dartclaw workflow status <run-id>
dart run dartclaw_cli:dartclaw workflow status <run-id> --standalone
```

### `workflow validate`

```bash
dart run dartclaw_cli:dartclaw workflow validate path/to/workflow.yaml
```

## Deployment and Services

### `deploy setup`

```bash
dart run dartclaw_cli:dartclaw deploy setup
```

### `deploy config`

```bash
dart run dartclaw_cli:dartclaw deploy config
```

### `deploy secrets`

```bash
dart run dartclaw_cli:dartclaw deploy secrets
```

### `init`

```bash
dart run dartclaw_cli:dartclaw init
dart run dartclaw_cli:dartclaw init --non-interactive
```

### `service`

```bash
dart run dartclaw_cli:dartclaw service status
dart run dartclaw_cli:dartclaw service install
dart run dartclaw_cli:dartclaw service start
dart run dartclaw_cli:dartclaw service stop
dart run dartclaw_cli:dartclaw service uninstall
```

### `google-auth`

```bash
dart run dartclaw_cli:dartclaw google-auth
```
