import 'dart:convert';
import 'dart:io';

import '../../../../packages/dartclaw_workflow/test/fixtures/e2e_fixture.dart';

Future<void> main(List<String> args) async {
  final [provider, dataDir, remote, image] = args;
  final fixture = E2EFixture(provider: provider);
  final rendered = fixture
      .renderProfileYaml(
        dataDir: dataDir,
        workflowWorkspaceDir: '$dataDir/workspace',
        templatePath: '${File.fromUri(Platform.script).parent.path}/data/coding.yaml',
      )
      .replaceAll('__REMOTE__', jsonEncode(remote))
      .replaceAll('__IMAGE__', jsonEncode(image));
  File('$dataDir/dartclaw.yaml').writeAsStringSync(rendered);
  stdout.writeln(jsonEncode(await fixture.retainWorkflowForInspection(dataDir, 'implement-story')));
}
