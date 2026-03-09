import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Paginated result from reading the audit log.
class AuditPage {
  final List<AuditEntry> entries;
  final int totalEntries;
  final int currentPage;
  final int totalPages;
  final int pageSize;

  const AuditPage({
    required this.entries,
    required this.totalEntries,
    required this.currentPage,
    required this.totalPages,
    required this.pageSize,
  });

  static const empty = AuditPage(
    entries: [],
    totalEntries: 0,
    currentPage: 1,
    totalPages: 0,
    pageSize: 25,
  );
}

/// Reads and parses `audit.ndjson` with filtering and pagination.
///
/// Each call reads the full file (no caching) — acceptable at 10K entries
/// per PRD note. Returns newest entries first.
class AuditLogReader {
  static final _log = Logger('AuditLogReader');

  final String dataDir;

  AuditLogReader({required this.dataDir});

  String get _auditPath => '$dataDir/audit.ndjson';

  /// Read audit entries with optional filtering and pagination.
  ///
  /// [verdictFilter]: exact match on verdict ('pass', 'warn', 'block').
  /// [guardFilter]: case-insensitive substring match on guard name.
  /// Filters are AND-combined.
  Future<AuditPage> read({
    int page = 1,
    int pageSize = 25,
    String? verdictFilter,
    String? guardFilter,
  }) async {
    final file = File(_auditPath);
    if (!file.existsSync()) return AuditPage.empty;

    final lines = await file.readAsLines();
    if (lines.isEmpty) return AuditPage.empty;

    // Parse all lines, skip malformed.
    final allEntries = <AuditEntry>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        allEntries.add(AuditEntry.fromJson(json));
      } catch (e) {
        _log.warning('Skipping malformed audit line: $e');
      }
    }

    // Reverse for newest first.
    final reversed = allEntries.reversed.toList();

    // Apply filters.
    final filtered = reversed.where((entry) {
      if (verdictFilter != null && entry.verdict != verdictFilter) return false;
      if (guardFilter != null &&
          !entry.guard.toLowerCase().contains(guardFilter.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();

    final totalEntries = filtered.length;
    final totalPages = totalEntries == 0 ? 0 : (totalEntries + pageSize - 1) ~/ pageSize;
    final safePage = page.clamp(1, totalPages == 0 ? 1 : totalPages);
    final start = (safePage - 1) * pageSize;
    final end = (start + pageSize).clamp(0, totalEntries);
    final pageEntries = start < totalEntries ? filtered.sublist(start, end) : <AuditEntry>[];

    return AuditPage(
      entries: pageEntries,
      totalEntries: totalEntries,
      currentPage: safePage,
      totalPages: totalPages,
      pageSize: pageSize,
    );
  }
}
