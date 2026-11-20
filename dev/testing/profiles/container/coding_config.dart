import 'dart:convert';
import 'dart:io';

import '../../../../packages/dartclaw_workflow/test/fixtures/e2e_fixture.dart';

Future<void> main(List<String> args) async {
  final [provider, dataDir, remote, image, project] = args;
  final fixture = E2EFixture(provider: provider);
  final rendered = fixture
      .renderProfileYaml(
        dataDir: dataDir,
        workflowWorkspaceDir: '$dataDir/workspace',
        templatePath: '${File.fromUri(Platform.script).parent.path}/data/coding.yaml',
      )
      .replaceAll('__REMOTE__', jsonEncode(remote))
      .replaceAll('__IMAGE__', jsonEncode(image))
      // The go record ships disabled; only the Go fixture's instance enables it.
      .replaceAll('__CONTAINER_REGISTRIES__\n', project == 'go' ? '  registries:\n    go:\n      enabled: true\n' : '');
  File('$dataDir/dartclaw.yaml').writeAsStringSync(rendered);
  stdout.writeln(jsonEncode(await fixture.retainWorkflowForInspection(dataDir, 'implement-story')));
}
