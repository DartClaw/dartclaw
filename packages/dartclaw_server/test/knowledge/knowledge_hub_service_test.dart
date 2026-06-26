import 'dart:io';

import 'package:dartclaw_server/src/knowledge/knowledge_hub_service.dart';
import 'package:dartclaw_server/src/knowledge/knowledge_inbox_service.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Database searchDb;
  late Database taskDb;
  late MemoryService memory;
  late TemporalKnowledgeGraphService kg;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('knowledge_hub_service_test_');
    searchDb = sqlite3.openInMemory();
    taskDb = sqlite3.openInMemory();
    memory = MemoryService(searchDb);
    kg = TemporalKnowledgeGraphService(taskDb);
    _writeFile(tempDir, 'wiki/onboarding.md', 'Merge queue onboarding keeps source links.');
    _writeFile(tempDir, 'inbox/merge-note.md', 'Merge source landed in the inbox.');
    memory.insertChunk(text: 'Merge memory keeps durable context.', source: 'MEMORY.md', category: 'build');
    kg.addFact(
      entity: 'Merge queue',
      predicate: 'policy',
      value: 'requires green checks',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/onboarding.md',
    );
  });

  tearDown(() {
    searchDb.close();
    taskDb.close();
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
    final throwing = _ThrowingKg(taskDb);
    final result = await KnowledgeHubService(
      wiki: WikiSearchSource(workspaceDir: tempDir.path),
      kg: throwing,
      memory: memory,
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
    final recordingKg = _RecordingKg(taskDb);

    await KnowledgeHubService(
      wiki: WikiSearchSource(workspaceDir: tempDir.path),
      kg: recordingKg,
      memory: memory,
      inbox: KnowledgeInboxReadService(workspaceDir: tempDir.path),
    ).search(const KnowledgeHubQuery(query: 'merge', layer: KnowledgeHubLayer.kg, page: 2, perPage: 3));

    expect(recordingKg.lastSearch, 'merge');
    expect(recordingKg.lastLimit, 9);
  });
}

KnowledgeHubService _service(Directory tempDir, TemporalKnowledgeGraphService kg, MemoryService memory) {
  return KnowledgeHubService(
    wiki: WikiSearchSource(workspaceDir: tempDir.path),
    kg: kg,
    memory: memory,
    inbox: KnowledgeInboxReadService(workspaceDir: tempDir.path),
  );
}

void _writeFile(Directory tempDir, String relativePath, String body) {
  final file = File('${tempDir.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(body);
}

final class _ThrowingKg extends TemporalKnowledgeGraphService {
  _ThrowingKg(super.db);

  @override
  List<KnowledgeFact> allFacts({String? asOf, String? search, int? limit}) => throw StateError('boom');
}

final class _RecordingKg extends TemporalKnowledgeGraphService {
  String? lastSearch;
  int? lastLimit;

  _RecordingKg(super.db);

  @override
  List<KnowledgeFact> allFacts({String? asOf, String? search, int? limit}) {
    lastSearch = search;
    lastLimit = limit;
    return const [];
  }
}
