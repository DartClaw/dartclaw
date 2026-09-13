import 'dart:io';

import 'package:dartclaw_runtime/src/knowledge/knowledge_hub_service.dart';
import 'package:dartclaw_runtime/src/knowledge/knowledge_inbox_read_service.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show openPreparedTaskBackend;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../helpers/search_index_test_support.dart';

void main() {
  late Directory tempDir;
  late Database searchDb;
  late SqliteBackend taskBackend;
  late FullTextIndex memory;
  late TemporalKnowledgeGraphService kg;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('knowledge_hub_service_test_');
    searchDb = sqlite3.openInMemory();
    taskBackend = await openPreparedTaskBackend();
    memory = await prepareMemoryIndex(searchDb);
    kg = TemporalKnowledgeGraphService(taskBackend);
    _writeFile(tempDir, 'wiki/onboarding.md', 'Merge queue onboarding keeps source links.');
    _writeFile(tempDir, 'inbox/merge-note.md', 'Merge source landed in the inbox.');
    await _seed(memory, text: 'Merge memory keeps durable context.', id: '00000000-0000-4000-8000-000000000001');
    await kg.addFact(
      entity: 'Merge queue',
      predicate: 'policy',
      value: 'requires green checks',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/onboarding.md',
    );
  });

  tearDown(() async {
    searchDb.close();
    await taskBackend.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('S01 returns matches across wiki, KG, memory, and inbox', () async {
    final result = await _service(tempDir, kg, memory).search(const KnowledgeHubQuery(query: 'merge'));

    expect(result.items.map((item) => item.layer), containsAll(KnowledgeHubLayer.values.skip(1)));
    expect(result.layerCounts[KnowledgeHubLayer.wiki], 1);
    expect(result.layerCounts[KnowledgeHubLayer.kg], 1);
    expect(result.layerCounts[KnowledgeHubLayer.memory], 1);
    expect(result.layerCounts[KnowledgeHubLayer.inbox], 1);
  });

  test('S02 scopes results by layer and S07 no-match returns empty results', () async {
    final kgOnly = await _service(
      tempDir,
      kg,
      memory,
    ).search(const KnowledgeHubQuery(query: 'merge', layer: KnowledgeHubLayer.kg));
    final noMatch = await _service(tempDir, kg, memory).search(const KnowledgeHubQuery(query: 'zzznomatch'));

    expect(kgOnly.items, isNotEmpty);
    expect(kgOnly.items.every((item) => item.layer == KnowledgeHubLayer.kg), isTrue);
    expect(noMatch.items, isEmpty);
    expect(noMatch.totalItems, 0);
  });

  test('OC01 lists wiki content without a search query', () async {
    final result = await _service(tempDir, kg, memory).search(const KnowledgeHubQuery(layer: KnowledgeHubLayer.wiki));

    expect(result.items, hasLength(1));
    expect(result.items.single.layer, KnowledgeHubLayer.wiki);
    expect(result.items.single.sourceHref, '/knowledge/wiki/wiki/onboarding.md');
  });

  test('S06 isolates a failed KG query and keeps surviving layer results', () async {
    final throwing = _ThrowingKg(taskBackend);
    final result = await KnowledgeHubService(
      wiki: WikiSearchSource(workspaceDir: tempDir.path),
      kg: throwing,
      memoryIndex: memory,
      searchBackend: _search(tempDir, memory),
      inbox: KnowledgeInboxReadService(workspaceDir: tempDir.path),
    ).search(const KnowledgeHubQuery(query: 'merge'));

    expect(result.failedLayers, [KnowledgeHubLayer.kg]);
    expect(
      result.items.map((item) => item.layer),
      containsAll([KnowledgeHubLayer.wiki, KnowledgeHubLayer.memory, KnowledgeHubLayer.inbox]),
    );
  });

  test('S08 clamps over-long input and paginates normalized results', () async {
    for (var i = 0; i < 15; i++) {
      _writeFile(tempDir, 'inbox/long-$i.md', '${'m' * KnowledgeHubQuery.maxQueryLength} page item $i');
    }

    final longQuery = 'm' * 220;
    final page1 = await _service(
      tempDir,
      kg,
      memory,
    ).search(KnowledgeHubQuery(query: longQuery, layer: KnowledgeHubLayer.inbox, perPage: 5));
    final page2 = await _service(
      tempDir,
      kg,
      memory,
    ).search(KnowledgeHubQuery(query: longQuery, layer: KnowledgeHubLayer.inbox, page: 2, perPage: 5));

    expect(page1.query.query.length, KnowledgeHubQuery.maxQueryLength);
    expect(page1.items, hasLength(5));
    expect(page2.items, hasLength(5));
    expect(
      page1.items
          .map((item) => item.sourceLabel)
          .toSet()
          .intersection(page2.items.map((item) => item.sourceLabel).toSet()),
      isEmpty,
    );
  });

  test('KG hub leg passes the effective page cap to the shared KG read surface', () async {
    final recordingKg = _RecordingKg(taskBackend);

    await KnowledgeHubService(
      wiki: WikiSearchSource(workspaceDir: tempDir.path),
      kg: recordingKg,
      memoryIndex: memory,
      searchBackend: _search(tempDir, memory),
      inbox: KnowledgeInboxReadService(workspaceDir: tempDir.path),
    ).search(const KnowledgeHubQuery(query: 'merge', layer: KnowledgeHubLayer.kg, page: 2, perPage: 3));

    expect(recordingKg.lastSearch, 'merge');
    expect(recordingKg.lastLimit, 9);
  });

  test('layer-only search constrains composition before page top-K', () async {
    final entries = <MemoryIndexEntry>[];
    for (var index = 0; index < 5; index++) {
      entries.add(
        MemoryIndexEntry(
          id: '00000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
          revision: 1,
          topic: 'general',
          summary: 'Falcon memory $index',
          updated: DateTime.utc(2026),
        ),
      );
      _writeFile(tempDir, 'wiki/falcon-$index.md', '---\nprovenance: human-authored\n---\nFalcon wiki $index');
    }
    await memory.replaceAll([
      for (final entry in entries)
        SearchDocument(
          id: entry.id,
          chunks: [entry.summary],
          metadata: {'source': entry.id, 'role': 'memory', 'provenance': 'unknown'},
          timestamp: entry.updated,
        ),
    ], userId: 'owner');
    final service = _service(tempDir, kg, memory);

    final memoryOnly = await service.search(
      const KnowledgeHubQuery(query: 'Falcon', layer: KnowledgeHubLayer.memory, perPage: 3),
    );
    final wikiOnly = await service.search(
      const KnowledgeHubQuery(query: 'Falcon', layer: KnowledgeHubLayer.wiki, perPage: 3),
    );

    expect(memoryOnly.items, hasLength(3));
    expect(memoryOnly.items.every((item) => item.layer == KnowledgeHubLayer.memory), isTrue);
    expect(wikiOnly.items, hasLength(3));
    expect(wikiOnly.items.every((item) => item.layer == KnowledgeHubLayer.wiki), isTrue);
  });
}

KnowledgeHubService _service(Directory tempDir, TemporalKnowledgeGraphService kg, FullTextIndex memory) {
  return KnowledgeHubService(
    wiki: WikiSearchSource(workspaceDir: tempDir.path),
    kg: kg,
    memoryIndex: memory,
    searchBackend: _search(tempDir, memory),
    inbox: KnowledgeInboxReadService(workspaceDir: tempDir.path),
  );
}

Future<void> _seed(FullTextIndex index, {required String text, required String id}) async {
  await index.replaceAll([
    SearchDocument(
      id: id,
      chunks: [text],
      metadata: {'source': id, 'role': 'memory', 'provenance': 'unknown'},
      timestamp: DateTime.utc(2026),
    ),
  ], userId: 'owner');
}

ComposedSearchBackend _search(Directory tempDir, FullTextIndex memory) => ComposedSearchBackend(
  personal: Fts5SearchBackend(index: memory),
  wiki: WikiSearchSource(workspaceDir: tempDir.path),
);

void _writeFile(Directory tempDir, String relativePath, String body) {
  final file = File('${tempDir.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(body);
}

final class _ThrowingKg extends TemporalKnowledgeGraphService {
  new(super.backend);

  @override
  Future<List<KnowledgeFact>> allFacts({String? asOf, String? search, int? limit}) async => throw StateError('boom');
}

final class _RecordingKg extends TemporalKnowledgeGraphService {
  String? lastSearch;
  int? lastLimit;

  new(super.backend);

  @override
  Future<List<KnowledgeFact>> allFacts({String? asOf, String? search, int? limit}) async {
    lastSearch = search;
    lastLimit = limit;
    return const [];
  }
}
