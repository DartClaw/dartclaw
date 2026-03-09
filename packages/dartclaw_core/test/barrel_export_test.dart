/// Barrel export surface test — verifies that the public API contract holds.
///
/// Every symbol in the `show` clauses is importable and usable. Sealed class
/// subtypes are accessible via pattern matching even when only the base type
/// appears in the `show` clause.
library;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('barrel exports — sealed class accessibility', () {
    test('BridgeEvent sealed subtypes accessible via pattern matching', () {
      final BridgeEvent delta = DeltaEvent('hello');
      final BridgeEvent toolUse = ToolUseEvent(toolName: 'bash', toolId: 't1', input: {});
      final BridgeEvent toolResult = ToolResultEvent(toolId: 't1', output: 'ok', isError: false);
      final BridgeEvent init = SystemInitEvent(contextWindow: 200000);

      // Pattern matching works — exhaustive switch
      final matched = switch (delta) {
        DeltaEvent(:final text) => text,
        ToolUseEvent() => 'tool',
        ToolResultEvent() => 'result',
        SystemInitEvent() => 'init',
      };
      expect(matched, 'hello');

      // Type checks work
      expect(delta, isA<DeltaEvent>());
      expect(toolUse, isA<ToolUseEvent>());
      expect(toolResult, isA<ToolResultEvent>());
      expect(init, isA<SystemInitEvent>());
    });

    test('GuardVerdict sealed subtypes accessible via factories', () {
      final GuardVerdict pass = GuardVerdict.pass();
      final GuardVerdict warn = GuardVerdict.warn('caution');
      final GuardVerdict block = GuardVerdict.block('denied');

      expect(pass.isPass, isTrue);
      expect(warn.isWarn, isTrue);
      expect(warn.message, 'caution');
      expect(block.isBlock, isTrue);
      expect(block.message, 'denied');
    });
  });

  group('barrel exports — key symbols importable', () {
    test('model types constructable', () {
      final session = Session(id: 'test', createdAt: DateTime.now(), updatedAt: DateTime.now());
      expect(session.id, 'test');
      expect(session.type, SessionType.user);

      final msg = Message(
        cursor: 0,
        id: 'm1',
        sessionId: 'test',
        role: 'user',
        content: 'hello',
        createdAt: DateTime.now(),
      );
      expect(msg.role, 'user');

      final chunk = MemoryChunk(id: 1, textContent: 'fact', source: 'test', createdAt: DateTime.now());
      expect(chunk.textContent, 'fact');

      const result = MemorySearchResult(text: 'fact', source: 'test', score: 0.9);
      expect(result.score, 0.9);
    });

    test('SessionKey constructable', () {
      final key = SessionKey(agentId: 'main', scope: 'channel', identifiers: 'wa:123');
      expect(key.agentId, 'main');
    });

    test('container symbols importable', () {
      const config = ContainerConfig(enabled: true);
      expect(config.enabled, isTrue);
      expect(ContainerManager, isNotNull);
      expect(CredentialProxy, isNotNull);
    });
  });
}
