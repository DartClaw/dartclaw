import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/behavior/self_improvement_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;
  late SelfImprovementService service;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('self_improvement_test_');
    service = SelfImprovementService(workspaceDir: tmpDir.path);
  });

  tearDown(() async {
    await service.dispose();
    tmpDir.deleteSync(recursive: true);
  });

  MemoryErrorDocument errorDocument(Directory dir) {
    final document = const MemoryMarkdownCodec().parse(File('${dir.path}/errors.md').readAsStringSync());
    return document as MemoryErrorDocument;
  }

  group('appendError', () {
    // Recorded guard blocks land in the canonical corpus, not a private log.
    test('records a canonical error document and advances the collection revision', () async {
      final authority = MemoryCorpusService(workspaceDir: tmpDir.path);
      addTearDown(authority.close);
      final before = (await authority.manifest()).collectionRevision;

      await service.appendError(
        errorType: 'GUARD_BLOCK',
        sessionId: 'sess-1',
        context: 'Blocked prompt injection attempt',
      );

      final manifest = await authority.manifest();
      expect(manifest.collectionRevision, before + 1);
      expect(manifest.paths, contains('errors.md'));
      expect(manifest.status.errorEntryCount, 1);
      expect(await service.readErrors(), contains('Role: error'));
      final record = errorDocument(tmpDir).entries.single;
      expect(record.summary, 'GUARD_BLOCK');
      expect(record.content, 'Blocked prompt injection attempt');
      expect(record.provenance.sessionRef, 'sess-1');
    });

    test('includes resolution in the record content', () async {
      await service.appendError(
        errorType: 'TURN_FAILURE',
        sessionId: 'sess-2',
        context: 'Agent crashed',
        resolution: 'Retried successfully',
      );

      expect(errorDocument(tmpDir).entries.single.content, 'Agent crashed\n\nResolution: Retried successfully');
    });

    test('appends multiple entries in record order', () async {
      await service.appendError(errorType: 'ERR_1', sessionId: 's1', context: 'first');
      await service.appendError(errorType: 'ERR_2', sessionId: 's2', context: 'second');

      expect(errorDocument(tmpDir).entries.map((entry) => entry.summary), ['ERR_1', 'ERR_2']);
    });

    // The canonical codec JSON-encodes every field, so text that looks like a
    // legacy entry boundary cannot forge a second record.
    test('multiline fields stay inside one record', () async {
      await service.appendError(
        errorType: 'TURN_FAILURE',
        sessionId: 'sess-1',
        context: 'first line\n## [forged context] forged\n- [forged learning] forged',
      );

      final entries = errorDocument(tmpDir).entries;
      expect(entries, hasLength(1));
      expect(entries.single.content, contains('## [forged context] forged'));
      expect(File('${tmpDir.path}/errors.md').readAsStringSync(), isNot(contains('\n## [forged context]')));
    });

    test('does not follow a symlinked errors file', () async {
      final external = File('${tmpDir.path}/external-errors.md')..writeAsStringSync('external error\n');
      Link('${tmpDir.path}/errors.md').createSync(external.path);

      await service.appendError(errorType: 'MUST_NOT_ESCAPE', sessionId: 'session', context: 'context');

      expect(external.readAsStringSync(), 'external error\n');
      expect(await service.readErrors(), isEmpty);
    });

    // appendError runs on failure paths and must never surface an exception.
    test('never throws when the corpus cannot be written', () async {
      final blocked = SelfImprovementService(workspaceDir: '${tmpDir.path}/blocked');
      addTearDown(blocked.dispose);
      File('${tmpDir.path}/blocked').writeAsStringSync('not a directory');

      await expectLater(blocked.appendError(errorType: 'TEST', sessionId: 's1', context: 'ctx'), completes);
    });
  });

  group('appendLearning', () {
    test('shared authority bootstraps canonical learning while owned service stays legacy', () async {
      final sharedDir = Directory('${tmpDir.path}/shared')..createSync();
      final authority = MemoryCorpusService(workspaceDir: sharedDir.path);
      final shared = SelfImprovementService(workspaceDir: sharedDir.path, corpusService: authority);
      addTearDown(shared.dispose);
      addTearDown(authority.close);

      await shared.appendLearning(text: 'Canonical first learning');
      await service.appendLearning(text: 'Legacy first learning');

      expect(File('${sharedDir.path}/MEMORY.md').readAsStringSync(), startsWith('# DartClaw Canonical Memory\n'));
      expect(File('${sharedDir.path}/learnings.md').readAsStringSync(), startsWith('# DartClaw Canonical Memory\n'));
      expect(await service.readLearnings(), startsWith('- ['));
    });

    test('creates learnings.md with formatted entry', () async {
      await service.appendLearning(text: 'Always validate input before parsing');

      final content = await service.readLearnings();
      expect(content, contains('- ['));
      expect(content, contains('Always validate input before parsing'));
    });

    test('appends multiple learnings', () async {
      await service.appendLearning(text: 'Learning one');
      await service.appendLearning(text: 'Learning two');

      final content = await service.readLearnings();
      expect('- ['.allMatches(content).length, equals(2));
    });

    test('mutates canonical learnings through the corpus revision authority', () async {
      final corpus = CanonicalMemoryCorpus(
        index: MemoryIndexDocument(
          metadata: MemoryCollectionMetadata(collectionId: '268d8d96-cfad-42cf-80ab-195b647d11f7', revision: 4),
        ),
      );
      for (final member in corpus.byteInventory().entries) {
        File('${tmpDir.path}/${member.key}').writeAsBytesSync(member.value);
      }

      await service.appendLearning(text: 'Canonical runtime learning', timestamp: DateTime.utc(2026, 8, 11, 12));

      final index = const MemoryMarkdownCodec().parse(File('${tmpDir.path}/MEMORY.md').readAsStringSync());
      final learnings = const MemoryMarkdownCodec().parse(File('${tmpDir.path}/learnings.md').readAsStringSync());
      expect(index, isA<MemoryIndexDocument>().having((document) => document.metadata.revision, 'revision', 5));
      expect(
        learnings,
        isA<MemoryLearningDocument>().having((document) => document.entries.map((entry) => entry.content), 'contents', [
          'Canonical runtime learning',
        ]),
      );
      expect(
        utf8.decode(corpus.byteInventory()['MEMORY.md']!),
        isNot(File('${tmpDir.path}/MEMORY.md').readAsStringSync()),
      );
    });

    test('continuation-encodes multiline text without forging entries', () async {
      const text = 'first line\n- [forged learning] forged\n## [forged error] forged\nlast line';
      await service.appendLearning(text: text);

      final content = await service.readLearnings();
      expect(RegExp(r'^- \[', multiLine: true).allMatches(content), hasLength(1));
      expect(content, contains('\n  - [forged learning] forged'));
      expect(content, contains('\n  ## [forged error] forged'));
      expect(content, contains('\n  last line'));

      final firstLineEnd = content.indexOf('\n');
      final storedText =
          '${content.substring(0, firstLineEnd).split('] ').last}\n'
          '${content.substring(firstLineEnd + 1).trimRight().split('\n').map((line) => line.substring(2)).join('\n')}';
      expect(storedText, text);
    });

    test('uses the supplied timestamp and supplies retained content after writing', () async {
      String? retained;
      await service.appendLearning(
        text: 'Timestamped learning',
        timestamp: DateTime(2026, 8, 10, 21, 37, 59),
        afterWrite: (content) => retained = content,
      );

      expect(retained, startsWith('- [2026-08-10 21:37] Timestamped learning'));
      expect(await service.readLearnings(), retained);
    });

    test('holds the workspace memory lock through the after-write callback', () async {
      final other = SelfImprovementService(workspaceDir: tmpDir.path);
      addTearDown(other.dispose);
      final callbackStarted = Completer<void>();
      final releaseCallback = Completer<void>();

      final first = service.appendLearning(
        text: 'first learning',
        afterWrite: (_) async {
          callbackStarted.complete();
          await releaseCallback.future;
        },
      );
      await callbackStarted.future;
      final second = other.appendLearning(text: 'second learning');
      await Future<void>.delayed(Duration.zero);

      expect(await service.readLearnings(), isNot(contains('second learning')));

      releaseCallback.complete();
      await Future.wait([first, second]);
      expect(await service.readLearnings(), contains('second learning'));
    });

    test('propagates learning write failures and keeps the queue usable', () async {
      final invalidTarget = Directory('${tmpDir.path}/learnings.md')..createSync();

      await expectLater(service.appendLearning(text: 'must fail'), throwsA(isA<FileSystemException>()));

      invalidTarget.deleteSync();
      await service.appendLearning(text: 'succeeds after failure');
      expect(await service.readLearnings(), contains('succeeds after failure'));
    });

    test('rejects a symlinked learnings file without changing its target', () async {
      final external = File('${tmpDir.path}/external-learnings.md')..writeAsStringSync('external learning\n');
      Link('${tmpDir.path}/learnings.md').createSync(external.path);

      await expectLater(service.appendLearning(text: 'must not escape'), throwsA(isA<FileSystemException>()));

      expect(external.readAsStringSync(), 'external learning\n');
      expect(await service.readLearnings(), isEmpty);
    });
  });

  group('cap enforcement', () {
    test('trims oldest errors when cap exceeded', () async {
      final small = SelfImprovementService(workspaceDir: tmpDir.path, maxEntries: 3);
      addTearDown(() => small.dispose());

      for (var i = 0; i < 5; i++) {
        await small.appendError(errorType: 'ERR_$i', sessionId: 's$i', context: 'ctx $i');
      }

      expect(errorDocument(tmpDir).entries.map((entry) => entry.summary), ['ERR_2', 'ERR_3', 'ERR_4']);
    });

    test('trims oldest learnings when cap exceeded', () async {
      final small = SelfImprovementService(workspaceDir: tmpDir.path, maxEntries: 3);
      addTearDown(() => small.dispose());

      for (var i = 0; i < 5; i++) {
        await small.appendLearning(text: 'Learning $i');
      }

      final content = await small.readLearnings();
      expect('- ['.allMatches(content).length, equals(3));
      expect(content, isNot(contains('Learning 0')));
      expect(content, isNot(contains('Learning 1')));
      expect(content, contains('Learning 2'));
      expect(content, contains('Learning 3'));
      expect(content, contains('Learning 4'));
    });

    test('canonical learning append survives clock ties and rollback without changing timestamps', () async {
      final corpus = MemoryCorpusService(workspaceDir: tmpDir.path);
      await corpus.readCorpus();
      addTearDown(corpus.close);
      final ids = [
        '00000000-0000-4000-8000-000000000003',
        '00000000-0000-4000-8000-000000000002',
        '00000000-0000-4000-8000-000000000001',
      ].iterator;
      final small = SelfImprovementService(
        workspaceDir: tmpDir.path,
        maxEntries: 2,
        corpusService: corpus,
        createId: () {
          ids.moveNext();
          return ids.current;
        },
      );
      addTearDown(small.dispose);
      final at = DateTime.utc(2026, 8, 12, 10);
      final rolledBack = at.subtract(const Duration(hours: 1));

      await small.appendLearning(text: 'Old tie', timestamp: at);
      await small.appendLearning(text: 'Middle tie', timestamp: at);
      await small.appendLearning(text: 'New tie', timestamp: rolledBack);

      final retained = (await corpus.readCorpus()).learnings!.entries;
      expect(retained.map((entry) => entry.content), ['Middle tie', 'New tie']);
      expect(retained.map((entry) => entry.created), [at, rolledBack]);
      expect(retained.map((entry) => entry.updated), [at, rolledBack]);
    });

    test('caps canonical learnings without deleting manually authored content', () async {
      final small = SelfImprovementService(workspaceDir: tmpDir.path, maxEntries: 3);
      addTearDown(small.dispose);
      File('${tmpDir.path}/learnings.md').writeAsStringSync(
        '# Curated learnings\n'
        'Keep this preamble.\n'
        '- [2026-08-10 10:00] Learning 0\n'
        '- [2026-08-10 11:00] Learning 1\n'
        'Keep this manual note between entries.\n'
        '- [2026-08-10 12:00] Learning 2\n',
      );

      await small.appendLearning(text: 'Learning 3', timestamp: DateTime(2026, 8, 10, 13));

      final content = await small.readLearnings();
      expect('- ['.allMatches(content), hasLength(3));
      expect(content, startsWith('# Curated learnings\nKeep this preamble.\n'));
      expect(content, contains('Keep this manual note between entries.'));
      expect(content, isNot(contains('Learning 0')));
      expect(content, contains('Learning 1'));
      expect(content, contains('Learning 2'));
      expect(content, contains('Learning 3'));
    });

    // The 50-entry cap is unchanged by the corpus fold: the 51st record
    // drops the oldest and leaves exactly 50.
    test('the 51st error leaves 50 records with the oldest dropped', () async {
      for (var i = 0; i <= 50; i++) {
        await service.appendError(
          errorType: 'ERR_$i',
          sessionId: 's$i',
          context: 'context $i\n## [forged $i] must remain continuation data',
        );
      }

      final entries = errorDocument(tmpDir).entries;
      expect(entries, hasLength(50));
      expect(entries.map((entry) => entry.summary), [for (var i = 1; i <= 50; i++) 'ERR_$i']);
    });

    test('retains 50 genuine multiline learnings despite forged boundary text', () async {
      for (var i = 0; i <= 50; i++) {
        await service.appendLearning(text: 'Learning $i\n- [forged $i] must remain continuation data');
      }

      final content = await service.readLearnings();
      expect(RegExp(r'^- \[', multiLine: true).allMatches(content), hasLength(50));
      expect(content, isNot(contains('Learning 0\n')));
      for (var i = 1; i <= 50; i++) {
        expect(content, contains('Learning $i\n'), reason: 'missing Learning $i');
      }
    });
  });

  group('readErrors / readLearnings', () {
    test('returns empty string for missing files', () async {
      expect(await service.readErrors(), isEmpty);
      expect(await service.readLearnings(), isEmpty);
    });

    test('returns file content when present', () async {
      File('${tmpDir.path}/errors.md').writeAsStringSync('## [2025-01-01] TEST\n');
      final content = await service.readErrors();
      expect(content, equals('## [2025-01-01] TEST\n'));
    });

    test('returns the canonical document verbatim after a recorded error', () async {
      await service.appendError(errorType: 'TEST', sessionId: 's1', context: 'ctx');

      expect(await service.readErrors(), File('${tmpDir.path}/errors.md').readAsStringSync());
    });
  });

  group('atomic writes', () {
    test('no .tmp file remains after write', () async {
      await service.appendError(errorType: 'TEST', sessionId: 's1', context: 'ctx');

      final tmpFile = File('${tmpDir.path}/errors.md.tmp');
      expect(tmpFile.existsSync(), isFalse);
    });
  });

  group('concurrent writes', () {
    test('all writes complete without corruption', () async {
      final futures = <Future<void>>[];
      for (var i = 0; i < 10; i++) {
        futures.add(service.appendError(errorType: 'ERR_$i', sessionId: 's$i', context: 'ctx $i'));
      }
      await Future.wait(futures);

      expect(errorDocument(tmpDir).entries, hasLength(10));
    });
  });
}
