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

    test('maps Edit and edit_file to file_edit', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.mapToolName('Edit'), CanonicalTool.fileEdit);
      expect(adapter.mapToolName('edit_file'), CanonicalTool.fileEdit);
    });

    test('maps WebFetch/web_fetch and mcp_* tools', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.mapToolName('WebFetch'), CanonicalTool.webFetch);
      expect(adapter.mapToolName('web_fetch'), CanonicalTool.webFetch);
      expect(adapter.mapToolName('mcp_tool_call'), CanonicalTool.mcpCall);
    });

    test('returns null for unknown, empty, and lowercase Bash', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.mapToolName('unknown_tool'), isNull);
      expect(adapter.mapToolName(''), isNull);
      expect(adapter.mapToolName('bash'), isNull);
    });
  });
}
