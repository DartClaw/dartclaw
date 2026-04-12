import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

GuardContext _ctx({required String hookPoint, String? toolName}) {
  return GuardContext(hookPoint: hookPoint, toolName: toolName, timestamp: DateTime.now());
}

void main() {
  group('TaskToolFilterGuard', () {
    late TaskToolFilterGuard guard;

    setUp(() {
      guard = TaskToolFilterGuard();
    });

    test('null allowedTools — all tools pass', () async {
      guard.allowedTools = null;
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'));
      expect(verdict.isPass, isTrue);
    });

    test('empty allowedTools — all tools pass', () async {
      guard.allowedTools = [];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'));
      expect(verdict.isPass, isTrue);
    });

    test('tool in allowedTools — pass', () async {
      guard.allowedTools = ['shell', 'file_read'];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'));
      expect(verdict.isPass, isTrue);
    });

    test('tool not in allowedTools — block with message', () async {
      guard.allowedTools = ['file_read'];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'));
      expect(verdict.isBlock, isTrue);
      expect(verdict.message, contains('shell'));
      expect(verdict.message, contains('file_read'));
    });

    test('mcp_call in allowedTools — pass', () async {
      guard.allowedTools = ['shell', 'file_read', 'mcp_call'];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'mcp_call'));
      expect(verdict.isPass, isTrue);
    });

    test('non-beforeToolCall hookPoint — always pass', () async {
      guard.allowedTools = ['file_read'];
      final messageCtx = GuardContext(hookPoint: 'messageReceived', timestamp: DateTime.now());
      final agentCtx = GuardContext(hookPoint: 'beforeAgentSend', timestamp: DateTime.now());
      expect((await guard.evaluate(messageCtx)).isPass, isTrue);
      expect((await guard.evaluate(agentCtx)).isPass, isTrue);
    });

    test('null toolName — pass', () async {
      guard.allowedTools = ['file_read'];
      final verdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: null));
      expect(verdict.isPass, isTrue);
    });

    test('allowedTools can be updated between turns', () async {
      guard.allowedTools = ['file_read'];
      expect((await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'))).isBlock, isTrue);

      guard.allowedTools = null;
      expect((await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'shell'))).isPass, isTrue);
    });

    test('guard name and category', () {
      expect(guard.name, 'task_tool_filter');
      expect(guard.category, 'tool');
    });
  });
}
