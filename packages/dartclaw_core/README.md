# dartclaw_core

Shared library for DartClaw - bridge protocol, runtime models, config, channels, and file-based services.

`dartclaw_core` is the SQLite-free heart of the runtime. It provides the
Claude subprocess harness, channel interfaces, config loading, events, session
services, task types, and re-exports `dartclaw_models` plus
`dartclaw_security`.

> **Status: Pre-1.0**. Depend on `dartclaw_core` when you want the runtime
> without the default SQLite-backed storage layer.

## Installation

```sh
dart pub add dartclaw_core
```

## Quick Start

Prerequisites: install the `claude` binary and set `ANTHROPIC_API_KEY`.

```dart
import 'package:dartclaw_core/dartclaw_core.dart';

Future<void> main() async {
  final harness = ClaudeCodeHarness(cwd: '.');

  try {
    await harness.start();

    final result = await harness.turn(
      sessionId: 'core-example',
      messages: [
        {'role': 'user', 'content': 'List the main runtime services.'},
      ],
      systemPrompt: 'You are a concise assistant.',
    );

    print(result);
  } finally {
    await harness.dispose();
  }
}
```

## Key Types

- `AgentHarness`, `ClaudeCodeHarness`, `HarnessConfig`: subprocess lifecycle and turn execution.
- `Channel`, `ChannelManager`, `ChannelConfig`, `ChannelConfigProvider`: channel integration and configuration plumbing.
- `Guard`, `GuardChain`, `InputSanitizer`, `FileGuard`: security APIs re-exported from `dartclaw_security`.
- `SessionService`, `MessageService`, `KvService`, `MemoryFileService`: file-based persistence with no SQLite dependency.
- `DartclawConfig`, `AgentDefinition`, `ScheduledTaskDefinition`: runtime and agent configuration.
- `Task`, `Goal`, `TaskOrigin`, `TaskCreator`, `TaskLister`: task models plus channel/task callback contracts.
- `BridgeEvent`, `EventBus`, `DartclawEvent`: protocol and application event streams.

## API Surface

- `package:dartclaw_core/dartclaw_core.dart`: the SDK-facing barrel. Prefer this for normal use.
- The public barrel now includes the operational types that still appear in exported APIs, including task-trigger parsing, review-command parsing, worker state, harness process hooks, and harness/container wiring.
- `package:dartclaw_core/src/...`: deeper internals such as docker validation, credential-proxy plumbing, security-profile resolution, and lifecycle subscribers. These imports are supported for power users and first-party packages, but they are not the stable barrel surface.
- Task service implementations now live in `package:dartclaw_server`, not `dartclaw_core`.

## When to Use This Package

Use `dartclaw_core` directly when you need the agent runtime but want to bring
your own persistence, run in an environment where SQLite is a bad fit, or keep
the dependency graph lean for Flutter or embedded integrations. If you want the
default storage and channel stack out of the box, use
[`dartclaw`](https://pub.dev/packages/dartclaw).

## Related Packages

- [`dartclaw`](https://pub.dev/packages/dartclaw) for the umbrella SDK.
- [`dartclaw_models`](https://pub.dev/packages/dartclaw_models) for zero-dependency shared data types.
- [`dartclaw_security`](https://pub.dev/packages/dartclaw_security) for the guard framework on its own.
- [`dartclaw_storage`](https://pub.dev/packages/dartclaw_storage) for SQLite-backed persistence and search.

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_core/latest/)
- [SDK Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/sdk)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_core)

## License

MIT - see [LICENSE](LICENSE).
