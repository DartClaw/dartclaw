import 'dart:io';

import 'package:dartclaw_server/src/task/task_file_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('TaskFileGuard', () {
    late TaskFileGuard guard;

    setUp(() {
      guard = TaskFileGuard();
    });

    test('register and isAllowed for path within worktree', () {
      guard.register('task-1', '/data/worktrees/task-1');
      expect(guard.isAllowed('task-1', '/data/worktrees/task-1/src/main.dart'), isTrue);
    });

    test('isAllowed returns true for exact worktree path', () {
      guard.register('task-1', '/data/worktrees/task-1');
      expect(guard.isAllowed('task-1', '/data/worktrees/task-1'), isTrue);
    });

    test('isAllowed returns false for path outside worktree', () {
      guard.register('task-1', '/data/worktrees/task-1');
      expect(guard.isAllowed('task-1', '/data/worktrees/task-2/src/main.dart'), isFalse);
      expect(guard.isAllowed('task-1', '/etc/passwd'), isFalse);
    });

    test('isAllowed returns false for unregistered task', () {
      expect(guard.isAllowed('task-unknown', '/data/worktrees/task-1/file.dart'), isFalse);
    });

    test('deregister removes access', () {
      guard.register('task-1', '/data/worktrees/task-1');
      expect(guard.isAllowed('task-1', '/data/worktrees/task-1/file.dart'), isTrue);

      guard.deregister('task-1');
      expect(guard.isAllowed('task-1', '/data/worktrees/task-1/file.dart'), isFalse);
    });

    test('isAllowed handles parent directory traversal (../)', () {
      final tmpDir = Directory.systemTemp.createTempSync('file_guard_test_');
      try {
        final worktreePath = p.join(tmpDir.path, 'worktree');
        Directory(worktreePath).createSync();

        guard.register('task-1', worktreePath);
        // ../../../etc/passwd relative to worktree
        final traversalPath = p.join(worktreePath, '..', '..', '..', 'etc', 'passwd');
        expect(guard.isAllowed('task-1', traversalPath), isFalse);
      } finally {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('hasRegistration tracks state correctly', () {
      expect(guard.hasRegistration('task-1'), isFalse);
      guard.register('task-1', '/data/worktrees/task-1');
      expect(guard.hasRegistration('task-1'), isTrue);
      guard.deregister('task-1');
      expect(guard.hasRegistration('task-1'), isFalse);
    });

    test('getPath returns registered path', () {
      expect(guard.getPath('task-1'), isNull);
      guard.register('task-1', '/data/worktrees/task-1');
      expect(guard.getPath('task-1'), endsWith('task-1'));
    });
  });
}
