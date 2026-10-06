import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'mcp_server.dart';

/// The contextual write guard behind `wiki_write`, `kg_add` and `kg_invalidate`.
///
/// A turn that arrived on a chat channel changes shared knowledge only for an admin sender, and each such
/// call is audited with its channel and sender. A turn on a non-channel surface (web, scheduled) and a call
/// with no turn at all are not gated here: the sender comes only from [McpCallerContext.turn], never from
/// tool arguments.
final class KnowledgeWriteGate {
  /// [isAdmin] is the governance admin rule, [refuseFirst] a refusal checked before the channel gate.
  new({
    required bool Function(String senderId) isAdmin,
    required GuardAuditLogger auditLogger,
    required Future<ToolResult?> Function(McpCallerContext caller) refuseFirst,
  }) : _isAdmin = isAdmin,
       _auditLogger = auditLogger,
       _refuseFirst = refuseFirst;

  static const _guardName = 'KnowledgeWriteGate';

  final bool Function(String senderId) _isAdmin;
  final GuardAuditLogger _auditLogger;
  final Future<ToolResult?> Function(McpCallerContext caller) _refuseFirst;

  /// The guard for [tool], to hand a write tool as its `contextualWriteGuard`.
  Future<ToolResult?> Function(McpCallerContext caller) guardFor(String tool) => (caller) async {
    final refusal = await _refuseFirst(caller);
    if (refusal != null) return refusal;

    final turn = caller.turn;
    final channel = turn?.channelType;
    if (turn == null || channel == null) return null;

    final sender = turn.senderId;
    // An unidentified sender is an admin only where every sender is.
    final admin = _isAdmin(sender ?? '');
    try {
      await _auditLogger.writeEntry(
        AuditEntry(
          timestamp: DateTime.now(),
          guard: _guardName,
          hook: 'mcp_tool_call',
          verdict: admin ? 'pass' : 'block',
          reason: sender == null
              ? 'channel turn carries no sender'
              : admin
              ? 'admin sender'
              : 'sender is not in governance.admin_senders',
          rawProviderToolName: tool,
          channel: channel,
          peerId: sender,
          tool: tool,
          decision: admin ? 'allow' : 'deny',
          principal: sender,
        ),
      );
    } catch (error) {
      return ToolResult.error('Shared knowledge write refused: audit failure: $error');
    }
    if (admin) return null;
    return const ToolResult.error(
      'Writing shared knowledge from a channel requires an admin sender (governance.admin_senders)',
    );
  };
}
