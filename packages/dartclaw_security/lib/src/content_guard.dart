import 'dart:convert';

import 'package:meta/meta.dart';

import 'content_scan.dart';
import 'guard.dart';
import 'guard_verdict.dart';

/// Guard that scans content at inter-agent boundaries using classification.
///
/// Fires only at `beforeAgentSend` hook points (search → main agent handoff).
/// Classification and its fail policy belong to the injected [ContentScan];
/// this guard adds only the hook-point gate and the [enabled] check.
///
/// At this hook point an over-cap message is prefix-scanned and passed whole:
/// the content is an agent's own output, not raw third-party content.
class ContentGuard extends Guard {
  final ContentScan _scan;

  /// Whether the guard runs at all.
  final bool enabled;

  /// Creates a content guard over an injected [ContentScan].
  new({required ContentScan scan, this.enabled = true}) : _scan = scan;

  /// The injected scan instance.
  @visibleForTesting
  ContentScan get scan => _scan;

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

    final verdict = await _scan.evaluate(content);
    if (!verdict.blocked) return GuardVerdict.pass();
    final classification = verdict.classification;
    return GuardVerdict.block(
      classification != null ? 'Content classified as $classification' : 'Content classification failed (fail-closed)',
    );
  }
}

/// Truncates [text] so its UTF-8 encoding is at most [maxBytes] bytes, never
/// splitting a multi-byte sequence at the boundary.
///
/// Use this when the downstream constraint is byte-length (e.g. a classifier
/// API with a maximum payload size). For char-count truncation, use
/// `truncate` from `package:dartclaw_core`.
String truncateUtf8Bytes(String text, int maxBytes) {
  final encoded = utf8.encode(text);
  if (encoded.length <= maxBytes) return text;
  var end = maxBytes;
  while (end > 0) {
    try {
      return utf8.decode(encoded.sublist(0, end));
    } on FormatException {
      end--;
    }
  }
  return '';
}
