import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;

import 'worktree_manager.dart' show WorktreeException;

const hostWorktreeGitOptions = ['-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false'];

/// Thrown when host Git refuses an agent worktree whose Git location no longer
/// matches what the project recorded for it.
final class TamperedWorktreeException implements Exception {
  final String worktreePath;
  final String reason;

  const new(this.worktreePath, this.reason);

  @override
  String toString() => 'Refusing host Git in tampered worktree "$worktreePath": $reason';
}

/// Host-owned Git location of a checkout: pass [gitDir] and [workTree]
/// explicitly so Git never resolves them from the checkout's own `.git`.
typedef HostWorktreeLocation = ({String gitDir, String workTree});

/// Runs host Git in [projectDir], or with [worktreePath] in that checkout of
/// the project's repository.
///
/// A [worktreePath] other than [projectDir] runs with `--git-dir` and
/// `--work-tree` from [resolveHostWorktree], so the worktree's `.git` file never
/// chooses the config, attributes or hooks Git reads. Before the requested Git
/// command runs this throws [TamperedWorktreeException] when the worktree fails
/// [resolveHostWorktree], or when a gitlink in its index (the one [plan]
/// selects) holds a nested repository, whose own config Git would run when it
/// checks that repository for changes. [runner] receives every invocation.
Future<ProcessResult> runHostWorktreeGit(
  List<String> args, {
  required String projectDir,
  String? worktreePath,
  ProcessEnvironmentPlan plan = const EmptyProcessEnvironmentPlan(),
  bool noSystemConfig = true,
  GitRunner runner = runGit,
}) async {
  if (worktreePath == null || _sameHeldPath(projectDir, worktreePath)) {
    return runner(
      [...hostWorktreeGitOptions, ...args],
      workingDirectory: projectDir,
      plan: plan,
      noSystemConfig: noSystemConfig,
    );
  }
  final location = await resolveHostWorktree(projectDir: projectDir, worktreePath: worktreePath, runner: runner);
  final explicit = [...hostWorktreeGitOptions, '--git-dir=${location.gitDir}', '--work-tree=${location.workTree}'];
  final index = await runner(
    [...explicit, 'ls-files', '--stage', '-z'],
    workingDirectory: location.workTree,
    plan: plan,
    noSystemConfig: noSystemConfig,
  );
  if (index.exitCode != 0) return index;
  final nested = _populatedGitlink(location.workTree, index.stdout as String);
  if (nested != null) {
    throw TamperedWorktreeException(worktreePath, 'gitlink "$nested" holds a nested repository');
  }
  return runner(
    [...explicit, ...args],
    workingDirectory: location.workTree,
    plan: plan,
    noSystemConfig: noSystemConfig,
  );
}

/// The absolute, symlink-resolved common dir of [projectDir]'s repository.
///
/// Git runs in [projectDir] only; throws [WorktreeException] when it cannot
/// answer.
Future<String> resolveHostGitCommonDir(String projectDir, {GitRunner runner = runGit}) async {
  final result = await runner([
    ...hostWorktreeGitOptions,
    'rev-parse',
    '--path-format=absolute',
    '--git-common-dir',
  ], workingDirectory: projectDir);
  final raw = (result.stdout as String).trim();
  final commonDir = result.exitCode == 0 && raw.isNotEmpty ? _canonicalDirectory(raw) : null;
  if (commonDir == null) {
    throw WorktreeException(
      'Failed to resolve the Git common dir of "$projectDir"',
      gitStderr: (result.stderr as String).trim(),
      exitCode: result.exitCode,
    );
  }
  return commonDir;
}

/// Resolves [worktreePath] against the records of [projectDir]'s repository.
///
/// A linked worktree's gitdir is the `<common>/worktrees/<id>` record whose
/// `gitdir` file names `<worktreePath>/.git`, and the worktree's `.git` must be
/// a regular file naming that record; the main worktree's gitdir is the common
/// dir itself, which its `.git` must be. [worktreePath] must be a directory,
/// not a symlink: only its parent is resolved through the filesystem, and the
/// record and gitlink are compared as paths, never followed into the worktree.
/// A relative record or gitlink (`worktree.useRelativePaths`) is joined to its
/// own file's directory. Git runs only in [projectDir]. Throws
/// [TamperedWorktreeException] when no record matches or `.git` disagrees.
Future<HostWorktreeLocation> resolveHostWorktree({
  required String projectDir,
  required String worktreePath,
  GitRunner runner = runGit,
}) async {
  final commonDir = await resolveHostGitCommonDir(projectDir, runner: runner);
  final workTree = _heldPath(worktreePath);
  final workTreeType = workTree == null
      ? FileSystemEntityType.notFound
      : FileSystemEntity.typeSync(workTree, followLinks: false);
  if (workTreeType == FileSystemEntityType.link) {
    throw TamperedWorktreeException(worktreePath, 'the worktree directory is a symlink');
  }
  if (workTree == null || workTreeType != FileSystemEntityType.directory) {
    throw TamperedWorktreeException(worktreePath, 'the worktree directory is missing');
  }
  final dotGit = p.join(workTree, '.git');
  final dotGitType = FileSystemEntity.typeSync(dotGit, followLinks: false);

  if (p.basename(commonDir) == '.git' && p.dirname(commonDir) == workTree) {
    if (dotGitType != FileSystemEntityType.directory) {
      throw TamperedWorktreeException(worktreePath, '.git is no longer the repository directory');
    }
    return (gitDir: commonDir, workTree: workTree);
  }

  final records = <String>[];
  final recordsDir = Directory(p.join(commonDir, 'worktrees'));
  if (recordsDir.existsSync()) {
    for (final record in recordsDir.listSync(followLinks: false).whereType<Directory>()) {
      final target = _readPathFile(p.join(record.path, 'gitdir'));
      if (target != null && p.basename(target) == '.git' && p.equals(p.dirname(target), workTree)) {
        records.add(record.path);
      }
    }
  }
  if (records.length != 1) {
    throw TamperedWorktreeException(
      worktreePath,
      records.isEmpty ? 'no worktree record under "$commonDir" names it' : 'several worktree records name it',
    );
  }
  final gitDir = _canonicalDirectory(records.single)!;
  if (dotGitType != FileSystemEntityType.file) {
    throw TamperedWorktreeException(worktreePath, '.git is not the gitlink file Git wrote');
  }
  final content = File(dotGit).readAsStringSync();
  final linked = content.startsWith('gitdir: ')
      ? _resolveRelative(workTree, _stripLineEnd(content.substring(8)))
      : null;
  if (linked == null || !p.equals(linked, gitDir)) {
    throw TamperedWorktreeException(worktreePath, '.git no longer names "$gitDir"');
  }
  return (gitDir: gitDir, workTree: workTree);
}

String? _populatedGitlink(String workTree, String lsFilesStage) {
  for (final entry in lsFilesStage.split('\u0000')) {
    if (!entry.startsWith('160000 ')) continue;
    final tab = entry.indexOf('\t');
    if (tab < 0) continue;
    final path = entry.substring(tab + 1);
    final nestedGit = p.join(workTree, path, '.git');
    if (FileSystemEntity.typeSync(nestedGit, followLinks: false) != FileSystemEntityType.notFound ||
        FileSystemEntity.typeSync(nestedGit) != FileSystemEntityType.notFound) {
      return path;
    }
  }
  return null;
}

String? _readPathFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return _resolveRelative(p.dirname(path), _stripLineEnd(file.readAsStringSync()));
}

String? _resolveRelative(String base, String path) => path.isEmpty ? null : p.normalize(p.join(base, path));

String _stripLineEnd(String value) => value.replaceFirst(RegExp(r'[\r\n]+$'), '');

String? _canonicalDirectory(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
}

/// [path] with its parent symlink-resolved and its last component kept as
/// given. The parent is the host-owned worktrees root; resolving the last
/// component would follow a symlink an agent put in place of its worktree.
String? _heldPath(String path) {
  final absolute = p.normalize(p.absolute(path));
  final parent = _canonicalDirectory(p.dirname(absolute));
  return parent == null ? null : p.join(parent, p.basename(absolute));
}

bool _sameHeldPath(String a, String b) {
  final heldA = _heldPath(a);
  return heldA != null ? p.equals(heldA, _heldPath(b) ?? '') : p.equals(p.absolute(a), p.absolute(b));
}
