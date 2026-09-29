import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late IndexHealthStore health;
  late _MemoryRebuildTarget target;

  setUp(() {
    root = Directory.systemTemp.createTempSync('index_reconciler_');
    health = IndexHealthStore(workspaceDir: root.path, now: () => DateTime.utc(2026, 8, 12));
    target = _MemoryRebuildTarget();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  CanonicalIndexReconciler reconciler({
    Future<void> Function(IndexReconcileTransition transition)? transitionHook,
    IndexHealthStore? healthStore,
  }) => CanonicalIndexReconciler(target: target, healthStore: healthStore ?? health, transitionHook: transitionHook);

  test('validated empty corpus is healthy with exact zero rows', () async {
    final result = await reconciler().reconcile(
      corpus: _corpus(),
      canonicalRevision: 7,
      canonicalFingerprint: 'fingerprint-7',
    );

    expect(result.rowCount, 0);
    expect(result.rebuilt, isTrue);
    expect(result.health.state, IndexHealthState.healthy);
    expect(result.health.indexRevision, 7);
    expect(await target.live.count(userId: 'owner'), 0);
  });

  test('complete validation preserves canonical row identity', () async {
    final result = await reconciler().reconcile(
      corpus: _corpus(withEntry: true),
      canonicalRevision: 7,
      canonicalFingerprint: 'fingerprint-7',
    );

    expect(result.rowCount, 1);
    final row = (await target.live.fetch(['22222222-2222-4222-8222-222222222222'], userId: 'owner')).single;
    expect(
      (
        row.metadata['role'],
        row.id,
        row.metadata['entry_id'],
        row.metadata['entry_revision'],
        row.metadata['provenance'],
      ),
      ('topic', '22222222-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222', '3', 'manual:test'),
    );
  });

  test('current fast path rebuilds a target whose canonical rows were tampered', () async {
    final corpus = _corpus(withEntry: true);
    await reconciler().reconcile(corpus: corpus, canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7');
    await target.live.replaceAll([
      SearchDocument(
        id: '22222222-2222-4222-8222-222222222222',
        chunks: const ['tampered'],
        metadata: const {
          'source': '22222222-2222-4222-8222-222222222222',
          'role': 'topic',
          'provenance': 'manual:test',
          'entry_id': '22222222-2222-4222-8222-222222222222',
          'entry_revision': '3',
        },
        timestamp: DateTime.utc(2026, 8, 10),
      ),
    ], userId: 'owner');

    final repaired = await reconciler().ensureCurrent(
      corpus: corpus,
      canonicalRevision: 7,
      canonicalFingerprint: 'fingerprint-7',
    );

    expect((repaired.rebuilt, repaired.rowCount, repaired.health.state), (true, 1, IndexHealthState.healthy));
    expect((await target.live.search('Durable', userId: 'owner')).single.chunk, 'Durable searchable fact');
  });

  test('batched current fast path proves exact rows and complete canonical authentication', () async {
    final expected = MemoryIndexProjection.documents(_corpus(withEntry: true));
    await reconciler().reconcileBatched(
      rowBatches: () => Stream.value(expected),
      canonicalRevision: 7,
      canonicalFingerprint: 'fingerprint-7',
    );
    var authenticated = 0;
    final current = await reconciler().ensureCurrentBatched(
      rowBatches: () => Stream.value(expected),
      canonicalRevision: 7,
      canonicalFingerprint: 'fingerprint-7',
      authenticateComplete: () async => authenticated++,
    );
    expect((current.rebuilt, current.rowCount, authenticated), (false, 1, 1));

    await target.live.replaceAll([
      SearchDocument(
        id: expected.single.id,
        chunks: const ['tampered'],
        metadata: expected.single.metadata,
        timestamp: expected.single.timestamp,
      ),
    ], userId: 'owner');
    authenticated = 0;
    final repaired = await reconciler().ensureCurrentBatched(
      rowBatches: () => Stream.value(expected),
      canonicalRevision: 7,
      canonicalFingerprint: 'fingerprint-7',
      authenticateComplete: () async => authenticated++,
    );
    expect((repaired.rebuilt, repaired.rowCount, authenticated), (true, 1, 1));
    expect((await target.live.fetch([expected.single.id], userId: 'owner')).single.chunks, expected.single.chunks);
  });

  test('complete authentication failure prevents publication and healthy evidence', () async {
    final prior = InMemoryFullTextIndex();
    await prior.upsert([_sentinel], userId: 'owner');
    target.liveOrNull = prior;

    await expectLater(
      reconciler().reconcileBatched(
        rowBatches: () => Stream.value(MemoryIndexProjection.documents(_corpus(withEntry: true))),
        canonicalRevision: 7,
        canonicalFingerprint: 'fingerprint-7',
        authenticateComplete: () async => throw StateError('canonical changed'),
      ),
      throwsStateError,
    );

    expect((await target.live.fetch([_sentinel.id], userId: 'owner')).single.chunks, _sentinel.chunks);
    expect(
      (await health.read(canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7')).state,
      IndexHealthState.degraded,
    );
  });

  test('audit records participate in canonical identity but produce no derived rows', () async {
    final result = await reconciler().reconcile(
      corpus: _corpus(withAudit: true),
      canonicalRevision: 7,
      canonicalFingerprint: 'audit-fingerprint-7',
    );

    expect(result.rowCount, 0);
    expect(await target.live.count(userId: 'owner'), 0);
  });

  for (final transition in IndexReconcileTransition.values.where(
    (value) => value != IndexReconcileTransition.swapped,
  )) {
    test('failure at ${transition.name} preserves the target and converges on retry', () async {
      final prior = InMemoryFullTextIndex();
      await prior.upsert([_sentinel], userId: 'owner');
      target.liveOrNull = prior;

      await expectLater(
        reconciler(
          transitionHook: (current) async {
            if (current == transition) throw StateError('fault ${transition.name}');
          },
        ).reconcile(corpus: _corpus(), canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7'),
        throwsStateError,
      );

      expect((await target.live.fetch([_sentinel.id], userId: 'owner')).single.chunks, _sentinel.chunks);
      expect(
        (await health.read(canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7')).state,
        IndexHealthState.degraded,
      );

      final retry = await reconciler().reconcile(
        corpus: _corpus(),
        canonicalRevision: 7,
        canonicalFingerprint: 'fingerprint-7',
      );
      expect(retry.health.state, IndexHealthState.healthy);
    });
  }

  test('failure after publication leaves the replacement degraded and converges on retry', () async {
    await expectLater(
      reconciler(
        transitionHook: (transition) async {
          if (transition == IndexReconcileTransition.swapped) throw StateError('publication observer failed');
        },
      ).reconcile(corpus: _corpus(withEntry: true), canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7'),
      throwsStateError,
    );

    expect(await target.live.count(userId: 'owner'), 1);
    expect(
      (await health.read(canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7')).state,
      IndexHealthState.degraded,
    );
    expect(
      (await reconciler().ensureCurrent(
        corpus: _corpus(withEntry: true),
        canonicalRevision: 7,
        canonicalFingerprint: 'fingerprint-7',
      )).health.state,
      IndexHealthState.healthy,
    );
  });

  test('health publication failure retains the already-published derived rows', () async {
    final failingHealth = IndexHealthStore(
      workspaceDir: root.path,
      writer: (file, evidence) async {
        if (evidence['state'] == 'healthy') throw StateError('health publication unavailable');
        await atomicWriteJson(file, evidence);
      },
    );

    await expectLater(
      reconciler(healthStore: failingHealth)
          .reconcile(corpus: _corpus(withEntry: true), canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7'),
      throwsStateError,
    );

    expect(await target.live.count(userId: 'owner'), 1);
  });

  test('target publication failure preserves the prior target', () async {
    final prior = InMemoryFullTextIndex();
    await prior.upsert([_sentinel], userId: 'owner');
    target
      ..liveOrNull = prior
      ..failPublication = true;

    await expectLater(
      reconciler().reconcile(
        corpus: _corpus(withEntry: true),
        canonicalRevision: 7,
        canonicalFingerprint: 'fingerprint-7',
      ),
      throwsStateError,
    );

    expect((await target.live.fetch([_sentinel.id], userId: 'owner')).single.chunks, _sentinel.chunks);
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

final class _MemoryRebuildTarget implements IndexRebuildTarget {
  InMemoryFullTextIndex? liveOrNull;
  var failPublication = false;

  InMemoryFullTextIndex get live => liveOrNull ?? (throw StateError('target is absent'));

  @override
  Future<bool> isPresent() async => liveOrNull != null;

  @override
  Future<T> validateLive<T>(Future<T> Function(FullTextIndex index) body) => body(live);

  @override
  Future<T> rebuild<T>({
    required Future<T> Function(FullTextIndex index, Future<void> Function() populated) populateAndValidate,
    required Future<void> Function(IndexReconcileTransition transition) transition,
  }) async {
    final candidate = InMemoryFullTextIndex();
    await transition(IndexReconcileTransition.siblingCreated);
    final result = await populateAndValidate(candidate, () => transition(IndexReconcileTransition.populated));
    await transition(IndexReconcileTransition.validated);
    await transition(IndexReconcileTransition.beforeClose);
    await transition(IndexReconcileTransition.closed);
    await transition(IndexReconcileTransition.beforeSwap);
    if (failPublication) throw StateError('target publication unavailable');
    liveOrNull = candidate;
    await transition(IndexReconcileTransition.swapped);
    return result;
  }
}

final _sentinel = SearchDocument(
  id: 'prior',
  chunks: const ['prior target'],
  metadata: const {'source': 'prior', 'role': 'memory', 'provenance': 'unknown'},
  timestamp: DateTime.utc(2025),
);

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
