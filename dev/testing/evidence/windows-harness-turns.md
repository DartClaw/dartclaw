# Native Windows Harness-Turn Evidence

**Status**: QUALIFIED

**Run timestamps**: Claude `2026-07-11T19:02:46.7206933+02:00`; Codex `2026-07-11T19:03:19.4863254+02:00`
**Host**: Windows 11 Pro 10.0 build 26200, ARM64 (Parallels)
**Windows user**: `TOBIASLFSTR7587\tobias` (`C:\Users\tobias`)
**Dart**: 3.12.1 stable, `windows_arm64`
**DartClaw under test**: source checkout at `8bfb9ac4a328f2d9acd1e6b035febc86036ad0b0` plus uncommitted
0.21 plan changes; not a release artifact. Windows accessed the checkout through `Z:\Repos\Libs\dartclaw\dartclaw-public`,
mapped to `\\Mac\Home\Repos\Libs\dartclaw\dartclaw-public`.
**Claude**: Claude Code 2.1.207
**Codex**: codex-cli 0.139.0

Both providers used distinct data directories and fresh DartClaw server startups. Each turn ran through DartClaw's
HTTP session API and provider-scoped harness pool. Both reached terminal completion, stored assistant `pong`, and
logged no JSONL/JSON-RPC parse or stdio transport error.

## Claude Result

- Data directory: `C:\Users\tobias\AppData\Local\Temp\dartclaw-s07-claude-20260711-r3`.
- HTTP session: `66f6d727-7a9a-4da3-a68a-344834174a45`; turn:
  `9fe592e0-e931-4dc9-b10f-dfd41fb3bbaf`.
- DartClaw terminal state: `completed`; `TurnRunner` logged `text=4 chars` and stored assistant response `pong`.
- The parsed terminal provider result logged `is_error=false`; no authentication, JSONL parse, or stdio transport error
  occurred.
- Qualification: **PASS**.

## Codex Result

- Data directory: `C:\Users\tobias\AppData\Local\Temp\dartclaw-s07-codex-20260711-r2`.
- HTTP session: `d19567e3-293f-4e1f-a1b7-742e056daff4`; turn:
  `a979ceaa-2cbe-4f23-9c70-aed020c67b36`.
- DartClaw terminal state: `completed`; the harness processed the app-server completion, logged
  `Turn complete: reason=completed`, and stored assistant response `pong`.
- No JSON-RPC parse or stdio transport error was logged.
- Qualification: **PASS**.

## Non-Fatal Setup Warnings

Codex emitted the project-trust warning and continued to a passing turn:

```text
Project-local config, hooks, and exec policies are disabled in the following folders until the project is trusted,
but skills still load.
```

The `node_repl` MCP sidecar also failed its startup handshake; DartClaw surfaced the provider detail and the turn still
completed:

```text
Codex MCP server "node_repl" failed to start: MCP client for `node_repl` failed to start: MCP startup failed:
handshaking with MCP server failed: connection closed: initialize response
```

Claude warned that the mapped checkout was not trusted and ignored project-local permission allow entries. That did
not prevent the no-tool prompt from completing:

```text
Ignoring 68 permissions.allow entries from .claude/settings.local.json: this workspace has not been trusted.
```
