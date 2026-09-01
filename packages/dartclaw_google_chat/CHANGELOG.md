All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_google_chat`.

## Unreleased

### Added
- Package-owned Space Events dispatch, subscription routes, startup user-OAuth resolution, and OAuth setup mechanics
- `lib/testing.dart` — an opt-in test-double entry point serving `FakeGoogleChatRestClient`. Deliberately not re-exported by the package barrel, which stays free of test-only symbols
- Package-owned synchronous webhook ingress, JWT verification, and the `SlashCommandExecutor` runtime seam

### Changed
- Tests use the core-owned `FakeGoogleJwtVerifier` from the dev-only `dartclaw_testing` dependency

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
