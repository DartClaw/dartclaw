import 'package:dartclaw_kernel/dartclaw_kernel.dart' show AuditEntry, GuardAuditLogger;
import 'package:logging/logging.dart';

final _log = Logger('RefusalAudit');

/// Guard name on the entries a refused reserved command, or the MCP tool that does the same thing, writes.
const reservedCommandGuard = 'ReservedCommand';

/// The refusal an admin-only chat action answers a sender outside `governance.admin_senders`.
const adminOnlyRefusal = 'Only admin senders can use this command.';

/// Writes the one audit entry for a chat action refused to its caller: the single writer behind a refused reserved
/// command, a refused `task_*` or run-control tool call, and a delegated turn turned away from either.
///
/// [guard] is the concern's own guard name, [hook] the surface asking (`channel_command` or `tool`), [tool] the
/// command or tool refused. A null [auditLogger] writes nothing; a failing write is logged and never changes the
/// refusal.
Future<void> auditRefusal(
  GuardAuditLogger? auditLogger, {
  required String guard,
  required String hook,
  required String tool,
  required String reason,
  String? channel,
  String? senderId,
  String? runId,
  String? stepId,
}) async {
  if (auditLogger == null) return;
  try {
    await auditLogger.writeEntry(
      AuditEntry(
        timestamp: DateTime.now(),
        guard: guard,
        hook: hook,
        verdict: 'block',
        reason: reason,
        channel: channel,
        peerId: senderId,
        tool: tool,
        decision: 'deny',
        principal: senderId,
        runId: runId,
        stepId: stepId,
      ),
    );
  } catch (e) {
    _log.warning('Failed to audit $guard refusal for $senderId', e);
  }
}
