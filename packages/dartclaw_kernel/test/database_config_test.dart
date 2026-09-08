import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  test('database defaults to inert SQLite configuration', () {
    final omitted = loadNoFile();
    final explicit = loadYaml('database:\n  backend: sqlite\n');

    expect(omitted.database, const DatabaseConfig.defaults());
    expect(explicit.database, const DatabaseConfig.defaults());
  });

  test('postgres accepts one environment-substituted URL and the default pool size', () {
    final config = loadYaml(
      'database:\n  backend: postgres\n  url: postgresql://\${PG_HOST}/db\n',
      env: const {'HOME': defaultTestHome, 'PG_HOST': 'database.internal'},
    );

    expect(
      config.database,
      const DatabaseConfig(
        backend: DatabaseBackendKind.postgres,
        url: 'postgresql://database.internal/db',
        urlEnvVars: ['PG_HOST'],
      ),
    );
    expect(config.reloadBlockingWarnings, isEmpty);
  });

  test('postgres allows a password supplied entirely by environment substitution', () {
    final config = loadYaml(
      'database:\n  backend: postgres\n  url: postgresql://runtime:\${DATABASE_PASSWORD}@database.internal/db\n',
      env: const {'HOME': defaultTestHome, 'DATABASE_PASSWORD': 'EnvOnlyPasswordX9'},
    );

    expect(config.database.url, 'postgresql://runtime:EnvOnlyPasswordX9@database.internal/db');
    expect(config.database.urlEnvVars, ['DATABASE_PASSWORD']);
    expect(config.reloadBlockingWarnings, isEmpty);
  });

  test('postgres treats an unresolved URL template as the configured reference', () {
    final config = loadYaml(
      'database:\n  backend: postgres\n  url: \${DARTCLAW_DATABASE_URL}\n',
      env: const {'HOME': defaultTestHome},
    );

    expect(config.database.url, isEmpty);
    expect(config.database.urlEnvVars, ['DARTCLAW_DATABASE_URL']);
    expect(config.reloadBlockingWarnings, isEmpty);
  });

  test('postgres accepts one named credential and an explicit pool size', () {
    final config = loadYaml('''
database:
  backend: postgres
  credential: production-db
  pool_size: 7
''');

    expect(
      config.database,
      const DatabaseConfig(backend: DatabaseBackendKind.postgres, credential: 'production-db', poolSize: 7),
    );
  });

  for (final invalid in const {
    'missing reference': (
      yaml: 'database:\n  backend: postgres\n',
      warningFragments: ['database.url', 'database.credential', 'exactly one'],
    ),
    'both references': (
      yaml: '''
database:
  backend: postgres
  url: postgresql://database/db
  credential: production-db
''',
      warningFragments: ['database.url', 'database.credential', 'exactly one'],
    ),
    'non-positive pool size': (
      yaml: '''
database:
  backend: postgres
  url: postgresql://database/db
  pool_size: 0
''',
      warningFragments: ['database.pool_size'],
    ),
  }.entries) {
    test('postgres reports ${invalid.key} as a blocking database warning', () {
      final config = loadYaml(invalid.value.yaml);
      final warnings = config.reloadBlockingWarnings.join('\n');

      expect(config.reloadBlockingWarnings, isNotEmpty);
      for (final fragment in invalid.value.warningFragments) {
        expect(warnings, contains(fragment));
      }
    });
  }

  for (final invalid in const [
    (
      shape: 'authority password',
      url: 'postgresql://runtime:LiteralAuthorityPasswordX9@database.internal/db',
      secret: 'LiteralAuthorityPasswordX9',
    ),
    (
      shape: 'password query parameter',
      url: 'postgresql://runtime@database.internal/db?password=LiteralQueryPasswordY8',
      secret: 'LiteralQueryPasswordY8',
    ),
    (
      shape: 'authority password after leading whitespace',
      url: ' postgresql://runtime:LiteralAuthorityPasswordX9@database.internal/db',
      secret: 'LiteralAuthorityPasswordX9',
    ),
    (
      shape: 'encoded password query parameter',
      url: 'postgresql://runtime@database.internal/db?pass%77ord=LiteralQueryPasswordY8',
      secret: 'LiteralQueryPasswordY8',
    ),
    (
      shape: 'malformed query parameter',
      url: 'postgresql://runtime@database.internal/db?pass%ZZword=LiteralQueryPasswordY8',
      secret: 'LiteralQueryPasswordY8',
    ),
  ]) {
    test('postgres rejects a literal ${invalid.shape} without reproducing it', () {
      final config = loadYaml("database:\n  backend: postgres\n  url: '${invalid.url}'\n");
      final warnings = config.reloadBlockingWarnings.join('\n');

      expect(warnings, contains('database.url'));
      expect(warnings, contains('environment substitution'));
      expect(warnings, contains('database.credential'));
      expect(warnings, isNot(contains(invalid.secret)));
    });
  }

  test('SQLite retains inactive PostgreSQL references without warning', () {
    final config = loadYaml('''
database:
  backend: sqlite
  url: postgresql://inactive:InactivePasswordZ7@database.internal/db?password=InactiveQueryPasswordW6
  credential: inactive-credential
''');

    expect(
      config.database.url,
      'postgresql://inactive:InactivePasswordZ7@database.internal/db?password=InactiveQueryPasswordW6',
    );
    expect(config.database.credential, 'inactive-credential');
    expect(config.reloadBlockingWarnings, isEmpty);
  });

  test('unknown database keys use the standard unknown-field refusal', () {
    expect(
      () => loadYaml('database:\n  backend: sqlite\n  surprise: true\n'),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('database.surprise'))),
    );
  });

  test('database is restart-tier configuration', () {
    expect(ConfigNotifier.sectionTiers['database'], ConfigReloadTier.restart);
  });
}
