import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness, FakeProjectService;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';

void main() {
  test('reference suggestions offer only the chat current explicit project', () async {
    final root = Directory.systemTemp.createTempSync('general_project_references_');
    try {
      final owner = Directory(p.join(root.path, 'owner'))..createSync();
      final checkout = Directory(p.join(root.path, 'checkout'))..createSync();
      final sessions = SessionService(baseDir: root.path);
      final messages = MessageService(baseDir: root.path);
      final turns = FakeTurnManager(messages, FakeAgentHarness());
      final projects = FakeProjectService(
        localProject: Project(
          id: '_local',
          name: 'Local',
          remoteUrl: '',
          localPath: root.path,
          status: ProjectStatus.ready,
          createdAt: DateTime.utc(2026),
        ),
        projects: [
          Project(
            id: 'checkout',
            name: 'Checkout',
            remoteUrl: '',
            localPath: checkout.path,
            status: ProjectStatus.ready,
            createdAt: DateTime.utc(2026),
          ),
        ],
      );
      final handler = sessionRoutes(
        sessions,
        messages,
        turns,
        FakeAgentHarness(),
        projectService: projects,
        ownerWorkspaceDir: owner.path,
      ).call;

      Future<List<dynamic>> suggestions(String sessionId) async {
        final response = await handler(
          Request('GET', Uri.parse('http://localhost/api/sessions/$sessionId/references')),
        );
        expect(response.statusCode, 200);
        return (jsonDecode(await response.readAsString()) as Map<String, dynamic>)['references'] as List<dynamic>;
      }

      final general = await sessions.createSession();
      final generalRefs = await suggestions(general.id);
      expect(generalRefs.where((value) => (value as Map<String, dynamic>)['type'] == 'project'), isEmpty);

      final opened = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/open'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'project_id': 'checkout'}),
        ),
      );
      expect(opened.statusCode, 201);
      final projectId = (jsonDecode(await opened.readAsString()) as Map<String, dynamic>)['id'] as String;
      final projectRefs = await suggestions(projectId);
      expect(
        projectRefs.where((value) => (value as Map<String, dynamic>)['type'] == 'project').map((value) => value['id']),
        ['checkout'],
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}
