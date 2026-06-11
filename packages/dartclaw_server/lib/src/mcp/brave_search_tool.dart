import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'search_mcp_tool.dart';
import 'search_provider.dart';

/// Brave Search API provider.
class BraveSearchProvider implements SearchProvider {
  static final _log = Logger('BraveSearchProvider');

  final String _apiKey;
  final Duration _timeout;

  BraveSearchProvider({required String apiKey, Duration timeout = const Duration(seconds: 15)})
    : _apiKey = apiKey,
      _timeout = timeout;

  @override
  Future<List<SearchResult>> search(String query, {int count = 5}) async {
    final uri = Uri.https('api.search.brave.com', '/res/v1/web/search', {'q': query, 'count': count.toString()});

    try {
      final response = await httpRequest(
        uri,
        headers: {'X-Subscription-Token': _apiKey, 'Accept': 'application/json'},
        connectionTimeout: _timeout,
        timeout: _timeout,
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final web = json['web'] as Map<String, dynamic>?;
      final results = web?['results'] as List<dynamic>? ?? [];

      return results.map((r) {
        final item = r as Map<String, dynamic>;
        return SearchResult(
          title: item['title'] as String? ?? '',
          url: item['url'] as String? ?? '',
          snippet: item['description'] as String? ?? '',
        );
      }).toList();
    } on TimeoutException {
      _log.warning('Brave search timed out after ${_timeout.inSeconds}s');
      rethrow;
    } on SocketException catch (e) {
      _log.warning('Brave search connection failed: ${e.message}');
      rethrow;
    }
  }
}

/// MCP tool that searches via Brave Search API.
class BraveSearchTool extends SearchMcpTool {
  BraveSearchTool({required super.provider, super.contentGuard});

  @override
  String get name => 'brave_search';

  @override
  String get description => 'Search the web using Brave Search API. Returns titles, URLs, and snippets.';

  @override
  String get providerId => 'brave';

  @override
  String get providerLabel => 'Brave';

  @override
  int get maxCount => 20;
}
