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

    test('skips when .git already exists', () async {
      Directory('${tmpDir.path}/.git').createSync();
      runner.setResult('git --version', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      // Only the --version call, no init
      expect(runner.calls, hasLength(1));
    });

    test('skips when git not available', () async {
      runner.setResult('git --version', _fail());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      // Only the --version call
      expect(runner.calls, hasLength(1));
    });

    test('does not overwrite existing .gitignore', () async {
      File('${tmpDir.path}/.gitignore').writeAsStringSync('custom\n');
      runner.setResult('git --version', _ok());
      runner.setResult('git init', _ok());
      runner.setResult('git status', _ok('?? file.txt'));
      runner.setResult('git add', _ok());
      runner.setResult('git commit', _ok());
      final sync = createSync();

      await sync.isGitAvailable();
      await sync.initIfNeeded();

      expect(File('${tmpDir.path}/.gitignore').readAsStringSync(), 'custom\n');
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
