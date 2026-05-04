import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves symlinks through the deepest existing ancestor of [path].
///
/// This allows callers to reason about future descendants under mounted roots
/// while still treating ancestor-symlink escapes as outside the mount.
String canonicalizePathWithExistingAncestors(String path) {
  final absolutePath = p.normalize(p.absolute(path));
  final parts = p.split(absolutePath);
  if (parts.isEmpty) {
    return absolutePath;
  }

  var current = parts.first;
  for (var index = 1; index < parts.length; index++) {
    final candidate = p.join(current, parts[index]);
    final lexicalType = FileSystemEntity.typeSync(candidate, followLinks: false);
    if (lexicalType == FileSystemEntityType.notFound) {
      return p.normalize(p.join(current, p.joinAll(parts.sublist(index))));
    }

    try {
      final resolvedType = FileSystemEntity.typeSync(candidate);
      current = switch (resolvedType) {
        FileSystemEntityType.directory => p.normalize(Directory(candidate).resolveSymbolicLinksSync()),
        FileSystemEntityType.file ||
        FileSystemEntityType.link => p.normalize(File(candidate).resolveSymbolicLinksSync()),
        _ => p.normalize(candidate),
      };
    } catch (_) {
      current = p.normalize(candidate);
    }
  }

  return current;
}
