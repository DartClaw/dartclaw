import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'diff_generator.dart';

const _files = {'.mcp.json', '.envrc', '.vscode/tasks.json', '.vscode/settings.json', 'mise.toml'};
const _directories = ['.claude/', '.codex/', '.husky/', '.githooks/', '.github/workflows/'];

const executionSurfaceHoldKey = '_executionSurfaceHold';

bool _listed(String path) {
  final normalized = path.toLowerCase();
  return _files.contains(normalized) || _directories.any(normalized.startsWith);
}

/// Execution-surface paths [branch] changes against [baseRef] in [projectDir]'s
/// repository, plus the uncommitted changes in [worktreePath] when given.
Future<List<String>> executionSurfacePaths({
  required String projectDir,
  String? worktreePath,
  required String baseRef,
  required String branch,
  GitRunner? processRunner,
  bool fromMergeBase = true,
}) async {
  final changes = await DiffGenerator(
    projectDir: projectDir,
    processRunner: processRunner,
  ).changes(baseRef: baseRef, branch: branch, worktreePath: worktreePath, fromMergeBase: fromMergeBase);
  return {
    for (final change in changes) ...[
      if (_listed(change.path) || change.isSymlink) change.path,
      if (change.status == DiffFileStatus.renamed)
        if (change.oldPath case final path? when _listed(path)) path,
    ],
  }.toList()..sort();
}

Future<String> executionSurfaceBaseRef({
  required String projectDir,
  required String defaultBranch,
  GitRunner? processRunner,
}) async {
  final result = await (processRunner ?? runGit)([
    'rev-parse',
    '--verify',
    'origin/$defaultBranch',
  ], workingDirectory: projectDir);
  return result.exitCode == 0 ? 'origin/$defaultBranch' : defaultBranch;
}

List<String> executionSurfaceHeldPaths(Map<String, dynamic> config) {
  final hold = config[executionSurfaceHoldKey];
  if (hold is! Map) return const [];
  return (hold['paths'] as List?)?.cast<String>() ?? const [];
}
