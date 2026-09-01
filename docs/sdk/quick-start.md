# Quick Start

**SDK Guide** | [Concepts](concepts.md) | [Architecture](architecture.md) | [Security](security.md) | [Package Guide](packages.md) | [User Guide](../guide/getting-started.md) | [Examples](../../examples/sdk/)

DartClaw offers two tiers, and they are not equally supported:

1. **Build on a running DartClaw server** — depend on `dartclaw_client` (or the `dartclaw` umbrella, which adds the shared DTOs) and drive the server's HTTP API and SSE streams. This is the tier the project supports for external consumers.
2. **Fork the runtime** — clone the repository and depend on `dartclaw_core` and `dartclaw_kernel` directly to embed the harness in your own process. There is no published package and no compatibility promise for this tier; you own the fork.

Start with tier 1 unless you specifically need the runtime in your own process.

> **Status**: no DartClaw package is on pub.dev yet. Depend on the client tier via a git-pinned dependency; use `dependency_overrides` against a local checkout for the runtime tier. See [ADR-008](../../dev/adrs/008-sdk-publishing-strategy.md).

## Prerequisites

- Dart SDK `>=3.13.0`
- A running DartClaw server (`dartclaw serve` — see the [User Guide](../guide/getting-started.md))
- A gateway token from `dartclaw token show`, unless the server runs with `gateway.auth_mode: none`

## Tier 1: Build On A Running Server

```yaml
# pubspec.yaml
dependencies:
  dartclaw:
    git:
      url: https://github.com/DartClaw/dartclaw.git
      path: packages/dartclaw
```

Use `packages/dartclaw_client` instead of `packages/dartclaw` if you want the client without the shared DTO types.

```dart
import 'package:dartclaw/dartclaw.dart';

Future<void> main() async {
  final client = DartclawApiClient(
    baseUri: Uri.parse('http://localhost:3333'),
    token: 'your-gateway-token',
  );

  try {
    final sessions = await client.getList('/api/sessions');
    print('${sessions.length} session(s).');

    // Follow the server's event stream; reconnect twice before giving up.
    await for (final event in client.streamEvents(
      '/api/events',
      onDisconnect: (attempt) async => attempt <= 2,
    )) {
      print('event: ${event['type']}');
    }
  } on DartclawApiException catch (error) {
    // `message` is safe to print — it never contains the bearer token.
    print('Request failed (${error.code ?? error.statusCode}): ${error.message}');
  }
}
```

### What's Happening

`DartclawApiClient` is a transport, not a runtime. It holds a base URI and a bearer token, sends `authorization: Bearer <token>` on every request, decodes JSON responses, and decodes SSE `data:` frames from streaming endpoints. Every non-2xx status raises `DartclawApiException` carrying the server's `code`/`statusCode`/`details` envelope.

Resolving the token from a config file or a data directory is deliberately not the client's job — the client never touches a DartClaw data directory. The DartClaw CLI composes that resolution itself in `apps/dartclaw_cli/lib/src/commands/connected_command_support.dart`, and is the largest working example of this tier.

The endpoints are documented in [Web UI and API](../guide/web-ui-and-api.md).

## Tier 2: Fork The Runtime

To run the harness inside your own process, clone the repository and depend on the runtime packages through path or `dependency_overrides`. The four projects under [`examples/sdk/`](../../examples/sdk/) are set up exactly that way.

```dart
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';

Future<void> main() async {
  final harness = ClaudeCodeHarness(cwd: '.');
  await harness.start();

  final sub = harness.events.listen((event) {
    if (event case DeltaEvent(:final text)) stdout.write(text);
  });

  try {
    final result = await harness.turn(
      sessionId: 'quick-start',
      messages: [
        {'role': 'user', 'content': 'Explain DartClaw in one sentence.'},
      ],
      systemPrompt: 'You are a concise assistant.',
    );
    stdout.writeln('\n\nstop_reason=${result.stopReason}');
  } finally {
    await sub.cancel();
    await harness.dispose();
  }
}
```

This needs the `claude` binary on your `PATH` plus either `ANTHROPIC_API_KEY` or an existing Claude CLI login. `ClaudeCodeHarness` starts the native process, sends turns over the JSONL control protocol, and streams `DeltaEvent`, `ToolUseEvent`, and `SystemInitEvent` back. `CodexHarness` is the equivalent for Codex.

The [runnable example project](../../examples/sdk/single_turn_cli/) extends this with command-line argument support and a configurable session ID.

## Next Steps

- Choosing between the tiers, package by package: [Package Guide](packages.md)
- The mental model behind both tiers: [Core Concepts](concepts.md)
- Tier boundaries and extension seams: [Architecture](architecture.md)
- Token handling, guard chains, and isolation: [Security](security.md)
- Runnable fork-the-runtime projects: [single_turn_cli](../../examples/sdk/single_turn_cli/README.md), [custom_guard](../../examples/sdk/custom_guard/README.md), [multi_turn_cli](../../examples/sdk/multi_turn_cli/README.md), [shelf_server](../../examples/sdk/shelf_server/README.md)
- The deployable reference app: [User Guide](../guide/getting-started.md)

> `dartclaw_runtime` and `dartclaw_cli` in this repo are full working implementations of the server side. Study them when you need production-sized composition examples; they are not something you can install.
