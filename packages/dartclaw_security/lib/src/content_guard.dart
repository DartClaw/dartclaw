import 'dart:convert';

import 'package:logging/logging.dart';

import 'cloudflare_detector.dart';
import 'content_classifier.dart';
import 'guard.dart';
import 'guard_verdict.dart';

/// Guard that scans content at inter-agent boundaries using classification.
///
/// Fires only at `beforeAgentSend` hook points (search → main agent handoff).
/// Fail behavior is configurable: [failOpen] controls whether classification
/// errors result in pass (true) or block (false, default).
class ContentGuard extends Guard {
  static final _log = Logger('ContentGuard');

  /// Classifier used to score outbound agent content.
  final ContentClassifier _classifier;

  /// Maximum UTF-8 payload size sent to the classifier.
  final int maxContentBytes;

  /// Timeout for the classifier call.
  final Duration timeout;

  /// Whether the guard runs at all.
  final bool enabled;

  /// Whether classifier failures should pass instead of block.
  final bool failOpen;

  /// Creates a content guard around a concrete [ContentClassifier].
  ContentGuard({
    required ContentClassifier classifier,
    this.maxContentBytes = 50 * 1024,
    this.timeout = const Duration(seconds: 15),
    this.enabled = true,
    this.failOpen = false,
  }) : _classifier = classifier;

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

    // Classify content
    try {
      final classification = await _classifier.classify(truncated, timeout: timeout);

      if (classification == 'safe') {
        return GuardVerdict.pass();
      }

      _log.warning('Content blocked: classification=$classification');
      return GuardVerdict.block('Content classified as $classification');
    } catch (e) {
      if (failOpen) {
        _log.warning('Content classification failed (fail-open): $e');
        return GuardVerdict.pass();
      }
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
