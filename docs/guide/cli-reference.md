# DartClaw CLI Reference

Reference for the `dartclaw` command-line interface.

Examples in this page use `dartclaw` as the command name. If you are running from a source checkout, use `build/bin/dartclaw` after `bash dev/tools/build.sh`, or replace `dartclaw` with `dart run dartclaw_cli:dartclaw`.

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

The human table includes a `VARIABLES` column naming each workflow's required variables (name only), so you can compose a `run` command without inspecting `--json`. The `--json` output is unchanged and carries the full variable objects (required flag, description, default) under `variables`.

### `workflow show`

Print a workflow definition, either raw or fully resolved.

```bash
dartclaw workflow show <name>
dartclaw workflow show <name> --resolved            # merge stepDefaults + substitute workflow variables
dartclaw workflow show <name> --resolved --step <id>  # emit a single resolved step
dartclaw workflow show <name> --json                # {"yaml": "..."} envelope for scripting
dartclaw workflow show <name> --standalone          # load from the local registry, bypass the server
```

### `workflow run`

```bash
dartclaw workflow run spec-and-implement --var FEATURE="Add search"
dartclaw workflow run spec-and-implement --json
dartclaw workflow run spec-and-implement --standalone --force --var FEATURE="Local run"
dartclaw workflow run spec-and-implement --standalone --json --var FEATURE="CI run"
dartclaw workflow run code-review --approvals=auto-on-stall --var TARGET=HEAD
```

`--approvals` overrides `workflow.approvals` for one run. Values: `manual` (pause on `needsInput` and `approval`), `auto-on-stall` (auto-resolve `needsInput`, still pause at explicit approvals), `auto` (auto-resolve both).

### `workflow runs`

```bash
dartclaw workflow runs
dartclaw workflow runs --status running --definition code-review --json
```

### `workflow pause`

```bash
dartclaw workflow pause <run-id>
dartclaw workflow pause <run-id> --json
dartclaw workflow pause <run-id> --standalone
```

### `workflow resume`

```bash
dartclaw workflow resume <run-id>
dartclaw workflow resume <run-id> --json
dartclaw workflow resume <run-id> --standalone
```

### `workflow retry`

```bash
dartclaw workflow retry <run-id>
dartclaw workflow retry <run-id> --standalone
```

### `workflow cancel`

```bash
dartclaw workflow cancel <run-id>
dartclaw workflow cancel <run-id> --feedback "Reject current review"
dartclaw workflow cancel <run-id> --feedback "Reject current review" --json
dartclaw workflow cancel <run-id> --standalone --feedback "Reject current review"
```

`resume`, `cancel`, `pause`, and `retry` accept `--standalone` (with `--force`), driving the run's lifecycle in-process against the local task DB instead of a server – so an approval-paused `workflow run --standalone` can be taken to completion without ever starting `dartclaw serve`. The engine's state-transition guards still apply: a guard violation (e.g. resuming a `running` run, or retrying a non-`failed` one) prints a one-line reason and exits non-zero, never a stack trace. Like `workflow run --standalone`, these abort if a server is reachable on the resolved loopback port unless `--force` is added. A stale `running` run (left by an abruptly killed standalone process) is **not** auto-reconciled – the guard surfaces it cleanly and you re-run once the run is in a resumable state.

### `workflow status`

```bash
dartclaw workflow status <run-id>
dartclaw workflow status <run-id> --json
dartclaw workflow status <run-id> --standalone
```

### `workflow validate`

```bash
dartclaw workflow validate path/to/workflow.yaml
dartclaw workflow validate path/to/workflow.yaml --skills   # also probe each step's provider for its skill ref
```

`--skills` is opt-in and additive: after the structural validation it probes each agent step's referenced skill against that step's resolved provider and emits a **warning** (naming the step id, skill ref, and provider) for any ref the provider cannot resolve — catching a whole class of green-but-broken YAMLs before any tokens are spent. It never changes exit codes: unresolvable refs stay warnings, and if the provider CLI is missing or the probe otherwise fails the command still returns the structural verdict plus a note that skill resolution could not be checked. Default `validate` (without `--skills`) is unchanged and runs no probe.

### `workflow cleanup-skills`

Remove DartClaw-managed workflow skill links from project workspaces.

```bash
dartclaw workflow cleanup-skills
dartclaw workflow cleanup-skills --include-cwd      # also clean the current working directory
```

## Deployment and Services

### `deploy setup` (removed)

The `deploy setup` prerequisite check has been **removed**. Its preflight checks are now part of `dartclaw init` – run [`dartclaw init`](#init) instead.

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
dartclaw init                  # interactive setup wizard
dartclaw init --non-interactive
dartclaw init --workflow       # minimal standalone config for running workflows
dartclaw init --personalize    # re-seed conversational onboarding (existing installs)
dartclaw init --apply-drafts   # apply USER.md.draft / SOUL.md.draft from onboarding
dartclaw setup                 # alias for `dartclaw init`
```

Key flags:

| Flag | Effect |
|------|--------|
| `--workflow` | Write a minimal standalone workflow config under `./.dartclaw`; skips HTTP/channel/container setup. Prints the bare `workflow run --standalone` command when using the default cwd-local config. See [Workflows § Standalone CLI](workflows.md#standalone-cli-zero-server). |
| `--personalize` | Re-seed first-run personalization without rerunning full setup. Reruns write `USER.md.draft` and `SOUL.md.draft` so curated behavior files are not overwritten; review them in web chat. |
| `--apply-drafts` | Apply reviewed `USER.md.draft` / `SOUL.md.draft` from onboarding. Prompts before replacing `SOUL.md` in an interactive terminal. |
| `--non-interactive` (`-n`) | Run without prompts; required inputs must come from flags or existing config. |

The personalization flow is described in [Getting Started](getting-started.md) and [Customization](customization.md); the workspace files it scaffolds are documented in [Workspace](workspace.md).

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
