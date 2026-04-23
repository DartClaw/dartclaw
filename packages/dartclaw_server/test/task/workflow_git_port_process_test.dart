import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowGitPortProcess;
import 'package:test/test.dart';

void main() {
  group('WorkflowGitPortProcess', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workflow_git_port_process_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('replays artifact commit add/diff/commit sequence', () async {
      await _git(tempDir.path, ['init', '-q']);
      File('${tempDir.path}/plan.md').writeAsStringSync('plan');

      final port = WorkflowGitPortProcess();

      await port.add(tempDir.path, ['plan.md']);
      expect(await port.diffNameOnly(tempDir.path, cached: true), ['plan.md']);

      final commit = await port.commit(
        tempDir.path,
        message: 'chore(workflow): artifacts',
        authorName: 'DartClaw Workflow',
        authorEmail: 'workflow@dartclaw.local',
      );

      expect(commit.sha, isNotEmpty);
      expect(await port.pathExistsAtRef(tempDir.path, ref: 'HEAD', path: 'plan.md'), isTrue);
      expect(await port.diffNameOnly(tempDir.path, cached: true), isEmpty);
    });
  });
}

Future<void> _git(String workingDirectory, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed: ${result.stderr}');
  }
}
