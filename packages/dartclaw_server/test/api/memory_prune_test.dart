import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String workspaceDir;
  late KvService kvService;
  late MemoryStatusService statusService;
  late MemoryService memoryService;
  late Database db;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('memory_prune_test');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(workspaceDir).createSync(recursive: true);

    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    db = sqlite3.open(p.join(tempDir.path, 'memory.db'));
    memoryService = MemoryService(db);

    statusService = MemoryStatusService(
      workspaceDir: workspaceDir,
      config: DartclawConfig(dataDir: tempDir.path),
      kvService: kvService,
    );
  });

  tearDown(() async {
    db.close();
    await kvService.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('POST /api/memory/prune', () {
    test('returns 503 when pruner not configured', () async {
      final router = memoryRoutes(
        statusService: statusService,
        workspaceDir: workspaceDir,
        // No pruner — not configured
      );

      final response = await router.call(
        Request('POST', Uri.parse('http://localhost/api/memory/prune')),
      );

      expect(response.statusCode, 503);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error']['code'], 'UNAVAILABLE');
    });

    test('returns 200 with result when pruner is configured', () async {
      // Write a MEMORY.md with entries
      File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync(
        '## general\n- [2026-03-01 10:00] Test entry\n',
      );

      final pruner = MemoryPruner(
        workspaceDir: workspaceDir,
        memoryService: memoryService,
        archiveAfterDays: 90,
      );

      final router = memoryRoutes(
        statusService: statusService,
        workspaceDir: workspaceDir,
        pruner: pruner,
        kvService: kvService,
      );

      final response = await router.call(
        Request('POST', Uri.parse('http://localhost/api/memory/prune')),
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body, containsPair('entriesArchived', isA<int>()));
      expect(body, containsPair('duplicatesRemoved', isA<int>()));
      expect(body, containsPair('entriesRemaining', isA<int>()));
      expect(body, containsPair('finalSizeBytes', isA<int>()));
    });

    test('persists result to KV prune_history', () async {
      File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync(
        '## general\n- [2026-03-01 10:00] Entry one\n',
      );

      final pruner = MemoryPruner(
        workspaceDir: workspaceDir,
        memoryService: memoryService,
        archiveAfterDays: 90,
      );

      final router = memoryRoutes(
        statusService: statusService,
        workspaceDir: workspaceDir,
        pruner: pruner,
        kvService: kvService,
      );

      await router.call(
        Request('POST', Uri.parse('http://localhost/api/memory/prune')),
      );

      final raw = await kvService.get('prune_history');
      expect(raw, isNotNull);
      final history = jsonDecode(raw!) as List;
      expect(history, hasLength(1));
      expect(history.first, containsPair('timestamp', isA<String>()));
      expect(history.first, containsPair('entriesArchived', isA<int>()));
    });

    test('history trimmed to 10 entries', () async {
      // Pre-populate with 10 existing entries
      final existing = List.generate(10, (i) => {
        'timestamp': '2026-01-${(i + 1).toString().padLeft(2, '0')}T00:00:00.000Z',
        'entriesArchived': 0,
        'duplicatesRemoved': 0,
        'entriesRemaining': 5,
        'finalSizeBytes': 100,
      });
      await kvService.set('prune_history', jsonEncode(existing));

      File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync(
        '## general\n- [2026-03-01 10:00] Entry\n',
      );

      final pruner = MemoryPruner(
        workspaceDir: workspaceDir,
        memoryService: memoryService,
        archiveAfterDays: 90,
      );

      final router = memoryRoutes(
        statusService: statusService,
        workspaceDir: workspaceDir,
        pruner: pruner,
        kvService: kvService,
      );

      await router.call(
        Request('POST', Uri.parse('http://localhost/api/memory/prune')),
      );

      final raw = await kvService.get('prune_history');
      final history = jsonDecode(raw!) as List;
      expect(history, hasLength(10)); // Still 10, not 11
      // Latest entry should be last
      expect(history.last['timestamp'], startsWith('2026-03'));
    });

    test('returns 200 with zeros for empty MEMORY.md', () async {
      // No MEMORY.md file — pruner returns empty result
      final pruner = MemoryPruner(
        workspaceDir: workspaceDir,
        memoryService: memoryService,
        archiveAfterDays: 90,
      );

      final router = memoryRoutes(
        statusService: statusService,
        workspaceDir: workspaceDir,
        pruner: pruner,
        kvService: kvService,
      );

      final response = await router.call(
        Request('POST', Uri.parse('http://localhost/api/memory/prune')),
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['entriesArchived'], 0);
      expect(body['duplicatesRemoved'], 0);
      expect(body['entriesRemaining'], 0);
    });
  });
}
