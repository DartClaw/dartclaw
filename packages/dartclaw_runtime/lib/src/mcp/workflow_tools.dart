import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';

import '../task/workflow_start_precondition_exception.dart';
import 'tool_schema.dart';

/// MCP tool that starts a named workflow through the existing workflow service.
///
/// A thin adapter: required-variable validation, declared defaults and the
/// `PROJECT` fallback all live in [WorkflowService.start], and duplicating any
/// of them here would fork the rule the HTTP start route already follows.
class WorkflowRunTool implements McpTool {
  new({required WorkflowDefinitionSource definitions, required WorkflowService workflows})
    : _definitions = definitions,
      _workflows = workflows;

  final WorkflowDefinitionSource _definitions;
  final WorkflowService _workflows;

  @override
  String get name => 'workflow_run';

  @override
  String get description =>
      'Start a registered workflow. List the catalog with workflow_list first — it carries each definition\'s '
      'required and optional variables. The run appears in the run store and the web UI like any other.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      'definition': {'type': 'string', 'description': 'Workflow definition name, as returned by workflow_list.'},
      'variables': {
        'type': 'object',
        'additionalProperties': {'type': 'string'},
        'description': 'Values for the definition\'s declared variables, keyed by variable name.',
      },
      'project': {
        'type': 'string',
        'description': 'Project the run belongs to; satisfies a declared PROJECT variable.',
      },
    },
    const ['definition'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final definitionName = args['definition'] as String;
    final definition = _definitions.getByName(definitionName);
    if (definition == null) {
      return toolError('unknown_definition', 'No workflow definition named $definitionName', {
        'definition': definitionName,
      });
    }

    final variables = <String, String>{
      for (final entry in (args['variables'] as Map? ?? const {}).entries) '${entry.key}': entry.value as String,
    };
    final project = args['project'] as String? ?? variables['PROJECT'];

    final WorkflowRun run;
    try {
      run = await _workflows.start(definition, variables, projectId: project);
    } on ArgumentError catch (error) {
      return toolError('invalid_variables', '${error.message}', {'definition': definitionName});
    } on WorkflowStartPreconditionException catch (error) {
      return toolError('precondition_failed', error.message, {'definition': definitionName});
    }
    return toolJson({
      'run_id': run.id,
      'definition': run.definitionName,
      'status': run.status.name,
      'location': '/workflows/${run.id}',
      'variables': run.variablesJson,
    });
  }
}

/// MCP tool that lists the workflow catalog with each definition's variables.
class WorkflowListTool implements McpTool {
  new({required WorkflowDefinitionSource definitions}) : _definitions = definitions;

  final WorkflowDefinitionSource _definitions;

  @override
  String get name => 'workflow_list';

  @override
  String get description =>
      'List the registered workflow definitions with their descriptions and declared variables, so workflow_run can '
      'be called with the right parameters without a second lookup.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(const {}, const []);

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    return toolJson({
      'workflows': [
        for (final summary in _definitions.listSummaries())
          {
            'name': summary.name,
            'description': summary.description,
            'step_count': summary.stepCount,
            'variables': [
              for (final entry in summary.variables.entries)
                {
                  'name': entry.key,
                  'required': entry.value.required,
                  'description': entry.value.description,
                  if (entry.value.defaultValue != null) 'default': entry.value.defaultValue,
                },
            ],
          },
      ],
    });
  }
}
