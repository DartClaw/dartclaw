import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task, TaskType;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

import '../helpers/factories.dart';

Task _makeTask({
  String title = 'Implement feature X',
  String description = 'Build it well.',
  String? acceptanceCriteria,
}) => Task(
  id: 'task-1',
  title: title,
  description: description,
  type: TaskType.coding,
  createdAt: DateTime.now(),
  acceptanceCriteria: acceptanceCriteria,
);

typedef _ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory});

_ProcessRunner _recordingRunner(
  List<({String executable, List<String> arguments, String? workingDirectory})> calls, {
  int exitCode = 0,
  String stdout = '',
  bool ghNotFound = false,
}) {
  return (executable, arguments, {workingDirectory}) async {
    calls.add((executable: executable, arguments: arguments, workingDirectory: workingDirectory));
    if (ghNotFound && executable == 'gh' && !arguments.contains('--version')) {
      throw ProcessException(executable, arguments, 'No such file or directory');
    }
    return ProcessResult(0, exitCode, stdout, '');
  };
}

void main() {
  group('PrCreator', () {
    test('returns PrGhNotFound when gh is not on PATH', () async {
      final creator = PrCreator(
        processRunner: (executable, arguments, {workingDirectory}) async {
          if (executable == 'gh' && arguments.contains('--version')) {
            throw ProcessException('gh', ['--version'], 'No such file');
          }
          return ProcessResult(0, 0, '', '');
        },
      );
      final result = await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git'),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );
      expect(result, isA<PrGhNotFound>());
      final notFound = result as PrGhNotFound;
      expect(notFound.instructions, contains('dartclaw/task-1'));
      expect(notFound.instructions, contains('git@github.com:u/my-app.git'));
      expect(notFound.instructions, contains('main'));
    });

    test('returns PrGhNotFound when gh --version exits non-zero', () async {
      final creator = PrCreator(
        processRunner: (executable, arguments, {workingDirectory}) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 1, '', 'command not found');
          }
          return ProcessResult(0, 0, 'https://github.com/u/r/pull/1', '');
        },
      );
      final result = await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git'),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );
      expect(result, isA<PrGhNotFound>());
    });

    test('returns PrCreated with URL parsed from stdout', () async {
      final creator = PrCreator(
        processRunner: (executable, arguments, {workingDirectory}) async {
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'gh version 2.40.0', '');
          return ProcessResult(0, 0, 'https://github.com/u/r/pull/42\n', '');
        },
      );
      final result = await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git'),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );
      expect(result, isA<PrCreated>());
      expect((result as PrCreated).url, 'https://github.com/u/r/pull/42');
    });

    test('returns PrCreationFailed when gh exits non-zero', () async {
      final creator = PrCreator(
        processRunner: (executable, arguments, {workingDirectory}) async {
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'gh version 2', '');
          return ProcessResult(
            0,
            1,
            '',
            'error: A pull request for branch "dartclaw/task-1" into "main" already exists.',
          );
        },
      );
      final result = await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git'),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );
      expect(result, isA<PrCreationFailed>());
      final failed = result as PrCreationFailed;
      expect(failed.error, contains('exit code 1'));
      expect(failed.details, contains('already exists'));
    });

    test('includes --draft flag when project.pr.draft is true', () async {
      final calls = <({String executable, List<String> arguments, String? workingDirectory})>[];
      final creator = PrCreator(processRunner: _recordingRunner(calls, stdout: 'https://github.com/u/r/pull/1'));

      await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git', pr: const PrConfig(draft: true)),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      final prCall = calls.lastWhere((c) => c.arguments.contains('create'));
      expect(prCall.arguments, contains('--draft'));
    });

    test('does not include --draft when project.pr.draft is false', () async {
      final calls = <({String executable, List<String> arguments, String? workingDirectory})>[];
      final creator = PrCreator(processRunner: _recordingRunner(calls, stdout: 'https://github.com/u/r/pull/1'));

      await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git', pr: const PrConfig(draft: false)),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      final prCall = calls.lastWhere((c) => c.arguments.contains('create'));
      expect(prCall.arguments, isNot(contains('--draft')));
    });

    test('includes --label for each label in project.pr.labels', () async {
      final calls = <({String executable, List<String> arguments, String? workingDirectory})>[];
      final creator = PrCreator(processRunner: _recordingRunner(calls, stdout: 'https://github.com/u/r/pull/1'));

      await creator.create(
        project: makeProject(
          remoteUrl: 'git@github.com:u/my-app.git',
          pr: const PrConfig(labels: ['agent', 'automated']),
        ),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      final prCall = calls.lastWhere((c) => c.arguments.contains('create'));
      final labelArgs = <String>[];
      for (var i = 0; i < prCall.arguments.length - 1; i++) {
        if (prCall.arguments[i] == '--label') {
          labelArgs.add(prCall.arguments[i + 1]);
        }
      }
      expect(labelArgs, containsAll(['agent', 'automated']));
    });

    test('builds gh pr create with --title, --body, --head, --base', () async {
      final calls = <({String executable, List<String> arguments, String? workingDirectory})>[];
      final creator = PrCreator(processRunner: _recordingRunner(calls, stdout: 'https://github.com/u/r/pull/1'));

      await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git', defaultBranch: 'develop'),
        task: _makeTask(title: 'My Task', description: 'Do the thing.'),
        branch: 'dartclaw/task-my-task',
      );

      final prCall = calls.lastWhere((c) => c.arguments.contains('create'));
      expect(prCall.arguments, containsAll(['--title', 'My Task']));
      expect(prCall.arguments, containsAll(['--head', 'dartclaw/task-my-task']));
      expect(prCall.arguments, containsAll(['--base', 'develop']));
      expect(prCall.arguments, contains('--body'));
    });

    test('uses project.localPath as working directory', () async {
      final calls = <({String executable, List<String> arguments, String? workingDirectory})>[];
      final creator = PrCreator(processRunner: _recordingRunner(calls, stdout: 'https://github.com/u/r/pull/1'));

      await creator.create(
        project: makeProject(remoteUrl: 'git@github.com:u/my-app.git', localPath: '/data/projects/my-app'),
        task: _makeTask(),
        branch: 'dartclaw/task-1',
      );

      final prCall = calls.lastWhere((c) => c.arguments.contains('create'));
      expect(prCall.workingDirectory, '/data/projects/my-app');
    });

    test('caches _ghAvailable after first check', () async {
      var versionCheckCount = 0;
      final creator = PrCreator(
        processRunner: (executable, arguments, {workingDirectory}) async {
          if (arguments.contains('--version')) versionCheckCount++;
          return ProcessResult(0, 0, 'https://github.com/u/r/pull/1', '');
        },
      );
      final project = makeProject(remoteUrl: 'git@github.com:u/my-app.git');
      final task = _makeTask();

      await creator.create(project: project, task: task, branch: 'branch-1');
      await creator.create(project: project, task: task, branch: 'branch-2');

      expect(versionCheckCount, 1);
    });

    test('PrCreationResult subtypes support exhaustive switch', () {
      PrCreationResult result = const PrCreated('https://example.com');
      final _ = switch (result) {
        PrCreated(:final url) => 'created: $url',
        PrGhNotFound(:final instructions) => 'not found: $instructions',
        PrCreationFailed(:final error, :final details) => 'failed: $error ($details)',
      };
    });
  });
}
