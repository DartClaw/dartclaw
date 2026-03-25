# DartClaw

An experimental, security-conscious AI agent runtime built with Dart.

DartClaw wraps the native `claude` CLI binary behind a Dart host that owns
security policy, subprocess orchestration, session state, storage, and
multi-channel messaging. The result is an AOT-friendly SDK with zero npm at
runtime.

> **Status: Pre-1.0**. The package structure is stabilizing, but APIs may
> still change before a 1.0 release.

## Architecture

```text
┌────────────────────────────────────────────────────────────┐
│ Dart Host                                                  │
│                                                            │
│  AgentHarness • GuardChain • EventBus • Sessions • Channels│
│                                                            │
└───────────────────────┬────────────────────────────────────┘
                        │ JSONL over stdin/stdout
┌───────────────────────▼────────────────────────────────────┐
│ Native `claude` CLI binary                                 │
│                                                            │
│  model execution • tool protocol • streaming deltas        │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

Most applications start with this umbrella package. It re-exports
`dartclaw_core`, `dartclaw_storage`, and the channel packages; `dartclaw_models`
and `dartclaw_security` are available transitively through `dartclaw_core`.

Operational internals in `dartclaw_core` are intentionally narrower now, but
the public barrel still re-exports the types that appear in exported APIs.
Use the umbrella or `dartclaw_core` barrel for normal SDK work; reach into
`package:dartclaw_core/src/...` only for deeper internals such as docker
validation, credential-proxy plumbing, or security-profile resolution.

## Quick Start

Prerequisites: install the `claude` binary and set `ANTHROPIC_API_KEY`.

```dart
import 'package:dartclaw/dartclaw.dart';

Future<void> main() async {
  final harness = ClaudeCodeHarness(cwd: '.');

  try {
    await harness.start();

    harness.events.listen((event) {
      switch (event) {
        case DeltaEvent(:final text):
          print(text);
        case ToolUseEvent(:final toolName):
          print('[tool] $toolName');
        case _:
          break;
      }
    });

    final result = await harness.turn(
      sessionId: 'readme-example',
      messages: [
        {'role': 'user', 'content': 'Summarize what DartClaw gives me.'},
      ],
      systemPrompt: 'You are a concise assistant.',
    );

    print(result);
  } finally {
    await harness.dispose();
  }
}
```

## Packages

| Package | Description | Use when |
| --- | --- | --- |
| [`dartclaw`](https://pub.dev/packages/dartclaw) | Umbrella package for the full SDK surface most users need. | You want one dependency and a working starting point. |
| [`dartclaw_core`](https://pub.dev/packages/dartclaw_core) | Harness, channels, config, events, file-based services, no SQLite dependency. | You need the runtime in Flutter or want custom persistence. |
| [`dartclaw_models`](https://pub.dev/packages/dartclaw_models) | Zero-dependency data types for sessions, messages, tasks, and memory. | You only need shared models or serialization types. |
| [`dartclaw_security`](https://pub.dev/packages/dartclaw_security) | Guard framework for command, file, network, and content policy checks. | You want custom guard chains or to reuse the security layer directly. |
| [`dartclaw_storage`](https://pub.dev/packages/dartclaw_storage) | SQLite-backed memory search, pruning, and task persistence. | You want the default persistence and FTS5 search stack. |
| [`dartclaw_whatsapp`](https://pub.dev/packages/dartclaw_whatsapp) | WhatsApp channel integration via a GOWA sidecar. | You are wiring an agent into WhatsApp. |
| [`dartclaw_signal`](https://pub.dev/packages/dartclaw_signal) | Signal channel integration via `signal-cli`. | You are wiring an agent into Signal. |
| [`dartclaw_google_chat`](https://pub.dev/packages/dartclaw_google_chat) | Google Chat channel integration for Workspace deployments. | You are wiring an agent into Google Chat. |

## Core Abstractions

- `AgentHarness` and `ClaudeCodeHarness` manage the Claude subprocess lifecycle and turn execution.
- `Guard` and `GuardChain` enforce application-level security before tool calls or inbound messages reach the model.
- `Channel` and `ChannelManager` provide a common interface for messaging transports.
- `BridgeEvent` and `EventBus` expose typed streaming events from the JSONL control protocol and the wider runtime.
- `Session`, `Message`, `Task`, and `Goal` capture persisted conversation and work state.

## Reference Implementations

The repository includes two complete reference implementations built on this
SDK:

- [`dartclaw_server`](https://github.com/tolo/dartclaw/tree/main/packages/dartclaw_server) is a shelf-based HTTP API plus HTMX web UI.
- [`dartclaw_cli`](https://github.com/tolo/dartclaw/tree/main/apps/dartclaw_cli) is a CLI with `serve`, `status`, `deploy`, `sessions`, `token`, and maintenance commands.

Study them, fork them, or replace them with your own composition layer.

## Custom Extensions

If you are composing with `package:dartclaw_server`, you can register custom
guards, channels, and event listeners before the first request is served.
For `onEvent<T>()`, construct the server with the shared runtime `EventBus`
you use elsewhere in your composition, for example
`DartclawServer(..., eventBus: eventBus)`:

```dart
import 'dart:async';

import 'package:dartclaw/dartclaw.dart';
import 'package:dartclaw_server/dartclaw_server.dart';

StreamSubscription<TaskStatusChangedEvent> configureServer(DartclawServer server) {
  server.registerGuard(MyGuard());
  server.registerChannel(MyChannel());

  // Assumes the server was constructed with `eventBus: eventBus`.
  return server.onEvent<TaskStatusChangedEvent>((event) {
    print('Task ${event.taskId} is now ${event.newStatus.name}');
  });
}
```

These extension points stay open until the first request is handled. After
that, later calls throw `StateError`. Keep the returned subscription and cancel
it when your process shuts down.

## Documentation

- [User Guide](https://github.com/tolo/dartclaw/tree/main/docs/guide)
- [SDK Guide](https://github.com/tolo/dartclaw/tree/main/docs/sdk)
- [API Reference](https://pub.dev/documentation/dartclaw/latest/)
- [Examples](https://github.com/tolo/dartclaw/tree/main/examples/sdk)
- [Repository](https://github.com/tolo/dartclaw)

## License

MIT - see [LICENSE](LICENSE).
