# Example Configs

Quick start: `bash examples/run.sh` (uses `dev.yaml` by default, stores data in `.dartclaw-dev/`).

Specify a config: `bash examples/run.sh production --port 8080`

| File | Purpose |
|------|---------|
| `dev.yaml` | Local development — no auth, guards off, verbose logging |
| `production.yaml` | Production-hardened — token auth, guards, container isolation, JSON logging |
| `personal-assistant.yaml` | Long-running knowledge companion — scheduled journaling, git sync, relaxed guards |
| `run.sh` | Launcher — `run.sh [config] [args...]`, defaults to `dev` |

**Note:** Change `data_dir` to match your environment. Paths starting with `~` expand to `$HOME`.

**Tip:** Set `name` to give your instance a custom identity (e.g. `name: Jarvis`). It appears in the startup banner, browser tab, sidebar logo, and login page. Defaults to `DartClaw`.
