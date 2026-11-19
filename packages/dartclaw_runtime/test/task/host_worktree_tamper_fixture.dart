import 'dart:io';

import 'package:path/path.dart' as p;

/// Real-Git project with one linked worktree, plus the ways an agent can
/// retarget that worktree's `.git` gitlink.
///
/// Every armed command writes a marker into [root], outside the worktree, so a
/// test proves host Git ran nothing the agent chose by checking [markers].
final class HostWorktreeTamperFixture {
  final Directory root;
  final String projectDir;
  final String worktreePath;
  final String branch;

  new _(this.root, this.projectDir, this.worktreePath, this.branch);

  /// Written by an agent-chosen clean filter.
  File get filterMarker => File(p.join(root.path, 'filter-ran'));

  /// Written by an agent-chosen `diff.external` command.
  File get diffMarker => File(p.join(root.path, 'diff-ran'));

  /// Written by an agent-chosen `core.fsmonitor` command.
  File get fsmonitorMarker => File(p.join(root.path, 'fsmonitor-ran'));

  List<File> get markers => [filterMarker, diffMarker, fsmonitorMarker];

  /// Markers that exist; empty when host Git ran nothing the agent chose.
  List<String> get existingMarkers => [
    for (final marker in markers)
      if (marker.existsSync()) p.basename(marker.path),
  ];

  /// Creates `<root>/project` on `main` with one commit and a DartClaw-style
  /// worktree at `<root>/worktrees/<name>` on a new [branch].
  static Future<HostWorktreeTamperFixture> create({
    String branch = 'story',
    String worktreeName = 'task-1',
    Map<String, String> files = const {'README.md': 'fixture\n'},
  }) async {
    final temp = Directory.systemTemp.createTempSync('host_worktree_tamper_');
    final root = Directory(temp.resolveSymbolicLinksSync());
    final projectDir = p.join(root.path, 'project');
    Directory(projectDir).createSync();
    await git(projectDir, ['init', '-q', '-b', 'main']);
    await git(projectDir, ['config', 'user.email', 'fixture@example.com']);
    await git(projectDir, ['config', 'user.name', 'Fixture']);
    for (final entry in files.entries) {
      File(p.join(projectDir, entry.key))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
    await git(projectDir, ['add', '-A']);
    await git(projectDir, ['commit', '-q', '-m', 'init']);
    final worktreePath = p.join(root.path, 'worktrees', worktreeName);
    Directory(p.dirname(worktreePath)).createSync(recursive: true);
    await git(projectDir, ['worktree', 'add', '-q', '-b', branch, worktreePath, 'main']);
    return HostWorktreeTamperFixture._(root, projectDir, worktreePath, branch);
  }

  /// The admin record Git keeps for the worktree under the project's common dir.
  String get adminDir =>
      Directory(p.join(projectDir, '.git', 'worktrees', p.basename(worktreePath))).resolveSymbolicLinksSync();

  File get gitlink => File(p.join(worktreePath, '.git'));

  /// Writes [relativePath] in the worktree.
  void write(String relativePath, [String content = 'changed\n']) {
    File(p.join(worktreePath, relativePath))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// Scenario S02: the gitlink names `.evil`, an agent-built copy of the
  /// repository (its refs and an index of the worktree's branch) whose config
  /// runs commands of the agent's choosing on any Git that reads it: a clean
  /// filter on `add`, `diff.external` on `diff`, `core.fsmonitor` on `status`.
  Future<void> rewriteGitlinkToAgentGitdir() async {
    final evil = await _buildAgentGitdir('.evil');
    File(p.join(evil, 'info', 'exclude')).writeAsStringSync('.evil\n');
    gitlink.writeAsStringSync('gitdir: .evil\n');
  }

  /// Scenario S07: an agent ran `git init`, so `.git` is a directory.
  Future<void> replaceGitlinkWithRepository() async {
    gitlink.deleteSync();
    await git(worktreePath, ['init', '-q', '-b', 'main']);
    await _armConfig(p.join(worktreePath, '.git'));
    File(p.join(worktreePath, '.git', 'info', 'attributes'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('* filter=evil\n');
  }

  /// Scenario S07: `.git` is a symlink, to the genuine admin dir unless
  /// [toAgentGitdir], when it names an agent-built gitdir armed like `.evil`.
  Future<void> replaceGitlinkWithSymlink({bool toAgentGitdir = false}) async {
    final target = toAgentGitdir ? await _buildAgentGitdir('.evil-link') : adminDir;
    if (toAgentGitdir) File(p.join(target, 'info', 'exclude')).writeAsStringSync('.evil-link\n');
    gitlink.deleteSync();
    Link(gitlink.path).createSync(target);
  }

  /// Scenario S07: the gitlink is gone, so Git looking from the worktree climbs
  /// to the repository enclosing it, which the agent armed (a workspace
  /// repository above the worktrees root).
  Future<void> deleteGitlink() async {
    gitlink.deleteSync();
    final enclosing = p.dirname(worktreePath);
    await git(enclosing, ['init', '-q', '-b', 'main']);
    await _armConfig(p.join(enclosing, '.git'));
    File(p.join(enclosing, '.git', 'info', 'attributes'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('* filter=evil\n');
  }

  /// Scenario F1: the worktree directory moved away and a symlink at its path
  /// points to the project checkout, whose [operatorFile] is uncommitted work.
  void replaceWorktreeWithProjectSymlink() {
    Directory(worktreePath).renameSync('$worktreePath-moved');
    Link(worktreePath).createSync(projectDir);
    File(p.join(projectDir, operatorFile)).writeAsStringSync('operator work in progress\n');
  }

  /// Uncommitted operator work [replaceWorktreeWithProjectSymlink] leaves in
  /// the project checkout.
  static const operatorFile = 'operator-wip.txt';

  Future<String> _buildAgentGitdir(String name) async {
    final dir = p.join(worktreePath, name);
    await git(worktreePath, ['clone', '-q', '--bare', projectDir, dir]);
    await git(worktreePath, ['--git-dir=$dir', '--work-tree=$worktreePath', 'read-tree', branch]);
    await git(worktreePath, ['--git-dir=$dir', 'symbolic-ref', 'HEAD', 'refs/heads/$branch']);
    await _armConfig(dir);
    Directory(p.join(dir, 'info')).createSync(recursive: true);
    File(p.join(dir, 'info', 'attributes')).writeAsStringSync('* filter=evil\n');
    return dir;
  }

  /// Runs plain `git` in the worktree, as Git does when it trusts the
  /// worktree's own `.git`; never fails, so a positive control sees what ran.
  Future<ProcessResult> plainGit(List<String> args) => Process.run('git', args, workingDirectory: worktreePath);

  /// Scenario S09: an agent-built repository at `sub`, recorded on [branch] as
  /// a gitlink, whose config runs a clean filter and `diff.external` on any
  /// Git process that enters it. A `.gitmodules` entry with `ignore = none`
  /// overrides any `diff.ignoreSubmodules` default the host could set.
  Future<void> nestRepository() async {
    final sub = p.join(worktreePath, 'sub');
    Directory(sub).createSync();
    await git(sub, ['init', '-q', '-b', 'main']);
    File(p.join(sub, 's.txt')).writeAsStringSync('s\n');
    await git(sub, ['add', '.']);
    await git(sub, ['-c', 'user.email=a@b', '-c', 'user.name=a', 'commit', '-q', '-m', 'sub']);
    await git(worktreePath, ['add', 'sub']);
    write('.gitmodules', '[submodule "sub"]\n\tpath = sub\n\turl = ./sub\n\tignore = none\n');
    await git(worktreePath, ['add', '.gitmodules']);
    await git(worktreePath, ['commit', '-q', '-m', 'nest sub']);
    await _armConfig(p.join(sub, '.git'));
    File(p.join(sub, '.git', 'info', 'attributes'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('* filter=evil\n');
    // Same size and a later mtime: Git must re-hash the file through the filter.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    File(p.join(sub, 's.txt')).writeAsStringSync('t\n');
  }

  Future<void> _armConfig(String gitDir) async {
    Future<void> set(String key, String value) => git(gitDir, ['--git-dir=$gitDir', 'config', key, value]);
    await set('core.bare', 'false');
    await set('filter.evil.clean', "sh -c 'touch \"${filterMarker.path}\"; cat'");
    await set('filter.evil.smudge', 'cat');
    await set('diff.external', "sh -c 'touch \"${diffMarker.path}\"'");
    await set('core.fsmonitor', "sh -c 'touch \"${fsmonitorMarker.path}\"'");
  }

  Future<void> dispose() async {
    if (root.existsSync()) await root.delete(recursive: true);
  }

  /// Runs fixture-side Git (never the code under test) and fails loudly.
  static Future<ProcessResult> git(String workingDirectory, List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw StateError('fixture git ${args.join(' ')} failed in $workingDirectory: ${result.stderr}');
    }
    return result;
  }
}
