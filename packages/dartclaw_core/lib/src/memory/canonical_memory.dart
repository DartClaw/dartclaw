import 'dart:collection';

import '../storage/uuid_validation.dart';

/// The only canonical memory Markdown format version supported by this release.
const canonicalMemoryFormatVersion = 1;

final _topicSlug = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

void _requireId(String value, String field) {
  if (!isValidUuid(value)) throw ArgumentError.value(value, field, 'must be a canonical lowercase UUID');
}

void _requireRevision(int value, String field) {
  if (value < 1) throw ArgumentError.value(value, field, 'must be positive');
}

void _requireText(String value, String field) {
  if (value.trim().isEmpty) throw ArgumentError.value(value, field, 'must not be blank');
}

void _requireUtc(DateTime value, String field) {
  if (!value.isUtc) throw ArgumentError.value(value, field, 'must be UTC');
}

/// Validates the canonical lowercase topic slug contract.
void validateMemoryTopic(String topic) {
  if (topic.length > 64 || !_topicSlug.hasMatch(topic)) {
    throw ArgumentError.value(topic, 'topic', 'must be a lowercase slug of at most 64 characters');
  }
}

/// Discriminates canonical memory documents and external knowledge layers.
enum MemoryRole {
  indexDocument('index'),
  topic('topic'),
  archive('archive'),
  observation('observation'),
  learning('learning'),
  audit('audit'),
  wiki('wiki'),
  kg('kg');

  new(this.wireName);

  final String wireName;

  static MemoryRole parse(String value) => values.firstWhere(
    (role) => role.wireName == value,
    orElse: () => throw FormatException('Unsupported memory role: $value'),
  );

  bool get isIndexEligible => this == MemoryRole.topic;
}

/// Identifies the closed set of canonical memory capture paths.
enum MemoryOriginKind {
  turn,
  journal,
  inbox,
  curation,
  migration;

  static MemoryOriginKind parse(String value) => values.firstWhere(
    (kind) => kind.name == value,
    orElse: () => throw FormatException('Unsupported memory origin kind: $value'),
  );
}

/// Carries source provenance for a canonical memory record.
final class MemorySourceRef {
  /// Creates a provenance reference.
  ///
  /// [sourceLocator] and every present optional text field must be nonblank.
  /// Capture origins require [sourceEvent]; manual and migration references
  /// require it to be absent. Throws [ArgumentError] when either contract is
  /// violated.
  new({this.originKind, required this.sourceLocator, this.sourceEvent, this.caller, this.sessionRef}) {
    _requireText(sourceLocator, 'sourceLocator');
    if (sourceEvent != null) _requireText(sourceEvent!, 'sourceEvent');
    if (caller != null) _requireText(caller!, 'caller');
    if (sessionRef != null) _requireText(sessionRef!, 'sessionRef');
    if (originKind == null || originKind == MemoryOriginKind.migration) {
      if (sourceEvent != null) {
        throw ArgumentError.value(sourceEvent, 'sourceEvent', 'must be absent without a capture origin');
      }
    } else if (sourceEvent == null) {
      throw ArgumentError.value(sourceEvent, 'sourceEvent', 'must be present for capture origins');
    }
  }

  final MemoryOriginKind? originKind;
  final String sourceLocator;
  final String? sourceEvent;
  final String? caller;
  final String? sessionRef;

  /// Whether every optional replay discriminator is present on both references and equal.
  ///
  /// Deduplication and deletion authorization must use this method, not structural [operator ==].
  bool isExactReplayOf(MemorySourceRef other) =>
      originKind == other.originKind &&
      sourceLocator == other.sourceLocator &&
      sourceEvent != null &&
      sourceEvent == other.sourceEvent &&
      caller != null &&
      caller == other.caller &&
      sessionRef != null &&
      sessionRef == other.sessionRef;

  bool _hasSameFieldsAs(MemorySourceRef other) =>
      originKind == other.originKind &&
      sourceLocator == other.sourceLocator &&
      sourceEvent == other.sourceEvent &&
      caller == other.caller &&
      sessionRef == other.sessionRef;

  @override
  bool operator ==(Object other) => identical(this, other) || other is MemorySourceRef && isExactReplayOf(other);

  @override
  int get hashCode => Object.hash(originKind, sourceLocator, sourceEvent, caller, sessionRef);
}

/// Identifies a canonical collection and its positive mutation revision.
final class MemoryCollectionMetadata {
  new({this.formatVersion = canonicalMemoryFormatVersion, required this.collectionId, required this.revision}) {
    if (formatVersion != canonicalMemoryFormatVersion) {
      throw ArgumentError.value(formatVersion, 'formatVersion', 'unsupported');
    }
    _requireId(collectionId, 'collectionId');
    _requireRevision(revision, 'collectionRevision');
  }

  final int formatVersion;
  final String collectionId;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is MemoryCollectionMetadata &&
      formatVersion == other.formatVersion &&
      collectionId == other.collectionId &&
      revision == other.revision;

  @override
  int get hashCode => Object.hash(formatVersion, collectionId, revision);
}

/// Shared identity, revision, timestamp, and provenance contract for records.
abstract base class CanonicalMemoryRecord {
  new({
    required this.id,
    required this.revision,
    required this.created,
    required this.updated,
    required this.provenance,
  }) {
    _requireId(id, 'id');
    _requireRevision(revision, 'revision');
    _requireUtc(created, 'created');
    _requireUtc(updated, 'updated');
    if (created.isAfter(updated)) throw ArgumentError.value(updated, 'updated', 'must not precede created');
  }

  final String id;
  final int revision;
  final DateTime created;
  final DateTime updated;
  final MemorySourceRef provenance;
  String get locator => id;
}

/// A detailed curated personal-memory entry stored in a topic or archive document.
final class CanonicalMemoryEntry extends CanonicalMemoryRecord {
  new({
    required super.id,
    required super.revision,
    required this.topic,
    required this.summary,
    required this.content,
    required super.created,
    required super.updated,
    required super.provenance,
  }) {
    validateMemoryTopic(topic);
    _requireText(summary, 'summary');
    _requireText(content, 'content');
  }

  final String topic;
  final String summary;
  final String content;

  @override
  bool operator ==(Object other) =>
      other is CanonicalMemoryEntry &&
      id == other.id &&
      revision == other.revision &&
      topic == other.topic &&
      summary == other.summary &&
      content == other.content &&
      created == other.created &&
      updated == other.updated &&
      provenance._hasSameFieldsAs(other.provenance);

  @override
  int get hashCode => Object.hash(id, revision, topic, summary, content, created, updated, provenance);
}

/// A stable runtime-learning entry stored outside personal topic memory.
final class CanonicalMemoryLearning extends CanonicalMemoryRecord {
  new({
    required super.id,
    required super.revision,
    required this.summary,
    required this.content,
    required super.created,
    required super.updated,
    required super.provenance,
  }) {
    _requireText(summary, 'summary');
    _requireText(content, 'content');
  }

  final String summary;
  final String content;

  @override
  bool operator ==(Object other) =>
      other is CanonicalMemoryLearning &&
      id == other.id &&
      revision == other.revision &&
      summary == other.summary &&
      content == other.content &&
      created == other.created &&
      updated == other.updated &&
      provenance._hasSameFieldsAs(other.provenance);

  @override
  int get hashCode => Object.hash(id, revision, summary, content, created, updated, provenance);
}

/// The bounded prompt-index representation of an active curated entry.
final class MemoryIndexEntry {
  new({
    required this.id,
    required this.revision,
    required this.topic,
    required this.summary,
    required this.updated,
    this.priority = 0,
    String? locator,
  }) : locator = locator ?? id {
    _requireId(id, 'id');
    _requireRevision(revision, 'revision');
    validateMemoryTopic(topic);
    _requireText(summary, 'summary');
    _requireUtc(updated, 'updated');
    if (priority < 0) throw ArgumentError.value(priority, 'priority', 'must be non-negative');
    if (this.locator != id) throw ArgumentError.value(this.locator, 'locator', 'must equal entry ID');
  }

  final String id;
  final int revision;
  final String topic;
  final String summary;
  final DateTime updated;
  final int priority;
  final String locator;

  @override
  bool operator ==(Object other) =>
      other is MemoryIndexEntry &&
      id == other.id &&
      revision == other.revision &&
      topic == other.topic &&
      summary == other.summary &&
      updated == other.updated &&
      priority == other.priority &&
      locator == other.locator;

  @override
  int get hashCode => Object.hash(id, revision, topic, summary, updated, priority, locator);
}

/// A provenance-labelled raw observation that is never prompt-authoritative by location.
final class MemoryObservation {
  new({
    required this.id,
    required this.recorded,
    required this.content,
    required this.trustLabel,
    this.isTruncated = false,
    Iterable<String> resultingEntryIds = const [],
    required this.provenance,
  }) : resultingEntryIds = immutableMemoryList(resultingEntryIds) {
    _requireId(id, 'id');
    _requireUtc(recorded, 'recorded');
    _requireText(content, 'content');
    _requireText(trustLabel, 'trustLabel');
    for (final entryId in this.resultingEntryIds) {
      _requireId(entryId, 'resultingEntryId');
    }
  }

  final String id;
  final DateTime recorded;
  final String content;
  final String trustLabel;
  final bool isTruncated;
  final List<String> resultingEntryIds;
  final MemorySourceRef provenance;

  @override
  bool operator ==(Object other) =>
      other is MemoryObservation &&
      id == other.id &&
      recorded == other.recorded &&
      content == other.content &&
      trustLabel == other.trustLabel &&
      isTruncated == other.isTruncated &&
      memoryListsEqual(resultingEntryIds, other.resultingEntryIds) &&
      provenance._hasSameFieldsAs(other.provenance);

  @override
  int get hashCode =>
      Object.hash(id, recorded, content, trustLabel, isTruncated, Object.hashAll(resultingEntryIds), provenance);
}

/// Records a deletion without copying entry content.
///
/// [reason] is stored verbatim and may independently quote that content.
final class MemoryDeletionAudit {
  new({required this.entryId, required this.deletedAt, required this.reason, required this.provenance}) {
    _requireId(entryId, 'entryId');
    _requireUtc(deletedAt, 'deletedAt');
    _requireText(reason, 'reason');
  }

  final String entryId;
  final DateTime deletedAt;
  final String reason;
  final MemorySourceRef provenance;

  @override
  bool operator ==(Object other) =>
      other is MemoryDeletionAudit &&
      entryId == other.entryId &&
      deletedAt == other.deletedAt &&
      reason == other.reason &&
      provenance._hasSameFieldsAs(other.provenance);

  @override
  int get hashCode => Object.hash(entryId, deletedAt, reason, provenance);
}

List<T> immutableMemoryList<T>(Iterable<T> values) => UnmodifiableListView(values.toList());

bool memoryListsEqual<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
