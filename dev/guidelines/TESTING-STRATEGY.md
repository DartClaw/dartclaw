# DartClaw Testing Strategy

> **Status**: Active
> **Current through**: 0.14.7
> **Scope**: All packages in the DartClaw pub workspace

---

## Philosophy

**Pragmatic and effective.** Tests exist to catch real bugs and prevent regressions, not to hit coverage targets. Every test should justify its existence by protecting against a plausible failure mode.

**Principles:**
- Test behavior, not implementation — assert on observable outcomes, not internal state
- A "unit" is a behavior, not a class — tests may involve multiple collaborating classes; the boundary is the public API, not the class boundary
- The right test at the right layer — prefer the cheapest test that covers the risk
- Sociable by default — let real collaborators participate; reserve test doubles for external boundaries (network, harness, channels, third-party APIs)
- Security-critical code gets exhaustive coverage; plumbing code gets smoke coverage
- False-positive tests (verifying we *don't* block legitimate input) are as valuable as true-positive tests
- No real-time waits in tests — use `fake_async` for timer logic, `Duration.zero` delays only for microtask yields
- Test gates must encode their infrastructure assumptions — if a suite binds ports, starts processes, or relies on filesystem/static-asset fixtures, run it with explicit serialization or isolate those resources per test
- Tests are production code — same lint rules, same review standards

**Calibration** (Fowler): The sign of too little testing is that you cannot confidently change your code. The sign of too much is that you spend more time changing your tests than your production code.

**Behavioral boundary rule** (Khorikov): Intra-system communications (domain classes calling each other) are implementation details — do not verify with mocks. Inter-system communications (calls to external systems like channels, harness binaries, third-party APIs) are part of observable behavior — fakes and assertions on those interactions are appropriate.

---

## Test Layers

DartClaw uses a four-layer test model. The primary boundary between layers is **whether infrastructure setup is required** — not how many classes participate. A test involving five collaborating classes through a public API with no I/O is a unit test. A test of a single service that needs a temp directory is an integration test.

### Layer 1 — Unit Tests (~60% of test count)

**What**: Behavioral tests through public APIs. No file I/O, no network, no subprocesses, no database. May involve a single function or multiple collaborating classes — the distinguishing factor is zero infrastructure, not class count.

**Targets**: Parsers, validators, models, config readers, pattern matchers, guard evaluators, guard chains (with test doubles for individual guards), state machines, utility functions, multi-class domain logic.

**Sociable tests are welcome here.** When a behavior involves multiple classes working together (e.g., `GuardChain` + `Guard` implementations, `ReviewCommandParser` + value objects), test them together through the entry-point's public API. Only introduce test doubles when a collaborator crosses an external boundary or is genuinely impractical to construct.

**Characteristics**:
- Run in microseconds
- Zero or minimal `setUp`/`tearDown` overhead
- Assertions on return values, observable state changes, or interactions with external boundaries
- Use constructor injection for any dependency
- Parallel-safe by default; if a test cannot run alongside other package tests, it is not Layer 1

**When to write**: Always, for any component that has branching logic or transforms data.

**When to skip**: Trivial delegating methods with zero branching. Generated boilerplate. Private helpers whose behavior is fully covered by public API tests.

```dart
group('SessionKey', () {
  test('dmShared derives stable key from channel and peer', () {
    final key = SessionKey.dmShared(channel: 'whatsapp', peerId: '+1234');
    expect(key.scope, 'dm');
    expect(key.value, contains('whatsapp'));
  });
});
```

### Layer 2 — Integration Tests (~30% of test count)

**What**: Behavioral tests that need infrastructure — temp directories, in-memory SQLite, or fakes for external boundaries (harness, channels, third-party APIs). May involve one service or several wired together.

**Targets**: Services with file-based or SQLite storage, multi-service interactions, EventBus subscriber chains, channel message routing, task lifecycle flows.

**Characteristics**:
- Temp directories for file-based storage (`Directory.systemTemp.createTempSync`)
- In-memory SQLite (`sqlite3.openInMemory()`) for search/task tests
- Shared fakes from `dartclaw_testing` for external boundaries (harness, channels, processes)
- Per-test isolation — `setUp` creates fresh state, `tearDown` cleans up
- May require serialized execution when testing real local resources such as TCP ports, process wiring, current working directory behavior, or static-asset filesystem lookup. Prefer random ports and per-test temp directories; when that is not practical, the command must use `-j 1` and the reason must be documented.

**When to write**: For any behavior that requires storage, persistence, or interaction with an external boundary that must be faked.

**When to skip**: When the service is a thin wrapper that delegates entirely to a tested component.

```dart
late Directory tempDir;
late TaskService taskService;

setUp(() {
  tempDir = Directory.systemTemp.createTempSync('task_test_');
  final db = sqlite3.openInMemory();
  taskService = TaskService(repository: SqliteTaskRepository(db));
});

tearDown(() => tempDir.deleteSync(recursive: true));

test('task transitions from queued to running', () async {
  final task = await taskService.create(description: 'build login');
  await taskService.updateStatus(task.id, TaskStatus.running);
  expect((await taskService.get(task.id))!.status, TaskStatus.running);
});
```

### Layer 3 — API/Handler Tests (~8% of test count)

**What**: Real shelf handlers invoked directly via `handler(Request(...))` — no TCP, no bind. Server wired with real storage and fakes for external boundaries.

**Targets**: HTTP route handlers, auth middleware, response shapes, error codes, content negotiation (JSON vs HTML fragment), SSE stream structure.

**Characteristics**:
- Construct the handler or server in `setUp`, invoke with `shelf.Request`
- Assert on status codes, response bodies (JSON decode or HTML contains), headers
- Test both authenticated and unauthenticated paths
- No real network — fast and deterministic

**When to write**: For every API endpoint that external consumers (web UI, CLI, channels) depend on. For auth middleware. For any response that has conditional structure (fragment vs full page, JSON error envelope).

**When to skip**: Endpoints that are trivial pass-through to a tested service with no transformation.

```dart
test('GET /api/tasks returns task list', () async {
  await taskService.create(description: 'test task');
  final response = await handler(
    Request('GET', Uri.parse('http://localhost/api/tasks'),
      headers: {'Authorization': 'Bearer $token'}),
  );
  expect(response.statusCode, 200);
  final body = jsonDecode(await response.readAsString()) as List;
  expect(body, hasLength(1));
  expect(body.first['description'], 'test task');
});
```

### Layer 4 — Live Integration & E2E Tests (<2% of test count)

**What**: Tests that require real external systems, real binaries, or the fully assembled runtime wiring.

**Characteristics**:
- Tagged with `@Tags(['integration'])` — skipped by default in `dart_test.yaml`
- Run explicitly: `dart test -t integration`
- Long timeouts (`Timeout(Duration(seconds: 60))`)
- Require environment setup (API keys, binaries, hardware)

**When to write**: For protocol-level verification (JSONL round-trip with real binary), channel E2E pairing flows, deployment smoke tests, and server-builder wiring that must exercise the real package composition.

**When to skip**: Almost always — prefer Layer 2 integration tests with `FakeAgentHarness` / `FakeProcess`. Only write Layer 4 tests when the real binary's behavior cannot be faithfully simulated.

```dart
@Tags(['integration'])
test('real harness completes a turn', () async {
  await harness.start();
  final result = await harness.turn(
    sessionId: 'test',
    messages: [{'role': 'user', 'content': 'Reply with: OK'}],
  );
  expect(result['stop_reason'], isNotNull);
}, timeout: Timeout(Duration(seconds: 60)));
```

The CLI E2E coverage now includes [`apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart`](../../../dartclaw-public/apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart), which boots the real `ServiceWiring`, uses `FakeAgentHarness` plus in-memory SQLite, and verifies that the assembled server serves `/` and `/health`.

```dart
@Tags(['integration'])
test('ServiceWiring builds a server that serves / and /health', () async {
  final result = await wiring.wire();

  final rootResponse = await result.server.handler(Request('GET', Uri.parse('http://localhost/')));
  expect(rootResponse.statusCode, equals(302));

  final healthResponse = await result.server.handler(Request('GET', Uri.parse('http://localhost/health')));
  expect(healthResponse.statusCode, equals(200));
});
```

### Integration test model selection

The workflow integration tier (`packages/dartclaw_workflow` Layer 4 suite, gated by `dart test -t integration`) runs against a default provider + per-role model preset baked into `E2EFixture`. Five environment variables let you swap that preset at run time without editing fixtures or test files:

| Variable | Effect |
|---|---|
| `DARTCLAW_TEST_PROVIDER` | `codex` (default) or `claude`. Selects the preset for the four role models, the provider's executable, and the sandbox / `permissionMode` setting. |
| `DARTCLAW_TEST_WORKFLOW_MODEL` | Overrides the `workflow` role model. |
| `DARTCLAW_TEST_PLANNER_MODEL` | Overrides the `planner` role model. |
| `DARTCLAW_TEST_EXECUTOR_MODEL` | Overrides the `executor` role model. |
| `DARTCLAW_TEST_REVIEWER_MODEL` | Overrides the `reviewer` role model. |

**Precedence**: explicit `E2EFixture(...)` constructor arg wins over env var, env var wins over preset default. Empty-string env vars are treated as unset.

**Provider presets**:

| Preset | Workflow / Planner | Executor / Reviewer | Sandbox | API key env var |
|---|---|---|---|---|
| `codex` (default) | `gpt-5.4` | `gpt-5.3-codex-spark` | `danger-full-access` | `CODEX_API_KEY` |
| `claude` | `claude-opus-4-7` | `claude-sonnet-4-6` | `bypassPermissions` | `ANTHROPIC_API_KEY` |

**Run the integration tier against Claude**:

```bash
DARTCLAW_TEST_PROVIDER=claude ANTHROPIC_API_KEY=... \
  dart test packages/dartclaw_workflow -t integration
```

Mix-and-match works too — e.g. keep the codex provider but force a faster executor for a quick local sweep:

```bash
DARTCLAW_TEST_EXECUTOR_MODEL=gpt-5.3-codex-spark \
  dart test packages/dartclaw_workflow -t integration
```

### Visual / UI Smoke Tests (Manual)

**What**: Browser-based visual validation of the HTMX web UI. Manual or agent-driven via `chrome-devtools` MCP / `agent-browser`.

**Targets**: Page layout, navigation, real-time updates (SSE), responsive behavior, error states.

**Characteristics**:
- Defined in [`dev/testing/UI-SMOKE-TEST.md`](../../../dartclaw-public/dev/testing/UI-SMOKE-TEST.md) (18+ numbered test cases)
- Run against a testing profile (`plain` or `channels`)
- Not part of the `dart test` suite — triggered manually or via visual validation workflow

**When to run**: Before releases, after UI changes, after template/CSS modifications.

**Note**: Template rendering correctness (HTML structure, XSS escaping) is tested at Layer 2/3 via string assertions on rendered output. Browser tests cover layout and interactivity that string assertions cannot verify.

**Future automation**: A strategy for automating 13 of 24 smoke TCs as Dart `puppeteer` browser E2E tests (tagged `@Tags(['e2e'])`) is documented in [`docs/research/e2e-test-strategy/research.md`](../research/e2e-test-strategy/research.md). This would add a Layer 4 sub-tier for browser automation without introducing Node.js. Tracked in the [product backlog](../PRODUCT-BACKLOG.md#automated-browser-e2e-tests).

---

## What Must Always Be Tested

These categories get comprehensive test coverage — no exceptions.

### Security-Critical Components
- **Guard implementations** — every pattern with both blocking (true positive) AND non-blocking (false positive) cases
- **Input sanitizer** — injection patterns, encoding bypass attempts, legitimate input that must pass
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

All shared fakes live in `packages/dartclaw_testing/`. This is the canonical source — **never redeclare fakes locally in test files**.

**Boundary rule for fakes**: Fakes should replace *external boundaries* — systems that are slow, non-deterministic, or outside the process (harness binaries, channel networks, third-party REST APIs, subprocesses). Do not create fakes for internal collaborators that can participate as real objects. Each fake is a maintenance surface that can drift from the real implementation it replaces.

| Fake / helper | Purpose | Key features |
|---------------|---------|-------------|
| `FakeAgentHarness` | Agent turn simulation | Controllable completions, event emission, call tracking |
| `FakeChannel` | Channel message routing | Configurable JID ownership, sent message recording |
| `FakeGuard` | Guard pipeline testing | Configurable verdicts, dynamic evaluators |
| `FakeProcess` | Subprocess simulation | Stream-backed stdout/stderr, kill tracking |
| `CapturingFakeProcess` | Subprocess I/O assertions | Captures stdin lines and decoded JSON maps |
| `FakeCodexProcess` | Codex/Claude harness protocol tests | JSON-RPC helpers and outbound message capture |
| `FakeGoogleChatRestClient` | Google Chat REST boundary | Configurable responses and request recording |
| `FakeGoogleJwtVerifier` | Google Chat auth boundary | Deterministic accept/reject verification |
| `FakeProjectService` | Project CRUD flows | Callback-driven state and freshness checks |
| `FakeTurnManager` | Turn lifecycle control | Reserve/execute/cancel hooks and configurable outcomes |
| `NullIoSink` | Discard-all IOSink for subprocess tests | No-op `write`, `add`, `close` — silences stdout/stderr |
| `InMemorySessionService` | Session storage without filesystem | Full API mirror, zero I/O |
| `InMemoryTaskRepository` | Task storage without SQLite | Full CRUD, in-memory |
| `RecordingMessageQueue` | Queue routing assertions | Enqueued-message recording, optional forwarding |
| `RecordingReviewHandler` | Review flow assertions | Captures review calls and comments |
| `TaskOps` | Channel/task test scaffolding | Shared create/transition/update helpers |
| `TestEventBus` | Event bus with recording | Event capture, subscription verification |

**Rule**: When you need a test double, check `dartclaw_testing` first. If a suitable fake doesn't exist, add it there — not in the test file.

**Fake drift audit** (at each milestone): For each fake in `dartclaw_testing`, verify it still faithfully represents the interface it replaces. Look for methods added to the real interface but missing from the fake, or behavioral assumptions in the fake that no longer match reality. Fakes that drift from their real counterparts produce false confidence — tests pass while production breaks.

Related helpers such as `channelOriginJson`, `createTask`, `flushAsync`, `latestRequestId`, `noOpDelay`, `pumpEventLoop`, `putTaskInReview`, `respondToLatestThreadStart`, `shortTaskId`, `startHarness`, and `waitForSentMessage` are also exported from `dartclaw_testing` for reuse.

### Test Configuration

**`dart_test.yaml`** (workspace root):
```yaml
tags:
  contract:
  integration:
    skip: "Requires live API credentials — run explicitly with: dart test -t integration"
```

**Tag usage**:
- `@Tags(['integration'])` — live binary / network tests (skipped by default)
- `@Tags(['contract'])` — shared interface compliance tests; selector only, not skipped by default. The repo currently uses shared contract helpers such as `searchBackendContractTests`, even when the tag itself is not applied.
- No tag needed for unit and integration tests (the default)

Package-level `dart_test.yaml` files mirror the workspace defaults where a package or app has its own integration-tagged tests, so the default skip text stays accurate when those packages are run in isolation.

### Testing Profiles (Pre-configured Environments)

| Profile | Command | Purpose |
|---------|---------|---------|
| `plain` | `bash dev/testing/plain/run.sh` | No channels, guards on, seeded data |
| `channels` | `bash dev/testing/channels/run.sh` | WhatsApp + Signal enabled |

Both serve on port 3333. Use `--port <N>` to override.

---

## Async Testing Patterns

### Timer-based logic: Use `fake_async`

```dart
import 'package:fake_async/fake_async.dart';

test('rate limiter resets after window', () {
  fakeAsync((fake) {
    final limiter = SlidingWindowRateLimiter(max: 5, window: Duration(minutes: 1));
    for (var i = 0; i < 5; i++) limiter.record('sender1');
    expect(limiter.isLimited('sender1'), isTrue);

    fake.elapse(Duration(minutes: 1));
    expect(limiter.isLimited('sender1'), isFalse);
  });
});
```

**Important**: `fakeAsync` callbacks must be synchronous. Use `fake.flushMicrotasks()` and `fake.flushTimers()` for async-like control flow inside the callback.

### Stream assertions: Use `StreamQueue`

```dart
import 'package:async/async.dart';

test('event bus delivers typed events in order', () async {
  final queue = StreamQueue(eventBus.on<TaskStatusChangedEvent>());
  eventBus.fire(TaskStatusChangedEvent(taskId: '1', status: TaskStatus.running));
  eventBus.fire(TaskStatusChangedEvent(taskId: '1', status: TaskStatus.review));

  final first = await queue.next;
  expect(first.status, TaskStatus.running);
  final second = await queue.next;
  expect(second.status, TaskStatus.review);
  await queue.cancel();
});
```

### Microtask yields

When testing broadcast streams or EventBus, use `await Future<void>.delayed(Duration.zero)` to yield exactly once to the event loop. Never use real-time delays (`Duration(milliseconds: 100)`) in tests.

### Async loop safety

Never use `(_) async {}` delay patterns in production loops being tested. This causes microtask starvation and multi-GB memory leaks. Production loops must yield to the timer queue (`Timer`, `Future.delayed` with non-zero duration, or structured async patterns).

---

## Test Design Reference: Beck's Test Desiderata

When deciding *how* to test something, these 12 properties (Kent Beck, 2019) serve as trade-off sliders — no single test maximizes all of them:

| Property | What it means | DartClaw emphasis |
|----------|---------------|-------------------|
| **Behavioral** | Sensitive to behavior changes | Primary — this is our core principle |
| **Structure-insensitive** | Unchanged when code structure changes | Primary — tests should survive refactoring |
| **Fast** | Sub-second execution | Layers 1-3 must be fast |
| **Isolated** | Same results regardless of execution order | All layers — per-test `setUp`/`tearDown` |
| **Deterministic** | No flakiness | All layers — no real-time, no network |
| **Specific** | Failure cause is obvious | Prefer one behavior per test |
| **Predictive** | Passing means production-ready | Stronger at Layer 2-4, weaker at Layer 1 |
| **Readable** | Comprehensible for the reader | Name tests after the behavior, not the method |
| **Writable** | Cheap to write relative to code cost | If setup is expensive, fix the design |
| **Inspiring** | Passing tests inspire confidence | Comes from testing real behavior, not mocks |
| **Composable** | Suite confidence > individual test confidence | Contract tests, overlapping coverage chains |
| **Automated** | No human intervention | Layers 1-4; visual tests are the exception |

**Key trade-off**: Unit tests sacrifice *Predictive* (they don't prove the whole system works) for *Fast*, *Specific*, and *Writable*. Integration tests sacrifice *Speed* for *Predictive*. Accept these trade-offs consciously.

For the full framework, see [research: behavior-focused testing](../research/behavior-focused-testing/research.md).

---

## Running Tests

### Per-Package (Primary)

```bash
# Run all tests for a package
dart test packages/dartclaw_core
dart test packages/dartclaw_server
dart test packages/dartclaw_security

# Run a specific test file
dart test packages/dartclaw_server/test/api/task_routes_test.dart

# Run tests matching a name pattern
dart test packages/dartclaw_core --name "SessionKey"

# Run only contract tests
dart test -t contract packages/dartclaw_storage
```

### Mixed Local Integration Gates

Some package combinations include Layer 2/3 tests that exercise real local resources, especially CLI/server tests that bind ports, start service wiring, or probe filesystem/static-asset layout. Those suites are valid, but they are not guaranteed to be cross-package parallel-safe. Run them either as separate package commands or as a serialized aggregate:

```bash
dart test -j 1 --reporter=failures-only \
  packages/dartclaw_workflow packages/dartclaw_server apps/dartclaw_cli
```

Do not write FIS or release gates that rely on the default package-parallel aggregate form for this package set. If a new test needs a fixed port, global process state, cwd-sensitive lookup, or shared filesystem fixture, call that out in the test or guideline update and prefer random ports / per-test temp roots where possible.

### All Packages

```bash
# Quick: test all packages sequentially
for pkg in packages/dartclaw_models packages/dartclaw_core packages/dartclaw_config \
  packages/dartclaw_security packages/dartclaw_storage packages/dartclaw_whatsapp \
  packages/dartclaw_signal packages/dartclaw_google_chat packages/dartclaw_server \
  packages/dartclaw_testing packages/dartclaw apps/dartclaw_cli; do
  echo "=== $pkg ===" && dart test "$pkg" || exit 1
done
```

### Live Integration Tests

```bash
# Requires real claude binary + API credentials
dart test -t integration packages/dartclaw_core
```

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
3. **Does it persist data?** (storage, config, thread bindings) → Layer 2 with temp dirs or in-memory SQLite
4. **Does it expose an API?** (HTTP routes, slash commands, config API) → Layer 3 handler tests
5. **Does it interact with external systems?** (channels, claude binary, Google Chat API) → Layer 2 with fakes for external boundaries, Layer 4 only if fake coverage is insufficient
6. **Is it pure logic or multi-class domain behavior?** (parsing, validation, rate calculation, guard chain orchestration) → Layer 1, letting real collaborators participate where practical

Each FIS should specify which layers are needed and why, referencing this strategy.

### Coverage Expectations by Package

| Package | Target | Rationale |
|---------|--------|-----------|
| `dartclaw_security` | 85%+ | Security-critical — comprehensive coverage is non-negotiable |
| `dartclaw_core` | 80%+ | Foundation — bridges, events, config, session management |
| `dartclaw_models` | 70%+ | Pure data classes — test serialization, factories, edge cases |
| `dartclaw_config` | 80%+ | Config parsing errors cascade everywhere |
| `dartclaw_storage` | 80%+ | Data integrity — crash recovery, cursor behavior |
| `dartclaw_server` | 70%+ | Largest package; many lines are template rendering |
| Channel packages | 75%+ | Message routing, webhook parsing, access control |
| `dartclaw_testing` | 60%+ | Test infrastructure — lower bar acceptable |
| `dartclaw_cli` | 60%+ | CLI wiring; core logic tested via server package |

These are guidance targets, not enforcement gates. A package at 65% with well-chosen tests is better than 90% with brittle ones.

---

## Anti-Patterns

- **Real-time waits** — `await Future.delayed(Duration(milliseconds: 200))` in tests. Use `fake_async` or `Duration.zero` microtask yield.
- **Local fake redeclaration** — Copying `FakeAgentHarness` into a test file instead of importing from `dartclaw_testing`. Causes drift.
- **Testing implementation details** — Asserting on private field values, internal call sequences between domain classes, or the specific way a result was computed. Test what the system *produces*, not *how* it produces it. Note: asserting on interactions with *external boundaries* (e.g., verifying a message was sent to a channel, or that the correct review action was dispatched) is testing observable behavior, not implementation — that is appropriate.
- **Mocking internal collaborators** — Replacing domain classes with mocks to test another domain class in isolation. Let real collaborators participate. Only use fakes at external boundaries. If constructing a collaborator is painful, that's design feedback — fix the design, not the test.
- **One test per class** — Writing a test file for every class is a structural mirror, not a behavioral strategy. The trigger for a new test is implementing a new behavior, not creating a new class.
- **Catch-all exception tests** — `expect(() => ..., throwsException)`. Always assert on the specific exception type.
- **Shared mutable state across tests** — Using `setUpAll` with mutable state. Each test gets its own `setUp`.
- **Ignoring tearDown** — Temp directories and database connections must be cleaned up. Leaked resources cause flaky CI.
- **100% coverage chasing** — Writing tests for trivial getters or delegation methods. Focus on risk.
- **Mock returning a mock** — If a test double returns another test double, the test is likely testing nothing real. Step back and reconsider whether you are testing at the right level of abstraction.
