import 'package:dartclaw_workflow/dartclaw_workflow.dart' show OutputConfig, OutputFormat, WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/execution_envelope_schema.dart' show buildExecutionEnvelopeSchema;
import 'package:test/test.dart';

void main() {
  test('scalar path constraint reaches the finalizer while null remains claimable', () {
    const step = WorkflowStep(
      id: 'spec',
      name: 'Generate Specification',
      outputs: {
        'spec_path': OutputConfig(format: OutputFormat.path, schema: {'type': 'string', 'minLength': 1}),
      },
    );

    final schema = buildExecutionEnvelopeSchema(step, step.outputs)!;
    final outputs = (schema['properties'] as Map<String, dynamic>)['outputs'] as Map<String, dynamic>;
    final path = (outputs['properties'] as Map<String, dynamic>)['spec_path'] as Map<String, dynamic>;
    expect(path['type'], ['string', 'null']);
    expect(path['minLength'], 1);
  });
}
