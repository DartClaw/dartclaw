# dartclaw_client

HTTP and SSE client for a running DartClaw server.

`dartclaw_client` declares no dependencies — not on any DartClaw package, not on
anything from pub. Hold a base URI and a bearer token and you can drive a
server's API without the DartClaw runtime, a config file, or a DartClaw data
directory. That is the whole point of the package: consumers that talk to a
server should not have to carry the harness, the guard chain, or SQLite storage
to do it.

> **Status: Pre-1.0**. The wire contract is stable; the Dart surface may still
> change before 1.0.

## Installation

Not on pub.dev yet — see
[ADR-008](https://github.com/DartClaw/dartclaw/blob/main/dev/adrs/008-sdk-publishing-strategy.md).
Depend on it by git or path:

```yaml
dependencies:
  dartclaw_client:
    git:
      url: https://github.com/DartClaw/dartclaw.git
      path: packages/dartclaw_client
```

## Quick Start

Start a server (`dartclaw serve`) and get a token (`dartclaw token show`):

```dart
import 'package:dartclaw_client/dartclaw_client.dart';

Future<void> main() async {
  final client = DartclawApiClient(
    baseUri: Uri.parse('http://localhost:3333'),
    token: 'your-gateway-token',
  );

  final tasks = await client.getList('/api/tasks');
  print('${tasks.length} task(s).');

  await for (final event in client.streamEvents('/api/events')) {
    print('event: ${event['type']}');
  }
}
```

## What it gives you

- **Requests** — `get`/`post`/`patch`/`delete` return decoded JSON; the
  `getObject`/`getList`/`postObject`/`patchObject`/`deleteObject` variants
  assert the shape. `getText` is for endpoints that emit non-JSON bodies.
- **SSE streams** — `streamEvents` decodes `data:` frames (multi-line frames
  included) and skips frames carrying no data rather than aborting the stream.
  Supply `onDisconnect` to decide whether a dropped stream reconnects; attempts
  are spaced by `reconnectDelays` and capped by `maxReconnects`.
- **Errors** — every non-2xx status raises `DartclawApiException` carrying the
  server's `code`/`statusCode`/`details` envelope. `message` never contains the
  bearer token, but it can contain the base URI — keep credentials out of
  `baseUri` before printing it.
- **A transport seam** — implement `ApiTransport` to run the client against a
  fake in your own tests, or over a transport other than `dart:io`.

## Authentication

The `token` is sent as `authorization: Bearer <token>` on every request. Pass
`null` when the server's gateway runs with `auth_mode: none`. Resolving a token
from a config file or a data directory is deliberately *not* this package's job
— that belongs to whatever composes it, as it does in the DartClaw CLI.

## Documentation

- [SDK Quick Start](https://github.com/DartClaw/dartclaw/tree/main/docs/sdk/quick-start.md)
- [Web UI and API](https://github.com/DartClaw/dartclaw/tree/main/docs/guide/web-ui-and-api.md) — the endpoints this client speaks
- [Repository](https://github.com/DartClaw/dartclaw)

## License

MIT - see [LICENSE](LICENSE).
