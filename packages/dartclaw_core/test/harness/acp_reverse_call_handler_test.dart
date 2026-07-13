import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/harness/acp_reverse_call_handlers.dart' show AcpReverseCallHandlers;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_test_support.dart';

void main() {
  group('ACP reverse-call handlers', () {
    late Directory serviceRoot;
    late Directory worktree;

    setUp(() async {
      serviceRoot = await Directory.systemTemp.createTemp('dartclaw_acp_service_');
      worktree = await Directory.systemTemp.createTemp('dartclaw_acp_worktree_');
    });

    tearDown(() async {
      for (final directory in [serviceRoot, worktree]) {
        if (directory.existsSync()) {
          await directory.delete(recursive: true);
        }
      }
    });

    test('file calls use the active turn workspace and session authorization', () async {
      final guard = RecordingGuard();
      final handlers = AcpReverseCallHandlers(guardChain: GuardChain(guards: [guard]));
      handlers.bindTurn(sessionId: 'task-session', effectiveDirectory: worktree.path);
      await File(p.join(worktree.path, 'allowed.txt')).writeAsString('visible');

      final read = await handlers.readTextFile({'path': 'allowed.txt'});
      final write = await handlers.writeTextFile({'path': 'created.txt', 'content': 'new'});

      expect(read, containsPair('content', 'visible'));
      expect(write, containsPair('ok', true));
      expect(File(p.join(worktree.path, 'created.txt')).readAsStringSync(), 'new');
      expect(File(p.join(serviceRoot.path, 'created.txt')).existsSync(), isFalse);
      expect(guard.contexts.map((context) => context.sessionId), everyElement('task-session'));
      expect(guard.contexts.map((context) => context.rawProviderToolName), ['fs/read_text_file', 'fs/write_text_file']);
    });

    test('session-scoped read-only policy blocks writes', () async {
      final taskGuard = TaskToolFilterGuard();
      taskGuard.setSessionReadOnly('read-only-session', true);
      final handlers = AcpReverseCallHandlers(guardChain: GuardChain(guards: [taskGuard]));
      handlers.bindTurn(sessionId: 'read-only-session', effectiveDirectory: worktree.path);

      final response = await handlers.writeTextFile({'path': 'denied.txt', 'content': 'must not land'});

      expect(response, containsPair('noAccess', true));
      expect(File(p.join(worktree.path, 'denied.txt')).existsSync(), isFalse);
    });

    test('reverse calls fail closed outside an active turn', () async {
      final handlers = AcpReverseCallHandlers();

      await expectLater(handlers.readTextFile({'path': 'missing.txt'}), throwsA(isA<Exception>()));
      await expectLater(handlers.writeTextFile({'path': 'created.txt', 'content': 'no'}), throwsA(isA<Exception>()));
      expect(File(p.join(serviceRoot.path, 'created.txt')).existsSync(), isFalse);
    });

    test('active workspace jail rejects traversal and symlink escape', () async {
      final outside = await Directory.systemTemp.createTemp('dartclaw_acp_outside_');
      addTearDown(() async {
        if (outside.existsSync()) {
          await outside.delete(recursive: true);
        }
      });
      await File(p.join(outside.path, 'secret.txt')).writeAsString('outside');
      await Link(p.join(worktree.path, 'outside-link')).create(outside.path);
      final handlers = AcpReverseCallHandlers()..bindTurn(sessionId: 'session-1', effectiveDirectory: worktree.path);

      await expectLater(handlers.readTextFile({'path': '../outside.txt'}), throwsA(isA<Exception>()));
      await expectLater(handlers.readTextFile({'path': 'outside-link/secret.txt'}), throwsA(isA<Exception>()));
    });

    test('permission requests require an active turn', () async {
      final handlers = AcpReverseCallHandlers(
        permissionDecision: (request) async => const AcpPermissionResult(granted: false, reason: 'denied'),
      );

      await expectLater(handlers.requestPermission({'operation': 'file_write'}), throwsA(isA<Exception>()));

      handlers.bindTurn(sessionId: 'session-1', effectiveDirectory: worktree.path);
      final response = await handlers.requestPermission({'operation': 'file_write'});
      expect(response, containsPair('granted', false));
      expect(response, containsPair('reason', 'denied'));
    });

    test('turn unbind drains accepted calls and rejects new calls', () async {
      final guard = _BlockingGuard();
      final handlers = AcpReverseCallHandlers(guardChain: GuardChain(guards: [guard]));
      handlers.bindTurn(sessionId: 'session-1', effectiveDirectory: worktree.path);

      final write = handlers.writeTextFile({'path': 'accepted.txt', 'content': 'accepted'});
      await guard.entered.future;
      var unbound = false;
      final unbind = handlers.unbindTurn('session-1').then((_) => unbound = true);
      await Future<void>.delayed(Duration.zero);

      expect(unbound, isFalse);
      await expectLater(handlers.writeTextFile({'path': 'late.txt', 'content': 'late'}), throwsA(isA<Exception>()));
      guard.release.complete();
      await write;
      await unbind;

      expect(File(p.join(worktree.path, 'accepted.txt')).readAsStringSync(), 'accepted');
      expect(File(p.join(worktree.path, 'late.txt')).existsSync(), isFalse);
    });
  });
}

final class _BlockingGuard extends Guard {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  String get name => 'blocking';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return GuardVerdict.pass();
  }
}
