import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/workflow_local_path_preflight.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Directory repoDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('workflow_local_path_preflight_test_');
    repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);
    _runGit(repoDir.path, ['init', '-b', 'main']);
    _runGit(repoDir.path, ['config', 'user.name', 'Test User']);
    _runGit(repoDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('hello\n');
    _runGit(repoDir.path, ['add', 'README.md']);
    _runGit(repoDir.path, ['commit', '-m', 'initial']);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('fails on dirty or branch-mismatched local paths without the override flag', () async {
    _runGit(repoDir.path, ['checkout', '-b', 'feature/local']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('dirty\n');

    await expectLater(
      ensureWorkflowLocalPathProjectReady(
        projectId: 'live-project',
        localPath: repoDir.path,
        configuredBranch: 'main',
        publishEnabled: false,
        allowDirty: false,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf([contains('live-project'), contains('feature/local'), contains('dirty path count 1')]),
        ),
      ),
    );
  });

  test('allowDirtyLocalPath lets dirty local paths proceed', () async {
    _runGit(repoDir.path, ['checkout', '-b', 'feature/local']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('dirty\n');

    await expectLater(
      ensureWorkflowLocalPathProjectReady(
        projectId: 'live-project',
        localPath: repoDir.path,
        configuredBranch: 'main',
        publishEnabled: false,
        allowDirty: true,
      ),
      completes,
    );
  });

  test('publish-enabled local paths require an origin remote', () async {
    await expectLater(
      ensureWorkflowLocalPathProjectReady(
        projectId: 'live-project',
        localPath: repoDir.path,
        configuredBranch: 'main',
        publishEnabled: true,
        allowDirty: false,
      ),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('origin remote'))),
    );
  });

  test('publish-enabled local paths pass when origin exists', () async {
    final originDir = Directory(p.join(tempDir.path, 'origin.git'))..createSync(recursive: true);
    _runGit(originDir.path, ['init', '--bare']);
    _runGit(repoDir.path, ['remote', 'add', 'origin', originDir.path]);

    await expectLater(
      ensureWorkflowLocalPathProjectReady(
        projectId: 'live-project',
        localPath: repoDir.path,
        configuredBranch: 'main',
        publishEnabled: true,
        allowDirty: false,
      ),
      completes,
    );
  });

  test('detached HEAD fails when configuredBranch is empty and no explicit branch was supplied', () async {
    _runGit(repoDir.path, ['checkout', '--detach', 'HEAD']);

    await expectLater(
      ensureWorkflowLocalPathProjectReady(
        projectId: 'live-project',
        localPath: repoDir.path,
        configuredBranch: '',
        publishEnabled: false,
        allowDirty: false,
      ),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('expected an attached branch'))),
    );
  });

  test('detached HEAD is allowed when an explicit branch was supplied', () async {
    _runGit(repoDir.path, ['checkout', '--detach', 'HEAD']);

    await expectLater(
      ensureWorkflowLocalPathProjectReady(
        projectId: 'live-project',
        localPath: repoDir.path,
        configuredBranch: '',
        publishEnabled: false,
        allowDirty: false,
        hasExplicitBranch: true,
      ),
      completes,
    );
  });

  // ── S54: Local-path branch safety — S42-A regression (BRANCH= caller override) ──

  test('S54: configured branch check compares observed branch against configuredBranch, not caller BRANCH override',
      () async {
    // S42-A regression: the guard must compare against the project's configuredBranch,
    // not the caller-supplied BRANCH variable. Passing hasExplicitBranch=true must NOT
    // bypass a configuredBranch mismatch — it is only used when configuredBranch is empty.
    _runGit(repoDir.path, ['checkout', '-b', 'feature/foo']);

    // hasExplicitBranch: true simulates a caller passing `-v BRANCH=feature/foo`.
    // The configured project branch is 'main', so this must still fail.
    await expectLater(
      ensureWorkflowLocalPathProjectReady(
        projectId: 'live-project',
        localPath: repoDir.path,
        configuredBranch: 'main',
        publishEnabled: false,
        allowDirty: false,
        hasExplicitBranch: true,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf([contains('live-project'), contains('feature/foo'), contains('"main"')]),
        ),
      ),
    );
  });

  test('S54: omitted configuredBranch accepts current HEAD when hasExplicitBranch is true', () async {
    // Non-destructive implicit HEAD behavior: when no configuredBranch is set,
    // the preflight must not attempt a checkout switch. An explicit BRANCH hint
    // (hasExplicitBranch=true) simply suppresses the detached-HEAD failure.
    // In this case the repo is on 'main' (clean), so it must proceed.
    await expectLater(
      ensureWorkflowLocalPathProjectReady(
        projectId: 'live-project',
        localPath: repoDir.path,
        configuredBranch: '',
        publishEnabled: false,
        allowDirty: false,
        hasExplicitBranch: true,
      ),
      completes,
    );
  });
}

void _runGit(String workingDirectory, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed in $workingDirectory: ${result.stderr}');
  }
}
