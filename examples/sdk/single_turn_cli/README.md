# single_turn_cli

Minimal DartClaw SDK example that asks one question, streams the answer, and exits.

This example currently uses `dependency_overrides` that point at local workspace packages. Once DartClaw 0.9.0 is published to pub.dev, replace those local overrides with normal package dependencies.

Prerequisites: Dart SDK 3.11+, `claude` in `PATH`, and either `ANTHROPIC_API_KEY` or an existing Claude CLI login.

```bash
cd examples/sdk/single_turn_cli
dart pub get
dart run -- "Explain what DartClaw is."
```
