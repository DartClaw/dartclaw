# shelf_server

Minimal DartClaw SDK example that hosts an agent behind a Shelf endpoint. It is intentionally small and does not reproduce the full `dartclaw_server` reference implementation.

This example uses `dependency_overrides` that point at local workspace packages because the SDK is still pre-publication. Once the SDK packages are published, replace the overrides with normal package dependencies.

Prerequisites:

- Dart SDK 3.12+
- For live agent mode: `claude` in `PATH` and either `ANTHROPIC_API_KEY` or an existing Claude CLI login
- For deterministic local verification without Claude auth: use `--demo`

```bash
cd examples/sdk/shelf_server
dart pub get
dart run shelf_server --demo --port 8095
```

In another terminal:

```bash
curl -s -X POST http://127.0.0.1:8095/turn -d 'Explain DartClaw in one sentence.'
```

Live mode uses the same endpoint and streams Server-Sent Events:

```bash
dart run shelf_server --port 8095
curl -N -X POST http://127.0.0.1:8095/turn -d 'Explain DartClaw in one sentence.'
```

`dartclaw_server` is the full reference implementation with auth, persistence, channels, HTMX pages, and operational APIs. This example only shows the SDK hosting seam.
