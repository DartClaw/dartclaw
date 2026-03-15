All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_core`.

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- `ChannelConfigProvider` and shared channel primitives for the decomposed workspace
- Sqlite-free harness, bridge, configuration, task, and event abstractions

### Changed
- Extracted the security framework to `dartclaw_security`
- Extracted WhatsApp, Signal, and Google Chat integrations to dedicated channel packages
- Kept the core package focused on reusable SDK surfaces and file-based services
