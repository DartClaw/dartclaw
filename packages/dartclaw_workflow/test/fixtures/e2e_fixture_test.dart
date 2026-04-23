import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/credential_preflight.dart';
import 'package:test/test.dart';

import 'e2e_fixture.dart';

void main() {
  test('build() materializes a typed workflow e2e fixture', () async {
    final fixture = await E2EFixture()
        .withProject(
          'fixture-project',
          remote: 'https://example.invalid/fixture-project.git',
          credentials: null,
        )
        .withProjectSetup((projectDir) {
          Directory(projectDir).createSync(recursive: true);
          File('$projectDir/README.md').writeAsStringSync('# Fixture\n');
        })
        .build();
    addTearDown(fixture.dispose);

    expect(Directory(fixture.workspaceDir).existsSync(), isTrue);
    expect(Directory(fixture.workflowWorkspaceDir).existsSync(), isTrue);
    expect(Directory(fixture.projectDir).existsSync(), isTrue);
    expect(File('${fixture.projectDir}/README.md').existsSync(), isTrue);
    expect(fixture.config.projects.definitions.keys, contains('fixture-project'));
    expect(fixture.config.workflow.workspaceDir, fixture.workflowWorkspaceDir);
  });

  test('fixture config does not emit an unused CODEX_API_KEY warning', () async {
    final fixture = await E2EFixture()
        .withProject(
          'fixture-project',
          remote: 'https://example.invalid/fixture-project.git',
          credentials: null,
        )
        .build();
    addTearDown(fixture.dispose);

    final result = CredentialPreflight.validate(fixture.config, const {'GITHUB_TOKEN': 'test-token'});
    expect(result.warnings.where((warning) => warning.contains('CODEX_API_KEY')), isEmpty);
  });
}
