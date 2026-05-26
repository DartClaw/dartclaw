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
- Top-level command families covered: `init`, `serve`, `service` (install/start/stop/uninstall), `status`, `agents`, `config`, `jobs`, `projects`, `sessions`, `tasks`, `traces`, `workflow` (run/runs/pause/resume/cancel/status/validate/show), `deploy`, `rebuild-index`, `token`, `google-auth`. See [`cli-reference.md`](../../docs/guide/cli-reference.md) for the full surface.
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

- [CLI Reference](../../docs/guide/cli-reference.md) — full command surface with flags and examples
- [API Reference](https://pub.dev/documentation/dartclaw_cli/latest/)
- [User Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/apps/dartclaw_cli)

## License

MIT - see [LICENSE](LICENSE).
