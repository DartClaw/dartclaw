import 'dart:io';

import 'package:path/path.dart' as p;

/// Reads the wiki page at [locator] (`wiki/<path>.md`, relative to [workspaceDir]).
///
/// Returns null for every refusal (malformed locator, traversal, missing file, symlink
/// escape, I/O failure), so callers can answer all of them identically and the
/// refusal never reveals what exists in the workspace.
String? readContainedWikiPage(String workspaceDir, String locator) {
  if (!locator.startsWith('wiki/') || !locator.endsWith('.md')) return null;
  final wikiRoot = p.normalize(p.absolute(p.join(workspaceDir, 'wiki')));
  final filePath = p.normalize(p.absolute(p.join(wikiRoot, locator.substring('wiki/'.length))));
  if (!p.isWithin(wikiRoot, filePath)) return null;
  final file = File(filePath);
  if (!file.existsSync()) return null;

  try {
    final canonicalWikiRoot = p.normalize(Directory(wikiRoot).resolveSymbolicLinksSync());
    final canonicalFilePath = p.normalize(file.resolveSymbolicLinksSync());
    if (!p.isWithin(canonicalWikiRoot, canonicalFilePath)) return null;
    // Read the path that was verified, not the one that was requested: the
    // workspace is agent-writable, so re-resolving through `file` would let a
    // symlink swapped in after the check serve content from outside the root.
    return File(canonicalFilePath).readAsStringSync();
  } on FileSystemException {
    return null;
  }
}
