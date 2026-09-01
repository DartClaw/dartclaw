import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/memory/memory_prune_service.dart';
import 'package:dartclaw_runtime/src/web/pages/memory_page.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late String workspaceDir;
  late KvService kvService;
  late MemoryStatusService statusService;
  late MemoryService memoryService;
  late SessionService sessions;
  late MessageService messages;
  late Database db;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_memory_page_test_');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(workspaceDir).createSync(recursive: true);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    db = sqlite3.open(p.join(tempDir.path, 'memory.db'));
    memoryService = MemoryService(db);
    statusService = MemoryStatusService(
      workspaceDir: workspaceDir,
      config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
      kvService: kvService,
    );
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
  });

  tearDown(() async {
    db.close();
    await kvService.dispose();
    tempDir.deleteSync(recursive: true);
  });

  Handler handlerWith(MemoryPruneService pruning) {
    final page = MemoryPage(memoryStatusServiceGetter: () => statusService, memoryPruneServiceGetter: () => pruning);
    return webRoutes(
      sessions,
      messages,
      pageRegistry: PageRegistry()..register(page),
      config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
      dataDir: tempDir.path,
    ).call;
  }

  Future<({int status, String body, Map<String, String> headers})> post(Handler handler) async {
    final response = await handler(Request('POST', Uri.parse('http://localhost/memory/prune')));
    return (status: response.statusCode, body: await response.readAsString(), headers: response.headers);
  }

  Map<String, dynamic> toast(Map<String, String> headers) {
    final trigger = jsonDecode(headers['hx-trigger-after-swap']!) as Map<String, dynamic>;
    return trigger['dc:toast'] as Map<String, dynamic>;
  }

  test('S01 confirmed prune returns the refreshed region, history row, and count toast', () async {
    File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('## general\n- [2025-01-01 10:00] Old entry\n');
    final pruner = MemoryPruner(workspaceDir: workspaceDir, memoryService: memoryService, archiveAfterDays: 90);
    final response = await post(handlerWith(MemoryPruneService(pruner: pruner, kvService: kvService)));

    expect(response.status, 200);
    expect(response.body, contains('id="memory-inner"'));
    final history = jsonDecode((await kvService.get('prune_history'))!) as List<dynamic>;
    final run = history.single as Map<String, dynamic>;
    expect(response.body, contains('title="${run['timestamp']}"'));
    expect(toast(response.headers), {
      'type': 'success',
      'message':
          'Archived ${run['entriesArchived']}; de-duplicated ${run['duplicatesRemoved']}; '
          '${run['entriesRemaining']} entries remain',
    });
  });

  test('S02 unavailable prune returns the unchanged region and an error toast', () async {
    final before = await statusService.getStatus();
    final response = await post(handlerWith(MemoryPruneService(kvService: kvService)));

    expect(response.status, 200);
    expect(response.body, contains('id="memory-inner"'));
    expect(toast(response.headers), {'type': 'error', 'message': 'Memory pruner not configured'});
    expect(await statusService.getStatus(), before);
    expect(await kvService.get('prune_history'), isNull);
  });

  test('the declared prune route is non-GET and owned by the memory page', () {
    expect(MemoryPage().declaredRoutes, [(method: 'POST', path: '/memory/prune')]);
  });

  test('an unauthenticated request is refused before pruning', () async {
    File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('## general\n- [2025-01-01 10:00] Old entry\n');
    final pruner = MemoryPruner(workspaceDir: workspaceDir, memoryService: memoryService, archiveAfterDays: 90);
    final token = 'a' * 64;
    final guarded = const Pipeline()
        .addMiddleware(
          authMiddleware(
            tokenService: TokenService(token: token),
            gatewayToken: token,
          ),
        )
        .addHandler(handlerWith(MemoryPruneService(pruner: pruner, kvService: kvService)));

    final response = await post(guarded);
    expect(response.status, 401);
    expect(await kvService.get('prune_history'), isNull);
  });

  test('a cross-origin local-admin request is refused before pruning', () async {
    File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('## general\n- [2025-01-01 10:00] Old entry\n');
    final pruner = MemoryPruner(workspaceDir: workspaceDir, memoryService: memoryService, archiveAfterDays: 90);
    final guarded = const Pipeline()
        .addMiddleware(localAdminMiddleware())
        .addMiddleware(originHostGuardMiddleware())
        .addHandler(handlerWith(MemoryPruneService(pruner: pruner, kvService: kvService)));

    final response = await guarded(
      Request(
        'POST',
        Uri.parse('http://localhost/memory/prune'),
        headers: {'host': 'localhost', 'origin': 'https://attacker.example'},
      ),
    );
    expect(response.statusCode, 403);
    expect(await kvService.get('prune_history'), isNull);
  });
}
