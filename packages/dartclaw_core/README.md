# dartclaw_core

Shared library for DartClaw – bridge protocol, runtime models, config, channels, and persistence services.

`dartclaw_core` provides provider harnesses, channel interfaces, config loading,
events, session services, task lifecycle models, SQLite-backed repositories, and search.

> **Status: Pre-1.0**. Runtime and persistence APIs may change before 1.0.

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
- `Channel`, `ChannelManager`, `ChannelConfig`: channel integration and configuration plumbing.
- `Guard`, `GuardChain`, `CommandGuard`, `FileGuard`: security APIs imported directly from `dartclaw_kernel`.
- `SessionService`, `MessageService`, `KvService`, `MemoryFileService`: file-backed persistence.
- `MemoryService`, `Fts5SearchBackend`, `QmdSearchBackend`: SQLite and hybrid search services.
- `SqliteTaskRepository`, `SqliteGoalRepository`, `SqliteAgentExecutionRepository`: durable execution persistence.
- `DartclawConfig`, `AgentDefinition`, `ScheduledTaskDefinition`: runtime and agent configuration.
- `Task`, `Goal`, `TaskOrigin`: task and goal models plus channel-origin metadata.
- `BridgeEvent`, `EventBus`, `DartclawEvent`: protocol and application event streams.

## API Surface

- `package:dartclaw_core/dartclaw_core.dart`: the SDK-facing barrel. Prefer this for normal use.
- The public barrel now includes the operational types that still appear in exported APIs, including task-trigger parsing, worker state, harness process hooks, and harness/container wiring.
- `package:dartclaw_core/src/...`: deeper internals such as docker validation, credential-proxy plumbing, security-profile resolution, and lifecycle subscribers. These imports are supported for power users and first-party packages, but they are not the stable barrel surface.
- Task service implementations now live in `package:dartclaw_runtime`, not `dartclaw_core`.

## When to Use This Package

Use `dartclaw_core` directly when you need to embed or extend the agent runtime,
including its default SQLite persistence and search implementation.

This is the **fork-the-runtime** tier: it is not published to pub.dev and carries
no compatibility promise. Depend on it from a checkout and own the fork — see
[ADR-008](https://github.com/DartClaw/dartclaw/blob/main/dev/adrs/008-sdk-publishing-strategy.md).
If you only need to drive a running `dartclaw serve`, use the client tier
(`dartclaw` / `dartclaw_client`) instead.

## Related Packages

- [`dartclaw`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw) — the client tier umbrella, for talking to a running server.
- [`dartclaw_kernel`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_kernel) for shared data, configuration, and guard contracts.

## Documentation

- [SDK Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/sdk)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_core)

## License

MIT - see [LICENSE](LICENSE).
