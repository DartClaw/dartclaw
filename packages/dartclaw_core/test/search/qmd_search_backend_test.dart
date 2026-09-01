import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'search_test_support.dart';

/// Fake search backend that records calls and returns canned results.
class FakeFts5Backend implements SearchBackend {
  final List<String> searchCalls = [];
  List<MemorySearchResult> nextResults = [];
  List<MemorySearchDegradation> nextDegradations = const [];

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) async {
    searchCalls.add(query);
    return MemorySearchOutcome(results: nextResults, degradations: nextDegradations);
  }

  @override
  Future<void> indexAfterWrite() async {}

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async => null;
}

void main() {
  group('QmdSearchBackend', () {
    test('delegates to QMD when running', () async {
      final fts5 = FakeFts5Backend();
      final qmd = FakeQmdManager();
      qmd.nextQueryResult = [
        {'text': 'Result from QMD', 'source': 'memory.md', 'score': 0.95},
      ];

      final backend = QmdSearchBackend(manager: qmd, fallback: fts5);
      final results = await backend.search('dart async');

      expect(results, hasLength(1));
      expect(results.first.text, 'Result from QMD');
      expect(fts5.searchCalls, ['dart async']);
    });

    test('never exposes audit records returned by QMD', () async {
      final qmd = FakeQmdManager()
        ..nextQueryResult = [
          {'text': 'Private audit payload', 'source': 'MEMORY.audit.md', 'score': 1.0},
          {'text': 'Visible observation', 'source': 'memory/2026-08-12.md', 'score': 0.9},
          {'text': 'Visible inbox source', 'source': 'inbox/release.md', 'score': 0.8},
        ];
      final backend = QmdSearchBackend(manager: qmd, fallback: FakeFts5Backend());

      final results = await backend.search('payload observation');

      expect(results.map((result) => result.text), ['Visible inbox source']);
      expect(results.single.role, 'knowledge-inbox');
      expect(results.single.locator, 'qmd:/inbox/release.md');
    });

    test('native locator resolution rejects a symlinked parent directory', () async {
      final workspace = Directory.systemTemp.createTempSync('dartclaw_qmd_resolve_');
      final outside = Directory.systemTemp.createTempSync('dartclaw_qmd_outside_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      addTearDown(() => outside.deleteSync(recursive: true));
      File(p.join(outside.path, 'secret.md')).writeAsStringSync('not workspace knowledge');
      Link(p.join(workspace.path, 'linked')).createSync(outside.path);
      final backend = QmdSearchBackend(
        manager: QmdManager(workspaceDir: workspace.path),
        fallback: FakeFts5Backend(),
      );

      expect(await backend.resolve('qmd:/linked/secret.md'), isNull);
    });

    test('authority-form search sources round-trip through canonical QMD locators', () async {
      final workspace = Directory.systemTemp.createTempSync('dartclaw_qmd_round_trip_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      Directory(p.join(workspace.path, 'inbox')).createSync();
      File(p.join(workspace.path, 'inbox', 'note one.md')).writeAsStringSync('admitted workspace knowledge');
      File(p.join(workspace.path, '.env')).writeAsStringSync('not indexed knowledge');
      final qmd = FakeQmdManager(workspaceDir: workspace.path)
        ..nextQueryResult = [
          {'text': 'search snippet', 'source': 'qmd://memory/inbox/note%20one.md', 'score': 0.9},
        ];
      final backend = QmdSearchBackend(manager: qmd, fallback: FakeFts5Backend());

      final result = (await backend.search('knowledge')).single;

      expect(result.locator, 'qmd:/inbox/note%20one.md');
      expect((await backend.resolve(result.locator))?.text, 'admitted workspace knowledge');
      expect(await backend.resolve('qmd:/.env'), isNull);
    });

    test('native locator rejects an oversized source before reading its body', () async {
      final workspace = Directory.systemTemp.createTempSync('dartclaw_qmd_oversized_resolve_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      final source = File(p.join(workspace.path, 'inbox', 'oversized.md'))..parent.createSync(recursive: true);
      final handle = source.openSync(mode: FileMode.write);
      handle.truncateSync(MemoryResourceLimits.sourceBytes + 1);
      handle.closeSync();
      final backend = QmdSearchBackend(
        manager: QmdManager(workspaceDir: workspace.path),
        fallback: FakeFts5Backend(),
      );

      await expectLater(
        backend.resolve('qmd:/inbox/oversized.md'),
        throwsA(
          isA<MemoryResourceLimitException>()
              .having((error) => error.role, 'role', MemoryRole.topic)
              .having((error) => error.locator, 'locator', 'qmd:/inbox/oversized.md')
              .having((error) => error.observedBytes, 'observedBytes', MemoryResourceLimits.sourceBytes + 1)
              .having((error) => error.limitBytes, 'limitBytes', MemoryResourceLimits.sourceBytes),
        ),
      );
    });

    test('falls back to FTS5 when QMD not running', () async {
      final fts5 = FakeFts5Backend();
      fts5.nextResults = [const MemorySearchResult(text: 'FTS5 result', source: 'memory', score: -1.0)];
      fts5.nextDegradations = const [
        MemorySearchDegradation(
          layer: 'wiki',
          locator: 'wiki/oversized.md',
          reason: 'sourceBytes',
          observed: 9,
          limit: 8,
        ),
      ];
      final qmd = FakeQmdManager(fakeRunning: false);

      final backend = QmdSearchBackend(manager: qmd, fallback: fts5);
      final results = await backend.search('test query');

      expect(results, hasLength(1));
      expect(results.first.text, 'FTS5 result');
      expect(results.degradedLayers, ['qmd']);
      expect(results.degradations, fts5.nextDegradations);
      expect(fts5.searchCalls, contains('test query'));
    });

    test('falls back to FTS5 on QMD error', () async {
      final fts5 = FakeFts5Backend();
      fts5.nextResults = [const MemorySearchResult(text: 'Fallback', source: 'memory', score: -0.5)];
      final qmd = FakeQmdManager();
      qmd.shouldThrow = true;

      final backend = QmdSearchBackend(manager: qmd, fallback: fts5);
      final results = await backend.search('test');

      expect(results, hasLength(1));
      expect(results.first.text, 'Fallback');
    });

    for (final response in [
      ('malformed list', '[{"unexpected":true}]'),
      ('malformed map', '{"results":{"unexpected":true}}'),
    ]) {
      test('falls back to FTS5 on ${response.$1} response', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;
          request.response.write(response.$2);
          await request.response.close();
        });
        final fts5 = FakeFts5Backend()
          ..nextResults = [const MemorySearchResult(text: 'Fallback', source: 'memory', score: -0.5)];
        final backend = QmdSearchBackend(
          manager: _RunningQmdManager(port: server.port),
          fallback: fts5,
        );

        final results = await backend.search('test');

        expect(results.single.text, 'Fallback');
        expect(fts5.searchCalls, ['test']);
      });
    }

    test('indexAfterWrite delegates to QMD manager', () async {
      final fts5 = FakeFts5Backend();
      final qmd = FakeQmdManager();
      final backend = QmdSearchBackend(manager: qmd, fallback: fts5);

      // Should not throw
      await backend.indexAfterWrite();
    });

    test('indexAfterWrite reports a QMD refresh failure to the canonical writer', () async {
      final qmd = FakeQmdManager()..shouldThrow = true;
      final backend = QmdSearchBackend(manager: qmd, fallback: FakeFts5Backend());

      await expectLater(backend.indexAfterWrite(), throwsException);
    });

    test('wiki outranks raw QMD rows and higher-relevance raw rows sort first', () async {
      final workspace = Directory.systemTemp.createTempSync('dartclaw_qmd_wiki_rank_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      Directory(p.join(workspace.path, 'wiki')).createSync(recursive: true);
      File(p.join(workspace.path, 'wiki', 'dart-async.md')).writeAsStringSync('''
---
provenance: llm-authored
sources:
  - "inbox/dart.md"
confidence: medium
last_updated: 2026-05-01T00:00:00.000Z
last_updated_by: "test"
contradicts: []
related: []
---
# Dart Async

Dart async programming synthesized from source.
''');

      final fts5 = FakeFts5Backend();
      final qmd = FakeQmdManager();
      // QMD relevance is higher-is-better; the more relevant row must rank first.
      qmd.nextQueryResult = [
        {'text': 'Less relevant raw', 'source': 'm-low.md', 'score': 0.5},
        {'text': 'More relevant raw', 'source': 'm-high.md', 'score': 0.9},
      ];

      final backend = ComposedSearchBackend(
        personal: QmdSearchBackend(manager: qmd, fallback: fts5),
        wiki: WikiSearchSource(workspaceDir: workspace.path),
      );
      final results = await backend.search('dart async');

      expect(results.map((r) => r.text).toList(), [
        contains('Dart async programming synthesized'),
        'More relevant raw',
        'Less relevant raw',
      ]);
    });

    test('wiki and QMD copies of the same page occupy one result slot', () async {
      final workspace = Directory.systemTemp.createTempSync('dartclaw_qmd_wiki_dedupe_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      Directory(p.join(workspace.path, 'wiki')).createSync(recursive: true);
      File(p.join(workspace.path, 'wiki', 'dart.md')).writeAsStringSync('''
---
provenance: human-authored
---
# Dart

Dart async reference.
''');
      final qmd = FakeQmdManager()
        ..nextQueryResult = [
          {'text': 'QMD duplicate', 'source': 'qmd://memory/wiki/dart.md', 'score': 0.9},
          {'text': 'Distinct inbox item', 'source': 'qmd://memory/inbox/note.md', 'score': 0.8},
        ];
      final backend = ComposedSearchBackend(
        personal: QmdSearchBackend(manager: qmd, fallback: FakeFts5Backend()),
        wiki: WikiSearchSource(workspaceDir: workspace.path),
      );

      final results = await backend.search('dart async', limit: 2);

      expect(results.map((result) => result.source), ['wiki/dart.md', 'qmd://memory/inbox/note.md']);
    });

    test('search depth options', () {
      expect(SearchDepth.fromString('fast'), SearchDepth.fast);
      expect(SearchDepth.fromString('standard'), SearchDepth.standard);
      expect(SearchDepth.fromString('deep'), SearchDepth.deep);
      expect(SearchDepth.fromString('unknown'), SearchDepth.standard);
    });
  });
}

final class _RunningQmdManager extends QmdManager {
  new({required super.port}) : super(host: InternetAddress.loopbackIPv4.address);

  @override
  bool get isRunning => true;
}
