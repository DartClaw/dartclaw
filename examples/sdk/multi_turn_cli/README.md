# multi_turn_cli

Small DartClaw SDK example that keeps multi-turn conversation history in a local `SessionService` and `MessageService` store.

This example uses `dependency_overrides` that point at local workspace packages because the SDK is still pre-publication. Once the SDK packages are published, replace the overrides with normal package dependencies.

Prerequisites:

- Dart SDK 3.12+
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
