# SDK Examples

These four projects are all **fork-the-runtime** examples: they embed the DartClaw runtime in their own process and depend on `dartclaw_core` through `dependency_overrides` pointing at this checkout. The runtime packages are not published and carry no compatibility promise — see [ADR-008](../../dev/adrs/008-sdk-publishing-strategy.md) and the [Package Guide](../../docs/sdk/packages.md).

| Example | Demonstrates | Requires `claude` for live mode |
| --- | --- | --- |
| [single_turn_cli](single_turn_cli/) | One prompt, streamed answer, clean shutdown | Yes |
| [custom_guard](custom_guard/) | Minimal custom `Guard` and `GuardChain` evaluation | No |
| [multi_turn_cli](multi_turn_cli/) | Session-backed multi-turn CLI history | Yes, except `--demo` |
| [shelf_server](shelf_server/) | Minimal HTTP host around the runtime | Yes, except `--demo` |

## Looking for the client tier?

Most consumers want the other tier: talk to a `dartclaw serve` you already run, over its HTTP API and SSE streams, with `package:dartclaw` as the only dependency. The example for that tier is the umbrella package's own [`example/example.dart`](../../packages/dartclaw/example/example.dart), and the [SDK Quick Start](../../docs/sdk/quick-start.md) starts there.
