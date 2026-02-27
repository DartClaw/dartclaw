import 'dart:convert';

import 'package:logging/logging.dart';

import 'anthropic_client.dart';
import 'cloudflare_detector.dart';
import 'guard.dart';
import 'guard_verdict.dart';

/// Guard that scans content at inter-agent boundaries using Haiku classification.
///
/// Fires only at `beforeAgentSend` hook points (search → main agent handoff).
/// Fail-closed: any error, timeout, or ambiguous classification → block.
class ContentGuard extends Guard {
  static final _log = Logger('ContentGuard');

  final AnthropicClient _client;
  final int maxContentBytes;
  final Duration timeout;
  final bool enabled;

  ContentGuard({
    required AnthropicClient client,
    this.maxContentBytes = 50 * 1024,
    this.timeout = const Duration(seconds: 15),
    this.enabled = true,
  }) : _client = client;

  @override
  String get name => 'content-guard';

  @override
  String get category => 'content';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (!enabled) return GuardVerdict.pass();

    // Only evaluate at agent boundary (beforeAgentSend)
    if (context.hookPoint != 'beforeAgentSend') return GuardVerdict.pass();

    final content = context.messageContent;
    if (content == null || content.isEmpty) return GuardVerdict.pass();

    // Truncate to max bytes (UTF-8 safe)
    final truncated = _truncateUtf8(content, maxContentBytes);

    // Skip Cloudflare challenge pages
    if (CloudflareDetector.isCloudflareChallenge(truncated)) {
      _log.fine('Cloudflare challenge detected — skipping classification');
      return GuardVerdict.pass();
    }

    // Classify via Haiku
    try {
      final classification = await _client.classify(truncated, timeout: timeout);

      if (classification == 'safe') {
        return GuardVerdict.pass();
      }

      _log.warning('Content blocked: classification=$classification');
      return GuardVerdict.block('Content classified as $classification');
    } catch (e) {
      _log.warning('Content classification failed (fail-closed): $e');
      return GuardVerdict.block('Content classification failed (fail-closed)');
    }
  }

  /// Truncate string to [maxBytes] of UTF-8 without splitting multi-byte chars.
  static String _truncateUtf8(String text, int maxBytes) {
    final encoded = utf8.encode(text);
    if (encoded.length <= maxBytes) return text;
    // Decode back, allowing malformed to handle partial multi-byte at boundary
    return utf8.decode(encoded.sublist(0, maxBytes), allowMalformed: true);
  }
}
