import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/memory_tools.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryObserveTool', () {
    test('exposes only text and the closed capture role', () {
      final tool = MemoryObserveTool(handler: (args) async => {});
      final schema = tool.inputSchema;
      final properties = schema['properties'] as Map<String, dynamic>;

      expect(tool.name, 'memory_observe');
      expect(schema['required'], ['text', 'role']);
      expect(schema['additionalProperties'], isFalse);
      expect(properties.keys, unorderedEquals(['text', 'role']));
      expect((properties['role'] as Map<String, dynamic>)['enum'], ['observation', 'learning']);
    });
  });

  group('MemoryApplyTool', () {
    test('exposes a closed atomic operation schema', () {
      final tool = MemoryApplyTool(handler: (args) async => {});
      expect(tool.name, 'memory_apply');
      expect(tool.inputSchema['type'], 'object');
      final required = tool.inputSchema['required'] as List;
      expect(required, ['expectedRevision', 'operations']);
      final properties = tool.inputSchema['properties'] as Map<String, dynamic>;
      expect(properties.keys, unorderedEquals(['expectedRevision', 'operations']));
      expect(properties['operations'], containsPair('minItems', 1));
      final operationSchema = (properties['operations'] as Map<String, dynamic>)['items'] as Map<String, dynamic>;
      expect(operationSchema['oneOf'], hasLength(4));
      for (final schema in (operationSchema['oneOf'] as List).cast<Map<String, dynamic>>()) {
        expect(schema['additionalProperties'], isFalse);
      }
    });

    test('invokes handler and returns extracted text', () async {
      final tool = MemoryApplyTool(
        handler: (args) async => {
          'content': [
            {'type': 'text', 'text': '{"canonicalOutcome":"committed"}'},
          ],
        },
      );

      final result = await tool.call({'expectedRevision': 1, 'operations': []});
      expect(result, isA<ToolResultText>());
      expect((result as ToolResultText).content, contains('committed'));
    });
  });

  group('MemorySearchTool', () {
    test('has correct name and schema', () {
      final tool = MemorySearchTool(handler: (args) async => {});
      expect(tool.name, 'memory_search');
      final required = tool.inputSchema['required'] as List;
      expect(required, contains('query'));
      final limit = (tool.inputSchema['properties'] as Map<String, dynamic>)['limit'] as Map<String, dynamic>;
      expect(limit, containsPair('type', 'integer'));
      expect(limit, containsPair('minimum', 1));
      expect(limit, containsPair('maximum', 50));
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
      expect(result, isA<ToolResultText>());
      expect((result as ToolResultText).content, contains('Some result'));
    });
  });

  group('MemoryReadTool', () {
    test('has correct name and schema', () {
      final tool = MemoryReadTool(handler: (args) async => {});
      expect(tool.name, 'memory_read');
      expect(tool.description, isNotEmpty);
      final schema = tool.inputSchema;
      final properties = schema['properties'] as Map<String, dynamic>;
      expect(schema['oneOf'], hasLength(2));
      expect(properties.keys, unorderedEquals(['locator', 'role', 'topic', 'limit']));
      expect((properties['role'] as Map<String, dynamic>)['enum'], ['topic', 'archive']);
    });

    test('invokes handler and returns extracted text', () async {
      final tool = MemoryReadTool(
        handler: (args) async => {
          'content': [
            {'type': 'text', 'text': '## general\n- Some memory entry'},
          ],
        },
      );

      final result = await tool.call({'locator': 'entry-id'});
      expect(result, isA<ToolResultText>());
      expect((result as ToolResultText).content, contains('Some memory entry'));
    });
  });
}
