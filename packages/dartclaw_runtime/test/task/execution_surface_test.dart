import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/task/execution_surface.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'task_executor_test_support.dart' show initGitRepo;

void main() {
  group('ExecutionSurface', () {
    late Directory repo;

    Future<void> git(List<String> args) async {
      final result = await runGit(args, workingDirectory: repo.path);
      if (result.exitCode != 0) throw StateError('${args.join(' ')}: ${result.stderr}');
    }

    Future<void> commit() async {
      await git(['add', '-A']);
      await git([
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.com',
        'commit',
        '--no-gpg-sign',
        '-m',
        'change',
      ]);
    }

    void write(String path, [String content = 'changed\n']) {
      final file = File(p.join(repo.path, path))..parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    Future<List<String>> paths() => executionSurfacePaths(worktreePath: repo.path, baseRef: 'main', branch: 'feature');

    setUp(() async {
      repo = await initGitRepo();
      await git(['checkout', '-b', 'feature']);
    });
    tearDown(() => repo.deleteSync(recursive: true));

    const listed = [
      '.claude/hooks/x.sh',
      '.mcp.json',
      '.codex/config.toml',
      '.husky/pre-commit',
      '.githooks/pre-push',
      '.github/workflows/ci.yml',
      '.envrc',
      '.vscode/tasks.json',
      '.vscode/settings.json',
      'mise.toml',
    ];
    const clean = ['.vscode/launch.json', '.github/dependabot.yml', 'CLAUDE.md', 'AGENTS.md', 'docs/.claude/notes.md'];

    for (final state in ['committed', 'staged', 'untracked']) {
      test('holds every listed form and excludes nearby paths when $state', () async {
        for (final path in [...listed, ...clean]) {
          write(path);
        }
        if (state == 'committed') await commit();
        if (state == 'staged') await git(['add', '-A']);
        expect(await paths(), unorderedEquals(listed));
      });
    }

    test('matches listed root paths case insensitively', () async {
      write('.Claude/Settings.json');
      expect(await paths(), ['.Claude/Settings.json']);
    });

    test('counts unstaged edits, deletions, and both rename ends', () async {
      write('.mcp.json');
      write('.envrc');
      write('ordinary.txt');
      await commit();
      await git(['branch', '-f', 'main', 'HEAD']);
      write('.mcp.json', 'updated\n');
      File(p.join(repo.path, '.envrc')).deleteSync();
      await git(['mv', 'ordinary.txt', 'mise.toml']);
      expect(await paths(), unorderedEquals(['.mcp.json', '.envrc', 'mise.toml']));
      await git(['mv', 'mise.toml', 'ordinary-again.txt']);
      await git(['mv', '.mcp.json', 'renamed.json']);
      expect(await paths(), unorderedEquals(['.mcp.json', '.envrc']));
    });

    for (final state in ['committed', 'staged', 'untracked']) {
      test('holds added symlinks at any depth when $state', () async {
        Directory(p.join(repo.path, 'docs')).createSync();
        Link(p.join(repo.path, 'docs/notes.md')).createSync('/etc/passwd');
        if (state == 'committed') await commit();
        if (state == 'staged') await git(['add', '-A']);
        expect(await paths(), ['docs/notes.md']);
      });
    }

    test('deleting an existing symlink is clean but retargeting or retyping hits', () async {
      Link(p.join(repo.path, 'link.md')).createSync('README.md');
      write('retyped.md');
      await commit();
      await git(['branch', '-f', 'main', 'HEAD']);
      Link(p.join(repo.path, 'link.md')).deleteSync();
      expect(await paths(), isEmpty);
      Link(p.join(repo.path, 'link.md')).createSync('retyped.md');
      File(p.join(repo.path, 'retyped.md')).deleteSync();
      Link(p.join(repo.path, 'retyped.md')).createSync('README.md');
      expect(await paths(), unorderedEquals(['link.md', 'retyped.md']));
    });

    test('preserves newline filenames and does not read symlink targets', () async {
      const name = 'docs/new\nname.md';
      Directory(p.join(repo.path, 'docs')).createSync();
      Link(p.join(repo.path, name)).createSync('/no/such/target');
      expect(await paths(), [name]);
    });

    test('metadata inspection never invokes a configured diff driver', () async {
      write('.gitattributes', '*.txt diff=probe\n');
      write('ordinary.txt');
      await commit();
      await git(['branch', '-f', 'main', 'HEAD']);
      await git(['config', 'diff.probe.command', 'touch driver-ran']);
      await git(['config', 'diff.probe.textconv', 'touch converter-ran']);
      write('ordinary.txt', 'new content\n');
      expect(await paths(), isEmpty);
      expect(File(p.join(repo.path, 'driver-ran')).existsSync(), isFalse);
      expect(File(p.join(repo.path, 'converter-ran')).existsSync(), isFalse);
    });

    test('keeps committed symlink evidence when the worktree deletes it', () async {
      Link(p.join(repo.path, 'ordinary-link')).createSync('outside');
      await commit();
      Link(p.join(repo.path, 'ordinary-link')).deleteSync();
      expect(await paths(), ['ordinary-link']);
    });

    test('keeps the old listed rename endpoint when the destination is dirty', () async {
      write('.mcp.json', 'original');
      await commit();
      await git(['branch', '-f', 'main', 'HEAD']);
      await git(['mv', '.mcp.json', 'ordinary.json']);
      await commit();
      write('ordinary.json', 'dirty');
      expect(await paths(), ['.mcp.json']);
    });

    for (final output in ['not raw metadata', ':100644 120000 abc def A\u0000link', '\u0000']) {
      test('malformed metadata fails closed: ${output.length}', () async {
        await expectLater(
          executionSurfacePaths(
            worktreePath: repo.path,
            baseRef: 'main',
            branch: 'feature',
            processRunner: (
              args, {
              workingDirectory,
              noSystemConfig = true,
              plan = const EmptyProcessEnvironmentPlan(),
            }) async => ProcessResult(0, 0, output, ''),
          ),
          throwsException,
        );
      });
    }
    test('non-git metadata read fails closed', () async {
      final root = Directory.systemTemp.createTempSync('not-git-');
      addTearDown(() => root.deleteSync(recursive: true));
      await expectLater(
        executionSurfacePaths(worktreePath: root.path, baseRef: 'main', branch: 'feature'),
        throwsException,
      );
    });

    test('a bad base ref fails closed', () async {
      await expectLater(
        executionSurfacePaths(worktreePath: repo.path, baseRef: 'missing', branch: 'feature'),
        throwsException,
      );
    });
  });
}
