import 'dart:convert';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

/// Soft-trims oversized tool results by keeping head + tail with a
/// truncation marker in the middle.
///
/// Applied by `McpProtocolHandler` to the successful text result of every
/// `tools/call` it dispatches, relays of a configured MCP server included --
/// not to a tool's error result, which is delivered as produced. The marker is
/// the signal: bytes are never dropped silently, and an oversized JSON result
/// becomes text the model must read as truncated rather than parse.
class ResultTrimmer implements Reconfigurable {
  static final _log = Logger('ResultTrimmer');

  int _maxBytes;

  /// Ceiling on either surviving slice: raising [maxBytes] raises the size a
  /// result may reach untouched, never how much of an oversized one survives.
  static const _maxSliceBytes = 2048;

  new({int maxBytes = 50 * 1024}) : _maxBytes = maxBytes;

  int get maxBytes => _maxBytes;

  @override
  Set<String> get watchKeys => const {'context.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    final newMax = delta.current.context.maxResultBytes;
    if (newMax == _maxBytes) return;
    _maxBytes = newMax;
    _log.info('ResultTrimmer maxBytes updated to $_maxBytes');
  }

  /// Returns [result] unchanged if within [maxBytes], otherwise a head+tail
  /// excerpt separated by the truncation marker.
  ///
  /// The excerpt is sized from [maxBytes] so the returned text fits the cap;
  /// only a cap too small to hold the marker itself yields more than it allows,
  /// because the marker is never dropped.
  String trim(String result) {
    final encoded = utf8.encode(result);
    if (encoded.length <= _maxBytes) return result;

    // The marker's own bytes come out of the budget, sized against the largest
    // count it can report so the total never exceeds the cap.
    final sliceBytes = ((_maxBytes - _marker(encoded.length).length) ~/ 2).clamp(0, _maxSliceBytes);
    final head = _decodeSlice(encoded, 0, sliceBytes);
    final tail = _decodeSlice(encoded, encoded.length - sliceBytes, encoded.length);
    final trimmedBytes = encoded.length - utf8.encode(head).length - utf8.encode(tail).length;

    return '$head${_marker(trimmedBytes)}$tail';
  }

  static String _marker(int trimmedBytes) => '\n...[trimmed $trimmedBytes bytes]...\n';

  /// Decodes the byte range [startByte]..[endByte] of [encoded], moving both
  /// ends off any UTF-8 continuation byte so the slice never splits a character.
  static String _decodeSlice(List<int> encoded, int startByte, int endByte) {
    var start = startByte.clamp(0, encoded.length);
    var end = endByte.clamp(start, encoded.length);
    while (start < end && (encoded[start] & 0xC0) == 0x80) {
      start++;
    }
    while (end > start && end < encoded.length && (encoded[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(encoded.sublist(start, end));
  }
}
