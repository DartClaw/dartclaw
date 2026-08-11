import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show MemoryEntry, MemoryFileService, RepoLock, parseMemoryEntries, secureWriteFileSync;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../storage/memory_service.dart';

/// Result of a pruning operation.
typedef PruneResult = ({int entriesArchived, int duplicatesRemoved, int entriesRemaining, int finalSizeBytes});

/// Manages MEMORY.md size through timestamp-based archival and deduplication.
///
/// Entries older than [archiveAfterDays] are moved to MEMORY.archive.md.
/// Exact duplicates (by normalized text) are removed, keeping the newest.
/// Undated entries are preserved (never archived or removed as duplicates).
class MemoryPruner {
  static final _log = Logger('MemoryPruner');
  static final _workspaceMemoryLock = RepoLock();
  static const _emptyResult = (entriesArchived: 0, duplicatesRemoved: 0, entriesRemaining: 0, finalSizeBytes: 0);

  /// Workspace directory containing `MEMORY.md` and `MEMORY.archive.md`.
  final String workspaceDir;

  /// Storage-backed memory service for index synchronization.
  final MemoryService memoryService;

  /// Age threshold in days after which entries are archived.
  final int archiveAfterDays;
  final void Function(File target, String contents) _writeFile;
  String? _resolvedWorkspaceDir;

  /// Creates a pruner that operates on the given [workspaceDir].
  MemoryPruner({
    required this.workspaceDir,
    required this.memoryService,
    this.archiveAfterDays = 90,
    void Function(File target, String contents)? writeFileForTesting,
  }) : _writeFile =
           writeFileForTesting ??
           ((target, contents) => secureWriteFileSync(target, contents, restrictPermissions: false));

  /// Deduplicates and archives parsed entries while preserving opaque source content.
  Future<PruneResult> prune() {
    final root = _workspaceRoot();
    final lockRoot = root ?? p.absolute(workspaceDir);
    return _workspaceMemoryLock.acquire(p.join(lockRoot, 'MEMORY.md'), () => _pruneLocked(root));
  }

  Future<PruneResult> _pruneLocked(String? root) async {
    if (root == null) {
      memoryService.replaceSourceRows(const [], sources: const {'memory_save', 'archive'});
      _log.info('Workspace does not exist, skipping prune');
      return _emptyResult;
    }
    final file = File(p.join(root, 'MEMORY.md'));
    final content = MemoryFileService.readRegularFile(file) ?? '';

    final entries = parseMemoryEntries(content);
    final deduped = removeDuplicates(entries);
    final duplicatesRemoved = entries.length - deduped.length;

    final (:keep, :archive) = partitionByAge(deduped, archiveAfterDays);

    final hasChanges = archive.isNotEmpty || duplicatesRemoved > 0;
    final newContent = hasChanges ? _removeEntriesFromSource(content, entries, keep) : content;
    if (newContent == null) {
      throw StateError('Parsed MEMORY.md entries could not be mapped back to their source');
    }

    final archiveUpdate = archive.isEmpty ? null : _prepareArchiveUpdate(root, archive);
    final archiveContent =
        archiveUpdate?.updated ??
        archiveUpdate?.existing ??
        MemoryFileService.readRegularFile(File(p.join(root, 'MEMORY.archive.md'))) ??
        '';
    final learningsContent = MemoryFileService.readRegularFile(File(p.join(root, 'learnings.md'))) ?? '';
    final canonicalRows = [
      ..._indexEntries(parseMemoryEntries(newContent), source: 'memory_save'),
      ..._indexEntries(parseMemoryEntries(archiveContent), source: 'archive'),
      ..._indexEntries(parseMemoryEntries(learningsContent), source: 'memory_save', category: 'learning'),
    ];

    var archiveWritten = false;
    var sourceWritten = false;
    try {
      if (archiveUpdate?.updated case final updated?) {
        _writeFile(archiveUpdate!.file, updated);
        archiveWritten = true;
      }
      if (hasChanges) {
        _writeFile(file, newContent);
        sourceWritten = true;
      }
      memoryService.replaceSourceRows(canonicalRows, sources: const {'memory_save', 'archive'});
    } catch (error, stackTrace) {
      final rollbackError = _rollbackEffects(
        archiveUpdate,
        sourceFile: file,
        existingSource: content,
        updatedSource: newContent,
        archiveWritten: archiveWritten,
        sourceWritten: sourceWritten,
      );
      if (rollbackError != null) {
        Error.throwWithStackTrace(
          StateError('Memory prune failed: $error; rollback failed: $rollbackError'),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    _log.info(
      'Pruned MEMORY.md: ${archive.length} archived, '
      '$duplicatesRemoved deduped, '
      '${keep.length} remaining (${utf8.encode(newContent).length}B)',
    );

    return (
      entriesArchived: archive.length,
      duplicatesRemoved: duplicatesRemoved,
      entriesRemaining: keep.length,
      finalSizeBytes: utf8.encode(newContent).length,
    );
  }

  String? _removeEntriesFromSource(String content, List<MemoryEntry> entries, List<MemoryEntry> keep) {
    final retained = Set<MemoryEntry>.identity()..addAll(keep);
    final removalRanges = <({int start, int end})>[];
    var searchOffset = 0;

    for (final entry in entries) {
      final start = entry.sourceStart;
      final blockEnd = entry.sourceEnd;
      if (start == null || blockEnd == null || start < searchOffset || blockEnd > content.length) return null;
      if (content.substring(start, blockEnd) != entry.rawBlock) return null;
      var end = blockEnd;
      if (end < content.length && content.codeUnitAt(end) == 0x0A) end++;
      if (!retained.contains(entry)) removalRanges.add((start: start, end: end));
      searchOffset = end;
    }

    final result = StringBuffer();
    var copyOffset = 0;
    for (final range in removalRanges) {
      result.write(content.substring(copyOffset, range.start));
      copyOffset = range.end;
    }
    result.write(content.substring(copyOffset));
    return result.toString();
  }

  /// Removes exact duplicates by normalized text, keeping the newest dated entry.
  List<MemoryEntry> removeDuplicates(List<MemoryEntry> entries) {
    final seen = <String, int>{};
    final result = List<MemoryEntry?>.from(entries);

    for (var i = 0; i < entries.length; i++) {
      if (entries[i].timestamp == null) continue;
      final norm = entries[i].normalizedText;
      final existing = seen[norm];
      if (existing != null) {
        final existingEntry = entries[existing];
        final currentEntry = entries[i];
        if (_isNewer(currentEntry, existingEntry)) {
          result[existing] = null;
          seen[norm] = i;
        } else {
          result[i] = null;
        }
      } else {
        seen[norm] = i;
      }
    }

    return result.whereType<MemoryEntry>().toList();
  }

  bool _isNewer(MemoryEntry a, MemoryEntry b) => a.timestamp!.isAfter(b.timestamp!);

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

  ({File file, String? existing, String? updated}) _prepareArchiveUpdate(String root, List<MemoryEntry> entries) {
    final archiveFile = File(p.join(root, 'MEMORY.archive.md'));
    final previous = MemoryFileService.readRegularFile(archiveFile);
    final existing = previous ?? '';
    final archivedEntries = parseMemoryEntries(existing);
    final archivedIdentities = archivedEntries
        .map((entry) => (category: entry.category, rawBlock: entry.rawBlock))
        .toSet();
    final newEntries = entries
        .where((entry) => !archivedIdentities.contains((category: entry.category, rawBlock: entry.rawBlock)))
        .toList();
    if (newEntries.isEmpty) return (file: archiveFile, existing: previous, updated: null);
    if (MemoryFileService.hasUnclosedFence(existing)) {
      throw const FormatException('Cannot append to MEMORY.archive.md after an unclosed fenced block');
    }

    final separator = existing.isEmpty || existing.endsWith('\n\n')
        ? ''
        : existing.endsWith('\n')
        ? '\n'
        : '\n\n';
    final updated = '$existing$separator${reconstructMemoryMd(newEntries)}';
    return (file: archiveFile, existing: previous, updated: updated);
  }

  Iterable<MemoryIndexRow> _indexEntries(
    Iterable<MemoryEntry> entries, {
    required String source,
    String? category,
  }) sync* {
    for (final entry in entries) {
      yield* MemoryService.indexRows(
        text: entry.rawText,
        source: source,
        category: category ?? entry.category,
        createdAt: entry.timestamp,
      );
    }
  }

  Object? _rollbackEffects(
    ({File file, String? existing, String? updated})? archiveUpdate, {
    required File sourceFile,
    required String existingSource,
    required String updatedSource,
    required bool archiveWritten,
    required bool sourceWritten,
  }) {
    Object? rollbackError;
    if (sourceWritten && updatedSource != existingSource) {
      try {
        _writeFile(sourceFile, existingSource);
      } catch (error) {
        rollbackError = error;
      }
    }
    final update = archiveUpdate;
    if (archiveWritten && update?.updated != null) {
      try {
        final existing = update!.existing;
        if (existing == null) {
          if (update.file.existsSync()) update.file.deleteSync();
        } else {
          _writeFile(update.file, existing);
        }
      } catch (error) {
        rollbackError ??= error;
      }
    }
    return rollbackError;
  }

  String? _workspaceRoot() {
    if (_resolvedWorkspaceDir case final resolved?) {
      final type = FileSystemEntity.typeSync(resolved, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException('Workspace root is not a directory', resolved);
      }
      return resolved;
    }
    final directory = Directory(p.absolute(workspaceDir));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory && type != FileSystemEntityType.link) {
      throw FileSystemException('Workspace root is not a directory', directory.path);
    }
    final resolved = directory.resolveSymbolicLinksSync();
    if (FileSystemEntity.typeSync(resolved, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Workspace root does not resolve to a directory', directory.path);
    }
    return _resolvedWorkspaceDir = p.normalize(resolved);
  }
}
