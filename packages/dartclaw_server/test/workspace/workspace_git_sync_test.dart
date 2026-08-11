import 'dart:io';

import 'package:dartclaw_server/src/workspace/workspace_git_sync.dart';
import 'package:test/test.dart';

/// Records all commands run and returns preconfigured results.
class FakeCommandRunner {
  final List<(String, List<String>, String?)> calls = [];
  final Map<String, ProcessResult> _results = {};
  ProcessResult _default = ProcessResult(0, 0, '', '');

  void setResult(String key, ProcessResult result) => _results[key] = result;
  void setDefault(ProcessResult result) => _default = result;

  /// Build a lookup key from executable + first arg.
  static String key(String exe, List<String> args) => args.isEmpty ? exe : '$exe ${args.first}';

  Future<ProcessResult> run(String executable, List<String> arguments, {String? workingDirectory}) async {
    calls.add((executable, arguments, workingDirectory));
    final k = key(executable, arguments);
    return _results[k] ?? _default;
  }
}

ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');
ProcessResult _fail([String stderr = 'error']) => ProcessResult(0, 1, '', stderr);

void main() {
  late Directory tmpDir;
  late FakeCommandRunner runner;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('git_sync_test_');
    runner = FakeCommandRunner();
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  WorkspaceGitSync createSync({bool pushEnabled = true}) =>
      WorkspaceGitSync(workspaceDir: tmpDir.path, pushEnabled: pushEnabled, commandRunner: runner.run);

  group('isGitAvailable', () {
    test('returns true when git --version succeeds', () async {
      runner.setResult('git --version', _ok('git version 2.43.0'));
      final sync = createSync();

      expect(await sync.isGitAvailable(), isTrue);
      expect(sync.gitAvailable, isTrue);
    });

    test('returns false when git --version fails', () async {
      runner.setResult('git --version', _fail());
      final sync = createSync();

      expect(await sync.isGitAvailable(), isFalse);
      expect(sync.gitAvailable, isFalse);
    });

    test('returns false when git command throws', () async {
      final sync = WorkspaceGitSync(
        workspaceDir: tmpDir.path,
        commandRunner: (exe, args, {workingDirectory}) async {
          throw ProcessException('git', args, 'not found');
        },
      );

      expect(await sync.isGitAvailable(), isFalse);
      expect(sync.gitAvailable, isFalse);
    });
  });

  group('initIfNeeded', () {
    test('creates a missing workspace before initializing git', () async {
      final workspace = Directory('${tmpDir.path}/missing/workspace');
      runner.setResult('git --version', _ok());
      runner.setResult('git init', _ok());
      final sync = WorkspaceGitSync(workspaceDir: workspace.path, commandRunner: runner.run);

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      expect(workspace.existsSync(), isTrue);
      expect(runner.calls.where((call) => call.$2.first == 'init').single.$3, workspace.path);
    });

    test('initializes repo when .git missing', () async {
      runner.setResult('git --version', _ok());
      runner.setResult('git init', _ok());
      runner.setResult('git status', _ok('?? .gitignore'));
      runner.setResult('git add', _ok());
      runner.setResult('git commit', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      // Should have run: init, status, add, commit
      final cmds = runner.calls.skip(1).map((c) => '${c.$1} ${c.$2.first}').toList();
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
      runner.setResult('git --version', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      // Only the --version call, no init
      expect(runner.calls, hasLength(1));
      expect(File('${tmpDir.path}/.gitignore').readAsStringSync(), WorkspaceGitSync.defaultGitignore);
    });

    test('skips when git not available', () async {
      runner.setResult('git --version', _fail());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      // Only the --version call
      expect(runner.calls, hasLength(1));
    });

    test('preserves existing .gitignore entries', () async {
      File('${tmpDir.path}/.gitignore').writeAsStringSync('custom\n');
      runner.setResult('git --version', _ok());
      runner.setResult('git init', _ok());
      runner.setResult('git status', _ok('?? file.txt'));
      runner.setResult('git add', _ok());
      runner.setResult('git commit', _ok());
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
      runner.setResult('git --version', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();
      await sync.initIfNeeded();

      final lines = gitignore.readAsLinesSync();
      expect(lines, containsAll(['custom/', '.env', 'errors.md']));
      expect(lines, isNot(contains('learnings.md')));
      expect(lines.where((line) => line == '.env'), hasLength(1));
      expect(lines.where((line) => line == 'errors.md'), hasLength(1));
      expect(runner.calls.where((call) => call.$2.first == 'init'), isEmpty);
    });

    test('preserves a legacy learnings ignore rule in an existing workspace', () async {
      Directory('${tmpDir.path}/.git').createSync();
      const custom = 'learnings.md\ncustom/\n!custom/keep.md\n';
      final gitignore = File('${tmpDir.path}/.gitignore')..writeAsStringSync(custom);
      runner.setResult('git --version', _ok());
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
      runner.setResult('git --version', _ok());
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
      runner.setResult('git --version', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      expect(File('${tmpDir.path}/.gitignore').existsSync(), isTrue);
      expect(runner.calls.where((call) => call.$2.first == 'init'), isEmpty);
    });

    test('does not follow a .gitignore symlink outside the workspace', () async {
      Directory('${tmpDir.path}/.git').createSync();
      final outside = Directory.systemTemp.createTempSync('gitignore_link_target_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final sentinel = File('${outside.path}/sentinel')..writeAsStringSync('unchanged\n');
      Link('${tmpDir.path}/.gitignore').createSync(sentinel.path);
      runner.setResult('git --version', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      expect(sentinel.readAsStringSync(), 'unchanged\n');
      expect(FileSystemEntity.typeSync('${tmpDir.path}/.gitignore', followLinks: false), FileSystemEntityType.link);
    });

    test('leaves a non-UTF-8 .gitignore untouched', () async {
      Directory('${tmpDir.path}/.git').createSync();
      final gitignore = File('${tmpDir.path}/.gitignore')..writeAsBytesSync([0xff]);
      runner.setResult('git --version', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      expect(gitignore.readAsBytesSync(), [0xff]);
    });
  });

  group('commitAll', () {
    test('no-op when no changes', () async {
      runner.setResult('git --version', _ok());
      runner.setResult('git status', _ok(''));
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.commitAll(), isFalse);

      // Only --version + status
      expect(runner.calls, hasLength(2));
    });

    test('commits when changes exist', () async {
      runner.setResult('git --version', _ok());
      runner.setResult('git status', _ok('M file.txt'));
      runner.setResult('git add', _ok());
      runner.setResult('git commit', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.commitAll(), isTrue);

      final commitCall = runner.calls.firstWhere((c) => c.$2.first == 'commit');
      expect(commitCall.$2, contains('-m'));
      expect(commitCall.$2.last, startsWith('DartClaw auto-commit:'));
    });

    test('uses custom message when provided', () async {
      runner.setResult('git --version', _ok());
      runner.setResult('git status', _ok('M file.txt'));
      runner.setResult('git add', _ok());
      runner.setResult('git commit', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.commitAll(message: 'Custom msg');

      final commitCall = runner.calls.firstWhere((c) => c.$2.first == 'commit');
      expect(commitCall.$2.last, 'Custom msg');
    });

    test('returns false when git not available', () async {
      runner.setResult('git --version', _fail());
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.commitAll(), isFalse);
    });

    test('all commands use workingDirectory', () async {
      runner.setResult('git --version', _ok());
      runner.setResult('git status', _ok('M f.txt'));
      runner.setResult('git add', _ok());
      runner.setResult('git commit', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.commitAll();

      // All git commands (except --version) should have workingDirectory set
      for (final call in runner.calls.skip(1)) {
        expect(call.$3, tmpDir.path, reason: 'git ${call.$2.first} missing workingDirectory');
      }
    });
  });

  group('push', () {
    test('pushes when remote exists and pushEnabled', () async {
      runner.setResult('git --version', _ok());
      runner.setResult('git remote', _ok('https://example.com/repo.git'));
      runner.setResult('git push', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.push(), isTrue);

      final pushCalls = runner.calls.where((c) => c.$2.first == 'push');
      expect(pushCalls, hasLength(1));
    });

    test('skips when no remote configured', () async {
      runner.setResult('git --version', _ok());
      runner.setResult('git remote', _fail('fatal: No such remote'));
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.push(), isTrue); // returns true (no error)

      final pushCalls = runner.calls.where((c) => c.$2.first == 'push');
      expect(pushCalls, isEmpty);
    });

    test('skips when pushEnabled is false', () async {
      runner.setResult('git --version', _ok());
      final sync = createSync(pushEnabled: false);

      await sync.isGitAvailable();
      expect(await sync.push(), isTrue);
      // No remote check or push
      expect(runner.calls, hasLength(1));
    });

    test('returns false on push failure without throwing', () async {
      runner.setResult('git --version', _ok());
      runner.setResult('git remote', _ok('https://example.com/repo.git'));
      runner.setResult('git push', _fail('network error'));
      final sync = createSync();

      await sync.isGitAvailable();
      expect(await sync.push(), isFalse);
    });
  });

  group('commitAndPush', () {
    test('commits then pushes', () async {
      runner.setResult('git --version', _ok());
      runner.setResult('git status', _ok('M f.txt'));
      runner.setResult('git add', _ok());
      runner.setResult('git commit', _ok());
      runner.setResult('git remote', _ok('https://example.com/repo.git'));
      runner.setResult('git push', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.commitAndPush(); // should not throw

      final ops = runner.calls.skip(1).map((c) => c.$2.first).toList();
      expect(ops, ['status', 'add', 'commit', 'remote', 'push']);
    });

    test('does not throw on git failure', () async {
      runner.setResult('git --version', _ok());
      final sync = WorkspaceGitSync(
        workspaceDir: tmpDir.path,
        commandRunner: (exe, args, {workingDirectory}) async {
          if (args.first == '--version') return _ok();
          throw ProcessException('git', args, 'broken');
        },
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
