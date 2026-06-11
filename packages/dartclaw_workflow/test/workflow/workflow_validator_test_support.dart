// Shared spine builders + matcher for the split validator suites.
//
// `workflow_definition_validator_test.dart` was split along the production rule
// axis (lib/src/workflow/validation/*_rules.dart) into six sibling files; they
// all import these helpers so the `WorkflowDefinition(name:'wf', ...)` spine and
// the `errors.any((e) => e.type == ... && e.stepId == ...)` assertion shape are
// declared once.
import 'package:dartclaw_workflow/dartclaw_workflow.dart';

/// Builds a [WorkflowDefinition] with throwaway name/description and a single
/// default agent step when [steps] is empty. Mirrors the historical `_buildDef`.
WorkflowDefinition buildDef({
  String name = 'test',
  String description = 'Test workflow',
  Map<String, WorkflowVariable> variables = const {},
  List<WorkflowStep> steps = const [],
  List<WorkflowLoop> loops = const [],
  List<WorkflowNode>? nodes,
  WorkflowGitStrategy? gitStrategy,
  List<StepConfigDefault>? stepDefaults,
}) {
  return WorkflowDefinition(
    name: name,
    description: description,
    variables: variables,
    steps: steps.isEmpty
        ? [
            const WorkflowStep(id: 's1', name: 'S1', prompts: ['Do it']),
          ]
        : steps,
    loops: loops,
    nodes: nodes,
    gitStrategy: gitStrategy,
    stepDefaults: stepDefaults,
  );
}

/// A single agent step with the most common overridable fields.
WorkflowStep step({
  String id = 's1',
  String name = 'Step',
  String prompt = 'Do it',
  List<String> inputs = const [],
  Map<String, OutputConfig>? outputs,
  String? gate,
}) => WorkflowStep(
  id: id,
  name: name,
  prompts: [prompt],
  inputs: inputs,
  outputs: outputs == null || outputs.isEmpty ? null : outputs,
  gate: gate,
);

/// A review-source step emitting the fixed review-report + count keys an
/// aggregate-reviews step consumes. Defaults the count keys to source-scoped ids.
WorkflowStep reviewSourceStep({required String id, Map<String, OutputConfig>? outputs}) => WorkflowStep(
  id: id,
  name: id,
  prompts: const ['p'],
  outputs:
      outputs ??
      {
        'review_findings': const OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
        '$id.findings_count': const OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
        '$id.gating_findings_count': const OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
      },
);

/// An aggregate-reviews step with the fixed three-key output shape by default.
WorkflowStep aggregateReviewsStep({
  List<String>? aggregateReviews = const ['review-a'],
  Map<String, OutputConfig>? outputs,
}) => WorkflowStep(
  id: 'review-aggregate',
  name: 'Review Aggregate',
  type: WorkflowTaskType.aggregateReviews,
  aggregateReviews: aggregateReviews,
  outputs:
      outputs ??
      const {
        'review_findings': OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
        'findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
        'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
      },
);

/// Returns `true` when [errors] contains an entry matching all supplied
/// constraints. Any unspecified constraint is treated as a wildcard.
bool hasError(
  List<ValidationError> errors, {
  ValidationErrorType? type,
  String? stepId,
  String? loopId,
  String? messageContains,
}) => errors.any(
  (e) =>
      (type == null || e.type == type) &&
      (stepId == null || e.stepId == stepId) &&
      (loopId == null || e.loopId == loopId) &&
      (messageContains == null || e.message.contains(messageContains)),
);
