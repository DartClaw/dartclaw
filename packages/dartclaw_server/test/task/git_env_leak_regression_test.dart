import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('git env leak regression', () {
    late Directory tempDir;
    late Directory repoDir;
    late File sentinelFile;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('dartclaw_git_env_leak_');
      repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);
      sentinelFile = File(p.join(tempDir.path, 'sentinel.txt'));

      await _git(repoDir.path, ['init']);
      await _git(repoDir.path, ['remote', 'add', 'origin', 'ssh://example.com/repo.git']);
      await _git(repoDir.path, [
        'config',
        'core.sshCommand',
        "/bin/sh -c 'printf \"%s\" \"\${ANTHROPIC_API_KEY:-empty}\" > \"${sentinelFile.path}\"; exit 1' --",
      ]);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('SafeProcess.git does not leak parent API keys into repo-controlled sshCommand', () async {
      final result = await SafeProcess.git(
        ['fetch', 'origin'],
        plan: const GitCredentialPlan.none(),
        workingDirectory: repoDir.path,
        baseEnvironment: {
          'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
          'HOME': tempDir.path,
          'LANG': 'en_US.UTF-8',
          'ANTHROPIC_API_KEY': 'leak-canary',
        },
      );

      expect(result.exitCode, isNonZero);
      expect(sentinelFile.readAsStringSync(), 'empty');
    });
  });
}

Future<ProcessResult> _git(String workingDirectory, List<String> arguments) {
  return Process.run('git', arguments, workingDirectory: workingDirectory);
}
