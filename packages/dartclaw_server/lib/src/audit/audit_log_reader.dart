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

  static const empty = AuditPage(entries: [], totalEntries: 0, currentPage: 1, totalPages: 0, pageSize: 25);
}

/// Reads and parses date-partitioned audit logs with filtering and pagination.
///
/// Legacy `audit.ndjson` files remain readable until retention cleanup removes
/// them. Each call reads all audit files without caching and returns newest
/// entries first.
class AuditLogReader {
  static final _log = Logger('AuditLogReader');
  static final _auditFilePattern = RegExp(r'^audit-\d{4}-\d{2}-\d{2}\.ndjson$');

  final String dataDir;

  AuditLogReader({required this.dataDir});

  /// Read audit entries with optional filtering and pagination.
  ///
  /// [verdictFilter]: exact match on verdict ('pass', 'warn', 'block').
  /// [guardFilter]: case-insensitive substring match on guard name.
  /// Filters are AND-combined.
  ///
  /// Throws [FileSystemException] rather than returning a partial audit page
  /// when a retained log cannot be read.
  Future<AuditPage> read({int page = 1, int pageSize = 25, String? verdictFilter, String? guardFilter}) async {
    final files = await _auditFiles();
    if (files.isEmpty) return AuditPage.empty;

    final allEntries = <({AuditEntry entry, int sequence})>[];
    for (final file in files) {
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          allEntries.add((entry: AuditEntry.fromJson(json), sequence: allEntries.length));
        } catch (e) {
          _log.warning('Skipping malformed audit line: $e');
        }
      }
    }

    allEntries.sort((a, b) {
      final timestampOrder = b.entry.timestamp.compareTo(a.entry.timestamp);
      return timestampOrder != 0 ? timestampOrder : b.sequence.compareTo(a.sequence);
    });

    final filtered = allEntries.map((item) => item.entry).where((entry) {
      if (verdictFilter != null && entry.verdict != verdictFilter) return false;
      if (guardFilter != null && !entry.guard.toLowerCase().contains(guardFilter.toLowerCase())) {
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

  Future<List<File>> _auditFiles() async {
    final directory = Directory(dataDir);
    if (!await directory.exists()) return const [];

    final files = <File>[];
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name == 'audit.ndjson' || _auditFilePattern.hasMatch(name)) {
        files.add(entity);
      }
    }
    files.sort((a, b) {
      final aIsLegacy = a.uri.pathSegments.last == 'audit.ndjson';
      final bIsLegacy = b.uri.pathSegments.last == 'audit.ndjson';
      if (aIsLegacy != bIsLegacy) return aIsLegacy ? -1 : 1;
      return a.path.compareTo(b.path);
    });
    return files;
  }
}
