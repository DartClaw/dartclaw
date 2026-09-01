# multi_turn_cli

Small DartClaw SDK example that keeps multi-turn conversation history in a local `SessionService` and `MessageService` store.

This is a **fork-the-runtime** example: it depends on `dartclaw_core` directly through `dependency_overrides` pointing at this checkout. The runtime packages are not published and carry no compatibility promise — see [ADR-008](../../../dev/adrs/008-sdk-publishing-strategy.md). If you only need to drive a running `dartclaw serve`, use the client tier instead: [SDK Quick Start](../../../docs/sdk/quick-start.md).

Prerequisites:

- Dart SDK 3.13+
- For live agent mode: `claude` in `PATH` and either `ANTHROPIC_API_KEY` or an existing Claude CLI login
- For deterministic local verification without Claude auth: use `--demo`

```bash
cd examples/sdk/multi_turn_cli
dart pub get
dart run multi_turn_cli --demo
```

Live one-shot mode:

```bash
dart run multi_turn_cli --once "Remember that my project codename is Tamarind."
dart run multi_turn_cli --once "What codename did I mention?"
```

Interactive live mode:

```bash
dart run
```

Type `exit` or press Ctrl-D to stop. The example stores session files under `.dartclaw-sdk-example/`.
