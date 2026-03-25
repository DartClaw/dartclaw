# dartclaw_server

HTTP API and HTMX web UI for DartClaw — a reference implementation.

`dartclaw_server` is the reference server composition layer for DartClaw. It
turns the SDK packages into a shelf-based HTTP API with session management,
task execution, SSE streams, authentication, and an HTMX web UI.

> **This is a reference implementation** built on the DartClaw SDK packages.
> Study the source, fork it, or replace it with your own server layer.

## What This Demonstrates

- Composing `dartclaw_core`, `dartclaw_security`, and `dartclaw_storage` into a complete runtime.
- Wiring channel packages into a multi-transport server.
- Exposing HTTP APIs, SSE streams, and a browser UI on top of the same runtime state.
- Running tasks, session flows, and maintenance services in one application.

## Getting Started

Start the reference server through the CLI app:

```sh
dart run dartclaw_cli:dartclaw serve --port 3333
```

Then open `http://localhost:3333`.

## Built With

- [`dartclaw_core`](https://pub.dev/packages/dartclaw_core)
- [`dartclaw_security`](https://pub.dev/packages/dartclaw_security)
- [`dartclaw_storage`](https://pub.dev/packages/dartclaw_storage)
- [`dartclaw_whatsapp`](https://pub.dev/packages/dartclaw_whatsapp)
- [`dartclaw_signal`](https://pub.dev/packages/dartclaw_signal)
- [`dartclaw_google_chat`](https://pub.dev/packages/dartclaw_google_chat)

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_server/latest/)
- [User Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_server)

## License

MIT - see [LICENSE](LICENSE).
