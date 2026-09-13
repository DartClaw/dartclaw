import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/src/workflow/workflow_schema_emitter.dart';

import '../test/fitness_support.dart';

const regenerationCommand = 'dart run packages/dartclaw_workflow/tool/generate_workflow_schema.dart';

String renderWorkflowJsonSchema() => '${const JsonEncoder.withIndent('  ').convert(emitWorkflowJsonSchema())}\n';

bool workflowSchemaIsCurrent(File artifact, String rendered) =>
    artifact.existsSync() && artifact.readAsStringSync() == rendered;

String workflowSchemaDriftMessage(String artifactPath) =>
    '$artifactPath has drifted from WorkflowDslRules. Regenerate with: $regenerationCommand';

Future<void> main(List<String> args) async {
  final root = resolveRepoRoot();
  final artifact = File('$root/schemas/workflow.schema.json');
  final rendered = renderWorkflowJsonSchema();
  if (args.contains('--check')) {
    if (!workflowSchemaIsCurrent(artifact, rendered)) {
      stderr.writeln(workflowSchemaDriftMessage(artifact.path));
      exitCode = 1;
      return;
    }
    stdout.writeln('${artifact.path} is up to date');
    return;
  }
  artifact.parent.createSync(recursive: true);
  artifact.writeAsStringSync(rendered);
  stdout.writeln('Wrote ${artifact.path}');
}
