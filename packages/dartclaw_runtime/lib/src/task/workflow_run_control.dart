import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:logging/logging.dart';

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
}

/// What a run-control call came to.
sealed class RunControlResult {
  const new();
}

/// The run was resumed or cancelled. [run] is the resumed run, `null` for a cancel.
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

/// The one admin gate, resolver and audit writer for resuming or cancelling a run from a
/// chat button, an agent tool or the web.
///
/// Chat and tool callers must be admin senders under `governance.admin_senders`; the web
/// caller is already authenticated, so it is audited but never gated. Every call writes
/// exactly one entry, and none ever carries a nonce. The sender comes only from the host's
/// record of the turn or the click, never from a model argument.
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

  /// Handles a click on an approval post: Approve resumes the run, Reject cancels it.
  Future<ChannelRunApprovalResult> handleApproval(ChannelRunApprovalRequest request) async {
    final approve = request.action == ChannelRunApprovalAction.approve;
    final result = await _resolve(
      hook: 'button',
      source: WorkflowApprovalSource.button,
      resume: approve,
      runId: request.runId,
      stepId: request.stepId,
      channel: request.channelType,
      senderId: request.senderId,
      displayName: request.senderDisplayName,
      expect: WorkflowApprovalExpectation(
        stepId: request.stepId,
        nonce: request.nonce,
        channelType: request.channelType,
        messageId: request.postMessageId,
      ),
    );
    return switch (result) {
      RunControlResolved() => const ChannelRunApprovalResolved(),
      RunControlRefused(:final reason, :final message) => ChannelRunApprovalRefused(switch (reason) {
        RunControlRefusal.notAdmin || RunControlRefusal.needsChatTurn => ChannelRunApprovalRefusal.notAdmin,
        RunControlRefusal.invalid => ChannelRunApprovalRefusal.invalid,
        RunControlRefusal.alreadyResolved => ChannelRunApprovalRefusal.alreadyResolved,
        RunControlRefusal.notPending => ChannelRunApprovalRefusal.notPending,
      }, message),
      // A click names its run, so an unknown one is a stale or forged button.
      RunControlNotFound() => const ChannelRunApprovalRefused(
        ChannelRunApprovalRefusal.invalid,
        'This approval button is no longer valid',
      ),
      RunControlFailed(:final message) => ChannelRunApprovalFailed(message),
    };
  }

  /// Resumes [runId] for the chat turn [turn], which must carry an admin sender.
  Future<RunControlResult> resumeFromTool(String runId, TurnProvenance? turn) => _fromTool(true, runId, turn);

  /// Cancels [runId] for the chat turn [turn], which must carry an admin sender.
  Future<RunControlResult> cancelFromTool(String runId, TurnProvenance? turn, {String? feedback}) =>
      _fromTool(false, runId, turn, feedback: feedback);

  /// Resumes [runId] for the authenticated web caller. Never admin-gated.
  Future<RunControlResult> resumeFromWeb(String runId) => _resolve(
    hook: 'web',
    source: WorkflowApprovalSource.web,
    resume: true,
    runId: runId,
    adminGated: false,
    principal: _webPrincipal,
  );

  /// Cancels [runId] for the authenticated web caller, with optional rejection [feedback].
  /// Never admin-gated.
  Future<RunControlResult> cancelFromWeb(String runId, {String? feedback}) => _resolve(
    hook: 'web',
    source: WorkflowApprovalSource.web,
    resume: false,
    runId: runId,
    feedback: feedback,
    adminGated: false,
    principal: _webPrincipal,
  );

  Future<RunControlResult> _fromTool(bool resume, String runId, TurnProvenance? turn, {String? feedback}) async {
    final channel = turn?.channelType;
    if (turn == null || channel == null) {
      const message = 'Run control needs a chat turn';
      await _audit(
        hook: 'tool',
        resume: resume,
        runId: runId,
        stepId: await _pendingStep(runId),
        allowed: false,
        reason: message,
      );
      return const RunControlRefused(RunControlRefusal.needsChatTurn, message);
    }
    return _resolve(
      hook: 'tool',
      source: WorkflowApprovalSource.tool,
      resume: resume,
      runId: runId,
      channel: channel,
      senderId: turn.senderId,
      feedback: feedback,
    );
  }

  Future<RunControlResult> _resolve({
    required String hook,
    required WorkflowApprovalSource source,
    required bool resume,
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
      resume: resume,
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
      WorkflowRun? resumed;
      if (resume) {
        resumed = await _workflows.resume(runId, expect: expect, resolver: resolver);
      } else {
        await _workflows.cancel(runId, feedback: feedback, expect: expect, resolver: resolver);
      }
      await audit(allowed: true);
      return RunControlResolved(resumed);
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
      };
    } on ArgumentError {
      await audit(allowed: false, reason: 'run not found');
      return const RunControlNotFound();
    } on StateError catch (error) {
      // The resume route has always answered a refused transition with its own text; cancel answered 500.
      if (source == WorkflowApprovalSource.web && resume) {
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

  Future<void> _audit({
    required String hook,
    required bool resume,
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
          tool: resume ? 'resume' : 'cancel',
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
