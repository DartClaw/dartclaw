import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('runGit', () {
    late Directory tempDir;
    late String repoPath;
    late File sentinel;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('dartclaw_git_runner_');
      repoPath = p.join(tempDir.path, 'repo');
      Directory(repoPath).createSync(recursive: true);
      sentinel = File(p.join(tempDir.path, 'sentinel.txt'));

      await Process.run('git', ['init'], workingDirectory: repoPath);
      final hookPath = p.join(repoPath, '.git', 'hooks', 'pre-commit');
      File(hookPath).writeAsStringSync(
        '#!/bin/sh\n'
        'printf "%s|%s" "\${GIT_CONFIG_NOSYSTEM:-unset}" "\${GIT_ASKPASS:-unset}" > "${sentinel.path}"\n',
      );
      await Process.run('chmod', ['+x', hookPath]);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// Commits through [runGit] so the pre-commit hook records the environment
    /// the git child actually observed.
    Future<ProcessResult> commitThroughRunGit({bool? noSystemConfig}) {
      const args = [
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.com',
        'commit',
        '--allow-empty',
        '--no-gpg-sign',
        '-m',
        'sentinel',
      ];
      return noSystemConfig == null
          ? runGit(args, workingDirectory: repoPath)
          : runGit(args, workingDirectory: repoPath, noSystemConfig: noSystemConfig);
    }

    test('omitting plan and noSystemConfig neutralizes system git config and overlays no credentials', () async {
      final result = await commitThroughRunGit();

      expect(result.exitCode, 0, reason: (result.stderr as String));
      expect(
        sentinel.readAsStringSync(),
        '1|unset',
        reason: 'the safe posture must be what omission yields, with no credential overlay',
      );
    });

    test('noSystemConfig: false leaves GIT_CONFIG_NOSYSTEM unset in the git child', () async {
      final result = await commitThroughRunGit(noSystemConfig: false);

      expect(result.exitCode, 0, reason: (result.stderr as String));
      expect(sentinel.readAsStringSync(), 'unset|unset');
    });

    test('plan environment reaches the git child', () async {
      final result = await runGit(
        const [
          '-c',
          'user.name=Test',
          '-c',
          'user.email=test@example.com',
          'commit',
          '--allow-empty',
          '--no-gpg-sign',
          '-m',
          'sentinel',
        ],
        workingDirectory: repoPath,
        plan: const InlineProcessEnvironmentPlan({'GIT_ASKPASS': '/tmp/askpass'}),
      );

      expect(result.exitCode, 0, reason: (result.stderr as String));
      expect(sentinel.readAsStringSync(), '1|/tmp/askpass');
    });
  });
}
