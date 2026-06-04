import 'workflow_definition.dart';

Map<String, OutputConfig>? effectiveOutputsFor(WorkflowStep step) => step.outputs;

List<String> effectiveOutputKeysFor(WorkflowStep step, Map<String, OutputConfig>? effectiveOutputs) =>
    effectiveOutputs?.keys.toList(growable: false) ?? step.outputKeys;
