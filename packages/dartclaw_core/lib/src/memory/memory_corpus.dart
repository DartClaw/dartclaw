import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'canonical_memory.dart';
import 'memory_documents.dart';
import 'memory_markdown_codec.dart';

/// Preserved opaque bytes held under the canonical legacy subtree.
final class VerbatimMemoryMember {
  new({required this.path, required List<int> bytes}) : _bytes = Uint8List.fromList(bytes) {
    final segments = path.split('/');
    if (path.contains(r'\') ||
        !RegExp(r'^memory/legacy/(?:[^/]+/)*[^/]+$').hasMatch(path) ||
        segments.any((segment) => segment == '.' || segment == '..')) {
      throw ArgumentError.value(path, 'path', 'must be beneath memory/legacy');
    }
  }

  final String path;
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
}

/// An immutable canonical corpus plus preserved opaque legacy members.
final class CanonicalMemoryCorpus {
  new({
    required this.index,
    Iterable<MemoryTopicDocument> topics = const [],
    MemoryArchiveDocument? archive,
    Iterable<MemoryObservationDocument> observations = const [],
    MemoryLearningDocument? learnings,
    MemoryAuditDocument? audit,
    Iterable<VerbatimMemoryMember> verbatimMembers = const [],
  }) : topics = List.unmodifiable(topics.toList()..sort((left, right) => left.topic.compareTo(right.topic))),
       archive = archive,
       observations = List.unmodifiable(observations.toList()..sort((left, right) => left.date.compareTo(right.date))),
       learnings = learnings,
       audit = audit,
       verbatimMembers = List.unmodifiable(
         verbatimMembers.toList()..sort((left, right) => left.path.compareTo(right.path)),
       );

  final MemoryIndexDocument index;
  final List<MemoryTopicDocument> topics;
  final MemoryArchiveDocument? archive;
  final List<MemoryObservationDocument> observations;
  final MemoryLearningDocument? learnings;
  final MemoryAuditDocument? audit;
  final List<VerbatimMemoryMember> verbatimMembers;

  /// Returns a new lexicographically ordered canonical and verbatim byte inventory.
  SplayTreeMap<String, Uint8List> byteInventory([MemoryMarkdownCodec codec = const MemoryMarkdownCodec()]) {
    final inventory = SplayTreeMap<String, Uint8List>();
    void addCanonical(String path, CanonicalMemoryDocument document) {
      if (inventory.containsKey(path)) throw MemoryCorpusValidationException(['duplicate corpus path: $path']);
      inventory[path] = Uint8List.fromList(utf8.encode(codec.render(document)));
    }

    addCanonical('MEMORY.md', index);
    for (final topic in topics) {
      addCanonical('memory/topics/${topic.topic}.md', topic);
    }
    if (archive case final archive?) addCanonical('MEMORY.archive.md', archive);
    for (final observation in observations) {
      addCanonical('memory/${observation.date}.md', observation);
    }
    if (learnings case final learnings?) addCanonical('learnings.md', learnings);
    if (audit case final audit?) addCanonical('MEMORY.audit.md', audit);
    for (final member in verbatimMembers) {
      if (inventory.containsKey(member.path)) {
        throw MemoryCorpusValidationException(['duplicate corpus path: ${member.path}']);
      }
      inventory[member.path] = Uint8List.fromList(member.bytes);
    }
    return inventory;
  }
}

/// Reports every cross-document inconsistency found in a corpus.
final class MemoryCorpusValidationException implements Exception {
  new(Iterable<String> errors) : errors = List.unmodifiable(errors);
  final List<String> errors;
  @override
  String toString() => 'Invalid canonical memory corpus: ${errors.join('; ')}';
}

/// Enforces canonical identity and active-index consistency across documents.
final class MemoryCorpusValidator {
  const new();

  /// Throws [MemoryCorpusValidationException] when cross-document invariants fail.
  void validate(CanonicalMemoryCorpus corpus) {
    final errors = <String>[];
    final active = <String, CanonicalMemoryEntry>{};
    final topicNames = <String>{};
    for (final topic in corpus.topics) {
      if (!topicNames.add(topic.topic)) errors.add('duplicate topic document: ${topic.topic}');
      for (final entry in topic.entries) {
        if (active.containsKey(entry.id)) errors.add('duplicate active entry ID: ${entry.id}');
        active[entry.id] = entry;
      }
    }

    final archived = <String>{};
    for (final entry in corpus.archive?.entries ?? const <CanonicalMemoryEntry>[]) {
      if (!archived.add(entry.id)) errors.add('duplicate archive entry ID: ${entry.id}');
      if (active.containsKey(entry.id)) errors.add('entry ID exists in active and archive documents: ${entry.id}');
    }

    final indexIds = <String>{};
    for (final row in corpus.index.entries) {
      if (!indexIds.add(row.id)) errors.add('duplicate index entry ID: ${row.id}');
      final detail = active[row.id];
      if (detail == null) {
        errors.add('dangling index entry: ${row.id}');
        continue;
      }
      if (row.topic != detail.topic) errors.add('topic mismatch for ${row.id}');
      if (row.revision != detail.revision) errors.add('revision mismatch for ${row.id}');
      if (row.summary != detail.summary) errors.add('summary mismatch for ${row.id}');
      if (row.updated != detail.updated) errors.add('updated timestamp mismatch for ${row.id}');
      if (row.locator != detail.locator) errors.add('locator mismatch for ${row.id}');
    }
    for (final id in active.keys) {
      if (!indexIds.contains(id)) errors.add('active entry absent from index: $id');
    }

    final nonActiveIds = <String>{...archived};
    final observationDates = <String>{};
    for (final document in corpus.observations) {
      if (!observationDates.add(document.date)) errors.add('duplicate observation document: ${document.date}');
      for (final observation in document.observations) {
        if (!nonActiveIds.add(observation.id) || active.containsKey(observation.id)) {
          errors.add('duplicate canonical record ID: ${observation.id}');
        }
      }
    }
    for (final learning in corpus.learnings?.entries ?? const <CanonicalMemoryLearning>[]) {
      if (!nonActiveIds.add(learning.id) || active.containsKey(learning.id)) {
        errors.add('duplicate canonical record ID: ${learning.id}');
      }
    }

    final retired = <String>{};
    for (final record in corpus.audit?.records ?? const <MemoryDeletionAudit>[]) {
      if (!retired.add(record.entryId)) errors.add('duplicate deletion-audit entry ID: ${record.entryId}');
    }
    for (final id in retired) {
      if (active.containsKey(id) || nonActiveIds.contains(id)) {
        errors.add('retired entry ID is present in the canonical corpus: $id');
      }
    }

    final verbatimPaths = <String>{};
    for (final member in corpus.verbatimMembers) {
      if (!verbatimPaths.add(member.path)) errors.add('duplicate corpus path: ${member.path}');
    }
    if (errors.isNotEmpty) throw MemoryCorpusValidationException(errors);
  }
}
