import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ClaudeProtocolAdapter.mapToolName', () {
    test('maps Bash to shell', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.mapToolName('Bash'), CanonicalTool.shell);
    });

    test('maps Read to file_read', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.mapToolName('Read'), CanonicalTool.fileRead);
    });

    test('maps Write and write_file to file_write', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.mapToolName('Write'), CanonicalTool.fileWrite);
      expect(adapter.mapToolName('write_file'), CanonicalTool.fileWrite);
    });

    test('maps Edit, NotebookEdit, and edit_file to file_edit', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.mapToolName('Edit'), CanonicalTool.fileEdit);
      expect(adapter.mapToolName('NotebookEdit'), CanonicalTool.fileEdit);
      expect(adapter.mapToolName('edit_file'), CanonicalTool.fileEdit);
    });

    test('maps WebFetch/web_fetch and mcp_* tools', () {
      final adapter = ClaudeProtocolAdapter(
        ownMcpToolCanonicals: const {
          'web_fetch': CanonicalTool.webFetch,
          'brave_search': CanonicalTool.webSearch,
          'memory_apply': CanonicalTool.memoryApply,
          'memory_observe': CanonicalTool.memoryObserve,
          'memory_search': CanonicalTool.memorySearch,
          'memory_read': CanonicalTool.memoryRead,
          'sessions_spawn': CanonicalTool.sessionsSpawn,
          'sessions_send': CanonicalTool.sessionsSend,
        },
      );
      expect(adapter.mapToolName('WebFetch'), CanonicalTool.webFetch);
      expect(adapter.mapToolName('web_fetch'), CanonicalTool.webFetch);
      expect(adapter.mapToolName('WebSearch'), CanonicalTool.webSearch);
      expect(adapter.mapToolName('mcp__dartclaw__web_fetch'), CanonicalTool.webFetch);
      expect(adapter.mapToolName('mcp__dartclaw__brave_search'), CanonicalTool.webSearch);
      expect(adapter.mapToolName('mcp__dartclaw__memory_apply'), CanonicalTool.memoryApply);
      expect(adapter.mapToolName('mcp__dartclaw__memory_observe'), CanonicalTool.memoryObserve);
      expect(adapter.mapToolName('mcp__dartclaw__memory_search'), CanonicalTool.memorySearch);
      expect(adapter.mapToolName('mcp__dartclaw__memory_read'), CanonicalTool.memoryRead);
      expect(adapter.mapToolName('mcp__dartclaw__sessions_spawn'), CanonicalTool.sessionsSpawn);
      expect(adapter.mapToolName('mcp__dartclaw__sessions_send'), CanonicalTool.sessionsSend);
      expect(adapter.mapToolName('mcp__dartclaw__unknown'), CanonicalTool.mcpCall);
      expect(adapter.mapToolName('mcp__third_party__web_fetch'), CanonicalTool.mcpCall);
    });

    test('returns null for unknown, empty, and lowercase Bash', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.mapToolName('unknown_tool'), isNull);
      expect(adapter.mapToolName(''), isNull);
      expect(adapter.mapToolName('bash'), isNull);
    });
  });
}
