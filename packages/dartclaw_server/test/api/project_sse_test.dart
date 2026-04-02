import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/api/task_sse_routes.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Project _makeProject({required String id, String name = 'Test Project', ProjectStatus status = ProjectStatus.ready}) =>
    Project(
      id: id,
      name: name,
      remoteUrl: 'https://github.com/user/repo.git',
      localPath: '/tmp/$id',
      status: status,
      createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
    );

void main() {
  late Database db;
  late TaskService tasks;
  late EventBus eventBus;

  setUp(() {
    db = openTaskDbInMemory();
    tasks = TaskService(SqliteTaskRepository(db));
    eventBus = EventBus();
  });

  tearDown(() async {
    await eventBus.dispose();
    await tasks.dispose();
    db.close();
  });

  Map<String, dynamic> decodeFramePayload(String frame) {
    final dataLine = frame.trim().split('\n').first;
    expect(dataLine, startsWith('data: '));
    return jsonDecode(dataLine.substring('data: '.length)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> nextFramePayload(StreamIterator<String> iterator) async {
    final hasFrame = await iterator.moveNext().timeout(const Duration(seconds: 2));
    expect(hasFrame, isTrue);
    return decodeFramePayload(iterator.current);
  }

  test('ProjectStatusChangedEvent is forwarded as project_status SSE event', () async {
    final handler = taskSseRoutes(tasks, eventBus).call;
    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);

    // Consume connected frame.
    await nextFramePayload(iterator);

    // Fire a project status change event.
    eventBus.fire(
      ProjectStatusChangedEvent(
        projectId: 'my-project',
        oldStatus: ProjectStatus.cloning,
        newStatus: ProjectStatus.ready,
        timestamp: DateTime.now(),
      ),
    );

    final payload = await nextFramePayload(iterator);
    expect(payload['type'], 'project_status');
    expect(payload['projectId'], 'my-project');
    expect(payload['oldStatus'], 'cloning');
    expect(payload['newStatus'], 'ready');
  });

  test('project_status event with null oldStatus serializes null', () async {
    final handler = taskSseRoutes(tasks, eventBus).call;
    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);

    await nextFramePayload(iterator); // consume connected

    eventBus.fire(
      ProjectStatusChangedEvent(
        projectId: 'new-project',
        oldStatus: null,
        newStatus: ProjectStatus.cloning,
        timestamp: DateTime.now(),
      ),
    );

    final payload = await nextFramePayload(iterator);
    expect(payload['type'], 'project_status');
    expect(payload['projectId'], 'new-project');
    expect(payload['oldStatus'], isNull);
    expect(payload['newStatus'], 'cloning');
  });

  test('connected payload includes project summary when ProjectService is provided', () async {
    final localProject = _makeProject(id: '_local', name: 'Local');
    final extProject = _makeProject(id: 'ext-proj', name: 'Ext Project', status: ProjectStatus.cloning);
    final projectService = FakeProjectService(projects: [extProject], localProject: localProject);

    final handler = taskSseRoutes(tasks, eventBus, projects: projectService).call;
    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);

    final payload = await nextFramePayload(iterator);
    expect(payload['type'], 'connected');
    expect(payload['projects'], isA<List<dynamic>>());
    final projects = (payload['projects'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(projects, hasLength(2));
    expect(projects.any((p) => p['id'] == '_local'), isTrue);
    expect(projects.any((p) => p['id'] == 'ext-proj' && p['status'] == 'cloning'), isTrue);
  });

  test('connected payload has no projects key when ProjectService is null', () async {
    final handler = taskSseRoutes(tasks, eventBus).call;
    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);

    final payload = await nextFramePayload(iterator);
    expect(payload['type'], 'connected');
    expect(payload.containsKey('projects'), isFalse);
  });
}
