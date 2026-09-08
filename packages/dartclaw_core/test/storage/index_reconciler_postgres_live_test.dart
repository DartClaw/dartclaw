@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'postgres_live_support.dart';

void main() {
  for (final fault in const {
    IndexReconcileTransition.populated: 'populate',
    IndexReconcileTransition.validated: 'validate',
    IndexReconcileTransition.beforeSwap: 'swap',
  }.entries) {
    test('a ${fault.key.name} fault preserves the prior PostgreSQL index', () async {
      await withPostgresBackend((backend, _) async {
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        final index = _index(backend);
        await index.replaceAll(_documents('old', 3), userId: 'owner');
        final workspace = Directory.systemTemp.createTempSync('postgres_reconcile_fault_');
        try {
          final health = IndexHealthStore(workspaceDir: workspace.path);
          await health.recordHealthy(canonicalRevision: 1, canonicalFingerprint: 'old');
          final reconciler = CanonicalIndexReconciler(
            healthStore: health,
            target: _target(backend),
            transitionHook: (transition) async {
              if (transition == fault.key) throw StateError('fault at ${fault.key.name}');
            },
          );

          await expectLater(
            reconciler.reconcileBatched(
              rowBatches: () => Stream.value(_documents('new', 4)),
              canonicalRevision: 2,
              canonicalFingerprint: 'new',
            ),
            throwsStateError,
          );

          expect((await index.search('old', userId: 'owner')).map((result) => result.id).toSet(), {
            'old-0',
            'old-1',
            'old-2',
          });
          expect(await index.search('new', userId: 'owner'), isEmpty);
          final evidence = await health.read(canonicalRevision: 2, canonicalFingerprint: 'new');
          expect(evidence.state, IndexHealthState.degraded);
          expect(evidence.failureStage, fault.value);
        } finally {
          workspace.deleteSync(recursive: true);
        }
      });
    });
  }

  test('a clean PostgreSQL rebuild commits rows and all transitions', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      final index = _index(backend);
      await index.replaceAll(_documents('old', 3), userId: 'owner');
      final workspace = Directory.systemTemp.createTempSync('postgres_reconcile_clean_');
      try {
        final health = IndexHealthStore(workspaceDir: workspace.path);
        final transitions = <IndexReconcileTransition>[];
        final reconciler = CanonicalIndexReconciler(
          healthStore: health,
          target: _target(backend),
          transitionHook: (transition) async => transitions.add(transition),
        );

        final result = await reconciler.reconcileBatched(
          rowBatches: () => Stream.value(_documents('new', 4)),
          canonicalRevision: 2,
          canonicalFingerprint: 'new',
        );

        expect(result.rowCount, 4);
        expect(result.health.state, IndexHealthState.healthy);
        expect(transitions, IndexReconcileTransition.values);
        expect((await index.search('new', userId: 'owner')).map((result) => result.id).toSet(), {
          'new-0',
          'new-1',
          'new-2',
          'new-3',
        });
        expect(await index.search('old', userId: 'owner'), isEmpty);
      } finally {
        workspace.deleteSync(recursive: true);
      }
    });
  });

  test('current PostgreSQL evidence validates the live index without rebuilding', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      final documents = _documents('current', 2);
      await _index(backend).replaceAll(documents, userId: 'owner');
      final workspace = Directory.systemTemp.createTempSync('postgres_reconcile_current_');
      try {
        final health = IndexHealthStore(workspaceDir: workspace.path);
        await health.recordHealthy(canonicalRevision: 4, canonicalFingerprint: 'current');
        final reconciler = CanonicalIndexReconciler(
          healthStore: health,
          target: _target(backend),
          transitionHook: (_) async => throw StateError('fast path must not rebuild'),
        );

        final result = await reconciler.ensureCurrentBatched(
          rowBatches: () => Stream.value(documents),
          canonicalRevision: 4,
          canonicalFingerprint: 'current',
        );

        expect(result.rowCount, 2);
        expect(result.health.state, IndexHealthState.healthy);
      } finally {
        workspace.deleteSync(recursive: true);
      }
    });
  });
}

TransactionalRebuildTarget _target(DatabaseBackend backend) => TransactionalRebuildTarget(
  backend,
  indexFactory: (tx) =>
      PostgresFtsIndex.withinTransaction(tx, table: PostgresFtsTable.memoryChunks, language: 'english'),
);

PostgresFtsIndex _index(DatabaseBackend backend) =>
    PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: 'english');

List<SearchDocument> _documents(String prefix, int count) => [
  for (var index = 0; index < count; index++)
    SearchDocument(
      id: '$prefix-$index',
      chunks: ['$prefix searchable chunk $index'],
      metadata: {'source': '$prefix-$index', 'role': 'memory', 'provenance': 'unknown'},
      timestamp: DateTime.utc(2026, 1, index + 1),
    ),
];
