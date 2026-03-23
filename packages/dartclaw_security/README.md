# dartclaw_security

Security guard framework for the DartClaw agent runtime.

`dartclaw_security` provides the composable policy layer used throughout
DartClaw. It includes the `Guard` interface, `GuardChain` orchestration,
default guards for commands, files, networks, and input sanitization, plus
audit hooks you can wire into your own event system.

> **Status: Pre-1.0**. The guard framework is usable today, but APIs and
> built-in defaults may still be refined before 1.0.

## Installation

```sh
dart pub add dartclaw_security
```

## Quick Start

```dart
import 'package:dartclaw_security/dartclaw_security.dart';

Future<void> main() async {
  final chain = GuardChain(
    guards: [
      CommandGuard(),
      FileGuard(),
      InputSanitizer(),
    ],
    onVerdict: (guardName, category, verdict, message, context) {
      print('[$guardName][$category] $verdict ${message ?? ''}');
    },
  );

  final verdict = await chain.evaluateBeforeToolCall(
    'shell',
    {'command': 'rm -rf ~/.ssh'},
  );

  print(verdict);
}
```

## Key Types

- `Guard`, `GuardChain`, `GuardContext`: the core evaluation interfaces.
- `GuardVerdict`, `GuardPass`, `GuardWarn`, `GuardBlock`: normalized outcomes from guard evaluation.
- `CommandGuard`, `FileGuard`, `NetworkGuard`, `InputSanitizer`: built-in protection for shell, file, network, and inbound message surfaces.
- `FileGuardConfig`, `CommandGuardConfig`, `NetworkGuardConfig`, `InputSanitizerConfig`: configuration objects for custom defaults.
- `GuardAuditLogger` and `AuditEntry`: application-level audit logging hooks.
- `MessageRedactor`, `ContentGuard`, `ContentClassifier`: higher-level content controls.

## When to Use This Package

Use `dartclaw_security` directly when you want to build or compose guards
outside the full runtime, or when you want to reuse DartClaw's security layer
inside a custom harness. Most applications get the same APIs transitively from
[`dartclaw_core`](https://pub.dev/packages/dartclaw_core).

## Related Packages

- [`dartclaw_core`](https://pub.dev/packages/dartclaw_core) re-exports this package.
- [`dartclaw`](https://pub.dev/packages/dartclaw) bundles the default SDK surface.

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_security/latest/)
- [Repository](https://github.com/tolo/dartclaw/tree/main/packages/dartclaw_security)

## License

MIT - see [LICENSE](LICENSE).
