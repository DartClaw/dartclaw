# dartclaw_models

Core data types for the DartClaw agent runtime - sessions, messages, memory chunks.

`dartclaw_models` is the smallest package in the workspace: pure Dart value
types with zero runtime dependencies. Use it when you only need shared session,
message, memory, or session-key types without pulling in the runtime itself.

> **Status: Pre-1.0**. The data model is settling, but fields may still evolve
> before 1.0.

## Installation

```sh
dart pub add dartclaw_models
```

## Quick Start

```dart
import 'package:dartclaw_models/dartclaw_models.dart';

void main() {
  final now = DateTime.now();
  final sessionKey = SessionKey.dmPerContact(
    agentId: 'support',
    peerId: '+46701234567',
  );

  final session = Session(
    id: sessionKey,
    title: 'Customer support',
    type: SessionType.channel,
    createdAt: now,
    updatedAt: now,
  );

  final message = Message(
    cursor: 1,
    id: 'msg-1',
    sessionId: session.id,
    role: 'user',
    content: 'Hello from WhatsApp',
    createdAt: now,
  );

  print(session.toJson());
  print(message.content);
}
```

## Key Types

- `Session` and `SessionType`: top-level conversation metadata.
- `Message`: persisted message content with role, cursor, and timestamp.
- `SessionKey`: deterministic session identifiers for web, DM, group, cron, and task scopes.
- `MemoryChunk` and `MemorySearchResult`: common types used by memory search services.

## When to Use This Package

Use `dartclaw_models` when you only need the shared data contracts in another
package, service, or client application. Most applications should consume these
types transitively through [`dartclaw_core`](https://pub.dev/packages/dartclaw_core)
or [`dartclaw`](https://pub.dev/packages/dartclaw).

## Related Packages

- [`dartclaw_core`](https://pub.dev/packages/dartclaw_core) for the runtime and service layer.
- [`dartclaw`](https://pub.dev/packages/dartclaw) for the umbrella SDK.

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_models/latest/)
- [Repository](https://github.com/tolo/dartclaw/tree/main/packages/dartclaw_models)

## License

MIT - see [LICENSE](LICENSE).
