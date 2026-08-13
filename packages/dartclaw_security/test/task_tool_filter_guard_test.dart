import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

GuardContext _ctx({
  required String hookPoint,
  String? toolName,
  String? rawProviderToolName,
  String? sessionId,
  Map<String, dynamic>? toolInput,
}) {
  return GuardContext(
    hookPoint: hookPoint,
    toolName: toolName,
    rawProviderToolName: rawProviderToolName,
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

    test('closed policy permits Claude tool discovery but not discovered capabilities', () async {
      guard.allowedTools = ['web_search'];

      final discovery = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'claude:ToolSearch', rawProviderToolName: 'ToolSearch'),
      );
      final allowedSearch = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'web_search', rawProviderToolName: 'WebSearch'),
      );
      final unrelatedFetch = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch', rawProviderToolName: 'WebFetch'),
      );

      expect(discovery.isPass, isTrue);
      expect(allowedSearch.isPass, isTrue);
      expect(unrelatedFetch.isBlock, isTrue);
    });

    test('Claude tool discovery requires matching raw and canonical identities', () async {
      guard.allowedTools = ['memory_apply'];

      final rawMismatch = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'shell', rawProviderToolName: 'ToolSearch'),
      );
      final canonicalMismatch = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'claude:ToolSearch', rawProviderToolName: 'Bash'),
      );

      expect(rawMismatch.isBlock, isTrue);
      expect(canonicalMismatch.isBlock, isTrue);
    });

    test('tool discovery remains blocked for a toolless policy', () async {
      guard.allowedTools = ['__knowledge_inbox_no_tools__'];

      final verdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'claude:ToolSearch', rawProviderToolName: 'ToolSearch'),
      );

      expect(verdict.isBlock, isTrue);
    });

    test('sentinel allowlist blocks read and network tools for toolless turns', () async {
      guard.allowedTools = ['__knowledge_inbox_no_tools__'];

      final fileVerdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'file_read'));
      final networkVerdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch'));

      expect(fileVerdict.isBlock, isTrue);
      expect(networkVerdict.isBlock, isTrue);
    });

    test('toolless sentinel dominates a mixed global allowlist', () async {
      guard.allowedTools = ['__knowledge_inbox_no_tools__', 'file_read'];

      final fileVerdict = await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'file_read'));
      final discoveryVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'claude:ToolSearch', rawProviderToolName: 'ToolSearch'),
      );

      expect(fileVerdict.isBlock, isTrue);
      expect(discoveryVerdict.isBlock, isTrue);
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
        (await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: 'web_fetch', sessionId: 'inbox-session')))
            .isPass,
        isTrue,
      );
    });

    test('toolless sentinel dominates a mixed session allowlist', () async {
      guard.setSessionToolFilter('inbox-session', ['__knowledge_inbox_no_tools__', 'file_read']);

      final fileVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'file_read', sessionId: 'inbox-session'),
      );
      final discoveryVerdict = await guard.evaluate(
        _ctx(
          hookPoint: 'beforeToolCall',
          toolName: 'claude:ToolSearch',
          rawProviderToolName: 'ToolSearch',
          sessionId: 'inbox-session',
        ),
      );
      final unrelatedSessionVerdict = await guard.evaluate(
        _ctx(hookPoint: 'beforeToolCall', toolName: 'file_read', sessionId: 'interactive-session'),
      );

      expect(fileVerdict.isBlock, isTrue);
      expect(discoveryVerdict.isBlock, isTrue);
      expect(unrelatedSessionVerdict.isPass, isTrue);
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

    test('read-only policy blocks memory writes but permits retrieval', () async {
      guard.readOnly = true;

      for (final tool in ['memory_apply', 'memory_observe']) {
        expect((await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: tool))).isBlock, isTrue);
      }
      for (final tool in ['memory_search', 'memory_read']) {
        expect((await guard.evaluate(_ctx(hookPoint: 'beforeToolCall', toolName: tool))).isPass, isTrue);
      }
    });

    test('guard name and category', () {
      expect(guard.name, 'task_tool_filter');
      expect(guard.category, 'tool');
    });
  });
}
