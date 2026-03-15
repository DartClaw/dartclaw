# dartclaw_cli

CLI application for DartClaw — a reference implementation.

`dartclaw_cli` is the reference command-line application for the DartClaw
workspace. It exposes a working entry point for the server stack and the
operational commands used to inspect, maintain, and deploy a DartClaw runtime.

> **This is a reference implementation** built on the DartClaw SDK packages.
> Study the source, fork it, or replace it with your own CLI layer.

## What This Demonstrates

- Building a complete CLI app on top of the DartClaw SDK packages.
- Starting the reference server with `serve`.
- Operational commands such as `status`, `sessions`, `token`, `deploy`, and `rebuild-index`.
- Wiring workspace configuration, storage, and channels into executable tooling.

## Getting Started

Run the reference CLI entry point:

```sh
dart run dartclaw_cli:dartclaw serve --port 3333
```

Use `dart run dartclaw_cli:dartclaw --help` to inspect the full command set.

## Built With

- [`dartclaw_core`](https://pub.dev/packages/dartclaw_core)
- [`dartclaw_storage`](https://pub.dev/packages/dartclaw_storage)
- [`dartclaw_server`](https://pub.dev/packages/dartclaw_server)
- [`dartclaw_whatsapp`](https://pub.dev/packages/dartclaw_whatsapp)
- [`dartclaw_signal`](https://pub.dev/packages/dartclaw_signal)
- [`dartclaw_google_chat`](https://pub.dev/packages/dartclaw_google_chat)

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_cli/latest/)
- [User Guide](https://github.com/tolo/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/tolo/dartclaw/tree/main/apps/dartclaw_cli)

## License

MIT - see [LICENSE](LICENSE).
