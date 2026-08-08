import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig, WorkflowRoleModelConfig;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRoleDefault, WorkflowRoleDefaults;

WorkflowRoleDefaults workflowRoleDefaultsFromConfig(DartclawConfig config) {
  final defaults = config.workflow.defaults;
  return WorkflowRoleDefaults(
    workflow: _roleDefault(defaults.workflow),
    planner: _roleDefault(defaults.planner),
    executor: _roleDefault(defaults.executor),
    reviewer: _roleDefault(defaults.reviewer),
  );
}

WorkflowRoleDefault _roleDefault(WorkflowRoleModelConfig config) {
  return WorkflowRoleDefault(provider: config.provider, model: config.model, effort: config.effort);
}
