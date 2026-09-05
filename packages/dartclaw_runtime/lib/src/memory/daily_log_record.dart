import 'dart:convert';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Maximum UTF-8 size of one daily-log record's serialized tool summaries.
const dailyLogMaxSerializedToolBytes = 64 * 1024;

// Raw text caps reserve worst-case JSON-escaping headroom within the sink's record ceiling.
const dailyLogMaxRawTitleBytes = 1024;
const dailyLogMaxRawUserBytes = 48 * 1024;
const dailyLogMaxRawResultBytes = 16 * 1024;
const dailyLogBytesTruncated = '[truncated: serialized bytes]';

/// The one daily-log record shape, shared by human-facing turn capture and
/// announce delivery.
///
/// [title], [userMessage] and [result] are redacted and capped here;
/// [toolSummaries] arrive already serialized under
/// [dailyLogMaxSerializedToolBytes] and are written as given.
String buildDailyLogRecord({
  required DateTime at,
  required MessageRedactor redactor,
  required String title,
  required String userMessage,
  required List<String> toolSummaries,
  required String result,
}) {
  final time = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  final titleSummary = dailyLogText(redactor, title, dailyLogMaxRawTitleBytes);
  final userSummary = dailyLogText(redactor, userMessage, dailyLogMaxRawUserBytes);
  final resultSummary = dailyLogText(
    redactor,
    result,
    dailyLogMaxRawResultBytes,
  ).trim().replaceAll(RegExp(r'\s+'), ' ');
  return '## $time — ${jsonEncode(titleSummary)}\n'
      '**User**: ${jsonEncode(userSummary)}\n'
      '**Tools**: ${jsonEncode(toolSummaries)}\n'
      '**Result**: ${jsonEncode(resultSummary)}';
}

/// [value] redacted and bounded to [maxBytes].
///
/// The cut runs before redaction to bound the regex work on an unbounded value,
/// and again after because redaction can lengthen text (`[REDACTED]` is longer
/// than a short match) and because only the second pass carries the truncation
/// marker. Cutting first is not what keeps an over-cap secret safe — a PEM block
/// survives it only because the redactor carries an unterminated-block pattern,
/// and a pattern needing a complete shape can still leave a partial match.
String dailyLogText(MessageRedactor redactor, String value, int maxBytes) {
  final bounded = dailyLogUtf8Prefix(value, maxBytes);
  return dailyLogBounded(redactor.redact(bounded.text), maxBytes, truncated: !bounded.complete);
}

/// [value] cut to [maxBytes], carrying the truncation marker when anything was
/// dropped here or by [truncated] upstream.
String dailyLogBounded(String value, int maxBytes, {bool truncated = false}) {
  final fitted = dailyLogUtf8Prefix(value, maxBytes);
  if (fitted.complete && !truncated) return fitted.text;
  final markerBytes = dailyLogUtf8Prefix(dailyLogBytesTruncated, maxBytes).bytes;
  return '${dailyLogUtf8Prefix(value, maxBytes - markerBytes).text}$dailyLogBytesTruncated';
}

/// The kernel's byte-boundary truncation plus the byte count and completeness
/// the daily-log budget needs. The cut itself is not re-derived here.
({String text, int bytes, bool complete}) dailyLogUtf8Prefix(String value, int maxBytes) {
  if (maxBytes <= 0) return (text: '', bytes: 0, complete: value.isEmpty);
  final text = truncateUtf8Bytes(value, maxBytes);
  return (text: text, bytes: utf8.encode(text).length, complete: text.length == value.length);
}
