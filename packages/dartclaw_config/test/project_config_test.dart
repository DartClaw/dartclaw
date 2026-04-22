import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Directory gitRepoDir;
  late Directory nonRepoDir;
  late String missingPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('project_config_test_');
    gitRepoDir = Directory('${tempDir.path}/git-repo')..createSync(recursive: true);
    Directory('${gitRepoDir.path}/.git').createSync(recursive: true);
    nonRepoDir = Directory('${tempDir.path}/not-a-repo')..createSync(recursive: true);
    missingPath = '${tempDir.path}/missing-repo';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('validateProjectLocalPath', () {
    test('rejects relative paths', () {
      final result = validateProjectLocalPath('relative/path');

      expect(result.isValid, isFalse);
      expect(result.errorCode, 'relative');
    });

    test('rejects traversal segments before normalization', () {
      final result = validateProjectLocalPath('${tempDir.path}/allowed/../etc');

      expect(result.isValid, isFalse);
      expect(result.errorCode, 'traversal');
    });

    test('rejects paths outside the allowlist', () {
      final result = validateProjectLocalPath(gitRepoDir.path, allowlist: [nonRepoDir.path]);

      expect(result.isValid, isFalse);
      expect(result.errorCode, 'outside-allowlist');
    });

    test('reports existence and git-shape metadata for valid paths', () {
      final result = validateProjectLocalPath(gitRepoDir.path, allowlist: [tempDir.path]);

      expect(result.isValid, isTrue);
      expect(result.normalizedPath, gitRepoDir.path);
      expect(result.pathExists, isTrue);
      expect(result.gitRepository, isTrue);
    });
  });

  group('parseProjectConfig', () {
    test('returns defaults for null input', () {
      final warns = <String>[];
      final config = parseProjectConfig(null, warns);

      expect(config, const ProjectConfig.defaults());
      expect(warns, isEmpty);
    });

    test('returns defaults for empty map', () {
      final warns = <String>[];
      final config = parseProjectConfig({}, warns);

      expect(config, const ProjectConfig.defaults());
      expect(warns, isEmpty);
    });

    test('parses remote-backed project definitions unchanged', () {
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

      final def = config.definitions['my-app']!;
      expect(warns, isEmpty);
      expect(def.remote, 'git@github.com:user/my-app.git');
      expect(def.localPath, isNull);
      expect(def.branch, 'develop');
      expect(def.credentials, 'github-ssh');
      expect(def.isDefault, isTrue);
      expect(def.cloneStrategy, CloneStrategy.full);
      expect(def.pr.strategy, PrStrategy.githubPr);
      expect(def.pr.draft, isTrue);
      expect(def.pr.labels, ['agent', 'automated']);
    });

    test('parses localPath-backed project definitions', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'local-app': {'localPath': gitRepoDir.path, 'branch': 'main'},
      }, warns);

      final def = config.definitions['local-app']!;
      expect(warns, isEmpty);
      expect(def.remote, isNull);
      expect(def.localPath, gitRepoDir.path);
      expect(def.branch, 'main');
    });

    test('localPath-backed project definitions default branch to empty for HEAD inference', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'local-app': {'localPath': gitRepoDir.path},
      }, warns);

      final def = config.definitions['local-app']!;
      expect(warns, isEmpty);
      expect(def.localPath, gitRepoDir.path);
      expect(def.branch, isEmpty);
    });

    test('remote-backed project definitions still default branch to main', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'remote-app': {'remote': 'git@github.com:user/remote-app.git'},
      }, warns);

      final def = config.definitions['remote-app']!;
      expect(warns, isEmpty);
      expect(def.remote, 'git@github.com:user/remote-app.git');
      expect(def.branch, 'main');
    });

    test('trims explicit branch values for both remote and localPath projects', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'remote-app': {'remote': 'git@github.com:user/remote-app.git', 'branch': '  develop  '},
        'local-app': {'localPath': gitRepoDir.path, 'branch': '  feature/live  '},
      }, warns);

      expect(warns, isEmpty);
      expect(config.definitions['remote-app']!.branch, 'develop');
      expect(config.definitions['local-app']!.branch, 'feature/live');
    });

    test('warns and skips entries supplying both remote and localPath', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'bad': {'remote': 'git@github.com:user/repo.git', 'localPath': gitRepoDir.path},
      }, warns);

      expect(config.isEmpty, isTrue);
      expect(warns.single, contains('exactly one of "remote" or "localPath"'));
    });

    test('warns and skips entries supplying neither remote nor localPath', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'bad': {'branch': 'main'},
      }, warns);

      expect(config.isEmpty, isTrue);
      expect(warns.single, contains('exactly one of "remote" or "localPath"'));
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

    test('rejects relative localPath values', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'bad': {'localPath': 'relative/path'},
      }, warns);

      expect(config.isEmpty, isTrue);
      expect(warns.single, contains('must be absolute'));
    });

    test('rejects traversal localPath values before allowlist evaluation', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'localPathAllowlist': [tempDir.path],
        'bad': {'localPath': '${tempDir.path}/allowed/../etc'},
      }, warns);

      expect(config.isEmpty, isTrue);
      expect(warns.single, contains('local-path traversal'));
    });

    test('rejects localPath values outside the configured allowlist', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'localPathAllowlist': [gitRepoDir.path],
        'bad': {'localPath': nonRepoDir.path},
      }, warns);

      expect(config.isEmpty, isTrue);
      expect(warns.single, contains('outside allowlist'));
    });

    test('warns but accepts non-existent localPath values', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'missing-repo': {'localPath': missingPath},
      }, warns);

      expect(config.definitions['missing-repo']?.localPath, missingPath);
      expect(warns.single, contains('does not exist at config-load time'));
    });

    test('warns but accepts non-git directories at config-load time', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'non-repo': {'localPath': nonRepoDir.path},
      }, warns);

      expect(config.definitions['non-repo']?.localPath, nonRepoDir.path);
      expect(warns.single, contains('is not a git repository at config-load time'));
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
      expect(config.definitions['my-app']!.cloneStrategy, CloneStrategy.shallow);
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
      expect(config.definitions['my-app']!.cloneStrategy, CloneStrategy.sparse);
    });
  });

  group('project scalar settings', () {
    test('fetchCooldownMinutes defaults to 5', () {
      final config = parseProjectConfig({
        'my-app': {'remote': 'git@github.com:u/r.git'},
      }, []);

      expect(config.fetchCooldownMinutes, 5);
    });

    test('parses fetchCooldownMinutes alongside project definitions', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'fetchCooldownMinutes': 10,
        'my-app': {'remote': 'git@github.com:u/r.git'},
      }, warns);

      expect(config.fetchCooldownMinutes, 10);
      expect(warns, isEmpty);
    });

    test('warns on non-integer fetchCooldownMinutes and uses default', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'fetchCooldownMinutes': 'not-an-int',
        'my-app': {'remote': 'git@github.com:u/r.git'},
      }, warns);

      expect(config.fetchCooldownMinutes, 5);
      expect(warns, anyElement(contains('fetchCooldownMinutes')));
    });

    test('allowApiLocalPath defaults to false', () {
      final config = parseProjectConfig({
        'my-app': {'remote': 'git@github.com:u/r.git'},
      }, []);

      expect(config.allowApiLocalPath, isFalse);
    });

    test('parses allowApiLocalPath and localPathAllowlist', () {
      final warns = <String>[];
      final config = parseProjectConfig({
        'allowApiLocalPath': true,
        'localPathAllowlist': [gitRepoDir.path, nonRepoDir.path],
        'my-app': {'remote': 'git@github.com:u/r.git'},
      }, warns);

      expect(config.allowApiLocalPath, isTrue);
      expect(config.localPathAllowlist, [gitRepoDir.path, nonRepoDir.path]);
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

    test('defaults are preserved in the const constructor', () {
      expect(const ProjectConfig().fetchCooldownMinutes, 5);
      expect(const ProjectConfig().allowApiLocalPath, isFalse);
      expect(const ProjectConfig().localPathAllowlist, isEmpty);
    });
  });
}
