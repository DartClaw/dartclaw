part of 'workflow_git_support.dart';

typedef _WorkflowGitTree = ({String revision, String tree, String? worktree});

Future<String> _resolveCommit(String projectDir, String ref) =>
    _readGit(projectDir, ['rev-parse', '--verify', '--end-of-options', '$ref^{commit}']);

Future<String> _readGit(
  String projectDir,
  List<String> args, {
  ProcessEnvironmentPlan plan = const EmptyProcessEnvironmentPlan(),
}) async {
  final result = await runHostWorktreeGit(args, workingDirectory: projectDir, plan: plan);
  if (result.exitCode != 0) throw StateError('git ${args.first}: ${_processFailureDetail(result)}');
  return (result.stdout as String).trim();
}

Future<_WorkflowGitTree> _captureTree(String projectDir, String branch, {bool includeWorktree = true}) async {
  final revision = await _resolveCommit(projectDir, includeWorktree ? 'refs/heads/$branch' : branch);
  final worktree = includeWorktree ? await _findWorktreePathForBranch(projectDir: projectDir, branch: branch) : null;
  final tree = worktree == null
      ? await _readGit(projectDir, ['rev-parse', '$revision^{tree}'])
      : await _previewTree(worktree);
  return (revision: revision, tree: tree, worktree: worktree);
}

Future<String> _previewTree(String worktree) async {
  final indexPath = await _readGit(worktree, ['rev-parse', '--path-format=absolute', '--git-path', 'index']);
  final scratch = await Directory.systemTemp.createTemp('dartclaw-workflow-index-');
  try {
    final previewIndex = p.join(scratch.path, 'index');
    await File(indexPath).copy(previewIndex);
    final plan = InlineProcessEnvironmentPlan({'GIT_INDEX_FILE': previewIndex});
    if ((await _readGit(worktree, ['rev-parse', '--shared-index-path'], plan: plan)).isNotEmpty) {
      throw StateError(
        'Workflow review cannot preview a split index in "$worktree". Run git update-index --no-split-index.',
      );
    }
    // Approval binds the tree the sweep stages, so the preview runs the same
    // configured filters; filter definitions are operator trust.
    const safeConfig = ['-c', 'core.splitIndex=false'];
    await _readGit(worktree, [...safeConfig, 'add', '-A'], plan: plan);
    return await _readGit(worktree, [...safeConfig, 'write-tree'], plan: plan);
  } finally {
    await scratch.delete(recursive: true);
  }
}

class _WorkflowGitCandidate {
  final String identity;
  final _WorkflowGitTree source;
  final _WorkflowGitTree base;
  final List<String> protectedPaths;

  const new(this.identity, this.source, this.base, this.protectedPaths);

  bool requiresApproval(String? approvedCandidate) => protectedPaths.isNotEmpty && identity != approvedCandidate;
}

Future<_WorkflowGitCandidate> _inspectCandidate({
  required String projectDir,
  required String branch,
  required String baseRef,
  required List<String?> operation,
  bool sweepBase = false,
}) async {
  final source = await _captureTree(projectDir, branch);
  final base = await _captureTree(projectDir, baseRef, includeWorktree: sweepBase);
  final protectedPaths = <String>{
    ...await executionSurfacePaths(
      worktreePath: projectDir,
      baseRef: base.revision,
      branch: source.revision,
      includeWorktree: false,
    ),
    for (final candidate in [source, if (sweepBase) base])
      ...await executionSurfacePaths(
        worktreePath: projectDir,
        baseRef: candidate.revision,
        branch: candidate.tree,
        includeWorktree: false,
        fromMergeBase: false,
      ),
  }.toList()..sort();
  final identity = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            _repoLockKey(projectDir),
            branch,
            baseRef,
            ...operation,
            source.revision,
            source.tree,
            base.revision,
            base.tree,
          ]),
        ),
      )
      .toString();
  return _WorkflowGitCandidate(identity, source, base, protectedPaths);
}

Future<String> _sweepCandidateTree({
  required String projectDir,
  required String branch,
  required _WorkflowGitTree candidate,
  required String commitMessage,
}) async {
  final branchRef = 'refs/heads/$branch';
  if (await _resolveCommit(projectDir, branchRef) != candidate.revision) {
    throw StateError('Workflow branch "$branch" changed after inspection. Retry to review its current changes.');
  }
  await commitWorkflowWorktreeChangesIfNeeded(
    projectDir: projectDir,
    branch: branch,
    commitMessage: commitMessage,
    expectedTree: candidate.tree,
  );
  final revision = await _resolveCommit(projectDir, branchRef);
  final commit = (await _readGit(projectDir, ['show', '-s', '--format=%T %P', revision])).split(' ');
  if (commit.first != candidate.tree ||
      (revision != candidate.revision && (commit.length != 2 || commit[1] != candidate.revision))) {
    throw StateError('Workflow branch "$branch" changed after inspection. Retry to review its current changes.');
  }
  return revision;
}
