import 'dart:convert';

/// Soft-trims oversized tool results by keeping head + tail with a
/// truncation marker in the middle.
///
/// Applied to tool results before storing in message history to prevent
/// excessive context consumption. The full result remains in the NDJSON
/// transcript.
class ResultTrimmer {
  final int maxBytes;
  static const _headBytes = 2048;
  static const _tailBytes = 2048;

  const ResultTrimmer({this.maxBytes = 50 * 1024});

  /// Returns [result] unchanged if within [maxBytes], otherwise returns
  /// a head+tail summary with truncation marker.
  String trim(String result) {
    final encoded = utf8.encode(result);
    if (encoded.length <= maxBytes) return result;

    final head = _safeUtf8Substring(result, encoded, 0, _headBytes);
    final tail = _safeUtf8Substring(result, encoded, encoded.length - _tailBytes, encoded.length);
    final trimmedBytes = encoded.length - _headBytes - _tailBytes;

    return '$head\n...[trimmed $trimmedBytes bytes]...\n$tail';
  }

  /// Extracts a substring from [text] that corresponds to the byte range
  /// [startByte]..[endByte] in [encoded], respecting UTF-8 character boundaries.
  static String _safeUtf8Substring(String text, List<int> encoded, int startByte, int endByte) {
    // Clamp to valid range
    final start = startByte.clamp(0, encoded.length);
    var end = endByte.clamp(start, encoded.length);

    // Avoid splitting a multi-byte UTF-8 character at the end
    while (end > start && end < encoded.length && (encoded[end] & 0xC0) == 0x80) {
      end--;
    }

    try {
      return utf8.decode(encoded.sublist(start, end));
    } catch (_) {
      // Fallback: use character-based substring
      final chars = text.length;
      if (startByte == 0) {
        final charEnd = (end * chars / encoded.length).floor().clamp(0, chars);
        return text.substring(0, charEnd);
      } else {
        final charStart = (start * chars / encoded.length).ceil().clamp(0, chars);
        return text.substring(charStart);
      }
    }
  }
}
