import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('bootstraps the exact separate vector schema and accepts current state without mutation', () async {
    final backend = SqliteBackend.openInMemory();
    addTearDown(backend.close);
    await SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db');

    expect(
      (await SqliteSchemaGate.inspect(backend, SchemaIdentity.vectors, storeName: 'vectors.db')).state,
      SqliteSchemaState.current,
    );
    final objects = await backend.query(
      "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
    );
    expect(objects.map((row) => '${row['type']}:${row['name']}'), [
      'index:conversation_vectors_lookup_idx',
      'index:memory_vectors_lookup_idx',
      'table:conversation_vectors',
      'table:dartclaw_schema',
      'table:memory_vectors',
    ]);
    final version = (await backend.query('PRAGMA schema_version')).single.values.single;
    await SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db');
    expect((await backend.query('PRAGMA schema_version')).single.values.single, version);
  });

  test('refuses unmarked, partial, and incompatible vector stores with derived-only guidance', () async {
    for (final setup in <Future<void> Function(DatabaseBackend)>[
      (backend) async {
        for (final sql in SchemaIdentity.vectors.bootstrapStatements) {
          await backend.execute(sql);
        }
      },
      (backend) => backend.execute(SchemaIdentity.vectors.bootstrapStatements.first),
      (backend) async {
        await SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db');
        await backend.execute('DROP INDEX memory_vectors_lookup_idx');
      },
    ]) {
      final backend = SqliteBackend.openInMemory();
      await setup(backend);
      try {
        await expectLater(
          SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db'),
          throwsA(
            isA<SchemaIncompatibleException>()
                .having((error) => error.action, 'action', contains('reset only vectors.db'))
                .having(
                  (error) => error.toString(),
                  'isolation',
                  isNot(anyOf(contains('search.db'), contains('dartclaw.db'))),
                ),
          ),
        );
      } finally {
        await backend.close();
      }
    }
  });

  test('failed bootstrap rolls back every vector object and retries cleanly', () async {
    final backend = SqliteBackend.openInMemory();
    addTearDown(backend.close);
    final failing = FailingVectorMutationBackend(backend, failAt: 3);

    await expectLater(SqliteSchemaGate.prepareVectors(failing, storeName: 'vectors.db'), throwsA(isA<StateError>()));
    expect(await backend.query("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"), isEmpty);

    await SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db');
    expect(
      (await SqliteSchemaGate.inspect(backend, SchemaIdentity.vectors, storeName: 'vectors.db')).state,
      SqliteSchemaState.current,
    );
  });
}
