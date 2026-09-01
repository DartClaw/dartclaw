import 'package:dartclaw_runtime/src/mcp/search_provider.dart';
import 'package:test/test.dart';

void main() {
  group('decodeSearchResults', () {
    test('normalizes provider-specific snippet fields', () {
      final brave = decodeSearchResults([
        {'title': 'Brave result', 'url': 'https://brave.example', 'description': 'Brave snippet'},
      ], snippetField: 'description');
      final tavily = decodeSearchResults([
        {'title': 'Tavily result', 'url': 'https://tavily.example', 'content': 'Tavily snippet'},
      ], snippetField: 'content');

      expect(brave.single.toJson(), {
        'title': 'Brave result',
        'url': 'https://brave.example',
        'snippet': 'Brave snippet',
      });
      expect(tavily.single.toJson(), {
        'title': 'Tavily result',
        'url': 'https://tavily.example',
        'snippet': 'Tavily snippet',
      });
    });

    test('defaults missing nullable fields to empty strings', () {
      final results = decodeSearchResults([<String, dynamic>{}], snippetField: 'content');

      expect(results.single.toJson(), {'title': '', 'url': '', 'snippet': ''});
    });

    test('rejects non-object result entries', () {
      expect(() => decodeSearchResults(['invalid'], snippetField: 'content'), throwsA(isA<TypeError>()));
    });
  });
}
