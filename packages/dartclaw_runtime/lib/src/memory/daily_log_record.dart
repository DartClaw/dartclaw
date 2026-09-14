import 'dart:convert';

import 'package:crypto/crypto.dart';
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

const _dailyLogMaxDepth = 16;
const _dailyLogMaxCollectionItems = 512;
const _dailyLogDepthTruncated = '[truncated: recursion depth]';
const _dailyLogItemsTruncated = '[truncated: collection items]';

/// The summary is written through a running byte budget rather than encoded
/// whole and then cut back, so peak memory stays at
/// [dailyLogMaxSerializedToolBytes] however wide the input is.
///
/// Identity is fed the raw value stream ahead of that budget and of redaction:
/// two calls sharing a large leading value summarise identically, and deriving
/// identity from the summary would silently drop the second from the log. Depth,
/// breadth and secret redaction do reach identity — past those the two calls
/// have nothing left to tell apart.
final class DailyLogToolSerializer {
  final MessageRedactor _redactor;
  final _identity = _DailyLogIdentity();
  final _summary = StringBuffer();
  var _items = 0;
  var _usedBytes = 0;
  var _exhausted = false;
  var _truncated = false;

  new(this._redactor);

  ({String summary, String identity, bool truncated}) serializeInput(Map<String, dynamic> input) {
    _writeValue(input, depth: 0);
    return (
      summary: dailyLogBounded(_summary.toString(), dailyLogMaxSerializedToolBytes, truncated: _truncated),
      identity: _identity.finish(),
      truncated: _truncated,
    );
  }

  void _writeValue(Object? value, {required int depth, Object? key}) {
    if (key != null && MessageRedactor.isSecretKey(key)) {
      _identity.tag('*');
      _write('"***"');
      return;
    }
    if (value is List) {
      if (depth >= _dailyLogMaxDepth) return _writeMarker(_dailyLogDepthTruncated);
      _identity.tag('[');
      _write('[');
      var wrote = false;
      for (final item in value) {
        if (!_consumeItem()) {
          if (wrote) _write(',');
          _writeMarker(_dailyLogItemsTruncated);
          break;
        }
        if (wrote) _write(',');
        _writeValue(item, depth: depth + 1);
        wrote = true;
      }
      _identity.tag(']');
      _write(']');
      return;
    }
    if (value is Map) {
      if (depth >= _dailyLogMaxDepth) return _writeMarker(_dailyLogDepthTruncated);
      _identity.tag('{');
      _write('{');
      var wrote = false;
      for (final entry in value.entries) {
        if (!_consumeItem()) {
          if (wrote) _write(',');
          _writeMarker(_dailyLogItemsTruncated);
          _write(':null');
          break;
        }
        if (wrote) _write(',');
        _writeString('${entry.key}');
        _write(':');
        _writeValue(entry.value, depth: depth + 1, key: entry.key);
        wrote = true;
      }
      _identity.tag('}');
      _write('}');
      return;
    }
    if (value is String) return _writeString(value);
    // jsonEncode throws on a non-finite double, and the caller swallows that, so
    // one such value would cost the whole entry.
    if (value is num && value.isFinite) {
      _identity.tag('n$value;');
      _write('$value');
      return;
    }
    if (value is bool || value == null) {
      _identity.tag(value == null ? 'z;' : 'b$value;');
      _write('$value');
      return;
    }
    _writeString(value.toString());
  }

  void _writeString(String value) {
    _identity.string(value);
    if (_exhausted) return;
    final bounded = dailyLogUtf8Prefix(value, dailyLogMaxSerializedToolBytes - _usedBytes);
    // Redaction always sees the value's own cap, never the smaller budget
    // remainder: that remainder lands wherever the entries before it ended, and
    // a secret split by it stops matching its pattern. Only what fits the
    // remainder is written, so the extra text redacted here never reaches the
    // entry.
    final redacted = _redactor.redact(
      bounded.complete ? bounded.text : dailyLogUtf8Prefix(value, dailyLogMaxSerializedToolBytes).text,
    );
    _write(jsonEncode(redacted));
    // The cut must outlive the value that took it: redaction can shrink an
    // over-cap string back under the budget, and the summary would then read as
    // complete and lose its truncation marker.
    if (!bounded.complete) _truncated = true;
  }

  void _writeMarker(String marker) {
    _identity.tag('!');
    _identity.string(marker);
    _write(jsonEncode(marker));
    _truncated = true;
  }

  /// The budget counts what is written, not what is read, so a value redaction
  /// shrinks cannot starve the entries after it. Exhausting it stops the summary
  /// but not the walk, which keeps feeding identity.
  void _write(String value) {
    if (_exhausted) return;
    final bounded = dailyLogUtf8Prefix(value, dailyLogMaxSerializedToolBytes - _usedBytes);
    _summary.write(bounded.text);
    _usedBytes += bounded.bytes;
    if (!bounded.complete) {
      _exhausted = true;
      _truncated = true;
    }
  }

  bool _consumeItem() {
    if (_items >= _dailyLogMaxCollectionItems) return false;
    _items++;
    return true;
  }
}

/// Values are type-tagged and strings length-prefixed — labels are ASCII, since
/// [tag] feeds code units as bytes — so no two distinct inputs feed the same
/// bytes. Strings go in raw: unredacted, uncut, and chunked so no encoded copy
/// of the input is ever held, because what the summary can afford to show must
/// not decide what the dedup key can tell apart.
final class _DailyLogIdentity {
  static const _chunkCodeUnits = 4096;

  late final Digest _result;
  late final ByteConversionSink _sink = sha256.startChunkedConversion(
    ChunkedConversionSink<Digest>.withCallback((digests) => _result = digests.single),
  );

  void tag(String label) => _sink.add(label.codeUnits);

  void string(String value) {
    tag('s${value.length}:');
    for (var start = 0; start < value.length; start += _chunkCodeUnits) {
      final end = start + _chunkCodeUnits < value.length ? start + _chunkCodeUnits : value.length;
      final bytes = List<int>.filled((end - start) * 2, 0);
      for (var i = start; i < end; i++) {
        final unit = value.codeUnitAt(i);
        bytes[(i - start) * 2] = unit >> 8;
        bytes[(i - start) * 2 + 1] = unit & 0xff;
      }
      _sink.add(bytes);
    }
  }

  /// Closes the stream: no value may be fed after this.
  String finish() {
    _sink.close();
    return '$_result';
  }
}
