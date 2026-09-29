import 'dart:io';

import 'package:path/path.dart' as p;

/// Reports why standalone execution ownership could not be acquired.
final class StandaloneExecutionLeaseException implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Holds the standalone session and KV state under one execution process.
final class StandaloneExecutionLease {
  new _(this.path, this._file);

  static final Set<String> _heldPaths = {};

  final String path;
  final RandomAccessFile _file;
  bool _released = false;

  static Future<StandaloneExecutionLease> acquire(String standaloneDir) async {
    final directory = Directory(p.absolute(standaloneDir));
    await directory.create(recursive: true);
    final canonicalDir = await directory.resolveSymbolicLinks();
    final path = p.join(canonicalDir, 'execution.owner.lock');
    if (!_heldPaths.add(path)) {
      throw StandaloneExecutionLeaseException('A standalone workflow execution is already active for $canonicalDir');
    }

    RandomAccessFile? file;
    try {
      file = await File(path).open(mode: FileMode.append);
      await file.lock(FileLock.exclusive);
      return StandaloneExecutionLease._(path, file);
    } catch (error) {
      try {
        await file?.close();
      } finally {
        _heldPaths.remove(path);
      }
      if (error is FileSystemException) {
        throw StandaloneExecutionLeaseException(
          'Could not acquire standalone workflow execution lock for $canonicalDir: $error. '
          'Another execution may already be active.',
        );
      }
      rethrow;
    }
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _file.unlock();
    } finally {
      try {
        await _file.close();
      } finally {
        _heldPaths.remove(path);
      }
    }
  }
}
