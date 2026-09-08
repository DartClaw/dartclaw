import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:postgres/postgres.dart' show SslMode;
import 'package:test/test.dart';

void main() {
  group('PostgreSQL connection posture', () {
    for (final testCase in const [
      (url: 'postgresql://localhost/db', mode: SslMode.require),
      (url: 'postgresql://127.0.0.1/db', mode: SslMode.require),
      (url: 'postgresql://[::1]/db', mode: SslMode.require),
      (url: 'postgresql://db.example.com/db', mode: SslMode.verifyFull),
      (url: 'postgresql://127.0.0.2/db', mode: SslMode.verifyFull),
      (url: 'postgresql://db.example.com/db?sslmode=verify-full', mode: SslMode.verifyFull),
      (url: 'postgresql://db.example.com/db?sslmode=verify-ca', mode: SslMode.verifyFull),
      (url: 'postgresql://db.example.com/db?sslmode=require', mode: SslMode.require),
      (url: 'postgresql://localhost/db?sslmode=disable', mode: SslMode.disable),
    ]) {
      test('${testCase.url} resolves ${testCase.mode.name}', () {
        final posture = evaluatePostgresConnectionPosture(testCase.url, credentialRef: 'DARTCLAW_DATABASE_URL');
        expect(posture.sslMode, testCase.mode);
        expect(posture.credentialRef, 'DARTCLAW_DATABASE_URL');
      });
    }

    test('decodes endpoint credentials but keeps only a safe identity', () {
      final posture = evaluatePostgresConnectionPosture(
        'postgresql://alice:p%40ss%3Aw0rd@db.example.com:5444/app',
        credentialRef: 'database-main',
        namespace: 'dc_test',
      );

      expect(posture.endpoint.host, 'db.example.com');
      expect(posture.endpoint.port, 5444);
      expect(posture.endpoint.database, 'app');
      expect(posture.endpoint.username, 'alice');
      expect(posture.endpoint.password, 'p@ss:w0rd');
      expect(posture.databaseIdentity, 'db.example.com:5444/app/dc_test');
      expect(posture.databaseIdentity, isNot(contains('alice')));
      expect(posture.databaseIdentity, isNot(contains('p@ss:w0rd')));
    });

    for (final host in ['db.example.com', '127.0.0.2']) {
      test('refuses cleartext to $host before returning connection settings', () {
        const secret = 'DistinctiveP4ssword';
        expect(
          () => evaluatePostgresConnectionPosture(
            'postgresql://alice:$secret@$host/app?sslmode=disable',
            credentialRef: 'database-main',
          ),
          throwsA(
            isA<StorageConnectionException>()
                .having((error) => '$error', 'message', contains('non-loopback'))
                .having((error) => '$error', 'message', contains('127.0.0.1'))
                .having((error) => '$error', 'message', isNot(contains(secret))),
          ),
        );
      });
    }

    test('refuses malformed shapes and parameters without echoing their values', () {
      const secret = 'DistinctiveP4ssword';
      final cases = <({String url, String expected})>[
        (url: 'host=db.example.com user=alice password=$secret', expected: 'postgres or postgresql URI'),
        (url: 'alice:$secret@db.example.com/app', expected: 'postgres or postgresql URI'),
        (url: 'postgresql://alice:$secret@db.example.com/app?sslmode=prefer', expected: 'sslmode'),
        (url: 'postgresql://alice:$secret@db.example.com/app?password=$secret', expected: 'password'),
        (url: 'postgresql://alice:$secret@db.example.com/a/b', expected: 'one database path segment'),
      ];

      for (final (:url, :expected) in cases) {
        expect(
          () => evaluatePostgresConnectionPosture(url, credentialRef: 'database-main'),
          throwsA(
            isA<StorageConnectionException>()
                .having((error) => '$error', 'message', contains(expected))
                .having((error) => '$error', 'message', isNot(contains(secret))),
          ),
          reason: url,
        );
      }
    });
  });
}
