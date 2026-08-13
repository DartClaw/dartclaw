import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show MemoryFileService, MemoryResourceLimits, MemoryRole;
import 'package:path/path.dart' as p;

const _streamChunkBytes = 64 * 1024;
const _maxTraversalEntities = MemoryResourceLimits.recursiveFiles * 2 + 1;

/// UTF-8 content and exact byte size from one workspace file read.
typedef WorkspaceFileSnapshot = ({String content, int sizeBytes});

/// Metadata for one regular direct child beneath a workspace directory.
typedef WorkspaceFileEntry = ({String name, int sizeBytes});

/// Stable bounded directory metadata plus truncation evidence.
typedef WorkspaceDirectoryScan = ({
  List<WorkspaceFileEntry> entries,
  int omittedCount,
  String? firstOmitted,
  bool complete,
});

/// Reads stable direct children beneath one canonical workspace root.
final class WorkspaceFileReader {
  final String _root;

  /// Pins [workspaceDir] to its canonical directory for subsequent reads.
  WorkspaceFileReader(String workspaceDir) : _root = _resolveRoot(workspaceDir);

  /// Reads regular file [name], or returns `null` when missing.
  WorkspaceFileSnapshot? read(String name, {MemoryRole? role}) {
    if (p.basename(name) != name) throw ArgumentError.value(name, 'name', 'must be a file name');
    _requireDirectory(_root);
    final file = File(p.join(_root, name));
    final content = MemoryFileService.readRegularFile(file, role: role);
    return content == null ? null : (content: content, sizeBytes: utf8.encode(content).length);
  }

  /// Streams metadata for matching regular children.
  Stream<WorkspaceFileEntry> readDirectory(String name, {bool Function(String name)? include}) async* {
    if (p.basename(name) != name) throw ArgumentError.value(name, 'name', 'must be a directory name');
    _requireDirectory(_root);
    final directory = Directory(p.join(_root, name));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException('Workspace child is not a directory', directory.path);
    }

    await for (final entity in directory.list(followLinks: false)) {
      final childName = p.basename(entity.path);
      if (include != null && !include(childName)) continue;
      if (FileSystemEntity.typeSync(entity.path, followLinks: false) != FileSystemEntityType.file) continue;
      final stat = entity.statSync();
      yield (name: childName, sizeBytes: stat.size);
    }
  }

  /// Returns at most [limit] regular children in lexical order.
  ///
  /// [WorkspaceDirectoryScan.complete] is false when bounded traversal cannot establish a deterministic prefix.
  Future<WorkspaceDirectoryScan> readDirectoryBounded(
    String name, {
    required int limit,
    bool Function(String name)? include,
  }) async {
    if (limit < 1 || limit > MemoryResourceLimits.recursiveFiles) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and ${MemoryResourceLimits.recursiveFiles}');
    }
    if (p.basename(name) != name) throw ArgumentError.value(name, 'name', 'must be a directory name');
    _requireDirectory(_root);
    final directory = Directory(p.join(_root, name));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return (entries: const <WorkspaceFileEntry>[], omittedCount: 0, firstOmitted: null, complete: true);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException('Workspace child is not a directory', directory.path);
    }

    final names = <String>[];
    var visitedEntities = 0;
    await for (final entity in directory.list(followLinks: false)) {
      visitedEntities++;
      if (visitedEntities > _maxTraversalEntities) {
        return (entries: const <WorkspaceFileEntry>[], omittedCount: 0, firstOmitted: null, complete: false);
      }
      final childName = p.basename(entity.path);
      if (include != null && !include(childName)) continue;
      if (entity is! File) continue;
      names.add(childName);
    }
    names.sort();
    final firstOmitted = names.length > limit ? names[limit] : null;
    return (
      entries: [
        for (final childName in names.take(limit))
          (name: childName, sizeBytes: File(p.join(directory.path, childName)).statSync().size),
      ],
      omittedCount: names.length > limit ? names.length - limit : 0,
      firstOmitted: firstOmitted,
      complete: true,
    );
  }

  /// Streams one regular child in fixed-size byte chunks.
  Stream<List<int>> streamDirectoryFileBytes(String directoryName, String name, {int? maxBytes}) async* {
    if (p.basename(directoryName) != directoryName) {
      throw ArgumentError.value(directoryName, 'directoryName', 'must be a directory name');
    }
    if (p.basename(name) != name) {
      throw ArgumentError.value(name, 'name', 'must be a file name');
    }

    _requireDirectory(_root);
    final directory = Directory(p.join(_root, directoryName));
    _requireDirectory(directory.path);
    final file = File(p.join(directory.path, name));
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Workspace child is not a regular file', file.path);
    }

    final handle = file.openSync();
    try {
      if (maxBytes case final limit? when handle.lengthSync() > limit) {
        throw FileSystemException('File exceeds remaining body-read budget', file.path);
      }
      while (true) {
        final bytes = handle.readSync(_streamChunkBytes);
        if (bytes.isEmpty) break;
        yield bytes;
      }
    } finally {
      handle.closeSync();
    }
  }

  static String _resolveRoot(String workspaceDir) {
    final directory = Directory(p.absolute(workspaceDir));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return p.normalize(directory.path);
    if (type != FileSystemEntityType.directory && type != FileSystemEntityType.link) {
      throw FileSystemException('Workspace root is not a directory', directory.path);
    }
    final resolved = directory.resolveSymbolicLinksSync();
    if (FileSystemEntity.typeSync(resolved, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Workspace root does not resolve to a directory', directory.path);
    }
    return p.normalize(resolved);
  }

  static void _requireDirectory(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Workspace child is not a directory', path);
    }
  }
}
