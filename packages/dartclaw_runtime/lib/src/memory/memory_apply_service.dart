import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:uuid/uuid.dart';

/// Maximum accepted character count for a caller-authored merge or removal reason.
const maxMemoryApplyReasonLength = 1024;
final _canonicalUuidPattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// Replaces derived memory-index rows after a canonical commit.
typedef MemoryIndexReconciler = FutureOr<void> Function(
  CanonicalMemoryCorpus corpus,
  Set<String> priorRecordIds,
  int baseRevision,
  String baseFingerprint,
  String userId,
);

/// Atomically applies closed personal-memory change sets through collection CAS.
///
/// Canonical commit and derived-index outcomes are reported separately. Model input
/// cannot select another store or provide audit provenance.
final class MemoryApplyService {
  new({
    required MemoryCorpusService corpus,
    required MemoryIndexReconciler reconcileIndex,
    DateTime Function()? now,
    String Function()? createId,
  }) : _corpus = corpus,
       _reconcileIndex = reconcileIndex,
       _now = now ?? DateTime.now,
       _createId = createId ?? const Uuid().v4;

  final MemoryCorpusService _corpus;
  final MemoryIndexReconciler _reconcileIndex;
  final DateTime Function() _now;
  final String Function() _createId;
  final Map<String, Set<String>> _runScopes = {};

  /// Restricts [apply] calls made from [sessionRef] to entries in [entryIds].
  ///
  /// A host-assembled run that hands a model a bounded snapshot registers that
  /// snapshot's entry IDs here, so the model cannot revise, merge, or remove an
  /// entry it was never shown. Throws [StateError] when [sessionRef] already
  /// has a scope – a stale scope is a different bounded set.
  void registerRunScope(String sessionRef, Set<String> entryIds) {
    if (_runScopes.containsKey(sessionRef)) {
      throw StateError('a run scope is already registered for session $sessionRef');
    }
    _runScopes[sessionRef] = Set.unmodifiable(entryIds);
  }

  /// Drops the run scope registered for [sessionRef]. Idempotent.
  void releaseRunScope(String sessionRef) => _runScopes.remove(sessionRef);

  /// Validates and applies [params] for the host-bound [userId] and [provenance].
  ///
  /// Validation and conflicts return typed rejection results. Canonical persistence
  /// failures are also bounded into rejection facts unless they simulate process death.
  ///
  /// When a run scope is registered for [provenance]'s session, the whole change set
  /// is refused before any mutation if any operation names an entry outside it.
  Future<Map<String, Object?>> apply(
    Map<String, dynamic> params, {
    required String userId,
    required MemorySourceRef provenance,
  }) async {
    final parsed = _parseRequest(params);
    if (parsed.requestError case final error?) {
      return _rejectedResult(parsed.operations, _lastKnownRevision(), error);
    }
    final sessionRef = provenance.sessionRef;
    final scope = sessionRef == null ? null : _runScopes[sessionRef];
    if (scope != null) {
      final outOfScope = _boundedReferenceFailures(parsed.operations, scope);
      if (outOfScope.isNotEmpty) {
        return _outOfScopeResult(parsed.operations, _lastKnownRevision(), outOfScope);
      }
    }

    _PreparedApply? prepared;
    var priorRecordIds = <String>{};
    Object? indexFailure;
    try {
      final baseManifest = await _corpus.manifest();
      final targetIds = parsed.operations.expand((operation) => operation.targets).map((target) => target.id).toSet();
      final selectedPaths = <String>{};
      var needsArchive = false;
      var needsAudit = false;
      for (final operation in parsed.operations) {
        switch (operation) {
          case _AddOperation():
            selectedPaths.add('memory/topics/${operation.topic}.md');
          case _ReviseOperation():
            selectedPaths.add('memory/topics/${operation.topic}.md');
            needsArchive = needsArchive || operation.state == 'archived';
          case _MergeOperation():
            selectedPaths.add('memory/topics/${operation.topic}.md');
            needsArchive = needsArchive || operation.state == 'archived';
            needsAudit = true;
          case _RemoveOperation():
            needsAudit = true;
          case _InvalidOperation():
            break;
        }
      }
      if (needsArchive) selectedPaths.add('MEMORY.archive.md');
      if (needsAudit) selectedPaths.add('MEMORY.audit.md');
      final result = await _corpus.changeSelected<_PreparedApply>(
        expectedRevision: parsed.expectedRevision!,
        include: (_, _) => false,
        recordIds: targetIds,
        paths: selectedPaths,
        prepare: (current) {
          priorRecordIds = _recordIds(current);
          prepared = _prepare(current, parsed.operations, provenance, _now().toUtc());
          return MemoryCorpusChange(value: prepared!, replacement: prepared!.replacement);
        },
        afterCommit: (value, committed) async {
          try {
            await _reconcileIndex(
              committed,
              priorRecordIds,
              baseManifest.collectionRevision,
              baseManifest.fingerprint,
              userId,
            );
          } on Object catch (error) {
            indexFailure = error;
          }
        },
      );
      if (result.wasStale) {
        return _conflictResult(parsed.operations, result.collectionRevision);
      }
      final value = result.value!;
      final records = {
        for (final entry in value.records.entries)
          entry.key: entry.value.withCollectionRevision(result.collectionRevision).toJson(),
      };
      if (!result.wasCommitted) {
        return {
          'canonicalOutcome': value.rejected ? 'rejected' : 'unchanged',
          'indexOutcome': 'notRun',
          'collectionRevision': result.collectionRevision,
          'operations': records,
          if (value.rejected)
            'failure': {
              'kind': 'validation',
              'stage': 'validation',
              'reason': 'change set rejected',
              'currentCollectionRevision': result.collectionRevision,
            },
        };
      }
      final failure = indexFailure;
      return {
        'canonicalOutcome': 'committed',
        'indexOutcome': failure == null ? 'current' : 'degraded',
        'collectionRevision': result.collectionRevision,
        'operations': records,
        if (failure != null)
          'failure': {
            'kind': 'indexReconciliation',
            'stage': 'derivedIndex',
            'reason': _boundedReason(failure),
            'currentCollectionRevision': result.collectionRevision,
          },
      };
    } on MemoryCorpusSimulatedCrash {
      rethrow;
    } on MemoryCorpusValidationException catch (error) {
      return _rejectedResult(parsed.operations, _lastKnownRevision(), _boundedReason(error));
    } on Object catch (error) {
      return _canonicalFailureResult(parsed.operations, _lastKnownRevision(), _boundedReason(error));
    }
  }

  Set<String> _recordIds(CanonicalMemoryCorpus corpus) => {
    for (final document in corpus.topics) ...document.entries.map((entry) => entry.id),
    ...?corpus.archive?.entries.map((entry) => entry.id),
    for (final document in corpus.observations) ...document.observations.map((entry) => entry.id),
    ...?corpus.learnings?.entries.map((entry) => entry.id),
  };

  int? _lastKnownRevision() {
    try {
      return MemoryCorpusService.readPersistedStatus(workspaceDir: _corpus.workspaceDir)?.collectionRevision;
    } on Object {
      return null;
    }
  }

  _PreparedApply _prepare(
    CanonicalMemoryCorpus current,
    List<_ApplyOperation> operations,
    MemorySourceRef provenance,
    DateTime now,
  ) {
    final entries = <String, _LocatedEntry>{};
    for (final topic in current.topics) {
      for (final entry in topic.entries) {
        entries[entry.id] = _LocatedEntry(entry: entry, archived: false);
      }
    }
    for (final entry in current.archive?.entries ?? const <CanonicalMemoryEntry>[]) {
      entries[entry.id] = _LocatedEntry(entry: entry, archived: true);
    }

    final errors = <String, List<String>>{};
    final claimedTargets = <String, String>{};
    void reject(String correlationId, String message) => (errors[correlationId] ??= []).add(message);
    for (final operation in operations) {
      for (final target in operation.targets) {
        final prior = claimedTargets[target.id];
        if (prior != null) {
          reject(operation.correlationId, 'target ${target.id} is also used by operation $prior');
          reject(prior, 'target ${target.id} is also used by operation ${operation.correlationId}');
        } else {
          claimedTargets[target.id] = operation.correlationId;
        }
        final located = entries[target.id];
        if (located == null) {
          reject(operation.correlationId, 'target ${target.id} does not exist in personal memory');
        } else if (located.entry.revision != target.expectedRevision) {
          reject(
            operation.correlationId,
            'target ${target.id} revision is ${located.entry.revision}, expected ${target.expectedRevision}',
          );
        }
      }
    }
    if (errors.isNotEmpty) {
      return _PreparedApply(
        rejected: true,
        records: {
          for (final operation in operations)
            operation.correlationId: _ApplyRecord(
              outcome: 'rejected',
              reason: errors[operation.correlationId]?.join('; ') ?? 'not applied because change set was rejected',
            ),
        },
      );
    }

    final addIds = <String, String>{};
    final claimedAddIds = <String, String>{};
    final retiredIds = {for (final record in current.audit?.records ?? const <MemoryDeletionAudit>[]) record.entryId};
    for (final operation in operations.whereType<_AddOperation>()) {
      final id = _createId();
      addIds[operation.correlationId] = id;
      final prior = claimedAddIds[id];
      if (!_canonicalUuidPattern.hasMatch(id)) {
        reject(operation.correlationId, 'host-generated entry ID is not a canonical lowercase UUID');
      } else if (entries.containsKey(id)) {
        reject(operation.correlationId, 'host-generated entry ID collides with an existing personal-memory entry');
      } else if (retiredIds.contains(id)) {
        reject(
          operation.correlationId,
          'host-generated entry ID collides with a permanently retired personal-memory entry',
        );
      } else if (prior != null) {
        reject(operation.correlationId, 'host-generated entry ID is also used by add operation $prior');
        reject(prior, 'host-generated entry ID is also used by add operation ${operation.correlationId}');
      } else {
        claimedAddIds[id] = operation.correlationId;
      }
    }
    if (errors.isNotEmpty) {
      return _PreparedApply(
        rejected: true,
        records: {
          for (final operation in operations)
            operation.correlationId: _ApplyRecord(
              outcome: 'rejected',
              reason: errors[operation.correlationId]?.join('; ') ?? 'not applied because change set was rejected',
            ),
        },
      );
    }

    final changedEntries = <String, _LocatedEntry>{...entries};
    final audits = [...current.audit?.records ?? const <MemoryDeletionAudit>[]];
    final records = <String, _ApplyRecord>{};
    for (final operation in operations) {
      switch (operation) {
        case _InvalidOperation():
          throw StateError('invalid operations must be rejected before preparation');
        case _AddOperation():
          final id = addIds[operation.correlationId]!;
          final entry = CanonicalMemoryEntry(
            id: id,
            revision: 1,
            topic: operation.topic,
            summary: _summary(operation.content),
            content: operation.content.trim(),
            created: now,
            updated: now,
            provenance: provenance,
          );
          changedEntries[id] = _LocatedEntry(entry: entry, archived: false);
          records[operation.correlationId] = _ApplyRecord(outcome: 'changed', entryId: id);
        case _ReviseOperation():
          final prior = entries[operation.target.id]!;
          final content = operation.content.trim();
          final archived = operation.state == 'archived';
          final isNoOp =
              prior.entry.topic == operation.topic &&
              prior.entry.content == content &&
              prior.entry.summary == _summary(content) &&
              prior.archived == archived;
          if (isNoOp) {
            records[operation.correlationId] = _ApplyRecord(outcome: 'exactNoOp', entryId: prior.entry.id);
            continue;
          }
          changedEntries[prior.entry.id] = _LocatedEntry(
            archived: archived,
            entry: CanonicalMemoryEntry(
              id: prior.entry.id,
              revision: prior.entry.revision + 1,
              topic: operation.topic,
              summary: _summary(content),
              content: content,
              created: prior.entry.created,
              updated: now,
              provenance: provenance,
            ),
          );
          records[operation.correlationId] = _ApplyRecord(outcome: 'changed', entryId: prior.entry.id);
        case _MergeOperation():
          final prior = entries[operation.target.id]!;
          changedEntries[prior.entry.id] = _LocatedEntry(
            archived: operation.state == 'archived',
            entry: CanonicalMemoryEntry(
              id: prior.entry.id,
              revision: prior.entry.revision + 1,
              topic: operation.topic,
              summary: _summary(operation.content),
              content: operation.content.trim(),
              created: prior.entry.created,
              updated: now,
              provenance: provenance,
            ),
          );
          for (final source in operation.sources) {
            changedEntries.remove(source.id);
            audits.add(
              MemoryDeletionAudit(entryId: source.id, deletedAt: now, reason: operation.reason, provenance: provenance),
            );
          }
          records[operation.correlationId] = _ApplyRecord(outcome: 'changed', entryId: prior.entry.id);
        case _RemoveOperation():
          changedEntries.remove(operation.target.id);
          audits.add(
            MemoryDeletionAudit(
              entryId: operation.target.id,
              deletedAt: now,
              reason: operation.reason,
              provenance: provenance,
            ),
          );
          records[operation.correlationId] = _ApplyRecord(outcome: 'changed', entryId: operation.target.id);
      }
    }
    if (records.values.every((record) => record.outcome == 'exactNoOp')) {
      return _PreparedApply(rejected: false, records: records);
    }

    final selectedOriginalIds = entries.keys.toSet();
    final byTopic = <String, List<CanonicalMemoryEntry>>{};
    final archived = <CanonicalMemoryEntry>[];
    for (final located in changedEntries.values) {
      if (located.archived) {
        archived.add(located.entry);
      } else {
        (byTopic[located.entry.topic] ??= []).add(located.entry);
      }
    }
    final topics = [for (final entry in byTopic.entries) MemoryTopicDocument(topic: entry.key, entries: entry.value)];
    final active = byTopic.values.expand((entries) => entries);
    final priorityById = {for (final entry in current.index.entries) entry.id: entry.priority};
    final replacement = CanonicalMemoryCorpus(
      index: MemoryIndexDocument(
        metadata: current.index.metadata,
        entries: [
          ...current.index.entries.where((entry) => !selectedOriginalIds.contains(entry.id)),
          for (final entry in active)
            MemoryIndexEntry(
              id: entry.id,
              revision: entry.revision,
              topic: entry.topic,
              summary: entry.summary,
              updated: entry.updated,
              priority: priorityById[entry.id] ?? 0,
            ),
        ],
      ),
      topics: topics,
      archive: archived.isEmpty ? null : MemoryArchiveDocument(entries: archived),
      observations: current.observations,
      learnings: current.learnings,
      errors: current.errors,
      audit: audits.isEmpty ? null : MemoryAuditDocument(records: audits),
      verbatimMembers: current.verbatimMembers,
    );
    return _PreparedApply(rejected: false, records: records, replacement: replacement);
  }
}

final class _ParsedRequest {
  const new({required this.expectedRevision, required this.operations, this.requestError});

  final int? expectedRevision;
  final List<_ApplyOperation> operations;
  final String? requestError;
}

_ParsedRequest _parseRequest(Map<String, dynamic> params) {
  final topUnknown = params.keys.where((key) => !const {'expectedRevision', 'operations'}.contains(key)).toList();
  final revision = params['expectedRevision'];
  final rawOperations = params['operations'];
  final operations = <_ApplyOperation>[];
  final errors = <String>[];
  if (topUnknown.isNotEmpty) errors.add('unsupported request fields: ${topUnknown.join(', ')}');
  if (revision is! int || revision < 1) errors.add('expectedRevision must be a positive integer');
  if (rawOperations is! List || rawOperations.isEmpty) {
    errors.add('operations must be a nonempty array');
  } else {
    final correlations = <String>{};
    for (var index = 0; index < rawOperations.length; index++) {
      final raw = rawOperations[index];
      try {
        if (raw is! Map) throw ArgumentError('operation must be an object');
        final map = raw.map((key, value) => MapEntry(key.toString(), value));
        final operation = _parseOperation(map);
        if (!correlations.add(operation.correlationId)) {
          throw ArgumentError('duplicate correlationId ${operation.correlationId}');
        }
        operations.add(operation);
      } on Object catch (error) {
        final reason = _boundedReason(error);
        final suppliedCorrelation = raw is Map ? raw['correlationId'] : null;
        var correlationId = suppliedCorrelation is String && suppliedCorrelation.trim().isNotEmpty
            ? suppliedCorrelation
            : 'operation[$index]';
        if (!correlations.add(correlationId)) {
          correlationId = 'operation[$index]';
          var suffix = 1;
          while (!correlations.add(correlationId)) {
            correlationId = 'operation[$index]#${suffix++}';
          }
        }
        operations.add(_InvalidOperation(correlationId: correlationId, reason: reason));
        errors.add('operation[$index]: $reason');
      }
    }
  }
  return _ParsedRequest(
    expectedRevision: revision is int && revision > 0 ? revision : null,
    operations: operations,
    requestError: errors.isEmpty ? null : errors.join('; '),
  );
}

_ApplyOperation _parseOperation(Map<String, dynamic> raw) {
  final kind = _requiredString(raw, 'kind');
  final correlationId = _requiredString(raw, 'correlationId');
  if (correlationId.trim().isEmpty) throw ArgumentError('correlationId must not be blank');
  switch (kind) {
    case 'add':
      _requireOnlyKeys(raw, const {'kind', 'correlationId', 'topic', 'content'});
      return _AddOperation(correlationId: correlationId, topic: _topic(raw), content: _content(raw));
    case 'revise':
      _requireOnlyKeys(raw, const {
        'kind',
        'correlationId',
        'targetId',
        'expectedEntryRevision',
        'topic',
        'content',
        'state',
      });
      return _ReviseOperation(
        correlationId: correlationId,
        target: _target(raw, 'targetId', 'expectedEntryRevision'),
        topic: _topic(raw),
        content: _content(raw),
        state: _state(raw),
      );
    case 'merge':
      _requireOnlyKeys(raw, const {
        'kind',
        'correlationId',
        'targetId',
        'expectedEntryRevision',
        'sources',
        'topic',
        'content',
        'state',
        'reason',
      });
      final sourceValues = raw['sources'];
      if (sourceValues is! List || sourceValues.isEmpty) throw ArgumentError('sources must be a nonempty array');
      final sources = <_Target>[];
      for (final value in sourceValues) {
        if (value is! Map) throw ArgumentError('each source must be an object');
        final map = value.map((key, value) => MapEntry(key.toString(), value));
        _requireOnlyKeys(map, const {'id', 'expectedEntryRevision'});
        sources.add(_target(map, 'id', 'expectedEntryRevision'));
      }
      final target = _target(raw, 'targetId', 'expectedEntryRevision');
      if (sources.any((source) => source.id == target.id) ||
          sources.map((source) => source.id).toSet().length != sources.length) {
        throw ArgumentError('merge target and sources must be distinct');
      }
      return _MergeOperation(
        correlationId: correlationId,
        target: target,
        sources: sources,
        topic: _topic(raw),
        content: _content(raw),
        state: _state(raw),
        reason: _reason(raw),
      );
    case 'remove':
      _requireOnlyKeys(raw, const {'kind', 'correlationId', 'targetId', 'expectedEntryRevision', 'reason'});
      return _RemoveOperation(
        correlationId: correlationId,
        target: _target(raw, 'targetId', 'expectedEntryRevision'),
        reason: _reason(raw),
      );
    default:
      throw ArgumentError('unsupported operation kind: $kind');
  }
}

sealed class _ApplyOperation {
  const new(this.correlationId);

  final String correlationId;
  Iterable<_Target> get targets;
  String? get parseError => null;
}

final class _InvalidOperation extends _ApplyOperation {
  const new({required String correlationId, required this.reason}) : super(correlationId);

  final String reason;
  @override
  Iterable<_Target> get targets => const [];
  @override
  String get parseError => reason;
}

final class _AddOperation extends _ApplyOperation {
  const new({required String correlationId, required this.topic, required this.content}) : super(correlationId);

  final String topic;
  final String content;
  @override
  Iterable<_Target> get targets => const [];
}

final class _ReviseOperation extends _ApplyOperation {
  const new({
    required String correlationId,
    required this.target,
    required this.topic,
    required this.content,
    required this.state,
  }) : super(correlationId);

  final _Target target;
  final String topic;
  final String content;
  final String state;
  @override
  Iterable<_Target> get targets => [target];
}

final class _MergeOperation extends _ApplyOperation {
  const new({
    required String correlationId,
    required this.target,
    required this.sources,
    required this.topic,
    required this.content,
    required this.state,
    required this.reason,
  }) : super(correlationId);

  final _Target target;
  final List<_Target> sources;
  final String topic;
  final String content;
  final String state;
  final String reason;
  @override
  Iterable<_Target> get targets => [target, ...sources];
}

final class _RemoveOperation extends _ApplyOperation {
  const new({required String correlationId, required this.target, required this.reason}) : super(correlationId);

  final _Target target;
  final String reason;
  @override
  Iterable<_Target> get targets => [target];
}

final class _Target {
  const new(this.id, this.expectedRevision);

  final String id;
  final int expectedRevision;
}

final class _LocatedEntry {
  const new({required this.entry, required this.archived});

  final CanonicalMemoryEntry entry;
  final bool archived;
}

final class _PreparedApply {
  const new({required this.rejected, required this.records, this.replacement});

  final bool rejected;
  final Map<String, _ApplyRecord> records;
  final CanonicalMemoryCorpus? replacement;
}

final class _ApplyRecord {
  const new({required this.outcome, this.entryId, this.reason, this.collectionRevision});

  final String outcome;
  final String? entryId;
  final String? reason;
  final int? collectionRevision;

  _ApplyRecord withCollectionRevision(int revision) =>
      _ApplyRecord(outcome: outcome, entryId: entryId, reason: reason, collectionRevision: revision);

  Map<String, Object?> toJson() => {
    'outcome': outcome,
    if (entryId != null) 'entryId': entryId,
    'collectionRevision': collectionRevision,
    if (reason != null) 'reason': reason,
  };
}

/// Reasons, by correlation ID, for every operation reaching outside [includedIds].
///
/// Only operations that name an existing entry are constrained; an add operation
/// takes a host-generated ID and has nothing to fall outside the snapshot.
Map<String, String> _boundedReferenceFailures(List<_ApplyOperation> operations, Set<String> includedIds) {
  final reasons = <String, String>{};
  for (final operation in operations) {
    final failures = <String>[];
    final target = switch (operation) {
      _ReviseOperation(:final target) => target,
      _MergeOperation(:final target) => target,
      _RemoveOperation(:final target) => target,
      // Exhaustive on purpose: a new referencing kind must not be exempted by a wildcard.
      _AddOperation() => null,
      _InvalidOperation() => null,
    };
    if (target != null && !includedIds.contains(target.id)) {
      failures.add('targetId was not included in the bounded snapshot');
    }
    if (operation case _MergeOperation(:final sources)) {
      for (final source in sources) {
        if (!includedIds.contains(source.id)) {
          failures.add('source ${source.id} was not included in the bounded snapshot');
        }
      }
    }
    if (failures.isNotEmpty) reasons[operation.correlationId] = failures.join('; ');
  }
  return reasons;
}

Map<String, Object?> _outOfScopeResult(
  List<_ApplyOperation> operations,
  int? revision,
  Map<String, String> outOfScope,
) => {
  'canonicalOutcome': 'rejected',
  'indexOutcome': 'notRun',
  'collectionRevision': revision,
  'operations': {
    for (final operation in operations)
      operation.correlationId: _ApplyRecord(
        outcome: 'rejected',
        reason: outOfScope[operation.correlationId] ?? 'not applied because the proposal was rejected',
        collectionRevision: revision,
      ).toJson(),
  },
  'failure': {
    'kind': 'validation',
    'stage': 'validation',
    'reason': 'change set references entries outside the run\'s bounded snapshot',
    'currentCollectionRevision': revision,
  },
};

Map<String, Object?> _conflictResult(List<_ApplyOperation> operations, int revision) => {
  'canonicalOutcome': 'conflict',
  'indexOutcome': 'notRun',
  'collectionRevision': revision,
  'operations': {
    for (final operation in operations)
      operation.correlationId: _ApplyRecord(
        outcome: 'rejected',
        reason: 'collection revision is stale',
        collectionRevision: revision,
      ).toJson(),
  },
  'failure': {
    'kind': 'conflict',
    'stage': 'collectionRevision',
    'reason': 'expected collection revision is stale',
    'currentCollectionRevision': revision,
  },
};

Map<String, Object?> _rejectedResult(List<_ApplyOperation> operations, int? revision, String reason) => {
  'canonicalOutcome': 'rejected',
  'indexOutcome': 'notRun',
  'collectionRevision': revision,
  'operations': {
    for (final operation in operations)
      operation.correlationId: _ApplyRecord(
        outcome: 'rejected',
        reason: operation.parseError ?? 'not applied because change set was rejected: $reason',
        collectionRevision: revision,
      ).toJson(),
  },
  'failure': {'kind': 'validation', 'stage': 'validation', 'reason': reason, 'currentCollectionRevision': revision},
};

Map<String, Object?> _canonicalFailureResult(List<_ApplyOperation> operations, int? revision, String reason) => {
  'canonicalOutcome': 'rejected',
  'indexOutcome': 'notRun',
  'collectionRevision': revision,
  'operations': {
    for (final operation in operations)
      operation.correlationId: _ApplyRecord(
        outcome: 'rejected',
        reason: 'not applied because the canonical commit failed',
        collectionRevision: revision,
      ).toJson(),
  },
  'failure': {
    'kind': 'canonicalCommit',
    'stage': 'canonicalCommit',
    'reason': reason,
    'currentCollectionRevision': revision,
  },
};

_Target _target(Map<String, dynamic> raw, String idKey, String revisionKey) {
  final id = _requiredString(raw, idKey);
  if (!_canonicalUuidPattern.hasMatch(id)) {
    throw ArgumentError('$idKey must be a canonical lowercase UUID');
  }
  final revision = raw[revisionKey];
  if (revision is! int || revision < 1) throw ArgumentError('$revisionKey must be a positive integer');
  return _Target(id, revision);
}

String _topic(Map<String, dynamic> raw) {
  final value = _requiredString(raw, 'topic');
  validateMemoryTopic(value);
  return value;
}

String _content(Map<String, dynamic> raw) {
  final value = _requiredString(raw, 'content');
  if (value.trim().isEmpty) throw ArgumentError('content must not be blank');
  return value;
}

String _state(Map<String, dynamic> raw) {
  final value = _requiredString(raw, 'state');
  if (value != 'active' && value != 'archived') throw ArgumentError('state must be active or archived');
  return value;
}

String _reason(Map<String, dynamic> raw) {
  final value = _requiredString(raw, 'reason');
  if (value.trim().isEmpty) throw ArgumentError('reason must not be blank');
  if (value.runes.length > maxMemoryApplyReasonLength) {
    throw ArgumentError('reason must not exceed $maxMemoryApplyReasonLength characters');
  }
  return value;
}

String _requiredString(Map<String, dynamic> raw, String key) {
  final value = raw[key];
  if (value is! String) throw ArgumentError('$key must be a string');
  return value;
}

void _requireOnlyKeys(Map<String, dynamic> raw, Set<String> allowed) {
  final unknown = raw.keys.where((key) => !allowed.contains(key)).toList(growable: false);
  if (unknown.isNotEmpty) throw ArgumentError('unsupported fields: ${unknown.join(', ')}');
}

String _summary(String content) => content.trim().split('\n').first;

String _boundedReason(Object error) {
  final value = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return value.length <= 256 ? value : '${value.substring(0, 253)}...';
}
