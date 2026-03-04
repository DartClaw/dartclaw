import 'package:logging/logging.dart';

import 'guard_verdict.dart';

// Forward declarations to avoid circular imports — guard.dart imports this file.
// GuardAuditLogger references Guard and GuardContext by using dynamic or
// by importing guard.dart. We keep the full import here.

/// Structured audit logger for guard verdicts and tool usage.
class GuardAuditLogger {
  static final _log = Logger('GuardAudit');

  /// Logs a verdict produced by a guard evaluation.
  ///
  /// Log level: INFO for pass, WARNING for warn, SEVERE for block.
  void logVerdict({
    required GuardVerdict verdict,
    required String guardName,
    required String guardCategory,
    required String hookPoint,
    required DateTime timestamp,
  }) {
    final msg =
        '[$guardName][$guardCategory][$hookPoint] '
        'verdict=${_verdictLabel(verdict)}'
        '${verdict.message != null ? ' msg=${verdict.message}' : ''} '
        'at=${timestamp.toIso8601String()}';

    if (verdict.isBlock) {
      _log.severe(msg);
    } else if (verdict.isWarn) {
      _log.warning(msg);
    } else {
      _log.info(msg);
    }
  }

  /// Logs a PostToolUse audit entry.
  void logPostToolUse({
    required String toolName,
    required bool success,
    required Map<String, dynamic> response,
  }) {
    final msg =
        '[PostToolUse] tool=$toolName success=$success'
        '${response.containsKey('error') ? ' error=${response['error']}' : ''}';
    if (success) {
      _log.info(msg);
    } else {
      _log.warning(msg);
    }
  }

  static String _verdictLabel(GuardVerdict v) => switch (v) {
    GuardVerdict(isBlock: true) => 'block',
    GuardVerdict(isWarn: true) => 'warn',
    _ => 'pass',
  };
}
