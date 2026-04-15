import 'dart:io';

import 'package:dartclaw_server/src/task/diff_generator.dart';
import 'package:dartclaw_server/src/task/worktree_manager.dart';
import 'package:test/test.dart';

void main() {
  group('DiffGenerator', () {
    late DiffGenerator generator;
    late List<({String executable, List<String> args})> calls;
    late Map<String, ProcessResult> responses;

    setUp(() {
      calls = [];
      responses = {};
    });

    ProcessResult pr(String stdout, {String stderr = '', int exitCode = 0}) {
      return ProcessResult(0, exitCode, stdout, stderr);
    }

    Future<ProcessResult> mockRunner(String executable, List<String> arguments, {String? workingDirectory}) async {
      calls.add((executable: executable, args: arguments));
      final key = arguments.join(' ');
      return responses[key] ?? pr('');
    }

    test('generates structured diff from numstat and unified output', () async {
      generator = DiffGenerator(projectDir: '/project', processRunner: mockRunner);

      responses['diff --numstat main...feature'] = pr('10\t2\tlib/main.dart\n3\t0\tlib/new.dart\n');
      responses['diff -U3 --no-color main...feature'] = pr(
        'diff --git a/lib/main.dart b/lib/main.dart\n'
        '--- a/lib/main.dart\n'
        '+++ b/lib/main.dart\n'
        '@@ -1,5 +1,7 @@\n'
        ' line1\n'
        '-old line\n'
        '+new line\n'
        '+added line\n'
        ' line3\n'
        'diff --git a/lib/new.dart b/lib/new.dart\n'
        '--- /dev/null\n'
        '+++ b/lib/new.dart\n'
        '@@ -0,0 +1,3 @@\n'
        '+first\n'
        '+second\n'
        '+third\n',
      );

      final result = await generator.generate(baseRef: 'main', branch: 'feature');

      expect(result.filesChanged, equals(2));
      expect(result.totalAdditions, equals(13));
      expect(result.totalDeletions, equals(2));
      expect(result.files[0].path, equals('lib/main.dart'));
      expect(result.files[0].additions, equals(10));
      expect(result.files[0].deletions, equals(2));
      expect(result.files[0].hunks, hasLength(1));
      expect(result.files[0].hunks[0].oldStart, equals(1));
      expect(result.files[0].hunks[0].newStart, equals(1));
      expect(result.files[1].path, equals('lib/new.dart'));
      expect(result.files[1].additions, equals(3));
    });

    test('handles empty diff', () async {
      generator = DiffGenerator(projectDir: '/project', processRunner: mockRunner);

      responses['diff --numstat main...feature'] = pr('');
      responses['diff -U3 --no-color main...feature'] = pr('');

      final result = await generator.generate(baseRef: 'main', branch: 'feature');

      expect(result.files, isEmpty);
      expect(result.filesChanged, equals(0));
      expect(result.totalAdditions, equals(0));
      expect(result.totalDeletions, equals(0));
    });

    test('handles binary files', () async {
      generator = DiffGenerator(projectDir: '/project', processRunner: mockRunner);

      responses['diff --numstat main...feature'] = pr('-\t-\tassets/image.png\n');
      responses['diff -U3 --no-color main...feature'] = pr('');

      final result = await generator.generate(baseRef: 'main', branch: 'feature');

      expect(result.files, hasLength(1));
      expect(result.files[0].path, equals('assets/image.png'));
      expect(result.files[0].binary, isTrue);
      expect(result.files[0].additions, equals(0));
      expect(result.files[0].deletions, equals(0));
    });

    test('handles renamed files', () async {
      generator = DiffGenerator(projectDir: '/project', processRunner: mockRunner);

      responses['diff --numstat main...feature'] = pr('5\t2\tlib/{old.dart => new.dart}\n');
      responses['diff -U3 --no-color main...feature'] = pr('');

      final result = await generator.generate(baseRef: 'main', branch: 'feature');

      expect(result.files, hasLength(1));
      expect(result.files[0].path, equals('lib/new.dart'));
      expect(result.files[0].oldPath, equals('lib/old.dart'));
      expect(result.files[0].status, equals(DiffFileStatus.renamed));
    });

    test('handles deleted files', () async {
      generator = DiffGenerator(projectDir: '/project', processRunner: mockRunner);

      responses['diff --numstat main...feature'] = pr('0\t15\tlib/removed.dart\n');
      responses['diff -U3 --no-color main...feature'] = pr('');

      final result = await generator.generate(baseRef: 'main', branch: 'feature');

      expect(result.files, hasLength(1));
      expect(result.files[0].path, equals('lib/removed.dart'));
      expect(result.files[0].status, equals(DiffFileStatus.deleted));
      expect(result.files[0].deletions, equals(15));
    });

    test('throws WorktreeException on git failure', () async {
      generator = DiffGenerator(projectDir: '/project', processRunner: mockRunner);

      responses['diff --numstat main...feature'] = pr('', exitCode: 128, stderr: 'fatal: bad ref');

      expect(() => generator.generate(baseRef: 'main', branch: 'feature'), throwsA(isA<WorktreeException>()));
    });

    test('uses three-dot diff syntax', () async {
      generator = DiffGenerator(projectDir: '/project', processRunner: mockRunner);

      responses['diff --numstat main...feature'] = pr('');
      responses['diff -U3 --no-color main...feature'] = pr('');
      responses['diff --numstat HEAD'] = pr('');
      responses['diff -U3 --no-color HEAD'] = pr('');
      responses['ls-files --others --exclude-standard'] = pr('');

      await generator.generate(baseRef: 'main', branch: 'feature');

      expect(calls.any((call) => call.args.contains('main...feature')), isTrue);
      expect(calls.any((call) => call.args.contains('HEAD')), isTrue);
    });

    test('includes untracked files from the worktree', () async {
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_diff_generator_test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final noteFile = File('${tempDir.path}/notes/spec-publish.md');
      noteFile.parent.createSync(recursive: true);
      noteFile.writeAsStringSync('# Publish note\n- Added by workflow.\n');

      generator = DiffGenerator(projectDir: tempDir.path, processRunner: mockRunner);

      responses['diff --numstat main...feature'] = pr('');
      responses['diff -U3 --no-color main...feature'] = pr('');
      responses['diff --numstat HEAD'] = pr('');
      responses['diff -U3 --no-color HEAD'] = pr('');
      responses['ls-files --others --exclude-standard'] = pr('notes/spec-publish.md\n');

      final result = await generator.generate(baseRef: 'main', branch: 'feature', projectDir: tempDir.path);

      expect(result.filesChanged, 1);
      expect(result.files.single.path, 'notes/spec-publish.md');
      expect(result.files.single.status, DiffFileStatus.added);
      expect(result.files.single.additions, 2);
    });
  });

  group('DiffResult JSON round-trip', () {
    test('toJson and fromJson', () {
      final result = DiffResult(
        files: [
          DiffFileEntry(
            path: 'lib/main.dart',
            status: DiffFileStatus.modified,
            additions: 5,
            deletions: 2,
            hunks: [
              DiffHunk(
                header: '@@ -1,5 +1,7 @@',
                oldStart: 1,
                oldCount: 5,
                newStart: 1,
                newCount: 7,
                lines: [' ctx', '-old', '+new'],
              ),
            ],
          ),
        ],
        totalAdditions: 5,
        totalDeletions: 2,
        filesChanged: 1,
      );

      final json = result.toJson();
      final restored = DiffResult.fromJson(json);

      expect(restored.filesChanged, equals(1));
      expect(restored.totalAdditions, equals(5));
      expect(restored.totalDeletions, equals(2));
      expect(restored.files[0].path, equals('lib/main.dart'));
      expect(restored.files[0].hunks[0].oldStart, equals(1));
      expect(restored.files[0].hunks[0].lines, equals([' ctx', '-old', '+new']));
    });

    test('DiffFileEntry with oldPath and binary flag', () {
      final entry = DiffFileEntry(
        path: 'new.dart',
        oldPath: 'old.dart',
        status: DiffFileStatus.renamed,
        additions: 0,
        deletions: 0,
        binary: true,
        hunks: const [],
      );

      final json = entry.toJson();
      final restored = DiffFileEntry.fromJson(json);

      expect(restored.oldPath, equals('old.dart'));
      expect(restored.binary, isTrue);
      expect(restored.status, equals(DiffFileStatus.renamed));
    });
  });
}
