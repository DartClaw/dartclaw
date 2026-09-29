import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/storage/index_rebuild_target.dart' show IndexPopulateAndValidate, IndexReconcileHook;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'memory_wiring_test_support.dart';

void main() {
  late Directory dataDir;

  setUp(() => dataDir = Directory.systemTemp.createTempSync('storage_wiring_preflight_'));
  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('the canonical corpus is current before the lexical index factory observes the workspace', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Visible canonical fact'],
      },
    );
    final memory = File(p.join(config.workspaceDir, 'MEMORY.md'));
    var indexOpened = false;
    final wiring = _wiring(
      config,
      onIndex: () {
        indexOpened = true;
        final index = const MemoryMarkdownCodec().parse(memory.readAsStringSync());
        expect(index, isA<MemoryIndexDocument>());
        expect((index as MemoryIndexDocument).entries, hasLength(1));
      },
    );

    await wiring.wire();
    expect(indexOpened, isTrue);
    await wiring.dispose();
  });

  test('the preflight report is emitted before lexical index activation', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Visible after preflight'],
      },
    );
    final events = <String>[];
    final subscription = Logger.root.onRecord.listen((record) {
      if (record.loggerName == 'StorageWiring' && record.message.startsWith('Memory preflight:')) {
        events.add('report');
      }
    });
    addTearDown(subscription.cancel);
    final wiring = _wiring(config, onIndex: () => events.add('index'));

    await wiring.wire();
    expect(events.first, 'report');
    expect(events.where((event) => event == 'index'), isNotEmpty);
    await wiring.dispose();
  });

  test('a preview-dialect workspace is refused before indexing and remains byte-for-byte intact', () async {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    final memory = File(p.join(config.workspaceDir, 'MEMORY.md'))..parent.createSync(recursive: true);
    memory.writeAsStringSync('## general\n- [2026-08-10 10:00] Preview dialect fact\n');
    final learnings = File(p.join(config.workspaceDir, 'learnings.md'))
      ..writeAsStringSync('- [2026-08-10 10:00] Preview learning\n');
    var indexOpened = false;
    final wiring = _wiring(config, onIndex: () => indexOpened = true);

    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));

    expect(indexOpened, isFalse);
    expect(memory.readAsStringSync(), '## general\n- [2026-08-10 10:00] Preview dialect fact\n');
    expect(learnings.readAsStringSync(), '- [2026-08-10 10:00] Preview learning\n');
    final failure = records.singleWhere((record) => record.message.contains('preflight failed'));
    final report = (failure.error! as MemoryPreflightException).report;
    expect(report, contains('Stage: legacy-dialect-detected'));
    expect(report, contains('MEMORY.md, learnings.md'));
    expect(report, contains(MemoryPreflight.lastConvertingRelease));
  });

  test('invalid current corpus emits a bounded member report before indexing', () async {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    for (final lineEnding in ['\n', '\r\n', '\r']) {
      records.clear();
      final config = DartclawConfig(
        server: ServerConfig(dataDir: p.join(dataDir.path, 'case-${lineEnding.codeUnits.join('-')}')),
      );
      final memory = seedInvalidCurrentMemory(config.workspaceDir, lineEnding: lineEnding);
      final before = memory.readAsBytesSync();
      var indexOpened = false;
      final wiring = _wiring(config, onIndex: () => indexOpened = true);

      await expectLater(
        wiring.wire(),
        throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)),
        reason: lineEnding.codeUnits.toString(),
      );

      expect(indexOpened, isFalse, reason: lineEnding.codeUnits.toString());
      expect(memory.readAsBytesSync(), before, reason: lineEnding.codeUnits.toString());
      final failure = records.singleWhere((record) => record.message.contains('preflight failed'));
      final report = (failure.error! as MemoryPreflightException).report;
      expect(report, contains('MEMORY.md'));
      expect(report, contains('Stage: validate-classify-or-commit'));
      expect(utf8.encode(report).length, lessThanOrEqualTo(MemoryPreflight.maxReportBytes));
    }
  });

  test('missing derived rows are reconstructed before search activation', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Unique startup recovery fact'],
      },
    );
    final wiring = _wiring(config);

    await wiring.wire();
    try {
      expect(
        (await wiring.memoryIndex.search('Unique startup', userId: 'owner')).single.chunk,
        contains('recovery fact'),
      );
      final manifest = await wiring.memoryCorpus.manifest();
      final health = await wiring.indexHealth.read(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
      );
      expect(health.isCurrent(manifest.collectionRevision, manifest.fingerprint), isTrue);
    } finally {
      await wiring.dispose();
    }
  });

  test('a supported stopped edit advances once and is indexed before healthy activation', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Before stopped edit'],
      },
    );
    final first = _wiring(config);
    await first.wire();
    final priorRevision = (await first.memoryCorpus.readCorpus()).index.metadata.revision;
    await first.dispose();
    final topic = File(p.join(config.workspaceDir, 'memory', 'topics', 'general.md'));
    topic.writeAsStringSync(topic.readAsStringSync().replaceAll('Before stopped edit', 'After stopped edit'));
    final index = File(p.join(config.workspaceDir, 'MEMORY.md'));
    index.writeAsStringSync(index.readAsStringSync().replaceAll('Before stopped edit', 'After stopped edit'));

    final second = _wiring(config);
    await second.wire();
    try {
      expect((await second.memoryCorpus.readCorpus()).index.metadata.revision, priorRevision + 1);
      expect(
        (await second.memoryIndex.search('After stopped', userId: 'owner')).single.chunk,
        contains('After stopped edit'),
      );
      expect(await second.memoryIndex.search('Before', userId: 'owner'), isEmpty);
    } finally {
      await second.dispose();
    }
  });

  test('a stopped observation deletion advances once and reconciles the index', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Stable topic'],
      },
      observations: const {
        '2026-08-07': ['Delete this raw observation'],
      },
    );
    final observation = File(p.join(config.workspaceDir, 'memory', '2026-08-07.md'));
    final first = _wiring(config);
    await first.wire();
    final prior = await first.memoryCorpus.manifest();
    await first.dispose();

    observation.deleteSync();
    final second = _wiring(config);
    await second.wire();
    try {
      final current = await second.memoryCorpus.manifest();
      expect(current.collectionRevision, prior.collectionRevision + 1);
      expect(current.paths, isNot(contains('memory/2026-08-07.md')));
      expect(await second.memoryIndex.search('Delete this raw observation', userId: 'owner'), isEmpty);
    } finally {
      await second.dispose();
    }
  });

  test('derived recovery failure boots degraded with canonical memory available', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Canonical remains readable'],
      },
    );
    File(p.join(config.workspaceDir, 'wiki', 'recovery.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('Native recovery source survives');
    final health = IndexHealthStore(workspaceDir: config.workspaceDir);
    final wiring = _wiring(
      config,
      indexReconciler: CanonicalIndexReconciler(healthStore: health, target: const _FailingRebuildTarget()),
    );

    await wiring.wire();
    try {
      final corpus = await wiring.memoryCorpus.readCorpus();
      expect(corpus.index.entries.single.summary, contains('Canonical remains readable'));
      final manifest = await wiring.memoryCorpus.manifest();
      expect(
        (await wiring.indexHealth.read(
          canonicalRevision: manifest.collectionRevision,
          canonicalFingerprint: manifest.fingerprint,
        )).state,
        IndexHealthState.degraded,
      );
      expect(await wiring.memoryIndex.search('Canonical', userId: 'owner'), isEmpty);
      final search = await wiring.searchBackend.search('recovery');
      expect(search.map((result) => result.locator), ['wiki/recovery.md']);
      expect(search.degradedLayers, ['memory']);
      expect(search.degradations.single.reason, 'indexNotCurrent');
    } finally {
      await wiring.dispose();
    }
  });
}

StorageWiring _wiring(DartclawConfig config, {void Function()? onIndex, CanonicalIndexReconciler? indexReconciler}) {
  final indices = <PostgresFtsTable, InMemoryFullTextIndex>{};
  return StorageWiring(
    config: config,
    eventBus: EventBus(),
    taskBackendFactory: (_) async => openPreparedTaskBackend(),
    taskBackendIsPrepared: true,
    searchIndexFactory: (_, table, {required withinTransaction}) {
      onIndex?.call();
      return indices.putIfAbsent(table, InMemoryFullTextIndex.new);
    },
    indexReconciler: indexReconciler,
    exitFn: (code) => throw _Exit(code),
  );
}

final class _FailingRebuildTarget implements IndexRebuildTarget {
  const new();

  @override
  Future<bool> isPresent() async => false;

  @override
  Future<T> validateLive<T>(Future<T> Function(FullTextIndex index) body) =>
      Future.error(StateError('live index unavailable'));

  @override
  Future<T> rebuild<T>({
    required IndexPopulateAndValidate<T> populateAndValidate,
    required IndexReconcileHook transition,
  }) => Future.error(StateError('injected reconciliation failure'));
}

final class _Exit implements Exception {
  const new(this.code);

  final int code;
}
