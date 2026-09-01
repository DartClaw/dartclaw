import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('memory_preflight_'));
  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  Future<T> withPreflight<T>(Future<T> Function(MemoryPreflight preflight) body) async {
    final corpus = MemoryCorpusService(workspaceDir: workspace.path);
    try {
      return await body(MemoryPreflight(workspaceDir: workspace.path, corpusService: corpus));
    } finally {
      await corpus.close();
    }
  }

  Map<String, List<int>> workspaceBytes() {
    final result = <String, List<int>>{};
    for (final entity in workspace.listSync(recursive: true, followLinks: false)) {
      if (entity is File) result[p.relative(entity.path, from: workspace.path)] = entity.readAsBytesSync();
    }
    return result;
  }

  group('preview-dialect refusal', () {
    test('a headerless MEMORY.md is refused with the detected paths and the operator action', () async {
      File(p.join(workspace.path, 'MEMORY.md')).writeAsStringSync('## general\n- [2026-08-10 10:00] Preview fact\n');
      File(p.join(workspace.path, 'learnings.md')).writeAsStringSync('- [2026-08-10 10:00] Preview learning\n');
      File(p.join(workspace.path, 'memory', '2026-08-10.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('## 10:00 — "Chat"\n');
      final before = workspaceBytes();

      final report = await withPreflight((preflight) async {
        try {
          await preflight.preflight();
          fail('preflight accepted a preview-dialect workspace');
        } on MemoryPreflightException catch (error) {
          return error.report;
        }
      });

      expect(report, contains('Stage: legacy-dialect-detected'));
      expect(report, contains('MEMORY.md'));
      expect(report, contains('learnings.md'));
      expect(report, contains('memory/2026-08-10.md'));
      expect(report, contains(MemoryPreflight.lastConvertingRelease));
      expect(utf8.encode(report).length, lessThanOrEqualTo(MemoryPreflight.maxReportBytes));
      expect(workspaceBytes(), before);
    });

    test('legacy sources without a MEMORY.md get the same actionable message', () async {
      for (final path in ['memory/2026-08-19.md', 'learnings.md', 'MEMORY.archive.md']) {
        final scoped = Directory(p.join(workspace.path, path.replaceAll('/', '-')))..createSync(recursive: true);
        File(p.join(scoped.path, path))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('- [2026-08-19 09:00] Preview entry\n');
        final corpus = MemoryCorpusService(workspaceDir: scoped.path);
        addTearDown(corpus.close);

        await expectLater(
          MemoryPreflight(workspaceDir: scoped.path, corpusService: corpus).preflight(),
          throwsA(
            isA<MemoryPreflightException>()
                .having((error) => error.report, 'report', contains('Stage: legacy-dialect-detected'))
                .having((error) => error.report, 'report', contains(path))
                .having((error) => error.report, 'report', isNot(contains('MEMORY.md is missing'))),
          ),
          reason: path,
        );
        expect(File(p.join(scoped.path, 'MEMORY.md')).existsSync(), isFalse, reason: path);
      }
    });
  });

  group('canonical workspace', () {
    test('a canonical workspace whose index lost its header is not mistaken for the preview dialect', () async {
      await withPreflight((preflight) => preflight.preflight());
      await _seedTopicEntry(workspace.path, summary: 'Canonical fact');
      await withPreflight((preflight) => preflight.preflight());
      // learnings.md / MEMORY.archive.md / memory/<date>.md are canonical member
      // paths too, so a damaged index must not read as a downgrade instruction.
      final memory = File(p.join(workspace.path, 'MEMORY.md'));
      memory.writeAsStringSync(memory.readAsStringSync().replaceFirst('$canonicalMemoryHeader\n', ''));

      await expectLater(
        withPreflight((preflight) => preflight.preflight()),
        throwsA(
          isA<MemoryPreflightException>()
              .having((error) => error.stage, 'stage', isNot(MemoryPreflight.legacyDialectStage))
              .having((error) => error.report, 'report', isNot(contains(MemoryPreflight.lastConvertingRelease))),
        ),
      );
    });

    test('an empty workspace adopts an empty canonical corpus', () async {
      final result = await withPreflight((preflight) => preflight.preflight());

      expect(result.status, MemoryPreflightStatus.alreadyCurrent);
      expect(result.collectionRevision, 1);
      expect(result.render(), contains('Memory preflight: alreadyCurrent'));
      expect(File(p.join(workspace.path, 'MEMORY.md')).readAsStringSync(), startsWith('$canonicalMemoryHeader\n'));
    });

    test('a supported stopped-runtime edit reconciles and reports the new revision', () async {
      await withPreflight((preflight) => preflight.preflight());
      await _seedTopicEntry(workspace.path, summary: 'Before stopped edit');
      final priorRevision = await withPreflight((preflight) async => (await preflight.preflight()).collectionRevision);

      for (final path in ['MEMORY.md', 'memory/topics/general.md']) {
        final file = File(p.join(workspace.path, path));
        file.writeAsStringSync(file.readAsStringSync().replaceAll('Before stopped edit', 'After stopped edit'));
      }

      final result = await withPreflight((preflight) => preflight.preflight());

      expect(result.status, MemoryPreflightStatus.reconciled);
      expect(result.collectionRevision, priorRevision + 1);
      expect(result.render(), contains('supported canonical member changed'));
      expect(Directory(p.join(workspace.path, '.dartclaw-memory-migration-snapshot')).existsSync(), isFalse);
    });

    // errors.md joined the corpus in this release with no earlier
    // converter, so an existing canonical workspace's legacy file must become a
    // canonical error document at startup rather than fail hydration.
    test('a legacy errors.md becomes canonical error records without operator action', () async {
      await withPreflight((preflight) => preflight.preflight());
      File(p.join(workspace.path, 'errors.md')).writeAsStringSync(
        'Operator note kept verbatim.\n'
        '## [2026-08-10T10:00:00.000Z] GUARD_BLOCK\n'
        '- Session: sess-1\n'
        '- Context: Blocked prompt injection\n'
        '  ## [forged] continuation\n'
        '\n'
        '## [2026-08-10T11:00:00.000Z] TURN_FAILURE\n'
        '- Session: sess-2\n'
        '- Context: Agent crashed\n'
        '- Resolution: Retried successfully\n'
        '\n',
      );

      final result = await withPreflight((preflight) => preflight.preflight());

      expect(result.status, MemoryPreflightStatus.reconciled);
      expect(result.render(), contains('error errors.md'));
      final document = const MemoryMarkdownCodec().parse(File(p.join(workspace.path, 'errors.md')).readAsStringSync());
      expect(document, isA<MemoryErrorDocument>());
      final entries = (document as MemoryErrorDocument).entries;
      expect(entries.map((entry) => entry.summary), ['GUARD_BLOCK', 'TURN_FAILURE']);
      expect(entries.first.content, 'Blocked prompt injection\n## [forged] continuation');
      expect(entries.first.created, DateTime.utc(2026, 8, 10, 10));
      expect(entries.first.provenance.originKind, MemoryOriginKind.migration);
      expect(entries.first.provenance.sessionRef, 'sess-1');
      expect(entries.last.content, 'Agent crashed\n\nResolution: Retried successfully');
      expect(
        File(p.join(workspace.path, 'memory', 'legacy', 'errors.md')).readAsStringSync(),
        'Operator note kept verbatim.\n',
      );

      final settled = await withPreflight((preflight) => preflight.preflight());
      expect(settled.status, MemoryPreflightStatus.alreadyCurrent);
    });

    // Errors are written from failure contexts; a stray byte must convert, not
    // strand the file at a member path the authority then refuses to hydrate.
    test('a legacy errors.md holding a malformed byte still converts', () async {
      await withPreflight((preflight) => preflight.preflight());
      File(p.join(workspace.path, 'errors.md')).writeAsBytesSync([
        ...utf8.encode('## [2026-08-10T10:00:00.000Z] GUARD_BLOCK\n- Context: broken '),
        0x80,
        ...utf8.encode(' byte\n'),
      ]);

      final result = await withPreflight((preflight) => preflight.preflight());

      expect(result.status, MemoryPreflightStatus.reconciled);
      final document = const MemoryMarkdownCodec().parse(File(p.join(workspace.path, 'errors.md')).readAsStringSync());
      expect((document as MemoryErrorDocument).entries.single.summary, 'GUARD_BLOCK');
    });

    test('an already canonical errors.md is left byte-identical', () async {
      await withPreflight((preflight) => preflight.preflight());
      final rendered = const MemoryMarkdownCodec().render(MemoryErrorDocument());
      File(p.join(workspace.path, 'errors.md')).writeAsStringSync(rendered);
      await withPreflight((preflight) => preflight.preflight());
      final before = workspaceBytes();

      final result = await withPreflight((preflight) => preflight.preflight());

      expect(result.status, MemoryPreflightStatus.alreadyCurrent);
      expect(workspaceBytes(), before);
    });

    test('a canonical workspace re-reports as current without touching bytes', () async {
      await withPreflight((preflight) => preflight.preflight());
      await _seedTopicEntry(workspace.path, summary: 'Stable canonical fact');
      await withPreflight((preflight) => preflight.preflight());
      final before = workspaceBytes();

      final result = await withPreflight((preflight) => preflight.preflight());

      expect(result.status, MemoryPreflightStatus.alreadyCurrent);
      expect(workspaceBytes(), before);
    });
  });
}

/// Commits one canonical topic entry through the shared corpus authority.
Future<void> _seedTopicEntry(String workspaceDir, {required String summary}) async {
  final corpus = MemoryCorpusService(workspaceDir: workspaceDir);
  try {
    await corpus.updateFiles<int>(
      paths: const [],
      prepare: (_) => throw StateError('canonical workspace'),
      prepareCanonical: (current) {
        final updated = DateTime.utc(2026, 8, 10, 10);
        const id = 'b7c1e2d4-3f5a-4b6c-8d9e-0a1b2c3d4e5f';
        final entry = CanonicalMemoryEntry(
          id: id,
          revision: 1,
          topic: 'general',
          summary: summary,
          content: summary,
          created: updated,
          updated: updated,
          provenance: MemorySourceRef(sourceLocator: 'test-seed'),
        );
        return MemoryCorpusMutation(
          value: 0,
          corpus: CanonicalMemoryCorpus(
            index: MemoryIndexDocument(
              metadata: current.index.metadata,
              entries: [MemoryIndexEntry(id: id, revision: 1, topic: 'general', summary: summary, updated: updated)],
            ),
            topics: [
              MemoryTopicDocument(topic: 'general', entries: [entry]),
            ],
          ),
        );
      },
      bootstrapCanonical: true,
    );
  } finally {
    await corpus.close();
  }
}
