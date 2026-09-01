# Package Rules — `dartclaw_testing`

**Role**: Canonical home for shared test doubles and in-memory repositories used across the workspace. Public surface is the curated barrel `lib/dartclaw_testing.dart` — only types listed there are reusable across packages.

## Boundaries
- **Consumers MUST list this package only under `dev_dependencies`, never `dependencies`.** Verified across the workspace (`dartclaw_core`, `dartclaw_kernel`, `dartclaw_acp`, `dartclaw_runtime`, `dartclaw_workflow`, `dartclaw_google_chat`, `dartclaw_signal`, `dartclaw_whatsapp`, `dartclaw_cli` all do this). A production dep would ship test doubles into shipped binaries, and now fails CI rather than review: the tier order (`dev/package_tiers.txt`) puts this package on the top tier beside `dartclaw_fitness`, above everything that ships, so a `dependencies:` entry or a `lib/` import naming it is an upward edge. `dev_dependencies` are not edges and stay legal.
- **This package production-depends only on core-and-below.** Allowed prod deps, pinned as an exact set by the `testing_package_deps` gate: `dartclaw_core` and `dartclaw_kernel`. That pin, not the tier position, is what keeps this package from reaching the runtime it outranks. A double whose port is owned above core does **not** belong here — it belongs to the package that owns the port, behind that package's `lib/testing.dart` (see `dartclaw_google_chat` and `dartclaw_workflow`). Adding any other dependency means updating that pin, and needs a reason better than convenience.
- Dev-dependencies are `test` and `lints` only; a double needing a shipped implementation package to test it lives in that package's test tree instead.
- Do **not** add fakes for purely internal collaborators. Per `dev/guidelines/TESTING-STRATEGY.md` Behavioral Boundary Rule, fakes replace external boundaries only — harness binaries, channel networks, third-party REST APIs, subprocesses, persistence ports. Internal classes participate as themselves.

## Conventions
- One file per fake/helper under `lib/src/`, named `fake_*.dart` / `in_memory_*.dart` / `recording_*.dart` / `*_test_helpers.dart`. Export from `lib/dartclaw_testing.dart` with an explicit `show` clause — no blanket exports.
- A helper used by exactly one package belongs in that package's test tree, not here. What lives here is what more than one package shares. `FakeGoogleJwtVerifier` is shared by the Google Chat and server suites because its port is core-owned.
- Naming: `Fake*` for boundary doubles, `InMemory*` for repository ports, `Recording*` for capture-only collaborators, `Test*` for test-aware variants of real types (`TestEventBus`).
- New fake → register in `public_api_test.dart` so the barrel surface stays asserted. Add a focused per-fake test (`fake_*_test.dart`) covering its observable behavior.
- When the real interface gains a method, update the fake in the same change. Drift = false confidence; the milestone-cadence "fake drift audit" exists for a reason but in-flight changes shouldn't introduce drift.
- `FakeAgentHarness` records the authoritative prompt/model/effort turn inputs. `FakeTurnManager` must mirror prompt scope and `systemPromptOverride` exactly so cross-package routing tests can assert the contract.
- `bin/` holds entrypoints that let a non-Dart caller reach a helper that must not be reimplemented outside its authority — currently only `seed_canonical_memory.dart`, so release smoke scripts seed a canonical corpus through `MemoryCorpusService` instead of hand-writing the dialect. Not a home for convenience CLIs.
- Helpers that are utility-only (no fake state) live alongside the fake they support — e.g. `channel_test_helpers.dart`, `codex_harness_test_helpers.dart`, `flush_async.dart`, `null_io_sink.dart`. Don't create a `utils.dart` grab bag.

## Gotchas
- The `lib/dartclaw_testing.dart` barrel re-exports selected `dartclaw_core` types; kernel contracts remain explicit `dartclaw_kernel` imports in tests. Adding a new symbol here is a public-API change for every test suite — keep the `show` lists tight.
- Most consumers import the barrel bare, so removing a re-exported symbol can break a file that never named it. Only a full `dart analyze` plus the complete test run proves a removal is safe.
- `flushAsync` and `pumpEventLoop` exist for microtask drainage; production loops still need `Duration.zero` yields per the `feedback_dart_async_test_loops` rule. Don't paper over real bugs with helper sleeps.
- `FakeCodexProcess` ships v118 helpers (`startHarnessV118`, `respondToLatestThreadStartV118`) for the GPT-5 Codex protocol — pick the right variant; mixing them silently breaks framing.

## Testing
- Tests under `test/` are real package tests of the fakes themselves, not consumer tests. `public_api_test.dart` is the barrel-surface contract.
- A double's pinning test moves with the double: the fakes now owned by `dartclaw_workflow` are pinned in `packages/dartclaw_workflow/test/testing/`, and the server- and CLI-local helpers in their own test trees. The shared JWT-verifier fake is pinned by `fake_google_jwt_verifier_test.dart`.
- No fitness gates live here: the repo-wide suite is the `dartclaw_fitness` workspace member at `dev/fitness/`.
- Run with the standard `dart test` — no integration-tier suites here.

## Key files
- `lib/dartclaw_testing.dart` — curated barrel; the public API of the package.
- `lib/src/fake_agent_harness.dart`, `fake_codex_process.dart`, `fake_process.dart` (also holds `RecordingGitRunner`/`GitInvocation`, the single test seam for `dartclaw_kernel`'s canonical `runGit`), `fake_channel.dart`, `fake_channel_manager.dart`, `fake_guard.dart`, `fake_google_jwt_verifier.dart`, `fake_content_classifier.dart`, `fake_turn_manager.dart`, `fake_project_service.dart` — boundary doubles.
- `lib/src/in_memory_*.dart` — repository ports (task, session, workflow step).
- `lib/src/test_event_bus.dart`, `lib/src/recording_message_queue.dart` — recording collaborators.
- `lib/src/channel_test_helpers.dart`, `lib/src/codex_harness_test_helpers.dart` — scenario scaffolding.
- `lib/src/canonical_memory_fixture.dart` — `seedCanonicalMemory`; the only sanctioned way to write a canonical memory corpus for a fixture. `MemoryPreflight` refuses the preview dialect, so hand-written Markdown fails at startup.
- `bin/seed_canonical_memory.dart` — the same helper for shell callers (`dev/testing/profiles/windows-runtime/run.ps1`); run it from the workspace root.
- `test/public_api_test.dart` — barrel-surface contract; update when exporting a new symbol.
