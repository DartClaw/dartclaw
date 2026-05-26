# Quick Start

**SDK Guide** | [User Guide](../guide/getting-started.md) | [API Reference](https://pub.dev/documentation/dartclaw/latest/) | [Examples](../../examples/sdk/)

> **Status**: DartClaw is name-squatted on pub.dev as `0.0.1-dev.1`; the real publish is deferred until the public repo opens. Until then, use a git-pinned dependency or `dependency_overrides` against a local checkout. See ADR-008 (private repo: `docs/adrs/008-sdk-publishing-strategy.md`).

DartClaw is a Dart SDK for building agent runtimes around the native `claude` CLI. The reference server in this repo is one consumer of that SDK, but the same packages also let you build a one-file CLI, embed an agent in an existing Dart service, or compose your own storage, guards, and channels.

## Prerequisites

- Dart SDK `>=3.12.0`
- `claude` binary in your `PATH`
- Either `ANTHROPIC_API_KEY` in your environment or an existing Claude CLI login

## Install

Once the SDK packages are actually published to pub.dev (see ADR-008 for the milestone), the workspace overrides become unnecessary and you can install directly:

```bash
dart pub add dartclaw
```

## Variant 1: Single-Turn CLI

This is the smallest useful DartClaw program. It starts the harness, streams `DeltaEvent` text to stdout, runs one turn, then shuts down cleanly.

```dart
import 'dart:io';

import 'package:dartclaw/dartclaw.dart';

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
    stdout.writeln('\n\nstop_reason=${result['stop_reason']}');
  } finally {
    await sub.cancel();
    await harness.dispose();
  }
}
```

The assistant text arrives through `harness.events`. The `turn()` result is metadata such as `stop_reason`, token counts, cost, and duration.

The [runnable example project](../../examples/sdk/single_turn_cli/) extends this with command-line argument support and a configurable session ID.

## Variant 2: Minimal Shelf Endpoint

Add Shelf for this variant:

```bash
dart pub add shelf
```

This keeps the same harness behind a `POST /turn` endpoint with an SSE response stream, but it intentionally sends a hardcoded prompt instead of parsing the request body. The full reference implementation in `dartclaw_server` adds routing, auth, persistence, and multi-session orchestration on top of the same primitives.

```dart
import 'dart:async';
import 'dart:convert';
import 'package:dartclaw/dartclaw.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main() async {
  await shelf_io.serve((request) async {
    if (request.method != 'POST' || request.url.path != 'turn') return Response.notFound('POST /turn');
    final harness = ClaudeCodeHarness(cwd: '.');
    final stream = StreamController<List<int>>();
    await harness.start();
    final sub = harness.events.listen((event) {
      if (event case DeltaEvent(:final text)) stream.add(utf8.encode('data: ${jsonEncode(text)}\n\n'));
    });
    unawaited(harness.turn(
      sessionId: 'http-demo',
      messages: [{'role': 'user', 'content': 'Explain DartClaw in one sentence.'}],
      systemPrompt: 'You are a concise assistant.',
    ).whenComplete(() async {
      await sub.cancel();
      await harness.dispose();
      await stream.close();
    }));
    return Response.ok(stream.stream, headers: {'content-type': 'text/event-stream; charset=utf-8'});
  }, '127.0.0.1', 8080);
}
```

## What's Happening

`ClaudeCodeHarness` is the Dart-side host. It starts the native `claude` process, sends turns over the JSONL control protocol, and exposes streamed events such as `DeltaEvent`, `ToolUseEvent`, and `SystemInitEvent`. That split is the core DartClaw model: Dart owns lifecycle, policy, storage, and integration points; the agent process owns reasoning and tool execution.

## Next Steps

- Need help choosing packages: [Package Guide](packages.md)
- Want a runnable project instead of an inline snippet: [single_turn_cli](../../examples/sdk/single_turn_cli/README.md)
- Want the deployable reference app: [User Guide](../guide/getting-started.md)
- Want a deeper mental model: Core Concepts is planned for 0.10

> `dartclaw_server` and `dartclaw_cli` in this repo are full working examples built on these same SDK packages. Study them when you need a production-sized reference implementation.
