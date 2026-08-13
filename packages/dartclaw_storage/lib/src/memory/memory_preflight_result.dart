part of 'legacy_memory_migrator.dart';

String _migrationSummary(String text) => text.trim().split('\n').first.trim();

/// Outcome of canonical memory startup preflight.
enum MemoryPreflightStatus {
  /// Legacy sources were converted and committed.
  migrated,

  /// The canonical corpus was already current.
  alreadyCurrent,

  /// Supported stopped-runtime edits were reconciled.
  reconciled,
}

final class _MemoryPreflightDiagnostic {
  const new({required this.role, required this.locator, required this.stage, required this.reason});

  final String role;
  final String locator;
  final String stage;
  final String reason;
}

/// Result emitted before derived memory indexes may start.
final class MemoryPreflightResult {
  new _({
    required this.status,
    required this.collectionRevision,
    required this.fingerprint,
    required this.totalDiagnostics,
    required Iterable<_MemoryPreflightDiagnostic> diagnostics,
    required Map<MemoryRole, int> roleCounts,
    required this.defaultTopicCount,
    this.snapshotPath,
  }) : _diagnostics = List.unmodifiable(diagnostics),
       roleCounts = Map.unmodifiable(roleCounts);

  /// The preflight action that completed.
  final MemoryPreflightStatus status;

  /// Current canonical collection revision.
  final int collectionRevision;

  /// Fingerprint of the committed canonical corpus.
  final String fingerprint;

  /// Total diagnostics before count and byte truncation.
  final int totalDiagnostics;

  final List<_MemoryPreflightDiagnostic> _diagnostics;

  /// Number of migrated records by canonical role.
  final Map<MemoryRole, int> roleCounts;

  /// Number of legacy entries assigned to the parser-defaulted general topic.
  final int defaultTopicCount;

  /// Exact retained pre-migration snapshot path, when migration ran.
  final String? snapshotPath;

  /// Number of diagnostics omitted by the count cap.
  int get omittedDiagnostics => totalDiagnostics - _diagnostics.length;

  /// Renders a UTF-8 report capped at 64 KiB and 100 diagnostics.
  String render() {
    final header = <String>[
      'Memory preflight: ${status.name}',
      'Collection revision: $collectionRevision',
      'Fingerprint: $fingerprint',
      if (snapshotPath != null) 'Recoverable snapshot: $snapshotPath',
      if (roleCounts.isNotEmpty)
        'Migrated roles: ${roleCounts.entries.map((entry) => '${entry.key.wireName}=${entry.value}').join(', ')}',
      if (defaultTopicCount > 0) 'Legacy entries assigned to topic general: $defaultTopicCount',
    ];
    var returned = _diagnostics.length;
    while (true) {
      final omitted = totalDiagnostics - returned;
      final lines = [
        ...header,
        'Diagnostics: total=$totalDiagnostics returned=$returned omitted=$omitted',
        for (final diagnostic in _diagnostics.take(returned))
          '[${diagnostic.stage}] ${diagnostic.role} ${diagnostic.locator}: ${diagnostic.reason}',
      ];
      final value = '${lines.join('\n')}\n';
      if (utf8.encode(value).length <= LegacyMemoryMigrator.maxReportBytes) return value;
      if (returned == 0) {
        return _utf8Prefix(value, LegacyMemoryMigrator.maxReportBytes);
      }
      returned--;
    }
  }
}

/// A failed preflight with a bounded recovery report.
final class MemoryPreflightException implements Exception {
  const new _(this.report);

  /// Creates a failure carrying a bounded operator report.
  factory bounded({required String stage, required Object error}) =>
      MemoryPreflightException._(LegacyMemoryMigrator._failureReport(stage, error));

  /// Bounded recovery report suitable for startup logging.
  final String report;

  @override
  String toString() => report;
}

String _utf8Prefix(String value, int maxBytes) {
  final bytes = utf8.encode(value);
  if (bytes.length <= maxBytes) return value;
  var end = maxBytes;
  while (end > 0 && end < bytes.length && bytes[end] & 0xc0 == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end));
}

final class _PreparedMigration {
  const new({required this.corpus, required this.result, required this.sourceFingerprint});

  final CanonicalMemoryCorpus corpus;
  final MemoryPreflightResult result;
  final String sourceFingerprint;
}

final class _DailyBlock {
  const new({required this.start, required this.end, required this.timestamp, required this.content});

  final int start;
  final int end;
  final DateTime timestamp;
  final String content;
}

final class _SourceLine {
  const new({required this.start, required this.contentEnd, required this.text});

  final int start;
  final int contentEnd;
  final String text;
}
