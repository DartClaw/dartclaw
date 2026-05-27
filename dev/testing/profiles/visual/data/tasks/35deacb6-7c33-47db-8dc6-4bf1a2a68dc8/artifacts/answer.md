# Seeded Workspace Status — Plain Testing Profile

_Profile path: `dartclaw-private/docs/testing/plain/`_
_Date: 2026-03-11 · Port: 3338 · Auth: token (`devtoken0…`/`gateway_token` file)_

---

## Configuration

| Setting | Value |
|---------|-------|
| Port | 3338 |
| Auth mode | `token` |
| Guards | enabled |
| Scheduling heartbeat | disabled |
| Channels | none (plain profile) |
| Workspace git sync | disabled |
| Log level | `FINE` |

---

## Sessions (5 total)

| ID | Title | Type | Channel key | Created |
|----|-------|------|-------------|---------|
| `aaaaaaaa-1111-…-0001` | Project planning | `main` | `main` | 2026-03-06 |
| `aaaaaaaa-1111-…-0002` | Code review notes | `archive` | `main` | 2026-03-05 |
| `f276617f-…` | _(untitled)_ | `cron` | `agent:main:cron:daily-summary` | 2026-03-10 |
| `cfa9a4f8-…` | _(untitled)_ | `task` | `agent:main:task:157dc0bb-…` | 2026-03-11 |
| `13fbb8b0-…` | _(untitled)_ | `task` | `agent:main:task:35deacb6-…` | 2026-03-11 |

- **2 main sessions** (one active `main`, one `archive`) — no message files, metadata only.
- **1 cron session** (`daily-summary` job) — has run twice (2026-03-10 and 2026-03-11).
- **2 task sessions** — created 2026-03-11; the `cfa9a4f8` session recorded a turn failure.

---

## Scheduled Jobs

| Name | Schedule | Delivery |
|------|----------|----------|
| `daily-summary` | `0 9 * * *` (daily 09:00) | `announce` |
| `weekly-cleanup` | `0 2 * * 0` (Sunday 02:00) | `none` |

---

## Usage

| Date | Input tokens | Output tokens | Agent |
|------|-------------|---------------|-------|
| 2026-03-10 | 3 | 191 | `cron:daily-summary` |
| 2026-03-11 | 5 | 866 | `cron:daily-summary` |

**Session cost** (`f276617f`): 1,065 tokens total · ~$0.20 · 2 turns.

---

## Workspace Files

| File | Content |
|------|---------|
| `SOUL.md` | Default persona: _"helpful, capable AI assistant"_ |
| `USER.md` | Blank user context template |
| `AGENTS.md` | Safety rules (no-exfiltrate, no-prompt-injection, etc.) |
| `TOOLS.md` | Present (not read) |
| `errors.md` | 2 entries: `DateTime.parse()` null bug (2026-03-05); turn failure on `cfa9a4f8` (2026-03-11) |
| `learnings.md` | 2 entries: prefer concise responses; project uses Dart pub workspace |
| `memory/2026-03-11.md` | Cron run summary — `daily-summary` job output for 2026-03-10 commit activity |

---

## KV Store Highlights

- `prune_history` — one pruning run: 3 archived, 1 duplicate removed, 12 remaining (2026-03-06).
- `session_cost:f276617f` — cost record for the cron session.
- `usage_daily:2026-03-10` / `usage_daily:2026-03-11` — per-day usage aggregates.
- `turn:13fbb8b0` — in-flight turn record for the most recent task session.

---

## Notes

- No message files exist for the two main sessions (`0001`, `0002`) — titles and metadata only.
- The cron session (`f276617f`) is the only session with recorded turns and cost data.
- Task session `cfa9a4f8` has a `TURN_FAILURE` error logged (exit code -2, 2026-03-11T22:25).
- `tasks.db` / `tasks.db-shm` / `tasks.db-wal` are present but not inspected (binary SQLite).
- `search.db` present — FTS5 index for memory search.
