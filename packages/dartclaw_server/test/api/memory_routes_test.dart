import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String workspaceDir;
  late KvService kvService;
  late MemoryStatusService statusService;
  late Handler handler;

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

    final router = memoryRoutes(statusService: statusService, workspaceDir: workspaceDir);
    handler = router.call;
  });

  tearDown(() async {
    await kvService.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('GET /api/memory/status', () {
    test('returns 200 with valid JSON', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/memory/status')));
      expect(response.statusCode, 200);

      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
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
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/memory/status')));
      expect(response.headers['content-type'], contains('application/json'));
    });
  });

  group('GET /api/memory/files/<name>', () {
    test('returns MEMORY.md content', () async {
      File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('## general\n- [2026-01-01 10:00] Test\n');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/memory/files/memory')));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'text/plain; charset=utf-8');
      final body = await response.readAsString();
      expect(body, contains('## general'));
    });

    test('returns errors.md content', () async {
      File(p.join(workspaceDir, 'errors.md')).writeAsStringSync('## [2026-03-01] Error\n');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/memory/files/errors')));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), contains('Error'));
    });

    test('returns learnings.md content', () async {
      File(p.join(workspaceDir, 'learnings.md')).writeAsStringSync('## [2026-03-01] Learning\n');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/memory/files/learnings')));
      expect(response.statusCode, 200);
    });

    test('returns archive content', () async {
      File(p.join(workspaceDir, 'MEMORY.archive.md')).writeAsStringSync('archived stuff\n');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/memory/files/archive')));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), contains('archived stuff'));
    });

    test('returns 404 for unknown file name', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/memory/files/unknown')));
      expect(response.statusCode, 404);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error']['code'], 'NOT_FOUND');
    });

    test('returns 200 with empty body when file does not exist', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/memory/files/memory')));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), isEmpty);
    });
  });
}
