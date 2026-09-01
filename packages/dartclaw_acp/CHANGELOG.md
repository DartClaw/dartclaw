All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_acp`.

## Unreleased

### Added
- Package created by relocating the ACP harness, client, protocol adapter, reverse-call handlers, target validation, NDJSON channel, config DTOs and section parser out of `dartclaw_core` and `dartclaw_config`. Behaviour is unchanged; `json_rpc_2` and `stream_channel` are now this package's dependencies alone
