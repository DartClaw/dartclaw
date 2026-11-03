import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:logging/logging.dart';

import '../governance/refusal_audit.dart';

/// Why [WorkflowRunControl] refused a call.
enum RunControlRefusal {
  /// The sender is not in `governance.admin_senders`.
  notAdmin,

  /// The call came from a turn that is not a chat turn.
  needsChatTurn,

  /// A click that matches no live approval post.
  invalid,

  /// The approval was already resolved.
  alreadyResolved,

  /// The run is not waiting at that approval.
  notPending,

  /// The gate names no revise step.
  changesNotOffered,

  /// The gate already went through its bound of request-changes rounds.
  limitReached,

  /// A request to change carried no feedback.
  feedbackRequired,
}

/// The action's `name` is what an audit entry records as the tool.
enum _RunAction { resume, cancel, requestChanges, checkRequestChanges }

/// What a run-control call came to.
sealed class RunControlResult {
  const new();
}

/// The run was resumed, sent back for changes or cancelled. [run] is the run that continues, `null` for a cancel.
final class RunControlResolved extends RunControlResult {
  final WorkflowRun? run;

  const new([this.run]);
}

/// The call was refused and changed nothing.
final class RunControlRefused extends RunControlResult {
  final RunControlRefusal reason;

  /// Text to answer the caller with.
  final String message;

  const new(this.reason, this.message);
}

/// No run has that ID.
final class RunControlNotFound extends RunControlResult {
  const new();
}

/// The resolution failed and left the approval pending.
final class RunControlFailed extends RunControlResult {
  final String message;

  const new(this.message);
}

/// The one admin gate, resolver and audit writer for resuming, cancelling or requesting changes at a run
/// from a chat button, an agent tool or the web.
///
/// Chat and tool callers must be admin senders under `governance.admin_senders`; the web
/// caller is already authenticated, so it is audited but never gated. A tool call needs a live
/// chat turn: a task or workflow-step turn ([TurnProvenance.delegated]) is refused whoever
/// requested it. Every call writes exactly one entry, and none ever carries a nonce. The sender
/// comes only from the host's record of the turn or the click, never from a model argument.
final class WorkflowRunControl {
  static final _log = Logger('WorkflowRunControl');
  static const _guardName = 'RunApprovalGate';
  static const _webPrincipal = 'owner';
  static const _notAdminMessage = 'Only admin senders can resolve approvals';
  static const _failedMessage = 'The approval could not be resolved. Try again.';

  final WorkflowService _workflows;
  final bool Function(String senderId) _isAdmin;
  final GuardAuditLogger _auditLogger;

  new({
    required WorkflowService workflows,
    required bool Function(String senderId) isAdmin,
    required GuardAuditLogger auditLogger,
  }) : _workflows = workflows,
       _isAdmin = isAdmin,
       _auditLogger = auditLogger;

  /// Handles a click on an approval post or a request-changes form's submission: Approve resumes the run,
  /// Reject cancels it, a submission sends it back to the gate's revise step, and a click on Request changes
  /// only checks that the sender may and the gate is live.
  Future<ChannelRunApprovalResult> handleApproval(ChannelRunApprovalRequest request) async {
    final action = switch (request.action) {
      ChannelRunApprovalAction.approve => _RunAction.resume,
      ChannelRunApprovalAction.reject => _RunAction.cancel,
      ChannelRunApprovalAction.requestChanges => _RunAction.requestChanges,
      ChannelRunApprovalAction.checkRequestChanges => _RunAction.checkRequestChanges,
    };
    final result = await _resolve(
      hook: 'button',
      source: WorkflowApprovalSource.button,
      action: action,
      runId: request.runId,
      stepId: request.stepId,
      channel: request.channelType,
      senderId: request.senderId,
      displayName: request.senderDisplayName,
      feedback: request.feedback,
      expect: WorkflowApprovalExpectation(
        stepId: request.stepId,
        nonce: request.nonce,
        channelType: request.channelType,
        messageId: request.postMessageId,
      ),
    );
    return switch (result) {
      RunControlResolved() when action == _RunAction.checkRequestChanges => const ChannelRunApprovalPermitted(),
      RunControlResolved() => const ChannelRunApprovalResolved(),
      RunControlRefused(:final reason, :final message) => ChannelRunApprovalRefused(switch (reason) {
        RunControlRefusal.notAdmin || RunControlRefusal.needsChatTurn => ChannelRunApprovalRefusal.notAdmin,
        RunControlRefusal.invalid => ChannelRunApprovalRefusal.invalid,
        RunControlRefusal.alreadyResolved => ChannelRunApprovalRefusal.alreadyResolved,
        RunControlRefusal.notPending => ChannelRunApprovalRefusal.notPending,
        RunControlRefusal.changesNotOffered => ChannelRunApprovalRefusal.changesNotOffered,
        RunControlRefusal.limitReached => ChannelRunApprovalRefusal.limitReached,
        RunControlRefusal.feedbackRequired => ChannelRunApprovalRefusal.feedbackRequired,
      }, message),
      // A click names its run, so an unknown one is a stale or forged button.
      RunControlNotFound() => const ChannelRunApprovalRefused(
        ChannelRunApprovalRefusal.invalid,
        'This approval button is no longer valid',
      ),
      RunControlFailed(:final message) => ChannelRunApprovalFailed(message),
    };
  }

  /// Resumes [runId] for the live chat turn [turn], which must carry an admin sender.
  Future<RunControlResult> resumeFromTool(String runId, TurnProvenance? turn) =>
      _fromTool(_RunAction.resume, runId, turn);

  /// Cancels [runId] for the live chat turn [turn], which must carry an admin sender.
  Future<RunControlResult> cancelFromTool(String runId, TurnProvenance? turn, {String? feedback}) =>
      _fromTool(_RunAction.cancel, runId, turn, feedback: feedback);

  /// Sends [runId] back to its gate's revise step with [feedback] for the live chat turn [turn], which must
  /// carry an admin sender.
  Future<RunControlResult> requestChangesFromTool(String runId, TurnProvenance? turn, {required String feedback}) =>
      _fromTool(_RunAction.requestChanges, runId, turn, feedback: feedback);

  /// Resumes [runId] for the authenticated web caller. Never admin-gated.
  Future<RunControlResult> resumeFromWeb(String runId) => _resolve(
    hook: 'web',
    source: WorkflowApprovalSource.web,
    action: _RunAction.resume,
    runId: runId,
    adminGated: false,
    principal: _webPrincipal,
  );

  /// Cancels [runId] for the authenticated web caller, with optional rejection [feedback].
  /// Never admin-gated.
  Future<RunControlResult> cancelFromWeb(String runId, {String? feedback}) => _resolve(
    hook: 'web',
    source: WorkflowApprovalSource.web,
    action: _RunAction.cancel,
    runId: runId,
    feedback: feedback,
    adminGated: false,
    principal: _webPrincipal,
  );

  /// Sends [runId] back to its gate's revise step with [feedback] for the authenticated web caller.
  /// Never admin-gated.
  Future<RunControlResult> requestChangesFromWeb(String runId, {required String feedback}) => _resolve(
    hook: 'web',
    source: WorkflowApprovalSource.web,
    action: _RunAction.requestChanges,
    runId: runId,
    feedback: feedback,
    adminGated: false,
    principal: _webPrincipal,
  );

  Future<RunControlResult> _fromTool(_RunAction action, String runId, TurnProvenance? turn, {String? feedback}) async {
    final channel = turn?.channelType;
    // An approval gate needs a human: delegated work may write as its requester but never resolve a gate.
    if (turn == null || channel == null || turn.delegated) {
      const message = 'Run control needs a chat turn';
      await auditRefusal(
        _auditLogger,
        guard: _guardName,
        hook: 'tool',
        tool: action.name,
        reason: message,
        channel: channel,
        senderId: turn?.senderId,
        runId: runId,
        stepId: await _pendingStep(runId),
      );
      return const RunControlRefused(RunControlRefusal.needsChatTurn, message);
    }
    return _resolve(
      hook: 'tool',
      source: WorkflowApprovalSource.tool,
      action: action,
      runId: runId,
      channel: channel,
      senderId: turn.senderId,
      feedback: feedback,
    );
  }

  Future<RunControlResult> _resolve({
    required String hook,
    required WorkflowApprovalSource source,
    required _RunAction action,
    required String runId,
    String? stepId,
    String? channel,
    String? senderId,
    String? displayName,
    String? principal,
    String? feedback,
    bool adminGated = true,
    WorkflowApprovalExpectation? expect,
  }) async {
    WorkflowRun? existing;
    Object? readFailure;
    try {
      existing = await _workflows.get(runId);
    } catch (error) {
      readFailure = error;
    }
    final step = stepId ?? existing?.contextJson['_approval.pending.stepId'] as String?;
    Future<void> audit({required bool allowed, String? reason, bool failed = false}) => _audit(
      hook: hook,
      action: action,
      runId: runId,
      stepId: step,
      channel: channel,
      senderId: senderId,
      principal: principal,
      allowed: allowed,
      failed: failed,
      reason: reason,
    );

    // An unidentified channel sender is an admin only where every sender is (the knowledge-write gate's rule).
    if (adminGated && !_isAdmin(senderId ?? '')) {
      await audit(
        allowed: false,
        reason: senderId == null ? 'channel turn carries no sender' : 'sender is not in governance.admin_senders',
      );
      return const RunControlRefused(RunControlRefusal.notAdmin, _notAdminMessage);
    }
    if (readFailure != null) {
      _log.warning('Failed to read workflow run $runId', readFailure);
      await audit(allowed: false, failed: true, reason: 'resolution failed: ${readFailure.runtimeType}');
      return const RunControlFailed(_failedMessage);
    }
    if (existing == null) {
      await audit(allowed: false, reason: 'run not found');
      return const RunControlNotFound();
    }

    final resolver = WorkflowApprovalResolver(source: source, senderId: senderId, displayName: displayName);
    try {
      WorkflowRun? continued;
      switch (action) {
        case _RunAction.resume:
          continued = await _workflows.resume(runId, expect: expect, resolver: resolver);
        case _RunAction.cancel:
          await _workflows.cancel(runId, feedback: feedback, expect: expect, resolver: resolver);
        case _RunAction.requestChanges:
          continued = await _workflows.requestChanges(
            runId,
            feedback: feedback ?? '',
            expect: expect,
            resolver: resolver,
          );
        case _RunAction.checkRequestChanges:
          await _workflows.checkRequestChanges(runId, expect: expect);
          // A check that passes resolved nothing, so it leaves no entry.
          return const RunControlResolved();
      }
      await audit(
        allowed: true,
        reason: action == _RunAction.requestChanges ? _revisionReason(existing, step, continued) : null,
      );
      return RunControlResolved(continued);
    } on WorkflowApprovalRefused catch (refusal) {
      await audit(allowed: false, reason: refusal.reason.name);
      final web = source == WorkflowApprovalSource.web;
      return switch (refusal.reason) {
        WorkflowApprovalRefusal.invalidNonce => const RunControlRefused(
          RunControlRefusal.invalid,
          'This approval button is no longer valid',
        ),
        WorkflowApprovalRefusal.alreadyResolved => RunControlRefused(
          RunControlRefusal.alreadyResolved,
          web ? refusal.message : 'This approval was already resolved',
        ),
        WorkflowApprovalRefusal.notPending => RunControlRefused(
          RunControlRefusal.notPending,
          web ? refusal.message : 'The run is not waiting at this approval',
        ),
        WorkflowApprovalRefusal.changesNotOffered => RunControlRefused(
          RunControlRefusal.changesNotOffered,
          web ? refusal.message : 'This approval does not offer request changes',
        ),
        WorkflowApprovalRefusal.limitReached => RunControlRefused(
          RunControlRefusal.limitReached,
          web ? refusal.message : 'This approval reached its revision limit',
        ),
        WorkflowApprovalRefusal.feedbackRequired => RunControlRefused(
          RunControlRefusal.feedbackRequired,
          'Feedback is required to request changes',
        ),
      };
    } on ArgumentError {
      await audit(allowed: false, reason: 'run not found');
      return const RunControlNotFound();
    } on StateError catch (error) {
      // The resume route has always answered a refused transition with its own text; cancel answered 500.
      if (source == WorkflowApprovalSource.web && action == _RunAction.resume) {
        await audit(allowed: false, reason: error.message);
        return RunControlRefused(RunControlRefusal.notPending, error.message);
      }
      await audit(allowed: false, failed: true, reason: 'resolution failed: ${error.message}');
      return const RunControlFailed(_failedMessage);
    } catch (error, stackTrace) {
      _log.warning('Failed to resolve workflow run $runId', error, stackTrace);
      await audit(allowed: false, failed: true, reason: 'resolution failed: ${error.runtimeType}');
      return const RunControlFailed(_failedMessage);
    }
  }

  Future<String?> _pendingStep(String runId) async {
    try {
      final run = await _workflows.get(runId);
      return run?.contextJson['_approval.pending.stepId'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// `revision n/max` for the round the owner recorded on [continued]; [before] (read outside the run's
  /// lock) supplies only the gate's bound, which a run's definition snapshot never changes.
  String? _revisionReason(WorkflowRun? before, String? stepId, WorkflowRun? continued) {
    final max = before == null ? null : workflowRevisionState(before)?.max;
    final round = continued == null || stepId == null
        ? null
        : workflowContextValue(continued, '$stepId.approval.revision');
    return max == null || round is! num ? null : 'revision ${round.toInt()}/$max';
  }

  Future<void> _audit({
    required String hook,
    required _RunAction action,
    required String runId,
    String? stepId,
    String? channel,
    String? senderId,
    String? principal,
    required bool allowed,
    bool failed = false,
    String? reason,
  }) async {
    try {
      await _auditLogger.writeEntry(
        AuditEntry(
          timestamp: DateTime.now(),
          guard: _guardName,
          hook: hook,
          verdict: allowed ? 'pass' : 'block',
          reason: reason,
          channel: channel,
          peerId: senderId,
          tool: action.name,
          decision: allowed
              ? 'allow'
              : failed
              ? 'error'
              : 'deny',
          principal: senderId ?? principal,
          runId: runId,
          stepId: stepId,
        ),
      );
    } catch (error, stackTrace) {
      _log.severe('Failed to audit run control for $runId', error, stackTrace);
    }
  }
}
