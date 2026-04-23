import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';

import 'git_credential_env.dart';

typedef GitStatusRunner =
    Future<ProcessResult> Function(List<String> args, {required String workingDirectory, bool noSystemConfig});

/// Snapshot of a worktree's porcelain git status.
final class GitStatusSnapshot {
  final Set<String> entries;

  const GitStatusSnapshot(this.entries);
}

sealed class ReadOnlyEvaluation {
  const ReadOnlyEvaluation();
}

final class ReadOnlyClean extends ReadOnlyEvaluation {
  const ReadOnlyClean();
}

final class ReadOnlyViolation extends ReadOnlyEvaluation {
  final List<String> mutatedPaths;

  const ReadOnlyViolation(this.mutatedPaths);
}

/// Detects project mutations that occurred during a read-only task turn.
final class TaskReadOnlyGuard {
  TaskReadOnlyGuard({required this.worktreePath, GitStatusRunner? git, this.noSystemConfig = false, Logger? log})
    : _git = git ?? _defaultGit,
      _log = log ?? Logger('TaskReadOnlyGuard');

  final String worktreePath;
  final GitStatusRunner _git;
  final bool noSystemConfig;
  final Logger _log;

  Future<GitStatusSnapshot> baseline() => snapshot();

  Future<GitStatusSnapshot> snapshot() async {
    final result = await _git(
      const ['status', '--porcelain=v1', '-z', '--untracked-files=all'],
      workingDirectory: worktreePath,
      noSystemConfig: noSystemConfig,
    );
    if (result.exitCode != 0) {
      throw StateError('git status failed in "$worktreePath": ${result.stderr}');
    }
    return GitStatusSnapshot(_parseStatusEntries(result.stdout as String));
  }

  ReadOnlyEvaluation evaluate(GitStatusSnapshot before, GitStatusSnapshot after) {
    final addedEntries = after.entries.difference(before.entries).toList()..sort();
    if (addedEntries.isEmpty) {
      return const ReadOnlyClean();
    }
    final paths = addedEntries.map(_statusEntryPath).toSet().toList()..sort();
    return ReadOnlyViolation(paths);
  }

  Future<String?> mutationSummary(GitStatusSnapshot before) async {
    try {
      final evaluation = evaluate(before, await snapshot());
      return switch (evaluation) {
        ReadOnlyClean() => null,
        ReadOnlyViolation(:final mutatedPaths) => _summary(mutatedPaths),
      };
    } catch (error) {
      _log.fine('Skipping read-only mutation check for "$worktreePath" because git status failed: $error');
      return null;
    }
  }

  static Set<String> _parseStatusEntries(String stdout) {
    if (stdout.isEmpty) return <String>{};
    final parts = stdout.split('\u0000');
    final entries = <String>{};
    for (var i = 0; i < parts.length; i++) {
      final entry = parts[i];
      if (entry.isEmpty) continue;
      entries.add(entry);
      if (_isRenameOrCopy(entry) && i + 1 < parts.length) {
        i++;
      }
    }
    return entries;
  }

  static bool _isRenameOrCopy(String entry) {
    if (entry.length < 2) return false;
    return entry[0] == 'R' || entry[1] == 'R' || entry[0] == 'C' || entry[1] == 'C';
  }

  static String _statusEntryPath(String entry) {
    if (entry.length <= 3) return entry.trim();
    return entry.substring(3).trim();
  }

  static String _summary(List<String> mutatedPaths) {
    final preview = mutatedPaths.take(6).join(', ');
    final remaining = mutatedPaths.length - 6;
    final suffix = remaining > 0 ? ' (+$remaining more)' : '';
    return 'Read-only task modified project files: $preview$suffix';
  }

  static Future<ProcessResult> _defaultGit(
    List<String> args, {
    required String workingDirectory,
    bool noSystemConfig = false,
  }) {
    return SafeProcess.git(
      args,
      plan: const GitCredentialPlan.none(),
      workingDirectory: workingDirectory,
      noSystemConfig: noSystemConfig,
    );
  }
}
