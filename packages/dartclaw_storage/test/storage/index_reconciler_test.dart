import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_storage/src/storage/index_reconciler.dart' show IndexReconcileTransition;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String targetPath;
  late IndexHealthStore health;

  setUp(() {
    root = Directory.systemTemp.createTempSync('index_reconciler_');
    targetPath = p.join(root.path, 'search.db');
    health = IndexHealthStore(workspaceDir: root.path, now: () => DateTime.utc(2026, 8, 12));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('validated empty corpus is healthy with exact zero rows', () async {
    final result = await CanonicalIndexReconciler(
      targetPath: targetPath,
      healthStore: health,
    ).reconcile(corpus: _corpus(), canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7');

    expect(result.rowCount, 0);
    expect(result.health.state, IndexHealthState.healthy);
    expect(result.health.indexRevision, 7);
    final db = openSearchDb(targetPath);
    expect(db.select('SELECT COUNT(*) AS count FROM memory_chunks').single['count'], 0);
    db.close();
  });

  test('complete validation preserves canonical row identity', () async {
    final corpus = _corpus(withEntry: true);

    final result = await CanonicalIndexReconciler(
      targetPath: targetPath,
      healthStore: health,
    ).reconcile(corpus: corpus, canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7');

    expect(result.rowCount, 1);
    final db = openSearchDb(targetPath);
    final row = db.select('SELECT * FROM memory_chunks').single;
    expect(
      (row['role'], row['locator'], row['entry_id'], row['entry_revision'], row['provenance']),
      ('topic', '22222222-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222', 3, 'manual:test'),
    );
    db.close();
  });

  test('batched current fast path proves exact rows and complete canonical authentication', () async {
    final corpus = _corpus(withEntry: true);
    final expected = MemoryService.canonicalIndexRows(corpus);
    final reconciler = CanonicalIndexReconciler(targetPath: targetPath, healthStore: health);
    await reconciler.reconcileBatched(
      rowBatches: () => Stream.value(expected),
      canonicalRevision: 7,
      canonicalFingerprint: 'fingerprint-7',
    );
    var authenticated = 0;
    final current = await reconciler.ensureCurrentBatched(
      rowBatches: () => Stream.value(expected),
      canonicalRevision: 7,
      canonicalFingerprint: 'fingerprint-7',
      authenticateComplete: () async => authenticated++,
    );
    expect((current.rowCount, authenticated), (1, 1));

    final db = openSearchDb(targetPath);
    db.execute("UPDATE memory_chunks SET text = 'tampered'");
    db.close();
    authenticated = 0;
    final repaired = await reconciler.ensureCurrentBatched(
      rowBatches: () => Stream.value(expected),
      canonicalRevision: 7,
      canonicalFingerprint: 'fingerprint-7',
      authenticateComplete: () async => authenticated++,
    );
    expect((repaired.rowCount, authenticated), (1, 1));
    final repairedDb = openSearchDb(targetPath);
    expect(repairedDb.select('SELECT text FROM memory_chunks').single['text'], 'Durable searchable fact');
    repairedDb.close();
  });

  test('complete authentication failure prevents swap and healthy publication', () async {
    final target = File(targetPath)..writeAsBytesSync([9, 1, 1]);
    await expectLater(
      CanonicalIndexReconciler(targetPath: targetPath, healthStore: health).reconcileBatched(
        rowBatches: () => Stream.value(MemoryService.canonicalIndexRows(_corpus(withEntry: true))),
        canonicalRevision: 7,
        canonicalFingerprint: 'fingerprint-7',
        authenticateComplete: () async => throw StateError('canonical changed'),
      ),
      throwsStateError,
    );
    expect(target.readAsBytesSync(), [9, 1, 1]);
    expect(
      (await health.read(canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7')).state,
      IndexHealthState.degraded,
    );
  });

  test('audit records participate in canonical identity but produce no derived rows', () async {
    final corpus = _corpus(withAudit: true);

    final result = await CanonicalIndexReconciler(
      targetPath: targetPath,
      healthStore: health,
    ).reconcile(corpus: corpus, canonicalRevision: 7, canonicalFingerprint: 'audit-fingerprint-7');

    expect(result.rowCount, 0);
    final db = openSearchDb(targetPath);
    expect(db.select('SELECT COUNT(*) AS count FROM memory_chunks').single['count'], 0);
    db.close();
  });

  for (final transition in IndexReconcileTransition.values) {
    test('failure at ${transition.name} preserves target and converges on retry', () async {
      final target = File(targetPath)..writeAsBytesSync([4, 2, 4, 2]);

      await expectLater(
        CanonicalIndexReconciler(
          targetPath: targetPath,
          healthStore: health,
          transitionHook: (current) async {
            if (current == transition) throw StateError('fault ${transition.name}');
          },
        ).reconcile(corpus: _corpus(), canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7'),
        throwsStateError,
      );

      expect(target.readAsBytesSync(), [4, 2, 4, 2]);
      expect(root.listSync().where((entity) => p.basename(entity.path).contains('dartclaw-rebuild')), isEmpty);
      expect(
        (await health.read(canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7')).state,
        IndexHealthState.degraded,
      );

      final retry = await CanonicalIndexReconciler(
        targetPath: targetPath,
        healthStore: health,
      ).reconcile(corpus: _corpus(), canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7');
      expect(retry.health.state, IndexHealthState.healthy);
    });
  }

  test('health publication failure rolls back the swapped target', () async {
    final target = File(targetPath)..writeAsBytesSync([9, 8, 7]);
    final failingHealth = IndexHealthStore(
      workspaceDir: root.path,
      writer: (file, evidence) async {
        if (evidence['state'] == 'healthy') throw StateError('health publication unavailable');
        await atomicWriteJson(file, evidence);
      },
    );

    await expectLater(
      CanonicalIndexReconciler(
        targetPath: targetPath,
        healthStore: failingHealth,
      ).reconcile(corpus: _corpus(), canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7'),
      throwsStateError,
    );

    expect(target.readAsBytesSync(), [9, 8, 7]);
    expect(root.listSync().where((entity) => p.basename(entity.path).contains('dartclaw-rebuild')), isEmpty);
  });

  test('replacement failure after moving the sibling restores prior target bytes', () async {
    final target = File(targetPath)..writeAsBytesSync([6, 5, 4]);

    await expectLater(
      CanonicalIndexReconciler(
        targetPath: targetPath,
        healthStore: health,
        replaceFile: (sibling, destination) {
          sibling.renameSync(destination);
          throw StateError('replacement publication unavailable');
        },
      ).reconcile(corpus: _corpus(), canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7'),
      throwsStateError,
    );

    expect(target.readAsBytesSync(), [6, 5, 4]);
    expect(root.listSync().where((entity) => p.basename(entity.path).contains('dartclaw-rebuild')), isEmpty);
  });

  test('persisted rebuilding evidence reopens as interrupted degradation', () async {
    await health.recordRebuilding(canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7');
    expect(
      (await health.read(canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7')).state,
      IndexHealthState.rebuilding,
    );

    final reopened = await IndexHealthStore(workspaceDir: root.path)
        .read(canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7');

    expect(reopened.state, IndexHealthState.degraded);
    expect(reopened.failureStage, 'interrupted');
  });

  test('incremental degradation retains last validated identity across restart', () async {
    await health.recordHealthy(canonicalRevision: 41, canonicalFingerprint: 'fingerprint-41');
    final validatedAt = (await health.read(canonicalRevision: 41, canonicalFingerprint: 'fingerprint-41')).validatedAt;

    await health.recordDegraded(
      canonicalRevision: 42,
      canonicalFingerprint: 'fingerprint-42',
      stage: 'incremental',
      reason: StateError('projection unavailable'),
    );

    final reopened = await IndexHealthStore(workspaceDir: root.path)
        .read(canonicalRevision: 42, canonicalFingerprint: 'fingerprint-42');
    expect(reopened.state, IndexHealthState.degraded);
    expect(reopened.canonicalRevision, 42);
    expect(reopened.canonicalFingerprint, 'fingerprint-42');
    expect(reopened.indexRevision, 41);
    expect(reopened.indexFingerprint, 'fingerprint-41');
    expect(reopened.validatedAt, validatedAt);
    expect(reopened.failureStage, 'incremental');
  });
}

CanonicalMemoryCorpus _corpus({bool withEntry = false, bool withAudit = false}) {
  final entries = withEntry
      ? <CanonicalMemoryEntry>[
          CanonicalMemoryEntry(
            id: '22222222-2222-4222-8222-222222222222',
            revision: 3,
            created: DateTime.utc(2026, 8, 10),
            updated: DateTime.utc(2026, 8, 11),
            provenance: MemorySourceRef(sourceLocator: 'manual:test'),
            topic: 'general',
            summary: 'Durable fact',
            content: 'Durable searchable fact',
          ),
        ]
      : <CanonicalMemoryEntry>[];
  return CanonicalMemoryCorpus(
    index: MemoryIndexDocument(
      metadata: MemoryCollectionMetadata(collectionId: '11111111-1111-4111-8111-111111111111', revision: 7),
      entries: [
        for (final entry in entries)
          MemoryIndexEntry(
            id: entry.id,
            revision: entry.revision,
            topic: entry.topic,
            summary: entry.summary,
            updated: entry.updated,
          ),
      ],
    ),
    topics: [if (entries.isNotEmpty) MemoryTopicDocument(topic: 'general', entries: entries)],
    audit: withAudit
        ? MemoryAuditDocument(
            records: [
              MemoryDeletionAudit(
                entryId: '33333333-3333-4333-8333-333333333333',
                deletedAt: DateTime.utc(2026, 8, 12),
                reason: 'Removal requested',
                provenance: MemorySourceRef(sourceLocator: 'manual:test'),
              ),
            ],
          )
        : null,
  );
}
