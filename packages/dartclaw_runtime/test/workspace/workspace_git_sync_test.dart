import 'dart:io';

import 'package:dartclaw_runtime/src/workspace/workspace_git_sync.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');
ProcessResult _fail([String stderr = 'error']) => ProcessResult(0, 1, '', stderr);

void main() {
  late Directory tmpDir;
  late RecordingGitRunner runner;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('git_sync_test_');
    runner = RecordingGitRunner();
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  WorkspaceGitSync createSync({bool pushEnabled = true}) =>
      WorkspaceGitSync(workspaceDir: tmpDir.path, pushEnabled: pushEnabled, commandRunner: runner.run);

  group('isGitAvailable', () {
    test('returns true when git --version succeeds', () async {
      runner.setResponse(['--version'], _ok('git version 2.43.0'));
      final sync = createSync();

      expect(await sync.isGitAvailable(), isTrue);
      expect(sync.gitAvailable, isTrue);
    });

    test('returns false when git --version fails', () async {
      runner.setResponse(['--version'], _fail());
      final sync = createSync();

      expect(await sync.isGitAvailable(), isFalse);
      expect(sync.gitAvailable, isFalse);
    });

    test('returns false when git command throws', () async {
      final sync = WorkspaceGitSync(
        workspaceDir: tmpDir.path,
        commandRunner: RecordingGitRunner(
          responder: (call) => throw ProcessException('git', call.arguments, 'not found'),
        ).run,
      );

      expect(await sync.isGitAvailable(), isFalse);
      expect(sync.gitAvailable, isFalse);
    });
  });

  group('initIfNeeded', () {
    test('creates a missing workspace before initializing git', () async {
      final workspace = Directory('${tmpDir.path}/missing/workspace');
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['init'], _ok());
      final sync = WorkspaceGitSync(workspaceDir: workspace.path, commandRunner: runner.run);

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      expect(workspace.existsSync(), isTrue);
      expect(runner.calls.where((call) => call.arguments.first == 'init').single.workingDirectory, workspace.path);
    });

    test('initializes repo when .git missing', () async {
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['init'], _ok());
      runner.setResponse(['status'], _ok('?? .gitignore'));
      runner.setResponse(['add'], _ok());
      runner.setResponse(['commit'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      // Should have run: init, status, add, commit
      final cmds = runner.calls.skip(1).map((c) => 'git ${c.arguments.first}').toList();
      expect(cmds, contains('git init'));
      expect(cmds, contains('git add'));
      expect(cmds, contains('git commit'));

      // .gitignore should be created
      final gitignore = File('${tmpDir.path}/.gitignore');
      expect(gitignore.existsSync(), isTrue);
      final content = gitignore.readAsStringSync();
      expect(content, contains('.env'));
      expect(content, contains('*.key'));
      expect(content, contains('*.pem'));
      expect(content, contains('secrets*'));
      expect(content, contains('.DS_Store'));
    });

    test('does not reinitialize an existing repo and creates its default .gitignore', () async {
      Directory('${tmpDir.path}/.git').createSync();
      runner.setResponse(['--version'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      // Only the --version call, no init
      expect(runner.calls, hasLength(1));
      expect(File('${tmpDir.path}/.gitignore').readAsStringSync(), WorkspaceGitSync.defaultGitignore);
    });

    test('skips when git not available', () async {
      runner.setResponse(['--version'], _fail());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      // Only the --version call
      expect(runner.calls, hasLength(1));
    });

    test('preserves existing .gitignore entries', () async {
      File('${tmpDir.path}/.gitignore').writeAsStringSync('custom\n');
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['init'], _ok());
      runner.setResponse(['status'], _ok('?? file.txt'));
      runner.setResponse(['add'], _ok());
      runner.setResponse(['commit'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      final lines = File('${tmpDir.path}/.gitignore').readAsLinesSync();
      expect(lines, containsAll(['custom', 'errors.md']));
      expect(lines, isNot(contains('learnings.md')));
    });

    test('adds missing default entries to a cloned repo without duplicating existing entries', () async {
      Directory('${tmpDir.path}/.git').createSync();
      final gitignore = File('${tmpDir.path}/.gitignore')..writeAsStringSync('custom/\n.env\n');
      runner.setResponse(['--version'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();
      await sync.initIfNeeded();

      final lines = gitignore.readAsLinesSync();
      expect(lines, containsAll(['custom/', '.env', 'errors.md']));
      expect(lines, isNot(contains('learnings.md')));
      expect(lines.where((line) => line == '.env'), hasLength(1));
      expect(lines.where((line) => line == 'errors.md'), hasLength(1));
      expect(runner.calls.where((call) => call.arguments.first == 'init'), isEmpty);
    });

    test('preserves a legacy learnings ignore rule in an existing workspace', () async {
      Directory('${tmpDir.path}/.git').createSync();
      const custom = 'learnings.md\ncustom/\n!custom/keep.md\n';
      final gitignore = File('${tmpDir.path}/.gitignore')..writeAsStringSync(custom);
      runner.setResponse(['--version'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();
      final firstContent = gitignore.readAsStringSync();
      await sync.initIfNeeded();

      expect(firstContent, endsWith(custom));
      expect(firstContent.split('\n').where((line) => line == 'learnings.md'), hasLength(1));
      expect(gitignore.readAsStringSync(), firstContent);
    });

    test('places defaults before custom negations and preserves a missing trailing newline', () async {
      Directory('${tmpDir.path}/.git').createSync();
      const custom = '*.md\n!errors.md';
      final gitignore = File('${tmpDir.path}/.gitignore')..writeAsStringSync(custom);
      runner.setResponse(['--version'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();
      final firstContent = gitignore.readAsStringSync();
      await sync.initIfNeeded();

      final lines = firstContent.split('\n');
      expect(lines.indexOf('errors.md'), lessThan(lines.indexOf('!errors.md')));
      expect(firstContent, endsWith(custom));
      expect(gitignore.readAsStringSync(), firstContent);
    });

    test('recognizes a git worktree metadata file as an existing repo', () async {
      File('${tmpDir.path}/.git').writeAsStringSync('gitdir: /tmp/repo/.git/worktrees/example\n');
      runner.setResponse(['--version'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      expect(File('${tmpDir.path}/.gitignore').existsSync(), isTrue);
      expect(runner.calls.where((call) => call.arguments.first == 'init'), isEmpty);
    });

    test('does not follow a .gitignore symlink outside the workspace', () async {
      Directory('${tmpDir.path}/.git').createSync();
      final outside = Directory.systemTemp.createTempSync('gitignore_link_target_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final sentinel = File('${outside.path}/sentinel')..writeAsStringSync('unchanged\n');
      Link('${tmpDir.path}/.gitignore').createSync(sentinel.path);
      runner.setResponse(['--version'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      expect(sentinel.readAsStringSync(), 'unchanged\n');
      expect(FileSystemEntity.typeSync('${tmpDir.path}/.gitignore', followLinks: false), FileSystemEntityType.link);
    });

    test('leaves a non-UTF-8 .gitignore untouched', () async {
      Directory('${tmpDir.path}/.git').createSync();
      final gitignore = File('${tmpDir.path}/.gitignore')..writeAsBytesSync([0xff]);
      runner.setResponse(['--version'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      expect(gitignore.readAsBytesSync(), [0xff]);
    });
  });

  group('commitAll', () {
    test('no-op when no changes', () async {
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['status'], _ok(''));
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.commitAll(), isFalse);

      // Only --version + status
      expect(runner.calls, hasLength(2));
    });

    test('commits when changes exist', () async {
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['status'], _ok('M file.txt'));
      runner.setResponse(['add'], _ok());
      runner.setResponse(['commit'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.commitAll(), isTrue);

      final commitCall = runner.calls.firstWhere((c) => c.arguments.first == 'commit');
      expect(commitCall.arguments, contains('-m'));
      expect(commitCall.arguments.last, startsWith('DartClaw auto-commit:'));
    });

    test('uses custom message when provided', () async {
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['status'], _ok('M file.txt'));
      runner.setResponse(['add'], _ok());
      runner.setResponse(['commit'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.commitAll(message: 'Custom msg');

      final commitCall = runner.calls.firstWhere((c) => c.arguments.first == 'commit');
      expect(commitCall.arguments.last, 'Custom msg');
    });

    test('returns false when git not available', () async {
      runner.setResponse(['--version'], _fail());
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.commitAll(), isFalse);
    });

    test('all commands use workingDirectory', () async {
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['status'], _ok('M f.txt'));
      runner.setResponse(['add'], _ok());
      runner.setResponse(['commit'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.commitAll();

      // All git commands (except --version) should have workingDirectory set
      for (final call in runner.calls.skip(1)) {
        expect(call.workingDirectory, tmpDir.path, reason: 'git ${call.arguments.first} missing workingDirectory');
      }
    });

    test('every workspace git spawn leaves system git config in band', () async {
      // Workspace git is the documented outlier: it commits inside an
      // automation-owned directory yet keeps system config, and flipping that
      // is a behaviour change rather than a dedup.
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['status'], _ok('M f.txt'));
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.commitAll();

      expect(runner.calls, isNotEmpty);
      expect(
        runner.calls.every((call) => !call.noSystemConfig),
        isTrue,
        reason: 'GIT_CONFIG_NOSYSTEM must stay unset for workspace git',
      );
    });
  });

  group('push', () {
    test('pushes when remote exists and pushEnabled', () async {
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['remote'], _ok('https://example.com/repo.git'));
      runner.setResponse(['push'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.push(), isTrue);

      final pushCalls = runner.calls.where((c) => c.arguments.first == 'push');
      expect(pushCalls, hasLength(1));
    });

    test('skips when no remote configured', () async {
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['remote'], _fail('fatal: No such remote'));
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.push(), isTrue); // returns true (no error)

      final pushCalls = runner.calls.where((c) => c.arguments.first == 'push');
      expect(pushCalls, isEmpty);
    });

    test('skips when pushEnabled is false', () async {
      runner.setResponse(['--version'], _ok());
      final sync = createSync(pushEnabled: false);

      await sync.isGitAvailable();
      expect(await sync.push(), isTrue);
      // No remote check or push
      expect(runner.calls, hasLength(1));
    });

    test('returns false on push failure without throwing', () async {
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['remote'], _ok('https://example.com/repo.git'));
      runner.setResponse(['push'], _fail('network error'));
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.push(), isFalse);
    });
  });

  group('commitAndPush', () {
    test('commits then pushes', () async {
      runner.setResponse(['--version'], _ok());
      runner.setResponse(['status'], _ok('M f.txt'));
      runner.setResponse(['add'], _ok());
      runner.setResponse(['commit'], _ok());
      runner.setResponse(['remote'], _ok('https://example.com/repo.git'));
      runner.setResponse(['push'], _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.commitAndPush(); // should not throw

      final ops = runner.calls.skip(1).map((c) => c.arguments.first).toList();
      expect(ops, ['status', 'add', 'commit', 'remote', 'push']);
    });

    test('does not throw on git failure', () async {
      runner.setResponse(['--version'], _ok());
      final sync = WorkspaceGitSync(
        workspaceDir: tmpDir.path,
        commandRunner: RecordingGitRunner(
          responder: (call) =>
              call.arguments.first == '--version' ? _ok() : throw ProcessException('git', call.arguments, 'broken'),
        ).run,
      );

      await sync.isGitAvailable();
      // Should swallow the exception
      await sync.commitAndPush();
    });
  });

  group('.gitignore content', () {
    test('default gitignore has correct patterns', () {
      expect(WorkspaceGitSync.defaultGitignore, contains('.env'));
      expect(WorkspaceGitSync.defaultGitignore, contains('*.key'));
      expect(WorkspaceGitSync.defaultGitignore, contains('*.pem'));
      expect(WorkspaceGitSync.defaultGitignore, contains('secrets*'));
      expect(WorkspaceGitSync.defaultGitignore, contains('.DS_Store'));
    });
  });
}
