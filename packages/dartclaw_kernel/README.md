# dartclaw_kernel

Shared data, configuration, guard, and utility contracts for the DartClaw runtime.

`dartclaw_kernel` is the bottom of the workspace dependency graph. It owns the value types used across packages, the
full `DartclawConfig` lifecycle, guard evaluation and audit primitives, safe process helpers, and small shared
utilities. It depends on no other DartClaw package.

## Installation

```sh
dart pub add dartclaw_kernel
```

## Quick Start

```dart
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

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

- `Session`, `Message`, `SessionKey`, and `MemorySearchOutcome` – shared data contracts.
- `DartclawConfig` — composed root config object loaded from `dartclaw.yaml`.
- `ConfigMeta` / `FieldMeta` — field registry mapping YAML paths to JSON keys, mutability tiers, and metadata.
- `ConfigMutability` — tier enum: `live`, `reloadable`, `restart`, `readonly`.
- `ConfigValidator` — validates API and CLI update requests against `ConfigMeta` field rules.
- `ConfigWriter` — non-destructive atomic YAML writes with `.bak` backup and temp+rename.
- `ConfigNotifier` / `ConfigDelta` / `Reconfigurable` — hot-reload pipeline: delta detection and change dispatch.
- `CredentialRegistry` — resolves named credential entries (env-var refs) at runtime.
- `ProviderValidator` — startup probes for configured AI providers.
- `Guard`, `GuardChain`, and `GuardVerdict` – composable security evaluation.
- `SafeProcess` and `EnvPolicy` – sanitized subprocess execution.

## When to Use This Package

- Packages that need shared data, configuration, guard, or utility contracts without depending on the runtime.
- Tooling that parses its own config sections and needs their warnings on the config's load-warning sink, via `DartclawConfig.parseWithLoadWarnings`. A plain string is blocking; `addConfigAdvisory` marks one advisory, the same classification a built-in section gets.

## Related Packages

- [`dartclaw_core`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_core) – runtime primitives built on
  the kernel.

## Documentation

- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_kernel)

## License

MIT - see [LICENSE](LICENSE).
