import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';

typedef SessionUsageRecord = ({
  int? inputTokens,
  int? outputTokens,
  int? cachedInputTokens,
  int? effectiveTokens,
  double? estimatedCostUsd,
  String provider,
});

SessionUsageRecord emptyUsage(String provider) => (
  inputTokens: null,
  outputTokens: null,
  cachedInputTokens: null,
  effectiveTokens: null,
  estimatedCostUsd: null,
  provider: provider,
);

Future<SessionUsageRecord> readSessionUsage(
  KvService? kvService,
  String sessionId, {
  String defaultProvider = 'claude',
}) async {
  if (kvService == null) return emptyUsage(defaultProvider);

  final raw = await kvService.get('session_cost:$sessionId');
  if (raw == null) return emptyUsage(defaultProvider);

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return emptyUsage(defaultProvider);

    // Prefer canonical field names (written by TurnRunner post-S06);
    // fall back to legacy 'cached_input_tokens' for KV entries written
    // by older versions.
    final cacheReadTokens =
        (decoded['cache_read_tokens'] as num?)?.toInt() ?? (decoded['cached_input_tokens'] as num?)?.toInt();
    return (
      inputTokens: (decoded['input_tokens'] as num?)?.toInt(),
      outputTokens: (decoded['output_tokens'] as num?)?.toInt(),
      cachedInputTokens: cacheReadTokens,
      effectiveTokens: (decoded['effective_tokens'] as num?)?.toInt(),
      estimatedCostUsd: (decoded['estimated_cost_usd'] as num?)?.toDouble(),
      provider: switch (decoded['provider']) {
        final String value when value.trim().isNotEmpty => value,
        _ => defaultProvider,
      },
    );
  } catch (e) {
    return emptyUsage(defaultProvider);
  }
}
