import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show MemoryEntry;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../storage/memory_service.dart';

/// Result of a pruning operation.
typedef PruneResult = ({
  int entriesArchived,
  int duplicatesRemoved,
  int entriesRemaining,
  int finalSizeBytes,
});

/// Manages MEMORY.md size through timestamp-based archival and deduplication.
///
/// Entries older than [archiveAfterDays] are moved to MEMORY.archive.md.
/// Exact duplicates (by normalized text) are removed, keeping the newest.
/// Undated entries are preserved (never archived or removed as duplicates).
class MemoryPruner {
  static final _log = Logger('MemoryPruner');
  static const _emptyResult = (entriesArchived: 0, duplicatesRemoved: 0, entriesRemaining: 0, finalSizeBytes: 0);

  static final _timestampRe = RegExp(r'^\- \[(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\]');

  final String workspaceDir;
  final MemoryService memoryService;
  final int archiveAfterDays;

  MemoryPruner({
    required this.workspaceDir,
    required this.memoryService,
    this.archiveAfterDays = 90,
  });

  String get _memoryPath => p.join(workspaceDir, 'MEMORY.md');
  String get _archivePath => p.join(workspaceDir, 'MEMORY.archive.md');

  /// Runs the full pruning cycle: deduplicate, archive old entries, rewrite MEMORY.md.
  Future<PruneResult> prune() async {
    final file = File(_memoryPath);
    if (!file.existsSync()) {
      _log.info('MEMORY.md does not exist, skipping prune');
      return _emptyResult;
    }

    final content = file.readAsStringSync();
    if (content.trim().isEmpty) {
      _log.info('MEMORY.md is empty, skipping prune');
      return _emptyResult;
    }

    final entries = parseMemoryEntries(content);
    if (entries.isEmpty) return _emptyResult;

    // Step 1: Deduplication
    final deduped = removeDuplicates(entries);
    final duplicatesRemoved = entries.length - deduped.length;

    // Step 2: Partition by age
    final (:keep, :archive) = partitionByAge(deduped, archiveAfterDays);

    // Step 3: Archive old entries
    if (archive.isNotEmpty) {
      try {
        _appendToArchive(archive);
      } catch (e) {
        _log.severe('Failed to write MEMORY.archive.md, aborting prune: $e');
        return (
          entriesArchived: 0,
          duplicatesRemoved: 0,
          entriesRemaining: entries.length,
          finalSizeBytes: content.length,
        );
      }

      // Step 4: Index archived entries in FTS5
      for (final entry in archive) {
        try {
          memoryService.insertChunk(
            text: entry.rawText,
            source: 'archive',
            category: entry.category,
          );
        } catch (e) {
          _log.warning('Failed to index archived entry: $e');
        }
      }
    }

    // Step 5: Rewrite MEMORY.md with remaining entries
    final newContent = reconstructMemoryMd(keep);
    _atomicWrite(File(_memoryPath), newContent);

    _log.info(
      'Pruned MEMORY.md: ${archive.length} archived, '
      '$duplicatesRemoved deduped, '
      '${keep.length} remaining (${newContent.length}B)',
    );

    return (
      entriesArchived: archive.length,
      duplicatesRemoved: duplicatesRemoved,
      entriesRemaining: keep.length,
      finalSizeBytes: newContent.length,
    );
  }

  /// Parses MEMORY.md content into structured entries preserving timestamps.
  List<MemoryEntry> parseMemoryEntries(String content) {
    final lines = content.split('\n');
    final entries = <MemoryEntry>[];
    var currentCategory = 'general';
    final blockLines = <String>[];
    DateTime? currentTimestamp;
    StringBuffer? currentText;

    void flushEntry() {
      if (currentText != null && blockLines.isNotEmpty) {
        final rawBlock = blockLines.join('\n');
        final rawText = currentText.toString().trim();
        if (rawText.isNotEmpty) {
          entries.add(MemoryEntry(
            timestamp: currentTimestamp,
            category: currentCategory,
            rawText: rawText,
            rawBlock: rawBlock,
          ));
        }
      }
      blockLines.clear();
      currentText = null;
      currentTimestamp = null;
    }

    for (final line in lines) {
      if (line.startsWith('## ')) {
        flushEntry();
        currentCategory = line.substring(3).trim();
        continue;
      }

      if (line.startsWith('- [')) {
        flushEntry();
        final match = _timestampRe.firstMatch(line);
        if (match != null) {
          final datePart = match.group(1)!;
          final timePart = match.group(2)!;
          try {
            currentTimestamp = DateTime.parse('${datePart}T$timePart:00');
          } catch (_) {
            currentTimestamp = null;
            _log.warning('Failed to parse timestamp from line: $line');
          }
          // Extract text after "] "
          final closeBracket = line.indexOf('] ', 2);
          if (closeBracket != -1) {
            currentText = StringBuffer(line.substring(closeBracket + 2).trim());
          } else {
            currentText = StringBuffer();
          }
        } else {
          // Entry starts with "- [" but doesn't match timestamp pattern
          currentTimestamp = null;
          currentText = StringBuffer(line.substring(2).trim());
        }
        blockLines.add(line);
        continue;
      }

      // Continuation line
      if (currentText != null && line.trim().isNotEmpty) {
        currentText!.write('\n');
        currentText!.write(line.trim());
        blockLines.add(line);
      }
    }
    flushEntry();

    return entries;
  }

  /// Removes exact duplicates by normalized text, keeping the newest entry.
  /// Undated entries are treated as newest (never removed as duplicates).
  List<MemoryEntry> removeDuplicates(List<MemoryEntry> entries) {
    final seen = <String, int>{}; // normalizedText -> index of best entry
    final result = List<MemoryEntry?>.from(entries);

    for (var i = 0; i < entries.length; i++) {
      final norm = entries[i].normalizedText;
      final existing = seen[norm];
      if (existing != null) {
        // Decide which to keep: prefer undated (treated as newest), then newer timestamp
        final existingEntry = entries[existing];
        final currentEntry = entries[i];
        if (_isNewer(currentEntry, existingEntry)) {
          result[existing] = null; // remove older
          seen[norm] = i;
        } else {
          result[i] = null; // remove current (older)
        }
      } else {
        seen[norm] = i;
      }
    }

    return result.whereType<MemoryEntry>().toList();
  }

  /// Returns true if [a] should be kept over [b] (a is "newer").
  bool _isNewer(MemoryEntry a, MemoryEntry b) => switch ((a.timestamp, b.timestamp)) {
    (null, DateTime()) => true, // undated beats dated
    (DateTime(), null) => false,
    (null, null) => false, // keep existing
    (final ta?, final tb?) => ta.isAfter(tb),
  };

  /// Partitions entries into keep/archive lists based on age threshold.
  /// Undated entries always stay in keep list.
  ({List<MemoryEntry> keep, List<MemoryEntry> archive}) partitionByAge(
    List<MemoryEntry> entries,
    int archiveAfterDays,
  ) {
    final cutoff = DateTime.now().subtract(Duration(days: archiveAfterDays));
    final keep = <MemoryEntry>[];
    final archive = <MemoryEntry>[];

    for (final entry in entries) {
      if (entry.timestamp == null || !entry.timestamp!.isBefore(cutoff)) {
        keep.add(entry);
      } else {
        archive.add(entry);
      }
    }

    return (keep: keep, archive: archive);
  }

  /// Reconstructs MEMORY.md from entries, grouping by category.
  String reconstructMemoryMd(List<MemoryEntry> entries) {
    if (entries.isEmpty) return '';

    final buf = StringBuffer();
    String? lastCategory;

    for (final entry in entries) {
      if (entry.category != lastCategory) {
        if (lastCategory != null) buf.writeln();
        buf.writeln('## ${entry.category}');
        lastCategory = entry.category;
      }
      buf.writeln(entry.rawBlock);
    }

    return buf.toString();
  }

  void _appendToArchive(List<MemoryEntry> entries) {
    final archiveFile = File(_archivePath);
    final buf = StringBuffer();
    final dateStr = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    buf.writeln('## Archived [$dateStr]');
    for (final entry in entries) {
      buf.writeln(entry.rawBlock);
    }
    buf.writeln();

    if (archiveFile.existsSync()) {
      archiveFile.writeAsStringSync(buf.toString(), mode: FileMode.append);
    } else {
      archiveFile.parent.createSync(recursive: true);
      archiveFile.writeAsStringSync(buf.toString());
    }
  }

  static void _atomicWrite(File target, String content) {
    final tempFile = File('${target.path}.tmp');
    tempFile.writeAsStringSync(content);
    tempFile.renameSync(target.path);
  }
}
