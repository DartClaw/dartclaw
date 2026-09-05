// Fitness function: no raw git Process.run/Process.start in production code.
//
// What this enforces:
//   Production code under packages/<X>/lib/ and apps/<X>/lib/ must not call
//   `Process.run('git', ...)` or `Process.start('git', ...)` directly.
//   All git subprocess invocations must go through `SafeProcess.git(...)`.
//   The canonical implementation (safe_process.dart) is the only allowed site.
//
// Why:
//   Raw git subprocesses bypass SafeProcess's environment isolation (credential
//   stripping, path sanitization). This fitness test freezes the post-S47
//   baseline where zero production files invoke git directly, acting as a
//   regression guard.
//
// How to resolve a failure:
//   Replace `await Process.run('git', args)` / `Process.start('git', args)`
//   with `await runGit(args, workingDirectory: ...)` from
//   `package:dartclaw_kernel/dartclaw_kernel.dart` — the second gate below
//   forbids reaching for `SafeProcess.git` directly.
//   If the call site genuinely must spawn git directly (e.g. a new canonical
//   wrapper), add an entry to `allowlist/safe_process_raw_git.txt` with format
//   `<relative-path>  # <rationale>`. It waives this gate only.
//
// Second gate: one git-runner seam.
//
// What this enforces:
//   Production code must reach git through `runGit(...)` from
//   `package:dartclaw_kernel/dartclaw_kernel.dart`, not through
//   `SafeProcess.git` directly. Only the canonical runner
//   (`process/git_runner.dart`) may call it.
//
// Why:
//   `GIT_CONFIG_NOSYSTEM` is a security-relevant spawn policy. With one owner
//   the safe posture is the default and every opt-out is enumerable; with one
//   copy per call site the policy drifts invisibly — which is how the
//   task-accept path staged and committed with system hooks in band until
//   0.24.2.
//
// How to resolve a failure:
//   Route the call through `runGit(args, workingDirectory: ..., plan: ...,
//   noSystemConfig: ...)`. If the file genuinely is a new canonical runner,
//   add it to `allowlist/safe_process_git_seam.txt` with a rationale.
//
// The two gates hold separate allowlists on purpose. One shared list meant a
// rationale written for a raw spawn also excused the seam call in the same
// file, and the reverse — each gate asks a different question, so each carries
// its own answers.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _rawGitAllowlistName = 'safe_process_raw_git.txt';
const _gitSeamAllowlistName = 'safe_process_git_seam.txt';

void main() {
  late Allowlist rawGitAllowlist;
  late Allowlist gitSeamAllowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    rawGitAllowlist = readAllowlist(repoRoot, _rawGitAllowlistName);
    gitSeamAllowlist = readAllowlist(repoRoot, _gitSeamAllowlistName);
  });

  // A stale entry guards nothing; fail the gate that owns it rather than pass quietly.
  tearDownAll(() {
    rawGitAllowlist.assertNoStaleEntries();
    gitSeamAllowlist.assertNoStaleEntries();
  });

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, _rawGitAllowlistName), entryFormat: '<relative-path>');
    assertAllowlistFormat(allowlistFile(repoRoot, _gitSeamAllowlistName), entryFormat: '<relative-path>');
  });

  test('no raw git Process.run/Process.start in production code', () {
    final violations = <String>[];
    final rawGitPattern = RegExp(r'''Process\.(run|start)\s*\(\s*['"]git''');

    for (final baseDir in ['packages', 'apps']) {
      final dir = Directory('$repoRoot/$baseDir');
      if (!dir.existsSync()) continue;
      for (final pkg in dir.listSync().whereType<Directory>()) {
        final libDir = Directory('${pkg.path}/lib');
        if (!libDir.existsSync()) continue;
        for (final file in libDir.listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;

          final relativePath = relativeTo(file.path, repoRoot);
          final lines = file.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            if (rawGitPattern.hasMatch(lines[i])) {
              // Consulted only on a real spawn site, so an entry for a file that
              // no longer spawns reads as stale instead of silent.
              if (rawGitAllowlist.containsKey(relativePath)) continue;
              violations.add(
                '$relativePath:${i + 1}: raw git Process.run/start — '
                'use SafeProcess.git instead (see $fitnessReadmePath)',
              );
            }
          }
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'Raw git subprocess violations (see $fitnessReadmePath):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });

  test('SafeProcess.git is only called from the canonical git runner', () {
    final violations = <String>[];
    final directGitPattern = RegExp(r'SafeProcess\.git\s*\(');

    for (final file in productionDartFiles(repoRoot)) {
      final relativePath = relativeTo(file.path, repoRoot);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (directGitPattern.hasMatch(lines[i])) {
          if (gitSeamAllowlist.containsKey(relativePath)) continue;
          violations.add(
            '$relativePath:${i + 1}: direct SafeProcess.git call — '
            'route it through runGit from package:dartclaw_kernel (see $fitnessReadmePath)',
          );
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'Git runner seam violations (see $fitnessReadmePath):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}
