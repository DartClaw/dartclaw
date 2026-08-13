import 'canonical_memory.dart';

/// A typed canonical Markdown document with an explicit storage role.
abstract base class CanonicalMemoryDocument {
  MemoryRole get role;
}

/// Collection metadata and the bounded active-entry index.
final class MemoryIndexDocument extends CanonicalMemoryDocument {
  new({required this.metadata, Iterable<MemoryIndexEntry> entries = const []})
    : entries = immutableMemoryList(
        entries.toList()..sort((left, right) {
          final byPriority = right.priority.compareTo(left.priority);
          if (byPriority != 0) return byPriority;
          final byUpdated = right.updated.compareTo(left.updated);
          return byUpdated != 0 ? byUpdated : left.id.compareTo(right.id);
        }),
      );

  final MemoryCollectionMetadata metadata;
  final List<MemoryIndexEntry> entries;
  @override
  MemoryRole get role => MemoryRole.indexDocument;

  @override
  bool operator ==(Object other) =>
      other is MemoryIndexDocument && metadata == other.metadata && memoryListsEqual(entries, other.entries);

  @override
  int get hashCode => Object.hash(metadata, Object.hashAll(entries));
}

/// Detailed active entries for one validated topic slug.
final class MemoryTopicDocument extends CanonicalMemoryDocument {
  new({required this.topic, Iterable<CanonicalMemoryEntry> entries = const []})
    : entries = immutableMemoryList(entries.toList()..sort((left, right) => left.id.compareTo(right.id))) {
    validateMemoryTopic(topic);
    for (final entry in this.entries) {
      if (entry.topic != topic) throw ArgumentError.value(entry.topic, 'entry.topic', 'must match document topic');
    }
  }

  final String topic;
  final List<CanonicalMemoryEntry> entries;
  @override
  MemoryRole get role => MemoryRole.topic;

  @override
  bool operator ==(Object other) =>
      other is MemoryTopicDocument && topic == other.topic && memoryListsEqual(entries, other.entries);

  @override
  int get hashCode => Object.hash(topic, Object.hashAll(entries));
}

/// Detailed inactive entries whose stable identities survive archival.
final class MemoryArchiveDocument extends CanonicalMemoryDocument {
  new({Iterable<CanonicalMemoryEntry> entries = const []})
    : entries = immutableMemoryList(entries.toList()..sort((left, right) => left.id.compareTo(right.id)));
  final List<CanonicalMemoryEntry> entries;
  @override
  MemoryRole get role => MemoryRole.archive;

  @override
  bool operator ==(Object other) => other is MemoryArchiveDocument && memoryListsEqual(entries, other.entries);

  @override
  int get hashCode => Object.hashAll(entries);
}

/// Raw observations for one valid UTC calendar date.
final class MemoryObservationDocument extends CanonicalMemoryDocument {
  new({required this.date, Iterable<MemoryObservation> observations = const []})
    : observations = immutableMemoryList(
        observations.toList()..sort((left, right) {
          final byTime = left.recorded.compareTo(right.recorded);
          return byTime == 0 ? left.id.compareTo(right.id) : byTime;
        }),
      ) {
    final parsedDate = DateTime.tryParse('${date}T00:00:00Z');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        parsedDate == null ||
        parsedDate.toIso8601String().substring(0, 10) != date) {
      throw ArgumentError.value(date, 'date', 'must be a valid YYYY-MM-DD date');
    }
    for (final observation in this.observations) {
      if (observation.recorded.toIso8601String().substring(0, 10) != date) {
        throw ArgumentError.value(observation.recorded, 'observation.recorded', 'must match document date');
      }
    }
  }
  final String date;
  final List<MemoryObservation> observations;
  @override
  MemoryRole get role => MemoryRole.observation;

  @override
  bool operator ==(Object other) =>
      other is MemoryObservationDocument && date == other.date && memoryListsEqual(observations, other.observations);

  @override
  int get hashCode => Object.hash(date, Object.hashAll(observations));
}

/// Canonical bounded runtime learnings with stable entry identity.
final class MemoryLearningDocument extends CanonicalMemoryDocument {
  new({Iterable<CanonicalMemoryLearning> entries = const []}) : entries = immutableMemoryList(entries);
  final List<CanonicalMemoryLearning> entries;
  @override
  MemoryRole get role => MemoryRole.learning;

  @override
  bool operator ==(Object other) => other is MemoryLearningDocument && memoryListsEqual(entries, other.entries);

  @override
  int get hashCode => Object.hashAll(entries);
}

/// Canonical deletion records whose host fields do not copy entry content.
final class MemoryAuditDocument extends CanonicalMemoryDocument {
  new({Iterable<MemoryDeletionAudit> records = const []})
    : records = immutableMemoryList(
        records.toList()..sort((left, right) {
          final byTime = left.deletedAt.compareTo(right.deletedAt);
          if (byTime != 0) return byTime;
          final byEntry = left.entryId.compareTo(right.entryId);
          if (byEntry != 0) return byEntry;
          return _compareAuditContent(left, right);
        }),
      );
  final List<MemoryDeletionAudit> records;
  @override
  MemoryRole get role => MemoryRole.audit;

  @override
  bool operator ==(Object other) => other is MemoryAuditDocument && memoryListsEqual(records, other.records);

  @override
  int get hashCode => Object.hashAll(records);
}

int _compareAuditContent(MemoryDeletionAudit left, MemoryDeletionAudit right) {
  for (final values in [
    (left.reason, right.reason),
    (left.provenance.originKind?.name, right.provenance.originKind?.name),
    (left.provenance.sourceLocator, right.provenance.sourceLocator),
    (left.provenance.sourceEvent, right.provenance.sourceEvent),
    (left.provenance.caller, right.provenance.caller),
    (left.provenance.sessionRef, right.provenance.sessionRef),
  ]) {
    final comparison = _compareNullableStrings(values.$1, values.$2);
    if (comparison != 0) return comparison;
  }
  return 0;
}

int _compareNullableStrings(String? left, String? right) {
  if (left == null) return right == null ? 0 : -1;
  if (right == null) return 1;
  return left.compareTo(right);
}
