import 'package:dartclaw_models/dartclaw_models.dart';

/// Resolved effective config for a step, merging per-step fields with the
/// first matching [StepConfigDefault] entry. Per-step explicit values win.
class ResolvedStepConfig {
  final String? provider;
  final String? model;
  final int? maxTokens;
  final double? maxCostUsd;
  final int? maxRetries;
  final List<String>? allowedTools;

  const ResolvedStepConfig({
    this.provider,
    this.model,
    this.maxTokens,
    this.maxCostUsd,
    this.maxRetries,
    this.allowedTools,
  });
}

/// Returns true if [pattern] glob-matches [stepId].
///
/// Supports `*` as a wildcard matching zero or more characters.
/// No other special characters (`?`, `**`, `[...]`) are supported.
/// Step IDs are expected to be kebab-case (e.g. `review-code`).
bool globMatchStepId(String pattern, String stepId) {
  if (!pattern.contains('*')) return pattern == stepId;
  // Translate * to .* and anchor the pattern.
  final regexStr = pattern.split('*').map(RegExp.escape).join('.*');
  return RegExp('^$regexStr\$').hasMatch(stepId);
}

/// Resolves the effective config for [step] given optional [defaults].
///
/// Iterates [defaults] in order — first entry whose [StepConfigDefault.match]
/// glob-matches [step.id] provides the defaults. First match wins; entries
/// are NOT merged. Per-step explicit fields take precedence over the matched
/// default's fields (field-level, from the ONE matching default).
ResolvedStepConfig resolveStepConfig(WorkflowStep step, List<StepConfigDefault>? defaults) {
  StepConfigDefault? matched;
  if (defaults != null) {
    for (final d in defaults) {
      if (globMatchStepId(d.match, step.id)) {
        matched = d;
        break;
      }
    }
  }

  return ResolvedStepConfig(
    provider: step.provider ?? matched?.provider,
    model: step.model ?? matched?.model,
    maxTokens: step.maxTokens ?? matched?.maxTokens,
    maxCostUsd: step.maxCostUsd ?? matched?.maxCostUsd,
    maxRetries: step.maxRetries ?? matched?.maxRetries,
    allowedTools: step.allowedTools ?? matched?.allowedTools,
  );
}
