import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Real-git fixture for component-level tests of the workflow promotion pipeline.
///
/// Spins up a temp directory with an initialized git repository, an integration
/// branch checked out at the project root (inline mode, matching how the
/// workflow engine operates when a user runs against a repo that is not a
/// dedicated worktree), and on-demand story branches with their own worktrees.
///
/// Tests drive `promoteWorkflowBranchLocally` / `commitWorkflowWorktreeChangesIfNeeded`
/// directly against the fixture's paths to exercise the merge / worktree /
/// artifact-committer plumbing without a real agent harness.
class WorkflowGitFixture {
  WorkflowGitFixture._({
    required this.tempRoot,
    required this.projectDir,
    required this.runId,
    required this.integrationBranch,
  });

  /// Temp directory holding the fixture. Deleted on [dispose].
  final Directory tempRoot;

  /// Absolute path to the git repository. Integration branch is checked out
  /// here (inline mode).
  final String projectDir;

  /// Synthetic workflow run identifier, used to namespace branch names.
  final String runId;

  /// Integration branch checked out at [projectDir].
  final String integrationBranch;

  /// Story branch -> worktree path, populated by [createStoryBranch].
  final Map<String, String> _storyWorktrees = {};

  static const _env = {
    'GIT_AUTHOR_NAME': 'Component Test',
    'GIT_AUTHOR_EMAIL': 'component@test.local',
    'GIT_COMMITTER_NAME': 'Component Test',
    'GIT_COMMITTER_EMAIL': 'component@test.local',
    // Avoid picking up a global template that might install hooks.
    'GIT_TEMPLATE_DIR': '',
  };

  /// Creates a fixture with an initialized repo and an integration branch
  /// checked out inline at the project root.
  ///
  /// - [runId] namespaces branch names (defaults to `run-fixture`).
  /// - [integrationBranch] overrides the default
  ///   `dartclaw/workflow/<runId>/integration` branch name.
  /// - [seedFiles] (relPath -> contents) is committed to the integration branch
  ///   before the fixture is returned. Always includes `README.md` unless
  ///   explicitly overridden.
  /// - [gitAttributes], if provided, is written to `.gitattributes` on the
  ///   integration branch before any story branches are created. Used for
  ///   tests that exercise `merge=union` behavior on append-only docs.
  static Future<WorkflowGitFixture> create({
    String runId = 'run-fixture',
    String? integrationBranch,
    Map<String, String>? seedFiles,
    String? gitAttributes,
  }) async {
    final tempRoot = Directory.systemTemp.createTempSync('dartclaw_wf_component_');
    final projectDir = p.join(tempRoot.path, 'project');
    Directory(projectDir).createSync(recursive: true);

    await _run('git', ['init', '-b', 'main'], cwd: projectDir);
    // Disable commit signing and any noise that would fail in CI.
    await _run('git', ['config', 'commit.gpgsign', 'false'], cwd: projectDir);
    await _run('git', ['config', 'tag.gpgsign', 'false'], cwd: projectDir);
    await _run('git', ['config', 'user.name', 'Component Test'], cwd: projectDir);
    await _run('git', ['config', 'user.email', 'component@test.local'], cwd: projectDir);

    final initialFiles = <String, String>{'README.md': 'fixture\n', ...?seedFiles};
    for (final entry in initialFiles.entries) {
      final file = File(p.join(projectDir, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    await _run('git', ['add', '-A'], cwd: projectDir);
    await _commit(projectDir, 'init');

    final branch = integrationBranch ?? 'dartclaw/workflow/$runId/integration';
    await _run('git', ['checkout', '-b', branch], cwd: projectDir);

    if (gitAttributes != null) {
      File(p.join(projectDir, '.gitattributes')).writeAsStringSync(gitAttributes);
      await _run('git', ['add', '.gitattributes'], cwd: projectDir);
      await _commit(projectDir, 'add .gitattributes');
    }

    return WorkflowGitFixture._(tempRoot: tempRoot, projectDir: projectDir, runId: runId, integrationBranch: branch);
  }

  /// Creates a story branch off the current integration tip and a dedicated
  /// worktree checked out on that branch.
  ///
  /// - [committedFiles] (optional) are written and committed on the story
  ///   branch before returning.
  /// - [uncommittedFiles] (optional) are left as uncommitted modifications in
  ///   the worktree, to exercise the "skill wrote sibling files" pre-promotion
  ///   state.
  ///
  /// Returns the absolute worktree path.
  Future<String> createStoryBranch(
    String storyId, {
    String? branchName,
    Map<String, String>? committedFiles,
    Map<String, String>? uncommittedFiles,
  }) async {
    final branch = branchName ?? 'dartclaw/workflow/$runId/story-$storyId';
    final worktreePath = p.join(tempRoot.path, 'worktrees', 'story-$storyId');
    await _run('git', ['worktree', 'add', '-b', branch, worktreePath, integrationBranch], cwd: projectDir);

    if (committedFiles != null && committedFiles.isNotEmpty) {
      for (final entry in committedFiles.entries) {
        final file = File(p.join(worktreePath, entry.key));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
      }
      await _run('git', ['add', '-A'], cwd: worktreePath);
      await _commit(worktreePath, 'story $storyId initial commit');
    }

    if (uncommittedFiles != null && uncommittedFiles.isNotEmpty) {
      for (final entry in uncommittedFiles.entries) {
        final file = File(p.join(worktreePath, entry.key));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
      }
    }

    _storyWorktrees[storyId] = worktreePath;
    return worktreePath;
  }

  /// Worktree path for a previously-created story branch.
  String worktreeFor(String storyId) {
    final path = _storyWorktrees[storyId];
    if (path == null) {
      throw StateError('No worktree created for story "$storyId"');
    }
    return path;
  }

  /// Branch name for a story.
  String storyBranch(String storyId) => 'dartclaw/workflow/$runId/story-$storyId';

  /// Writes files into the integration worktree without committing. Useful for
  /// modelling "skill wrote sibling files outside declared outputs" state.
  void writeUncommittedIntegrationFiles(Map<String, String> files) => _writeFiles(projectDir, files);

  /// Writes files into a story worktree without committing.
  void writeUncommittedStoryFiles(String storyId, Map<String, String> files) =>
      _writeFiles(worktreeFor(storyId), files);

  /// Stages and commits whatever is currently dirty in a worktree.
  Future<void> commitAll({required String worktreePath, required String message}) async {
    await _run('git', ['add', '-A'], cwd: worktreePath);
    await _commit(worktreePath, message);
  }

  /// Current sha of the named branch, as reported by `git rev-parse`.
  Future<String> branchSha(String branch) async {
    final result = await _run('git', ['rev-parse', branch], cwd: projectDir, expectSuccess: true);
    return (result.stdout as String).trim();
  }

  /// Raw `git log` on a branch — handy for inspecting sweep commits,
  /// merge commits, etc. Returns one subject per line, newest first.
  Future<List<String>> logSubjects(String branch, {int max = 20}) async {
    final result = await _run('git', ['log', '--pretty=%s', '-n$max', branch], cwd: projectDir, expectSuccess: true);
    return (result.stdout as String).split('\n').where((line) => line.isNotEmpty).toList(growable: false);
  }

  /// Returns true if the given branch has a worktree checked out (visible via
  /// `git worktree list --porcelain`).
  Future<bool> hasWorktreeFor(String branch) async {
    final result = await _run('git', ['worktree', 'list', '--porcelain'], cwd: projectDir, expectSuccess: true);
    final target = 'refs/heads/$branch';
    for (final line in (result.stdout as String).split('\n')) {
      if (line.trim() == 'branch $target') return true;
    }
    return false;
  }

  /// Escape hatch for arbitrary git inspection in tests.
  Future<ProcessResult> rawGit(List<String> args, {String? inDir}) => _run('git', args, cwd: inDir ?? projectDir);

  Future<void> dispose() async {
    // Best-effort worktree teardown so git's metadata stays consistent when
    // the temp dir is removed out from under it.
    for (final worktree in _storyWorktrees.values) {
      await _run('git', ['worktree', 'remove', '--force', worktree], cwd: projectDir);
    }
    try {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Test teardown — worktree metadata may have already released the dirs.
    }
  }

  static void _writeFiles(String dir, Map<String, String> files) {
    for (final entry in files.entries) {
      final file = File(p.join(dir, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
  }

  static Future<ProcessResult> _run(
    String executable,
    List<String> args, {
    required String cwd,
    bool expectSuccess = false,
  }) async {
    final result = await Process.run(executable, args, workingDirectory: cwd, environment: _env);
    if (expectSuccess && result.exitCode != 0) {
      throw StateError(
        '$executable ${args.join(' ')} failed in $cwd (exit ${result.exitCode}): '
        '${(result.stderr as String).trim()}',
      );
    }
    return result;
  }

  static Future<void> _commit(String cwd, String message) async {
    final result = await Process.run(
      'git',
      ['commit', '-m', message, '--no-gpg-sign'],
      workingDirectory: cwd,
      environment: _env,
    );
    if (result.exitCode != 0) {
      final combined = '${result.stdout}\n${result.stderr}';
      if (combined.contains('nothing to commit')) return;
      throw StateError(
        'git commit failed in $cwd (exit ${result.exitCode}): '
        '${(result.stderr as String).trim()}',
      );
    }
  }
}
