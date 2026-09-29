import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/auth/request_auth_context.dart';
import 'package:dartclaw_runtime/src/memory/memory_admin_service.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show InMemoryFullTextIndex, openPreparedTaskBackend, seedCanonicalMemory;
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

  test('legacy owner endpoints refuse corpus selectors instead of returning owner data', () async {
    File(p.join(workspaceDir, 'MEMORY.md')).writeAsStringSync('owner-only-marker');
    for (final route in [
      '/api/memory/status?corpus=forged',
      '/api/memory/files/memory?corpus=forged',
      '/api/memory/prune?corpus=forged',
    ]) {
      final method = route.contains('/prune') ? 'POST' : 'GET';
      final response = await client.expectResponse(method, route, status: 400);
      expect(await response.readAsString(), isNot(contains('owner-only-marker')));
    }
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

    test('rejects an oversized fixed file without reading its contents', () async {
      final file = File(p.join(workspaceDir, 'MEMORY.md'));
      final handle = file.openSync(mode: FileMode.write);
      try {
        handle.truncateSync(MemoryFileService.maxReadableFileBytes + 1);
      } finally {
        handle.closeSync();
      }

      await client.expectResponse('GET', '/api/memory/files/memory', status: 500);
    });

    test('rejects fixed-file symlinks without exposing their targets', () async {
      final external = File(p.join(tempDir.path, 'outside.md'))..writeAsStringSync('external-secret');
      for (final target in [
        (apiName: 'memory', fileName: 'MEMORY.md'),
        (apiName: 'archive', fileName: 'MEMORY.archive.md'),
        (apiName: 'errors', fileName: 'errors.md'),
        (apiName: 'learnings', fileName: 'learnings.md'),
      ]) {
        final link = Link(p.join(workspaceDir, target.fileName))..createSync(external.path);

        final response = await client.expectResponse('GET', '/api/memory/files/${target.apiName}', status: 500);

        expect(await response.readAsString(), isNot(contains('external-secret')));
        expect(external.readAsStringSync(), 'external-secret');
        link.deleteSync();
      }
    }, skip: Platform.isWindows);
  });

  group('owner corpus administration', () {
    late StorageWiring storage;
    late KvService adminKv;
    late ApiRouteTestClient owner;
    late ApiRouteTestClient nonAdmin;
    late String configuredSelector;
    late String retainedSelector;

    setUp(() async {
      final a = AgentWorkspace.managed(agentId: 'a', dataDir: tempDir.path, ownerWorkspaceDir: workspaceDir);
      final removed = AgentWorkspace.managed(
        agentId: 'removed',
        dataDir: tempDir.path,
        ownerWorkspaceDir: workspaceDir,
      );
      await WorkspaceService(dataDir: tempDir.path).prepareManagedAgents([a, removed]);
      await seedCanonicalMemory(
        workspaceDir,
        topics: const {
          'general': ['owner unique marker'],
        },
      );
      await seedCanonicalMemory(
        a.directory,
        topics: const {
          'general': ['agent alpha marker'],
        },
      );
      await seedCanonicalMemory(
        removed.directory,
        topics: const {
          'general': ['retained gamma marker'],
        },
        observations: const {
          '2026-02-23': ['retained source observation'],
        },
      );
      final unmarked = Directory(p.join(tempDir.path, 'agents', 'unmarked', 'workspace'))..createSync(recursive: true);
      await seedCanonicalMemory(
        unmarked.path,
        topics: const {
          'general': ['unmarked secret marker'],
        },
      );
      final mismatched = Directory(p.join(tempDir.path, 'agents', 'mismatched', 'workspace'))
        ..createSync(recursive: true);
      File(p.join(mismatched.parent.path, 'identity.json')).writeAsStringSync('{"agentId":"a"}\n');
      await seedCanonicalMemory(
        mismatched.path,
        topics: const {
          'general': ['mismatched secret marker'],
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
              workspace: a,
            ),
          ],
        ),
      );
      final indices = <PostgresFtsTable, InMemoryFullTextIndex>{};
      storage = StorageWiring(
        config: config,
        eventBus: EventBus(),
        taskBackendFactory: (_) async => openPreparedTaskBackend(),
        taskBackendIsPrepared: true,
        searchIndexFactory: (_, table, {required withinTransaction}) =>
            indices.putIfAbsent(table, InMemoryFullTextIndex.new),
        exitFn: (code) => throw StateError('unexpected exit $code'),
      );
      await storage.wire();
      adminKv = KvService(filePath: p.join(tempDir.path, 'admin-kv.json'));
      final routes = memoryRoutes(
        statusService: MemoryStatusService(workspaceDir: workspaceDir, config: config, kvService: adminKv),
        workspaceDir: workspaceDir,
        adminService: MemoryAdminService(storage: storage),
      );
      nonAdmin = ApiRouteTestClient(routes.call);
      owner = ApiRouteTestClient((request) => routes.call(withAdminAuthContext(request)));
      final inventory = await owner.expectJsonObject('GET', '/api/memory/corpora');
      final corpora = (inventory['corpora'] as List).cast<Map<String, dynamic>>();
      configuredSelector = corpora.singleWhere((item) => item['label'] == 'a')['selector'] as String;
      retainedSelector = corpora.singleWhere((item) => item['label'] == 'removed')['selector'] as String;
    });

    tearDown(() async {
      await adminKv.dispose();
      await storage.messages.dispose();
      await storage.dispose();
    });

    test('selection reads one private corpus and refuses forged and non-admin selectors', () async {
      final main = await owner.expectJsonObject('GET', '/api/memory/entries');
      final a = await owner.expectJsonObject('GET', '/api/memory/entries?corpus=$configuredSelector');
      final removed = await owner.expectJsonObject('GET', '/api/memory/entries?corpus=$retainedSelector');
      expect((main['entries'] as List).single['content'], 'owner unique marker');
      expect((a['entries'] as List).single['content'], 'agent alpha marker');
      expect((removed['entries'] as List).single['content'], 'retained gamma marker');
      expect((removed['selected'] as Map)['kind'], 'retained');
      expect(storage.adminMemoryContexts.map((context) => context.workspace?.agentId), isNot(contains('unmarked')));
      expect(storage.adminMemoryContexts.map((context) => context.workspace?.agentId), isNot(contains('mismatched')));
      expect(
        await owner.expectJsonErrorCode('GET', '/api/memory/entries?corpus=agent:a', status: 404),
        'CORPUS_UNAVAILABLE',
      );
      expect(
        await owner.expectJsonErrorCode('GET', '/api/memory/entries?corpus=../a', status: 404),
        'CORPUS_UNAVAILABLE',
      );
      expect(await nonAdmin.expectJsonErrorCode('GET', '/api/memory/corpora', status: 403), 'FORBIDDEN');
      expect(
        await nonAdmin.expectJsonErrorCode('GET', '/api/memory/entries?corpus=$configuredSelector', status: 403),
        'FORBIDDEN',
      );
      expect(await nonAdmin.expectJsonErrorCode('POST', '/api/memory/entries/any/remove', status: 403), 'FORBIDDEN');
    });

    test('search and detail report selected revisions and no-match state', () async {
      final a = await owner.expectJsonObject('GET', '/api/memory/entries?corpus=$configuredSelector&q=alpha');
      expect((a['entries'] as List).single['content'], 'agent alpha marker');
      expect((a['health'] as Map)['state'], 'healthy');
      final noMatch = await owner.expectJsonObject('GET', '/api/memory/entries?corpus=$configuredSelector&q=gamma');
      expect(noMatch['state'], 'noMatch');
      final id = (a['entries'] as List).single['id'] as String;
      final detail = await owner.expectJsonObject('GET', '/api/memory/entries/$id?corpus=$configuredSelector');
      expect((detail['entry'] as Map)['entryRevision'], 1);
      expect(detail['collectionRevision'], a['collectionRevision']);
      final wrong = await owner.expectJsonObject(
        'GET',
        '/api/memory/entries/99999999-9999-4999-8999-999999999999?corpus=$retainedSelector',
        status: 404,
      );
      expect(wrong['state'], 'notFound');
    });

    test('CAS edit and remove preserve other corpora and retained observations', () async {
      final before = await owner.expectJsonObject('GET', '/api/memory/entries?corpus=$retainedSelector');
      final entry = (before['entries'] as List).single as Map;
      final id = entry['id'] as String;
      final edit = {
        'corpus': retainedSelector,
        'expectedCollectionRevision': before['collectionRevision'],
        'expectedEntryRevision': entry['entryRevision'],
        'topic': 'general',
        'content': 'retained corrected marker',
        'state': 'active',
      };
      final changed = await owner.expectJsonObject('POST', '/api/memory/entries/$id/revise', json: edit);
      expect(changed['canonicalOutcome'], 'committed');
      expect(changed['indexOutcome'], 'current', reason: '$changed');
      expect((changed['currentEntry'] as Map)['content'], 'retained corrected marker');
      final missingSelector = {...edit}..remove('corpus');
      expect(
        await owner.expectJsonErrorCode('POST', '/api/memory/entries/$id/revise', json: missingSelector, status: 400),
        'INVALID_INPUT',
      );
      final stale = await owner.expectJsonObject('POST', '/api/memory/entries/$id/revise', json: edit, status: 409);
      expect(stale['canonicalOutcome'], 'conflict');
      expect((stale['currentEntry'] as Map)['content'], 'retained corrected marker');
      final main = await owner.expectJsonObject('GET', '/api/memory/entries');
      expect((main['entries'] as List).single['content'], 'owner unique marker');
      final removed = await owner.expectJsonObject(
        'POST',
        '/api/memory/entries/$id/remove',
        json: {
          'corpus': retainedSelector,
          'expectedCollectionRevision': changed['collectionRevision'],
          'expectedEntryRevision': 2,
          'reason': 'Owner removed outdated curated content',
        },
      );
      expect(removed['canonicalOutcome'], 'committed');
      expect(removed['currentEntry'], isNull);
      expect(removed['removalDisclosure'], contains('does not erase retained source observations'));
      final corpus = await storage.adminMemoryContexts
          .singleWhere((context) => context.principal == 'agent:removed')
          .corpus
          .readCorpus();
      expect(corpus.observations.single.observations.single.content, 'retained source observation');
      expect(corpus.audit?.records, hasLength(1));
    });
  });
}
