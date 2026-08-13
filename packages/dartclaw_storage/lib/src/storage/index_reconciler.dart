import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'memory_service.dart';
import 'search_db.dart';

/// Writes one index-health evidence update.
typedef IndexHealthWriter = Future<void> Function(File file, Map<String, Object?> evidence);

/// Truthful state of the disposable canonical-memory search index.
enum IndexHealthState {
  /// Complete current-corpus parity was validated.
  healthy,

  /// A known mismatch or recovery failure exists.
  degraded,

  /// A full reconciliation is active in this process.
  rebuilding,

  /// Evidence could not be established.
  unknown,
}

/// Durable evidence about the last complete canonical-index reconciliation.
final class IndexHealthEvidence {
  /// Creates an immutable health snapshot.
  const IndexHealthEvidence({
    required this.state,
    required this.canonicalRevision,
    required this.canonicalFingerprint,
    this.indexRevision,
    this.indexFingerprint,
    this.validatedAt,
    this.failureStage,
    this.reason,
    this.action,
  });

  /// Current derived-index state.
  final IndexHealthState state;

  /// Current canonical collection revision.
  final int canonicalRevision;

  /// Current canonical full-union fingerprint.
  final String canonicalFingerprint;

  /// Last completely validated index revision.
  final int? indexRevision;

  /// Last completely validated index fingerprint.
  final String? indexFingerprint;

  /// Time of the last complete validation.
  final DateTime? validatedAt;

  /// Transition stage that failed.
  final String? failureStage;

  /// Bounded operator-facing failure reason.
  final String? reason;

  /// Safe operator recovery action.
  final String? action;

  /// Whether this evidence proves exact current parity.
  bool isCurrent(int revision, String fingerprint) =>
      state == IndexHealthState.healthy &&
      canonicalRevision == revision &&
      canonicalFingerprint == fingerprint &&
      indexRevision == revision &&
      indexFingerprint == fingerprint;

  /// Serializes the durable evidence contract.
  Map<String, Object?> toJson() => {
    'state': state.name,
    'canonicalRevision': canonicalRevision,
    'canonicalFingerprint': canonicalFingerprint,
    'indexRevision': indexRevision,
    'indexFingerprint': indexFingerprint,
    'validatedAt': validatedAt?.toUtc().toIso8601String(),
    'failureStage': failureStage,
    'reason': reason,
    'action': action,
  };
}

/// Persists derived-index evidence beside the canonical corpus coordination state.
final class IndexHealthStore {
  /// Creates a workspace-scoped evidence store.
  IndexHealthStore({required String workspaceDir, DateTime Function()? now, IndexHealthWriter? writer})
    : _file = File(p.join(workspaceDir, '.dartclaw-memory-index.json')),
      _now = now ?? DateTime.now,
      _writer = writer;

  final File _file;
  final DateTime Function() _now;
  final IndexHealthWriter? _writer;
  var _active = false;

  /// Absolute path of the evidence file.
  String get path => _file.path;

  /// Reads evidence relative to the supplied current canonical identity.
  Future<IndexHealthEvidence> read({required int canonicalRevision, required String canonicalFingerprint}) async {
    final evidence = await _readPersisted();
    if (evidence == null) {
      return IndexHealthEvidence(
        state: IndexHealthState.unknown,
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
        reason: 'No completed index reconciliation evidence is available.',
        action: 'Run dartclaw rebuild-index.',
      );
    }
    if (evidence.state == IndexHealthState.rebuilding && !_active) {
      return IndexHealthEvidence(
        state: IndexHealthState.degraded,
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
        indexRevision: evidence.indexRevision,
        indexFingerprint: evidence.indexFingerprint,
        validatedAt: evidence.validatedAt,
        failureStage: 'interrupted',
        reason: 'The previous index reconciliation did not complete.',
        action: 'Run dartclaw rebuild-index.',
      );
    }
    if (evidence.canonicalRevision != canonicalRevision || evidence.canonicalFingerprint != canonicalFingerprint) {
      return IndexHealthEvidence(
        state: IndexHealthState.degraded,
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
        indexRevision: evidence.indexRevision,
        indexFingerprint: evidence.indexFingerprint,
        validatedAt: evidence.validatedAt,
        failureStage: 'canonicalMismatch',
        reason: 'The search index has not been validated for the current canonical collection.',
        action: 'Run dartclaw rebuild-index.',
      );
    }
    return evidence;
  }

  /// Records an active full reconciliation while retaining prior success facts.
  Future<void> recordRebuilding({
    required int canonicalRevision,
    required String canonicalFingerprint,
    IndexHealthEvidence? previous,
  }) async {
    await _write(
      IndexHealthEvidence(
        state: IndexHealthState.rebuilding,
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
        indexRevision: previous?.indexRevision,
        indexFingerprint: previous?.indexFingerprint,
        validatedAt: previous?.validatedAt,
        action: 'Wait for reconciliation to complete.',
      ),
    );
    _active = true;
  }

  /// Publishes complete current-corpus parity.
  Future<void> recordHealthy({required int canonicalRevision, required String canonicalFingerprint}) async {
    _active = false;
    await _write(
      IndexHealthEvidence(
        state: IndexHealthState.healthy,
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
        indexRevision: canonicalRevision,
        indexFingerprint: canonicalFingerprint,
        validatedAt: _now().toUtc(),
      ),
    );
  }

  /// Persists a known failure without discarding prior success facts.
  Future<void> recordDegraded({
    required int canonicalRevision,
    required String canonicalFingerprint,
    required String stage,
    required Object reason,
    IndexHealthEvidence? previous,
  }) async {
    _active = false;
    previous ??= await _readPriorEvidence();
    await _write(
      IndexHealthEvidence(
        state: IndexHealthState.degraded,
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
        indexRevision: previous?.indexRevision,
        indexFingerprint: previous?.indexFingerprint,
        validatedAt: previous?.validatedAt,
        failureStage: stage,
        reason: _boundedReason(reason),
        action: 'Run dartclaw rebuild-index while DartClaw is stopped.',
      ),
    );
  }

  Future<IndexHealthEvidence?> _readPriorEvidence() async {
    try {
      return await _readPersisted();
    } catch (_) {
      return null;
    }
  }

  Future<IndexHealthEvidence?> _readPersisted() async {
    if (!_file.existsSync()) return null;
    final type = FileSystemEntity.typeSync(_file.path, followLinks: false);
    if (type != FileSystemEntityType.file) throw FileSystemException('Index health evidence is not a file', _file.path);
    final value = jsonDecode(await _file.readAsString());
    if (value is! Map<String, dynamic>) throw const FormatException('Index health evidence must be an object');
    return _decode(value);
  }

  Future<void> _write(IndexHealthEvidence evidence) async {
    _file.parent.createSync(recursive: true);
    final writer = _writer;
    if (writer == null) {
      await atomicWriteJson(_file, evidence.toJson());
    } else {
      await writer(_file, evidence.toJson());
    }
  }

  static IndexHealthEvidence _decode(Map<String, dynamic> json) {
    final stateName = json['state'];
    final revision = json['canonicalRevision'];
    final fingerprint = json['canonicalFingerprint'];
    if (stateName is! String || revision is! int || revision < 1 || fingerprint is! String || fingerprint.isEmpty) {
      throw const FormatException('Index health evidence is malformed');
    }
    final state = IndexHealthState.values.where((value) => value.name == stateName).firstOrNull;
    if (state == null) throw const FormatException('Index health state is invalid');
    final indexRevision = json['indexRevision'];
    final indexFingerprint = json['indexFingerprint'];
    final validatedAt = json['validatedAt'];
    if (indexRevision != null && indexRevision is! int ||
        indexFingerprint != null && indexFingerprint is! String ||
        validatedAt != null && validatedAt is! String) {
      throw const FormatException('Index health reconciliation evidence is malformed');
    }
    return IndexHealthEvidence(
      state: state,
      canonicalRevision: revision,
      canonicalFingerprint: fingerprint,
      indexRevision: indexRevision as int?,
      indexFingerprint: indexFingerprint as String?,
      validatedAt: validatedAt == null ? null : DateTime.parse(validatedAt as String),
      failureStage: json['failureStage'] as String?,
      reason: json['reason'] as String?,
      action: json['action'] as String?,
    );
  }

  static String _boundedReason(Object reason) {
    final value = reason.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return value.length <= 512 ? value : value.substring(0, 512);
  }
}

/// Named fault points in the fresh-sibling reconciliation transaction.
enum IndexReconcileTransition {
  /// The sibling database handle was created.
  siblingCreated,

  /// Canonical rows were populated.
  populated,

  /// SQLite, FTS, and row parity validated.
  validated,

  /// The sibling is about to close.
  beforeClose,

  /// The sibling handle closed.
  closed,

  /// Atomic target replacement is about to run.
  beforeSwap,

  /// Target replacement completed.
  swapped,
}

/// Observes or injects one reconciliation transition.
typedef IndexReconcileHook = Future<void> Function(IndexReconcileTransition transition);

/// Replaces the target with a closed sibling database.
typedef IndexFileReplace = void Function(File sibling, String targetPath);

/// Outcome of one complete fresh-sibling reconciliation.
final class IndexReconcileResult {
  /// Creates a successful reconciliation result.
  const IndexReconcileResult({required this.revision, required this.rowCount, required this.health});

  /// Canonical revision projected.
  final int revision;

  /// Exact projected row count.
  final int rowCount;

  /// Published healthy evidence.
  final IndexHealthEvidence health;
}

/// Rebuilds the FTS5 index from one captured canonical corpus and publishes it atomically.
final class CanonicalIndexReconciler {
  /// Creates a reconciler for one `search.db` target.
  CanonicalIndexReconciler({
    required this.targetPath,
    required this.healthStore,
    SearchDbFactory? databaseFactory,
    IndexFileReplace? replaceFile,
    IndexReconcileHook? transitionHook,
  }) : _databaseFactory = databaseFactory ?? openSearchDb,
       _replaceFile = replaceFile ?? _replace,
       _transitionHook = transitionHook;

  /// Target `search.db` path.
  final String targetPath;

  /// Workspace-scoped health evidence store.
  final IndexHealthStore healthStore;
  final SearchDbFactory _databaseFactory;
  final IndexFileReplace _replaceFile;
  final IndexReconcileHook? _transitionHook;

  /// Validates a current target or reconstructs it when evidence or bytes are stale.
  Future<IndexReconcileResult> ensureCurrent({
    required CanonicalMemoryCorpus corpus,
    required int canonicalRevision,
    required String canonicalFingerprint,
    String userId = 'owner',
  }) async {
    try {
      final evidence = await healthStore.read(
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
      );
      final target = File(targetPath);
      if (evidence.isCurrent(canonicalRevision, canonicalFingerprint) &&
          FileSystemEntity.typeSync(target.path, followLinks: false) == FileSystemEntityType.file) {
        final database = _databaseFactory(target.path);
        try {
          final expected = MemoryService.canonicalIndexRows(corpus);
          MemoryService(database).validateIndexRows(expected, userId: userId);
          return IndexReconcileResult(revision: canonicalRevision, rowCount: expected.length, health: evidence);
        } finally {
          database.close();
        }
      }
    } catch (_) {
      // Full reconstruction below is the recovery path for unreadable evidence or target bytes.
    }
    return reconcile(
      corpus: corpus,
      canonicalRevision: canonicalRevision,
      canonicalFingerprint: canonicalFingerprint,
      userId: userId,
    );
  }

  /// Validates current evidence or reconstructs from independently bounded row batches.
  Future<IndexReconcileResult> ensureCurrentBatched({
    required Stream<List<MemoryIndexRow>> Function() rowBatches,
    required int canonicalRevision,
    required String canonicalFingerprint,
    Future<void> Function()? authenticateComplete,
    String userId = 'owner',
  }) async {
    try {
      final evidence = await healthStore.read(
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
      );
      final target = File(targetPath);
      if (evidence.isCurrent(canonicalRevision, canonicalFingerprint) &&
          FileSystemEntity.typeSync(target.path, followLinks: false) == FileSystemEntityType.file) {
        final database = _databaseFactory(target.path);
        try {
          final memory = MemoryService(database)..validateIntegrity();
          var expectedRows = 0;
          await for (final rows in rowBatches()) {
            final ids = rows.map((row) => row.entryId).whereType<String>().toSet();
            memory.validateMemoryRecords(rows, ids, userId: userId);
            expectedRows += rows.length;
          }
          if (memory.memoryRowCount(userId: userId) != expectedRows) throw StateError('Index row count mismatch');
          await authenticateComplete?.call();
          return IndexReconcileResult(revision: canonicalRevision, rowCount: expectedRows, health: evidence);
        } finally {
          database.close();
        }
      }
    } catch (_) {
      // Full reconstruction below is the recovery path for unreadable evidence or target bytes.
    }
    return reconcileBatched(
      rowBatches: rowBatches,
      canonicalRevision: canonicalRevision,
      canonicalFingerprint: canonicalFingerprint,
      authenticateComplete: authenticateComplete,
      userId: userId,
    );
  }

  /// Reconstructs and validates the complete current canonical projection.
  Future<IndexReconcileResult> reconcile({
    required CanonicalMemoryCorpus corpus,
    required int canonicalRevision,
    required String canonicalFingerprint,
    String userId = 'owner',
  }) => reconcileBatched(
    rowBatches: () => Stream.value(MemoryService.canonicalIndexRows(corpus)),
    canonicalRevision: canonicalRevision,
    canonicalFingerprint: canonicalFingerprint,
    userId: userId,
  );

  /// Reconstructs the index from independently bounded canonical row batches.
  Future<IndexReconcileResult> reconcileBatched({
    required Stream<List<MemoryIndexRow>> Function() rowBatches,
    required int canonicalRevision,
    required String canonicalFingerprint,
    Future<void> Function()? authenticateComplete,
    String userId = 'owner',
  }) async {
    IndexHealthEvidence? previous;
    try {
      previous = await healthStore.read(
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
      );
    } catch (_) {}
    await healthStore.recordRebuilding(
      canonicalRevision: canonicalRevision,
      canonicalFingerprint: canonicalFingerprint,
      previous: previous,
    );

    final target = File(targetPath);
    target.parent.createSync(recursive: true);
    final sibling = File(
      p.join(
        target.parent.path,
        '.${p.basename(target.path)}.dartclaw-rebuild-$pid-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    final backup = File('${sibling.path}.previous');
    var stage = 'create';
    var swapped = false;
    Database? database;
    var rowCount = 0;
    try {
      database = _databaseFactory(sibling.path);
      await _transition(IndexReconcileTransition.siblingCreated);
      stage = 'populate';
      final memory = MemoryService(database);
      memory.rebuildIndex(const [], userId: userId);
      await for (final rows in rowBatches()) {
        final ids = rows.map((row) => row.entryId).whereType<String>().toSet();
        memory.replaceMemoryRecords(rows, ids, userId: userId);
        memory.validateMemoryRecords(rows, ids, userId: userId);
        rowCount += rows.length;
      }
      await _transition(IndexReconcileTransition.populated);
      stage = 'validate';
      memory.validateIntegrity();
      if (memory.memoryRowCount(userId: userId) != rowCount) throw StateError('Index row count mismatch');
      await authenticateComplete?.call();
      await _transition(IndexReconcileTransition.validated);
      stage = 'close';
      await _transition(IndexReconcileTransition.beforeClose);
      database.close();
      database = null;
      await _transition(IndexReconcileTransition.closed);
      stage = 'swap';
      await _transition(IndexReconcileTransition.beforeSwap);
      if (FileSystemEntity.typeSync(target.path, followLinks: false) == FileSystemEntityType.file) {
        target.copySync(backup.path);
      }
      swapped = true;
      _replaceFile(sibling, target.path);
      await _transition(IndexReconcileTransition.swapped);
      stage = 'publish';
      await healthStore.recordHealthy(canonicalRevision: canonicalRevision, canonicalFingerprint: canonicalFingerprint);
      final health = await healthStore.read(
        canonicalRevision: canonicalRevision,
        canonicalFingerprint: canonicalFingerprint,
      );
      if (backup.existsSync()) backup.deleteSync();
      return IndexReconcileResult(revision: canonicalRevision, rowCount: rowCount, health: health);
    } catch (error, stackTrace) {
      try {
        database?.close();
      } catch (_) {}
      if (swapped) {
        try {
          if (backup.existsSync()) {
            if (target.existsSync()) target.deleteSync();
            backup.renameSync(target.path);
          } else if (target.existsSync()) {
            target.deleteSync();
          }
        } catch (rollbackError) {
          Error.throwWithStackTrace(
            StateError('Index reconciliation failed: $error; target rollback failed: $rollbackError'),
            stackTrace,
          );
        }
      }
      try {
        if (sibling.existsSync()) sibling.deleteSync();
      } catch (_) {}
      try {
        if (backup.existsSync()) backup.deleteSync();
      } catch (_) {}
      try {
        await healthStore.recordDegraded(
          canonicalRevision: canonicalRevision,
          canonicalFingerprint: canonicalFingerprint,
          stage: stage,
          reason: error,
          previous: previous,
        );
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _transition(IndexReconcileTransition transition) async => _transitionHook?.call(transition);

  static void _replace(File sibling, String targetPath) => sibling.renameSync(targetPath);
}
