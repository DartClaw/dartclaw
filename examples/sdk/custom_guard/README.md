# custom_guard

Minimal DartClaw SDK example that implements a custom `Guard`, adds it to a `GuardChain`, and evaluates sample inbound messages.

This is a **fork-the-runtime** example: it depends on `dartclaw_core` directly through `dependency_overrides` pointing at this checkout. The runtime packages are not published and carry no compatibility promise — see [ADR-008](../../../dev/adrs/008-sdk-publishing-strategy.md). If you only need to drive a running `dartclaw serve`, use the client tier instead: [SDK Quick Start](../../../docs/sdk/quick-start.md).

Prerequisites: Dart SDK 3.13+. This example does not require the `claude` binary or provider auth because it exercises the guard framework directly.

```bash
cd examples/sdk/custom_guard
dart pub get
dart run
dart run custom_guard "please keep this public"
dart run custom_guard "my launch code is swordfish"
```

The first two commands should pass. The last command should block because the custom guard denies messages containing the configured secret phrase.
