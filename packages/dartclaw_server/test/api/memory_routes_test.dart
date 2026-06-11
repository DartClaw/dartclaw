import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'api_test_helpers.dart';

void main() {
  late Directory tempDir;
  late String workspaceDir;
  late KvService kvService;
  late MemoryStatusService statusService;
  late ApiRouteTestClient client;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('memory_routes_test');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(workspaceDir).createSync(recursive: true);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));

    statusService = MemoryStatusService(
      workspaceDir: workspaceDir,
      config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
      kvService: kvService,
    );

    client = ApiRouteTestClient(memoryRoutes(statusService: statusService, workspaceDir: workspaceDir).call);
  });

  tearDown(() async {
    await kvService.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('GET /api/memory/status', () {
    test('returns 200 with valid JSON', () async {
      final body = await client.expectJsonObject('GET', '/api/memory/status');
      expect(body, containsPair('memoryMd', isA<Map<String, dynamic>>()));
      expect(body, containsPair('archiveMd', isA<Map<String, dynamic>>()));
      expect(body, containsPair('errorsMd', isA<Map<String, dynamic>>()));
      expect(body, containsPair('learningsMd', isA<Map<String, dynamic>>()));
      expect(body, containsPair('search', isA<Map<String, dynamic>>()));
      expect(body, containsPair('pruner', isA<Map<String, dynamic>>()));
      expect(body, containsPair('dailyLogs', isA<Map<String, dynamic>>()));
      expect(body, containsPair('config', isA<Map<String, dynamic>>()));
    });

    test('content-type is application/json', () async {
      final response = await client.expectResponse('GET', '/api/memory/status', status: 200);
      expect(response.headers['content-type'], contains('application/json'));
    });
  });

  group('GET /api/memory/files/<name>', () {
    test('returns MEMORY.md content', () async {
      File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('## general\n- [2026-01-01 10:00] Test\n');

      final response = await client.expectResponse('GET', '/api/memory/files/memory', status: 200);
      expect(response.headers['content-type'], 'text/plain; charset=utf-8');
      expect(await response.readAsString(), contains('## general'));
    });

    test('returns errors.md content', () async {
      File(p.join(workspaceDir, 'errors.md')).writeAsStringSync('## [2026-03-01] Error\n');

      expect(await client.expectText('GET', '/api/memory/files/errors'), contains('Error'));
    });

    test('returns learnings.md content', () async {
      File(p.join(workspaceDir, 'learnings.md')).writeAsStringSync('## [2026-03-01] Learning\n');

      await client.expectResponse('GET', '/api/memory/files/learnings', status: 200);
    });

    test('returns archive content', () async {
      File(p.join(workspaceDir, 'MEMORY.archive.md')).writeAsStringSync('archived stuff\n');

      expect(await client.expectText('GET', '/api/memory/files/archive'), contains('archived stuff'));
    });

    test('returns 404 for unknown file name', () async {
      final body = await client.expectJsonObject('GET', '/api/memory/files/unknown', status: 404);
      expect(body['error']['code'], 'NOT_FOUND');
    });

    test('returns 200 with empty body when file does not exist', () async {
      expect(await client.expectText('GET', '/api/memory/files/memory'), isEmpty);
    });
  });
}
