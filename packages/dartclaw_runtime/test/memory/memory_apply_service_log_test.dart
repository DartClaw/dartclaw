import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/memory/memory_apply_service.dart';
import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const _a = '00000000-0000-4000-8000-00000000000a';

void main() {
  late Directory workspace;
  late Database db;
  late MemoryService index;
  late MemoryCorpusService corpus;
  late MemorySourceRef provenance;

  setUp(() async {
    workspace = Directory.systemTemp.createTempSync('memory_apply_service_log_test_');
    db = sqlite3.openInMemory();
    index = MemoryService(db);
    corpus = MemoryCorpusService(workspaceDir: workspace.path);
    provenance = MemorySourceRef(
      originKind: MemoryOriginKind.curation,
      sourceLocator: 'session:curator',
      sourceEvent: 'turn:apply',
      caller: 'agent:main',
      sessionRef: 'curator',
    );
    await corpus.readCorpus();
  });

  tearDown(() async {
    await corpus.close();
    db.close();
    workspace.deleteSync(recursive: true);
  });

  MemoryApplyService service({MemoryIndexReconciler? reconcile}) => MemoryApplyService(
    corpus: corpus,
    now: () => DateTime.utc(2026, 8, 12, 12),
    createId: () => '00000000-0000-4000-8000-00000000000f',
    reconcileIndex:
        reconcile ??
        (committed, _, _, _, userId) {
          index.replaceMemoryRows(MemoryService.canonicalIndexRows(committed), userId: userId);
        },
  );

  group('operator log', () {
    List<LogRecord> captureApplyLog() {
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen((record) {
        if (record.loggerName == 'MemoryApplyService') records.add(record);
      });
      addTearDown(subscription.cancel);
      return records;
    }

    // The apply result reaches only the calling model; a scheduled curation run
    // refused every fire must still be visible to an operator reading the log.
    test('a refused change set is logged at WARNING with its failure kind and stage', () async {
      final records = captureApplyLog();
      final result = await service().apply(
        {
          'expectedRevision': 0,
          'operations': [
            {'op': 'remove', 'id': _a},
          ],
        },
        userId: 'owner',
        provenance: provenance,
      );

      expect(result['canonicalOutcome'], 'rejected');
      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
      expect(
        records.single.message,
        allOf(contains('rejected'), contains('session:curator'), contains('validation'), contains('1 operations')),
      );
    });

    test('a committed change set logs nothing at WARNING', () async {
      final records = captureApplyLog();
      final revision = (await corpus.manifest()).collectionRevision;
      final result = await service().apply(
        {
          'expectedRevision': revision,
          'operations': [
            {'kind': 'add', 'correlationId': 'add', 'topic': 'general', 'content': 'A new entry'},
          ],
        },
        userId: 'owner',
        provenance: provenance,
      );

      expect(result['canonicalOutcome'], 'committed');
      expect(records.where((record) => record.level >= Level.WARNING), isEmpty);
    });

    test('a committed change set whose derived-index reconciliation degraded is logged at WARNING', () async {
      final records = captureApplyLog();
      final revision = (await corpus.manifest()).collectionRevision;
      final result = await service(reconcile: (_, _, _, _, _) => throw StateError('index unavailable')).apply(
        {
          'expectedRevision': revision,
          'operations': [
            {'kind': 'add', 'correlationId': 'add', 'topic': 'general', 'content': 'A new entry'},
          ],
        },
        userId: 'owner',
        provenance: provenance,
      );

      expect(result['canonicalOutcome'], 'committed');
      expect(result['indexOutcome'], 'degraded');
      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
      expect(records.single.message, allOf(contains('committed'), contains('indexReconciliation')));
    });

    test('a stale expected revision is logged at INFO, not WARNING', () async {
      final records = captureApplyLog();
      final revision = (await corpus.manifest()).collectionRevision;
      final result = await service().apply(
        {
          'expectedRevision': revision + 5,
          'operations': [
            {'kind': 'add', 'correlationId': 'add', 'topic': 'general', 'content': 'A new entry'},
          ],
        },
        userId: 'owner',
        provenance: provenance,
      );

      expect(result['canonicalOutcome'], 'conflict');
      expect(records, hasLength(1));
      expect(records.single.level, Level.INFO);
      expect(records.single.message, contains('conflict'));
    });
  });
}
