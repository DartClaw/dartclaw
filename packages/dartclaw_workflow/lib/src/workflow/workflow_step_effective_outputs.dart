import 'workflow_definition.dart';

List<String> effectiveOutputKeysFor(WorkflowStep step, Map<String, OutputConfig>? effectiveOutputs) =>
    effectiveOutputs?.keys.toList(growable: false) ?? step.outputKeys;
