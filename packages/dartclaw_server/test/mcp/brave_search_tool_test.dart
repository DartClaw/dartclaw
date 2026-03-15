import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/brave_search_tool.dart';
import 'package:dartclaw_server/src/mcp/search_provider.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class _MockProvider implements SearchProvider {
  List<SearchResult> results;
  bool shouldThrow;
  String errorMessage;

  _MockProvider({this.results = const [], this.shouldThrow = false, this.errorMessage = 'provider error'});

  @override
  Future<List<SearchResult>> search(String query, {int count = 5}) async {
    if (shouldThrow) throw Exception(errorMessage);
    return results.take(count).toList();
  }
}

class _FakeClassifier implements ContentClassifier {
  String result;
  _FakeClassifier({this.result = 'safe'});

  @override
  Future<String> classify(String content, {Duration timeout = const Duration(seconds: 15)}) async {
    return result;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _text(ToolResult r) => (r as ToolResultText).content;
String _errorMsg(ToolResult r) => (r as ToolResultError).message;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('BraveSearchTool', () {
    group('MCP interface', () {
      test('name is brave_search', () {
        final tool = BraveSearchTool(provider: _MockProvider());
        expect(tool.name, 'brave_search');
      });

      test('inputSchema has correct structure', () {
        final tool = BraveSearchTool(provider: _MockProvider());
        expect(tool.inputSchema['type'], 'object');
        final required = tool.inputSchema['required'] as List;
        expect(required, contains('query'));
        final props = tool.inputSchema['properties'] as Map<String, dynamic>;
        expect(props.containsKey('query'), isTrue);
        expect(props.containsKey('count'), isTrue);
      });

      test('description is non-empty', () {
        final tool = BraveSearchTool(provider: _MockProvider());
        expect(tool.description, isNotEmpty);
      });
    });

    group('input validation', () {
      test('missing query returns error', () async {
        final tool = BraveSearchTool(provider: _MockProvider());
        final result = await tool.call({});
        expect(result, isA<ToolResultError>());
        expect(_errorMsg(result), contains('query'));
      });

      test('empty query returns error', () async {
        final tool = BraveSearchTool(provider: _MockProvider());
        final result = await tool.call({'query': ''});
        expect(result, isA<ToolResultError>());
      });
    });

    group('search results', () {
      test('successful search returns JSON with results', () async {
        final provider = _MockProvider(
          results: [
            SearchResult(title: 'Title 1', url: 'https://a.com', snippet: 'Snippet 1'),
            SearchResult(title: 'Title 2', url: 'https://b.com', snippet: 'Snippet 2'),
          ],
        );
        final tool = BraveSearchTool(provider: provider);
        final result = await tool.call({'query': 'test'});
        final json = jsonDecode(_text(result)) as Map<String, dynamic>;
        expect(json['provider'], 'brave');
        expect(json['query'], 'test');
        final results = json['results'] as List;
        expect(results, hasLength(2));
        expect(results[0]['title'], 'Title 1');
        expect(results[0]['url'], 'https://a.com');
        expect(results[0]['snippet'], 'Snippet 1');
      });

      test('empty results returns JSON with empty array', () async {
        final provider = _MockProvider(results: []);
        final tool = BraveSearchTool(provider: provider);
        final result = await tool.call({'query': 'test'});
        final json = jsonDecode(_text(result)) as Map<String, dynamic>;
        expect(json['results'], isEmpty);
        expect(json['count'], 0);
      });

      test('provider error returns error result', () async {
        final provider = _MockProvider(shouldThrow: true, errorMessage: 'API down');
        final tool = BraveSearchTool(provider: provider);
        final result = await tool.call({'query': 'test'});
        expect(result, isA<ToolResultError>());
        expect(_errorMsg(result), contains('Brave search failed'));
        expect(_errorMsg(result), contains('API down'));
        expect(_errorMsg(result), contains('WebSearch as fallback'));
      });

      test('count clamped to 1-20 range', () async {
        final provider = _MockProvider(
          results: [SearchResult(title: 'T', url: 'https://a.com', snippet: 'S')],
        );
        final tool = BraveSearchTool(provider: provider);

        // count=0 clamped to 1
        var result = await tool.call({'query': 'test', 'count': 0});
        var json = jsonDecode(_text(result)) as Map<String, dynamic>;
        expect(json['results'], isA<List<dynamic>>());

        // count=50 clamped to 20
        result = await tool.call({'query': 'test', 'count': 50});
        json = jsonDecode(_text(result)) as Map<String, dynamic>;
        expect(json['results'], isA<List<dynamic>>());
      });
    });

    group('ContentGuard integration', () {
      test('safe content passes through', () async {
        final classifier = _FakeClassifier(result: 'safe');
        final guard = ContentGuard(classifier: classifier);
        final provider = _MockProvider(
          results: [SearchResult(title: 'Title', url: 'https://a.com', snippet: 'Safe text')],
        );
        final tool = BraveSearchTool(provider: provider, contentGuard: guard);
        final result = await tool.call({'query': 'test'});
        expect(result, isA<ToolResultText>());
        final json = jsonDecode(_text(result)) as Map<String, dynamic>;
        expect(json['results'], hasLength(1));
      });

      test('blocked content returns error result', () async {
        final classifier = _FakeClassifier(result: 'prompt_injection');
        final guard = ContentGuard(classifier: classifier);
        final provider = _MockProvider(
          results: [SearchResult(title: 'Bad', url: 'https://a.com', snippet: 'Injected content')],
        );
        final tool = BraveSearchTool(provider: provider, contentGuard: guard);
        final result = await tool.call({'query': 'test'});
        expect(result, isA<ToolResultError>());
        expect(_errorMsg(result), contains('Search results blocked by content guard'));
      });

      test('no guard (null) passes content through', () async {
        final provider = _MockProvider(
          results: [SearchResult(title: 'Title', url: 'https://a.com', snippet: 'Text')],
        );
        final tool = BraveSearchTool(provider: provider);
        final result = await tool.call({'query': 'test'});
        expect(result, isA<ToolResultText>());
        final json = jsonDecode(_text(result)) as Map<String, dynamic>;
        expect(json['results'], hasLength(1));
      });
    });
  });
}
