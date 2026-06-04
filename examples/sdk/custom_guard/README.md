# custom_guard

Minimal DartClaw SDK example that implements a custom `Guard`, adds it to a `GuardChain`, and evaluates sample inbound messages.

This example uses `dependency_overrides` that point at local workspace packages because the SDK is still pre-publication. Once the SDK packages are published, replace the overrides with normal package dependencies.

Prerequisites: Dart SDK 3.12+. This example does not require the `claude` binary or provider auth because it exercises the guard framework directly.

```bash
cd examples/sdk/custom_guard
dart pub get
dart run
dart run custom_guard "please keep this public"
dart run custom_guard "my launch code is swordfish"
```

The first two commands should pass. The last command should block because the custom guard denies messages containing the configured secret phrase.
