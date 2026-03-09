import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'guard_verdict.dart';

// ---------------------------------------------------------------------------
// AuditEntry
// ---------------------------------------------------------------------------

/// A single guard audit event persisted to `audit.ndjson`.
class AuditEntry {
  final DateTime timestamp;
  final String guard;
  final String hook;
  final String verdict;
  final String? reason;
  final String? sessionId;
  final String? channel;
  final String? peerId;

  const AuditEntry({
    required this.timestamp,
    required this.guard,
    required this.hook,
    required this.verdict,
    this.reason,
    this.sessionId,
    this.channel,
    this.peerId,
  });

  /// Deserializes an [AuditEntry] from a JSON map (NDJSON line).
  factory AuditEntry.fromJson(Map<String, dynamic> json) {
    return AuditEntry(
      timestamp: DateTime.parse(json['timestamp'] as String),
      guard: json['guard'] as String,
      hook: json['hook'] as String,
      verdict: json['verdict'] as String,
      reason: json['reason'] as String?,
      sessionId: json['sessionId'] as String?,
      channel: json['channel'] as String?,
      peerId: json['peerId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'guard': guard,
    'hook': hook,
    'verdict': verdict,
    if (reason != null) 'reason': reason,
    if (sessionId != null) 'sessionId': sessionId,
    if (channel != null) 'channel': channel,
    if (peerId != null) 'peerId': peerId,
  };
}

// ---------------------------------------------------------------------------
// GuardAuditLogger
// ---------------------------------------------------------------------------

/// Structured audit logger for guard verdicts and tool usage.
///
/// When [dataDir] is provided, appends NDJSON entries to `audit.ndjson`
/// alongside existing stdout logging. File writes are fire-and-forget
/// via [unawaited] to avoid affecting guard verdict latency.
class GuardAuditLogger {
  static final _log = Logger('GuardAudit');

  final String? dataDir;
  final int maxEntries;
  final int rotationCheckInterval;

  int _writeCount = 0;
  bool _dirChecked = false;
  Future<void> _pendingWrite = Future.value();

  GuardAuditLogger({
    this.dataDir,
    this.maxEntries = 10000,
    this.rotationCheckInterval = 100,
  });

  /// Path to the audit NDJSON file. Only meaningful when [dataDir] is set.
  String get auditFilePath => '$dataDir/audit.ndjson';

  /// Logs a verdict produced by a guard evaluation.
  ///
  /// Log level: INFO for pass, WARNING for warn, SEVERE for block.
  /// When [dataDir] is set, also appends to `audit.ndjson` (fire-and-forget).
  void logVerdict({
    required GuardVerdict verdict,
    required String guardName,
    required String guardCategory,
    required String hookPoint,
    required DateTime timestamp,
    String? sessionId,
    String? channel,
    String? peerId,
  }) {
    // Existing stdout logging — always runs.
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

    // File sink — fire-and-forget when dataDir is configured.
    if (dataDir != null) {
      final entry = AuditEntry(
        timestamp: timestamp,
        guard: guardName,
        hook: hookPoint,
        verdict: _verdictLabel(verdict),
        reason: verdict.message,
        sessionId: sessionId,
        channel: channel,
        peerId: peerId,
      );
      _pendingWrite = _pendingWrite.then((_) => _appendEntry(entry));
      unawaited(_pendingWrite);
    }
  }

  /// Logs a PostToolUse audit entry (stdout only — no file sink).
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

  // ---------------------------------------------------------------------------
  // File sink internals
  // ---------------------------------------------------------------------------

  Future<void> _appendEntry(AuditEntry entry) async {
    try {
      if (!_dirChecked) {
        final dir = Directory(dataDir!);
        if (!dir.existsSync()) await dir.create(recursive: true);
        _dirChecked = true;
      }

      final line = jsonEncode(entry.toJson());
      await File(auditFilePath).writeAsString('$line\n', mode: FileMode.append);

      _writeCount++;
      if (_writeCount % rotationCheckInterval == 0) {
        await _rotateIfNeeded();
      }
    } catch (e) {
      _log.warning('Failed to append audit entry: $e');
    }
  }

  Future<void> _rotateIfNeeded() async {
    try {
      final file = File(auditFilePath);
      if (!file.existsSync()) return;

      final lines = await file.readAsLines();
      if (lines.length <= maxEntries) return;

      // Keep the newest entries.
      final kept = lines.sublist(lines.length - maxEntries);
      final tmpPath = '$auditFilePath.tmp';
      final tmpFile = File(tmpPath);
      await tmpFile.writeAsString('${kept.join('\n')}\n');
      await tmpFile.rename(auditFilePath);

      _log.info(
        'Rotated audit.ndjson: ${lines.length} -> $maxEntries entries',
      );
    } catch (e) {
      _log.warning('Failed to rotate audit file: $e');
    }
  }

  static String _verdictLabel(GuardVerdict v) => switch (v) {
    GuardBlock() => 'block',
    GuardWarn() => 'warn',
    GuardPass() => 'pass',
  };
}
