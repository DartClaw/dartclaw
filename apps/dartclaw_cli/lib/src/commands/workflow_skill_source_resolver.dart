import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the built-in workflow skills source tree.
class WorkflowSkillSourceResolver {
  const WorkflowSkillSourceResolver._();

  /// Finds `packages/dartclaw_workflow/skills` in source checkouts and
  /// deterministic installed layouts.
  ///
  /// Trust assumption: the candidate roots (`Platform.script`,
  /// `Platform.resolvedExecutable`, `Directory.current`) and the path from
  /// each up to the filesystem root are operator-controlled. A crafted
  /// `data/skills/` or `packages/dartclaw_workflow/skills/` directory
  /// anywhere on those paths would be picked up. This is acceptable for
  /// the current threat model (DartClaw runs against operator CWDs); if
  /// that widens, anchor resolution to `Isolate.resolvePackageUri` and
  /// drop the upward filesystem walk.
  static String? resolveBuiltInSkillsSourceDir() {
    final candidateRoots = <String>{};

    if (Platform.script.scheme == 'file') {
      candidateRoots.add(p.dirname(Platform.script.toFilePath()));
    }
    candidateRoots.add(p.dirname(Platform.resolvedExecutable));
    candidateRoots.add(Directory.current.path);

    for (final root in candidateRoots) {
      final resolved = _searchUpwardsForSkills(root);
      if (resolved != null) return resolved;
    }

    return null;
  }

  static String? _searchUpwardsForSkills(String startDir) {
    var current = p.normalize(startDir);
    while (true) {
      for (final relative in const [
        ['packages', 'dartclaw_workflow', 'skills'],
        ['data', 'skills'],
      ]) {
        final candidate = p.joinAll([current, ...relative]);
        if (Directory(candidate).existsSync()) return candidate;
      }

      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return null;
  }
}
