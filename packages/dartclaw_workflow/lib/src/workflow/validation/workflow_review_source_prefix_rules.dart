part of '../workflow_definition_validator.dart';

extension _WorkflowReviewSourcePrefixRules on WorkflowDefinitionValidator {
  /// Enforces step-id prefixing on review-key outputs of steps that feed an
  /// `aggregate-reviews` step.
  ///
  /// A review source's report-path (`review_report_path`), count
  /// (`findings_count` / `gating_findings_count`), and `verdict` outputs must be
  /// declared as `<stepId>.<key>`. A bare (or mis-prefixed) review key collides
  /// on the shared run context with the aggregator's own bare outputs — the
  /// aggregator would read the source's report as its own, and two sources would
  /// last-writer-wins into a single key. Prefixing is always collision-safe
  /// because the host accepts the review skill's bare-suffix emission via the
  /// filesystem-claim alias (`context_extractor.dart _fileSystemClaimKey`).
  ///
  /// The rule fires on aggregator presence: any source feeding an
  /// `aggregate-reviews` step, even a single one, because a source's bare
  /// `review_report_path` collides with the aggregator's bare output regardless
  /// of source count. Single-review workflows with no aggregator (e.g.
  /// `code-review.yaml`) are unaffected — their bare canonical keys are correct.
  void _validateReviewSourcePrefixing(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepsById = {for (final step in definition.steps) step.id: step};
    final reviewedSourceIds = <String>{
      for (final step in definition.steps)
        if (step.taskType == WorkflowTaskType.aggregateReviews) ...?step.aggregateReviews,
    };
    if (reviewedSourceIds.isEmpty) return;

    for (final sourceId in reviewedSourceIds) {
      final source = stepsById[sourceId];
      if (source == null) continue; // Unknown source id is reported by the aggregate-reviews constraints rule.
      final prefix = '$sourceId.';
      for (final entry in source.outputs?.entries ?? const <MapEntry<String, OutputConfig>>[]) {
        if (!_isReviewKeyPreset(entry.value.presetName)) continue;
        if (entry.key.startsWith(prefix)) continue;
        final bareSuffix = entry.key.split('.').last;
        errors.add(
          _contextErr(
            sourceId,
            'Review source step "$sourceId" feeds an aggregate-reviews step but declares an unprefixed review '
            'output "${entry.key}"; prefix it with the step id: "$sourceId.$bareSuffix". A bare review key collides '
            'with the aggregate-reviews step\'s own {review_report_path, findings_count, gating_findings_count} '
            'outputs on the shared context.',
          ),
        );
      }
    }
  }

  bool _isReviewKeyPreset(String? presetName) =>
      isReviewReportPathPreset(presetName) ||
      presetName == 'findings_count' ||
      presetName == 'gating_findings_count' ||
      presetName == 'verdict';
}
