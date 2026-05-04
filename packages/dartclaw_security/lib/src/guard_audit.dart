import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'guard_verdict.dart';

// ---------------------------------------------------------------------------
// AuditEntry
// ---------------------------------------------------------------------------

/// A single guard audit event persisted to a date-partitioned audit NDJSON file.
class AuditEntry {
  /// When the audited event occurred.
  final DateTime timestamp;

  /// Stable name of the guard that emitted the verdict.
  final String guard;

  /// Hook point at which the guard evaluated.
  final String hook;

  /// Verdict label such as `pass`, `warn`, or `block`.
  final String verdict;

  /// Optional explanatory reason attached to the verdict.
  final String? reason;

  /// Raw provider-native tool name associated with the verdict, if any.
  final String? rawProviderToolName;

  /// Session identifier associated with the event, if available.
  final String? sessionId;

  /// Channel name associated with the event, if available.
  final String? channel;

  /// Peer identifier associated with the event, if available.
  final String? peerId;

  /// Creates a structured audit entry.
  const AuditEntry({
    required this.timestamp,
    required this.guard,
    required this.hook,
    required this.verdict,
    this.reason,
    this.rawProviderToolName,
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
      rawProviderToolName: json['rawProviderToolName'] as String?,
      sessionId: json['sessionId'] as String?,
      channel: json['channel'] as String?,
      peerId: json['peerId'] as String?,
    );
  }

  /// Serializes this audit entry to a JSON-safe map.
  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'guard': guard,
    'hook': hook,
    'verdict': verdict,
    if (reason != null) 'reason': reason,
    if (rawProviderToolName != null) 'rawProviderToolName': rawProviderToolName,
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
/// When [dataDir] is provided, appends NDJSON entries to date-partitioned
/// `audit-YYYY-MM-DD.ndjson` files
/// alongside existing stdout logging. File writes are fire-and-forget
/// via [unawaited] to avoid affecting guard verdict latency.
class GuardAuditLogger {
  static final _log = Logger('GuardAudit');
  static final _auditFilePattern = RegExp(r'^audit-(\d{4}-\d{2}-\d{2})\.ndjson$');

  /// Base data directory where audit partitions are stored, or `null` for stdout only.
  final String? dataDir;

  /// Retained for constructor compatibility; date partitioning replaces rotation.
  final int maxEntries;

  /// Retained for constructor compatibility; no longer used.
  final int rotationCheckInterval;

  bool _dirChecked = false;
  bool _migrationChecked = false;
  Future<void> _pendingWrite = Future.value();

  /// Creates an audit logger with optional file-backed persistence.
  GuardAuditLogger({this.dataDir, this.maxEntries = 10000, this.rotationCheckInterval = 100});

  /// Path to today's audit NDJSON partition. Only meaningful when [dataDir] is set.
  String get auditFilePath => _auditFilePathForDate(DateTime.now());

  /// Logs a verdict produced by a guard evaluation.
  ///
  /// Log level: INFO for pass, WARNING for warn, SEVERE for block.
  /// When [dataDir] is set, also appends to a date-partitioned NDJSON file
  /// (fire-and-forget).
  void logVerdict({
    required GuardVerdict verdict,
    required String guardName,
    required String guardCategory,
    required String hookPoint,
    required DateTime timestamp,
    String? rawProviderToolName,
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
        rawProviderToolName: rawProviderToolName,
        sessionId: sessionId,
        channel: channel,
        peerId: peerId,
      );
      _pendingWrite = _pendingWrite.then((_) => _appendEntry(entry));
      unawaited(_pendingWrite);
    }
  }

  /// Logs a `PermissionDenied` event from Claude Code's own permission layer.
  ///
  /// Log level: WARNING. When [dataDir] is set, appends an NDJSON audit entry
  /// with `guard: 'PermissionDenied'` and `verdict: 'denied'`.
  void logPermissionDenied({required String toolName, String? reason, String? sessionId, required DateTime timestamp}) {
    final msg =
        '[PermissionDenied][permission][PreToolUse] '
        'tool=$toolName'
        '${reason != null ? ' reason=$reason' : ''} '
        'at=${timestamp.toIso8601String()}';
    _log.warning(msg);

    if (dataDir != null) {
      final entry = AuditEntry(
        timestamp: timestamp,
        guard: 'PermissionDenied',
        hook: 'PermissionDenied',
        verdict: 'denied',
        reason: reason,
        rawProviderToolName: toolName,
        sessionId: sessionId,
      );
      _pendingWrite = _pendingWrite.then((_) => _appendEntry(entry));
      unawaited(_pendingWrite);
    }
  }

  /// Logs a PostToolUse audit entry (stdout only — no file sink).
  void logPostToolUse({required String toolName, required bool success, required Map<String, dynamic> response}) {
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
      await _ensureDataDirExists();
      await _migrateLegacyAuditFileIfNeeded();

      final line = jsonEncode(entry.toJson());
      await File(_auditFilePathForDate(entry.timestamp)).writeAsString('$line\n', mode: FileMode.append);
    } catch (e) {
      _log.warning('Failed to append audit entry: $e');
    }
  }

  /// Deletes dated audit files older than [maxRetentionDays].
  ///
  /// Returns the number of deleted files. `0` disables cleanup.
  Future<int> cleanOldFiles(int maxRetentionDays) {
    final cleanup = _pendingWrite.then((_) => _cleanOldFilesInternal(maxRetentionDays));
    _pendingWrite = cleanup.then((_) {});
    return cleanup;
  }

  Future<int> _cleanOldFilesInternal(int maxRetentionDays) async {
    try {
      if (dataDir == null || maxRetentionDays <= 0) {
        return 0;
      }

      final dir = Directory(dataDir!);
      if (!dir.existsSync()) {
        return 0;
      }

      final cutoffDate = _dateOnly(DateTime.now()).subtract(Duration(days: maxRetentionDays - 1));
      var deletedCount = 0;

      await for (final entity in dir.list()) {
        if (entity is! File) {
          continue;
        }

        final date = _auditDateFromFileName(entity.uri.pathSegments.last);
        if (date == null || !date.isBefore(cutoffDate)) {
          continue;
        }

        await entity.delete();
        deletedCount++;
      }

      return deletedCount;
    } catch (e) {
      _log.warning('Failed to clean old audit files: $e');
      return 0;
    }
  }

  String _auditFilePathForDate(DateTime date) => '$dataDir/audit-${date.toIso8601String().substring(0, 10)}.ndjson';

  String get _legacyAuditFilePath => '$dataDir/audit.ndjson';

  Future<void> _ensureDataDirExists() async {
    if (_dirChecked) {
      return;
    }

    final dir = Directory(dataDir!);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _dirChecked = true;
  }

  Future<void> _migrateLegacyAuditFileIfNeeded() async {
    if (_migrationChecked) {
      return;
    }

    final legacyFile = File(_legacyAuditFilePath);
    if (!legacyFile.existsSync()) {
      _migrationChecked = true;
      return;
    }

    final legacyLines = await legacyFile.readAsLines();
    final partitions = <String, StringBuffer>{};

    for (final line in legacyLines) {
      if (line.trim().isEmpty) {
        continue;
      }

      try {
        final entry = AuditEntry.fromJson(Map<String, dynamic>.from(jsonDecode(line) as Map));
        final buffer = partitions.putIfAbsent(_auditFilePathForDate(entry.timestamp), StringBuffer.new);
        buffer.writeln(jsonEncode(entry.toJson()));
      } catch (e) {
        _log.warning('Skipping malformed legacy audit entry during migration: $e');
      }
    }

    for (final MapEntry(key: filePath, value: buffer) in partitions.entries) {
      await File(filePath).writeAsString(buffer.toString(), mode: FileMode.append);
    }

    await legacyFile.delete();
    _migrationChecked = true;
  }

  static DateTime _dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);

  static DateTime? _auditDateFromFileName(String fileName) {
    final match = _auditFilePattern.firstMatch(fileName);
    if (match == null) {
      return null;
    }

    try {
      return DateTime.parse(match.group(1)!);
    } on FormatException {
      return null;
    }
  }

  static String _verdictLabel(GuardVerdict v) => switch (v) {
    GuardBlock() => 'block',
    GuardWarn() => 'warn',
    GuardPass() => 'pass',
  };
}
