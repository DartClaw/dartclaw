All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_whatsapp`.

## Unreleased

### Added
- Native typing indication for direct and group turns through GOWA chat presence

### Changed
- **Breaking:** removed `MediaExtraction`, `extractMediaDirectives`, `TaskTriggerConfig`, the `workspaceDir` argument from `formatResponse`, and the `workspaceDir` constructor argument from `WhatsAppChannel`. See the root 0.25 changelog for migration paths.

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- Standalone WhatsApp channel package with `WhatsAppChannel`, `WhatsAppConfig`, and `GowaManager`
- Response formatting and media extraction helpers for channel delivery
