import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/memory/memory_corpus_service.dart' show MemoryCorpusTransition;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  final fixedZoneChild = Platform.environment['DARTCLAW_FIXED_ZONE_CHILD'] == '1';

  setUp(() => workspace = Directory.systemTemp.createTempSync('legacy_memory_migrator_'));
  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('migrates recognized roles and preserves opaque bytes', () async {
    final legacyMemory = File(p.join(workspace.path, 'MEMORY.md'));
    legacyMemory.writeAsStringSync(
      '## User Preferences\r\n'
      '- [2026-08-10 10:00] Prefers concise answers\r\n'
      '```\r\n'
      '- [2026-08-10 11:00] fenced example\r\n'
      '```\r\n'
      'opaque tail\r\n',
    );
    final legacyMemoryBytes = legacyMemory.readAsBytesSync();
    File(
      p.join(workspace.path, 'MEMORY.archive.md'),
    ).writeAsStringSync('## Old Facts\n- [2026-08-09 09:00] Archived fact\n');
    File(p.join(workspace.path, 'learnings.md')).writeAsStringSync('- [2026-08-08 08:00] Validate before commit\n');
    final daily = File(p.join(workspace.path, 'memory', '2026-08-07.md'))..parent.createSync(recursive: true);
    daily.writeAsStringSync(
      '## 07:30 — "Chat"\n'
      '**User**: "question"\n'
      '**Tools**: ["read(file)"]\n'
      '**Result**: "answer"\n',
    );

    final authority = MemoryCorpusService(workspaceDir: workspace.path);
    final result = await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight();

    expect(result.status, MemoryPreflightStatus.migrated);
    expect(result.collectionRevision, 1);
    expect(result.roleCounts, {
      MemoryRole.topic: 1,
      MemoryRole.archive: 1,
      MemoryRole.observation: 1,
      MemoryRole.learning: 1,
    });
    expect(result.render(), contains('maximum parsed-record batch=1 limit=256'));
    final codec = MemoryMarkdownCodec();
    final topic =
        codec.parse(File(p.join(workspace.path, 'memory', 'topics', 'user-preferences.md')).readAsStringSync())
            as MemoryTopicDocument;
    expect(topic.entries.single.content, 'Prefers concise answers');
    expect(topic.entries.single.provenance.originKind, MemoryOriginKind.migration);
    expect(topic.entries.single.created.isUtc, isTrue);
    final archive = codec.parse(File(p.join(workspace.path, 'MEMORY.archive.md')).readAsStringSync());
    expect((archive as MemoryArchiveDocument).entries.single.content, 'Archived fact');
    final learnings = codec.parse(File(p.join(workspace.path, 'learnings.md')).readAsStringSync());
    expect((learnings as MemoryLearningDocument).entries.single.content, 'Validate before commit');
    final observation = codec.parse(File(p.join(workspace.path, 'memory', '2026-08-07.md')).readAsStringSync());
    expect((observation as MemoryObservationDocument).observations.single.content, contains('**User**: "question"'));
    final opaque = File(p.join(workspace.path, 'memory', 'legacy', 'MEMORY.md')).readAsBytesSync();
    expect(utf8.decode(opaque), contains('```\r\n- [2026-08-10 11:00] fenced example\r\n```\r\n'));
    final snapshot = Directory(result.snapshotPath!);
    final manifest =
        jsonDecode(File(p.join(snapshot.path, 'manifest.json')).readAsStringSync()) as Map<String, dynamic>;
    final members = manifest['members'] as Map<String, dynamic>;
    expect(File(p.join(snapshot.path, members['MEMORY.md'] as String)).readAsBytesSync(), legacyMemoryBytes);
    expect(members.keys, containsAll(['MEMORY.md', 'MEMORY.archive.md', 'learnings.md', 'memory/2026-08-07.md']));
    await authority.close();
  });

  test('preserves a UTF-8 BOM with adjacent opaque legacy bytes', () async {
    final source = Uint8List.fromList([
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode('- [2026-08-10 10:00] Recognized entry\r\nopaque tail\r\n'),
    ]);
    File(p.join(workspace.path, 'MEMORY.md')).writeAsBytesSync(source);
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight();

    final preserved = File(p.join(workspace.path, 'memory', 'legacy', 'MEMORY.md')).readAsBytesSync();
    expect(preserved, [0xef, 0xbb, 0xbf, ...utf8.encode('\nopaque tail\r\n')]);
    await authority.close();
  });

  test('host-local timestamps are proved under a fixed non-UTC zone', () async {
    final repoRoot = _repoRoot();
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'test',
        '--reporter=failures-only',
        'packages/dartclaw_storage/test/memory/legacy_memory_migrator_test.dart',
        '--name',
        'fixed-zone child',
      ],
      workingDirectory: repoRoot.path,
      environment: {...Platform.environment, 'TZ': 'America/New_York', 'DARTCLAW_FIXED_ZONE_CHILD': '1'},
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }, skip: fixedZoneChild);

  test('fixed-zone child converts host-local timestamp to UTC', () async {
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync('- [2026-01-15 10:00] Local time\n');
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight();

    final topic =
        const MemoryMarkdownCodec().parse(
              File(p.join(workspace.path, 'memory', 'topics', 'general.md')).readAsStringSync(),
            )
            as MemoryTopicDocument;
    expect(topic.entries.single.created, DateTime.utc(2026, 1, 15, 15));
    await authority.close();
  }, skip: !fixedZoneChild);

  test('completed migration is byte-stable and revision-stable', () async {
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync('- [2026-08-10 10:00] Stable entry\n');
    final firstAuthority = MemoryCorpusService(workspaceDir: workspace.path);
    await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: firstAuthority).preflight();
    await firstAuthority.close();
    final before = _workspaceFiles(workspace);

    final secondAuthority = MemoryCorpusService(workspaceDir: workspace.path);
    final second = await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: secondAuthority).preflight();

    expect(second.status, MemoryPreflightStatus.alreadyCurrent);
    expect(second.collectionRevision, 1);
    expect(_workspaceFiles(workspace), before);
    await secondAuthority.close();
  });

  test('removing an inspected migration snapshot preserves canonical availability', () async {
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync('- [2026-08-10 10:00] Stable entry\n');
    final initial = MemoryCorpusService(workspaceDir: workspace.path);
    final migrated = await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: initial).preflight();
    await initial.close();
    Directory(migrated.snapshotPath!).deleteSync(recursive: true);

    final reopened = MemoryCorpusService(workspaceDir: workspace.path);
    final manifest = await reopened.manifest();

    expect(manifest.collectionRevision, migrated.collectionRevision);
    expect(manifest.fingerprint, migrated.fingerprint);
    expect(manifest.status.migrationState, 'notApplicable');
    expect(manifest.status.migrationSnapshotPath, isNull);
    await reopened.close();
  });

  test('mismatched retained snapshot halts without mutation and gives manual retry action', () async {
    final memory = File(p.join(workspace.path, 'MEMORY.md'))..writeAsStringSync('- [2026-08-10 10:00] First version\n');
    final failing = MemoryCorpusService(
      workspaceDir: workspace.path,
      transitionHook: (transition, _) {
        if (transition == MemoryCorpusTransition.stageWritten) throw StateError('injected stage failure');
      },
    );
    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: failing).preflight(),
      throwsA(isA<MemoryPreflightException>()),
    );
    await failing.close();
    memory.writeAsStringSync('- [2026-08-10 10:00] Externally changed\n');
    final before = _workspaceFiles(workspace);

    final retry = MemoryCorpusService(workspaceDir: workspace.path);
    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: retry).preflight(),
      throwsA(
        isA<MemoryPreflightException>()
            .having((error) => error.report, 'report', contains('Inspect and delete'))
            .having((error) => error.report, 'report', contains('.dartclaw-memory-migration-snapshot')),
      ),
    );
    expect(_workspaceFiles(workspace), before);
    await retry.close();
  });

  test('corrupt retained snapshot payload halts unchanged and succeeds after manual deletion', () async {
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync('- [2026-08-10 10:00] Stable source\n');
    final failing = MemoryCorpusService(
      workspaceDir: workspace.path,
      transitionHook: (transition, _) {
        if (transition == MemoryCorpusTransition.stageWritten) throw StateError('injected stage failure');
      },
    );
    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: failing).preflight(),
      throwsA(isA<MemoryPreflightException>()),
    );
    await failing.close();
    final snapshot = Directory(p.join(workspace.path, '.dartclaw-memory-migration-snapshot'));
    final manifest =
        jsonDecode(File(p.join(snapshot.path, 'manifest.json')).readAsStringSync()) as Map<String, dynamic>;
    final member = (manifest['members'] as Map<String, dynamic>)['MEMORY.md'] as String;
    File(p.join(snapshot.path, member)).writeAsStringSync('corrupt');
    final before = _workspaceFiles(workspace);

    final retry = MemoryCorpusService(workspaceDir: workspace.path);
    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: retry).preflight(),
      throwsA(
        isA<MemoryPreflightException>()
            .having((error) => error.report, 'report', contains('snapshot payload differs for MEMORY.md'))
            .having((error) => error.report, 'report', contains('Inspect and delete')),
      ),
    );
    expect(_workspaceFiles(workspace), before);
    snapshot.deleteSync(recursive: true);
    final completed = await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: retry).preflight();
    expect(completed.status, MemoryPreflightStatus.migrated);
    await retry.close();
  });

  test('retained snapshot with every legacy source removed blocks empty bootstrap', () async {
    final memory = File(p.join(workspace.path, 'MEMORY.md'))
      ..writeAsStringSync('- [2026-08-10 10:00] Recoverable source\n');
    final failing = MemoryCorpusService(
      workspaceDir: workspace.path,
      transitionHook: (transition, _) {
        if (transition == MemoryCorpusTransition.stageWritten) throw StateError('injected stage failure');
      },
    );
    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: failing).preflight(),
      throwsA(isA<MemoryPreflightException>()),
    );
    await failing.close();
    memory.deleteSync();
    final before = _workspaceFiles(workspace);
    final retry = MemoryCorpusService(workspaceDir: workspace.path);

    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: retry).preflight(),
      throwsA(
        isA<MemoryPreflightException>()
            .having((error) => error.report, 'report', contains('no longer has any matching legacy sources'))
            .having((error) => error.report, 'report', contains('Inspect and delete')),
      ),
    );

    expect(_workspaceFiles(workspace), before);
    expect(File(p.join(workspace.path, 'MEMORY.md')).existsSync(), isFalse);
    expect(File(p.join(workspace.path, '.dartclaw-memory-corpus.json')).existsSync(), isFalse);
    await retry.close();
  });

  test('snapshot creation failure leaves legacy bytes and no canonical artifacts', () async {
    final memory = File(p.join(workspace.path, 'MEMORY.md'))
      ..writeAsStringSync('- [2026-08-10 10:00] Survives snapshot failure\n');
    File(p.join(workspace.path, '.dartclaw-memory-migration-snapshot.new')).writeAsStringSync('blocks directory');
    final before = memory.readAsBytesSync();
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight(),
      throwsA(isA<MemoryPreflightException>().having((error) => error.report, 'report', contains('failed'))),
    );

    expect(memory.readAsBytesSync(), before);
    expect(Directory(p.join(workspace.path, '.dartclaw-memory-migration-snapshot')).existsSync(), isFalse);
    expect(File(p.join(workspace.path, '.dartclaw-memory-corpus.json')).existsSync(), isFalse);
    await authority.close();
  });

  test('restart completes migration after every corpus transition crash', () async {
    for (final transition in MemoryCorpusTransition.values) {
      final caseDir = Directory(p.join(workspace.path, transition.name))..createSync();
      File(p.join(caseDir.path, 'MEMORY.md')).writeAsStringSync('- [2026-08-10 10:00] Active\n');
      final daily = File(p.join(caseDir.path, 'memory', '2026-08-09.md'))..parent.createSync(recursive: true);
      const dailyBytes =
          '## 07:30 — "Chat"\n'
          '**User**: "question"\n'
          '**Tools**: []\n'
          '**Result**: "answer"\n';
      daily.writeAsStringSync(dailyBytes);
      var crashed = false;
      final first = MemoryCorpusService(
        workspaceDir: caseDir.path,
        transitionHook: (actual, _) {
          if (!crashed && actual == transition) {
            crashed = true;
            throw MemoryCorpusSimulatedCrash(actual);
          }
        },
      );

      await expectLater(
        LegacyMemoryMigrator(workspaceDir: caseDir.path, corpusService: first).preflight(),
        throwsA(isA<MemoryPreflightException>()),
        reason: transition.name,
      );
      expect(crashed, isTrue, reason: transition.name);
      await first.close();

      final restarted = MemoryCorpusService(workspaceDir: caseDir.path);
      final result = await LegacyMemoryMigrator(workspaceDir: caseDir.path, corpusService: restarted).preflight();
      expect(result.collectionRevision, 1, reason: transition.name);
      final observation =
          const MemoryMarkdownCodec().parse(File(p.join(caseDir.path, 'memory', '2026-08-09.md')).readAsStringSync())
              as MemoryObservationDocument;
      expect(observation.observations.single.content, dailyBytes.trim(), reason: transition.name);
      final snapshot = Directory(p.join(caseDir.path, '.dartclaw-memory-migration-snapshot'));
      final manifest =
          jsonDecode(File(p.join(snapshot.path, 'manifest.json')).readAsStringSync()) as Map<String, dynamic>;
      final member = (manifest['members'] as Map<String, dynamic>)['memory/2026-08-09.md'] as String;
      expect(File(p.join(snapshot.path, member)).readAsStringSync(), dailyBytes, reason: transition.name);
      await restarted.close();
    }
  });

  test('invalid UTF-8 fails before snapshot or canonical mutation', () async {
    final memory = File(p.join(workspace.path, 'MEMORY.md'))..writeAsBytesSync([0xff, 0xfe, 0xfd]);
    final before = memory.readAsBytesSync();
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight(),
      throwsA(
        isA<MemoryPreflightException>()
            .having((error) => error.report, 'report', contains('Invalid UTF-8 in legacy source MEMORY.md'))
            .having((error) => error.report, 'report', contains('validate-classify-or-commit')),
      ),
    );
    expect(memory.readAsBytesSync(), before);
    expect(Directory(p.join(workspace.path, '.dartclaw-memory-migration-snapshot')).existsSync(), isFalse);
    await authority.close();
  });

  test('invalid UTF-8 diagnostic names the daily member', () async {
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync('- [2026-08-10 10:00] Valid source\n');
    final daily = File(p.join(workspace.path, 'memory', '2026-08-09.md'))..parent.createSync(recursive: true);
    daily.writeAsBytesSync([0xff]);
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight(),
      throwsA(
        isA<MemoryPreflightException>().having(
          (error) => error.report,
          'report',
          contains('Invalid UTF-8 in legacy source memory/2026-08-09.md'),
        ),
      ),
    );
    await authority.close();
  });

  test('invalid UTF-8 diagnostics identify every legacy root member', () async {
    for (final source in ['MEMORY.md', 'MEMORY.archive.md', 'learnings.md']) {
      final caseDir = Directory(p.join(workspace.path, source.replaceAll('.', '-')))..createSync();
      if (source != 'MEMORY.md') {
        File(p.join(caseDir.path, 'MEMORY.md')).writeAsStringSync('- [2026-08-10 10:00] Valid\n');
      }
      File(p.join(caseDir.path, source)).writeAsBytesSync([0xff]);
      final authority = MemoryCorpusService(workspaceDir: caseDir.path);

      await expectLater(
        LegacyMemoryMigrator(workspaceDir: caseDir.path, corpusService: authority).preflight(),
        throwsA(
          isA<MemoryPreflightException>().having(
            (error) => error.report,
            'report',
            contains('Invalid UTF-8 in legacy source $source'),
          ),
        ),
        reason: source,
      );
      expect(Directory(p.join(caseDir.path, '.dartclaw-memory-migration-snapshot')).existsSync(), isFalse);
      await authority.close();
    }
  });

  test('non-regular and over-limit sources leave no migration artifacts', () async {
    for (final kind in ['non-regular', 'over-limit']) {
      final caseDir = Directory(p.join(workspace.path, kind))..createSync();
      final memoryPath = p.join(caseDir.path, 'MEMORY.md');
      if (kind == 'non-regular') {
        Directory(memoryPath).createSync();
      } else {
        _writeSparse(File(memoryPath), MemoryCorpusService.maxCorpusBytes + 1);
      }
      final authority = MemoryCorpusService(workspaceDir: caseDir.path);

      await expectLater(
        LegacyMemoryMigrator(workspaceDir: caseDir.path, corpusService: authority).preflight(),
        throwsA(isA<MemoryPreflightException>()),
        reason: kind,
      );

      expect(
        Directory(p.join(caseDir.path, '.dartclaw-memory-migration-snapshot')).existsSync(),
        isFalse,
        reason: kind,
      );
      expect(File(p.join(caseDir.path, '.dartclaw-memory-corpus.json')).existsSync(), isFalse, reason: kind);
      await authority.close();
    }
  });

  test('aggregate limit plus one leaves all source bytes and creates no artifacts', () async {
    final memory = File(p.join(workspace.path, 'MEMORY.md'));
    final learnings = File(p.join(workspace.path, 'learnings.md'));
    _writeSparse(memory, MemoryCorpusService.maxCorpusBytes ~/ 2 + 1);
    _writeSparse(learnings, MemoryCorpusService.maxCorpusBytes ~/ 2);
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight(),
      throwsA(
        isA<MemoryPreflightException>().having((error) => error.report, 'report', contains('aggregate-byte limit')),
      ),
    );

    expect(memory.lengthSync(), MemoryCorpusService.maxCorpusBytes ~/ 2 + 1);
    expect(learnings.lengthSync(), MemoryCorpusService.maxCorpusBytes ~/ 2);
    expect(Directory(p.join(workspace.path, '.dartclaw-memory-migration-snapshot')).existsSync(), isFalse);
    expect(Directory(p.join(workspace.path, '.dartclaw-memory-migration-snapshot.new')).existsSync(), isFalse);
    expect(File(p.join(workspace.path, '.dartclaw-memory-transaction.json')).existsSync(), isFalse);
    expect(Directory(p.join(workspace.path, '.dartclaw-memory-transaction')).existsSync(), isFalse);
    expect(File(p.join(workspace.path, '.dartclaw-memory-corpus.json')).existsSync(), isFalse);
    await authority.close();
  });

  test('invalid current member is named and remains byte-identical', () async {
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync('## Topic\n- [2026-08-10 10:00] Active\n');
    final initial = MemoryCorpusService(workspaceDir: workspace.path);
    await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: initial).preflight();
    await initial.close();
    final topic = File(p.join(workspace.path, 'memory', 'topics', 'topic.md'))..writeAsBytesSync([0xff]);
    final before = _workspaceFiles(workspace);
    final reopened = MemoryCorpusService(workspaceDir: workspace.path);

    await expectLater(
      LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: reopened).preflight(),
      throwsA(
        isA<MemoryPreflightException>()
            .having((error) => error.report, 'report', contains('memory/topics/topic.md'))
            .having((error) => error.report, 'report', contains('validate-classify-or-commit')),
      ),
    );

    expect(topic.readAsBytesSync(), [0xff]);
    expect(_workspaceFiles(workspace), before);
    await reopened.close();
  });

  test('invalid current index marker line endings retain precise bounded diagnostics', () async {
    for (final lineEnding in ['\n', '\r\n', '\r']) {
      final caseDir = Directory(p.join(workspace.path, 'marker-${lineEnding.codeUnits.join('-')}'))..createSync();
      final memory = File(p.join(caseDir.path, 'MEMORY.md'))
        ..writeAsStringSync('# DartClaw Canonical Memory${lineEnding}invalid current metadata$lineEnding');
      final before = memory.readAsBytesSync();
      final authority = MemoryCorpusService(workspaceDir: caseDir.path);

      await expectLater(
        LegacyMemoryMigrator(workspaceDir: caseDir.path, corpusService: authority).preflight(),
        throwsA(
          isA<MemoryPreflightException>()
              .having((error) => error.report, 'report', contains('MEMORY.md'))
              .having((error) => error.report, 'report', contains('Stage: validate-classify-or-commit')),
        ),
        reason: lineEnding.codeUnits.toString(),
      );

      expect(memory.readAsBytesSync(), before, reason: lineEnding.codeUnits.toString());
      expect(File(p.join(caseDir.path, '.dartclaw-memory-corpus.json')).existsSync(), isFalse);
      await authority.close();
    }
  });

  test('daily recognition requires exact ordered payload and terminates at every heading', () async {
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync('- [2026-08-10 10:00] Active\n');
    final daily = File(p.join(workspace.path, 'memory', '2026-08-07.md'))..parent.createSync(recursive: true);
    const opaque =
        '## 07:30 — "Wrong order"\n'
        '**Tools**: []\n'
        '**User**: "question"\n'
        '**Result**: "answer"\n'
        '## ambiguous heading\n'
        '**User**: "must remain opaque"\n'
        '## 08:00 — "Noncanonical JSON"\n'
        '**User**: "question" \n'
        '**Tools**: [ ]\n'
        '**Result**: "answer"\n'
        '## 08:30 — "Valid"\n'
        '**User**: "question"\n'
        '**Tools**: ["read(file)"]\n'
        '**Result**: "answer"\n';
    daily.writeAsStringSync(opaque);
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    final result = await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight();

    expect(result.roleCounts[MemoryRole.observation], 1);
    final observation = const MemoryMarkdownCodec().parse(daily.readAsStringSync()) as MemoryObservationDocument;
    expect(observation.observations.single.content, startsWith('## 08:30'));
    final preserved = File(p.join(workspace.path, 'memory', 'legacy', 'memory__2026-08-07.md')).readAsStringSync();
    expect(preserved, startsWith('## 07:30'));
    expect(preserved, contains('## ambiguous heading\n**User**: "must remain opaque"\n'));
    expect(preserved, contains('## 08:00 — "Noncanonical JSON"\n'));
    expect(preserved, isNot(contains('## 08:30')));
    await authority.close();
  });

  test('daily recognition accepts writer CRLF while preserving adjacent ambiguous bytes exactly', () async {
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync('- [2026-08-10 10:00] Active\n');
    final daily = File(p.join(workspace.path, 'memory', '2026-08-07.md'))..parent.createSync(recursive: true);
    const valid =
        '## 07:30 — "Chat"\r\n'
        '**User**: "question"\r\n'
        '**Tools**: []\r\n'
        '**Result**: "answer"';
    const opaque = '\r\n##\r\nambiguous\r\n';
    daily.writeAsStringSync('$valid$opaque');
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight();

    final observation = const MemoryMarkdownCodec().parse(daily.readAsStringSync()) as MemoryObservationDocument;
    expect(observation.observations.single.content, valid);
    expect(
      File(p.join(workspace.path, 'memory', 'legacy', 'memory__2026-08-07.md')).readAsBytesSync(),
      utf8.encode(opaque),
    );
    await authority.close();
  });

  test('default topic count excludes explicit and slug-empty general categories', () async {
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync(
      '- [2026-08-10 09:00] Parser default\n'
      '## general\n'
      '- [2026-08-10 10:00] Explicit general\n'
      '## !!!\n'
      '- [2026-08-10 11:00] Explicit slug-empty\n',
    );
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    final result = await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight();

    expect(result.defaultTopicCount, 1);
    expect(result.render(), contains('Legacy entries assigned to topic general: 1'));
    final topic =
        const MemoryMarkdownCodec().parse(
              File(p.join(workspace.path, 'memory', 'topics', 'general.md')).readAsStringSync(),
            )
            as MemoryTopicDocument;
    expect(topic.entries, hasLength(3));
    await authority.close();
  });

  test('transforms 257 entries in batches and bounds diagnostics', () async {
    final memory = StringBuffer();
    for (var index = 0; index < 257; index++) {
      memory.writeln('- [2026-08-10 10:00] Entry $index');
    }
    File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync(memory.toString());
    final memoryDir = Directory(p.join(workspace.path, 'memory'))..createSync();
    for (var index = 0; index < 101; index++) {
      final month = (index ~/ 100).toString().padLeft(2, '0');
      final day = (index % 100).toString().padLeft(2, '0');
      File(p.join(memoryDir.path, '0000-$month-$day.md')).writeAsStringSync('opaque $index');
    }
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    final result = await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: authority).preflight();

    expect(result.roleCounts[MemoryRole.topic], 257);
    expect(result.render(), contains('maximum parsed-record batch=256 limit=256'));
    expect(result.totalDiagnostics, 103);
    expect(result.omittedDiagnostics, 3);
    expect(utf8.encode(result.render()).length, lessThanOrEqualTo(LegacyMemoryMigrator.maxReportBytes));
    expect(result.render(), contains('total=103 returned=100 omitted=3'));
    await authority.close();
  });

  test('diagnostic count cap is exact at 100 and 101', () async {
    for (final target in [100, 101]) {
      final caseDir = Directory(p.join(workspace.path, 'diagnostics-$target'))..createSync();
      File(p.join(caseDir.path, 'MEMORY.md')).writeAsStringSync('- [2026-08-10 10:00] Entry\n');
      final memoryDir = Directory(p.join(caseDir.path, 'memory'))..createSync();
      for (var index = 0; index < target - 2; index++) {
        final month = (index ~/ 28 + 1).toString().padLeft(2, '0');
        final day = (index % 28 + 1).toString().padLeft(2, '0');
        File(p.join(memoryDir.path, '0000-$month-$day.md')).writeAsStringSync('opaque $index');
      }
      final authority = MemoryCorpusService(workspaceDir: caseDir.path);

      final result = await LegacyMemoryMigrator(workspaceDir: caseDir.path, corpusService: authority).preflight();

      expect(result.totalDiagnostics, target);
      expect(result.omittedDiagnostics, target == 100 ? 0 : 1);
      expect(result.render(), contains('total=$target returned=100 omitted=${target - 100}'));
      await authority.close();
    }
  });

  test('failure reports accept exactly 64 KiB and reject 64 KiB plus one', () {
    final empty = MemoryPreflightException.bounded(stage: 'boundary', error: '').report;
    final exactError = '${'x' * (LegacyMemoryMigrator.maxReportBytes - utf8.encode(empty).length - 2)}é';

    final exact = MemoryPreflightException.bounded(stage: 'boundary', error: exactError).report;
    final over = MemoryPreflightException.bounded(stage: 'boundary', error: '${exactError}x').report;

    expect(
      utf8.encode(exact).length,
      LegacyMemoryMigrator.maxReportBytes,
      reason: exact.split('\n').firstWhere((line) => line.startsWith('Diagnostics:')),
    );
    expect(exact, endsWith('é\n'));
    expect(over, contains('Diagnostics: total=1 returned=0 omitted=1'));
    expect(utf8.encode(over).length, lessThanOrEqualTo(LegacyMemoryMigrator.maxReportBytes));
  });

  test('successful reports retain whole diagnostics up to the UTF-8 cap', () async {
    final probe = await _reconciliationReport(workspace, 'report-probe', uniformPadding: 0, tailPadding: 0);
    final probeBytes = utf8.encode(probe).length;
    expect(probe, contains('returned=100 omitted=0'));
    expect(probeBytes, lessThan(LegacyMemoryMigrator.maxReportBytes));
    final deficit = LegacyMemoryMigrator.maxReportBytes - probeBytes;
    final uniformPadding = deficit ~/ 100;
    final base = await _reconciliationReport(workspace, 'report-base', uniformPadding: uniformPadding, tailPadding: 0);
    expect(base, contains('total=100 returned=100 omitted=0'));
    final targetTail = LegacyMemoryMigrator.maxReportBytes - utf8.encode(base).length;
    final candidates = <(int, String)>[];
    for (var tail = targetTail - 16; tail <= targetTail + 16; tail++) {
      if (tail < 0) continue;
      candidates.add((
        tail,
        await _reconciliationReport(
          workspace,
          'report-candidate-$tail',
          uniformPadding: uniformPadding,
          tailPadding: tail,
        ),
      ));
    }
    final retained = candidates.lastWhere((candidate) => candidate.$2.contains('total=100 returned=100 omitted=0'));
    String? over;
    for (var tail = retained.$1 + 1; tail <= retained.$1 + 3; tail++) {
      final candidate = await _reconciliationReport(
        workspace,
        'report-over-$tail',
        uniformPadding: uniformPadding,
        tailPadding: tail,
      );
      if (candidate.contains('total=100 returned=99 omitted=1')) {
        over = candidate;
        break;
      }
    }

    expect(utf8.encode(retained.$2).length, lessThanOrEqualTo(LegacyMemoryMigrator.maxReportBytes));
    expect(over, isNotNull);
    expect(utf8.encode(over!).length, lessThan(LegacyMemoryMigrator.maxReportBytes));
  });
}

Map<String, List<int>> _workspaceFiles(Directory workspace) {
  final values = <String, List<int>>{};
  for (final entity in workspace.listSync(recursive: true, followLinks: false)) {
    if (entity is File) values[p.relative(entity.path, from: workspace.path)] = entity.readAsBytesSync();
  }
  return values;
}

void _writeSparse(File file, int length) {
  file.parent.createSync(recursive: true);
  final handle = file.openSync(mode: FileMode.write);
  try {
    handle.setPositionSync(length - 1);
    handle.writeByteSync(0);
  } finally {
    handle.closeSync();
  }
}

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (!File(p.join(directory.path, 'dev', 'guidelines', 'TESTING-STRATEGY.md')).existsSync()) {
    final parent = directory.parent;
    if (parent.path == directory.path) throw StateError('Repository root not found from ${Directory.current.path}');
    directory = parent;
  }
  return directory;
}

Future<String> _reconciliationReport(
  Directory parent,
  String name, {
  required int uniformPadding,
  required int tailPadding,
}) async {
  final workspace = Directory(p.join(parent.path, name))..createSync();
  final segment = 'a' * 180;
  final paths = <String>[
    for (var index = 0; index < 100; index++)
      p.posix.join(
        'memory',
        'legacy',
        segment,
        segment,
        segment,
        'd${'d' * (uniformPadding + (index == 99 ? tailPadding : 0))}',
        '$index.md',
      ),
  ];
  final authority = MemoryCorpusService(workspaceDir: workspace.path);
  await authority.updateFiles<void>(
    paths: const ['MEMORY.md'],
    prepare: (_) => throw StateError('canonical preparation required'),
    prepareLegacyCanonical: (_) => MemoryCorpusMutation(
      value: null,
      corpus: CanonicalMemoryCorpus(
        index: MemoryIndexDocument(
          metadata: MemoryCollectionMetadata(collectionId: '11111111-1111-4111-8111-111111111111', revision: 1),
        ),
        verbatimMembers: [for (final path in paths) VerbatimMemoryMember(path: path, bytes: utf8.encode('before'))],
      ),
    ),
  );
  await authority.close();
  for (final path in paths) {
    File(p.join(workspace.path, path)).writeAsStringSync('after');
  }
  final reopened = MemoryCorpusService(workspaceDir: workspace.path);
  final result = await LegacyMemoryMigrator(workspaceDir: workspace.path, corpusService: reopened).preflight();
  await reopened.close();
  return result.render();
}
