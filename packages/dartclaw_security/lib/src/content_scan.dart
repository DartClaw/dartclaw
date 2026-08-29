import 'dart:convert';

import 'package:logging/logging.dart';

import 'content_classifier.dart';
import 'content_guard.dart' show truncateUtf8Bytes;

/// Outcome of a [ContentScan.evaluate] call.
///
/// The verdict is data, not a message: each call site formats its own user-facing
/// wording from [classification] or [failureReason], so the scan stays the single
/// place the fail policy is decided without owning three message contracts.
final class ContentScanVerdict {
  /// Whether the content must not reach the agent.
  final bool blocked;

  /// Classifier label when the content was scored unsafe, else null.
  final String? classification;

  /// Classifier failure description when the classifier threw, else null.
  ///
  /// Set on both the fail-closed block and the fail-open pass.
  final String? failureReason;

  /// The span the classifier saw — the input truncated to the byte cap.
  ///
  /// Call sites that return content to an agent return exactly this, so no
  /// unscanned byte is forwarded.
  final String scannedText;

  /// Creates a verdict.
  const new({required this.blocked, required this.scannedText, this.classification, this.failureReason});
}

/// The one place a content classification and its fail policy are decided.
///
/// Owns the truncate → classify → fail-policy sequence for every scanning call
/// site (`ContentGuard`, `web_fetch`, and outbound MCP results from `public`
/// servers). [failOpen] is the only input deciding whether a classifier failure
/// passes or blocks; it defaults to `false`, so a construction that bypasses
/// wiring fails closed.
final class ContentScan {
  static final _log = Logger('ContentScan');

  final ContentClassifier _classifier;

  /// Maximum UTF-8 payload size sent to the classifier.
  final int maxContentBytes;

  /// Timeout for the classifier call.
  final Duration timeout;

  /// Whether classifier failures pass instead of block.
  final bool failOpen;

  /// Creates a scan over a concrete [ContentClassifier].
  new({
    required ContentClassifier classifier,
    this.maxContentBytes = 50 * 1024,
    this.timeout = const Duration(seconds: 15),
    this.failOpen = false,
  }) : _classifier = classifier;

  /// Whether [text] is longer than [maxContentBytes] in UTF-8 bytes.
  ///
  /// Invokes no classifier. Call sites that deny rather than prefix-scan
  /// oversize content query this before [evaluate].
  bool exceedsCap(String text) => utf8.encode(text).length > maxContentBytes;

  /// Classifies at most [maxContentBytes] of [content] and applies the fail policy.
  ///
  /// Empty content passes without reaching the classifier.
  Future<ContentScanVerdict> evaluate(String content) async {
    if (content.isEmpty) return const ContentScanVerdict(blocked: false, scannedText: '');

    final scanned = truncateUtf8Bytes(content, maxContentBytes);
    try {
      final classification = await _classifier.classify(scanned, timeout: timeout);
      if (classification == 'safe') {
        return ContentScanVerdict(blocked: false, scannedText: scanned);
      }
      _log.warning('Content blocked: classification=$classification');
      return ContentScanVerdict(blocked: true, scannedText: scanned, classification: classification);
    } catch (e) {
      if (failOpen) {
        _log.warning('Content classification failed (fail-open): $e');
        return ContentScanVerdict(blocked: false, scannedText: scanned, failureReason: '$e');
      }
      _log.warning('Content classification failed (fail-closed): $e');
      return ContentScanVerdict(blocked: true, scannedText: scanned, failureReason: '$e');
    }
  }
}
