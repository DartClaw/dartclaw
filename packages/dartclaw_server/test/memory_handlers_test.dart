import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/memory_handlers.dart' show maxMemoryCaptureTextLength, maxMemoryReadResponseBytes;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Map<String, dynamic> _json(Map<String, dynamic> result) {
  final content = result['content'] as List<dynamic>;
  return jsonDecode((content.single as Map<String, dynamic>)['text'] as String) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _add(
  MemoryHandlers handlers,
  MemoryCorpusService corpus,
  String content,
  String topic,
) async {
  final revision = (await corpus.readCorpus()).index.metadata.revision;
  final response = _json(
    await handlers.onApply({
      'expectedRevision': revision,
      'operations': [
        {'kind': 'add', 'correlationId': 'add-$revision', 'topic': topic, 'content': content},
      ],
    }),
  );
  final operations = response['operations'] as Map<String, dynamic>;
  return operations.values.single as Map<String, dynamic>;
}

void main() {
  late Database db;
  late MemoryService memory;
  late MemoryCorpusService corpus;
  late MemoryFileService memoryFile;
  late Directory workspace;
  late SearchBackend search;
  late MemoryCaptureContext context;
  late MemoryHandlers handlers;

  setUp(() {
    db = sqlite3.openInMemory();
    memory = MemoryService(db);
    workspace = Directory.systemTemp.createTempSync('memory_handlers_test_');
    corpus = MemoryCorpusService(workspaceDir: workspace.path);
    memoryFile = MemoryFileService(baseDir: workspace.path, corpusService: corpus);
    search = ComposedSearchBackend(
      personal: Fts5SearchBackend(memoryService: memory),
      wiki: WikiSearchSource(workspaceDir: workspace.path),
    );
    context = const MemoryCaptureContext(
      originKind: MemoryOriginKind.turn,
      sourceLocator: 'session:alpha',
      sourceEvent: 'message:1',
      caller: 'memory_observe',
      sessionRef: 'alpha',
    );
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: search,
      captureContext: (_) => context,
      now: () => DateTime.utc(2026, 8, 12, 10),
    );
  });

  tearDown(() async {
    await corpus.close();
    db.close();
    workspace.deleteSync(recursive: true);
  });

  test('observation capture returns canonical identity and advances the shared revision', () async {
    final base = await corpus.manifest();
    await IndexHealthStore(
      workspaceDir: workspace.path,
    ).recordHealthy(canonicalRevision: base.collectionRevision, canonicalFingerprint: base.fingerprint);
    final before = base.collectionRevision;

    final response = _json(await handlers.onObserve({'text': 'Falcon status is green', 'role': 'observation'}));
    final current = await corpus.readCorpus();

    expect(response, {
      'locator': isA<String>(),
      'role': 'observation',
      'entryRevision': 1,
      'collectionRevision': before + 1,
      'indexState': 'current',
    });
    final observation = current.observations.single.observations.single;
    expect(observation.id, response['locator']);
    expect(observation.provenance.sourceLocator, 'session:alpha');
    expect(observation.provenance.sourceEvent, 'message:1');
    expect(observation.trustLabel, 'untrusted-agent-observation');
    expect(memory.search('"Falcon"').single.locator, observation.id);
  });

  test('shared MCP capture records only truthful tool provenance known to the gateway', () async {
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: search,
      now: () => DateTime.utc(2026, 8, 12, 10),
    );
    const request = {'text': 'Gateway observation', 'role': 'observation'};

    await handlers.onObserve(request);
    await handlers.onObserve(request);

    final observations = (await corpus.readCorpus()).observations.single.observations;
    expect(observations.map((entry) => entry.provenance.sourceLocator).toSet(), {'tool:memory_observe'});
    expect(observations.every((entry) => entry.provenance.originKind == null), isTrue);
    expect(observations.every((entry) => entry.provenance.sourceEvent == null), isTrue);
    expect(observations.map((entry) => entry.provenance.caller).toSet(), {'mcp-gateway:memory_observe'});
    expect(observations.every((entry) => entry.provenance.sessionRef == null), isTrue);
  });

  test('learning capture remains canonical and obeys the retention cap', () async {
    final improvement = SelfImprovementService(workspaceDir: workspace.path, maxEntries: 2, corpusService: corpus);
    addTearDown(improvement.dispose);
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: search,
      selfImprovement: improvement,
      captureContext: (_) => context,
    );

    for (var index = 0; index < 3; index++) {
      await handlers.onObserve({'text': 'Learning $index', 'role': 'learning'});
    }

    final retained = (await corpus.readCorpus()).learnings!.entries;
    expect(retained.map((entry) => entry.content), unorderedEquals(['Learning 1', 'Learning 2']));
    expect(memory.search('"Learning"'), hasLength(2));
    expect(memory.search('"Learning"').every((result) => result.role == 'learning'), isTrue);
  });

  test('learning capture survives clock ties and rollback without changing timestamps', () async {
    final improvement = SelfImprovementService(workspaceDir: workspace.path, maxEntries: 2, corpusService: corpus);
    addTearDown(improvement.dispose);
    final ids = [
      '00000000-0000-4000-8000-000000000003',
      '00000000-0000-4000-8000-000000000002',
      '00000000-0000-4000-8000-000000000001',
    ].iterator;
    final at = DateTime.utc(2026, 8, 12, 10);
    final rolledBack = at.subtract(const Duration(hours: 1));
    final times = [at, at, rolledBack].iterator;
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: search,
      selfImprovement: improvement,
      captureContext: (_) => context,
      now: () {
        times.moveNext();
        return times.current;
      },
      createCaptureId: () {
        ids.moveNext();
        return ids.current;
      },
    );

    await handlers.onObserve({'text': 'Old tie', 'role': 'learning'});
    await handlers.onObserve({'text': 'Middle tie', 'role': 'learning'});
    final response = _json(await handlers.onObserve({'text': 'New tie', 'role': 'learning'}));

    final retained = (await corpus.readCorpus()).learnings!.entries;
    expect(retained.map((entry) => entry.id), contains(response['locator']));
    expect(retained.map((entry) => entry.content), ['Middle tie', 'New tie']);
    expect(retained.map((entry) => entry.created), [at, rolledBack]);
    expect(retained.map((entry) => entry.updated), [at, rolledBack]);
  });

  test('memory_apply adds through canonical topic identity', () async {
    final response = await _add(handlers, corpus, 'User prefers Dart', 'preferences');
    final current = await corpus.readCorpus();
    final entry = current.topics.single.entries.single;

    expect(response['entryId'], entry.id);
    expect(response['outcome'], 'changed');
    expect(entry.topic, 'preferences');
    final indexed = memory.search('"Dart"').single;
    expect(indexed.locator, entry.id);
    expect(indexed.source, entry.id);
    expect(indexed.source, entry.id);
  });

  test('invalid capture input leaves canonical and derived state unchanged', () async {
    final before = await corpus.readCorpus();
    for (final request in [
      {'text': 'value', 'role': 'topic'},
      {'text': '', 'role': 'observation'},
      {'text': 'x' * (maxMemoryCaptureTextLength + 1), 'role': 'observation'},
      {'text': 'value', 'role': 'observation', 'userId': 'other'},
    ]) {
      await expectLater(handlers.onObserve(request), throwsA(isA<ArgumentError>()));
    }

    expect((await corpus.readCorpus()).index.metadata.revision, before.index.metadata.revision);
    expect(memory.listRecent(), isEmpty);
  });

  test('committed capture reports a degraded index without rolling canonical content back', () async {
    final failing = _IndexFailingBackend(search);
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: failing,
      captureContext: (_) => context,
    );

    final response = _json(await handlers.onObserve({'text': 'Durable despite index failure', 'role': 'observation'}));

    expect(response['indexState'], 'degraded');
    final committed = await corpus.readCorpus();
    expect(committed.observations.single.observations.single.content, contains('Durable'));
    final snapshot = await corpus.snapshot(paths: const [], maxDocuments: 1, maxBytes: 1);
    final reopened = IndexHealthStore(workspaceDir: workspace.path);
    final degraded = await reopened.read(
      canonicalRevision: snapshot.collectionRevision,
      canonicalFingerprint: snapshot.fingerprint,
    );
    expect(degraded.state, IndexHealthState.degraded);
    expect(degraded.failureStage, 'incrementalProjection');

    await reopened.recordHealthy(
      canonicalRevision: snapshot.collectionRevision,
      canonicalFingerprint: snapshot.fingerprint,
    );
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: search,
      captureContext: (_) => context,
    );
    await handlers.onObserve({'text': 'Complete retry validates parity', 'role': 'observation'});
    final repairedSnapshot = await corpus.snapshot(paths: const [], maxDocuments: 1, maxBytes: 1);
    expect(
      (await reopened.read(
        canonicalRevision: repairedSnapshot.collectionRevision,
        canonicalFingerprint: repairedSnapshot.fingerprint,
      )).state,
      IndexHealthState.healthy,
    );
  });

  test('search passes natural language unchanged and rejects invalid limits', () async {
    final recording = _RecordingBackend();
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: recording,
      captureContext: (_) => context,
    );

    await handlers.onSearch({'query': '  project "Falcon" AND status?  '});

    expect(recording.queries, ['  project "Falcon" AND status?  ']);
    for (final limit in [0, 51, 1.5]) {
      await expectLater(handlers.onSearch({'query': 'Falcon', 'limit': limit}), throwsA(isA<ArgumentError>()));
    }
  });

  test('search exposes selected-backend degradation without dropping healthy results', () async {
    final backend = _RecordingBackend()
      ..results = const [MemorySearchResult(text: 'Falcon survives', source: 'native', score: 0)]
      ..canonicalRevision = 91
      ..degradedLayers = const ['qmd']
      ..degradations = const [
        MemorySearchDegradation(
          layer: 'wiki',
          locator: 'wiki/oversized.md',
          reason: 'sourceBytes',
          observed: 9,
          limit: 8,
        ),
      ];
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: backend,
    );

    final response = _json(await handlers.onSearch({'query': 'Falcon'}));

    expect(response['collectionRevision'], 91);
    expect(response['degradedLayers'], ['qmd']);
    expect(response['degradations'], [
      {
        'layer': 'wiki',
        'locator': 'wiki/oversized.md',
        'reason': 'sourceBytes',
        'observed': 9,
        'limit': 8,
        'omittedCount': 0,
      },
    ]);
    expect(response['results'], hasLength(1));
  });

  test('search returns bounded role-discriminated canonical results with distinct locators', () async {
    await _add(handlers, corpus, 'Falcon status shared text', 'falcon');
    await _add(handlers, corpus, 'Falcon status shared text', 'falcon');

    final response = _json(await handlers.onSearch({'query': 'Falcon status'}));
    final results = (response['results'] as List<dynamic>).cast<Map<String, dynamic>>();
    final collectionRevision = response['collectionRevision'] as int;

    expect(collectionRevision, (await corpus.readCorpus()).index.metadata.revision);
    expect(results, hasLength(2));
    expect(results.map((result) => result['locator']).toSet(), hasLength(2));
    expect(results.every((result) => result['role'] == 'topic'), isTrue);
    expect(results.every((result) => result['entryId'] == result['locator']), isTrue);

    final applied = _json(
      await handlers.onApply({
        'expectedRevision': collectionRevision,
        'operations': [
          {'kind': 'add', 'correlationId': 'from-search', 'topic': 'falcon', 'content': 'Current revision accepted'},
        ],
      }),
    );
    expect(applied['canonicalOutcome'], 'committed');
    expect(applied['collectionRevision'], collectionRevision + 1);
  });

  test('FTS backend owns operator encoding and preserves owner scope', () async {
    await _add(handlers, corpus, 'Falcon status searchable', 'falcon');
    db.execute('INSERT INTO memory_chunks (text, source, created_at, user_id, locator) VALUES (?, ?, ?, ?, ?)', [
      'Falcon status private',
      'other-id',
      DateTime(2026).toIso8601String(),
      'other',
      'other-id',
    ]);

    final response = _json(await handlers.onSearch({'query': 'Falcon AND status?'}));
    final results = response['results'] as List<dynamic>;

    expect(results, hasLength(1));
    expect((results.single as Map<String, dynamic>)['snippet'], contains('searchable'));
  });

  test('read round-trips canonical and native wiki locators without fabricating identity', () async {
    final saved = await _add(handlers, corpus, 'Canonical Falcon detail', 'falcon');
    Directory('${workspace.path}/wiki').createSync();
    File('${workspace.path}/wiki/falcon.md').writeAsStringSync('''
---
provenance: human-authored
---
Falcon wiki detail
''');
    final searched = _json(await handlers.onSearch({'query': 'Falcon'}));
    final wiki = (searched['results'] as List<dynamic>).cast<Map<String, dynamic>>().singleWhere(
      (result) => result['role'] == 'wiki',
    );

    final canonicalRead = _json(await handlers.onRead({'locator': saved['entryId']}));
    final wikiRead = _json(await handlers.onRead({'locator': wiki['locator']}));

    expect(canonicalRead['collectionRevision'], (await corpus.readCorpus()).index.metadata.revision);
    expect(wikiRead['collectionRevision'], canonicalRead['collectionRevision']);
    expect(((canonicalRead['results'] as List).single as Map)['content'], 'Canonical Falcon detail');
    final native = (wikiRead['results'] as List).single as Map;
    expect(native['role'], 'wiki');
    expect(native['locator'], 'wiki/falcon.md');
    expect(native.containsKey('entryId'), isFalse);
  });

  test('read reopens native KG and inbox locators through their source owners', () async {
    final kg = TemporalKnowledgeGraphService(db);
    final factId = kg.addFact(
      entity: 'Falcon',
      predicate: 'status',
      value: 'green',
      validFrom: '2026-08-12T00:00:00Z',
      source: 'wiki/falcon.md',
    );
    final otherFactId = kg.addFact(
      entity: 'Private Falcon',
      predicate: 'status',
      value: 'hidden',
      validFrom: '2026-08-12T00:00:00Z',
      source: 'wiki/private.md',
      owner: 'other',
    );
    Directory('${workspace.path}/inbox').createSync();
    File('${workspace.path}/inbox/note.md').writeAsStringSync('Native inbox detail');
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: _AlwaysResolvingBackend(search),
      nativeSourceResolver: LiveMemorySourceResolver(
        wiki: WikiSearchSource(workspaceDir: workspace.path),
        kg: kg,
        inbox: KnowledgeInboxReadService(workspaceDir: workspace.path),
      ),
    );

    final fact = _json(await handlers.onRead({'locator': '$factId'}));
    final inbox = _json(await handlers.onRead({'locator': 'inbox/note.md'}));

    expect((fact['results'] as List).single, {
      'role': 'kg',
      'provenance': 'wiki/falcon.md',
      'locator': '$factId',
      'content': 'falcon status green',
    });
    expect((inbox['results'] as List).single, {
      'role': 'knowledge-inbox',
      'provenance': 'inbox/note.md',
      'locator': 'inbox/note.md',
      'content': 'Native inbox detail',
    });
    expect(_json(await handlers.onRead({'locator': '99999'}))['results'], isEmpty);
    expect(_json(await handlers.onRead({'locator': '$otherFactId'}))['results'], isEmpty);
    await expectLater(handlers.onRead({'locator': '0'}), throwsA(isA<ArgumentError>()));
    await expectLater(handlers.onRead({'locator': 'inbox/../note.md'}), throwsA(isA<ArgumentError>()));
  });

  test('memory_read follows canonical QMD search locators and rejects files outside the index mask', () async {
    Directory('${workspace.path}/inbox').createSync();
    File('${workspace.path}/inbox/note one.md').writeAsStringSync('QMD inbox detail');
    File('${workspace.path}/.env').writeAsStringSync('not indexed knowledge');
    search = QmdSearchBackend(
      manager: _CannedQmdManager(workspaceDir: workspace.path),
      fallback: search,
    );
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: search,
      captureContext: (_) => context,
    );

    final searched = _json(await handlers.onSearch({'query': 'inbox detail'}));
    final locator = ((searched['results'] as List).single as Map)['locator'];
    final read = _json(await handlers.onRead({'locator': locator}));
    final rejected = _json(await handlers.onRead({'locator': 'qmd:/.env'}));

    expect(locator, 'qmd:/inbox/note%20one.md');
    expect(((read['results'] as List).single as Map)['content'], 'QMD inbox detail');
    expect(rejected['results'], isEmpty);
  });

  test('topic reads are bounded and topic-less role selectors are rejected', () async {
    await _add(handlers, corpus, 'First Falcon detail', 'falcon');
    await _add(handlers, corpus, 'Second Falcon detail', 'falcon');

    final response = _json(await handlers.onRead({'role': 'topic', 'topic': 'falcon', 'limit': 1}));

    expect(response['results'], hasLength(1));
    await expectLater(handlers.onRead({'role': 'observation', 'topic': 'falcon'}), throwsA(isA<ArgumentError>()));
    final staleLocator = const Uuid().v4();
    db.execute('INSERT INTO memory_chunks (text, source, created_at, user_id, locator) VALUES (?, ?, ?, ?, ?)', [
      'Stale derived content',
      staleLocator,
      DateTime(2026).toIso8601String(),
      'owner',
      staleLocator,
    ]);
    expect(_json(await handlers.onRead({'locator': staleLocator}))['results'], isEmpty);
    expect(_json(await handlers.onRead({'locator': 'wiki/missing.md'}))['results'], isEmpty);
    await expectLater(handlers.onRead({'locator': 'not-a-locator'}), throwsA(isA<ArgumentError>()));
    await expectLater(handlers.onRead({'locator': '../../secret'}), throwsA(isA<ArgumentError>()));
  });

  test('audit records are excluded from search and read surfaces', () async {
    final current = await corpus.readCorpus();
    final entryId = const Uuid().v4();
    await corpus.commit(
      expectedRevision: current.index.metadata.revision,
      replacement: CanonicalMemoryCorpus(
        index: current.index,
        topics: current.topics,
        archive: current.archive,
        observations: current.observations,
        learnings: current.learnings,
        audit: MemoryAuditDocument(
          records: [
            MemoryDeletionAudit(
              entryId: entryId,
              deletedAt: DateTime.utc(2026, 8, 12),
              reason: 'Private audit reason',
              provenance: MemorySourceRef(sourceLocator: 'operator'),
            ),
          ],
        ),
      ),
    );

    expect((_json(await handlers.onSearch({'query': 'Private audit'}))['results'] as List), isEmpty);
    await expectLater(handlers.onRead({'locator': entryId}), throwsA(isA<ArgumentError>()));
    await expectLater(handlers.onRead({'locator': 'MEMORY.audit.md'}), throwsA(isA<ArgumentError>()));
    await expectLater(handlers.onRead({'locator': 'qmd:/MEMORY.audit.md'}), throwsA(isA<ArgumentError>()));
  });

  test('read enforces the UTF-8 response ceiling and reports truncation', () async {
    final response = await _add(handlers, corpus, '🦅' * 20000, 'falcon');

    final raw = await handlers.onRead({'locator': response['entryId']});
    final encoded = utf8.encode(((raw['content'] as List).single as Map<String, dynamic>)['text'] as String);
    final decoded = _json(raw);

    expect(encoded.length, lessThanOrEqualTo(maxMemoryReadResponseBytes));
    expect(decoded['truncated'], isTrue);
  });

  test('read rejects metadata that cannot fit and MCP returns a bounded application error', () async {
    Directory('${workspace.path}/wiki').createSync();
    File('${workspace.path}/wiki/oversized.md').writeAsStringSync('''
---
provenance: ${'p' * (maxMemoryReadResponseBytes + 1)}
---
small body
''');

    await expectLater(handlers.onRead({'locator': 'wiki/oversized.md'}), throwsA(isA<ArgumentError>()));
    final protocol = McpProtocolHandler()..registerTool(MemoryReadTool(handler: handlers.onRead));
    final response = await protocol.handleRequest(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'memory_read',
          'arguments': {'locator': 'wiki/oversized.md'},
        },
      }),
    );

    expect(response, contains('isError'));
    expect(utf8.encode(response!).length, lessThanOrEqualTo(maxMemoryReadResponseBytes));
  });

  test('standalone capture indexes a delta without opening old observation partitions', () async {
    await corpus.manifest();
    await corpus.close();
    const codec = MemoryMarkdownCodec();
    for (var index = 0; index < 1001; index++) {
      final date = DateTime.utc(2020).add(Duration(days: index)).toIso8601String().substring(0, 10);
      final file = File('${workspace.path}/memory/$date.md')..parent.createSync(recursive: true);
      file.writeAsStringSync(codec.render(MemoryObservationDocument(date: date)));
    }
    final reads = <String>[];
    corpus = MemoryCorpusService(workspaceDir: workspace.path, readObserver: reads.add);
    memoryFile = MemoryFileService(baseDir: workspace.path, corpusService: corpus);
    handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: memoryFile,
      corpusService: corpus,
      searchBackend: search,
      captureContext: (_) => context,
      now: () => DateTime.utc(2026, 8, 12, 10),
    );
    await corpus.manifest();
    reads.clear();

    final response = _json(await handlers.onObserve({'text': 'Fresh sparse observation', 'role': 'observation'}));

    expect(response['indexState'], 'degraded');
    expect(reads.where((path) => path.startsWith('memory/20') && path != 'memory/2026-08-12.md'), isEmpty);
    expect(memory.search('Fresh sparse observation'), hasLength(1));
    final current = await corpus.manifest();
    final health = await IndexHealthStore(
      workspaceDir: workspace.path,
    ).read(canonicalRevision: current.collectionRevision, canonicalFingerprint: current.fingerprint);
    expect(health.state, IndexHealthState.degraded);
  });
}

final class _RecordingBackend implements SearchBackend {
  final queries = <String>[];
  List<MemorySearchResult> results = const [];
  List<String> degradedLayers = const [];
  List<MemorySearchDegradation> degradations = const [];
  int? canonicalRevision;

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) async {
    queries.add(query);
    return MemorySearchOutcome(
      results: results,
      degradedLayers: degradedLayers,
      degradations: degradations,
      canonicalRevision: canonicalRevision,
    );
  }

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async => null;

  @override
  Future<void> indexAfterWrite() async {}
}

final class _IndexFailingBackend implements SearchBackend {
  _IndexFailingBackend(this.delegate);

  final SearchBackend delegate;

  @override
  Future<void> indexAfterWrite() => throw StateError('injected index failure');

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) =>
      delegate.resolve(locator, userId: userId);

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) => delegate.search(query, limit: limit, userId: userId, layers: layers);
}

final class _AlwaysResolvingBackend implements SearchBackend {
  const _AlwaysResolvingBackend(this.delegate);

  final SearchBackend delegate;

  @override
  Future<void> indexAfterWrite() => delegate.indexAfterWrite();

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async =>
      MemorySearchResult(text: 'stale derived result', source: locator, score: 0, locator: locator);

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) => delegate.search(query, limit: limit, userId: userId, layers: layers);
}

final class _CannedQmdManager extends QmdManager {
  _CannedQmdManager({required super.workspaceDir});

  @override
  bool get isRunning => true;

  @override
  Future<List<Map<String, dynamic>>> query(String queryText, {String depth = 'standard', int limit = 10}) async => [
    {'text': 'search snippet', 'source': 'qmd://memory/inbox/note%20one.md', 'score': 0.9},
  ];
}
