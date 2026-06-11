import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'search_mcp_tool.dart';
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

    try {
      final response = await httpRequest(
        uri,
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'api_key': _apiKey, 'query': query, 'max_results': count, 'include_raw_content': false}),
        connectionTimeout: _timeout,
        timeout: _timeout,
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
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
    }
  }
}

/// MCP tool that searches via Tavily Search API.
class TavilySearchTool extends SearchMcpTool {
  TavilySearchTool({required super.provider, super.contentGuard});

  @override
  String get name => 'tavily_search';

  @override
  String get description => 'Search the web using Tavily Search API. Returns titles, URLs, and snippets.';

  @override
  String get providerId => 'tavily';

  @override
  String get providerLabel => 'Tavily';

  @override
  int get maxCount => 10;
}
