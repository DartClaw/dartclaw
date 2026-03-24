import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('ProjectStatus', () {
    test('has expected values', () {
      expect(ProjectStatus.values.map((e) => e.name), containsAll(['cloning', 'ready', 'error', 'stale']));
    });

    test('round-trips via asNameMap', () {
      for (final status in ProjectStatus.values) {
        expect(ProjectStatus.values.asNameMap()[status.name], equals(status));
      }
    });
  });

  group('CloneStrategy', () {
    test('has expected values', () {
      expect(CloneStrategy.values.map((e) => e.name), containsAll(['shallow', 'full', 'sparse']));
    });
  });

  group('PrStrategy', () {
    test('fromYaml parses hyphenated forms', () {
      expect(PrStrategy.fromYaml('branch-only'), equals(PrStrategy.branchOnly));
      expect(PrStrategy.fromYaml('github-pr'), equals(PrStrategy.githubPr));
    });

    test('fromYaml parses camelCase forms', () {
      expect(PrStrategy.fromYaml('branchOnly'), equals(PrStrategy.branchOnly));
      expect(PrStrategy.fromYaml('githubPr'), equals(PrStrategy.githubPr));
    });

    test('fromYaml returns branchOnly for unknown values', () {
      expect(PrStrategy.fromYaml('unknown'), equals(PrStrategy.branchOnly));
      expect(PrStrategy.fromYaml(null), equals(PrStrategy.branchOnly));
      expect(PrStrategy.fromYaml(42), equals(PrStrategy.branchOnly));
    });
  });

  group('PrConfig', () {
    test('defaults', () {
      const config = PrConfig.defaults();
      expect(config.strategy, equals(PrStrategy.branchOnly));
      expect(config.draft, isFalse);
      expect(config.labels, isEmpty);
    });

    test('toJson / fromJson round-trip', () {
      const config = PrConfig(
        strategy: PrStrategy.githubPr,
        draft: true,
        labels: ['agent', 'automated'],
      );
      final json = config.toJson();
      final roundTripped = PrConfig.fromJson(json);
      expect(roundTripped.strategy, equals(config.strategy));
      expect(roundTripped.draft, equals(config.draft));
      expect(roundTripped.labels, equals(config.labels));
    });

    test('toJson omits empty labels', () {
      const config = PrConfig.defaults();
      final json = config.toJson();
      expect(json.containsKey('labels'), isFalse);
    });

    test('fromJson handles missing fields with defaults', () {
      final config = PrConfig.fromJson({});
      expect(config.strategy, equals(PrStrategy.branchOnly));
      expect(config.draft, isFalse);
      expect(config.labels, isEmpty);
    });

    test('equality', () {
      const a = PrConfig(strategy: PrStrategy.githubPr, draft: true, labels: ['x']);
      const b = PrConfig(strategy: PrStrategy.githubPr, draft: true, labels: ['x']);
      expect(a, equals(b));
    });
  });

  group('Project', () {
    final now = DateTime(2024, 1, 15, 10, 30);

    Project makeProject({
      String id = 'my-project',
      String name = 'My Project',
      String remoteUrl = 'git@github.com:user/repo.git',
      String localPath = '/data/projects/my-project',
      ProjectStatus status = ProjectStatus.ready,
    }) => Project(
      id: id,
      name: name,
      remoteUrl: remoteUrl,
      localPath: localPath,
      status: status,
      createdAt: now,
    );

    test('all fields serialized in toJson', () {
      final project = Project(
        id: 'proj-1',
        name: 'My Project',
        remoteUrl: 'git@github.com:user/repo.git',
        localPath: '/data/projects/proj-1',
        defaultBranch: 'develop',
        credentialsRef: 'github-ssh',
        cloneStrategy: CloneStrategy.full,
        pr: const PrConfig(strategy: PrStrategy.githubPr, draft: true, labels: ['agent']),
        status: ProjectStatus.ready,
        lastFetchAt: now,
        configDefined: true,
        errorMessage: null,
        createdAt: now,
      );

      final json = project.toJson();
      expect(json['id'], equals('proj-1'));
      expect(json['name'], equals('My Project'));
      expect(json['remoteUrl'], equals('git@github.com:user/repo.git'));
      expect(json['localPath'], equals('/data/projects/proj-1'));
      expect(json['defaultBranch'], equals('develop'));
      expect(json['credentialsRef'], equals('github-ssh'));
      expect(json['cloneStrategy'], equals('full'));
      expect(json['status'], equals('ready'));
      expect(json['lastFetchAt'], equals(now.toIso8601String()));
      expect(json['configDefined'], isTrue);
      expect(json.containsKey('errorMessage'), isFalse);
      expect(json['createdAt'], equals(now.toIso8601String()));
    });

    test('toJson / fromJson round-trip with all fields', () {
      final project = Project(
        id: 'proj-1',
        name: 'My Project',
        remoteUrl: 'https://github.com/user/repo.git',
        localPath: '/data/projects/proj-1',
        defaultBranch: 'main',
        credentialsRef: 'my-cred',
        cloneStrategy: CloneStrategy.shallow,
        pr: const PrConfig.defaults(),
        status: ProjectStatus.error,
        lastFetchAt: now,
        configDefined: false,
        errorMessage: 'Clone failed',
        createdAt: now,
      );

      final json = project.toJson();
      final restored = Project.fromJson(json);

      expect(restored.id, equals(project.id));
      expect(restored.name, equals(project.name));
      expect(restored.remoteUrl, equals(project.remoteUrl));
      expect(restored.localPath, equals(project.localPath));
      expect(restored.defaultBranch, equals(project.defaultBranch));
      expect(restored.credentialsRef, equals(project.credentialsRef));
      expect(restored.cloneStrategy, equals(project.cloneStrategy));
      expect(restored.status, equals(project.status));
      expect(restored.lastFetchAt, equals(project.lastFetchAt));
      expect(restored.configDefined, equals(project.configDefined));
      expect(restored.errorMessage, equals(project.errorMessage));
      expect(restored.createdAt, equals(project.createdAt));
    });

    test('toJson omits null optional fields', () {
      final project = makeProject();
      final json = project.toJson();
      expect(json.containsKey('credentialsRef'), isFalse);
      expect(json.containsKey('lastFetchAt'), isFalse);
      expect(json.containsKey('errorMessage'), isFalse);
    });

    test('fromJson applies defaults for missing optional fields', () {
      final minimal = Project.fromJson({
        'id': 'x',
        'name': 'X',
        'remoteUrl': 'git@github.com:x/x.git',
        'localPath': '/x',
        'status': 'cloning',
        'createdAt': now.toIso8601String(),
        'pr': {'strategy': 'branchOnly', 'draft': false},
      });
      expect(minimal.defaultBranch, equals('main'));
      expect(minimal.credentialsRef, isNull);
      expect(minimal.cloneStrategy, equals(CloneStrategy.shallow));
      expect(minimal.configDefined, isFalse);
      expect(minimal.lastFetchAt, isNull);
      expect(minimal.errorMessage, isNull);
    });

    group('copyWith', () {
      test('returns identical project when no params given', () {
        final project = makeProject();
        final copy = project.copyWith();
        expect(copy.id, equals(project.id));
        expect(copy.status, equals(project.status));
        expect(copy.errorMessage, equals(project.errorMessage));
      });

      test('updates specific fields', () {
        final project = makeProject(status: ProjectStatus.cloning);
        final updated = project.copyWith(status: ProjectStatus.ready, lastFetchAt: now);
        expect(updated.status, equals(ProjectStatus.ready));
        expect(updated.lastFetchAt, equals(now));
        expect(updated.id, equals(project.id)); // unchanged
      });

      test('can set nullable fields to null via sentinel', () {
        final project = Project(
          id: 'p',
          name: 'P',
          remoteUrl: 'https://r',
          localPath: '/p',
          credentialsRef: 'cred',
          errorMessage: 'err',
          createdAt: now,
          lastFetchAt: now,
        );
        final cleared = project.copyWith(
          credentialsRef: null,
          errorMessage: null,
          lastFetchAt: null,
        );
        expect(cleared.credentialsRef, isNull);
        expect(cleared.errorMessage, isNull);
        expect(cleared.lastFetchAt, isNull);
      });

      test('preserves nullable fields when not specified', () {
        final project = Project(
          id: 'p',
          name: 'P',
          remoteUrl: 'https://r',
          localPath: '/p',
          credentialsRef: 'cred',
          errorMessage: 'err',
          createdAt: now,
          lastFetchAt: now,
        );
        final copy = project.copyWith(name: 'Updated');
        expect(copy.credentialsRef, equals('cred'));
        expect(copy.errorMessage, equals('err'));
        expect(copy.lastFetchAt, equals(now));
      });
    });

    test('toString includes key fields', () {
      final project = makeProject(id: 'proj-1', status: ProjectStatus.ready);
      final str = project.toString();
      expect(str, contains('proj-1'));
      expect(str, contains('ready'));
    });

    test('_local project with empty remoteUrl shows <local> in toString', () {
      final local = Project(
        id: '_local',
        name: 'myrepo',
        remoteUrl: '',
        localPath: '/home/user/myrepo',
        status: ProjectStatus.ready,
        createdAt: now,
      );
      expect(local.toString(), contains('<local>'));
    });
  });
}
