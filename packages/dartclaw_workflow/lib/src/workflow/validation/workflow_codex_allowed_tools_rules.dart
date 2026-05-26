part of '../workflow_definition_validator.dart';

extension _WorkflowCodexAllowedToolsRules on WorkflowDefinitionValidator {
  void _warnCodexAllowedToolsPolicy(WorkflowDefinition definition, List<ValidationError> warnings) {
    for (final step in definition.steps) {
      final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: roleDefaults);
      if (resolved.provider != 'codex') continue;
      final allowedTools = resolved.allowedTools;
      if (allowedTools == null || allowedTools.isEmpty || _isReadOnlyToolPolicy(allowedTools)) continue;

      final message =
          'Workflow "${definition.name}" step "${step.id}" declares non-read-only allowedTools for Codex. '
          'Codex CLI has no native tool allowlist; allowedTools is advisory while sandbox/approval policy carries '
          'enforcement.';
      warnings.add(_err(ValidationErrorType.unsupportedProviderCapability, message, stepId: step.id));
    }
  }

  bool _isReadOnlyToolPolicy(List<String> allowedTools) =>
      !allowedTools.contains('file_write') && !allowedTools.contains('file_edit');
}
