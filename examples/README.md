# Example Configs

Usage: `dartclaw --config examples/<file>.yaml serve` or set `DARTCLAW_CONFIG=examples/<file>.yaml`.

| File | Purpose |
|------|---------|
| `dev.yaml` | Local development — no auth, guards off, verbose logging |
| `production.yaml` | Production-hardened — token auth, guards, container isolation, JSON logging |
| `personal-assistant.yaml` | Long-running knowledge companion — scheduled journaling, git sync, relaxed guards |

**Note:** Change `data_dir` to match your environment. Paths starting with `~` expand to `$HOME`.
