# SDK Examples

Runnable DartClaw SDK examples. Each project uses `dependency_overrides` that point at this local workspace while the SDK packages are pre-publication.

| Example | Demonstrates | Requires `claude` for live mode |
| --- | --- | --- |
| [single_turn_cli](single_turn_cli/) | One prompt, streamed answer, clean shutdown | Yes |
| [custom_guard](custom_guard/) | Minimal custom `Guard` and `GuardChain` evaluation | No |
| [multi_turn_cli](multi_turn_cli/) | Session-backed multi-turn CLI history | Yes, except `--demo` |
| [shelf_server](shelf_server/) | Minimal HTTP host around the SDK | Yes, except `--demo` |
