import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/memory/memory_prune_service.dart';
import 'package:dartclaw_runtime/src/memory/memory_admin_service.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_runtime/src/web/pages/memory_page.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show InMemoryFullTextIndex, openPreparedTaskBackend, seedCanonicalMemory;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../test_utils.dart';
import '../../helpers/search_index_test_support.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late String workspaceDir;
  late KvService kvService;
  late MemoryStatusService statusService;
  late FullTextIndex memoryIndex;
  late SessionService sessions;
  late MessageService messages;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_memory_page_test_');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(workspaceDir).createSync(recursive: true);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    memoryIndex = await prepareMemoryIndex();
    statusService = MemoryStatusService(
      workspaceDir: workspaceDir,
      config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
      kvService: kvService,
    );
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
  });

  tearDown(() async {
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
    final trigger = jsonDecode(headers['hx-trigger']!) as Map<String, dynamic>;
    return trigger['dc:toast'] as Map<String, dynamic>;
  }

  test('S01 confirmed prune returns the refreshed region, history row, and count toast', () async {
    File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('## general\n- [2025-01-01 10:00] Old entry\n');
    final pruner = MemoryPruner(workspaceDir: workspaceDir, memoryIndex: memoryIndex, archiveAfterDays: 90);
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
    expect(MemoryPage().declaredRoutes, [
      (method: 'POST', path: '/memory/prune'),
      (method: 'POST', path: '/memory/edit'),
      (method: 'POST', path: '/memory/remove'),
    ]);
  });

  test('an unauthenticated request is refused before pruning', () async {
    File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('## general\n- [2025-01-01 10:00] Old entry\n');
    final pruner = MemoryPruner(workspaceDir: workspaceDir, memoryIndex: memoryIndex, archiveAfterDays: 90);
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
    final pruner = MemoryPruner(workspaceDir: workspaceDir, memoryIndex: memoryIndex, archiveAfterDays: 90);
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

  test('selected page renders one corpus and revision-checked edits recover from stale views', () async {
    final agent = AgentWorkspace.managed(agentId: 'a', dataDir: tempDir.path, ownerWorkspaceDir: workspaceDir);
    await WorkspaceService(dataDir: tempDir.path).prepareManagedAgents([agent]);
    await seedCanonicalMemory(
      workspaceDir,
      topics: const {
        'general': ['owner private marker'],
      },
    );
    await seedCanonicalMemory(
      agent.directory,
      topics: const {
        'general': ['agent A private marker'],
      },
    );
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      agent: AgentConfig(
        definitions: [
          AgentDefinition(
            id: 'a',
            description: 'A',
            prompt: '',
            allowedTools: const {'memory_apply', 'memory_search', 'memory_read', 'memory_observe'},
            workspace: agent,
          ),
        ],
      ),
    );
    final indices = <PostgresFtsTable, InMemoryFullTextIndex>{};
    final storage = StorageWiring(
      config: config,
      eventBus: EventBus(),
      taskBackendFactory: (_) async => openPreparedTaskBackend(),
      taskBackendIsPrepared: true,
      searchIndexFactory: (_, table, {required withinTransaction}) =>
          indices.putIfAbsent(table, InMemoryFullTextIndex.new),
      exitFn: (code) => throw StateError('unexpected exit $code'),
    );
    await storage.wire();
    try {
      final admin = MemoryAdminService(storage: storage);
      final page = MemoryPage(memoryStatusServiceGetter: () => statusService, memoryAdminServiceGetter: () => admin);
      final handler = webRoutes(
        sessions,
        messages,
        pageRegistry: PageRegistry()..register(page),
        config: config,
        dataDir: tempDir.path,
      ).call;
      final inventory = await admin.inventory();
      final corpus = (inventory['corpora'] as List).cast<Map<String, dynamic>>();
      final selector = corpus.singleWhere((item) => item['label'] == 'a')['selector'] as String;
      final selected = await handler(Request('GET', Uri.parse('http://localhost/memory?corpus=$selector')));
      final selectedHtml = await selected.readAsString();
      expect(selected.statusCode, 200);
      expect(selectedHtml, contains('agent A private marker'));
      expect(selectedHtml, isNot(contains('owner private marker')));
      expect(selectedHtml, isNot(contains('id="memory-files-card"')));

      final forged = await handler(Request('GET', Uri.parse('http://localhost/memory?corpus=agent:a')));
      expect(forged.statusCode, 200);
      final forgedHtml = await forged.readAsString();
      expect(forgedHtml, contains('The selected corpus is unavailable'));
      expect(forgedHtml, isNot(contains('owner private marker')));

      final listing = await admin.list(selector: selector);
      final entry = (listing['entries'] as List).single as Map<String, dynamic>;
      final entryId = entry['id'] as String;
      final detail = await handler(
        Request('GET', Uri.parse('http://localhost/memory?corpus=$selector&entry=$entryId')),
      );
      final detailHtml = await detail.readAsString();
      expect(detailHtml, contains('does not erase retained source observations'));
      expect(detailHtml, contains('name="expectedEntryRevision"'));

      final body = Uri(
        queryParameters: {
          'corpus': selector,
          'id': entryId,
          'expectedCollectionRevision': '${entry['collectionRevision']}',
          'expectedEntryRevision': '${entry['entryRevision']}',
          'topic': 'general',
          'state': 'active',
          'content': 'agent A corrected marker',
        },
      ).query;
      final saved = await handler(Request('POST', Uri.parse('http://localhost/memory/edit'), body: body));
      expect(saved.statusCode, 200);
      expect(await saved.readAsString(), contains('agent A corrected marker'));
      final current = (await admin.list(selector: selector))['entries'] as List;
      final currentEntry = current.single as Map<String, dynamic>;
      final unchangedBody = Uri(
        queryParameters: {
          'corpus': selector,
          'id': entryId,
          'expectedCollectionRevision': '${currentEntry['collectionRevision']}',
          'expectedEntryRevision': '${currentEntry['entryRevision']}',
          'topic': 'general',
          'state': 'active',
          'content': 'agent A corrected marker',
        },
      ).query;
      final unchanged = await handler(Request('POST', Uri.parse('http://localhost/memory/edit'), body: unchangedBody));
      expect(unchanged.statusCode, 200);
      expect(await unchanged.readAsString(), contains('no changes were needed'));
      final stale = await handler(Request('POST', Uri.parse('http://localhost/memory/edit'), body: body));
      expect(stale.statusCode, 409);
      expect(await stale.readAsString(), contains('Refresh its current revision'));
      expect((await admin.list(selector: 'owner'))['entries'].toString(), contains('owner private marker'));
    } finally {
      await storage.messages.dispose();
      await storage.dispose();
    }
  });
}
