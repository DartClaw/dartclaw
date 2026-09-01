# DartClaw

The client tier for DartClaw, an experimental, security-conscious AI agent
runtime built with Dart.

Depend on this package to drive a DartClaw server you already run: its HTTP API,
its SSE event streams, and the DTO types those endpoints carry. Nothing here
starts an agent, spawns a harness, or opens a DartClaw data directory — it is a
transport plus data types, with no runtime dependencies.

> **Status: Pre-1.0**. The package structure is stabilizing, but APIs may
> still change before a 1.0 release.

## Architecture

```text
┌──────────────────────────────┐
│ Your application             │
│   package:dartclaw           │
│   DartclawApiClient          │
└──────────────┬───────────────┘
               │ HTTP + SSE (bearer token)
┌──────────────▼───────────────┐
│ dartclaw serve               │
│   harness • guards • storage │
└──────────────────────────────┘
```

## Quick Start

Start a server (`dartclaw serve`) and get a token (`dartclaw token show`), then:

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

    await for (final event in client.streamEvents('/api/events').take(1)) {
      print('event: ${event['type']}');
    }
  } on DartclawApiException catch (error) {
    print('Request failed (${error.statusCode}): ${error.message}');
  }
}
```

## Packages

| Package | Description | Use when |
| --- | --- | --- |
| `dartclaw` | Umbrella for the client tier: re-exports `dartclaw_client` and `dartclaw_kernel`. | You want one dependency to talk to a running server. |
| `dartclaw_client` | HTTP API and SSE client, its error envelope, and the transport seam. No dependencies. | You want the client without the DTO types. |
| `dartclaw_kernel` | Shared data, typed configuration, guards, and deterministic utilities; the umbrella re-exports only its DTO subset. | You need bottom-tier contracts without runtime or storage. |

None of these are on pub.dev yet — see
[ADR-008](https://github.com/DartClaw/dartclaw/blob/main/dev/adrs/008-sdk-publishing-strategy.md)
for the publication plan. Depend on them by git or path until then.

To embed the runtime itself rather than talk to one, fork the repository and
depend on `dartclaw_core` and `dartclaw_kernel` directly.
That tier is not published and has no compatibility promise — see
[SDK Packages](https://github.com/DartClaw/dartclaw/tree/main/docs/sdk/packages.md).

## Client-Tier Abstractions

- `DartclawApiClient` issues JSON requests (`get`/`post`/`patch`/`delete`, plus
  the `*Object`/`getList` shapes) and follows SSE endpoints via `streamEvents`.
- `DartclawApiException` carries the server's `code`, `statusCode`, and
  `details` envelope. Its `message` never contains the token, but it can contain
  the base URI — keep credentials out of `baseUri` before printing it.
- `ApiTransport`, `ApiRequest`, and `ApiResponse` are the wire seam: implement
  `ApiTransport` to drive the client from a fake in your own tests.
- `Session`, `Message`, `SessionKey`, and the channel value types are the shared
  DTOs the endpoints carry.

## Reference Implementations

The repository includes two complete implementations of the *server* side:

- [`dartclaw_runtime`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_runtime) is a shelf-based HTTP API plus HTMX web UI.
- [`dartclaw_cli`](https://github.com/DartClaw/dartclaw/tree/main/apps/dartclaw_cli) is a CLI with `serve`, `status`, `service`, `sessions`, `token`, and maintenance commands — and the largest consumer of this client package.

## Documentation

- [User Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/guide)
- [SDK Quick Start](https://github.com/DartClaw/dartclaw/tree/main/docs/sdk/quick-start.md)
- [SDK Concepts](https://github.com/DartClaw/dartclaw/tree/main/docs/sdk/concepts.md)
- [SDK Architecture](https://github.com/DartClaw/dartclaw/tree/main/docs/sdk/architecture.md)
- [SDK Security](https://github.com/DartClaw/dartclaw/tree/main/docs/sdk/security.md)
- [SDK Package Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/sdk/packages.md)
- [Examples](https://github.com/DartClaw/dartclaw/tree/main/examples/sdk)
- [Repository](https://github.com/DartClaw/dartclaw)

## License

MIT - see [LICENSE](LICENSE).
