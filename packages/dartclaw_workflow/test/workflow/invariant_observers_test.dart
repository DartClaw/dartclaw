import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'invariant_observers.dart';

void main() {
  group('WorkspaceFileWriteObserver', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('wfw_observer_');
      File(p.join(tempDir.path, 'existing.txt')).writeAsStringSync('baseline\n');
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    test('diff detects new files created after snapshot', () async {
      final observer = WorkspaceFileWriteObserver.snapshot(tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      File(p.join(tempDir.path, 'new.txt')).writeAsStringSync('leaked\n');
      expect(observer.diff(), ['new.txt']);
    });

    test('diff detects modification of a file that existed at snapshot time', () async {
      final observer = WorkspaceFileWriteObserver.snapshot(tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      File(p.join(tempDir.path, 'existing.txt')).writeAsStringSync('changed\n');
      expect(observer.diff(), ['existing.txt']);
    });

    test('ignored dirs are excluded (default: .git, .dartclaw, .dart_tool)', () async {
      Directory(p.join(tempDir.path, '.git')).createSync();
      File(p.join(tempDir.path, '.git', 'HEAD')).writeAsStringSync('ref');
      final observer = WorkspaceFileWriteObserver.snapshot(tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      File(p.join(tempDir.path, '.git', 'index')).writeAsStringSync('idx');
      File(p.join(tempDir.path, 'authorized.md')).writeAsStringSync('ok');
      expect(observer.diff(), ['authorized.md']);
    });

    test('expectOnly passes when only allowed paths were written', () async {
      final observer = WorkspaceFileWriteObserver.snapshot(tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      Directory(p.join(tempDir.path, 'docs', 'specs', 'test')).createSync(recursive: true);
      File(p.join(tempDir.path, 'docs', 'specs', 'test', 'plan.md')).writeAsStringSync('plan');
      observer.expectOnly(['docs/specs/test/plan.md']);
    });

    test('expectOnly fails listing unauthorized paths when unexpected files changed', () async {
      final observer = WorkspaceFileWriteObserver.snapshot(tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      File(p.join(tempDir.path, 'plan.md')).writeAsStringSync('plan');
      File(p.join(tempDir.path, 'leaked.md')).writeAsStringSync('leaked');
      expect(
        () => observer.expectOnly(['plan.md']),
        throwsA(
          isA<TestFailure>().having((f) => f.message, 'message', contains('leaked.md')),
        ),
      );
    });

    test('expectOnly supports glob wildcards inside a path segment', () async {
      final observer = WorkspaceFileWriteObserver.snapshot(tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      Directory(p.join(tempDir.path, 'fis')).createSync();
      File(p.join(tempDir.path, 'fis', 's01-a.md')).writeAsStringSync('a');
      File(p.join(tempDir.path, 'fis', 's02-b.md')).writeAsStringSync('b');
      observer.expectOnly(['fis/*.md']);
    });

    test('expectNotTouched catches writes to a forbidden file anywhere in tree', () async {
      final observer = WorkspaceFileWriteObserver.snapshot(tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      Directory(p.join(tempDir.path, 'docs')).createSync();
      File(p.join(tempDir.path, 'docs', 'STATE.md')).writeAsStringSync('state');
      expect(
        () => observer.expectNotTouched(['STATE.md']),
        throwsA(
          isA<TestFailure>().having((f) => f.message, 'message', contains('STATE.md')),
        ),
      );
    });
  });

  group('LogInvariantObserver', () {
    test('detects forbidden warning matching default pattern', () async {
      final observer = LogInvariantObserver.defaults();
      observer.start();
      addTearDown(observer.dispose);

      Logger('Test').warning('the step prd requires a worktree but has no worktree metadata');

      expect(
        observer.expectClean,
        throwsA(
          isA<TestFailure>().having((f) => f.message, 'message', contains('requires a worktree')),
        ),
      );
    });

    test('ignores unrelated warnings', () async {
      final observer = LogInvariantObserver.defaults();
      observer.start();
      addTearDown(observer.dispose);

      Logger('Test').warning('some unrelated note');
      observer.expectClean();
    });

    test('respects user-supplied extra patterns', () async {
      final observer = LogInvariantObserver.defaults(extra: [RegExp(r'Forbidden marker \d+')]);
      observer.start();
      addTearDown(observer.dispose);

      Logger('Test').warning('Forbidden marker 42');
      expect(observer.expectClean, throwsA(isA<TestFailure>()));
    });

    test('capture() records WARNING+ records without any forbidden rules', () async {
      final observer = LogInvariantObserver.capture();
      observer.start();
      addTearDown(observer.dispose);

      Logger('Promotion').warning('promotion failed: merge conflict');
      Logger('Other').info('informational — should not be captured');

      expect(observer.records, hasLength(1));
      expect(observer.records.first.message, contains('merge conflict'));
      observer.expectClean();
    });

    test('expectRecord matches on pattern + level + loggerName when specified', () async {
      final observer = LogInvariantObserver.capture();
      observer.start();
      addTearDown(observer.dispose);

      Logger('MapStepContext').warning('Map iteration [0] failed (task=abc): promotion failed: X');

      observer
        ..expectRecord(pattern: RegExp(r'Map iteration \[\d+\] failed'))
        ..expectRecord(level: Level.WARNING, pattern: 'promotion failed')
        ..expectRecord(loggerName: 'MapStepContext', pattern: 'task=abc');
    });

    test('expectRecord fails with diagnostic listing all observed records', () async {
      final observer = LogInvariantObserver.capture();
      observer.start();
      addTearDown(observer.dispose);

      Logger('A').warning('first');
      Logger('B').severe('second');

      expect(
        () => observer.expectRecord(pattern: 'unseen pattern'),
        throwsA(
          isA<TestFailure>()
              .having((f) => f.message, 'message', allOf(contains('[WARNING] A: first'), contains('[SEVERE] B: second'))),
        ),
      );
    });

    test('expectRecord fails clearly when no records were captured', () async {
      final observer = LogInvariantObserver.capture();
      observer.start();
      addTearDown(observer.dispose);

      expect(
        () => observer.expectRecord(pattern: 'anything'),
        throwsA(
          isA<TestFailure>().having((f) => f.message, 'message', contains('No records were captured')),
        ),
      );
    });

    test('capture minimumLevel=INFO includes INFO records', () async {
      final observer = LogInvariantObserver.capture(minimumLevel: Level.INFO);
      observer.start();
      addTearDown(observer.dispose);

      Logger('Test').info('informational');
      expect(observer.records.where((r) => r.message == 'informational'), hasLength(1));
    });
  });

  group('TokenCeilingObserver', () {
    test('passes when every step is under the default ceiling', () {
      final observer = TokenCeilingObserver(defaultCeiling: 1000)
        ..record('plan', 800)
        ..record('review', 500);
      observer.expectAllWithinCeilings();
    });

    test('fails when a step exceeds the default ceiling', () {
      final observer = TokenCeilingObserver(defaultCeiling: 1000)..record('plan', 2500);
      expect(
        observer.expectAllWithinCeilings,
        throwsA(isA<TestFailure>().having((f) => f.message, 'message', contains('plan: 2500 > 1000'))),
      );
    });

    test('per-step override lifts the ceiling for legitimately heavy steps', () {
      final observer = TokenCeilingObserver(
        defaultCeiling: 1000,
        ceilings: {'plan': 5000},
      )
        ..record('plan', 4500)
        ..record('review', 500);
      observer.expectAllWithinCeilings();
    });

    test('record accumulates per step across multiple turns', () {
      final observer = TokenCeilingObserver(defaultCeiling: 1000)
        ..record('plan', 400)
        ..record('plan', 400)
        ..record('plan', 400);
      expect(
        observer.expectAllWithinCeilings,
        throwsA(isA<TestFailure>().having((f) => f.message, 'message', contains('plan: 1200 > 1000'))),
      );
    });
  });
}
