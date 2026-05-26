// Shared path helpers for workflow tests.
//
// Walks the directory tree to locate fixtures and sources regardless of
// the working directory when `dart test` is invoked (package root, repo
// root, or via `pub run`).
import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the canonical path to the workflow test fixtures directory.
///
/// Walks up from [Directory.current] looking for `test/fixtures` or the
/// monorepo variant `packages/dartclaw_workflow/test/fixtures`.
/// Throws [StateError] if neither is found.
String workflowFixturesRoot() => findAncestorDir(['test/fixtures', 'packages/dartclaw_workflow/test/fixtures']);

/// Resolves the canonical path to the built-in workflow definitions directory.
///
/// Walks up from [Directory.current] looking for
/// `lib/src/workflow/definitions` or the monorepo variant under
/// `packages/dartclaw_workflow/`.
/// Throws [StateError] if neither is found.
String workflowDefinitionsDir() =>
    findAncestorDir(['lib/src/workflow/definitions', 'packages/dartclaw_workflow/lib/src/workflow/definitions']);

/// Returns `true` when the `codex` binary is on PATH and exits cleanly.
Future<bool> codexAvailable() async {
  try {
    final result = await Process.run('codex', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Walks up from [Directory.current] until one of [relCandidates] resolves to
/// an existing directory, then returns that resolved absolute path.
///
/// The first candidate that exists wins on each level; the first level that
/// yields a hit is returned.  Throws [StateError] if no candidate is found
/// before the filesystem root.
String findAncestorDir(List<String> relCandidates) {
  var current = Directory.current;
  while (true) {
    for (final rel in relCandidates) {
      final candidate = Directory(p.join(current.path, rel));
      if (candidate.existsSync()) return candidate.resolveSymbolicLinksSync();
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate any of: ${relCandidates.join(', ')}');
    }
    current = parent;
  }
}
