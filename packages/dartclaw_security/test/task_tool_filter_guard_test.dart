import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

GuardContext _ctx({required String hookPoint, String? toolName, String? sessionId, Map<String, dynamic>? toolInput}) {
  return GuardContext(
    hookPoint: hookPoint,
    toolName: toolName,
    toolInput: toolInput,
    sessionId: sessionId,
    timestamp: DateTime.now(),
  );
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

    test('sentinel allowlist blocks read and network tools for toolless turns', () async {
      guard.allowedTools = ['__knowledge_inbox_no_tools__'];

      final fileVerdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'file_read'));
      final networkVerdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch'));

      expect(fileVerdict.isBlock, isTrue);
      expect(networkVerdict.isBlock, isTrue);
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

    test('session tool filters only affect the matching active session', () async {
      guard.setSessionToolFilter('inbox-session', ['__knowledge_inbox_no_tools__']);

      final inboxVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch', sessionId: 'inbox-session'),
      );
      final interactiveVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch', sessionId: 'interactive-session'),
      );

      expect(inboxVerdict.isBlock, isTrue);
      expect(interactiveVerdict.isPass, isTrue);

      guard.setSessionToolFilter('inbox-session', null);
      expect(
        (await guard.evaluate(
          _ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch', sessionId: 'inbox-session'),
        )).isPass,
        isTrue,
      );
    });

    test('session read-only mode only affects the matching active session', () async {
      guard.setSessionReadOnly('inbox-session', true);

      final inboxVerdict = await guard.evaluate(
        _ctx(
          hookPoint: 'beforeToolCall',
          toolName: 'shell',
          sessionId: 'inbox-session',
          toolInput: {'command': 'touch generated.txt'},
        ),
      );
      final interactiveVerdict = await guard.evaluate(
        _ctx(
          hookPoint: 'beforeToolCall',
          toolName: 'shell',
          sessionId: 'interactive-session',
          toolInput: {'command': 'touch generated.txt'},
        ),
      );

      expect(inboxVerdict.isBlock, isTrue);
      expect(interactiveVerdict.isPass, isTrue);

      guard.setSessionReadOnly('inbox-session', false);
      expect(
        (await guard.evaluate(
          _ctx(
            hookPoint: 'beforeToolCall',
            toolName: 'shell',
            sessionId: 'inbox-session',
            toolInput: {'command': 'touch generated.txt'},
          ),
        )).isPass,
        isTrue,
      );
    });

    test('guard name and category', () {
      expect(guard.name, 'task_tool_filter');
      expect(guard.category, 'tool');
    });
  });
}
