import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart' show ExecutionRepositoryTransactor;
import 'package:path/path.dart' as p;

import '../concurrency/repo_lock.dart';
import 'atomic_write.dart';

final _transactionKey = Object();
const _collections = [
  'tasks',
  'agentExecutions',
  'workflowSteps',
  'workflowRuns',
  'artifacts',
  'goals',
  'events',
  'traces',
];

/// Atomic file authority for standalone execution records.
///
/// A transaction stages all repository writes in one checkpoint. Failed actions
/// leave the prior checkpoint intact. A stable sidecar lock serializes writers
/// across processes, while [RepoLock] serializes users within a process.
final class FileExecutionStore implements ExecutionRepositoryTransactor {
  new _(this.path);

  /// Canonical checkpoint path.
  final String path;

  final RepoLock _lock = RepoLock();
  bool _closed = false;

  /// Opens or creates a versioned checkpoint, refusing malformed existing state.
  static Future<FileExecutionStore> open(String path) async {
    final parent = Directory(p.dirname(p.absolute(path)));
    await parent.create(recursive: true);
    final canonicalParent = await parent.resolveSymbolicLinks();
    final candidate = p.join(canonicalParent, p.basename(path));
    final isLink = await FileSystemEntity.type(candidate, followLinks: false) == FileSystemEntityType.link;
    final canonicalPath = isLink ? await File(candidate).resolveSymbolicLinks() : candidate;
    final context = Zone.current[_transactionKey] as _FileTransaction?;
    if (context != null && context.store.path == canonicalPath) {
      throw StateError('Cannot open file execution store during an operation: $canonicalPath');
    }
    final store = FileExecutionStore._(canonicalPath);
    await store._withFileLock(() async {
      if (!await File(store.path).exists()) {
        await atomicWriteJson(File(store.path), store._emptyState(), restrictPermissions: true);
      } else {
        await store._load();
      }
    });
    return store;
  }

  /// Reads the latest committed checkpoint, or the current transaction draft.
  Future<T> read<T>(T Function(Map<String, dynamic>) action) async {
    _ensureOpen();
    final context = Zone.current[_transactionKey] as _FileTransaction?;
    if (context != null && context.store.path == path) {
      _ensureContext(context);
      return action(context.state);
    }
    return _withFileLock(() async {
      final context = _FileTransaction(this, await _load(), readOnly: true);
      try {
        return await runZoned(() => action(context.state), zoneValues: {_transactionKey: context});
      } finally {
        context.active = false;
      }
    });
  }

  /// Applies an atomic mutation, joining the current transaction when present.
  Future<T> update<T>(FutureOr<T> Function(Map<String, dynamic>) action) async {
    _ensureOpen();
    final context = Zone.current[_transactionKey] as _FileTransaction?;
    if (context != null && context.store.path == path) {
      _ensureContext(context);
      if (context.readOnly) throw StateError('Cannot update during file execution read: $path');
      return await action(context.state);
    }
    return _withFileLock(() async {
      final draft = await _load();
      final tx = _FileTransaction(this, draft);
      try {
        final result = await runZoned(() => Future.sync(() => action(draft)), zoneValues: {_transactionKey: tx});
        await atomicWriteJson(File(path), draft, restrictPermissions: true);
        return result;
      } finally {
        tx.active = false;
      }
    });
  }

  /// Commits all joined repository operations with one atomic replacement.
  @override
  Future<T> transaction<T>(FutureOr<T> Function() action) async {
    _ensureOpen();
    final context = Zone.current[_transactionKey] as _FileTransaction?;
    if (context != null && context.store.path == path) {
      _ensureContext(context);
      throw StateError('Nested file execution transactions are unsupported: $path');
    }
    return _withFileLock(() async {
      final draft = await _load();
      final tx = _FileTransaction(this, draft);
      try {
        final result = await runZoned(() => Future.sync(action), zoneValues: {_transactionKey: tx});
        await atomicWriteJson(File(path), draft, restrictPermissions: true);
        return result;
      } finally {
        tx.active = false;
      }
    });
  }

  /// Closes this handle; the checkpoint and sidecar remain on disk.
  Future<void> close() async {
    final context = Zone.current[_transactionKey] as _FileTransaction?;
    if (context != null && context.store.path == path) {
      throw StateError('Cannot close file execution store during an operation: $path');
    }
    await _lock.acquire(path, () {
      _closed = true;
    });
  }

  Future<T> _withFileLock<T>(Future<T> Function() action) => _lock.acquire(path, () async {
    _ensureOpen();
    final handle = await File('$path.lock').open(mode: FileMode.append);
    var locked = false;
    try {
      await handle.lock(FileLock.blockingExclusive);
      locked = true;
      return await action();
    } finally {
      try {
        if (locked) await handle.unlock();
      } finally {
        await handle.close();
      }
    }
  });

  Future<Map<String, dynamic>> _load() async {
    final file = File(path);
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['schemaVersion'] != 1) {
        throw const FormatException('Unsupported execution checkpoint schema');
      }
      for (final collection in _collections) {
        final values = decoded[collection];
        if (values is! Map<String, dynamic>) {
          throw FormatException('Invalid $collection collection');
        }
        for (final value in values.values) {
          if (value is! Map<String, dynamic>) {
            throw FormatException('Invalid $collection record');
          }
        }
      }
      return decoded;
    } on FormatException catch (error) {
      throw FormatException('Invalid execution checkpoint at $path: ${error.message}');
    } on TypeError catch (error) {
      throw FormatException('Invalid execution checkpoint at $path: $error');
    }
  }

  Map<String, dynamic> _emptyState() => {
    'schemaVersion': 1,
    for (final collection in _collections) collection: <String, dynamic>{},
  };

  void _ensureOpen() {
    if (_closed) throw StateError('File execution store is closed: $path');
  }

  void _ensureContext(_FileTransaction context) {
    if (!context.active) throw StateError('File execution transaction has ended: $path');
    if (!identical(context.store, this)) {
      throw StateError('Another file execution handle owns the current operation: $path');
    }
  }
}

final class _FileTransaction {
  new(this.store, this.state, {this.readOnly = false});

  final FileExecutionStore store;
  final Map<String, dynamic> state;
  final bool readOnly;
  bool active = true;
}
