# single_turn_cli

Minimal DartClaw SDK example that asks one question, streams the answer, and exits.

This example uses `dependency_overrides` that point at local workspace packages because the SDK is still name-squatted on pub.dev as `0.0.1-dev.1` (see ADR-008 — private repo: `docs/adrs/008-sdk-publishing-strategy.md`). Once the SDK packages are actually published, replace the overrides with normal package dependencies.

Prerequisites: Dart SDK 3.12+, `claude` in `PATH`, and either `ANTHROPIC_API_KEY` or an existing Claude CLI login.

```bash
cd examples/sdk/single_turn_cli
dart pub get
dart run single_turn_cli "Explain what DartClaw is."
```
