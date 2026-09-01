# single_turn_cli

Minimal DartClaw SDK example that asks one question, streams the answer, and exits.

This is a **fork-the-runtime** example: it depends on `dartclaw_core` directly through `dependency_overrides` pointing at this checkout. The runtime packages are not published and carry no compatibility promise — see [ADR-008](../../../dev/adrs/008-sdk-publishing-strategy.md). If you only need to drive a running `dartclaw serve`, use the client tier instead: [SDK Quick Start](../../../docs/sdk/quick-start.md).

Prerequisites: Dart SDK 3.13+, `claude` in `PATH`, and either `ANTHROPIC_API_KEY` or an existing Claude CLI login.

```bash
cd examples/sdk/single_turn_cli
dart pub get
dart run single_turn_cli "Explain what DartClaw is."
```
