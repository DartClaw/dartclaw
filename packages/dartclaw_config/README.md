# dartclaw_config

Shared configuration metadata, validation, YAML writing, and scope reconciliation
utilities for the DartClaw runtime.

`dartclaw_config` owns the full config lifecycle for DartClaw: typed section classes
composed into `DartclawConfig`, YAML parsing, atomic `ConfigWriter`, `ConfigNotifier`
hot-reload, `ConfigMeta`/`FieldMeta` field registry, `CredentialRegistry`, and the
extension parser registration system.

## Installation

```sh
dart pub add dartclaw_config
```

## Quick Start

```dart
import 'package:dartclaw_config/dartclaw_config.dart';

// Load config from a YAML file
final config = DartclawConfig.load(configPath: 'dartclaw.yaml');
print(config.memory.maxBytes);   // e.g. 65536

// Validate an API update request
final validator = ConfigValidator();
final errors = validator.validate({'memory.max_bytes': '131072'});
if (errors.isEmpty) {
  // Apply the update via ConfigWriter
}
```

## Key Types

- `DartclawConfig` — composed root config object loaded from `dartclaw.yaml`.
- `ConfigMeta` / `FieldMeta` — field registry mapping YAML paths to JSON keys, mutability tiers, and metadata.
- `ConfigMutability` — tier enum: `live`, `reloadable`, `restart`, `readonly`.
- `ConfigValidator` — validates API and CLI update requests against `ConfigMeta` field rules.
- `ConfigWriter` — non-destructive atomic YAML writes with `.bak` backup and temp+rename.
- `ConfigNotifier` / `ConfigDelta` / `Reconfigurable` — hot-reload pipeline: delta detection and change dispatch.
- `CredentialRegistry` — resolves named credential entries (env-var refs) at runtime.
- `ProviderValidator` — startup probes for configured AI providers.

## When to Use This Package

- Hosts and tools that need to load, inspect, validate, or rewrite DartClaw config.
- Tooling that extends config parsing with channel-specific sections via `DartclawConfig.registerChannelConfigParser`.

## Related Packages

- [`dartclaw_models`](https://pub.dev/packages/dartclaw_models) — re-exported from this barrel.
- [`dartclaw_core`](https://pub.dev/packages/dartclaw_core) — runtime that consumes `DartclawConfig`.

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_config/latest/)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_config)

## License

MIT - see [LICENSE](LICENSE).
