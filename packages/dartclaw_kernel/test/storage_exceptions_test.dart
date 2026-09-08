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
}
