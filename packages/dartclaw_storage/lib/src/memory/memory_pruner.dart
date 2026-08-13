import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        CanonicalMemoryCorpus,
        CanonicalMemoryEntry,
        MemoryArchiveDocument,
        MemoryAuditDocument,
        MemoryCorpusChange,
        MemoryCorpusFileMutation,
        MemoryCorpusMutation,
        MemoryCorpusService,
        MemoryDeletionAudit,
        MemoryEntry,
        MemoryFileService,
        MemoryIndexDocument,
        MemoryIndexEntry,
        MemoryRole,
        MemoryTopicDocument,
        parseMemoryEntries;
import 'package:logging/logging.dart';

import '../storage/memory_service.dart';

/// Result of a pruning operation.
typedef PruneResult = ({int entriesArchived, int duplicatesRemoved, int entriesRemaining, int finalSizeBytes});

/// Manages MEMORY.md size through timestamp-based archival.
///
/// Entries older than [archiveAfterDays] are moved to MEMORY.archive.md.
/// Legacy duplicates are preserved because they lack complete replay provenance.
/// Undated legacy entries are preserved and never archived.
class MemoryPruner {
  static final _log = Logger('MemoryPruner');

  /// Workspace directory containing `MEMORY.md` and `MEMORY.archive.md`.
  final String workspaceDir;

  /// Storage-backed memory service for index synchronization.
  final MemoryService memoryService;

  /// Age threshold in days after which entries are archived.
  final int archiveAfterDays;
  final MemoryCorpusService _corpusService;
  final bool _ownsCorpusService;

  /// Creates a pruner that operates on the given [workspaceDir].
  MemoryPruner({
    required this.workspaceDir,
    required this.memoryService,
    this.archiveAfterDays = 90,
    void Function(File target, String contents)? writeFileForTesting,
    MemoryCorpusService? corpusService,
  }) : _ownsCorpusService = corpusService == null,
       _corpusService =
           corpusService ??
           MemoryCorpusService(
             workspaceDir: workspaceDir,
             legacyWriteForTesting: writeFileForTesting == null
                 ? null
                 : (target, bytes) => writeFileForTesting(target, utf8.decode(bytes)),
           ) {
    if (archiveAfterDays <= 0) {
      throw ArgumentError.value(archiveAfterDays, 'memory.pruning.archive_after_days', 'must be a positive integer');
    }
  }

  /// Archives parsed entries and removes canonical exact replay duplicates.
  Future<PruneResult> prune() {
    if (!_ownsCorpusService) return _pruneCanonicalSelected();
    return _corpusService
        .updateFiles<({PruneResult result, List<MemoryIndexRow> rows})>(
          paths: const ['MEMORY.md', 'MEMORY.archive.md', 'learnings.md'],
          prepare: _preparePrune,
          prepareCanonical: _prepareCanonicalPrune,
          bootstrapCanonical: !_ownsCorpusService,
          afterCommit: (prepared) {
            if (!_corpusService.hasPostCommitProjection) memoryService.replaceMemoryRows(prepared.rows);
          },
          rollbackOnAfterCommitFailure: true,
        )
        .then((prepared) => prepared.result);
  }

  Future<PruneResult> _pruneCanonicalSelected() async {
    while (true) {
      final manifest = await _corpusService.manifest();
      var priorIds = <String>{};
      final changed = await _corpusService.changeSelected<({PruneResult result, List<MemoryIndexRow> rows})>(
        expectedRevision: manifest.collectionRevision,
        include: (role, _) => const {MemoryRole.topic, MemoryRole.archive, MemoryRole.audit}.contains(role),
        paths: const ['MEMORY.archive.md', 'MEMORY.audit.md'],
        prepare: (corpus) {
          priorIds = {
            for (final topic in corpus.topics) ...topic.entries.map((entry) => entry.id),
            ...?corpus.archive?.entries.map((entry) => entry.id),
          };
          final mutation = _prepareCanonicalPrune(corpus);
          return MemoryCorpusChange(value: mutation.value, replacement: mutation.corpus);
        },
        afterCommit: (prepared, _) {
          if (!_corpusService.hasPostCommitProjection) {
            memoryService.replaceMemoryRecords(prepared.rows, priorIds);
          }
        },
      );
      if (changed.wasStale) continue;
      return changed.value!.result;
    }
  }

  MemoryCorpusMutation<({PruneResult result, List<MemoryIndexRow> rows})> _prepareCanonicalPrune(
    CanonicalMemoryCorpus corpus,
  ) {
    final all = corpus.topics.expand((document) => document.entries).toList();
    final (:survivors, :duplicates) = _deduplicateCanonical(all);
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: archiveAfterDays));
    final retained = survivors.where((entry) => !entry.updated.isBefore(cutoff)).toList();
    final archived = survivors.where((entry) => entry.updated.isBefore(cutoff)).toList();
    final topics = <String, List<CanonicalMemoryEntry>>{};
    for (final entry in retained) {
      (topics[entry.topic] ??= []).add(entry);
    }
    final topicDocuments = topics.entries.map((entry) => MemoryTopicDocument(topic: entry.key, entries: entry.value));
    final priorityById = {for (final entry in corpus.index.entries) entry.id: entry.priority};
    final indexEntries = retained.map(
      (entry) => MemoryIndexEntry(
        id: entry.id,
        revision: entry.revision,
        topic: entry.topic,
        summary: entry.summary,
        updated: entry.updated,
        priority: priorityById[entry.id] ?? 0,
      ),
    );
    final archiveEntries = {...corpus.archive?.entries ?? const <CanonicalMemoryEntry>[], ...archived}.toList();
    final deletedAt = DateTime.now().toUtc();
    final audits = [
      ...corpus.audit?.records ?? const <MemoryDeletionAudit>[],
      for (final duplicate in duplicates)
        MemoryDeletionAudit(
          entryId: duplicate.id,
          deletedAt: deletedAt,
          reason: 'exact replay duplicate',
          provenance: duplicate.provenance,
        ),
    ];
    final replacement = CanonicalMemoryCorpus(
      index: MemoryIndexDocument(metadata: corpus.index.metadata, entries: indexEntries),
      topics: topicDocuments,
      archive: archiveEntries.isEmpty ? null : MemoryArchiveDocument(entries: archiveEntries),
      observations: corpus.observations,
      learnings: corpus.learnings,
      audit: audits.isEmpty ? null : MemoryAuditDocument(records: audits),
      verbatimMembers: corpus.verbatimMembers,
    );
    final rows = MemoryService.canonicalIndexRows(replacement);
    final result = (
      entriesArchived: archived.length,
      duplicatesRemoved: duplicates.length,
      entriesRemaining: retained.length,
      finalSizeBytes: replacement.byteInventory()['MEMORY.md']!.length,
    );
    return MemoryCorpusMutation(value: (result: result, rows: rows), corpus: replacement);
  }

  ({List<CanonicalMemoryEntry> survivors, List<CanonicalMemoryEntry> duplicates}) _deduplicateCanonical(
    List<CanonicalMemoryEntry> entries,
  ) {
    final ordered = [...entries]
      ..sort((left, right) {
        final byCreated = left.created.compareTo(right.created);
        return byCreated != 0 ? byCreated : left.id.compareTo(right.id);
      });
    final survivors = <CanonicalMemoryEntry>[];
    final duplicates = <CanonicalMemoryEntry>[];
    final replayKeys =
        <
          ({String topic, String content, String origin, String locator, String event, String caller, String session})
        >{};
    for (final candidate in ordered) {
      final provenance = candidate.provenance;
      final origin = provenance.originKind;
      final event = provenance.sourceEvent;
      final caller = provenance.caller;
      final session = provenance.sessionRef;
      final key = origin == null || event == null || caller == null || session == null
          ? null
          : (
              topic: candidate.topic,
              content: _normalizeContent(candidate.content),
              origin: origin.name,
              locator: provenance.sourceLocator,
              event: event,
              caller: caller,
              session: session,
            );
      if (key != null && !replayKeys.add(key)) {
        duplicates.add(candidate);
      } else {
        survivors.add(candidate);
      }
    }
    return (survivors: survivors, duplicates: duplicates);
  }

  String _normalizeContent(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

  MemoryCorpusFileMutation<({PruneResult result, List<MemoryIndexRow> rows})> _preparePrune(
    Map<String, List<int>?> files,
  ) {
    final content = files['MEMORY.md'] == null ? '' : utf8.decode(files['MEMORY.md']!);

    final entries = parseMemoryEntries(content);
    const duplicatesRemoved = 0;

    final (:keep, :archive) = _partitionByAge(entries, archiveAfterDays);

    final hasChanges = archive.isNotEmpty;
    final newContent = hasChanges ? _removeEntriesFromSource(content, entries, keep) : content;
    if (newContent == null) {
      throw StateError('Parsed MEMORY.md entries could not be mapped back to their source');
    }

    final existingArchive = files['MEMORY.archive.md'] == null ? '' : utf8.decode(files['MEMORY.archive.md']!);
    final archiveContent = archive.isEmpty ? existingArchive : _updatedArchive(existingArchive, archive);
    final learningsContent = files['learnings.md'] == null ? '' : utf8.decode(files['learnings.md']!);
    final canonicalRows = [
      ..._indexEntries(parseMemoryEntries(newContent), source: 'legacy-memory'),
      ..._indexEntries(parseMemoryEntries(archiveContent), source: 'legacy-archive'),
      ..._indexEntries(parseMemoryEntries(learningsContent), source: 'legacy-learning', category: 'learning'),
    ];

    _log.info(
      'Pruned MEMORY.md: ${archive.length} archived, '
      '$duplicatesRemoved deduped, '
      '${keep.length} remaining (${utf8.encode(newContent).length}B)',
    );

    final result = (
      entriesArchived: archive.length,
      duplicatesRemoved: duplicatesRemoved,
      entriesRemaining: keep.length,
      finalSizeBytes: utf8.encode(newContent).length,
    );
    return MemoryCorpusFileMutation(
      value: (result: result, rows: canonicalRows),
      writes: {
        if (hasChanges) 'MEMORY.md': utf8.encode(newContent),
        if (archiveContent != existingArchive) 'MEMORY.archive.md': utf8.encode(archiveContent),
      },
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

  ({List<MemoryEntry> keep, List<MemoryEntry> archive}) _partitionByAge(
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

  String _reconstructMemoryMd(List<MemoryEntry> entries) {
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

  String _updatedArchive(String existing, List<MemoryEntry> entries) {
    final archivedEntries = parseMemoryEntries(existing);
    final archivedIdentities = archivedEntries
        .map((entry) => (category: entry.category, rawBlock: entry.rawBlock))
        .toSet();
    final newEntries = entries
        .where((entry) => !archivedIdentities.contains((category: entry.category, rawBlock: entry.rawBlock)))
        .toList();
    if (newEntries.isEmpty) return existing;
    if (MemoryFileService.hasUnclosedFence(existing)) {
      throw const FormatException('Cannot append to MEMORY.archive.md after an unclosed fenced block');
    }

    final separator = existing.isEmpty || existing.endsWith('\n\n')
        ? ''
        : existing.endsWith('\n')
        ? '\n'
        : '\n\n';
    return '$existing$separator${_reconstructMemoryMd(newEntries)}';
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
}
