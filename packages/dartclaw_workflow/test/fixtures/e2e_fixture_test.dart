import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/credential_preflight.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'e2e_fixture.dart';

void main() {
  test('build() materializes a typed workflow e2e fixture', () async {
    final fixture = await E2EFixture(
      projectId: 'fixture-project',
      projectRemote: 'https://example.invalid/fixture-project.git',
      projectCredentials: null,
      environment: const {},
      projectSetup: (projectDir) {
        Directory(projectDir).createSync(recursive: true);
        File('$projectDir/README.md').writeAsStringSync('# Fixture\n');
      },
    ).build();
    addTearDown(fixture.dispose);

    expect(Directory(fixture.workspaceDir).existsSync(), isTrue);
    expect(Directory(fixture.workflowWorkspaceDir).existsSync(), isTrue);
    expect(Directory(fixture.projectDir).existsSync(), isTrue);
    expect(File('${fixture.projectDir}/README.md').existsSync(), isTrue);
    expect(fixture.config.projects.definitions.keys, contains('fixture-project'));
    expect(fixture.config.workflow.workspaceDir, fixture.workflowWorkspaceDir);
  });

  test('fixture config does not emit an unused CODEX_API_KEY warning', () async {
    final fixture = await E2EFixture(
      projectId: 'fixture-project',
      projectRemote: 'https://example.invalid/fixture-project.git',
      projectCredentials: null,
      environment: const {},
    ).build();
    addTearDown(fixture.dispose);

    final result = CredentialPreflight.validate(fixture.config, const {'GITHUB_TOKEN': 'test-token'});
    expect(result.warnings.where((warning) => warning.contains('CODEX_API_KEY')), isEmpty);
  });

  group('default model resolution', () {
    test('codex preset defaults executor/reviewer to gpt-5.3-codex-spark', () {
      final fixture = E2EFixture(environment: const {});
      expect(fixture.provider, 'codex');
      expect(fixture.workflowModel, 'gpt-5.4');
      expect(fixture.plannerModel, 'gpt-5.4');
      expect(fixture.executorModel, 'gpt-5.3-codex-spark');
      expect(fixture.reviewerModel, 'gpt-5.3-codex-spark');
      expect(fixture.sandbox, 'danger-full-access');
    });

    test('per-role env var overrides preset default', () {
      final fixture = E2EFixture(environment: const {
        'DARTCLAW_TEST_EXECUTOR_MODEL': 'claude-haiku-4-5',
      });
      expect(fixture.executorModel, 'claude-haiku-4-5');
      expect(fixture.reviewerModel, 'gpt-5.3-codex-spark');
      expect(fixture.workflowModel, 'gpt-5.4');
    });

    test('explicit constructor arg wins over env var', () {
      final fixture = E2EFixture(
        executorModel: 'gpt-5.4',
        environment: const {'DARTCLAW_TEST_EXECUTOR_MODEL': 'claude-haiku-4-5'},
      );
      expect(fixture.executorModel, 'gpt-5.4');
    });

    test('empty-string env var is treated as unset', () {
      final fixture = E2EFixture(environment: const {
        'DARTCLAW_TEST_EXECUTOR_MODEL': '',
      });
      expect(fixture.executorModel, 'gpt-5.3-codex-spark');
    });

    test('claude provider switches preset models, sandbox, and executable', () {
      final fixture = E2EFixture(environment: const {
        'DARTCLAW_TEST_PROVIDER': 'claude',
      });
      expect(fixture.provider, 'claude');
      expect(fixture.workflowModel, 'claude-opus-4-7');
      expect(fixture.plannerModel, 'claude-opus-4-7');
      expect(fixture.executorModel, 'claude-sonnet-4-6');
      expect(fixture.reviewerModel, 'claude-sonnet-4-6');
      expect(fixture.sandbox, 'bypassPermissions');
    });

    test('claude preset still honors per-role env-var overrides', () {
      final fixture = E2EFixture(environment: const {
        'DARTCLAW_TEST_PROVIDER': 'claude',
        'DARTCLAW_TEST_EXECUTOR_MODEL': 'claude-haiku-4-5',
      });
      expect(fixture.executorModel, 'claude-haiku-4-5');
      expect(fixture.reviewerModel, 'claude-sonnet-4-6');
    });

    test('claude preset materializes claude provider entry with permissionMode', () async {
      final fixture = await E2EFixture(
        projectCredentials: null,
        environment: const {'DARTCLAW_TEST_PROVIDER': 'claude'},
      ).build();
      addTearDown(fixture.dispose);

      final entry = fixture.config.providers.entries['claude'];
      expect(entry, isNotNull);
      expect(entry!.executable, 'claude');
      expect(entry.options['permissionMode'], 'bypassPermissions');
      expect(entry.options.containsKey('approval'), isFalse);
    });

    test('withProvider realigns unspecified role models with the new provider preset', () {
      final swapped = E2EFixture(environment: const {})
          .withProvider(value: 'claude', workflowModel: 'claude-opus-4-7');
      expect(swapped.provider, 'claude');
      expect(swapped.workflowModel, 'claude-opus-4-7');
      expect(swapped.plannerModel, 'claude-opus-4-7');
      expect(swapped.executorModel, 'claude-sonnet-4-6');
      expect(swapped.reviewerModel, 'claude-sonnet-4-6');
      expect(swapped.sandbox, 'bypassPermissions');
    });

    test('withProvider keeps explicit per-role overrides while realigning the rest', () {
      final swapped = E2EFixture(environment: const {}).withProvider(
        value: 'claude',
        workflowModel: 'claude-opus-4-7',
        executorModel: 'claude-haiku-4-5',
      );
      expect(swapped.executorModel, 'claude-haiku-4-5');
      expect(swapped.plannerModel, 'claude-opus-4-7');
      expect(swapped.reviewerModel, 'claude-sonnet-4-6');
      expect(swapped.sandbox, 'bypassPermissions');
    });

    test('unknown provider value raises ArgumentError instead of silently selecting codex', () {
      expect(
        () => E2EFixture(environment: const {'DARTCLAW_TEST_PROVIDER': 'cluade'}),
        throwsArgumentError,
      );
    });
  });

  group('renderProfileYaml', () {
    final goldensDir = _goldensDir();

    test('codex preset matches frozen golden', () {
      final fixture = E2EFixture(environment: const {});
      final rendered = fixture.renderProfileYaml(
        dataDir: '/tmp/dartclaw-test/data',
        workflowWorkspaceDir: '/tmp/dartclaw-test/workflow-workspace',
      );
      final golden = File(p.join(goldensDir, 'profile-codex.yaml')).readAsStringSync();
      expect(rendered, golden);
    });

    test('claude preset matches frozen golden', () {
      final fixture = E2EFixture(environment: const {'DARTCLAW_TEST_PROVIDER': 'claude'});
      final rendered = fixture.renderProfileYaml(
        dataDir: '/tmp/dartclaw-test/data',
        workflowWorkspaceDir: '/tmp/dartclaw-test/workflow-workspace',
      );
      final golden = File(p.join(goldensDir, 'profile-claude.yaml')).readAsStringSync();
      expect(rendered, golden);
    });
  });
}

String _goldensDir() {
  var current = Directory.current;
  while (true) {
    final candidate = p.join(
      current.path,
      'packages',
      'dartclaw_workflow',
      'test',
      'fixtures',
      'workflow-e2e-profile',
      '_goldens',
    );
    if (Directory(candidate).existsSync()) return candidate;
    final localCandidate = p.join(
      current.path,
      'test',
      'fixtures',
      'workflow-e2e-profile',
      '_goldens',
    );
    if (Directory(localCandidate).existsSync()) return localCandidate;
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate goldens directory');
    }
    current = parent;
  }
}
