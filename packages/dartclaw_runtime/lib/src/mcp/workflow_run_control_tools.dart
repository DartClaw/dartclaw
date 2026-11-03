import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show WorkflowRunStatus;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowService, workflowContextValue, workflowRevisionState;

import '../task/workflow_run_control.dart';
import 'mcp_server.dart' show McpCallerContext, TurnAwareMcpTool;
import 'tool_schema.dart';

const _maxPendingMessageLength = 1000;

/// MCP tool that resumes a paused or approval-held workflow run.
///
/// A thin adapter over [WorkflowRunControl], which owns the admin gate and the audit entry. The
/// acting sender is the host's record of the calling turn; no argument can name one.
class WorkflowResumeTool implements TurnAwareMcpTool {
  new({required WorkflowRunControl control}) : _control = control;

  final WorkflowRunControl _control;

  @override
  String get name => 'workflow_resume';

  @override
  String get description =>
      'Resume a paused or approval-held workflow run, approving the pending approval step. Only an admin sender '
      'in a chat turn may resume a run; check workflow_status first.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(_runIdProperty, const ['run_id']);

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) => _resume(args, null);

  @override
  Future<ToolResult> callWithTurn(Map<String, dynamic> args, McpCallerContext context) => _resume(args, context.turn);

  Future<ToolResult> _resume(Map<String, dynamic> args, TurnProvenance? turn) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;
    final runId = args['run_id'] as String;
    return _answer(runId, 'resumed', await _control.resumeFromTool(runId, turn));
  }
}

/// MCP tool that cancels a workflow run, rejecting a pending approval with optional feedback.
class WorkflowCancelTool implements TurnAwareMcpTool {
  new({required WorkflowRunControl control}) : _control = control;

  final WorkflowRunControl _control;

  @override
  String get name => 'workflow_cancel';

  @override
  String get description =>
      'Cancel a workflow run. At a pending approval this rejects it, and feedback is recorded as the rejection '
      'reason. Only an admin sender in a chat turn may cancel a run.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      ..._runIdProperty,
      'feedback': {'type': 'string', 'description': 'Why the approval is rejected, recorded with the step.'},
    },
    const ['run_id'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) => _cancel(args, null);

  @override
  Future<ToolResult> callWithTurn(Map<String, dynamic> args, McpCallerContext context) => _cancel(args, context.turn);

  Future<ToolResult> _cancel(Map<String, dynamic> args, TurnProvenance? turn) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;
    final runId = args['run_id'] as String;
    final feedback = args['feedback'] as String?;
    return _answer(runId, 'cancelled', await _control.cancelFromTool(runId, turn, feedback: feedback));
  }
}

/// MCP tool that sends a run waiting at an approval gate back to the gate's revise step.
class WorkflowRequestChangesTool implements TurnAwareMcpTool {
  new({required WorkflowRunControl control}) : _control = control;

  final WorkflowRunControl _control;

  @override
  String get name => 'workflow_request_changes';

  @override
  String get description =>
      'Send a workflow run waiting at an approval gate back to the gate\'s revise step with feedback. The step '
      're-runs with the feedback and the run returns to the gate. Only gates that name a revise step offer this, '
      'up to their limit; workflow_status shows revision and limit. Only an admin sender in a chat turn may use it.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      ..._runIdProperty,
      'feedback': {'type': 'string', 'description': 'What to change; the revise step receives it verbatim.'},
    },
    const ['run_id', 'feedback'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) => _requestChanges(args, null);

  @override
  Future<ToolResult> callWithTurn(Map<String, dynamic> args, McpCallerContext context) =>
      _requestChanges(args, context.turn);

  Future<ToolResult> _requestChanges(Map<String, dynamic> args, TurnProvenance? turn) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;
    final runId = args['run_id'] as String;
    final feedback = args['feedback'] as String;
    return _answer(runId, 'changes_requested', await _control.requestChangesFromTool(runId, turn, feedback: feedback));
  }
}

/// MCP tool that reports a workflow run's state.
///
/// Read-only and ungated. It never returns the approval interaction, so a nonce cannot reach a model.
class WorkflowStatusTool implements McpTool {
  new({required WorkflowService workflows}) : _workflows = workflows;

  final WorkflowService _workflows;

  @override
  String get name => 'workflow_status';

  @override
  String get description =>
      'Report a workflow run\'s status, current step, pending approval (step, message and request time) and last '
      'error.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(_runIdProperty, const ['run_id']);

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;
    final runId = args['run_id'] as String;
    final run = await _workflows.get(runId);
    if (run == null) return toolError('unknown_run', 'No workflow run $runId', {'run_id': runId});

    final pendingStep = _pendingStep(run);
    final revision = pendingStep == null ? null : workflowRevisionState(run);
    return toolJson({
      'run_id': run.id,
      'definition': run.definitionName,
      'status': run.status.name,
      'current_step': pendingStep ?? _stepAtIndex(run),
      'pending_approval': pendingStep == null
          ? null
          : {
              'step': pendingStep,
              'message': _truncate(workflowContextValue(run, '$pendingStep.approval.message')),
              'requested_at': workflowContextValue(run, '$pendingStep.approval.requested_at'),
              if (revision != null) ...{'revision': revision.count, 'max_revisions': revision.max},
            },
      // A held run's message only names the approval, which `pending_approval` already carries.
      'last_error': pendingStep == null ? run.errorMessage : null,
    });
  }

  String? _pendingStep(WorkflowRun run) {
    final held = run.status == WorkflowRunStatus.awaitingApproval || run.status == WorkflowRunStatus.paused;
    return held ? run.contextJson['_approval.pending.stepId'] as String? : null;
  }

  String? _stepAtIndex(WorkflowRun run) {
    try {
      final steps = WorkflowDefinition.fromJson(run.definitionJson).steps;
      final index = run.currentStepIndex;
      return index >= 0 && index < steps.length ? steps[index].id : null;
    } catch (_) {
      return null;
    }
  }

  String? _truncate(Object? message) {
    if (message is! String) return null;
    final runes = message.runes;
    return runes.length <= _maxPendingMessageLength
        ? message
        : String.fromCharCodes(runes.take(_maxPendingMessageLength));
  }
}

const _runIdProperty = {
  'run_id': {'type': 'string', 'description': 'The workflow run ID, as workflow_run and workflow_status report it.'},
};

ToolResult _answer(String runId, String outcome, RunControlResult result) => switch (result) {
  RunControlResolved(:final run) => toolJson({
    'run_id': runId,
    'outcome': outcome,
    'status': run?.status.name ?? WorkflowRunStatus.cancelled.name,
  }),
  RunControlRefused(:final reason, :final message) => toolError(
    switch (reason) {
      RunControlRefusal.notAdmin => 'not_admin',
      RunControlRefusal.needsChatTurn => 'needs_chat_turn',
      RunControlRefusal.invalid => 'invalid',
      RunControlRefusal.alreadyResolved => 'already_resolved',
      RunControlRefusal.notPending => 'not_pending',
      RunControlRefusal.changesNotOffered => 'changes_not_offered',
      RunControlRefusal.limitReached => 'limit_reached',
      RunControlRefusal.feedbackRequired => 'feedback_required',
    },
    message,
    {'run_id': runId},
  ),
  RunControlNotFound() => toolError('unknown_run', 'No workflow run $runId', {'run_id': runId}),
  RunControlFailed(:final message) => toolError('failed', message, {'run_id': runId}),
};
