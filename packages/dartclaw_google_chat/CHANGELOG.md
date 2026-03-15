All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_google_chat`.

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- Standalone Google Chat channel package with `GoogleChatChannel` and `GoogleChatConfig`
- Google Chat REST client support plus GCP authentication helpers
- `ChatCardBuilder` — Cards v2 JSON builder for task status notifications, error reports, and confirmations
- `structuredPayload` on `ChannelResponse` enables Cards v2 delivery through the channel abstraction
- `CARD_CLICKED` webhook event handling — Accept/Reject button clicks routed through shared `TaskReviewService`
- `SlashCommandParser` — dual-shape compatibility parser for `MESSAGE+slashCommand` and `APP_COMMAND` events
- Slash commands: `/new` (create task), `/reset` (archive session), `/status` (active task/session summary)
