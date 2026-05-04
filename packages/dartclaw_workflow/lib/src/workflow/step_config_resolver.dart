import 'package:dartclaw_models/dartclaw_models.dart';

const workflowRoleDefaultAlias = '@workflow';
const plannerRoleDefaultAlias = '@planner';
const executorRoleDefaultAlias = '@executor';
const reviewerRoleDefaultAlias = '@reviewer';
const workflowRoleDefaultAliases = {
  workflowRoleDefaultAlias,
  plannerRoleDefaultAlias,
  executorRoleDefaultAlias,
  reviewerRoleDefaultAlias,
};

/// Provider/model defaults for workflow execution roles.
class WorkflowRoleDefault {
  final String? provider;
  final String? model;
  final String? effort;

  const WorkflowRoleDefault({this.provider, this.model, this.effort});
}

/// Runtime role defaults used when workflow YAML references `@workflow`,
/// `@planner`, `@executor`, or `@reviewer`.
class WorkflowRoleDefaults {
  final WorkflowRoleDefault workflow;
  final WorkflowRoleDefault planner;
  final WorkflowRoleDefault executor;
  final WorkflowRoleDefault reviewer;

  const WorkflowRoleDefaults({
    this.workflow = const WorkflowRoleDefault(),
    this.planner = const WorkflowRoleDefault(),
    this.executor = const WorkflowRoleDefault(),
    this.reviewer = const WorkflowRoleDefault(),
  });

  WorkflowRoleDefault resolve(String alias) {
    final specific = switch (alias) {
      workflowRoleDefaultAlias => workflow,
      plannerRoleDefaultAlias => planner,
      executorRoleDefaultAlias => executor,
      reviewerRoleDefaultAlias => reviewer,
      _ => const WorkflowRoleDefault(),
    };

    if (alias == workflowRoleDefaultAlias) {
      return workflow;
    }
    return WorkflowRoleDefault(
      provider: specific.provider ?? workflow.provider,
      model: specific.model ?? workflow.model,
      effort: specific.effort ?? workflow.effort,
    );
  }
}

/// Resolved effective config for a step, merging per-step fields with the
/// first matching [StepConfigDefault] entry. Per-step explicit values win.
class ResolvedStepConfig {
  final String? provider;
  final String? model;
  final String? effort;
  final int? maxTokens;
  final double? maxCostUsd;
  final int? maxRetries;
  final List<String>? allowedTools;

  const ResolvedStepConfig({
    this.provider,
    this.model,
    this.effort,
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
ResolvedStepConfig resolveStepConfig(
  WorkflowStep step,
  List<StepConfigDefault>? defaults, {
  WorkflowRoleDefaults? roleDefaults,
}) {
  StepConfigDefault? matched;
  if (defaults != null) {
    for (final d in defaults) {
      if (globMatchStepId(d.match, step.id)) {
        matched = d;
        break;
      }
    }
  }

  final provider = _resolveAlias(step.provider ?? matched?.provider, roleDefaults, isProvider: true);
  final model = _resolveAlias(step.model ?? matched?.model, roleDefaults, isProvider: false);
  final effort = _resolveEffort(step.effort ?? matched?.effort, step.provider ?? matched?.provider, roleDefaults);

  return ResolvedStepConfig(
    provider: provider,
    model: model,
    effort: effort,
    maxTokens: step.maxTokens ?? matched?.maxTokens,
    maxCostUsd: step.maxCostUsd ?? matched?.maxCostUsd,
    maxRetries: step.maxRetries ?? matched?.maxRetries,
    allowedTools: step.allowedTools ?? matched?.allowedTools,
  );
}

String? _resolveAlias(String? value, WorkflowRoleDefaults? roleDefaults, {required bool isProvider}) {
  if (value == null) {
    return null;
  }
  final defaults = roleDefaults;
  if (defaults == null) {
    return value;
  }

  final role = workflowRoleDefaultAliases.contains(value) ? value : null;
  if (role == null) {
    return value;
  }

  final resolved = defaults.resolve(role);
  return isProvider ? resolved.provider : resolved.model;
}

/// Resolves [effort] — if null, falls back to the role default's effort when
/// the provider/model uses a role alias.
String? _resolveEffort(String? effort, String? providerOrModel, WorkflowRoleDefaults? roleDefaults) {
  if (effort != null) return effort;
  if (roleDefaults == null) return null;

  // Infer the role alias from provider or model (whichever is a role alias).
  final alias = providerOrModel;
  if (alias == null) return null;
  final role = workflowRoleDefaultAliases.contains(alias) ? alias : null;
  if (role == null) return null;
  return roleDefaults.resolve(role).effort;
}
