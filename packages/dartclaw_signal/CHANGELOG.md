All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_signal`.

## Unreleased

### Fixed
- Post-start account linking now activates inbound receiving and selects the linked account for replies without restarting DartClaw, including during an active reconnect
- Channel startup distinguishes registered, unregistered, and indeterminate account state

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- Standalone Signal channel package with `SignalChannel`, `SignalConfig`, and `SignalCliManager`
- Sender mapping and Signal DM/group access helpers
