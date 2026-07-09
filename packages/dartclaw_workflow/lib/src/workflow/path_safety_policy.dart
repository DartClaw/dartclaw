import 'dart:io';

import 'package:path/path.dart' as p;

final _argumentSafePathPattern = RegExp(r'^[A-Za-z0-9._/-]+$');

void validateArgumentSafePath(String workspacePath, {required String fieldName, required String rawPath}) {
  if (RegExp(r'[\x00-\x20\x7f]').hasMatch(workspacePath)) {
    throw FormatException('$fieldName must not contain whitespace or control characters: $rawPath');
  }
  if (!_argumentSafePathPattern.hasMatch(workspacePath)) {
    throw FormatException('$fieldName must use argument-safe path characters: $rawPath');
  }
  if (p.split(workspacePath).contains('..')) {
    throw FormatException('$fieldName must not contain parent traversal: $rawPath');
  }
  if (p.split(workspacePath).any((segment) => segment.startsWith('-'))) {
    throw FormatException('$fieldName must not contain flag-shaped path segments: $rawPath');
  }
}

String safeProjectRelativePath(
  String rawPath,
  String? activeWorkspaceRoot, {
  required String fieldName,
  bool rejectRoot = false,
}) {
  final value = rawPath.trim();
  if (value.isEmpty || value == 'null') return p.normalize(value);
  final root = activeWorkspaceRoot?.trim();
  if (root == null || root.isEmpty) return p.normalize(value);

  final rootAbs = p.normalize(p.absolute(root));
  final candidateAbs = p.isAbsolute(value) ? p.normalize(value) : p.normalize(p.join(rootAbs, value));
  if (rejectRoot && candidateAbs == rootAbs) {
    throw FormatException('$fieldName targets the project root: $rawPath');
  }
  if (candidateAbs != rootAbs && !p.isWithin(rootAbs, candidateAbs)) {
    throw FormatException('$fieldName escapes project root: $rawPath');
  }

  final rootReal = resolveExistingPath(rootAbs);
  if (rootReal != null) {
    final candidateRealAnchor = resolveNearestExistingPath(candidateAbs);
    if (candidateRealAnchor != null && candidateRealAnchor != rootReal && !p.isWithin(rootReal, candidateRealAnchor)) {
      throw FormatException('$fieldName resolves outside project root: $rawPath');
    }
  }

  return p.normalize(p.relative(candidateAbs, from: rootAbs));
}

bool fileStaysInsideRoot(File file, String activeWorkspaceRoot) {
  try {
    final rootRealPath = Directory(p.normalize(p.absolute(activeWorkspaceRoot))).resolveSymbolicLinksSync();
    final fileRealPath = file.resolveSymbolicLinksSync();
    return p.isWithin(p.normalize(rootRealPath), p.normalize(fileRealPath));
  } on FileSystemException {
    return false;
  }
}

String? resolveNearestExistingPath(String path) {
  var current = p.normalize(path);
  while (true) {
    final resolved = resolveExistingPath(current);
    if (resolved != null) return resolved;
    final parent = p.dirname(current);
    if (parent == current) return null;
    current = parent;
  }
}

String? resolveExistingPath(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  try {
    final followedType = FileSystemEntity.typeSync(path);
    if (followedType == FileSystemEntityType.directory) {
      return p.normalize(Directory(path).resolveSymbolicLinksSync());
    }
    return p.normalize(File(path).resolveSymbolicLinksSync());
  } on FileSystemException {
    if (type == FileSystemEntityType.link) {
      try {
        final target = Link(path).targetSync();
        final resolvedTarget = p.isAbsolute(target) ? target : p.join(p.dirname(path), target);
        return p.normalize(p.absolute(resolvedTarget));
      } on FileSystemException {
        return null;
      }
    }
    return null;
  }
}
