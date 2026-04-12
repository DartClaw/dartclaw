import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('parseProjectConfig', () {
    test('returns defaults for null input', () {
      final warns = <String>[];
      final config = parseProjectConfig(null, warns);
      expect(config.isEmpty, isTrue);
      expect(warns, isEmpty);
    });

    test('returns defaults for empty map', () {
      final warns = <String>[];
      final config = parseProjectConfig({}, warns);
      expect(config.isEmpty, isTrue);
      expect(warns, isEmpty);
    });

    test('parses minimal project definition (remote only)', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'my-app': {'remote': 'git@github.com:user/my-app.git'},
      }, warns);

      expect(warns, isEmpty);
      expect(config.isEmpty, isFalse);
      expect(config.definitions.containsKey('my-app'), isTrue);

      final def = config.definitions['my-app']!;
      expect(def.id, equals('my-app'));
      expect(def.remote, equals('git@github.com:user/my-app.git'));
      expect(def.branch, equals('main'));
      expect(def.credentials, isNull);
      expect(def.cloneStrategy, equals(CloneStrategy.shallow));
      expect(def.pr.strategy, equals(PrStrategy.branchOnly));
      expect(def.pr.draft, isFalse);
      expect(def.pr.labels, isEmpty);
      expect(def.isDefault, isFalse);
    });

    test('parses full project definition with all fields', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'my-app': {
          'remote': 'git@github.com:user/my-app.git',
          'branch': 'develop',
          'credentials': 'github-ssh',
          'default': true,
          'clone': {'strategy': 'full'},
          'pr': {
            'strategy': 'github-pr',
            'draft': true,
            'labels': ['agent', 'automated'],
          },
        },
      }, warns);

      expect(warns, isEmpty);
      final def = config.definitions['my-app']!;
      expect(def.branch, equals('develop'));
      expect(def.credentials, equals('github-ssh'));
      expect(def.isDefault, isTrue);
      expect(def.cloneStrategy, equals(CloneStrategy.full));
      expect(def.pr.strategy, equals(PrStrategy.githubPr));
      expect(def.pr.draft, isTrue);
      expect(def.pr.labels, equals(['agent', 'automated']));
    });

    test('parses multiple project definitions', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'app-one': {'remote': 'https://github.com/u/app-one.git'},
        'app-two': {'remote': 'git@github.com:u/app-two.git', 'branch': 'main'},
      }, warns);

      expect(config.definitions.length, equals(2));
      expect(config.definitions.containsKey('app-one'), isTrue);
      expect(config.definitions.containsKey('app-two'), isTrue);
    });

    test('warns and skips _local key', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        '_local': {'remote': 'git@github.com:u/local.git'},
        'valid-project': {'remote': 'git@github.com:u/valid.git'},
      }, warns);

      expect(warns, anyElement(contains('_local')));
      expect(warns, anyElement(contains('reserved')));
      expect(config.definitions.containsKey('_local'), isFalse);
      expect(config.definitions.containsKey('valid-project'), isTrue);
    });

    test('warns and skips entry with missing remote', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'no-remote': {'branch': 'main'},
      }, warns);

      expect(warns, anyElement(contains('no-remote')));
      expect(warns, anyElement(contains('remote')));
      expect(config.isEmpty, isTrue);
    });

    test('warns and skips entry with non-map value', () {
      final warns = <String>[];
      final config = parseProjectConfig({'invalid': 'not-a-map'}, warns);

      expect(warns, anyElement(contains('invalid')));
      expect(config.isEmpty, isTrue);
    });

    test('warns on unknown clone strategy but uses default', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'my-app': {
          'remote': 'git@github.com:u/r.git',
          'clone': {'strategy': 'invalid-strategy'},
        },
      }, warns);

      expect(warns, anyElement(contains('invalid-strategy')));
      final def = config.definitions['my-app']!;
      expect(def.cloneStrategy, equals(CloneStrategy.shallow));
    });

    test('sparse clone strategy is parsed', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'my-app': {
          'remote': 'git@github.com:u/r.git',
          'clone': {'strategy': 'sparse'},
        },
      }, warns);

      expect(warns, isEmpty);
      expect(config.definitions['my-app']!.cloneStrategy, equals(CloneStrategy.sparse));
    });
  });

  group('fetchCooldownMinutes', () {
    test('defaults to 5 when not specified', () {
      final config = parseProjectConfig({
        'my-app': {'remote': 'git@github.com:u/r.git'},
      }, []);
      expect(config.fetchCooldownMinutes, equals(5));
    });

    test('defaults to 5 for null input', () {
      final config = parseProjectConfig(null, []);
      expect(config.fetchCooldownMinutes, equals(5));
    });

    test('defaults to 5 for empty map', () {
      final config = parseProjectConfig({}, []);
      expect(config.fetchCooldownMinutes, equals(5));
    });

    test('parses fetchCooldownMinutes alongside project definitions', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'fetchCooldownMinutes': 10,
        'my-app': {'remote': 'git@github.com:u/r.git'},
      }, warns);
      expect(config.fetchCooldownMinutes, equals(10));
      expect(config.definitions.containsKey('my-app'), isTrue);
      expect(warns, isEmpty);
    });

    test('warns on non-integer fetchCooldownMinutes and uses default', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'fetchCooldownMinutes': 'not-an-int',
        'my-app': {'remote': 'git@github.com:u/r.git'},
      }, warns);
      expect(config.fetchCooldownMinutes, equals(5));
      expect(warns, anyElement(contains('fetchCooldownMinutes')));
    });

    test('fetchCooldownMinutes key is not treated as a project definition', () {
      final warns = <String>[];
      final config = parseProjectConfig({'fetchCooldownMinutes': 15}, warns);
      expect(config.definitions.containsKey('fetchCooldownMinutes'), isFalse);
      expect(warns, isEmpty);
    });
  });

  group('ProjectConfig', () {
    test('isEmpty for empty definitions', () {
      expect(const ProjectConfig().isEmpty, isTrue);
      expect(const ProjectConfig.defaults().isEmpty, isTrue);
    });

    test('isEmpty false when definitions present', () {
      final config = ProjectConfig(
        definitions: {'x': const ProjectDefinition(id: 'x', remote: 'git@h:u/x')},
      );
      expect(config.isEmpty, isFalse);
    });

    test('fetchCooldownMinutes defaults to 5', () {
      expect(const ProjectConfig().fetchCooldownMinutes, equals(5));
      expect(const ProjectConfig.defaults().fetchCooldownMinutes, equals(5));
    });
  });
}
