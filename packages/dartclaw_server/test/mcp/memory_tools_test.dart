import 'package:dartclaw_server/src/mcp/memory_tools.dart';
import 'package:test/test.dart';

void main() {
  group('MemorySaveTool', () {
    test('has correct name and schema', () {
      final tool = MemorySaveTool(handler: (args) async => {});
      expect(tool.name, 'memory_save');
      expect(tool.description, isNotEmpty);
      expect(tool.inputSchema['type'], 'object');
      final required = tool.inputSchema['required'] as List;
      expect(required, contains('text'));
    });

    test('invokes handler and returns extracted text', () async {
      final tool = MemorySaveTool(
        handler: (args) async => {
              'content': [
                {'type': 'text', 'text': 'Saved 2 chunk(s) to memory.'},
              ],
            },
      );

      final result = await tool.call({'text': 'hello', 'category': 'test'});
      expect(result, 'Saved 2 chunk(s) to memory.');
    });
  });

  group('MemorySearchTool', () {
    test('has correct name and schema', () {
      final tool = MemorySearchTool(handler: (args) async => {});
      expect(tool.name, 'memory_search');
      expect(tool.description, isNotEmpty);
      final required = tool.inputSchema['required'] as List;
      expect(required, contains('query'));
    });

    test('invokes handler and returns extracted text', () async {
      final tool = MemorySearchTool(
        handler: (args) async => {
              'content': [
                {'type': 'text', 'text': '- [general] Some result (score: 1.00)'},
              ],
            },
      );

      final result = await tool.call({'query': 'test'});
      expect(result, contains('Some result'));
    });
  });

  group('MemoryReadTool', () {
    test('has correct name and schema', () {
      final tool = MemoryReadTool(handler: (args) async => {});
      expect(tool.name, 'memory_read');
      expect(tool.description, isNotEmpty);
    });

    test('invokes handler and returns extracted text', () async {
      final tool = MemoryReadTool(
        handler: (args) async => {
              'content': [
                {'type': 'text', 'text': '## general\n- Some memory entry'},
              ],
            },
      );

      final result = await tool.call({});
      expect(result, contains('Some memory entry'));
    });
  });
}
