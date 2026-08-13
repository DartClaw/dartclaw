import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../concurrency/repo_lock.dart';
import '../storage/atomic_write.dart';
import '../storage/write_op.dart';
import 'canonical_memory.dart';
import 'memory_corpus.dart';
import 'memory_documents.dart';
import 'memory_markdown_codec.dart';
import 'memory_resource_limits.dart';

part 'memory_corpus_manifest.dart';
part 'memory_corpus_authority.dart';
part 'memory_corpus_scanner.dart';

enum MemorySnapshotOmissionReason { documentLimit, aggregateByteLimit }

final class MemorySnapshotOmission {
  const new({required this.path, required this.reason});
  final String path;
  final MemorySnapshotOmissionReason reason;
}

final class MemoryCorpusSnapshot {
  new({
    required this.collectionRevision,
    required this.fingerprint,
    required Map<String, Uint8List> documents,
    required Iterable<MemorySnapshotOmission> omissions,
    required Iterable<MemoryCorpusExternalChange> externalChanges,
    Iterable<String> prefixDocuments = const [],
  }) : documents = Map.unmodifiable({
         for (final entry in documents.entries) entry.key: Uint8List.fromList(entry.value),
       }),
       omissions = List.unmodifiable(omissions),
       externalChanges = List.unmodifiable(externalChanges),
       prefixDocuments = Set.unmodifiable(prefixDocuments);
  final int collectionRevision;
  final String fingerprint;
  final Map<String, Uint8List> documents;
  final List<MemorySnapshotOmission> omissions;
  final List<MemoryCorpusExternalChange> externalChanges;
  final Set<String> prefixDocuments;
}

final class MemoryCorpusStatusSnapshot {
  new({
    required this.collectionRevision,
    required this.collectionFingerprint,
    required this.curatedEntryCount,
    required this.topicCount,
    required this.archiveEntryCount,
    required this.observationEntryCount,
    required this.learningEntryCount,
    required this.observationUsageBytes,
    required this.observationOldest,
    required this.observationNewest,
    required Iterable<String> opaqueLegacyLocators,
    required this.migrationState,
    this.migrationSnapshotPath,
    this.migrationAction,
  }) : opaqueLegacyLocators = List.unmodifiable(opaqueLegacyLocators);
  final int collectionRevision;
  final String collectionFingerprint;
  final int? curatedEntryCount, topicCount, archiveEntryCount;
  final int? observationEntryCount, learningEntryCount, observationUsageBytes;
  final DateTime? observationOldest, observationNewest;
  final List<String> opaqueLegacyLocators;
  final String migrationState;
  final String? migrationSnapshotPath, migrationAction;
  Map<String, Object?> toJson() => {
    'collectionRevision': collectionRevision,
    'collectionFingerprint': collectionFingerprint,
    'curatedEntryCount': curatedEntryCount,
    'topicCount': topicCount,
    'archiveEntryCount': archiveEntryCount,
    'observationEntryCount': observationEntryCount,
    'learningEntryCount': learningEntryCount,
    'observationUsageBytes': observationUsageBytes,
    'observationOldest': observationOldest?.toUtc().toIso8601String(),
    'observationNewest': observationNewest?.toUtc().toIso8601String(),
    'opaqueLegacyLocators': opaqueLegacyLocators,
    'migrationState': migrationState,
    'migrationSnapshotPath': migrationSnapshotPath,
    'migrationAction': migrationAction,
  };
}

final class MemoryCurationSnapshot {
  const new({
    required this.collectionRevision,
    required this.index,
    required this.entries,
    required this.observations,
    required this.entriesTruncated,
    required this.observationsTruncated,
  });
  final int collectionRevision;
  final MemoryIndexDocument index;
  final List<CanonicalMemoryEntry> entries;
  final List<MemoryObservation> observations;
  final bool entriesTruncated, observationsTruncated;
}

final class MemoryCorpusExternalChange {
  const new({required this.role, required this.locator, required this.wasRemoved});
  final MemoryRole? role;
  final String locator;
  final bool wasRemoved;
}

final class MemoryCorpusCommitResult {
  const new _({required this.wasCommitted, required this.collectionRevision, required this.fingerprint});
  const new committed({required int collectionRevision, required String fingerprint})
    : this._(wasCommitted: true, collectionRevision: collectionRevision, fingerprint: fingerprint);
  const new stale({required int collectionRevision, required String fingerprint})
    : this._(wasCommitted: false, collectionRevision: collectionRevision, fingerprint: fingerprint);
  final bool wasCommitted;
  final int collectionRevision;
  final String fingerprint;
}

final class MemoryCorpusProjection {
  new({
    required this.corpus,
    required Iterable<String> priorRecordIds,
    required this.isComplete,
    required this.baseRevision,
    required this.baseFingerprint,
  }) : priorRecordIds = Set.unmodifiable(priorRecordIds);

  final CanonicalMemoryCorpus corpus;
  final Set<String> priorRecordIds;
  final bool isComplete;
  final int baseRevision;
  final String baseFingerprint;
}

typedef MemoryCorpusPostCommitProjection = FutureOr<void> Function(MemoryCorpusProjection, MemoryCorpusCommitResult);

final class MemoryCorpusSelection {
  const new({required this.collectionRevision, required this.fingerprint, required this.corpus, required this.paths});
  final int collectionRevision;
  final String fingerprint;
  final CanonicalMemoryCorpus corpus;
  final Set<String> paths;
}

final class MemoryCorpusManifest {
  const new({required this.collectionRevision, required this.fingerprint, required this.paths, required this.status});
  final int collectionRevision;
  final String fingerprint;
  final List<String> paths;
  final MemoryCorpusStatusSnapshot status;
}

final class MemoryCorpusChange<T> {
  const new({required this.value, this.replacement});
  final T value;
  final CanonicalMemoryCorpus? replacement;
}

final class MemoryCorpusChangeResult<T> {
  const new({
    required this.wasStale,
    required this.wasCommitted,
    required this.collectionRevision,
    required this.fingerprint,
    this.value,
  });
  final bool wasStale, wasCommitted;
  final int collectionRevision;
  final String fingerprint;
  final T? value;
}

final class MemoryCorpusFileMutation<T> {
  new({required this.value, required Map<String, List<int>?> writes})
    : writes = Map.unmodifiable({
        for (final entry in writes.entries) entry.key: entry.value == null ? null : Uint8List.fromList(entry.value!),
      });
  final T value;
  final Map<String, Uint8List?> writes;
}

final class MemoryCorpusMutation<T> {
  const new({required this.value, required this.corpus});
  final T value;
  final CanonicalMemoryCorpus corpus;
}

enum MemoryCorpusTransition {
  stageWritten,
  backupWritten,
  targetReplaced,
  beforeCommitMarker,
  commitMarkerReplaced,
  fingerprintRecorded,
  beforeCleanup,
}

typedef MemoryCorpusTransitionHook = FutureOr<void> Function(MemoryCorpusTransition transition, String path);

final class MemoryCorpusSimulatedCrash implements Exception {
  const new(this.transition);
  final MemoryCorpusTransition transition;
}

final class MemoryCorpusPostCommitException implements Exception {
  const new({required this.result, required this.cause});
  final MemoryCorpusCommitResult result;
  final Object cause;
}

final class MemoryCorpusRecoveryRequired implements Exception {
  const new(this.message);
  final String message;

  @override
  String toString() => message;
}

final class MemoryCorpusService {
  new({
    required this.workspaceDir,
    MemoryCorpusTransitionHook? transitionHook,
    void Function(String path)? readObserver,
    void Function(File target, List<int> bytes)? legacyWriteForTesting,
  }) : _transitionHook = transitionHook,
       _readObserver = readObserver,
       _legacyWriteForTesting = legacyWriteForTesting;
  static const maxCorpusFiles = MemoryResourceLimits.recursiveFiles;
  static const maxCorpusBytes = MemoryResourceLimits.recursiveBodyBytes;
  static const _stateName = '.dartclaw-memory-corpus.json';
  static const _journalName = '.dartclaw-memory-transaction.json';
  static const _transactionDirName = '.dartclaw-memory-transaction';
  static final _lock = RepoLock();
  static final _publishedStates = <String, _CorpusState>{};
  static const _codec = MemoryMarkdownCodec();
  static const _validator = MemoryCorpusValidator();
  final String workspaceDir;
  final MemoryCorpusTransitionHook? _transitionHook;
  final void Function(String path)? _readObserver;
  final void Function(File target, List<int> bytes)? _legacyWriteForTesting;
  MemoryCorpusPostCommitProjection? _postCommitProjection;
  final _queue = BoundedWriteQueue();
  String? _root;
  bool _manifestAuthenticated = false;
  _CorpusState? _authenticatedState;

  void registerPostCommitProjection(MemoryCorpusPostCommitProjection projection) {
    if (_postCommitProjection != null) throw StateError('A memory corpus post-commit projection is already registered');
    _postCommitProjection = projection;
  }

  bool get hasPostCommitProjection => _postCommitProjection != null;

  Future<CanonicalMemoryCorpus> readCorpus() => selectDocuments(include: (_, _) => true).then((value) => value.corpus);

  Future<MemoryCorpusSelection> selectDocuments({required bool Function(MemoryRole? role, String path) include}) =>
      _lock.acquire(_lockKey, () async {
        final prepared = await _prepareManifestLocked();
        final paths = prepared.state.members.keys.where(
          (path) => path == 'MEMORY.md' || include(_roleForPath(path), path),
        );
        return _readSelectionLocked(prepared, paths);
      });

  Future<MemoryCorpusSelection> selectPaths(Iterable<String> paths) => _lock.acquire(_lockKey, () async {
    final prepared = await _prepareManifestLocked();
    return _readSelectionLocked(prepared, ['MEMORY.md', ...paths]);
  });

  Future<MemoryCorpusSelection?> selectRecord(String recordId, {MemoryRole? role}) => _lock.acquire(_lockKey, () async {
    final prepared = await _prepareManifestLocked();
    String? sourcePath;
    for (final entry in prepared.state.members.entries) {
      if (entry.key == 'MEMORY.md') continue;
      if (role != null && _roleForPath(entry.key) != role) continue;
      if (entry.value.recordIds.contains(recordId)) {
        sourcePath = entry.key;
        break;
      }
    }
    if (sourcePath == null) return null;
    return _readSelectionLocked(prepared, ['MEMORY.md', sourcePath]);
  });

  Future<MemoryCorpusManifest> manifest() => _lock.acquire(_lockKey, () async {
    final prepared = await _prepareManifestLocked();
    final status = prepared.state.status;
    if (status == null) throw const MemoryCorpusRecoveryRequired('canonical status manifest is missing');
    return MemoryCorpusManifest(
      collectionRevision: prepared.state.revision,
      fingerprint: prepared.state.fingerprint,
      paths: List.unmodifiable(prepared.state.members.keys.toList()..sort()),
      status: status,
    );
  });

  Future<void> authenticate(MemoryCorpusManifest expected) => _lock.acquire(_lockKey, () async {
    final root = _resolveRoot(create: true);
    await _recoverLocked(root);
    final state = _readState(File(p.join(root, _stateName)));
    final scanned = await _scanCorpusState(root);
    if (state == null ||
        !state.hasCompleteManifest ||
        state.revision != expected.collectionRevision ||
        state.fingerprint != expected.fingerprint ||
        scanned.revision != expected.collectionRevision ||
        scanned.fingerprint != expected.fingerprint ||
        _readIndexRevisionPrefix(File(p.join(root, 'MEMORY.md'))) != state.revision) {
      throw const MemoryCorpusRecoveryRequired('canonical corpus changed during reconciliation');
    }
    _requireManifestMetadataMatch(state, scanned);
    _authenticatedState = scanned;
    _manifestAuthenticated = true;
  });

  Future<MemoryCorpusStatusSnapshot> statusSnapshot() async => (await manifest()).status;

  static MemoryCorpusStatusSnapshot? readPersistedStatus({required String workspaceDir}) {
    final file = File(p.join(workspaceDir, _stateName));
    return _readState(file)?.status;
  }

  Future<MemoryCurationSnapshot> curationSnapshot({
    required int maxIndexBytes,
    int maxEntries = 50,
    int maxEntryBytes = 64 * 1024,
    int maxObservations = 50,
    int maxObservationBytes = 64 * 1024,
    DateTime? observationsAfter,
  }) {
    for (final value in [maxIndexBytes, maxEntries, maxEntryBytes, maxObservations, maxObservationBytes]) {
      if (value < 1) throw ArgumentError.value(value, 'snapshot limit', 'must be positive');
    }
    return _lock.acquire(_lockKey, () async {
      final prepared = await _prepareManifestLocked();
      final state = prepared.state;
      final indexPath = p.join(prepared.root, 'MEMORY.md');
      final indexFile = File(indexPath);
      final indexMember = state.members['MEMORY.md']!;
      final indexHandle = indexFile.openSync();
      late final Uint8List indexBytes;
      try {
        indexBytes = indexHandle.readSync(maxIndexBytes);
      } finally {
        indexHandle.closeSync();
      }
      if (indexFile.lengthSync() != indexMember.length || _fingerprintFile(indexFile) != indexMember.fingerprint) {
        throw const MemoryCorpusRecoveryRequired('MEMORY.md changed after manifest authentication');
      }
      final index = _parseBoundedIndex(indexBytes, state.revision);
      final wantedIds = index.entries.take(maxEntries).map((entry) => entry.id).toSet();
      final topicsInOrder = <String>[];
      final seenTopics = <String>{};
      for (final row in index.entries.take(maxEntries)) {
        if (seenTopics.add(row.topic)) topicsInOrder.add(row.topic);
      }
      final entriesById = <String, CanonicalMemoryEntry>{};
      var entrySourceBytes = 0;
      var entriesTruncated = indexFile.lengthSync() > maxIndexBytes;
      for (final topic in topicsInOrder) {
        final path = 'memory/topics/$topic.md';
        if (!state.members.containsKey(path)) continue;
        final file = File(p.join(prepared.root, path));
        final length = file.lengthSync();
        final member = state.members[path]!;
        if (length != member.length) throw MemoryCorpusRecoveryRequired('$path changed after manifest authentication');
        if (entrySourceBytes + length > maxEntryBytes) {
          entriesTruncated = true;
          continue;
        }
        final body = _readAuthenticatedMember(prepared.root, state.members, path);
        final document = _codec.parse(utf8.decode(body));
        if (document is! MemoryTopicDocument || document.topic != topic) {
          throw MemoryCorpusRecoveryRequired('$path has the wrong role or topic');
        }
        entrySourceBytes += length;
        for (final entry in document.entries) {
          if (wantedIds.contains(entry.id)) entriesById[entry.id] = entry;
        }
      }
      final entries = <CanonicalMemoryEntry>[];
      var entryBytes = 0;
      for (final row in index.entries.take(maxEntries)) {
        final entry = entriesById[row.id];
        if (entry == null) {
          entriesTruncated = true;
          continue;
        }
        final cost = utf8.encode(jsonEncode(_curationEntryJson(entry))).length;
        if (entries.length >= maxEntries || entryBytes + cost > maxEntryBytes) {
          entriesTruncated = true;
          break;
        }
        entries.add(entry);
        entryBytes += cost;
      }
      if (index.entries.length > maxEntries) entriesTruncated = true;
      final observationPaths = state.members.keys.where(_isObservationPath).toList()
        ..sort((left, right) => right.compareTo(left));
      final observations = <MemoryObservation>[];
      var observationSourceBytes = 0;
      var observationsTruncated = false;
      for (final path in observationPaths) {
        final date = path.substring('memory/'.length, path.length - '.md'.length);
        if (observationsAfter != null && date.compareTo(observationsAfter.toIso8601String().substring(0, 10)) < 0) {
          break;
        }
        if (observations.length >= maxObservations) {
          observationsTruncated = true;
          break;
        }
        final file = File(p.join(prepared.root, path));
        final length = file.lengthSync();
        final member = state.members[path]!;
        if (length != member.length) throw MemoryCorpusRecoveryRequired('$path changed after manifest authentication');
        if (observationSourceBytes + length > maxObservationBytes) {
          observationsTruncated = true;
          continue;
        }
        final body = _readAuthenticatedMember(prepared.root, state.members, path);
        final document = _codec.parse(utf8.decode(body));
        if (document is! MemoryObservationDocument || document.date != date) {
          throw MemoryCorpusRecoveryRequired('$path has the wrong role or date');
        }
        observationSourceBytes += length;
        observations.addAll(
          document.observations.where(
            (observation) => observationsAfter == null || observation.recorded.isAfter(observationsAfter),
          ),
        );
      }
      observations.sort((left, right) {
        final byRecorded = right.recorded.compareTo(left.recorded);
        return byRecorded != 0 ? byRecorded : left.id.compareTo(right.id);
      });
      var observationBytes = 0;
      final boundedObservations = <MemoryObservation>[];
      for (final observation in observations) {
        final cost = utf8.encode(jsonEncode(_curationObservationJson(observation))).length;
        if (boundedObservations.length >= maxObservations || observationBytes + cost > maxObservationBytes) {
          observationsTruncated = true;
          break;
        }
        boundedObservations.add(observation);
        observationBytes += cost;
      }
      return MemoryCurationSnapshot(
        collectionRevision: state.revision,
        index: index,
        entries: List.unmodifiable(entries),
        observations: List.unmodifiable(boundedObservations),
        entriesTruncated: entriesTruncated,
        observationsTruncated: observationsTruncated,
      );
    });
  }

  Future<MemoryCorpusSnapshot> snapshot({
    required Iterable<String> paths,
    required int maxDocuments,
    required int maxBytes,
    bool allowIndexPrefix = false,
  }) {
    if (maxDocuments < 1) throw ArgumentError.value(maxDocuments, 'maxDocuments', 'must be positive');
    if (maxBytes < 1) throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
    return _lock.acquire(_lockKey, () async {
      final prepared = await _prepareManifestLocked();
      final state = prepared.state;
      final documents = <String, Uint8List>{};
      final omissions = <MemorySnapshotOmission>[];
      final seen = <String>{};
      final prefixDocuments = <String>{};
      var bytes = 0;
      for (final relativePath in paths) {
        final normalized = _normalizeMemberPath(relativePath);
        if (!seen.add(normalized) || !state.members.containsKey(normalized)) continue;
        final file = File(p.join(prepared.root, normalized));
        final type = FileSystemEntity.typeSync(file.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        if (type != FileSystemEntityType.file) throw FileSystemException('Unexpected corpus entity', file.path);
        if (documents.length >= maxDocuments) {
          omissions.add(MemorySnapshotOmission(path: normalized, reason: MemorySnapshotOmissionReason.documentLimit));
          continue;
        }
        final length = file.lengthSync();
        if (bytes + length > maxBytes) {
          if (allowIndexPrefix && normalized == 'MEMORY.md' && bytes < maxBytes) {
            final handle = file.openSync();
            try {
              documents[normalized] = handle.readSync(maxBytes - bytes);
            } finally {
              handle.closeSync();
            }
            prefixDocuments.add(normalized);
            bytes = maxBytes;
            final member = state.members[normalized]!;
            if (file.lengthSync() != member.length || _fingerprintFile(file) != member.fingerprint) {
              throw MemoryCorpusRecoveryRequired('$normalized changed after manifest authentication');
            }
            continue;
          }
          omissions.add(
            MemorySnapshotOmission(path: normalized, reason: MemorySnapshotOmissionReason.aggregateByteLimit),
          );
          continue;
        }
        final value = _readAuthenticatedMember(prepared.root, state.members, normalized);
        if (normalized == 'MEMORY.md') {
          final index = _codec.parse(utf8.decode(value));
          if (index is! MemoryIndexDocument || index.metadata.revision != state.revision) {
            throw const MemoryCorpusRecoveryRequired(
              'collection identity or revision changed outside the corpus authority',
            );
          }
        }
        documents[normalized] = Uint8List.fromList(value);
        bytes += value.length;
      }
      return MemoryCorpusSnapshot(
        collectionRevision: state.revision,
        fingerprint: state.fingerprint,
        documents: documents,
        omissions: omissions,
        externalChanges: prepared.externalChanges,
        prefixDocuments: prefixDocuments,
      );
    });
  }

  Future<MemoryCorpusCommitResult> commit({
    required int expectedRevision,
    required CanonicalMemoryCorpus replacement,
    FutureOr<void> Function(MemoryCorpusCommitResult result)? afterCommit,
  }) async {
    final change = await changeSelected<void>(
      expectedRevision: expectedRevision,
      include: (_, _) => true,
      prepare: (_) => MemoryCorpusChange(value: null, replacement: replacement),
      validateSelection: true,
      afterCommit: afterCommit == null
          ? null
          : (_, committed) => afterCommit(
              MemoryCorpusCommitResult.committed(
                collectionRevision: committed.index.metadata.revision,
                fingerprint: _fingerprint(committed.byteInventory(_codec)),
              ),
            ),
    );
    return change.wasCommitted
        ? MemoryCorpusCommitResult.committed(
            collectionRevision: change.collectionRevision,
            fingerprint: change.fingerprint,
          )
        : MemoryCorpusCommitResult.stale(
            collectionRevision: change.collectionRevision,
            fingerprint: change.fingerprint,
          );
  }

  Future<MemoryCorpusChangeResult<T>> changeSelected<T>({
    required int expectedRevision,
    required bool Function(MemoryRole? role, String path) include,
    Iterable<String> recordIds = const [],
    Iterable<String> paths = const [],
    required FutureOr<MemoryCorpusChange<T>> Function(CanonicalMemoryCorpus current) prepare,
    bool validateSelection = false,
    FutureOr<void> Function(T value, CanonicalMemoryCorpus committed)? afterCommit,
  }) {
    final completer = Completer<MemoryCorpusChangeResult<T>>();
    final op = WriteOp(() async {
      try {
        final result = await _lock.acquire(
          _lockKey,
          () => _changeSelectedLocked(
            expectedRevision: expectedRevision,
            include: include,
            recordIds: recordIds,
            paths: paths,
            prepare: prepare,
            validateSelection: validateSelection,
            afterCommit: afterCommit,
          ),
        );
        completer.complete(result);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _forwardQueueFailure(op, completer);
    return completer.future;
  }

  Future<T> updateFiles<T>({
    required Iterable<String> paths,
    Iterable<String> Function()? discoverPaths,
    required FutureOr<MemoryCorpusFileMutation<T>> Function(Map<String, Uint8List?> files) prepare,
    FutureOr<MemoryCorpusMutation<T>> Function(CanonicalMemoryCorpus corpus)? prepareCanonical,
    FutureOr<MemoryCorpusMutation<T>> Function(Map<String, Uint8List?> files)? prepareLegacyCanonical,
    bool bootstrapCanonical = false,
    FutureOr<void> Function(T value)? afterCommit,
    bool rollbackOnAfterCommitFailure = false,
  }) {
    final completer = Completer<T>();
    final op = WriteOp(() async {
      try {
        final value = await _lock.acquire(_lockKey, () async {
          final root = _resolveRoot(create: true);
          await _recoverLocked(root);
          final canonicalManifest = await _canonicalManifestIfPresentLocked(
            root,
            bootstrap: bootstrapCanonical && prepareCanonical != null,
          );
          if (canonicalManifest != null) {
            if (prepareCanonical == null) {
              throw StateError('Canonical corpus mutation requires a canonical prepare callback');
            }
            final result = await _changeSelectedLocked<T>(
              prepared: canonicalManifest,
              expectedRevision: canonicalManifest.state.revision,
              include: (_, _) => true,
              prepare: (current) async {
                final mutation = await prepareCanonical(current);
                final unchanged =
                    _fingerprint(mutation.corpus.byteInventory(_codec)) == canonicalManifest.state.fingerprint;
                return MemoryCorpusChange(value: mutation.value, replacement: unchanged ? null : mutation.corpus);
              },
              validateSelection: true,
              afterCommit: afterCommit == null ? null : (value, _) => afterCommit(value),
            );
            return result.value as T;
          }
          final current = <String, Uint8List?>{};
          final files = <String, File>{};
          var sourceBytes = 0;
          final requestedPaths = <String>[...paths, ...?discoverPaths?.call()];
          for (final suppliedPath in requestedPaths) {
            final relativePath = _normalizeMemberPath(suppliedPath);
            if (files.containsKey(relativePath) || current.containsKey(relativePath)) continue;
            final file = File(p.join(root, relativePath));
            final type = FileSystemEntity.typeSync(file.path, followLinks: false);
            if (type == FileSystemEntityType.notFound) {
              current[relativePath] = null;
            } else if (type == FileSystemEntityType.file) {
              final length = file.lengthSync();
              if (length > maxCorpusBytes) {
                throw FileSystemException('File exceeds the corpus byte limit', file.path);
              }
              sourceBytes += length;
              if (sourceBytes > maxCorpusBytes) {
                throw const MemoryCorpusRecoveryRequired('legacy sources exceed the aggregate-byte limit');
              }
              files[relativePath] = file;
            } else {
              throw FileSystemException('Unexpected corpus entity', file.path);
            }
          }
          if (files.length > maxCorpusFiles) {
            throw const MemoryCorpusRecoveryRequired('legacy sources exceed the file-count limit');
          }
          for (final entry in files.entries) {
            current[entry.key] = Uint8List.fromList(entry.value.readAsBytesSync());
          }
          if (prepareLegacyCanonical != null) {
            final mutation = await prepareLegacyCanonical(Map.unmodifiable(current));
            final target = _withRevision(mutation.corpus, 1);
            _validator.validate(target);
            _requireInventoryBounds(target.byteInventory(_codec));
            await _commitInitialCorpusLocked(
              root,
              target,
              baseSelection: {
                for (final entry in current.entries)
                  if (entry.value != null) entry.key: entry.value!,
              },
            );
            if (afterCommit != null) await afterCommit(mutation.value);
            return mutation.value;
          }
          final mutation = await prepare(Map.unmodifiable(current));
          final writes = <String, Uint8List?>{};
          var writeBytes = 0;
          for (final entry in mutation.writes.entries) {
            final relativePath = _normalizeMemberPath(entry.key);
            writeBytes += entry.value?.length ?? 0;
            writes[relativePath] = entry.value;
          }
          if (writes.length > maxCorpusFiles || writeBytes > maxCorpusBytes) {
            throw MemoryCorpusValidationException(['legacy mutation exceeds corpus bounds']);
          }
          _replaceLegacyFiles(root, writes);
          if (afterCommit != null) {
            try {
              await afterCommit(mutation.value);
            } on Object {
              if (rollbackOnAfterCommitFailure) {
                _replaceLegacyFiles(root, {for (final path in writes.keys) path: current[path]});
              }
              rethrow;
            }
          }
          return mutation.value;
        });
        completer.complete(value);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _forwardQueueFailure(op, completer);
    return completer.future;
  }

  Future<void> close() => _queue.close();
  String get _lockKey => p.join(_resolveRoot(create: true), 'MEMORY.md');
  void _forwardQueueFailure<T>(WriteOp op, Completer<T> completer) {
    _queue.add(op);
    op.completer.future.catchError((Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    });
  }
}
