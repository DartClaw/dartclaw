import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'vector_index_contract.dart';

void main() {
  runVectorIndexContract('SQLite', () async {
    final delegate = SqliteBackend.openInMemory();
    await SqliteSchemaGate.prepareVectors(delegate, storeName: 'vectors.db');
    final backend = RecordingDatabaseBackend(delegate);
    return (
      memory: SqliteVectorIndex(backend, table: VectorTable.memoryChunks),
      conversation: SqliteVectorIndex(backend, table: VectorTable.conversationChunks),
      database: backend,
      close: backend.close,
    );
  });

  test('stores embeddings as little-endian float32 blobs with explicit dimensions', () async {
    final backend = SqliteBackend.openInMemory();
    addTearDown(backend.close);
    await SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db');
    final index = SqliteVectorIndex(backend, table: VectorTable.memoryChunks);
    await index.upsert([
      VectorRecord(
        documentId: 'record',
        chunkIndex: 0,
        contentHash: 'hash',
        modelFingerprint: 'model',
        vector: [1.5, -2.25],
      ),
    ], userId: 'owner');

    final row = (await backend.query('SELECT dimension, embedding FROM memory_vectors')).single;
    expect(row['dimension'], 2);
    final bytes = row['embedding'] as Uint8List;
    expect(bytes, [0, 0, 192, 63, 0, 0, 16, 192]);
  });

  test('corrupt SQLite representations fail with content-free derived recovery guidance', () async {
    final backend = SqliteBackend.openInMemory();
    addTearDown(backend.close);
    await SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db');
    await backend.execute(
      '''INSERT INTO memory_vectors
         (user_id, document_id, chunk_index, content_hash, model_fingerprint, dimension, embedding)
         VALUES (?, ?, ?, ?, ?, ?, ?)''',
      [
        'owner',
        'secret-document',
        0,
        'secret-hash',
        'model',
        2,
        Uint8List.fromList([0, 0, 128, 63]),
      ],
    );
    final index = SqliteVectorIndex(backend, table: VectorTable.memoryChunks);

    await expectLater(
      index.list(userId: 'owner'),
      throwsA(
        isA<SchemaIncompatibleException>()
            .having((error) => error.toString(), 'guidance', contains('derived vector projection'))
            .having((error) => error.toString(), 'content', isNot(contains('secret'))),
      ),
    );
  });

  test('replaceAll rollback preserves both corpora and owners byte-for-byte', () async {
    final backend = SqliteBackend.openInMemory();
    addTearDown(backend.close);
    await SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db');
    final memory = SqliteVectorIndex(backend, table: VectorTable.memoryChunks);
    final conversation = SqliteVectorIndex(backend, table: VectorTable.conversationChunks);
    await memory.upsert([
      _record('target-a', [1.25, -2.5]),
      _record('target-b', [3.5, 4.75]),
    ], userId: 'owner');
    await memory.upsert([
      _record('other-owner', [-5.25, 6.5]),
    ], userId: 'other');
    await conversation.upsert([
      _record('other-corpus', [7.75, -8.5]),
    ], userId: 'owner');
    final before = await _storedVectorRows(backend);
    final failing = FailingVectorMutationBackend(backend, failAt: 2);
    final failingIndex = SqliteVectorIndex(failing, table: VectorTable.memoryChunks);

    await expectLater(
      failingIndex.replaceAll([
        _record('replacement', [9.25, 10.5]),
      ], userId: 'owner'),
      throwsStateError,
    );
    expect(failing.mutationOutsideTransaction, isFalse);
    expect(await _storedVectorRows(backend), before);
  });

  test('upsert rollback preserves prior owner rows', () async {
    final backend = SqliteBackend.openInMemory();
    addTearDown(backend.close);
    await SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db');
    final index = SqliteVectorIndex(backend, table: VectorTable.memoryChunks);
    await index.upsert([
      _record('prior', [1]),
    ], userId: 'owner');
    final failing = FailingVectorMutationBackend(backend, failAt: 2);
    final failingIndex = SqliteVectorIndex(failing, table: VectorTable.memoryChunks);

    await expectLater(
      failingIndex.upsert(
        [
          _record('new', [2]),
        ],
        userId: 'owner',
        retire: {VectorIdentity(documentId: 'prior', chunkIndex: 0)},
      ),
      throwsStateError,
    );
    expect(failing.mutationOutsideTransaction, isFalse);
    expect((await index.list(userId: 'owner')).map((record) => record.documentId), ['prior']);
  });
}

VectorRecord _record(String id, List<double> vector) =>
    VectorRecord(documentId: id, chunkIndex: 0, contentHash: '$id-hash', modelFingerprint: 'model', vector: vector);

Future<List<List<Object?>>> _storedVectorRows(DatabaseBackend backend) async {
  final rows = await backend.query('''
    SELECT 'conversation_vectors' AS vector_table,
           user_id, document_id, chunk_index, content_hash, model_fingerprint, dimension, embedding
    FROM conversation_vectors
    UNION ALL
    SELECT 'memory_vectors' AS vector_table,
           user_id, document_id, chunk_index, content_hash, model_fingerprint, dimension, embedding
    FROM memory_vectors
    ORDER BY vector_table, user_id, document_id, chunk_index
  ''');
  return [
    for (final row in rows)
      [
        row['vector_table'],
        row['user_id'],
        row['document_id'],
        row['chunk_index'],
        row['content_hash'],
        row['model_fingerprint'],
        row['dimension'],
        List<int>.of(row['embedding'] as Uint8List),
      ],
  ];
}
