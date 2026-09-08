import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  test('storage exceptions render only allow-listed diagnostics', () async {
    const secrets = [
      'user_X7t8VQ',
      'password_H9m2Ls',
      'host-secret.example',
      'database_secret',
      'querySecret=K4p6',
      '/certs/private-client.pem',
      'raw driver detail H8u2',
    ];
    const safeIdentity = 'db.internal:5432/application';
    final errors = <StorageException>[
      StorageConnectionException(
        operation: 'connect',
        databaseIdentity: safeIdentity,
        guidance: 'Check database availability.',
      ),
      StoragePoolExhaustedException(
        operation: 'acquire connection',
        databaseIdentity: safeIdentity,
        guidance: 'Release work and retry.',
      ),
      StorageQueryException(
        operation: 'query',
        databaseIdentity: safeIdentity,
        sqlState: '23505',
        guidance: 'Correct the request.',
      ),
      StorageUnknownOutcomeException(
        operation: 'commit',
        databaseIdentity: safeIdentity,
        guidance: 'Verify database state before retrying.',
      ),
      SchemaIncompatibleException(
        storeName: safeIdentity,
        foundEpoch: '2',
        differences: const ['missing table tasks'],
        action: 'Back up then reset or recreate the database.',
      ),
    ];
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);

    for (final error in errors) {
      Logger('storage-test').severe('Storage startup refused', error);
      final rendered = [error.toString(), error.message, error.operation, error.databaseIdentity].join('\n');
      expect(rendered, contains(safeIdentity));
      for (final secret in secrets) {
        expect(rendered, isNot(contains(secret)));
      }
    }
    await Future<void>.delayed(Duration.zero);
    final logged = records.map((record) => '${record.message}\n${record.error}').join('\n');
    for (final secret in secrets) {
      expect(logged, isNot(contains(secret)));
    }
  });

  test('query failures expose SQLSTATE without driver details', () {
    final error = StorageQueryException(
      operation: 'query',
      databaseIdentity: 'db.internal:5432/application',
      sqlState: '42P01',
      guidance: 'Check the schema.',
    );

    expect(error.sqlState, '42P01');
    expect(error.toString(), contains('SQLSTATE 42P01'));
  });

  test('configuration refusals expose only the key, value, valid list, and guidance', () {
    final error = StorageConfigurationException(
      key: 'database.fts_language',
      value: 'klingon',
      validValues: const ['english', 'swedish'],
    );

    expect(error.operation, 'configuration');
    expect(error.databaseIdentity, isNull);
    expect(error.key, 'database.fts_language');
    expect(error.value, 'klingon');
    expect(error.validValues, ['english', 'swedish']);
    expect(
      error.toString(),
      'StorageConfigurationException: database.fts_language "klingon" is unavailable on this PostgreSQL server. '
      'Valid values: english, swedish. Choose a listed value, restart DartClaw, and rebuild the memory search index.',
    );
    for (final secret in ['postgres://private', 'raw driver detail', 'password=hidden']) {
      expect(error.toString(), isNot(contains(secret)));
    }
  });
}
