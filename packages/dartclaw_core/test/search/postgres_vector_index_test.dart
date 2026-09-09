import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'vector_index_contract.dart';

void main() {
  runVectorIndexContract('PostgreSQL', () async {
    final delegate = PostgresVectorTestBackend();
    final backend = RecordingDatabaseBackend(delegate);
    return (
      memory: PostgresVectorIndex(backend, table: VectorTable.memoryChunks),
      conversation: PostgresVectorIndex(backend, table: VectorTable.conversationChunks),
      database: backend,
      close: backend.close,
    );
  });

  test('qualifies pgvector SQL, materializes dimension filters, and parameterizes vector data', () async {
    final backend = PostgresVectorTestBackend();
    final index = PostgresVectorIndex(backend, table: VectorTable.memoryChunks);
    await index.upsert([
      _record('private-id', [1, 2]),
    ], userId: 'owner');
    await index.search([1, 2], userId: 'owner', modelFingerprint: 'model');

    final insert = backend.prepared.single;
    expect(insert, contains('CAST(? AS public.vector)'));
    expect(insert, isNot(contains('private-id')));
    final search = backend.queries.singleWhere((call) => call.sql.contains('WITH query_vector'));
    expect(search.sql, contains('candidates AS MATERIALIZED'));
    expect(search.sql.indexOf('public.vector_dims'), lessThan(search.sql.indexOf('OPERATOR(public.<=>)')));
    expect(
      search.sql,
      allOf(contains('public.vector_dims'), contains('public.vector_norm'), contains('OPERATOR(public.<=>)')),
    );
    expect(search.sql, isNot(contains('private-id')));
    expect(search.parameters, ['[1.0,2.0]', 'owner', 'model', 2, 2, 20]);
    expect(backend.transactions, 1);
  });

  test('mutation failures roll back retirements and replacements', () async {
    final backend = PostgresVectorTestBackend();
    final index = PostgresVectorIndex(backend, table: VectorTable.memoryChunks);
    await index.upsert([
      _record('prior', [1]),
    ], userId: 'owner');

    backend.failNextInsert = true;
    await expectLater(
      index.upsert(
        [
          _record('new', [2]),
        ],
        userId: 'owner',
        retire: {VectorIdentity(documentId: 'prior', chunkIndex: 0)},
      ),
      throwsStateError,
    );
    expect((await index.list(userId: 'owner')).single.documentId, 'prior');

    backend.failNextInsert = true;
    await expectLater(
      index.replaceAll([
        _record('replacement', [3]),
      ], userId: 'owner'),
      throwsStateError,
    );
    expect((await index.list(userId: 'owner')).single.documentId, 'prior');
  });

  test('invalid PostgreSQL result values fail with content-free derived recovery guidance', () async {
    final backend = PostgresVectorTestBackend();
    final index = PostgresVectorIndex(backend, table: VectorTable.memoryChunks);
    backend.listResultOverride = [
      {
        'document_id': 'secret-document',
        'chunk_index': -1,
        'content_hash': 'secret-hash',
        'model_fingerprint': 'model',
        'dimension': 1,
        'embedding': '[1]',
      },
    ];

    await expectLater(
      index.list(userId: 'owner'),
      throwsA(
        isA<SchemaIncompatibleException>()
            .having((error) => error.toString(), 'guidance', contains('derived vector projection'))
            .having((error) => error.toString(), 'content', isNot(contains('secret'))),
      ),
    );

    backend.searchResultOverride = [
      {'document_id': 'secret-document', 'chunk_index': 0, 'content_hash': 'secret-hash', 'score': double.nan},
    ];
    await expectLater(
      index.search(const [1], userId: 'owner', modelFingerprint: 'model'),
      throwsA(
        isA<SchemaIncompatibleException>()
            .having((error) => error.toString(), 'guidance', contains('derived vector projection'))
            .having((error) => error.toString(), 'content', isNot(contains('secret'))),
      ),
    );
  });
}

VectorRecord _record(String id, List<double> vector) =>
    VectorRecord(documentId: id, chunkIndex: 0, contentHash: '$id-hash', modelFingerprint: 'model', vector: vector);
