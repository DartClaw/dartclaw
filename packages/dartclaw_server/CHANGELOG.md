All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_server`.

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- Shelf server, HTMX web UI, MCP endpoints, and runtime composition for DartClaw
- Task execution, agent observability, scheduling, audit, and dashboard surfaces moved into the server package
- Web and API support for Google Chat, Signal pairing, sessions, memory, and task workflows
- `SlashCommandHandler` — server-side dispatcher for Google Chat slash commands, wired into `GoogleChatWebhookHandler`
- `TaskNotificationSubscriber` upgraded to deliver Cards v2 notifications for Google Chat channels
