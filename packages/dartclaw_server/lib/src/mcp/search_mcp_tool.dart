import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';

import 'search_provider.dart';

/// Shared `McpTool` implementation for web-search providers.
///
/// Owns the provider-agnostic surface: input JSON schema, query validation,
/// count clamping, [ContentGuard] scan, and result formatting. Subclasses
/// supply only the provider-specific seams via [name], [providerId],
/// [providerLabel], and [maxCount]; the HTTP call itself is abstracted behind
/// the injected [SearchProvider].
abstract class SearchMcpTool implements McpTool {
  final SearchProvider provider;
  final ContentGuard? contentGuard;

  SearchMcpTool({required this.provider, this.contentGuard});

  /// Lowercase provider id emitted in the result payload (e.g. `brave`).
  String get providerId;

  /// Human-facing provider label used in error messages (e.g. `Brave`).
  String get providerLabel;

  /// Upper bound for the `count` parameter (clamp ceiling + schema maximum).
  int get maxCount;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'Search query'},
      'count': {
        'type': 'integer',
        'description': 'Number of results (1-$maxCount, default 5)',
        'default': 5,
        'minimum': 1,
        'maximum': maxCount,
      },
    },
    'required': ['query'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final query = args['query'] as String?;
    if (query == null || query.isEmpty) {
      return ToolResult.error('Error: missing required parameter "query"');
    }

    final rawCount = args['count'] as int? ?? 5;
    final count = rawCount.clamp(1, maxCount);

    List<SearchResult> results;
    try {
      results = await provider.search(query, count: count);
    } on TimeoutException {
      return ToolResult.error('$providerLabel search timed out. The agent can use WebSearch as fallback.');
    } catch (e) {
      return ToolResult.error('$providerLabel search failed: $e. The agent can use WebSearch as fallback.');
    }

    // ContentGuard scan
    final guard = contentGuard;
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
        'provider': providerId,
        'count': results.length,
      }),
    );
  }
}
