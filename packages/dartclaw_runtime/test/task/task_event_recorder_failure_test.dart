import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/task/task_event_recorder.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show openPreparedTaskBackend;
import 'package:test/test.dart';

void main() {
  test('failed insert surfaces and does not fire a bus event', () async {
    final backend = await openPreparedTaskBackend();
    final bus = EventBus();
    final fired = <TaskEventCreatedEvent>[];
    final subscription = bus.on<TaskEventCreatedEvent>().listen(fired.add);
    final recorder = TaskEventRecorder(eventService: TaskEventService(backend), eventBus: bus);
    await backend.close();

    await expectLater(recorder.recordError('task-1', message: 'write failed'), throwsStateError);
    await Future<void>.delayed(Duration.zero);

    expect(fired, isEmpty);
    await subscription.cancel();
    await bus.dispose();
  });
}
