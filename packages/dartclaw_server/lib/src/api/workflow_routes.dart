import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        LoopIterationCompletedEvent,
        ParallelGroupCompletedEvent,
        Task,
        TaskStatusChangedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowCliTurnProgressEvent,
        WorkflowApprovalResolvedEvent,
        WorkflowLifecycleEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowApprovalPolicy,
        WorkflowDefinition,
        WorkflowDefinitionResolver,
        WorkflowDefinitionSource,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowService,
        WorkflowSummary,
        WorkflowTaskType,
        missingRequiredWorkflowVariables,
        missingRequiredWorkflowVariablesMessage,
        stepStatusFromTask;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../task/task_service.dart';
import '../task/workflow_start_precondition_exception.dart';
import 'api_helpers.dart';
import 'sse_broadcast.dart';

final _log = Logger('WorkflowRoutes');
const _maxWorkflowJsonBodyBytes = 256 * 1024;
const _maxWorkflowFormBodyBytes = 256 * 1024;

/// Creates a [Router] exposing workflow lifecycle API endpoints.
///
/// All endpoints require authentication (handled by the server pipeline).
/// Business logic delegated to [WorkflowService] — routes are thin
/// request/response translators.
Router workflowRoutes(
  WorkflowService workflows,
  TaskService tasks,
  WorkflowDefinitionSource definitions, {
  EventBus? eventBus,
}) {
  final router = Router();
  final resolver = WorkflowDefinitionResolver();

  // POST /api/workflows/run
  router.post('/api/workflows/run', (Request request) async {
    final parsed = await _parseWorkflowRunJsonRequest(request, definitions);
    return _startWorkflowResponse(parsed, workflows);
  });

  // POST /api/workflows/run-form
  router.post('/api/workflows/run-form', (Request request) async {
    final parsed = await _parseWorkflowRunFormRequest(request, definitions);
    return _startWorkflowResponse(parsed, workflows, htmlResponse: true);
  });

  // GET /api/workflows/runs
  router.get('/api/workflows/runs', (Request request) async {
    try {
      final params = request.url.queryParameters;
      final statusParam = params['status'];
      final status = statusParam != null ? WorkflowRunStatus.values.asNameMap()[statusParam] : null;
      final definitionName = params['definition'];

      final runs = await workflows.list(status: status, definitionName: definitionName);
      return jsonResponse(200, runs.map((r) => r.toJson()).toList());
    } catch (e, st) {
      _log.severe('Failed to list workflow runs', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list workflow runs');
    }
  });

  // GET /api/workflows/runs/<id>
  router.get('/api/workflows/runs/<id>', (Request request, String id) async {
    try {
      final run = await workflows.get(id);
      if (run == null) {
        return errorResponse(404, 'WORKFLOW_RUN_NOT_FOUND', 'Workflow run not found: $id');
      }
      final enriched = await _enrichRunDetail(run, tasks);
      return jsonResponse(200, enriched);
    } catch (e, st) {
      _log.severe('Failed to get workflow run $id', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get workflow run');
    }
  });

  // POST /api/workflows/runs/<id>/pause
  router.post('/api/workflows/runs/<id>/pause', (Request request, String id) async {
    try {
      final existing = await workflows.get(id);
      if (existing == null) {
        return errorResponse(404, 'WORKFLOW_RUN_NOT_FOUND', 'Workflow run not found: $id');
      }
      final run = await workflows.pause(id);
      return jsonResponse(200, run.toJson());
    } on StateError catch (e) {
      return errorResponse(409, 'INVALID_TRANSITION', e.message);
    } catch (e, st) {
      _log.severe('Failed to pause workflow run $id', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to pause workflow run');
    }
  });

  // POST /api/workflows/runs/<id>/resume
  router.post('/api/workflows/runs/<id>/resume', (Request request, String id) async {
    try {
      final existing = await workflows.get(id);
      if (existing == null) {
        return errorResponse(404, 'WORKFLOW_RUN_NOT_FOUND', 'Workflow run not found: $id');
      }
      final run = await workflows.resume(id);
      return jsonResponse(200, run.toJson());
    } on StateError catch (e) {
      return errorResponse(409, 'INVALID_TRANSITION', e.message);
    } catch (e, st) {
      _log.severe('Failed to resume workflow run $id', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to resume workflow run');
    }
  });

  // POST /api/workflows/runs/<id>/retry
  router.post('/api/workflows/runs/<id>/retry', (Request request, String id) async {
    try {
      final existing = await workflows.get(id);
      if (existing == null) {
        return errorResponse(404, 'WORKFLOW_RUN_NOT_FOUND', 'Workflow run not found: $id');
      }
      final run = await workflows.retry(id);
      return jsonResponse(200, run.toJson());
    } on StateError catch (e) {
      return errorResponse(409, 'INVALID_TRANSITION', e.message);
    } catch (e, st) {
      _log.severe('Failed to retry workflow run $id', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to retry workflow run');
    }
  });

  // POST /api/workflows/runs/<id>/cancel
  router.post('/api/workflows/runs/<id>/cancel', (Request request, String id) async {
    try {
      final existing = await workflows.get(id);
      if (existing == null) {
        return errorResponse(404, 'WORKFLOW_RUN_NOT_FOUND', 'Workflow run not found: $id');
      }
      if (existing.status.terminal) {
        return errorResponse(
          409,
          'INVALID_TRANSITION',
          'Workflow run is already in a terminal state: ${existing.status.name}',
        );
      }
      // Optional body: { "feedback": "..." } for approval rejection feedback.
      String? feedback;
      final contentType = request.headers['content-type'] ?? '';
      if (contentType.contains('application/json')) {
        final body = await readJsonObject(request, maxBytes: _maxWorkflowJsonBodyBytes);
        if (body.error != null) return body.error;
        if (body.value != null) {
          final feedbackField = body.value!['feedback'];
          if (feedbackField is String && feedbackField.trim().isNotEmpty) {
            feedback = feedbackField.trim();
          }
        }
      }
      await workflows.cancel(id, feedback: feedback);
      return Response(204);
    } catch (e, st) {
      _log.severe('Failed to cancel workflow run $id', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to cancel workflow run');
    }
  });

  // GET /api/workflows/definitions
  router.get('/api/workflows/definitions', (Request request) async {
    try {
      final summaries = definitions.listSummaries();
      return jsonResponse(200, summaries.map(_summaryToJson).toList());
    } catch (e, st) {
      _log.severe('Failed to list workflow definitions', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list workflow definitions');
    }
  });

  // GET /api/workflows/definitions/<name>
  // Query params:
  //   resolve=true         → returns YAML with stepDefaults applied
  //   step=<id>            → (with resolve=true) slices to a single resolved step
  router.get('/api/workflows/definitions/<name>', (Request request, String name) async {
    try {
      final def = definitions.getByName(name);
      if (def == null) {
        return errorResponse(404, 'DEFINITION_NOT_FOUND', 'Workflow definition not found: $name');
      }

      final params = request.url.queryParameters;
      final shouldResolve = params['resolve'] == 'true';
      if (!shouldResolve) {
        final authored = definitions.authoredYaml(name) ?? resolver.emitYaml(def);
        return Response.ok(authored, headers: {'content-type': 'application/yaml; charset=utf-8'});
      }

      final resolved = resolver.resolve(def);
      final stepId = params['step'];
      if (stepId != null && stepId.isNotEmpty) {
        final slice = resolver.sliceStep(resolved, stepId);
        if (slice == null) {
          return errorResponse(404, 'STEP_NOT_FOUND', 'Step "$stepId" not found in workflow "$name"');
        }
        return Response.ok(resolver.emitYaml(slice), headers: {'content-type': 'application/yaml; charset=utf-8'});
      }

      return Response.ok(resolver.emitYaml(resolved), headers: {'content-type': 'application/yaml; charset=utf-8'});
    } catch (e, st) {
      _log.severe('Failed to get workflow definition $name', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get workflow definition');
    }
  });

  // GET /api/workflows/runs/<id>/events — per-run SSE stream.
  router.get('/api/workflows/runs/<id>/events', (Request request, String id) async {
    final bus = eventBus;
    if (bus == null) {
      return errorResponse(503, 'SERVICE_UNAVAILABLE', 'Event bus not configured');
    }
    return _workflowRunSseHandler(id, workflows, tasks, bus);
  });

  return router;
}

typedef _ParsedWorkflowRunRequest = ({
  WorkflowDefinition? definition,
  Map<String, String> variables,
  String? projectId,
  WorkflowApprovalPolicy? approvals,
  bool allowDirtyLocalPath,
  bool inline,
  Response? error,
});

Future<_ParsedWorkflowRunRequest> _parseWorkflowRunJsonRequest(
  Request request,
  WorkflowDefinitionSource definitions,
) async {
  final body = await readJsonObject(request, maxBytes: _maxWorkflowJsonBodyBytes);
  if (body.error != null) {
    return (
      definition: null,
      variables: const <String, String>{},
      projectId: null,
      approvals: null,
      allowDirtyLocalPath: false,
      inline: false,
      error: body.error,
    );
  }
  final definitionField = body.value!['definition'];
  if (definitionField == null) {
    return (
      definition: null,
      variables: const <String, String>{},
      projectId: null,
      approvals: null,
      allowDirtyLocalPath: false,
      inline: false,
      error: errorResponse(400, 'INVALID_INPUT', 'Missing required field: definition'),
    );
  }
  if (definitionField is! String || definitionField.trim().isEmpty) {
    return (
      definition: null,
      variables: const <String, String>{},
      projectId: null,
      approvals: null,
      allowDirtyLocalPath: false,
      inline: false,
      error: errorResponse(400, 'INVALID_INPUT', 'Field "definition" must be a non-empty string'),
    );
  }

  final definition = definitions.getByName(definitionField.trim());
  if (definition == null) {
    return (
      definition: null,
      variables: const <String, String>{},
      projectId: null,
      approvals: null,
      allowDirtyLocalPath: false,
      inline: false,
      error: errorResponse(404, 'DEFINITION_NOT_FOUND', 'Workflow definition not found: $definitionField'),
    );
  }

  final variablesField = body.value!['variables'];
  if (variablesField != null && variablesField is! Map) {
    return (
      definition: null,
      variables: const <String, String>{},
      projectId: null,
      approvals: null,
      allowDirtyLocalPath: false,
      inline: false,
      error: errorResponse(400, 'INVALID_INPUT', 'Field "variables" must be an object', {'field': 'variables'}),
    );
  }
  final rawVariables = variablesField as Map? ?? const {};
  final variables = <String, String>{
    for (final entry in rawVariables.entries) entry.key.toString(): entry.value.toString(),
  };
  final projectField = body.value!['project'];
  final projectId = projectField is String && projectField.trim().isNotEmpty ? projectField.trim() : null;
  final approvalsResult = _parseApprovalPolicy(body.value!['approvals']);
  if (approvalsResult.error != null) {
    return (
      definition: null,
      variables: const <String, String>{},
      projectId: null,
      approvals: null,
      allowDirtyLocalPath: false,
      inline: false,
      error: approvalsResult.error,
    );
  }
  final allowDirtyLocalPath = body.value!['allowDirtyLocalPath'] == true;
  final inline = body.value!['inline'] == true;
  if (projectId != null && definition.variables.containsKey('PROJECT') && !variables.containsKey('PROJECT')) {
    variables['PROJECT'] = projectId;
  }

  final validationError = _validateWorkflowVariables(definition, variables);
  return (
    definition: definition,
    variables: variables,
    projectId: projectId,
    approvals: approvalsResult.policy,
    allowDirtyLocalPath: allowDirtyLocalPath,
    inline: inline,
    error: validationError,
  );
}

Future<_ParsedWorkflowRunRequest> _parseWorkflowRunFormRequest(
  Request request,
  WorkflowDefinitionSource definitions,
) async {
  final bodyResult = await readRequestBody(request, maxBytes: _maxWorkflowFormBodyBytes);
  if (bodyResult.error != null) {
    return (
      definition: null,
      variables: const <String, String>{},
      projectId: null,
      approvals: null,
      allowDirtyLocalPath: false,
      inline: false,
      error: bodyResult.error,
    );
  }
  final body = Uri.splitQueryString(bodyResult.body!);
  final definitionName = body['definition']?.trim();
  if (definitionName == null || definitionName.isEmpty) {
    return (
      definition: null,
      variables: const <String, String>{},
      projectId: null,
      approvals: null,
      allowDirtyLocalPath: false,
      inline: false,
      error: _workflowFormError('Workflow definition is required.'),
    );
  }
  final definition = definitions.getByName(definitionName);
  if (definition == null) {
    return (
      definition: null,
      variables: const <String, String>{},
      projectId: null,
      approvals: null,
      allowDirtyLocalPath: false,
      inline: false,
      error: _workflowFormError('Workflow definition not found: $definitionName'),
    );
  }
  final variables = <String, String>{
    for (final entry in body.entries)
      if (entry.key.startsWith('var_') && entry.value.trim().isNotEmpty) entry.key.substring(4): entry.value.trim(),
  };
  final projectId = body['project']?.trim().isNotEmpty == true ? body['project']!.trim() : null;
  final allowDirtyLocalPath = switch (body['allowDirtyLocalPath']?.trim().toLowerCase()) {
    '1' || 'true' || 'on' => true,
    _ => false,
  };
  if (projectId != null && definition.variables.containsKey('PROJECT') && !variables.containsKey('PROJECT')) {
    variables['PROJECT'] = projectId;
  }
  final validationError = _validateWorkflowVariables(definition, variables, htmlResponse: true);
  return (
    definition: definition,
    variables: variables,
    projectId: projectId,
    approvals: null,
    allowDirtyLocalPath: allowDirtyLocalPath,
    inline: false,
    error: validationError,
  );
}

({WorkflowApprovalPolicy? policy, Response? error}) _parseApprovalPolicy(Object? raw) {
  if (raw == null) return (policy: null, error: null);
  if (raw is! String || raw.trim().isEmpty) {
    return (
      policy: null,
      error: errorResponse(400, 'INVALID_INPUT', 'Field "approvals" must be one of: manual, auto-on-stall, auto', {
        'field': 'approvals',
        'allowedValues': ['manual', 'auto-on-stall', 'auto'],
      }),
    );
  }
  final policy = WorkflowApprovalPolicy.fromYaml(raw);
  if (policy != null) return (policy: policy, error: null);
  return (
    policy: null,
    error: errorResponse(400, 'INVALID_INPUT', 'Field "approvals" must be one of: manual, auto-on-stall, auto', {
      'field': 'approvals',
      'allowedValues': ['manual', 'auto-on-stall', 'auto'],
    }),
  );
}

Response? _validateWorkflowVariables(
  WorkflowDefinition definition,
  Map<String, String> variables, {
  bool htmlResponse = false,
}) {
  final missing = missingRequiredWorkflowVariables(definition, variables);
  if (missing.isEmpty) {
    return null;
  }
  final message = missingRequiredWorkflowVariablesMessage(missing);
  return htmlResponse
      ? _workflowFormError(message)
      : errorResponse(400, 'INVALID_INPUT', message, {'missingVariables': missing});
}

Future<Response> _startWorkflowResponse(
  _ParsedWorkflowRunRequest parsed,
  WorkflowService workflows, {
  bool htmlResponse = false,
}) async {
  if (parsed.error != null) {
    return parsed.error!;
  }
  final definition = parsed.definition!;
  try {
    final run = await workflows.start(
      definition,
      parsed.variables,
      projectId: parsed.projectId,
      approvals: parsed.approvals,
      allowDirtyLocalPath: parsed.allowDirtyLocalPath,
      inline: parsed.inline,
    );
    if (htmlResponse) {
      final location = '/workflows/${run.id}';
      return Response(201, headers: {'HX-Location': location, 'content-type': 'text/html; charset=utf-8'});
    }
    return jsonResponse(201, run.toJson());
  } on ArgumentError catch (e) {
    return htmlResponse
        ? _workflowFormError(e.message.toString())
        : errorResponse(400, 'INVALID_INPUT', e.message.toString());
  } on WorkflowStartPreconditionException catch (e) {
    return htmlResponse ? _workflowFormError(e.message) : errorResponse(409, 'WORKFLOW_PRECONDITION_FAILED', e.message);
  } on StateError catch (e) {
    _log.severe('Failed to start workflow', e);
    return htmlResponse
        ? _workflowFormError('Failed to start workflow')
        : errorResponse(500, 'INTERNAL_ERROR', 'Failed to start workflow');
  } catch (e, st) {
    _log.severe('Failed to start workflow', e, st);
    return htmlResponse
        ? _workflowFormError('Failed to start workflow')
        : errorResponse(500, 'INTERNAL_ERROR', 'Failed to start workflow');
  }
}

/// Renders an inline workflow-form error as an HTMX-swappable fragment.
///
/// Returns HTTP 200 (not 4xx/5xx) so HTMX's default `responseHandling` swaps
/// the fragment into the form's `hx-target`; on a 4xx/5xx the body is dropped
/// and the launch error vanishes from the UI. The JSON API path surfaces the
/// real status code via [errorResponse] instead.
Response _workflowFormError(String message) {
  return Response(
    200,
    body: '<span class="form-error-text">${htmlEscape.convert(message)}</span>',
    headers: {'content-type': 'text/html; charset=utf-8'},
  );
}

/// Enriches a [WorkflowRun] with per-step status and child task IDs.
Future<Map<String, dynamic>> _enrichRunDetail(WorkflowRun run, TaskService tasks) async {
  WorkflowDefinition definition;
  try {
    definition = WorkflowDefinition.fromJson(run.definitionJson);
  } catch (e) {
    _log.warning('Failed to deserialize definitionJson for run ${run.id}: $e');
    return run.toJson();
  }

  final allTasks = await tasks.list();
  final childTasks = allTasks.where((t) => t.workflowRunId == run.id).toList();
  final tasksByStepIndex = <int, Task>{
    for (final t in childTasks)
      if (t.stepIndex != null) t.stepIndex!: t,
  };

  final steps = <Map<String, dynamic>>[];
  for (var i = 0; i < definition.steps.length; i++) {
    final step = definition.steps[i];
    final task = tasksByStepIndex[i];
    final stepEntry = <String, dynamic>{
      'index': i,
      'id': step.id,
      'name': step.name,
      'type': step.taskType.toJson(),
      'status': _stepStatusWithApproval(run, i, step.id, step.taskType, task),
      'taskId': task?.id,
    };
    // Attach approval metadata for approval-type steps.
    if (step.taskType == WorkflowTaskType.approval) {
      final approvalStatus = run.contextJson['${step.id}.approval.status'];
      if (approvalStatus != null) {
        stepEntry['approval'] = {
          'status': approvalStatus,
          'message': run.contextJson['${step.id}.approval.message'],
          'requestedAt': run.contextJson['${step.id}.approval.requested_at'],
          if (run.contextJson['${step.id}.approval.resolved_at'] != null)
            'resolvedAt': run.contextJson['${step.id}.approval.resolved_at'],
          if (run.contextJson['${step.id}.approval.feedback'] != null)
            'feedback': run.contextJson['${step.id}.approval.feedback'],
          if (run.contextJson['${step.id}.approval.timeout_deadline'] != null)
            'timeoutDeadline': run.contextJson['${step.id}.approval.timeout_deadline'],
          if (run.contextJson['${step.id}.approval.cancel_reason'] != null)
            'cancelReason': run.contextJson['${step.id}.approval.cancel_reason'],
        };
      }
    }
    steps.add(stepEntry);
  }

  final childTaskIds = childTasks.map((t) => t.id).toList();
  final pendingApprovalStepId = run.contextJson['_approval.pending.stepId'] as String?;
  return run.toJson()
    ..['steps'] = steps
    ..['childTaskIds'] = childTaskIds
    ..['isApprovalPaused'] = pendingApprovalStepId != null
    ..['pendingApprovalStepId'] = pendingApprovalStepId;
}

/// Returns step status, handling approval-type steps which have no child task.
String _stepStatusWithApproval(WorkflowRun run, int index, String stepId, WorkflowTaskType stepType, Task? task) {
  if (stepType == WorkflowTaskType.approval) {
    final approvalStatus = run.contextJson['$stepId.approval.status'];
    return switch (approvalStatus) {
      'pending' => 'awaiting_approval',
      'approved' => 'completed',
      'rejected' => 'rejected',
      'timed_out' => 'timed_out',
      _ => index < run.currentStepIndex ? 'pending' : 'pending',
    };
  }
  return stepStatusFromTask(run, index, task, stepId: stepId);
}

Map<String, dynamic> _summaryToJson(WorkflowSummary s) => {
  'name': s.name,
  'description': s.description,
  'stepCount': s.stepCount,
  'variables': {
    for (final entry in s.variables.entries)
      entry.key: {
        'required': entry.value.required,
        'description': entry.value.description,
        'default': entry.value.defaultValue,
      },
  },
  'hasLoops': s.hasLoops,
  'maxTokens': s.maxTokens,
};

/// Per-run SSE handler — streams workflow lifecycle and child task status events.
Future<Response> _workflowRunSseHandler(
  String runId,
  WorkflowService workflows,
  TaskService tasks,
  EventBus eventBus,
) async {
  final run = await workflows.get(runId);
  if (run == null) {
    return Response.notFound(jsonEncode({'error': 'Workflow run not found: $runId'}));
  }

  final controller = StreamController<List<int>>();

  // Track known child task IDs for TaskStatusChangedEvent filtering.
  final childTaskIds = <String>{};
  final allTasks = await tasks.list();
  for (final t in allTasks) {
    if (t.workflowRunId == runId) childTaskIds.add(t.id);
  }

  // Build connected payload with current run state and step statuses.
  WorkflowDefinition definition;
  try {
    definition = WorkflowDefinition.fromJson(run.definitionJson);
  } catch (e) {
    _log.warning('Failed to deserialize definitionJson for run $runId: $e');
    definition = WorkflowDefinition(name: run.definitionName, description: '', steps: const [], variables: const {});
  }
  final tasksByStepIndex = <int, Task>{
    for (final t in allTasks.where((t) => t.workflowRunId == runId))
      if (t.stepIndex != null) t.stepIndex!: t,
  };
  final stepsPayload = [
    for (var i = 0; i < definition.steps.length; i++)
      {
        'index': i,
        'id': definition.steps[i].id,
        'name': definition.steps[i].name,
        'status': stepStatusFromTask(run, i, tasksByStepIndex[i], stepId: definition.steps[i].id),
        'taskId': tasksByStepIndex[i]?.id,
      },
  ];
  sendSseData(controller, {
    'type': 'connected',
    'run': {
      'id': run.id,
      'status': run.status.name,
      'currentStepIndex': run.currentStepIndex,
      'totalTokens': run.totalTokens,
    },
    'steps': stepsPayload,
  });

  // Subscribe to workflow lifecycle events.
  final runStatusSub = eventBus.on<WorkflowRunStatusChangedEvent>().where((e) => e.runId == runId).listen((event) {
    sendSseData(controller, event.toJson());
  });

  final stepCompletedSub = eventBus.on<WorkflowStepCompletedEvent>().where((e) => e.runId == runId).listen((
    event,
  ) async {
    childTaskIds.add(event.taskId);
    final task = event.taskId.isEmpty ? null : await tasks.get(event.taskId);
    final displayScope = event.displayScope ?? _taskDisplayScope(task);
    sendSseData(controller, _workflowEventPayload(event, displayScope: displayScope));
  });

  final parallelSub = eventBus.on<ParallelGroupCompletedEvent>().where((e) => e.runId == runId).listen((event) {
    sendSseData(controller, event.toJson());
  });

  final loopSub = eventBus.on<LoopIterationCompletedEvent>().where((e) => e.runId == runId).listen((event) {
    sendSseData(controller, event.toJson());
  });

  final mapIterationSub = eventBus.on<MapIterationCompletedEvent>().where((e) => e.runId == runId).listen((event) {
    sendSseData(controller, event.toJson());
  });

  final mapStepSub = eventBus.on<MapStepCompletedEvent>().where((e) => e.runId == runId).listen((event) {
    sendSseData(controller, event.toJson());
  });

  final taskStatusSub = eventBus.on<TaskStatusChangedEvent>().listen((event) async {
    final task = await tasks.get(event.taskId);
    if (task?.workflowRunId != runId) return;
    childTaskIds.add(event.taskId);
    final displayScope = _taskDisplayScope(task);
    final payload = <String, dynamic>{
      'type': 'task_status_changed',
      'taskId': event.taskId,
      'oldStatus': event.oldStatus.name,
      'newStatus': event.newStatus.name,
    };
    final stepIndex = task?.stepIndex;
    if (stepIndex != null) {
      payload['stepIndex'] = stepIndex;
    }
    if (displayScope != null) {
      payload['displayScope'] = displayScope;
    }
    sendSseData(controller, payload);
  });

  // Live per-step token ticks. The event carries no runId, so resolve the
  // owning run via the task (same approach as taskStatusSub above).
  final tokenProgressSub = eventBus.on<WorkflowCliTurnProgressEvent>().listen((event) async {
    final task = await tasks.get(event.taskId);
    if (task?.workflowRunId != runId) return;
    sendSseData(controller, {
      'type': 'workflow_cli_turn_progress',
      'taskId': event.taskId,
      'cumulativeTokens': event.cumulativeTokens,
    });
  });

  final approvalRequestedSub = eventBus.on<WorkflowApprovalRequestedEvent>().where((e) => e.runId == runId).listen((
    event,
  ) {
    sendSseData(controller, event.toJson());
  });

  final approvalResolvedSub = eventBus.on<WorkflowApprovalResolvedEvent>().where((e) => e.runId == runId).listen((
    event,
  ) {
    sendSseData(controller, event.toJson());
  });

  controller.onCancel = () {
    runStatusSub.cancel();
    stepCompletedSub.cancel();
    parallelSub.cancel();
    loopSub.cancel();
    mapIterationSub.cancel();
    mapStepSub.cancel();
    taskStatusSub.cancel();
    tokenProgressSub.cancel();
    approvalRequestedSub.cancel();
    approvalResolvedSub.cancel();
  };

  return Response.ok(controller.stream, headers: eventStreamHeaders);
}

String? _taskDisplayScope(Task? task) {
  final scope = task?.configJson['displayScope'];
  if (scope is! String) return null;
  final trimmed = scope.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Map<String, dynamic> _workflowEventPayload(WorkflowLifecycleEvent event, {String? displayScope}) {
  final payload = event.toJson();
  if (displayScope != null) {
    payload['displayScope'] = displayScope;
  }
  return payload;
}
