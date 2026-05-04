# Package Rules — `dartclaw_testing`

**Role**: Canonical home for shared test doubles and in-memory repositories used across the workspace. Public surface is the curated barrel `lib/dartclaw_testing.dart` — only types listed there are reusable across packages.

## Boundaries
- **Consumers MUST list this package only under `dev_dependencies`, never `dependencies`.** Verified across the workspace (`dartclaw_core`, `dartclaw_security`, `dartclaw_server`, `dartclaw_workflow`, `dartclaw_signal`, `dartclaw_whatsapp`, `dartclaw_google_chat`, `dartclaw_cli` all do this). A production dep on this package would ship test doubles into shipped binaries — fail review.
- This package's own `dependencies:` block intentionally pulls in `dartclaw_server`, `dartclaw_workflow`, `dartclaw_google_chat`, etc. — that is correct, the fakes implement those packages' interfaces. Don't try to invert it.
- Allowed prod deps (arch_check L1): `dartclaw_core`, `dartclaw_google_chat`, `dartclaw_models`, `dartclaw_security`, `dartclaw_server`, `dartclaw_workflow`. Adding `dartclaw_storage` (currently a dev_dependency) requires updating the arch_check contract.
- Do **not** add fakes for purely internal collaborators. Per `dev/guidelines/TESTING-STRATEGY.md` Behavioral Boundary Rule, fakes replace external boundaries only — harness binaries, channel networks, third-party REST APIs, subprocesses, persistence ports. Internal classes participate as themselves.

## Conventions
- One file per fake/helper under `lib/src/`, named `fake_*.dart` / `in_memory_*.dart` / `recording_*.dart` / `*_test_helpers.dart`. Export from `lib/dartclaw_testing.dart` with an explicit `show` clause — no blanket exports.
- Naming: `Fake*` for boundary doubles, `InMemory*` for repository ports, `Recording*` for capture-only collaborators, `Test*` for test-aware variants of real types (`TestEventBus`).
- New fake → register in `public_api_test.dart` so the barrel surface stays asserted. Add a focused per-fake test (`fake_*_test.dart`) covering its observable behavior.
- When the real interface gains a method, update the fake in the same change. Drift = false confidence; the milestone-cadence "fake drift audit" exists for a reason but in-flight changes shouldn't introduce drift.
- Helpers that are utility-only (no fake state) live alongside the fake they support — e.g. `channel_test_helpers.dart`, `codex_harness_test_helpers.dart`, `flush_async.dart`, `null_io_sink.dart`. Don't create a `utils.dart` grab bag.

## Gotchas
- The `lib/dartclaw_testing.dart` barrel re-exports selected types from `dartclaw_core`, `dartclaw_server`, `dartclaw_security`, `dartclaw_models`, and `dartclaw_google_chat` so test files only import this one package. Adding a new symbol here is a public-API change for every test suite — keep the `show` lists tight.
- `FakeGitGateway` has a parity test (`fake_git_gateway_parity_test.dart`) that pins its behavior against the real gateway shape — update both when the gateway interface changes.
- `flushAsync` and `pumpEventLoop` exist for microtask drainage; production loops still need `Duration.zero` yields per the `feedback_dart_async_test_loops` rule. Don't paper over real bugs with helper sleeps.
- `FakeCodexProcess` ships v118 helpers (`startHarnessV118`, `respondToLatestThreadStartV118`) for the GPT-5 Codex protocol — pick the right variant; mixing them silently breaks framing.

## Testing
- Tests under `test/` are real package tests of the fakes themselves, not consumer tests. `public_api_test.dart` is the barrel-surface contract.
- `test/fitness/` runs package-local fitness checks; keep additions cheap.
- Run with the standard `dart test` — no integration-tier suites here.

## Key files
- `lib/dartclaw_testing.dart` — curated barrel; the public API of the package.
- `lib/src/fake_agent_harness.dart`, `fake_codex_process.dart`, `fake_process.dart`, `fake_channel.dart`, `fake_guard.dart`, `fake_git_gateway.dart`, `fake_turn_manager.dart`, `fake_project_service.dart`, `fake_google_chat_rest_client.dart`, `fake_google_jwt_verifier.dart` — boundary doubles.
- `lib/src/in_memory_*.dart` — repository ports (task, session, agent execution, workflow step execution, transactor).
- `lib/src/test_event_bus.dart`, `lib/src/recording_message_queue.dart` — recording collaborators.
- `lib/src/channel_test_helpers.dart`, `lib/src/codex_harness_test_helpers.dart`, `lib/src/workflow_git_fixture.dart` — scenario scaffolding.
- `test/public_api_test.dart` — barrel-surface contract; update when exporting a new symbol.
