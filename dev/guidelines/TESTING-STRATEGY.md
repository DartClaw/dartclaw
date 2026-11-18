# DartClaw Testing Strategy

> **Status**: Active
> **Last reviewed**: 2026-11-18
> **Scope**: All packages in the DartClaw pub workspace

---

## Philosophy

Start with the failure a caller would notice. Drive the entry point the caller uses and assert the returned value,
persisted change, delivered message or response frame. A refactor that preserves that contract should keep the test green.

- Give each behavior a named test that runs by itself. Table-drive cases with the same setup and assertions, naming each input or outcome so a failing row is selectable.
- Use real collaborators and put doubles at the edge. A channel recipient, a retry count promised to a client, and a subprocess exit status are observable. Internal method order and private collection types can change freely.
- Put the edge-case matrix at the cheapest layer that can distinguish success from failure. Exercise the assembled handler or runtime when wiring adds a risk the lower layer cannot see.
- For a bug, run the regression against the broken behavior first. When rewriting an existing test, temporarily remove the behavior in isolation and check that the owning assertion fails. A rejected event followed by an accepted event on the same stream distinguishes filtering from a dead subscription.
- Replace source-string scans for runtime behavior with executable assertions. Keep structural checks where the structure is the contract, such as package dependency direction or a published schema.
- Preserve malformed inputs, legitimate inputs that must pass, denial cases, compatibility fixtures and boundary cases for guards, codecs, auth, storage, concurrency and workflow execution. Consolidate a duplicate only when the surviving test fails for the same regression.

**BDD frameworks: evaluated, not adopted.** Dart BDD packages either target Flutter/widget tests or mostly rename `group`/`test` without removing DartClaw's real friction (fixture/harness setup, route requests, filesystem and workflow matrices). Use BDD *language* — behavior-first test names, scenario grouping, and small table- or `Given/When/Then`-shaped helpers — where it improves scanning. Do not add a BDD framework dependency.

---

## Verification Scope at the Experimental Stage

This is the default for development, reviews, and experimental releases. It supersedes older blanket accessibility
qualification requirements, including the 0.27 Q10/E11 matrices. An explicit accessibility or compatibility task can
select a broader scope; do not infer one from a generic request for review, integration tests, or E2E verification.

| Required for the affected surface | Deferred unless explicitly requested or needed to reproduce a defect |
|---|---|
| Security boundaries, data integrity, persistence/recovery, public contracts | Full WCAG conformance audits and scanner-wide zero-finding targets |
| Core user journeys through the assembled app, including relevant failure/recovery paths | Screen-reader and physical-device/browser matrices |
| Basic keyboard operation, focus/labels, readable text, usable controls and no blocking overflow | Exhaustive contrast measurements, gradient adjudication, zoom/theme/viewport combinations |

Basic usability remains part of ordinary UI work: fix an observed keyboard trap, unreadable control, or inaccessible
primary action. A scanner's incomplete result alone is not a functional defect or an experimental-release blocker.
Retain audit output as advisory evidence; deferred checks are not passes and confer no accessibility claim.

Run focused regressions, affected integration/API tests, then a few browser journeys for wiring and interactions
lower layers cannot prove. Use one desktop browser by default; add a narrow viewport for layout changes and other
environments only for a named risk. Keep the mandatory gates in [Key Development Commands](KEY_DEVELOPMENT_COMMANDS.md).
This policy does not waive security or data-loss checks.

During diagnosis, rerun the failing step, not every previously passing journey or crash test. Repeat broader checks
when subsequent changes invalidate their evidence, and run the required final gate after implementation settles.
Documentation-only strategy edits need document/diff checks, not application builds or browser sweeps.

Keep functional assertions separate from optional audits in runners and reports. Existing strict profiles may still
combine them: select an affected journey or separate the phases before execution; never suppress a command failure
or manufacture a full-suite receipt. Report functional results, unexecuted checks, and advisory audits separately.

## Test Layers

Choose the boundary that owns the risk and the infrastructure that boundary needs. A parser can usually be exercised in memory. SQL transactions need PostgreSQL.
A route that projects workflow events into SSE needs the HTTP handler, event source and response stream.

```text
        Live / E2E        very few, explicit, expensive
      API / Handler       public HTTP/SSE/template contracts
    Component / Integration broad body of production-shaped behavior
  Focused Unit            dense pure logic, security rules, parsers, validators
Static checks             format, analyzer, architecture, fitness
```

**Layer choice rule**: pick the lowest level that proves the behavior without heavy mocking. If a unit test needs elaborate fakes for DartClaw-owned collaborators, promote it to a component/integration test. If an integration test mostly proves pure parser/validator logic, demote that behavior to a focused unit test and keep at most one integration smoke for wiring.

### Layer 1 — Focused Unit Tests

**What**: Behavioral tests through public APIs. No file I/O, no network, no subprocesses, no database. May involve a single function or multiple collaborating classes — the distinguishing factor is zero infrastructure, not class count.

**Targets**: Parsers, validators, models, config readers, pattern matchers, guard evaluators, guard chains, state machines, output normalization, path containment, redaction, budget math, schema presets, and other dense pure logic.

**Sociable tests are welcome here.** When a behavior involves multiple classes working together (e.g., `GuardChain` +
`Guard` implementations, `ChannelTaskBridge` + `ThreadBindingRouter`), test them together through the entry-point's
public API. Only introduce test doubles when a collaborator crosses an external boundary or is genuinely impractical to
construct.

**Characteristics**:
- Run in-process with no infrastructure startup
- Zero or minimal `setUp`/`tearDown` overhead
- Assertions on return values, observable state changes, or interactions with external boundaries
- Use constructor injection for any dependency
- Parallel-safe by default; if a test cannot run alongside other package tests, it is not Layer 1

**When to write**: When the behavior is cheaper and clearer to prove without infrastructure, or when the edge-case matrix would make an integration test slow, noisy, or hard to diagnose. Security-critical pure rules still get exhaustive focused unit coverage.

**When to skip**: Trivial delegating methods with zero branching. Generated boilerplate. Private helpers whose behavior is fully covered by public API tests.

For example, the session key suite checks that a literal peer ID containing `@` produces the encoded key that
downstream storage uses. [Session key cases](../../packages/dartclaw_kernel/test/session_key_test.dart)

### Layer 2 — Component / Integration Tests

Exercise a service through its storage or delivery boundary. Use an isolated directory for files and a recording
harness or channel for outbound work. Use disposable PostgreSQL for SQL dialect, schema, transactions, interlocks,
database search and restore behavior. An in-memory repository suffices when the claim concerns its caller.

**Targets**: Services with file-based storage, multi-service interactions, EventBus subscriber chains, channel message
routing, task lifecycle flows, workflow execution with fake harnesses, CLI/server wiring seams, and repository contracts.

**Characteristics**:
- Temp directories for file-based storage (`Directory.systemTemp.createTempSync`)
- Domain repository/backend fakes when SQL behavior is not the claim
- Shared fakes from `dartclaw_testing` for external boundaries (harness, channels, processes)
- Per-test isolation — `setUp` creates fresh state, `tearDown` cleans up
- When testing real local resources (TCP ports, process wiring, working-directory behavior, static-asset lookup), isolate them per test: bind port `0`, use per-test temp directories, and inject the working directory rather than assigning `Directory.current`. Serialization (`-j 1`) is a last resort — it costs 3–5× wall time across the package.
- Keep filesystem assertions portable across Linux CI and local macOS. For POSIX file permission assertions, prefer
  `File.statSync().mode & 0x1ff` and compare the octal string; do not shell out to platform-specific `stat` flags
  (`stat -f` is BSD/macOS, `stat -c` is GNU/Linux).

**When to write**: As the default for production-shaped behavior that needs storage, persistence, process/channel/harness boundaries, or several real DartClaw collaborators. Prefer this layer over mock-heavy unit tests.

**When to skip**: When the service is a thin wrapper that delegates entirely to a tested component.

The Knowledge Hub corpus suite seeds a temp wiki with both pipeline-authored pages and raw imported Markdown, then
queries the hub and lints the wiki. It runs in the default suite. [Corpus tests](../../packages/dartclaw_runtime/test/integration/knowledge_hub_corpus_integration_test.dart)

### Layer 3 — API / Handler Tests

Invoke the shelf handler directly with a request. Use real services and isolate storage and external dependencies to the extent the response contract allows.

**Targets**: HTTP route handlers, auth middleware, response shapes, error codes, content negotiation (JSON vs HTML fragment), SSE stream structure.

**Characteristics**:
- Construct the handler or server in `setUp`, invoke with `shelf.Request`
- Assert on status codes, response bodies (JSON decode or HTML contains), headers
- Test both authenticated and unauthenticated paths
- No real network — fast and deterministic

**When to write**: For every API endpoint that external consumers (web UI, CLI, channels) depend on. For auth middleware. For any response that has conditional structure (fragment vs full page, JSON error envelope). These are the primary public contract tests for server behavior.

**When to skip**: Endpoints that are trivial pass-through to a tested service with no transformation.

The workflow SSE suite drives a real handler, reads the connected snapshot and then checks the events a subscriber
receives for that run. [Workflow SSE tests](../../packages/dartclaw_runtime/test/api/workflow_sse_test.dart)

### Layer 4 — Live Integration & E2E Tests

**What**: Tests that require real external systems, real binaries, or the fully assembled runtime wiring.

Tagged `@Tags(['integration'])` and skipped by default in `dart_test.yaml`; run explicit files through their package/profile command with skipped tests enabled.
Allow long timeouts (`Timeout(Duration(seconds: 60))`) and prepare required API keys, binaries or hardware.

**When to write**: For protocol-level verification (JSONL round-trip with real binary), channel E2E pairing flows, deployment smoke tests, live workflow canaries, and server-builder wiring that must exercise the real package composition.

**When to skip**: Almost always — prefer Layer 2 integration tests with `FakeAgentHarness` / `FakeProcess`. Only write Layer 4 tests when the real binary's behavior cannot be faithfully simulated.

The composition-root E2E coverage lives in [`packages/dartclaw_runtime/test/runtime/server_builder_integration_test.dart`](../../packages/dartclaw_runtime/test/runtime/server_builder_integration_test.dart), which boots the real `DartclawRuntime`, uses `FakeAgentHarness` plus prepared domain fakes, and verifies that the assembled server serves `/` and `/health`. Separate live PostgreSQL probes prove production storage wiring.

### Workflow Validation Ladder

Workflow changes should move through the cheapest proof surface that covers the risk before using live model-backed tests.

1. **Workflow contract profile** - deterministic Dart tests for built-in YAML policy, gates, output contracts, review artifact resolution, aggregate-review wiring, and step-outcome semantics.
2. **Scripted/component E2E** - executor-level tests with fakes or canned harness responses when workflow plumbing needs to run without live agent turns.
3. **Targeted live canary** - one live integration canary for the changed subsystem.
4. **Full live workflow sweep** - final confidence gate only.

Choose the profile from the [testing commands](KEY_DEVELOPMENT_COMMANDS.md#testing-unit-integration-e2e).
Use the full live sweep when the change spans provider-backed journeys or release qualification calls for it.

The live runner writes logs under `.agent_temp/` by default and summarizes warning classes that are easy to miss in the
expanded reporter stream: cleanup idempotency noise, provider capability warnings, local plugin manifest warnings, and
large token-accounting lines.

### Integration test model selection

The workflow integration tier (`packages/dartclaw_workflow` Layer 4 suite, run through the `workflow-live` profile) runs against a default provider + per-role model preset baked into `E2EFixture`. Five environment variables let you swap that preset at run time without editing fixtures or test files:

| Variable | Effect |
|---|---|
| `DARTCLAW_TEST_PROVIDER` | `codex` (default) or `claude`. Selects the preset for the four role models, the provider's executable, and the sandbox / `permissionMode` setting. |
| `DARTCLAW_TEST_WORKFLOW_MODEL` | Overrides the `workflow` role model. |
| `DARTCLAW_TEST_PLANNER_MODEL` | Overrides the `planner` role model. |
| `DARTCLAW_TEST_EXECUTOR_MODEL` | Overrides the `executor` role model. |
| `DARTCLAW_TEST_REVIEWER_MODEL` | Overrides the `reviewer` role model. |

**Precedence**: explicit `E2EFixture(...)` constructor arg wins over env var, env var wins over preset default. Empty-string env vars are treated as unset.

**Provider presets**:

| Preset | Workflow | Planner | Executor / Reviewer | Sandbox | API key env var |
|---|---|---|---|---|---|
| `codex` | `gpt-5.6-luna` | `gpt-5.6-luna` (`medium`) | `gpt-5.6-luna` | `danger-full-access` | `CODEX_API_KEY` |
| `claude` | `claude-opus-5` | `claude-opus-5` | `claude-sonnet-5` | `dontAsk` | `ANTHROPIC_API_KEY` |

(The claude `Sandbox` column is the `permissionMode`. It stays `dontAsk`, **not** `bypassPermissions`, so provider prompts remain compatible with the guarded harness path.)

The fixture default provider is `codex`: all four roles run on `gpt-5.6-luna` (planner at medium effort). The product recommendation is `gpt-5.6-sol` for every role with effort varied per role (`docs/guide/workflows.md`); the test mapping uses luna because on sol the plan step's sub-agent fan-out ended the turn after the first story spec, and luna is quicker and cheaper for the fixture. Opt into Claude Sonnet with `DARTCLAW_TEST_PROVIDER=claude`. A Claude harness may print the benign stderr notice `Permission mode forced to default — CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is set`; the CLI does force default mode when the scrub var is set, while the host guard chain remains authoritative for step tool policy. Do not mistake the notice for a failure cause; a step failing `subtype=error_max_turns` points at the structured-output envelope finalizer's turn cap (`workflow_one_shot_runner.dart`), not at the env scrub.

Set the provider and any role overrides when invoking the affected workflow canary. The profile uses the provider
preset for unspecified roles. [Canary commands](KEY_DEVELOPMENT_COMMANDS.md#testing-unit-integration-e2e)

**Hermetic provider setup.** `workflow-live/run.sh` runs a fail-fast provider preflight before any `dart test` — a `--version` probe, a codex bundled-tool quarantine check, and Codex round-trips on the pinned workflow, planner, executor, and reviewer configurations (deduplicated when identical; Claude retains its executor-only probe; skip with `--skip-preflight`). Codex runs require the AndThen plugin under `~/.codex/plugins/cache/andthen`; the script copies and enables it in a profile-owned hermetic `CODEX_HOME` with seeded `auth.json` and a pinned executor model. Operator config cannot override fixture models in spawns that omit `--model` (skill-introspection probes, direct `executeTurn` calls). The step-isolation suite additionally pins `--model` explicitly on its direct harness spawns.

### Visual / UI Smoke Tests (Manual)

**What**: Browser-based visual validation of the HTMX web UI. Manual or agent-driven via `chrome-devtools` MCP / `agent-browser`.

Select affected journeys from [`UI-SMOKE-TEST.md`](../testing/UI-SMOKE-TEST.md) against `plain` or `channels`.
These are explicit browser checks, outside `dart test`. After UI changes, inspect the changed flow; before releases,
smoke the core flows. Apply the experimental-stage scope above rather than every optional audit in the inventory.

**Note**: Template rendering correctness (HTML structure, XSS escaping) is tested at Layer 2/3 via string assertions on rendered output. Browser tests cover layout and interactivity that string assertions cannot verify.

---

## What Must Always Be Tested

These categories get comprehensive test coverage — no exceptions.

### Security-Critical Components
- **Guard implementations** — every pattern with both blocking (true positive) AND non-blocking (false positive) cases
- **Content guard** — classifier verdicts at the agent boundary, fail-open vs fail-closed on classifier error, legitimate content that must pass
- **Message redactor** — secret patterns, PII patterns, partial redaction correctness
- **Auth middleware** — valid token, invalid token, missing token, expired token, rate limiting
- **SSRF protection** — private IP ranges, DNS rebinding, localhost variants
- **File guard** — path traversal, symlink resolution, allowlist/blocklist enforcement
- **Session key derivation** — scoping rules determine security isolation boundaries

### Data Integrity
- **Storage services** — CRUD operations, cursor-based crash recovery, restart persistence
- **NDJSON codec** — encode/decode round-trip, malformed lines, partial writes, empty files
- **JSONL control protocol** — message framing, large payloads, error responses
- **Config parser** — valid YAML, invalid YAML, missing fields, type mismatches, default values
- **Task state machine** — every valid transition, every invalid transition rejection

### Public API Contracts
- **Barrel exports** — one smoke test per package verifying the public API surface
- **Contract tests** — any interface with multiple implementations (e.g., `SearchBackend`) gets a shared test suite that all implementations must pass
- **Dartdoc lint rail** — `public_member_api_docs` is enabled in `dartclaw_kernel` and `dartclaw_core`; new undocumented public surface in those packages fails CI.

---

## What Should Usually Be Tested

These get coverage when the risk justifies it.

- Service-level integration (service + storage + fake boundaries)
- HTTP route handlers (status codes, response shapes, error cases)
- EventBus subscriber chains (event fired → subscriber action observed)
- Rate limiters and debounce logic (with `fake_async`)
- Template rendering (HTML structure, correct escaping, fragment vs full page)
- Config validation (ConfigMeta registration, unknown field warnings)

---

## What Can Be Skipped

- **Trivial delegation**: A method that calls one other method with no transformation
- **Generated/derived code**: Serialization for simple models that is tested transitively
- **Private helpers**: If the public method that calls them is tested
- **Visual layout**: Handled by manual UI smoke tests, not unit tests
- **Real-binary interaction**: Prefer `FakeAgentHarness` — only use Layer 4 for protocol verification

---

## Test Infrastructure

### Shared Test Doubles and Helpers (`dartclaw_testing` package)

Shared fakes for core-and-below boundaries live in `packages/dartclaw_testing/`. This is the canonical source — **never redeclare fakes locally in test files**.

**Where a double lives** (three homes, in this order):

1. **A double for a port owned by `dartclaw_core` or `dartclaw_kernel`** → `dartclaw_testing`, exported from its barrel. That package production-depends on core-and-below only, so consuming one shared double never drags an upper-tier package into a suite's dependency closure.
2. **A double for a port owned above core, used by more than one package** → the package that owns the port, in `lib/src/testing/`, re-exported from that package's `lib/testing.dart` with an explicit `show` clause. A `test/` tree is not reachable across packages, so the port's owner is the only home every consumer already depends on. The package barrel must not re-export it, so the production surface stays free of test-only symbols. Import it as `package:dartclaw_google_chat/testing.dart` or `package:dartclaw_workflow/testing.dart` — the `package:http/testing.dart` idiom.
3. **A helper used by exactly one package** → that package's own test tree. Nothing that one package uses belongs in the shared package.

**Boundary rule for fakes**: Fakes should replace *external boundaries* — systems that are slow, non-deterministic, or outside the process (harness binaries, channel networks, third-party REST APIs, subprocesses). Do not create fakes for internal collaborators that can participate as real objects. Each fake is a maintenance surface that can drift from the real implementation it replaces.

| Fake / helper | Purpose | Key features |
|---------------|---------|-------------|
| `FakeAgentHarness` | Agent turn simulation | Controllable completions, event emission, call tracking |
| `FakeChannel` | Channel message routing | Configurable JID ownership, sent message recording |
| `FakeGuard` | Guard pipeline testing | Configurable verdicts, dynamic evaluators |
| `FakeProcess` | Subprocess simulation | Stream-backed stdout/stderr, kill tracking |
| `CapturingFakeProcess` | Subprocess I/O assertions | Captures stdin lines and decoded JSON maps |
| `FakeCodexProcess` | Codex/Claude harness protocol tests | JSON-RPC helpers and outbound message capture |
| `FakeChannelManager` | Channel registry routing | Records dispatched messages per channel |
| `FakeContentClassifier` | Content-guard boundary | Configurable classification verdicts |
| `FakeProjectService` | Project CRUD flows | Callback-driven state and freshness checks |
| `FakeTurnManager` | Turn lifecycle control | Reserve/execute/cancel hooks and configurable outcomes |
| `NullIoSink` | Discard-all IOSink for subprocess tests | No-op `write`, `add`, `close` — silences stdout/stderr |
| `InMemorySessionService` | Session storage without filesystem | Full API mirror, zero I/O |
| `InMemoryTaskRepository` | Task storage without a database | Full CRUD, in-memory |
| `InMemoryWorkflowStepExecutionRepository` | Workflow-step storage without a database | Full kernel repository contract, in-memory |
| `RecordingMessageQueue` | Queue routing assertions | Enqueued-message recording, optional forwarding |
| `TaskOps` | Channel/task test scaffolding | Shared create/transition/update helpers |
| `TestEventBus` | Event bus with recording | Event capture, subscription verification |

Doubles served from their owning package's `testing.dart` instead of the shared barrel:

| Fake / helper | Entry point | Port it replaces |
|---------------|-------------|------------------|
| `FakeGoogleChatRestClient` | `package:dartclaw_google_chat/testing.dart` | `GoogleChatRestClient` |
| `FakeGitGateway` | `package:dartclaw_workflow/testing.dart` | `WorkflowGitPort` |
| `FakeSkillIntrospector` | `package:dartclaw_workflow/testing.dart` | `SkillIntrospector` |
| `FakeProviderAuthPreflight` | `package:dartclaw_workflow/testing.dart` | `ProviderAuthPreflight` |

**Rule**: When you need a test double, check `dartclaw_testing` first, then the owning package's `testing.dart`. If a suitable fake doesn't exist, add it to whichever of the three homes above applies — not to the test file.

**Fake drift audit** (at each milestone): For each fake in `dartclaw_testing`, verify it still faithfully represents the interface it replaces. Look for methods added to the real interface but missing from the fake, or behavioral assumptions in the fake that no longer match reality. Fakes that drift from their real counterparts produce false confidence — tests pass while production breaks.

Related helpers such as `channelOriginJson`, `createTask`, `flushAsync`, `latestRequestId`, `noOpDelay`, `pumpEventLoop`, `putTaskInReview`, `respondToLatestThreadStart`, `shortTaskId`, `startHarness`, and `waitForSentMessage` are also exported from `dartclaw_testing` for reuse.

Single-package helpers live with their consumer: `WorkflowGitFixture` in `packages/dartclaw_workflow/test/workflow/component/workflow_git_test_support.dart`, `InMemoryAgentExecutionRepository` / `InMemoryExecutionRepositoryTransactor` in `packages/dartclaw_runtime/test/helpers/`, and `captureRootLogs` in `apps/dartclaw_cli/test/helpers/log_test_helpers.dart`. `FakeGoogleJwtVerifier` is shared from `dartclaw_testing` because the core-owned port now has consumers in the Google Chat and server packages.

### Test Configuration

The workspace and member `dart_test.yaml` files configure default skips. The following distinctions matter when selecting a run.

- An ordinary component test with isolated files, in-memory repositories or a scripted harness runs by default. Add `component` or `contract` only where someone will use that selector.
- `slow` keeps expensive tests in the default suite and makes them separately selectable. Tag individual cases when a file mixes cheap assertions with real builds or process deadlines. Measure both selections and check that their counts add up to the unfiltered run.
- `integration` opts a suite out of the default run for explicit setup such as a disposable PostgreSQL database, a provider or full runtime wiring. `live-e2e` identifies the heavy provider journeys. Use the narrowest documented profile or explicit file with its prerequisites.

### Testing Profiles (Pre-configured Environments)

| Profile | Command | Purpose |
|---------|---------|---------|
| `plain` | `bash dev/testing/profiles/plain/run.sh` | Minimal seeded data, no channels |
| `channels` | `bash dev/testing/profiles/channels/run.sh` | WhatsApp + Signal enabled |
| `governance` | `bash dev/testing/profiles/governance/run.sh` | Tight governance limits and budget seeding |
| `visual` | `bash dev/testing/profiles/visual/run.sh` | Desktop visual smoke profile with seeded content |
| `workflows` | `bash dev/testing/profiles/workflows/run.sh` | Workflow execution profile and CLI wrapper |

Profiles have documented default ports in `dev/testing/README.md`. Use `--port <N>` to override server profiles.

---

## Async Testing Patterns

### Application timers

Advance the clock through the boundary the caller observes. The alert throttle suite checks delivery eligibility before and after
its cooldown, using a virtual clock in a synchronous `fakeAsync` callback. [Alert throttle tests](../../packages/dartclaw_runtime/test/alerts/alert_throttle_test.dart)

### Wait for the observable event

Subscribe before triggering the action. Await the frame, task result, or child-process exit and cancel subscriptions in
teardown. A timeout bounds a missing signal. On the success path the test proceeds as soon as the signal arrives.
Use `pumpEventQueue()` only to let already-scheduled in-process work advance. It cannot confirm completion of disk or
network I/O. Keep a real deadline when termination of an OS process is the behavior under test.
[Workflow event-stream tests](../../packages/dartclaw_runtime/test/api/workflow_sse_test.dart)

### Async loop safety

Never use `(_) async {}` delay patterns in production loops being tested. This causes microtask starvation and multi-GB memory leaks. Production loops must yield to the timer queue (`Timer`, `Future.delayed` with non-zero duration, or structured async patterns).

---

## Measuring feedback time

Time the exact selector a developer will run. Compare the same reporter, machine and cache state, and record the
number of cases executed. For a slow file, the JSON reporter records test start and finish times. Use those to
distinguish expensive fixtures and real waits from Dart startup. Use elapsed time as diagnostic evidence. A missed
deadline fails a test only when the deadline belongs to the behavior under test or bounds a missing signal.

## Running Tests

Use the selectors and tier commands in [Key Development Commands](KEY_DEVELOPMENT_COMMANDS.md#testing-unit-integration-e2e).

| Change under test | Start here | Widen when |
|---|---|---|
| Local behavior or regression | Named case, then its file | Neighboring cases share setup or a state transition |
| Handler, workflow step or channel adapter | Affected files or directory in that package | The changed contract has a consumer in another package |
| Shared fixture, barrel or public type | Owning tests plus affected consumers | Consumers cannot be bounded confidently, so run the full tier |
| Schema, transaction or restart recovery | The real boundary test with its required fixture | The change spans storage engines, runtime wiring or a live journey |

During a story, run the fixed fast smoke plus the story's own proofs. During iteration, rerun the failed case or file.
Run the full tier and the required CI-equivalent checks at the integration points listed in Key Development Commands.
Keep each member in its own test process and isolate mutable fixtures with per-test temp roots and ephemeral ports.

### PostgreSQL contract

The PostgreSQL gate runs first against plain PostgreSQL 14 without `public.vector`, then against a pgvector-capable
database for explicit hybrid behavior. [CI-equivalent gate](KEY_DEVELOPMENT_COMMANDS.md#ci-equivalent-gate)

It removes disposable resources on success, failure or interruption. A
container may provision test resources for the local gates, but that does not make a container engine the operator setup default.

Alternatively, supply the runner's documented disposable PostgreSQL URLs. Fixtures create/drop schemas, roles and
databases and terminate test connections, so never point them at a retained deployment. The vector lane creates its
own restricted role; a supplied database needs no container engine.

Coverage: backend/repository contracts, schema/vector preparation, lexical/vector search, serving interlocks,
hybrid/runtime wiring, workspace isolation and CLI rebuilds. The `full` workspace tier skips these live suites.
Provider-dependent retention is excluded. Run it from the workspace root with `DARTCLAW_POSTGRES_URL` and `CODEX_API_KEY`:

```bash
dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/temporary_retention_postgres_live_test.dart
```

Every contract group name starts with `[contract:<id>]`, and the same change must classify that id in
`packages/dartclaw_core/test/storage/contract/contract_groups.json`. The report checker compares exact sets, so an
unclassified group or a missing group fails the run.

Cross-engine search differences belong in `fts_divergence_whitelist.json` only with the query, document id, engine,
engine-level evidence, and review date. Entries that no current fixture exercises fail as stale.

### Coverage

```bash
# Per-package coverage
dart test --coverage=coverage/ packages/dartclaw_core
dart pub global run coverage:format_coverage \
  --lcov --in=coverage/ --out=coverage/lcov.info \
  --report-on=lib/

# View coverage report
genhtml coverage/lcov.info -o coverage/html && open coverage/html/index.html
```

---

## Applying This Strategy to New Features

When implementing a new feature (FIS), determine test requirements by asking:

1. **Is it security-critical?** (guards, auth, sanitization, access control) → Exhaustive Layer 1 + Layer 2 tests including false-positive coverage
2. **Does it manage state transitions?** (task lifecycle, session scoping, binding lifecycle) → Layer 1 for the state machine (if no infrastructure needed), Layer 2 for service integration with storage
3. **Does it persist data?** (storage, config, thread bindings) → Layer 2 with temp dirs or domain fakes; real PostgreSQL for SQL behavior
4. **Does it expose an API?** (HTTP routes, slash commands, config API) → Layer 3 handler tests
5. **Does it interact with external systems?** (channels, claude binary, Google Chat API) → Layer 2 with fakes for external boundaries, Layer 4 only if fake coverage is insufficient
6. **Is it pure logic or multi-class domain behavior?** (parsing, validation, rate calculation, guard chain orchestration) → Layer 1, letting real collaborators participate where practical

Each FIS should specify which layers are needed and why, referencing this strategy.

### Reviewing coverage

Review changed behavior for an untested failure, boundary input, or affected consumer. Use a coverage report to
locate unexecuted branches when that helps. Before merge, record the selected commands, pass and skip counts, and
which real boundaries ran. Keep flaky tests enabled while diagnosing them. Quarantine requires a maintainer decision.

---

## Anti-Patterns

- **Waiting a fixed interval for an async result**. A short sleep races a busy host and a long one slows every pass. Wait for the emitted event or the operation's completion.
- **Local fake redeclaration** — Copying `FakeAgentHarness` into a test file instead of importing from `dartclaw_testing`. Causes drift.
- **Testing implementation details** — Asserting on private field values, internal call sequences between domain classes, or the specific way a result was computed. Test what the system *produces*, not *how* it produces it. Note: asserting on interactions with *external boundaries* (e.g., verifying a message was sent to a channel, or that the correct review action was dispatched) is testing observable behavior, not implementation — that is appropriate.
- **Mocking internal collaborators** — Replacing domain classes with mocks to test another domain class in isolation. Let real collaborators participate. Only use fakes at external boundaries. If constructing a collaborator is painful, that's design feedback — fix the design, not the test.
- **One test per class** — Writing a test file for every class is a structural mirror, not a behavioral strategy. The trigger for a new test is implementing a new behavior, not creating a new class.
- **Catch-all exception tests** — `expect(() => ..., throwsException)`. Always assert on the specific exception type.
- **Shared mutable state across tests** — Using `setUpAll` with mutable state. Each test gets its own `setUp`.
- **Ignoring tearDown** — Temp directories and database connections must be cleaned up. Leaked resources cause flaky CI.
- **100% coverage chasing** — Writing tests for trivial getters or delegation methods. Focus on risk.
- **Mock returning a mock** — If a test double returns another test double, the test is likely testing nothing real. Step back and reconsider whether you are testing at the right level of abstraction.

---

## Fitness Functions

DartClaw ships a fitness suite at `dev/fitness/` – a dev-rooted workspace member that declares no production dependencies and imports none, so a repo-wide gate can never depend on the code it governs. It runs through the local `fitness` release gate and catches the drift classes surfaced in earlier milestones.

Run locally: `bash dev/tools/run-fitness.sh`

The L1 checks (plus a separate `dart format --line-length=120 --set-exit-if-changed` CI gate):

| Test file | What it enforces |
|-----------|-----------------|
| `barrel_show_clauses_test.dart` | Every `export 'src/...'` in a package barrel has an explicit `show` clause |
| `max_file_loc_test.dart` | `lib/src/**/*.dart` files fail at 110% of the 1,500-line target (1,650 LOC) |
| `package_cycles_test.dart` | Zero cycles in the workspace package dependency graph |
| `constructor_param_count_test.dart` | No public constructor has more than 12 parameters |
| `no_cross_package_env_plan_duplicates_test.dart` | `ProcessEnvironmentPlan` implementations live only in `dartclaw_kernel` |
| `safe_process_usage_test.dart` | No raw `Process.run/start('git', ...)` in production code, and `SafeProcess.git` only from the canonical runner — two rules with one allowlist each |

Intentional exceptions are committed as plain-text allowlists under `dev/fitness/test/allowlist/<test-name>.txt`, one per *rule* rather than per file where a file carries more than one. Each allowlist entry requires a `  # rationale` comment — no silent waivers. See `dev/fitness/README.md` for per-test "How to resolve a failure" guidance.

A Level-2 suite in the same directory extends these checks with dependency-direction data, cross-package `src/` import hygiene, testing-package dependency shape, and enum/event consumer exhaustiveness. The workspace-wide per-file method-count gate was retired in 0.25 (`DECISIONS.md` § Still Current); `packages/dartclaw_workflow/test/fitness_test.dart` keeps a package-scoped one, tagged `fitness-shape` and run at release prep. The crash-recovery smoke lives under `packages/dartclaw_runtime/test/integration/` and is explicitly gated with `--run-skipped -t integration`.
