All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_cli`.

## Unreleased

### Fixed
- macOS LaunchAgents preserve the installer shell's absolute PATH entries and refresh loaded definitions on reinstall
- Init protects pre-existing behavior files with draft onboarding and upgrades exact legacy generated instructions

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- CLI entry points for `serve`, `status`, `sessions`, `deploy`, `rebuild-index`, and `token`
- Config loader with channel parser registration for all channel packages
- `ServiceWiring` class for server construction and channel registration
