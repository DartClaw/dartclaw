import 'package:dartclaw_kernel/dartclaw_kernel.dart' show AuditEntry, GuardAuditLogger;
import 'package:logging/logging.dart';

final _log = Logger('ReservedCommandAudit');

/// The refusal an admin-only chat action answers a sender outside `governance.admin_senders`.
const adminOnlyRefusal = 'Only admin senders can use this command.';

/// Writes the one audit entry for a refused admin-only chat action: a reserved command ([hook]
/// `channel_command`) or the MCP tool that does the same thing ([hook] `tool`).
///
/// [tool] names the command or tool refused. A null [auditLogger] writes nothing; a failing write is logged and
/// never changes the refusal.
Future<void> auditReservedCommandRefusal(
  GuardAuditLogger? auditLogger, {
  required String channel,
  required String? senderId,
  required String tool,
  String hook = 'channel_command',
}) async {
  if (auditLogger == null) return;
  try {
    await auditLogger.writeEntry(
      AuditEntry(
        timestamp: DateTime.now(),
        guard: 'ReservedCommand',
        hook: hook,
        verdict: 'block',
        reason: adminOnlyRefusal,
        channel: channel,
        peerId: senderId,
        tool: tool,
        decision: 'deny',
        principal: senderId,
      ),
    );
  } catch (e) {
    _log.warning('Failed to audit reserved command refusal for $senderId', e);
  }
}
