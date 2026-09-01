All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_kernel`.

## Unreleased

### Changed

- Formed `dartclaw_kernel` from the models, configuration, and security packages without changing their behaviour.
- Removed the unused security-to-models dependency and the cross-package re-export chain.

## 0.9.0

### Added
- Extracted `ConfigMeta`, `ConfigValidator`, `ConfigWriter`, and `ScopeReconciler`
  from `dartclaw_server`
- Added the public `dartclaw_config` library entrypoint and package test suite
