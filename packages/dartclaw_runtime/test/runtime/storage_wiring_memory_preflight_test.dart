import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:dartclaw_testing/dartclaw_testing.dart' show seedCanonicalMemory;

void main() {
  late Directory dataDir;

  setUp(() => dataDir = Directory.systemTemp.createTempSync('storage_wiring_preflight_'));
  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('the canonical corpus is current before the FTS5 factory observes the workspace', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    Directory(config.workspaceDir).createSync(recursive: true);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Visible canonical fact'],
      },
    );
    final memory = File(p.join(config.workspaceDir, 'MEMORY.md'));
    var searchOpened = false;
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: (_) {
        searchOpened = true;
        final index = const MemoryMarkdownCodec().parse(memory.readAsStringSync());
        expect(index, isA<MemoryIndexDocument>());
        expect((index as MemoryIndexDocument).entries, hasLength(1));
        return sqlite3.openInMemory();
      },
      taskDbFactory: (_) => sqlite3.openInMemory(),
      exitFn: (code) => throw _Exit(code),
    );

    await wiring.wire();

    expect(searchOpened, isTrue);
    await wiring.dispose();
  });

  test('report is emitted before FTS5 and QMD activation', () async {
    final config = DartclawConfig(
      server: ServerConfig(dataDir: dataDir.path),
      search: const SearchConfig(backend: 'qmd'),
    );
    Directory(config.workspaceDir).createSync(recursive: true);
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
    final qmd = _SentinelQmdManager(() => events.add('qmd'));
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: (_) {
        events.add('fts5');
        return sqlite3.openInMemory();
      },
      taskDbFactory: (_) => sqlite3.openInMemory(),
      qmdManagerFactory: () => qmd,
      exitFn: (code) => throw _Exit(code),
    );

    await wiring.wire();

    expect(events, ['report', 'fts5', 'qmd']);
    await wiring.dispose();
  });

  test('a preview-dialect workspace is refused before the FTS5 factory, byte-for-byte intact', () async {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    final memory = File(p.join(config.workspaceDir, 'MEMORY.md'))..parent.createSync(recursive: true);
    memory.writeAsStringSync('## general\n- [2026-08-10 10:00] Preview dialect fact\n');
    final learnings = File(p.join(config.workspaceDir, 'learnings.md'))
      ..writeAsStringSync('- [2026-08-10 10:00] Preview learning\n');
    var searchOpened = false;
    var qmdConstructed = false;
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: (_) {
        searchOpened = true;
        return sqlite3.openInMemory();
      },
      taskDbFactory: (_) => sqlite3.openInMemory(),
      qmdManagerFactory: () {
        qmdConstructed = true;
        return _SentinelQmdManager(() {});
      },
      exitFn: (code) => throw _Exit(code),
    );

    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));

    expect(searchOpened, isFalse);
    expect(qmdConstructed, isFalse);
    expect(memory.readAsStringSync(), '## general\n- [2026-08-10 10:00] Preview dialect fact\n');
    expect(learnings.readAsStringSync(), '- [2026-08-10 10:00] Preview learning\n');
    final failure = records.singleWhere((record) => record.message.contains('preflight failed'));
    final report = (failure.error! as MemoryPreflightException).report;
    expect(report, contains('Stage: legacy-dialect-detected'));
    expect(report, contains('MEMORY.md, learnings.md'));
    expect(report, contains(MemoryPreflight.lastConvertingRelease));
  });

  test('invalid current corpus emits bounded member report before all index boundaries', () async {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    for (final lineEnding in ['\n', '\r\n', '\r']) {
      records.clear();
      final config = DartclawConfig(
        server: ServerConfig(dataDir: p.join(dataDir.path, 'case-${lineEnding.codeUnits.join('-')}')),
        search: const SearchConfig(backend: 'qmd'),
      );
      final memory = File(p.join(config.workspaceDir, 'MEMORY.md'))..parent.createSync(recursive: true);
      memory.writeAsStringSync('# DartClaw Canonical Memory${lineEnding}invalid current metadata$lineEnding');
      final before = memory.readAsBytesSync();
      var searchOpened = false;
      var qmdConstructed = false;
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        searchDbFactory: (_) {
          searchOpened = true;
          return sqlite3.openInMemory();
        },
        taskDbFactory: (_) => sqlite3.openInMemory(),
        qmdManagerFactory: () {
          qmdConstructed = true;
          return _SentinelQmdManager(() {});
        },
        exitFn: (code) => throw _Exit(code),
      );

      await expectLater(
        wiring.wire(),
        throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)),
        reason: lineEnding.codeUnits.toString(),
      );

      expect(searchOpened, isFalse, reason: lineEnding.codeUnits.toString());
      expect(qmdConstructed, isFalse, reason: lineEnding.codeUnits.toString());
      expect(memory.readAsBytesSync(), before, reason: lineEnding.codeUnits.toString());
      final failure = records.singleWhere((record) => record.message.contains('preflight failed'));
      expect(failure.error, isA<MemoryPreflightException>());
      final report = (failure.error! as MemoryPreflightException).report;
      expect(report, contains('MEMORY.md'));
      expect(report, contains('Stage: validate-classify-or-commit'));
      expect(utf8.encode(report).length, lessThanOrEqualTo(MemoryPreflight.maxReportBytes));
    }
  });

  test('missing index is reconstructed before the production search database opens', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    Directory(config.workspaceDir).createSync(recursive: true);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Unique startup recovery fact'],
      },
    );
    expect(File(config.searchDbPath).existsSync(), isFalse);
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: openSearchDb,
      taskDbFactory: (_) => sqlite3.openInMemory(),
      exitFn: (code) => throw _Exit(code),
    );

    await wiring.wire();

    expect(wiring.memory.search('Unique startup').single.text, contains('recovery fact'));
    final snapshot = await wiring.memoryCorpus.snapshot(paths: const [], maxDocuments: 1, maxBytes: 1);
    final health = await wiring.indexHealth.read(
      canonicalRevision: snapshot.collectionRevision,
      canonicalFingerprint: snapshot.fingerprint,
    );
    expect(health.state, IndexHealthState.healthy);
    expect(health.indexRevision, snapshot.collectionRevision);
    await wiring.dispose();
  });

  test('random corrupt index is replaced from canonical memory', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    Directory(config.workspaceDir).createSync(recursive: true);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Corrupt index recovery fact'],
      },
    );
    File(config.searchDbPath)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([0xff, 0, 0xfe, 1]);
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: openSearchDb,
      taskDbFactory: (_) => sqlite3.openInMemory(),
      exitFn: (code) => throw _Exit(code),
    );

    await wiring.wire();

    expect(wiring.memory.search('Corrupt index').single.text, contains('recovery fact'));
    await wiring.dispose();
  });

  test('supported stopped edit advances once and is indexed before healthy activation', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    Directory(config.workspaceDir).createSync(recursive: true);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['Before stopped edit'],
      },
    );
    final first = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: openSearchDb,
      taskDbFactory: (_) => sqlite3.openInMemory(),
      exitFn: (code) => throw _Exit(code),
    );
    await first.wire();
    final priorRevision = (await first.memoryCorpus.readCorpus()).index.metadata.revision;
    await first.dispose();
    final topic = File(p.join(config.workspaceDir, 'memory', 'topics', 'general.md'));
    topic.writeAsStringSync(topic.readAsStringSync().replaceAll('Before stopped edit', 'After stopped edit'));
    final index = File(p.join(config.workspaceDir, 'MEMORY.md'));
    index.writeAsStringSync(index.readAsStringSync().replaceAll('Before stopped edit', 'After stopped edit'));

    final second = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: openSearchDb,
      taskDbFactory: (_) => sqlite3.openInMemory(),
      exitFn: (code) => throw _Exit(code),
    );
    await second.wire();

    expect((await second.memoryCorpus.readCorpus()).index.metadata.revision, priorRevision + 1);
    expect(second.memory.search('After stopped').single.text, contains('After stopped edit'));
    expect(second.memory.search('Before stopped'), isEmpty);
    final snapshot = await second.memoryCorpus.snapshot(paths: const [], maxDocuments: 1, maxBytes: 1);
    expect(
      (await second.indexHealth.read(
        canonicalRevision: snapshot.collectionRevision,
        canonicalFingerprint: snapshot.fingerprint,
      )).state,
      IndexHealthState.healthy,
    );
    await second.dispose();
  });

  test('stopped observation deletion advances once and reconciles the index before healthy activation', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    Directory(config.workspaceDir).createSync(recursive: true);
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
    final first = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: openSearchDb,
      taskDbFactory: (_) => sqlite3.openInMemory(),
      exitFn: (code) => throw _Exit(code),
    );
    await first.wire();
    final prior = await first.memoryCorpus.manifest();
    expect(first.memory.search('Delete this raw observation'), hasLength(1));
    await first.dispose();

    observation.deleteSync();
    final second = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: openSearchDb,
      taskDbFactory: (_) => sqlite3.openInMemory(),
      exitFn: (code) => throw _Exit(code),
    );
    await second.wire();

    final current = await second.memoryCorpus.manifest();
    expect(current.collectionRevision, prior.collectionRevision + 1);
    expect(current.paths, isNot(contains('memory/2026-08-07.md')));
    expect(second.memory.search('Delete this raw observation'), isEmpty);
    expect(
      (await second.indexHealth.read(
        canonicalRevision: current.collectionRevision,
        canonicalFingerprint: current.fingerprint,
      )).state,
      IndexHealthState.healthy,
    );
    await second.dispose();
  });

  test('derived recovery failure boots degraded with canonical memory available', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    Directory(config.workspaceDir).createSync(recursive: true);
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
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchDbFactory: openSearchDb,
      taskDbFactory: (_) => sqlite3.openInMemory(),
      indexReconciler: CanonicalIndexReconciler(
        targetPath: config.searchDbPath,
        healthStore: health,
        transitionHook: (transition) async {
          if (transition.name == 'beforeSwap') throw StateError('swap unavailable');
        },
      ),
      exitFn: (code) => throw _Exit(code),
    );

    await wiring.wire();

    final corpus = await wiring.memoryCorpus.readCorpus();
    expect(corpus.index.entries.single.summary, contains('Canonical remains readable'));
    final snapshot = await wiring.memoryCorpus.snapshot(paths: const [], maxDocuments: 1, maxBytes: 1);
    expect(
      (await wiring.indexHealth.read(
        canonicalRevision: snapshot.collectionRevision,
        canonicalFingerprint: snapshot.fingerprint,
      )).state,
      IndexHealthState.degraded,
    );
    expect(() => wiring.memory.search('Canonical'), throwsA(isA<SqliteException>()));
    final search = await wiring.searchBackend.search('recovery');
    expect(search.map((result) => result.locator), ['wiki/recovery.md']);
    expect(search.canonicalRevision, snapshot.collectionRevision);
    expect(search.degradedLayers, ['memory']);
    expect(search.degradations.single.reason, 'indexNotCurrent');
    await wiring.dispose();
  });

  for (final targetInitiallyExists in [false, true]) {
    test(
      'derived recovery failure preserves ${targetInitiallyExists ? 'existing target bytes' : 'target absence'}',
      () async {
        final config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
        Directory(config.workspaceDir).createSync(recursive: true);
        await seedCanonicalMemory(
          config.workspaceDir,
          topics: const {
            'general': ['Canonical recovery fact'],
          },
        );
        final target = File(config.searchDbPath);
        List<int>? priorBytes;
        if (targetInitiallyExists) {
          target.parent.createSync(recursive: true);
          final database = openSearchDb(target.path);
          MemoryService(database);
          database.close();
          priorBytes = target.readAsBytesSync();
        }
        var targetOpenCalls = 0;
        final health = IndexHealthStore(workspaceDir: config.workspaceDir);
        final wiring = StorageWiring(
          config: config,
          eventBus: EventBus(),
          searchDbFactory: (path) {
            targetOpenCalls++;
            return openSearchDb(path);
          },
          taskDbFactory: (_) => sqlite3.openInMemory(),
          indexReconciler: CanonicalIndexReconciler(
            targetPath: config.searchDbPath,
            healthStore: health,
            transitionHook: (transition) async {
              if (transition.name == 'beforeSwap') throw StateError('swap unavailable');
            },
          ),
          exitFn: (code) => throw _Exit(code),
        );

        await wiring.wire();

        expect(targetOpenCalls, 0);
        if (targetInitiallyExists) {
          expect(target.readAsBytesSync(), priorBytes);
        } else {
          expect(target.existsSync(), isFalse);
        }
        expect(() => wiring.memory.search('Canonical'), throwsA(isA<SqliteException>()));
        await wiring.dispose();
      },
    );
  }
}

final class _Exit implements Exception {
  const new(this.code);

  final int code;
}

final class _SentinelQmdManager extends QmdManager {
  new(this.onActivate)
    : super(commandRunner: (executable, arguments, {workingDirectory}) async => ProcessResult(0, 0, '', ''));

  final void Function() onActivate;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> activate() async => onActivate();
}
