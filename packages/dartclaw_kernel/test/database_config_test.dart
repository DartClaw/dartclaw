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
      const DatabaseConfig(backend: DatabaseBackendKind.postgres, url: 'postgresql://database.internal/db'),
    );
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
    'missing reference': 'database:\n  backend: postgres\n',
    'both references': '''
database:
  backend: postgres
  url: postgresql://database/db
  credential: production-db
''',
    'non-positive pool size': '''
database:
  backend: postgres
  url: postgresql://database/db
  pool_size: 0
''',
  }.entries) {
    test('postgres reports ${invalid.key} as a blocking database warning', () {
      final config = loadYaml(invalid.value);

      expect(config.reloadBlockingWarnings, isNotEmpty);
      expect(config.reloadBlockingWarnings.join('\n'), contains('database.'));
    });
  }

  test('SQLite retains inactive PostgreSQL references without warning', () {
    final config = loadYaml('''
database:
  backend: sqlite
  url: postgresql://inactive/db
  credential: inactive-credential
''');

    expect(config.database.url, 'postgresql://inactive/db');
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
