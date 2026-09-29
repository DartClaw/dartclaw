import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  test('database defaults to PostgreSQL settings without an engine selector', () {
    expect(loadNoFile().database, const DatabaseConfig.defaults());
  });

  test('legacy postgres selector is accepted with removal guidance', () {
    final config = loadYaml('database:\n  backend: postgres\n');

    expect(config.database, const DatabaseConfig.defaults());
    expect(config.reloadBlockingWarnings, isEmpty);
    expect(config.warnings.join('\n'), contains('remove database.backend'));
  });

  for (final backend in const ['sqlite', 'mysql']) {
    test('$backend selector is refused because PostgreSQL is authoritative', () {
      final config = loadYaml('database:\n  backend: $backend\n');

      expect(config.reloadBlockingWarnings.join('\n'), contains('Invalid database.backend: "$backend"'));
      expect(config.reloadBlockingWarnings.join('\n'), contains('PostgreSQL is the only supported database'));
    });
  }

  test('database text-search language is normalized and defaults to english', () {
    final omitted = loadYaml('database: {}\n');
    final configured = loadYaml('database:\n  fts_language: " Swedish "\n');

    expect(omitted.database.ftsLanguage, 'english');
    expect(configured.database.ftsLanguage, 'swedish');
    expect(configured.reloadBlockingWarnings, isEmpty);
  });

  test('blank database text-search language is refused by key', () {
    final config = loadYaml('database:\n  fts_language: "  "\n');

    expect(config.database.ftsLanguage, 'english');
    expect(config.reloadBlockingWarnings.join('\n'), contains('database.fts_language'));
  });

  test('accepts one environment-substituted URL and the default pool size', () {
    final config = loadYaml(
      'database:\n  url: postgresql://\${PG_HOST}/db\n',
      env: const {'HOME': defaultTestHome, 'PG_HOST': 'database.internal'},
    );

    expect(config.database, const DatabaseConfig(url: 'postgresql://database.internal/db', urlEnvVars: ['PG_HOST']));
    expect(config.reloadBlockingWarnings, isEmpty);
  });

  test('allows a password supplied entirely by environment substitution', () {
    final config = loadYaml(
      'database:\n  url: postgresql://runtime:\${DATABASE_PASSWORD}@database.internal/db\n',
      env: const {'HOME': defaultTestHome, 'DATABASE_PASSWORD': 'EnvOnlyPasswordX9'},
    );

    expect(config.database.url, 'postgresql://runtime:EnvOnlyPasswordX9@database.internal/db');
    expect(config.database.urlEnvVars, ['DATABASE_PASSWORD']);
    expect(config.reloadBlockingWarnings, isEmpty);
  });

  test('treats an unresolved URL template as the configured reference', () {
    final config = loadYaml('database:\n  url: \${DARTCLAW_DATABASE_URL}\n', env: const {'HOME': defaultTestHome});

    expect(config.database.url, isEmpty);
    expect(config.database.urlEnvVars, ['DARTCLAW_DATABASE_URL']);
    expect(config.reloadBlockingWarnings, isEmpty);
  });

  test('accepts one named credential and an explicit pool size', () {
    final config = loadYaml('''
database:
  credential: production-db
  pool_size: 7
''');

    expect(config.database, const DatabaseConfig(credential: 'production-db', poolSize: 7));
  });

  test('omitting a connection reference remains loadable for pre-database commands', () {
    final config = loadYaml('database: {}\n');

    expect(config.database.url, isNull);
    expect(config.database.credential, isNull);
    expect(config.reloadBlockingWarnings, isEmpty);
  });

  for (final invalid in const {
    'both references': (
      yaml: '''
database:
  url: postgresql://database/db
  credential: production-db
''',
      warningFragments: ['database.url', 'database.credential', 'exactly one'],
    ),
    'non-positive pool size': (
      yaml: '''
database:
  url: postgresql://database/db
  pool_size: 0
''',
      warningFragments: ['database.pool_size'],
    ),
  }.entries) {
    test('reports ${invalid.key} as a blocking database warning', () {
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
    test('rejects a literal ${invalid.shape} without reproducing it', () {
      final config = loadYaml("database:\n  url: '${invalid.url}'\n");
      final warnings = config.reloadBlockingWarnings.join('\n');

      expect(warnings, contains('database.url'));
      expect(warnings, contains('environment substitution'));
      expect(warnings, contains('database.credential'));
      expect(warnings, isNot(contains(invalid.secret)));
    });
  }

  test('unknown database keys use the standard unknown-field refusal', () {
    expect(
      () => loadYaml('database:\n  surprise: true\n'),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('database.surprise'))),
    );
  });

  test('database is restart-tier configuration', () {
    expect(ConfigNotifier.sectionTiers['database'], ConfigReloadTier.restart);
  });
}
