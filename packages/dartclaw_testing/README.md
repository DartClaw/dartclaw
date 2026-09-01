# dartclaw_testing

Shared test doubles for DartClaw packages.

`dartclaw_testing` centralizes the canonical fakes that were previously copied
across `dartclaw_core`, `dartclaw_kernel`, and `dartclaw_runtime` tests. The
package production-depends only on `dartclaw_kernel`, `dartclaw_core` and
`dartclaw_kernel`. A double for a port owned above `dartclaw_core` lives in
the package that owns the port, behind that package's `testing.dart` entry
point.

## Included doubles

- `FakeAgentHarness`
- `FakeChannel`
- `FakeGuard`
- `FakeProcess`
- `CapturingFakeProcess`
- `InMemorySessionService`
- `InMemoryTaskRepository`
- `TestEventBus`

## Example

```dart
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';

Future<void> main() async {
  final harness = FakeAgentHarness();
  final events = TestEventBus();

  final turnFuture = harness.turn(
    sessionId: 'session-1',
    messages: const [
      {'role': 'user', 'content': 'hello'},
    ],
    systemPrompt: 'You are a test harness.',
  );

  harness.completeSuccess(const {'ok': true});
  final result = await turnFuture;

  final eventFuture = events.expectEvent<TaskStatusChangedEvent>();
  events.fire(
    TaskStatusChangedEvent(
      taskId: 'task-1',
      oldStatus: TaskStatus.queued,
      newStatus: TaskStatus.running,
      trigger: 'example',
      timestamp: DateTime.now(),
    ),
  );

  await eventFuture;
  print(result);
}
```

See [example/dartclaw_testing_example.dart](example/dartclaw_testing_example.dart)
for a runnable example.

## License

MIT - see [LICENSE](LICENSE).
