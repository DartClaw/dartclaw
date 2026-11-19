import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart' show EmptyProcessEnvironmentPlan, ProcessEnvironmentPlan, runGit;
import 'package:dartclaw_runtime/src/task/host_worktree_git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'host_worktree_tamper_fixture.dart';

void main() {
  late HostWorktreeTamperFixture fixture;
  late List<({List<String> args, String? dir})> calls;

  Future<ProcessResult> recordingGit(
    List<String> args, {
    String? workingDirectory,
    ProcessEnvironmentPlan plan = const EmptyProcessEnvironmentPlan(),
    bool noSystemConfig = true,
  }) {
    calls.add((args: args, dir: workingDirectory));
    return runGit(args, workingDirectory: workingDirectory, plan: plan, noSystemConfig: noSystemConfig);
  }

  Future<ProcessResult> hostGit(List<String> args, {String? worktreePath}) => runHostWorktreeGit(
    args,
    projectDir: fixture.projectDir,
    worktreePath: worktreePath ?? fixture.worktreePath,
    runner: recordingGit,
  );

  setUp(() async {
    fixture = await HostWorktreeTamperFixture.create();
    calls = [];
  });
  tearDown(() => fixture.dispose());

  group('an untampered worktree', () {
    test('resolves to the admin record under the project common dir', () async {
      final location = await resolveHostWorktree(projectDir: fixture.projectDir, worktreePath: fixture.worktreePath);
      expect(location.gitDir, fixture.adminDir);
      expect(location.workTree, fixture.worktreePath);
    });

    test('runs status with the recorded gitdir and reports its changes', () async {
      fixture.write('README.md');
      fixture.write('new.txt');

      final result = await hostGit(['status', '--porcelain', '--untracked-files=all']);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect((result.stdout as String).split('\n'), containsAll([' M README.md', '?? new.txt']));
      final status = calls.last;
      expect(status.dir, fixture.worktreePath);
      expect(
        status.args,
        containsAllInOrder([
          'core.hooksPath=/dev/null',
          'core.fsmonitor=false',
          '--git-dir=${fixture.adminDir}',
          '--work-tree=${fixture.worktreePath}',
          'status',
        ]),
      );
    });

    test('resolves when reached through a symlinked path', () async {
      final alias = p.join(fixture.root.path, 'alias');
      Link(alias).createSync(fixture.worktreePath);

      final location = await resolveHostWorktree(projectDir: fixture.projectDir, worktreePath: alias);

      expect(location.gitDir, fixture.adminDir);
      expect(location.workTree, fixture.worktreePath);
    });

    test('resolves a worktree Git recorded with relative paths', () async {
      final relative = p.join(fixture.root.path, 'worktrees', 'relative');
      await HostWorktreeTamperFixture.git(fixture.projectDir, [
        '-c',
        'worktree.useRelativePaths=true',
        'worktree',
        'add',
        '-q',
        '-b',
        'relative',
        relative,
        'main',
      ]);
      expect(File(p.join(relative, '.git')).readAsStringSync(), startsWith('gitdir: ..'));

      final location = await resolveHostWorktree(projectDir: fixture.projectDir, worktreePath: relative);
      expect(p.basename(location.gitDir), 'relative');
      expect(
        p.dirname(location.gitDir),
        p.join(Directory(p.join(fixture.projectDir, '.git')).resolveSymbolicLinksSync(), 'worktrees'),
      );
      final status = await hostGit(['status', '--porcelain'], worktreePath: relative);
      expect(status.exitCode, 0, reason: '${status.stderr}');
    });

    test('runs project-dir Git in the project dir with the host options only', () async {
      final result = await runHostWorktreeGit(
        ['rev-parse', 'HEAD'],
        projectDir: fixture.projectDir,
        runner: recordingGit,
      );
      expect(result.exitCode, 0);
      expect(calls.single.dir, fixture.projectDir);
      expect(calls.single.args, [...hostWorktreeGitOptions, 'rev-parse', 'HEAD']);
    });

    test('runs no config of an untracked repository it stages, then refuses the staged gitlink', () async {
      final sub = p.join(fixture.worktreePath, 'scratch');
      Directory(sub).createSync();
      await HostWorktreeTamperFixture.git(sub, ['init', '-q', '-b', 'main']);
      File(p.join(sub, 'file.txt')).writeAsStringSync('x\n');
      await HostWorktreeTamperFixture.git(sub, ['add', '.']);
      await HostWorktreeTamperFixture.git(sub, [
        '-c',
        'user.email=a@b',
        '-c',
        'user.name=a',
        'commit',
        '-q',
        '-m',
        'x',
      ]);
      await HostWorktreeTamperFixture.git(sub, [
        'config',
        'filter.evil.clean',
        "sh -c 'touch \"${fixture.filterMarker.path}\"; cat'",
      ]);
      File(p.join(sub, '.git', 'info', 'attributes'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('* filter=evil\n');
      // Same size and a later mtime: a Git that checks the repository must re-hash the file.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      File(p.join(sub, 'file.txt')).writeAsStringSync('y\n');

      for (final args in [
        ['status', '--porcelain', '--untracked-files=all'],
        ['add', '-A'],
      ]) {
        final result = await hostGit(args);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      // `add -A` recorded the repository as a gitlink, which every later call refuses.
      await expectLater(hostGit(['diff', '--cached', '--name-only']), throwsA(isA<TamperedWorktreeException>()));
      expect(fixture.existingMarkers, isEmpty);
    });
  });

  group('a repository nested as a gitlink', () {
    for (final args in [
      ['status', '--porcelain', '--untracked-files=all'],
      ['add', '-A'],
      ['diff', 'HEAD'],
    ]) {
      test('is refused before ${args.first} runs, and runs no config', () async {
        await fixture.nestRepository();

        await expectLater(
          hostGit(args),
          throwsA(isA<TamperedWorktreeException>().having((e) => e.reason, 'reason', contains('"sub"'))),
        );
        expect(calls.where((call) => call.args.contains(args.first)), isEmpty);
        expect(fixture.existingMarkers, isEmpty);
      });
    }
  });

  group('a tampered gitlink', () {
    final tampers = <String, Future<void> Function()>{
      'rewritten to an agent gitdir': () => fixture.rewriteGitlinkToAgentGitdir(),
      'replaced by a repository': () => fixture.replaceGitlinkWithRepository(),
      'replaced by a symlink to the real admin dir': () async => fixture.replaceGitlinkWithSymlink(),
      'deleted': () async => fixture.deleteGitlink(),
    };

    for (final tamper in tampers.entries) {
      test('${tamper.key} is refused before any Git runs against the worktree', () async {
        fixture.write('README.md');
        await tamper.value();

        await expectLater(
          hostGit(['status', '--porcelain']),
          throwsA(isA<TamperedWorktreeException>().having((e) => e.worktreePath, 'worktreePath', fixture.worktreePath)),
        );
        expect(calls, isNotEmpty);
        for (final call in calls) {
          expect(call.dir, fixture.projectDir);
          expect(call.args, isNot(contains(startsWith('--work-tree'))));
        }
        expect(fixture.existingMarkers, isEmpty);
      });
    }

    test('is refused when the worktree directory is gone', () async {
      Directory(fixture.worktreePath).deleteSync(recursive: true);
      await expectLater(hostGit(['status']), throwsA(isA<TamperedWorktreeException>()));
    });

    test('is refused when no worktree record of the project names the directory', () async {
      final stray = Directory(p.join(fixture.root.path, 'stray'))..createSync();
      await HostWorktreeTamperFixture.git(stray.path, ['init', '-q']);
      await expectLater(
        hostGit(['status'], worktreePath: stray.path),
        throwsA(isA<TamperedWorktreeException>().having((e) => e.reason, 'reason', contains('no worktree record'))),
      );
    });
  });
}
