import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/api/emergency_stop_routes.dart';
import 'package:dartclaw_runtime/src/auth/request_auth_context.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' as testing;
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskRepository, TestEventBus;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryTaskRepository repo;
  late TaskService taskService;
  late TestEventBus eventBus;
  late Router router;

  final ts = DateTime.parse('2026-03-21T12:00:00Z');

  setUp(() {
    repo = InMemoryTaskRepository();
    eventBus = TestEventBus();
    taskService = TaskService(repo, eventBus: eventBus);
    router = Router();
    registerEmergencyStopRoutes(
      router,
      turnManagerGetter: () => testing.FakeTurnManager(),
      taskService: taskService,
      eventBus: eventBus,
      sseBroadcast: SseBroadcast(),
    );
  });

  tearDown(() async {
    await eventBus.dispose();
    await taskService.dispose();
  });

  Future<void> queueRunningTask(String id) async {
    await repo.insert(Task(id: id, title: 'Task $id', description: 'do work', createdAt: ts));
    await taskService.transition(id, TaskStatus.queued, now: ts, trigger: 'test');
    await taskService.transition(id, TaskStatus.running, now: ts, trigger: 'test');
  }

  Request stopRequest() => Request('POST', Uri.parse('http://localhost/api/emergency-stop'));

  test('an admin request cancels running work and records who stopped it', () async {
    await queueRunningTask('t1');

    final response = await router.call(withAdminAuthContext(stopRequest()));

    expect(response.statusCode, 200);
    expect(jsonDecode(await response.readAsString()), containsPair('tasksCancelled', 1));
    expect((await taskService.get('t1'))!.status, TaskStatus.cancelled);
    final stop = eventBus.firedEvents.whereType<EmergencyStopEvent>().single;
    expect(stop.stoppedBy, 'api token');
  });

  test('the caller recorded is the one the authentication proved, not one it claimed', () async {
    final response = await router.call(withCookieAuthContext(stopRequest()));

    expect(response.statusCode, 200);
    expect(eventBus.firedEvents.whereType<EmergencyStopEvent>().single.stoppedBy, 'web session');
  });

  test('a request with no admin access is refused and cancels nothing', () async {
    await queueRunningTask('t2');

    final response = await router.call(stopRequest());

    expect(response.statusCode, 403);
    expect((await taskService.get('t2'))!.status, TaskStatus.running);
    expect(eventBus.firedEvents.whereType<EmergencyStopEvent>(), isEmpty);
  });
}
