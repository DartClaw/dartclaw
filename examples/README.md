# Example Configs

Quick start: `bash examples/run.sh` (uses `dev.yaml` by default, stores data in `.dartclaw-example/`).

**Prerequisite:** every config reads its database from `${DARTCLAW_DATABASE_URL}`, so a PostgreSQL 14+ database must
exist first ([PostgreSQL guide](../docs/guide/postgresql.md)). Export the URL, then bootstrap the empty schema once with
the config you will run:

```bash
export DARTCLAW_DATABASE_URL='postgresql://dartclaw:<password>@127.0.0.1:5432/dartclaw?sslmode=disable'
dart run dartclaw_cli:dartclaw --config examples/dev.yaml doctor --fix
bash examples/run.sh
```

`doctor` may also report a `secrets.permissions` failure when the example file is readable beyond its owner; that does
not stop it bootstrapping the schema. Git checks the files out readable by everyone, so before putting a literal secret
in a config, copy it outside the checkout and `chmod 600` the copy.

Specify a config: `bash examples/run.sh production --port 8080`

| File | Purpose |
|------|---------|
| `dev.yaml` | Local development — no auth, guards off, verbose logging |
| `production.yaml` | Production-hardened — token auth, guards, container isolation, JSON logging |
| `personal-assistant.yaml` | Long-running knowledge companion — journaling, research, git sync ([full guide](../docs/guide/recipes/00-personal-assistant.md)) |
| `slack/manifest-socket.yaml`, `slack/manifest-events.yaml` | Slack app manifests for Socket Mode and the Events API – not DartClaw configs ([Slack guide](../docs/guide/slack.md)) |
| `run.sh` | Launcher — `run.sh [config] [args...]`, defaults to `dev` |

**Note:** Change `data_dir` to match your environment. Paths starting with `~` expand to `$HOME`.

**Tip:** Set `name` to give your instance a custom identity (e.g. `name: Jarvis`). It appears in the startup banner, browser tab, sidebar logo, and login page. Defaults to `DartClaw`.
