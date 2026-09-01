import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:uuid/uuid.dart';

import 'canonical_memory.dart';
import 'memory_corpus.dart';
import 'memory_corpus_service.dart';
import 'memory_documents.dart';
import 'memory_entry_parser.dart';
import 'memory_resource_limits.dart';

/// Manages daily memory logs and bounded reads of workspace memory files.
class MemoryFileService {
  /// Maximum UTF-8 size of one daily-log record before a visible truncation marker is added.
  static const maxDailyLogEntryBytes = 512 * 1024;

  /// Maximum UTF-8 size retained in one date-partitioned daily-log file.
  static const maxDailyLogFileBytes = MemoryResourceLimits.observationPartitionBytes;

  /// Maximum size read from one canonical workspace text file.
  static const maxReadableFileBytes = MemoryResourceLimits.sourceBytes;
  static const _maxTraversalEntities = MemoryResourceLimits.recursiveFiles * 2 + 1;
  static const _dailyLogEntryTruncated = '\n\n[Daily log record truncated at 512 KiB]\n';
  static const _uuid = Uuid();
  final String baseDir;
  final MemoryCorpusService _corpusService;
  final bool _ownsCorpusService;
  new({required this.baseDir, MemoryCorpusService? corpusService})
    : _corpusService = corpusService ?? MemoryCorpusService(workspaceDir: baseDir),
      _ownsCorpusService = corpusService == null;

  /// Shared canonical corpus authority.
  MemoryCorpusService get corpusService => _corpusService;

  /// Appends an entry to the daily log file (`memory/YYYY-MM-DD.md`).
  Future<void> appendDailyLog(String entry) {
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final path = 'memory/$dateStr.md';
    if (!_ownsCorpusService) {
      return _appendCanonicalDailyLog(entry: entry, now: now, date: dateStr, path: path);
    }
    return _corpusService
        .updateFiles<int>(
          paths: [path],
          prepare: (files) {
            final bytes = files[path];
            final existing = bytes == null ? '' : _readBoundedDailyLogBytes(bytes);
            final boundedEntry = _truncateUtf8(entry, maxDailyLogEntryBytes, _dailyLogEntryTruncated);
            final content = _appendBoundedDailyLog(existing, '$boundedEntry\n', path);
            return MemoryCorpusFileMutation(value: 0, writes: {path: utf8.encode(content)});
          },
          prepareCanonical: (corpus) {
            final recorded = now.toUtc();
            final canonicalDate = recorded.toIso8601String().substring(0, 10);
            final bounded = _truncateUtf8(entry, maxDailyLogEntryBytes, _dailyLogEntryTruncated).trim();
            final observation = MemoryObservation(
              id: _uuid.v4(),
              recorded: recorded,
              content: bounded,
              trustLabel: 'untrusted-user-content',
              isTruncated: bounded != entry.trim(),
              provenance: MemorySourceRef(sourceLocator: 'daily-log'),
            );
            final observations = [...corpus.observations];
            final documentIndex = observations.indexWhere((document) => document.date == canonicalDate);
            if (documentIndex < 0) {
              observations.add(MemoryObservationDocument(date: canonicalDate, observations: [observation]));
            } else {
              observations[documentIndex] = MemoryObservationDocument(
                date: canonicalDate,
                observations: [...observations[documentIndex].observations, observation],
              );
            }
            final replacement = _replaceCorpus(corpus, observations: observations);
            final projectedBytes = replacement.byteInventory()['memory/$canonicalDate.md']!.length;
            if (projectedBytes > maxDailyLogFileBytes) {
              throw MemoryResourceLimitException(
                role: MemoryRole.observation,
                locator: 'memory/$canonicalDate.md',
                observedBytes: projectedBytes,
                limitBytes: maxDailyLogFileBytes,
                currentBytes: corpus.byteInventory()['memory/$canonicalDate.md']?.length ?? 0,
              );
            }
            return MemoryCorpusMutation(value: 0, corpus: replacement);
          },
          bootstrapCanonical: !_ownsCorpusService,
        )
        .then<void>((_) {});
  }

  Future<void> _appendCanonicalDailyLog({
    required String entry,
    required DateTime now,
    required String date,
    required String path,
  }) async {
    while (true) {
      final manifest = await _corpusService.manifest();
      final result = await _corpusService.changeSelected<int>(
        expectedRevision: manifest.collectionRevision,
        include: (role, locator) => role == MemoryRole.observation && locator == path,
        paths: [path],
        prepare: (corpus) {
          final recorded = now.toUtc();
          final bounded = _truncateUtf8(entry, maxDailyLogEntryBytes, _dailyLogEntryTruncated).trim();
          final observation = MemoryObservation(
            id: _uuid.v4(),
            recorded: recorded,
            content: bounded,
            trustLabel: 'untrusted-user-content',
            isTruncated: bounded != entry.trim(),
            provenance: MemorySourceRef(sourceLocator: 'daily-log'),
          );
          MemoryObservationDocument? prior;
          for (final document in corpus.observations) {
            if (document.date == date) prior = document;
          }
          final document = MemoryObservationDocument(
            date: date,
            observations: [...prior?.observations ?? const <MemoryObservation>[], observation],
          );
          final replacement = CanonicalMemoryCorpus(index: corpus.index, observations: [document]);
          final projectedBytes = replacement.byteInventory()[path]!.length;
          final currentBytes = prior == null
              ? 0
              : CanonicalMemoryCorpus(index: corpus.index, observations: [prior]).byteInventory()[path]!.length;
          if (projectedBytes > maxDailyLogFileBytes) {
            throw MemoryResourceLimitException(
              role: MemoryRole.observation,
              locator: path,
              observedBytes: projectedBytes,
              limitBytes: maxDailyLogFileBytes,
              currentBytes: currentBytes,
            );
          }
          return MemoryCorpusChange(value: 0, replacement: replacement);
        },
      );
      if (!result.wasStale) return;
    }
  }

  /// Disposes write queue. Drains in-flight writes before completing.
  Future<void> dispose() => _ownsCorpusService ? _corpusService.close() : Future.value();

  /// Strips markdown formatting for cleaner FTS5 indexing.
  static String stripMarkdown(String text) => text
      .replaceAll(RegExp(r'#{1,6}\s*'), '')
      .replaceAll(RegExp(r'\*{1,2}|_{1,2}'), '')
      .replaceAll(RegExp(r'`{1,3}'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'^>\s*', multiLine: true), '')
      .trim();

  /// Splits text >maxChars at paragraph boundaries.
  static List<String> splitParagraphs(String text, {int maxChars = 500}) {
    if (text.length <= maxChars) return [text];
    final chunks = <String>[];
    for (final para in text.split('\n\n')) {
      if (para.length <= maxChars) {
        chunks.add(para);
        continue;
      }
      var remaining = '';
      for (final line in para.split('\n')) {
        if (remaining.isNotEmpty && remaining.length + line.length + 1 > maxChars) {
          chunks.add(remaining.trim());
          remaining = '';
        }
        remaining = remaining.isEmpty ? line : '$remaining\n$line';
      }
      remaining = remaining.trim();
      while (remaining.length > maxChars) {
        var end = remaining.lastIndexOf(' ', maxChars);
        if (end <= 0) end = maxChars;
        chunks.add(remaining.substring(0, end).trim());
        remaining = remaining.substring(end).trim();
      }
      if (remaining.isNotEmpty) chunks.add(remaining);
    }
    return chunks.where((c) => c.isNotEmpty).toList();
  }

  static CanonicalMemoryCorpus _replaceCorpus(
    CanonicalMemoryCorpus corpus, {
    MemoryIndexDocument? index,
    Iterable<MemoryTopicDocument>? topics,
    Iterable<MemoryObservationDocument>? observations,
  }) => CanonicalMemoryCorpus(
    index: index ?? corpus.index,
    topics: topics ?? corpus.topics,
    archive: corpus.archive,
    observations: observations ?? corpus.observations,
    learnings: corpus.learnings,
    errors: corpus.errors,
    audit: corpus.audit,
    verbatimMembers: corpus.verbatimMembers,
  );

  /// Whether appending a new top-level section would enter an unclosed fence.
  static bool hasUnclosedFence(String text) => findMemoryCategoryInsertion(text.split('\n'), '\u0000').hasUnclosedFence;

  static String _appendBoundedDailyLog(String existing, String entry, String locator) {
    final combined = '$existing$entry';
    final projectedBytes = utf8.encode(combined).length;
    if (projectedBytes > maxDailyLogFileBytes) {
      throw MemoryResourceLimitException(
        role: MemoryRole.observation,
        locator: locator,
        observedBytes: projectedBytes,
        limitBytes: maxDailyLogFileBytes,
        currentBytes: utf8.encode(existing).length,
      );
    }
    return combined;
  }

  static String _readBoundedDailyLogBytes(List<int> bytes) {
    if (bytes.length > maxDailyLogFileBytes) {
      throw MemoryResourceLimitException(
        role: MemoryRole.observation,
        locator: 'daily-log partition',
        observedBytes: bytes.length,
        limitBytes: maxDailyLogFileBytes,
      );
    }
    return utf8.decode(bytes);
  }

  static String _truncateUtf8(String value, int maxBytes, String marker) {
    if (utf8.encode(value).length <= maxBytes) return value;
    return '${truncateUtf8Bytes(value, maxBytes - utf8.encode(marker).length)}$marker';
  }

  /// Reads [file] when its stable leaf is regular; returns `null` if missing and rejects symlinks and non-files.
  static String? readRegularFile(File file, {int maxBytes = maxReadableFileBytes, MemoryRole? role}) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) throw FileSystemException('Unexpected filesystem entity', file.path);
    final handle = file.openSync();
    try {
      final sizeBytes = handle.lengthSync();
      if (sizeBytes > maxBytes) {
        if (role != null) {
          throw MemoryResourceLimitException(
            role: role,
            locator: file.path,
            observedBytes: sizeBytes,
            limitBytes: maxBytes,
          );
        }
        throw FileSystemException('File exceeds $maxBytes-byte read limit', file.path);
      }
      final bytes = handle.readSync(sizeBytes);
      return utf8.decode(bytes);
    } finally {
      handle.closeSync();
    }
  }

  /// Selects at most [limit] regular descendants in stable relative-path order without following links.
  ///
  /// [complete] is false when the fixed entity-traversal budget prevents proving a deterministic prefix.
  /// In that case no filesystem-order-dependent candidate is returned.
  static Future<({List<File> files, File? firstOmitted, int omittedCount, bool complete})> listRegularFilesBounded(
    Directory root, {
    int limit = MemoryResourceLimits.recursiveFiles,
  }) async {
    if (limit < 1 || limit > MemoryResourceLimits.recursiveFiles) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and ${MemoryResourceLimits.recursiveFiles}');
    }
    if (FileSystemEntity.typeSync(root.path, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Expected a regular directory', root.path);
    }

    final collection = await _collectRegularFiles(root);
    if (!collection.complete) {
      return (files: const <File>[], firstOmitted: null, omittedCount: 0, complete: false);
    }
    final selected = collection.files;
    selected.sort((left, right) => left.path.compareTo(right.path));
    final firstOmitted = selected.length > limit ? selected[limit] : null;
    return (
      files: List<File>.unmodifiable(selected.take(limit)),
      firstOmitted: firstOmitted,
      omittedCount: selected.length > limit ? selected.length - limit : 0,
      complete: true,
    );
  }

  static Future<({List<File> files, bool complete})> _collectRegularFiles(Directory root) async {
    final selected = <File>[];
    final pending = <Directory>[root];
    var visitedEntities = 0;
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      final entries = <FileSystemEntity>[];
      await for (final entity in directory.list(followLinks: false)) {
        visitedEntities++;
        if (visitedEntities > _maxTraversalEntities) {
          return (files: const <File>[], complete: false);
        }
        entries.add(entity);
      }
      entries.sort((left, right) => left.path.compareTo(right.path));
      for (final entity in entries) {
        if (entity is File) selected.add(entity);
        if (entity is Directory) pending.add(entity);
      }
      pending.sort((left, right) => right.path.compareTo(left.path));
    }
    return (files: selected, complete: true);
  }
}
