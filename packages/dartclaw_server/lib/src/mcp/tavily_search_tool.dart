import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'search_provider.dart';

/// Tavily Search API provider.
class TavilySearchProvider implements SearchProvider {
  static final _log = Logger('TavilySearchProvider');

  final String _apiKey;
  final Duration _timeout;

  TavilySearchProvider({required String apiKey, Duration timeout = const Duration(seconds: 15)})
    : _apiKey = apiKey,
      _timeout = timeout;

  @override
  Future<List<SearchResult>> search(String query, {int count = 5}) async {
    final uri = Uri.https('api.tavily.com', '/search');

    final client = HttpClient();
    client.connectionTimeout = _timeout;
    try {
      final request = await client.postUrl(uri).timeout(_timeout);
      request.headers.set('Content-Type', 'application/json');

      final requestBody = jsonEncode({
        'api_key': _apiKey,
        'query': query,
        'max_results': count,
        'include_raw_content': false,
      });
      request.write(requestBody);

      final response = await request.close().timeout(_timeout);
      final body = await response.transform(utf8.decoder).join().timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: ${response.reasonPhrase}');
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final results = json['results'] as List<dynamic>? ?? [];

      return results.map((r) {
        final item = r as Map<String, dynamic>;
        return SearchResult(
          title: item['title'] as String? ?? '',
          url: item['url'] as String? ?? '',
          snippet: item['content'] as String? ?? '',
        );
      }).toList();
    } on TimeoutException {
      _log.warning('Tavily search timed out after ${_timeout.inSeconds}s');
      rethrow;
    } on SocketException catch (e) {
      _log.warning('Tavily search connection failed: ${e.message}');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

/// MCP tool that searches via Tavily Search API.
class TavilySearchTool implements McpTool {
  final SearchProvider _provider;
  final ContentGuard? _contentGuard;

  TavilySearchTool({required SearchProvider provider, ContentGuard? contentGuard})
    : _provider = provider,
      _contentGuard = contentGuard;

  @override
  String get name => 'tavily_search';

  @override
  String get description => 'Search the web using Tavily Search API. Returns titles, URLs, and snippets.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'Search query'},
      'count': {
        'type': 'integer',
        'description': 'Number of results (1-10, default 5)',
        'default': 5,
        'minimum': 1,
        'maximum': 10,
      },
    },
    'required': ['query'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final query = args['query'] as String?;
    if (query == null || query.isEmpty) {
      return ToolResult.error('Error: missing required parameter "query"');
    }

    final rawCount = args['count'] as int? ?? 5;
    final count = rawCount.clamp(1, 10);

    List<SearchResult> results;
    try {
      results = await _provider.search(query, count: count);
    } on TimeoutException {
      return ToolResult.error('Tavily search timed out. The agent can use WebSearch as fallback.');
    } catch (e) {
      return ToolResult.error('Tavily search failed: $e. The agent can use WebSearch as fallback.');
    }

    // ContentGuard scan
    final guard = _contentGuard;
    if (guard != null) {
      final concatenated = results.map((r) => '${r.title} ${r.snippet}').join('\n');
      final context = GuardContext(
        hookPoint: 'beforeAgentSend',
        messageContent: concatenated,
        timestamp: DateTime.now(),
      );
      final verdict = await guard.evaluate(context);
      if (verdict.isBlock) {
        return ToolResult.error('Search results blocked by content guard: ${verdict.message}');
      }
    }

    return ToolResult.text(
      jsonEncode({
        'results': results.map((r) => r.toJson()).toList(),
        'query': query,
        'provider': 'tavily',
        'count': results.length,
      }),
    );
  }
}
