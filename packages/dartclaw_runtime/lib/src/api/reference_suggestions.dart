import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

const _maxFileReferenceSuggestions = 10;
const _maxFileReferenceTraversalEntries = 128;

/// Collects bounded file reference suggestions without following symlinks.
Future<List<Map<String, dynamic>>> collectFileReferenceSuggestions(Directory root, String normalizedQuery) async {
  final references = <Map<String, dynamic>>[];
  final pending = <Directory>[root];
  var directoryIndex = 0;
  var traversed = 0;

  while (directoryIndex < pending.length &&
      references.length < _maxFileReferenceSuggestions &&
      traversed < _maxFileReferenceTraversalEntries) {
    final directory = pending[directoryIndex++];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (traversed >= _maxFileReferenceTraversalEntries || references.length >= _maxFileReferenceSuggestions) {
          break;
        }
        traversed++;
        final relative = p.relative(entity.path, from: root.path);
        if (_hasHiddenPathSegment(relative)) continue;
        if (entity is Directory) {
          pending.add(entity);
          continue;
        }
        if (entity is! File) continue;
        if (normalizedQuery.isNotEmpty && !relative.toLowerCase().contains(normalizedQuery)) continue;
        references.add({'type': 'file', 'id': relative, 'label': relative});
      }
    } on FileSystemException {
      // Inaccessible project directories should not make reference lookup fail.
    }
    await Future<void>.delayed(Duration.zero);
  }

  return references;
}

bool _hasHiddenPathSegment(String path) =>
    p.split(path).any((segment) => segment.startsWith('.') && segment != '.' && segment != '..');
