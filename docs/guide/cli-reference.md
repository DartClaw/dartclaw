# DartClaw CLI Reference

Reference for the `dartclaw` command-line interface.

Examples in this page use `dartclaw` as the command name. If you are running from a source checkout, use `build/dartclaw` after `bash dev/tools/build.sh`, or replace `dartclaw` with `dart run dartclaw_cli:dartclaw`.

Global flags:

```bash
dartclaw --config /path/to/dartclaw.yaml status
dartclaw --server localhost:4000 workflow runs
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
- `setup`
- `status`
- `tasks`
- `token`
- `traces`
- `workflow`

## Serve and Status

### `serve`

```bash
dartclaw serve
dartclaw serve --port 3333
```

### `status`

```bash
dartclaw status
```

## Agents

### `agents list`

```bash
dartclaw agents list
dartclaw agents list --json
```

### `agents show`

```bash
dartclaw agents show 0
dartclaw agents show 0 --json
```

## Config

### `config show`

```bash
dartclaw config show
dartclaw config show --json
```

### `config get`

```bash
dartclaw config get agent.model
dartclaw config get alerts.enabled
```

### `config set`

```bash
dartclaw config set alerts.enabled false
dartclaw config set tasks.max_concurrent 3
dartclaw config set alerts.enabled false --json
```

## Jobs

### `jobs list`

```bash
dartclaw jobs list
dartclaw jobs list --json
```

### `jobs create`

```bash
dartclaw jobs create --name daily-summary --schedule "0 8 * * *" --prompt "Summarize yesterday"
dartclaw jobs create --name nightly-review --schedule "0 22 * * *" --type task --title "Review backlog" --description "Inspect stale tasks" --task-type analysis
dartclaw jobs create --name daily-summary --schedule "0 8 * * *" --prompt "Summarize yesterday" --json
```

### `jobs show`

```bash
dartclaw jobs show daily-summary
dartclaw jobs show daily-summary --json
```

### `jobs delete`

```bash
dartclaw jobs delete daily-summary
dartclaw jobs delete daily-summary --json
```

## Projects

### `projects list`

```bash
dartclaw projects list
dartclaw projects list --json
```

### `projects add`

```bash
dartclaw projects add --name dartclaw --remote-url git@github.com:DartClaw/dartclaw.git --credentials-ref github-main
dartclaw projects add --name docs --remote-url https://github.com/org/docs.git --branch main --credentials-ref github-main
dartclaw projects add --name dartclaw --remote-url git@github.com:DartClaw/dartclaw.git --credentials-ref github-main --json
```

### `projects show`

```bash
dartclaw projects show <project-id>
dartclaw projects show <project-id> --json
```

### `projects fetch`

```bash
dartclaw projects fetch <project-id>
dartclaw projects fetch <project-id> --json
```

### `projects remove`

```bash
dartclaw projects remove <project-id>
dartclaw projects remove <project-id> --yes
dartclaw projects remove <project-id> --yes --json
```

## Sessions

### `sessions list`

```bash
dartclaw sessions list
dartclaw sessions list --type task
dartclaw sessions list --type task --json
```

### `sessions show`

```bash
dartclaw sessions show <session-id>
dartclaw sessions show <session-id> --json
```

### `sessions messages`

```bash
dartclaw sessions messages <session-id>
dartclaw sessions messages <session-id> --limit 20 --full
dartclaw sessions messages <session-id> --limit 20 --json
```

### `sessions archive`

```bash
dartclaw sessions archive <session-id>
dartclaw sessions archive <session-id> --json
```

### `sessions delete`

```bash
dartclaw sessions delete <session-id>
dartclaw sessions delete <session-id> --json
```

### `sessions cleanup`

```bash
dartclaw sessions cleanup
```

## Tasks

### `tasks list`

```bash
dartclaw tasks list
dartclaw tasks list --status running --type coding --limit 10
dartclaw tasks list --status running --json
```

### `tasks show`

```bash
dartclaw tasks show <task-id>
dartclaw tasks show <task-id> --json
```

### `tasks create`

```bash
dartclaw tasks create --title "Fix alerts" --description "Review 0.16.4 alert routing" --type analysis
dartclaw tasks create --title "Review PR" --description "Inspect project state" --type coding --project <project-id> --provider codex --auto-start
dartclaw tasks create --title "Fix alerts" --description "Review 0.16.4 alert routing" --type analysis --json
```

### `tasks start`

```bash
dartclaw tasks start <task-id>
dartclaw tasks start <task-id> --json
```

### `tasks cancel`

```bash
dartclaw tasks cancel <task-id>
dartclaw tasks cancel <task-id> --json
```

### `tasks review`

```bash
dartclaw tasks review <task-id> --action accept
dartclaw tasks review <task-id> --action push_back --comment "Tighten the API error handling"
dartclaw tasks review <task-id> --action accept --json
```

## Tokens and Index

### `token show`

```bash
dartclaw token show
```

### `token rotate`

```bash
dartclaw token rotate
```

### `rebuild-index`

```bash
dartclaw rebuild-index
```

## Traces

### `traces list`

```bash
dartclaw traces list
dartclaw traces list --provider claude --since 1h --limit 20
dartclaw traces list --provider claude --since 1h --limit 20 --json
```

### `traces show`

```bash
dartclaw traces show <turn-id>
dartclaw traces show <turn-id> --json
```

## Workflows

### `workflow list`

```bash
dartclaw workflow list
dartclaw workflow list --json
```

### `workflow run`

```bash
dartclaw workflow run spec-and-implement --var FEATURE="Add search"
dartclaw workflow run spec-and-implement --json
dartclaw workflow run spec-and-implement --standalone --force --var FEATURE="Local run"
dartclaw workflow run spec-and-implement --standalone --json --var FEATURE="CI run"
```

### `workflow runs`

```bash
dartclaw workflow runs
dartclaw workflow runs --status running --definition code-review --json
```

### `workflow pause`

```bash
dartclaw workflow pause <run-id>
dartclaw workflow pause <run-id> --json
```

### `workflow resume`

```bash
dartclaw workflow resume <run-id>
dartclaw workflow resume <run-id> --json
```

### `workflow cancel`

```bash
dartclaw workflow cancel <run-id>
dartclaw workflow cancel <run-id> --feedback "Reject current review"
dartclaw workflow cancel <run-id> --feedback "Reject current review" --json
```

### `workflow status`

```bash
dartclaw workflow status <run-id>
dartclaw workflow status <run-id> --json
dartclaw workflow status <run-id> --standalone
```

### `workflow validate`

```bash
dartclaw workflow validate path/to/workflow.yaml
```

## Deployment and Services

### `deploy setup`

```bash
dartclaw deploy setup
```

### `deploy config`

```bash
dartclaw deploy config
```

### `deploy secrets`

```bash
dartclaw deploy secrets
```

### `init`

```bash
dartclaw init
dartclaw init --non-interactive
dartclaw setup
```

### `service`

```bash
dartclaw service status
dartclaw service install
dartclaw service start
dartclaw service stop
dartclaw service uninstall
```

### `google-auth`

```bash
dartclaw google-auth
```
