@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import '../storage/postgres_live_support.dart';

void main() {
  test('real pgvector matches SQLite while isolating owner, corpus, fingerprint, and dimension', () async {
    await withPostgresBackend((backend, namespace) async {
      await PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: backend.databaseIdentity);
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: backend.databaseIdentity);

      final path = (await backend.query(
        "SELECT current_schema() AS app_schema, current_setting('search_path') AS search_path",
      )).single;
      expect(path, {'app_schema': namespace, 'search_path': namespace});

      final postgresMemory = PostgresVectorIndex(backend, table: VectorTable.memoryChunks);
      final postgresConversation = PostgresVectorIndex(backend, table: VectorTable.conversationChunks);
      final sqlite = SqliteBackend.openInMemory();
      try {
        await SqliteSchemaGate.prepareVectors(sqlite, storeName: 'vectors.db');
        final sqliteMemory = SqliteVectorIndex(sqlite, table: VectorTable.memoryChunks);
        final records = [
          _record('tie-a', 1, const [1, 0]),
          _record('tie-b', 0, const [1, 0]),
          _record('tie-a', 0, const [1, 0]),
          _record('roundtrip', 0, const [0.1, -0.2]),
          _record('orthogonal', 0, const [0, 1]),
          _record('negative', 0, const [-1, 0]),
          _record('zero', 0, const [0, 0]),
          _record('wrong-fingerprint', 0, const [1, 0], fingerprint: 'other-model'),
          _record('wrong-dimension', 0, const [1, 0, 0]),
        ];
        await postgresMemory.upsert(records, userId: 'owner');
        await sqliteMemory.upsert(records, userId: 'owner');
        await postgresMemory.upsert([
          _record('other-owner', 0, const [1, 0]),
        ], userId: 'other');
        await postgresConversation.upsert([
          _record('other-corpus', 0, const [1, 0]),
        ], userId: 'owner');

        final listed = await postgresMemory.list(userId: 'owner');
        expect(listed, hasLength(records.length));
        final roundTrip = listed.singleWhere((record) => record.documentId == 'roundtrip');
        _expectVectorClose(roundTrip.vector, Float32List.fromList(const [0.1, -0.2]));
        expect((await postgresMemory.list(userId: 'other')).single.documentId, 'other-owner');
        expect((await postgresConversation.list(userId: 'owner')).single.documentId, 'other-corpus');

        final postgresMatches = await postgresMemory.search(const [1, 0], userId: 'owner', modelFingerprint: 'model');
        final sqliteMatches = await sqliteMemory.search(const [1, 0], userId: 'owner', modelFingerprint: 'model');
        expect(_matchIdentities(postgresMatches), [
          'tie-a:0',
          'tie-a:1',
          'tie-b:0',
          'roundtrip:0',
          'orthogonal:0',
          'negative:0',
        ]);
        expect(_matchIdentities(postgresMatches), _matchIdentities(sqliteMatches));
        for (var index = 0; index < postgresMatches.length; index++) {
          expect(postgresMatches[index].score, closeTo(sqliteMatches[index].score, 1e-6));
        }
        expect(
          _matchIdentities(
            await postgresMemory.search(const [1, 0], userId: 'owner', modelFingerprint: 'model', limit: 2),
          ),
          ['tie-a:0', 'tie-a:1'],
        );
        expect(await postgresMemory.search(const [0, 0], userId: 'owner', modelFingerprint: 'model'), isEmpty);
      } finally {
        await sqlite.close();
      }
    });
  });

  test('real PostgreSQL rolls back failed upsert and complete replacement', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: backend.databaseIdentity);
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: backend.databaseIdentity);
      final memory = PostgresVectorIndex(backend, table: VectorTable.memoryChunks);
      final conversation = PostgresVectorIndex(backend, table: VectorTable.conversationChunks);
      await memory.upsert([
        _record('prior', 0, const [1, 0]),
      ], userId: 'owner');
      await memory.upsert([
        _record('other-owner', 0, const [0, 1]),
      ], userId: 'other');
      await conversation.upsert([
        _record('other-corpus', 0, const [-1, 0]),
      ], userId: 'owner');
      final before = await _storedRows(backend);

      final upsertBackend = FailingVectorMutationBackend(backend, failAt: 2);
      final failingUpsert = PostgresVectorIndex(upsertBackend, table: VectorTable.memoryChunks);
      await expectLater(
        failingUpsert.upsert(
          [
            _record('new', 0, const [0.5, 0.5]),
          ],
          userId: 'owner',
          retire: {VectorIdentity(documentId: 'prior', chunkIndex: 0)},
        ),
        throwsStateError,
      );
      expect(upsertBackend.mutationOutsideTransaction, isFalse);
      expect(await _storedRows(backend), before);

      final replaceBackend = FailingVectorMutationBackend(backend, failAt: 2);
      final failingReplace = PostgresVectorIndex(replaceBackend, table: VectorTable.memoryChunks);
      await expectLater(
        failingReplace.replaceAll([
          _record('replacement', 0, const [0.25, 0.75]),
        ], userId: 'owner'),
        throwsStateError,
      );
      expect(replaceBackend.mutationOutsideTransaction, isFalse);
      expect(await _storedRows(backend), before);
    });
  });
}

VectorRecord _record(String documentId, int chunkIndex, List<double> vector, {String fingerprint = 'model'}) =>
    VectorRecord(
      documentId: documentId,
      chunkIndex: chunkIndex,
      contentHash: '$documentId-$chunkIndex-hash',
      modelFingerprint: fingerprint,
      vector: vector,
    );

List<String> _matchIdentities(List<VectorMatch> matches) => [
  for (final match in matches) '${match.documentId}:${match.chunkIndex}',
];

void _expectVectorClose(List<double> actual, List<double> expected) {
  expect(actual, hasLength(expected.length));
  for (var index = 0; index < expected.length; index++) {
    expect(actual[index], closeTo(expected[index], 1e-6));
  }
}

Future<List<Map<String, Object?>>> _storedRows(PostgresBackend backend) => backend.query('''
      SELECT 'memory' AS corpus, user_id, document_id, chunk_index,
             content_hash, model_fingerprint, dimension,
             CAST(embedding AS text) AS embedding
      FROM memory_vectors
      UNION ALL
      SELECT 'conversation', user_id, document_id, chunk_index,
             content_hash, model_fingerprint, dimension,
             CAST(embedding AS text)
      FROM conversation_vectors
      ORDER BY corpus, user_id, document_id, chunk_index
    ''');
