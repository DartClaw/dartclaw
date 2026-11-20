import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show RepoLock;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show EmptyProcessEnvironmentPlan, ProcessEnvironmentPlan, runGit;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show WorkflowGitPortProcess;
import 'package:dartclaw_runtime/src/task/host_worktree_git.dart' show TamperedWorktreeException;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowGitMergeStrategy;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'host_worktree_tamper_fixture.dart';

import 'task_executor_test_support.dart' show initGitRepo;
import 'task_review_test_support.dart' show installMarkerGitHook;

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

    for (final hooksPath in ['.husky', '.githooks']) {
      test('commit runs no git hooks from $hooksPath', () async {
        final repo = await initGitRepo();
        addTearDown(() => repo.delete(recursive: true));
        final marker = await installMarkerGitHook(repo.path, hooksPath: hooksPath);
        File('${repo.path}/work.txt').writeAsStringSync('work\n');
        final port = WorkflowGitPortProcess();
        await port.add(repo.path, ['work.txt'], projectDir: repo.path);
        final commit = await port.commit(
          repo.path,
          projectDir: repo.path,
          message: 'fixture changes',
          authorName: 'Fixture',
          authorEmail: 'fixture@example.com',
        );
        expect(commit.sha, isNotEmpty);
        expect(await port.pathExistsAtRef(repo.path, projectDir: repo.path, ref: 'HEAD', path: 'work.txt'), isTrue);
        expect(marker.existsSync(), isFalse);
      });
    }

    test('replays artifact commit add/diff/commit sequence', () async {
      await _git(tempDir.path, ['init', '-q']);
      File('${tempDir.path}/plan.md').writeAsStringSync('plan');

      final port = WorkflowGitPortProcess();

      expect(await port.diffNameOnly(tempDir.path, projectDir: tempDir.path), ['plan.md']);

      await port.add(tempDir.path, ['plan.md'], projectDir: tempDir.path);
      expect(await port.diffNameOnly(tempDir.path, projectDir: tempDir.path, cached: true), ['plan.md']);

      final commit = await port.commit(
        tempDir.path,
        projectDir: tempDir.path,
        message: 'chore(workflow): artifacts',
        authorName: 'DartClaw Workflow',
        authorEmail: 'workflow@dartclaw.local',
      );

      expect(commit.sha, isNotEmpty);
      expect(await port.pathExistsAtRef(tempDir.path, projectDir: tempDir.path, ref: 'HEAD', path: 'plan.md'), isTrue);
      expect(await port.diffNameOnly(tempDir.path, projectDir: tempDir.path, cached: true), isEmpty);
    });

    test('reports current branch and detached HEAD through the port', () async {
      await _git(tempDir.path, ['init', '-q']);
      await _git(tempDir.path, ['checkout', '-qb', 'main']);
      File('${tempDir.path}/base.txt').writeAsStringSync('base');
      await _git(tempDir.path, ['add', 'base.txt']);
      await _git(tempDir.path, [
        '-c',
        'user.name=DartClaw Test',
        '-c',
        'user.email=test@example.com',
        'commit',
        '-qm',
        'initial',
      ]);

      final port = WorkflowGitPortProcess();

      expect(await port.currentBranch(tempDir.path, projectDir: tempDir.path), 'main');

      await _git(tempDir.path, ['checkout', '--detach', 'HEAD']);

      expect(await port.currentBranch(tempDir.path, projectDir: tempDir.path), 'HEAD');
    });
  });

  group('WorkflowGitPortProcess in a linked worktree', () {
    late HostWorktreeTamperFixture fixture;

    setUp(() async {
      fixture = await HostWorktreeTamperFixture.create();
    });
    tearDown(() => fixture.dispose());

    Future<String> branchTip() async =>
        ((await HostWorktreeTamperFixture.git(fixture.projectDir, ['rev-parse', fixture.branch])).stdout as String)
            .trim();

    test('stages and commits on the worktree branch through the recorded gitdir', () async {
      fixture.write('work.txt');
      final port = WorkflowGitPortProcess();
      await port.add(fixture.worktreePath, const [], projectDir: fixture.projectDir, all: true);
      final commit = await port.commit(fixture.worktreePath, projectDir: fixture.projectDir, message: 'work');
      expect(commit.sha, await branchTip());
      expect(
        (await HostWorktreeTamperFixture.git(fixture.projectDir, ['show', '${fixture.branch}:work.txt'])).stdout,
        'changed\n',
      );
    });

    final operations = <String, Future<void> Function(WorkflowGitPortProcess port)>{
      'add': (port) => port.add(fixture.worktreePath, const [], projectDir: fixture.projectDir, all: true),
      'commit': (port) => port.commit(fixture.worktreePath, projectDir: fixture.projectDir, message: 'sweep'),
      'merge': (port) => port.merge(
        fixture.worktreePath,
        projectDir: fixture.projectDir,
        ref: 'main',
        strategy: WorkflowGitMergeStrategy.merge,
      ),
      'reset': (port) => port.resetHard(fixture.worktreePath, 'HEAD', projectDir: fixture.projectDir),
      'status': (port) => port.status(fixture.worktreePath, projectDir: fixture.projectDir),
    };
    final tampers = <String, Future<void> Function()>{
      'gitlink rewritten to an agent gitdir': () => fixture.rewriteGitlinkToAgentGitdir(),
      'gitlink replaced by a repository': () => fixture.replaceGitlinkWithRepository(),
      'gitlink replaced by a symlink': () async => fixture.replaceGitlinkWithSymlink(),
      'gitlink deleted': () async => fixture.deleteGitlink(),
    };

    for (final tamper in tampers.entries) {
      for (final operation in operations.entries) {
        test('${operation.key} refuses a worktree whose ${tamper.key}', () async {
          fixture.write('work.txt');
          final tipBefore = await branchTip();
          await tamper.value();

          await expectLater(
            operation.value(WorkflowGitPortProcess()),
            throwsA(
              isA<TamperedWorktreeException>().having((e) => e.worktreePath, 'worktreePath', fixture.worktreePath),
            ),
          );
          expect(fixture.existingMarkers, isEmpty);
          expect(await branchTip(), tipBefore);
          if (tamper.key == 'gitlink replaced by a repository') {
            final agentHead = await Process.run('git', [
              'rev-parse',
              '--verify',
              'HEAD',
            ], workingDirectory: fixture.worktreePath);
            expect(agentHead.exitCode, isNot(0), reason: 'nothing may be committed into the agent repository');
          }
        });
      }
    }

    test('locks on the project common dir and runs no Git in the tampered worktree', () async {
      await fixture.rewriteGitlinkToAgentGitdir();
      final commonDir = Directory(p.join(fixture.projectDir, '.git')).resolveSymbolicLinksSync();
      final calls = <({List<String> args, String? dir})>[];
      final firstCallDone = Completer<void>();
      Future<ProcessResult> recordingGit(
        List<String> args, {
        String? workingDirectory,
        ProcessEnvironmentPlan plan = const EmptyProcessEnvironmentPlan(),
        bool noSystemConfig = true,
      }) async {
        calls.add((args: args, dir: workingDirectory));
        final result = await runGit(
          args,
          workingDirectory: workingDirectory,
          plan: plan,
          noSystemConfig: noSystemConfig,
        );
        if (!firstCallDone.isCompleted) firstCallDone.complete();
        return result;
      }

      final held = Completer<void>();
      final release = Completer<void>();
      final holder = RepoLock().acquire(commonDir, () async {
        held.complete();
        await release.future;
      });
      await held.future;

      final commit = WorkflowGitPortProcess(processRunner: recordingGit)
          .commit(fixture.worktreePath, projectDir: fixture.projectDir, message: 'sweep');
      await firstCallDone.future;
      await pumpEventQueue();
      // Only the lock-key read has run: the commit waits on the real common dir.
      expect(calls, hasLength(1));
      expect(calls.single.dir, fixture.projectDir);
      expect(calls.single.args, containsAllInOrder(['rev-parse', '--path-format=absolute', '--git-common-dir']));

      release.complete();
      await holder;
      await expectLater(commit, throwsA(isA<TamperedWorktreeException>()));
      expect(calls.where((call) => call.dir != fixture.projectDir), isEmpty);
      expect(fixture.existingMarkers, isEmpty);
    });
  });
}

Future<void> _git(String workingDirectory, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed: ${result.stderr}');
  }
}
