import 'dart:io';

import 'package:dartclaw_core/src/harness/acp_reverse_call_handlers.dart' show AcpReverseCallHandlers;
import 'package:test/test.dart';

void main() {
  group('ACP terminal handlers', () {
    late Directory workspace;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('dartclaw_acp_terminal_');
    });

    tearDown(() async {
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    test('terminal capability remains disabled until process-tree containment exists', () {
      final handlers = AcpReverseCallHandlers();

      expect(handlers.capabilityFlags['terminal'], isFalse);
      expect(handlers.ownsTerminals, isFalse);
    });

    test('terminal create is rejected during an active turn without spawning', () async {
      final handlers = AcpReverseCallHandlers();
      handlers.bindTurn(sessionId: 'session-1', effectiveDirectory: workspace.path);

      await expectLater(
        handlers.createTerminal({
          'command': 'echo hello',
          'env': {'PATH': workspace.path},
        }),
        throwsA(isA<Exception>()),
      );

      expect(await handlers.disposeTerminals(), isTrue);
    });

    test('terminal calls without an active turn fail closed', () async {
      final handlers = AcpReverseCallHandlers();

      await expectLater(handlers.createTerminal({'command': 'echo hello'}), throwsA(isA<Exception>()));
    });
  });
}
