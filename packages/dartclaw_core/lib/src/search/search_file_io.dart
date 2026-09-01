import 'dart:io';

import 'package:path/path.dart' as p;

/// Returns whether [file] is a regular file reached without crossing a link beneath [root].
bool isRegularFileWithinRoot(Directory root, File file) {
  if (!p.isWithin(root.path, file.path)) return false;
  final segments = p.split(p.relative(file.path, from: root.path));
  var current = root.path;
  for (var index = 0; index < segments.length; index++) {
    current = p.join(current, segments[index]);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    final expected = index == segments.length - 1 ? FileSystemEntityType.file : FileSystemEntityType.directory;
    if (type != expected) return false;
  }
  return true;
}
