/// Split text into chunks respecting a max size, using smart break points.
///
/// Break priority: paragraph (`\n\n`) > line (`\n`) > sentence (`. `) > word (` `).
/// Multi-part chunks get `(n/total)` prefix.
///
/// Throws [ArgumentError] when [maxSize] is not positive or cannot fit a
/// multipart label and content.
List<String> chunkText(String text, {int maxSize = 4000}) {
  final slices = chunkTextSlices(text, maxSize: maxSize);
  final chunks = [for (final slice in slices) slice.text];

  if (chunks.length == 1) return chunks;

  final total = chunks.length;
  return [for (var i = 0; i < total; i++) '(${i + 1}/$total) ${chunks[i]}'];
}

/// A text chunk and its half-open range in the source string.
final class TextChunkSlice {
  /// Chunk content after boundary whitespace is trimmed.
  final String text;

  /// Inclusive UTF-16 offset in the source string.
  final int start;

  /// Exclusive UTF-16 offset in the source string.
  final int end;

  /// Creates a source-backed text chunk.
  const new({required this.text, required this.start, required this.end});
}

/// Splits [text] like [chunkText] while preserving source offsets.
///
/// Unlike [chunkText], returned chunks do not include `(n/total)` prefixes.
/// Their content length reserves room for those prefixes when multipart.
/// Offsets use UTF-16 code units, matching Dart string indices.
/// Set [preserveBoundaryWhitespace] when whitespace is content-significant,
/// such as inside code blocks.
///
/// Throws [ArgumentError] when [maxSize] is not positive or cannot fit a
/// multipart label and content.
List<TextChunkSlice> chunkTextSlices(String text, {int maxSize = 4000, bool preserveBoundaryWhitespace = false}) {
  return _chunkTextSlices(text, maxSize: maxSize, preserveBoundaryWhitespace: preserveBoundaryWhitespace);
}

List<TextChunkSlice> _chunkTextSlices(
  String text, {
  required int maxSize,
  bool preserveBoundaryWhitespace = false,
  List<_ProtectedTextRange> protectedRanges = const [],
}) {
  if (maxSize <= 0) {
    throw ArgumentError.value(maxSize, 'maxSize', 'must be positive');
  }
  if (text.length <= maxSize) {
    return [TextChunkSlice(text: text, start: 0, end: text.length)];
  }

  var contentSize = maxSize;
  while (true) {
    final chunks = _splitText(
      text,
      maxSize: contentSize,
      preserveBoundaryWhitespace: preserveBoundaryWhitespace,
      protectedRanges: protectedRanges,
    );
    final prefixSize = '(${chunks.length}/${chunks.length}) '.length;
    final nextContentSize = maxSize - prefixSize;
    if (nextContentSize <= 0) {
      throw ArgumentError.value(maxSize, 'maxSize', 'is too small for multipart prefixes');
    }
    if (nextContentSize == contentSize) return chunks;
    contentSize = nextContentSize;
  }
}

List<TextChunkSlice> _splitText(
  String text, {
  required int maxSize,
  required bool preserveBoundaryWhitespace,
  required List<_ProtectedTextRange> protectedRanges,
}) {
  final chunks = <TextChunkSlice>[];
  var remainingStart = 0;

  while (remainingStart < text.length) {
    final remaining = text.substring(remainingStart);
    if (remaining.length <= maxSize) {
      chunks.add(TextChunkSlice(text: remaining, start: remainingStart, end: text.length));
      break;
    }

    var breakIndex = _safeUtf16BreakPoint(remaining, _findBreakPoint(remaining, maxSize));
    breakIndex = _moveBreakOutsideProtectedRange(
      remainingStart: remainingStart,
      breakIndex: breakIndex,
      maxSize: maxSize,
      protectedRanges: protectedRanges,
    );
    final rawEnd = remainingStart + breakIndex;
    final rawChunk = text.substring(remainingStart, rawEnd);
    final chunkText = preserveBoundaryWhitespace ? rawChunk : rawChunk.trimRight();
    final chunkEnd = preserveBoundaryWhitespace ? rawEnd : remainingStart + chunkText.length;
    chunks.add(TextChunkSlice(text: chunkText, start: remainingStart, end: chunkEnd));

    if (preserveBoundaryWhitespace) {
      remainingStart = rawEnd;
    } else {
      final trimmedRemaining = text.substring(rawEnd).trimLeft();
      remainingStart = text.length - trimmedRemaining.length;
    }
  }

  return chunks;
}

int _moveBreakOutsideProtectedRange({
  required int remainingStart,
  required int breakIndex,
  required int maxSize,
  required List<_ProtectedTextRange> protectedRanges,
}) {
  final absoluteBreak = remainingStart + breakIndex;
  for (final range in protectedRanges) {
    if (range.start >= absoluteBreak || range.end <= absoluteBreak || range.length > maxSize) continue;
    return range.start > remainingStart ? range.start - remainingStart : range.end - remainingStart;
  }
  return breakIndex;
}

int _safeUtf16BreakPoint(String text, int breakIndex) {
  if (breakIndex <= 0 || breakIndex >= text.length) return breakIndex;
  final before = text.codeUnitAt(breakIndex - 1);
  final after = text.codeUnitAt(breakIndex);
  final splitsSurrogatePair = before >= 0xD800 && before <= 0xDBFF && after >= 0xDC00 && after <= 0xDFFF;
  if (!splitsSurrogatePair) return breakIndex;
  return breakIndex == 1 ? breakIndex + 1 : breakIndex - 1;
}

/// Find the best break point within maxSize characters.
int _findBreakPoint(String text, int maxSize) {
  final searchRange = text.substring(0, maxSize);

  final para = searchRange.lastIndexOf('\n\n');
  if (para > maxSize ~/ 4) return para + 2;

  final line = searchRange.lastIndexOf('\n');
  if (line > maxSize ~/ 4) return line + 1;

  final sentence = searchRange.lastIndexOf('. ');
  if (sentence > maxSize ~/ 4) return sentence + 2;

  final word = searchRange.lastIndexOf(' ');
  if (word > maxSize ~/ 4) return word + 1;

  return maxSize;
}

const _multipartMarkupReserve = 10;
final _nativeLinkPattern = RegExp(r'<[^<>\n|]+\|[^<>\n]+>');

final class _ProtectedTextRange {
  const new(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;
}

/// Chunks `*`, `_`, `~`, and backtick-based chat markup into valid parts.
///
/// Formatting that crosses a boundary is closed at the end of one part and
/// reopened in the next. Final chunks include `(n/total)` prefixes and do not
/// exceed [maxSize].
///
/// Throws [ArgumentError] when [maxSize] is not positive or cannot fit
/// multipart labels, balanced markup, and content.
List<String> chunkNativeChatMarkup(String text, {int maxSize = 4000}) {
  if (maxSize <= 0) {
    throw ArgumentError.value(maxSize, 'maxSize', 'must be positive');
  }
  if (text.length <= maxSize) return [text];

  final contentSize = maxSize - _multipartMarkupReserve;
  if (contentSize <= 0) {
    throw ArgumentError.value(maxSize, 'maxSize', 'is too small for multipart markup');
  }

  final protectedRanges = [
    for (final match in _nativeLinkPattern.allMatches(text)) _ProtectedTextRange(match.start, match.end),
  ];
  final slices = _chunkTextSlices(
    text,
    maxSize: contentSize,
    preserveBoundaryWhitespace: true,
    protectedRanges: protectedRanges,
  );
  final active = <String>[];
  final chunks = <String>[];
  var cursor = 0;

  for (var i = 0; i < slices.length; i++) {
    final slice = slices[i];
    _scanMarkup(text, cursor, slice.start, active);
    final startsInsideCode = _hasActiveCode(active);
    final opening = _openingMarkup(active);
    _scanMarkup(text, slice.start, slice.end, active);
    final body = _wrapChunkContent(
      slice.text,
      opening: opening,
      closing: _closingMarkup(active),
      startsInsideCode: startsInsideCode,
      endsInsideCode: _hasActiveCode(active),
    );
    final prefix = '(${i + 1}/${slices.length}) ';
    chunks.add(body.startsWith('```') ? '${prefix.trimRight()}\n$body' : '$prefix$body');
    cursor = slice.end;
  }

  return chunks;
}

bool _hasActiveCode(List<String> active) => active.any((marker) => marker == '`' || marker == '```');

String _wrapChunkContent(
  String content, {
  required String opening,
  required String closing,
  required bool startsInsideCode,
  required bool endsInsideCode,
}) {
  if (content.trim().isEmpty) return content;

  var core = content;
  var leading = '';
  var trailing = '';
  if (!startsInsideCode) {
    final match = RegExp(r'^\s+').firstMatch(core);
    if (match != null) {
      leading = match.group(0)!;
      core = core.substring(match.end);
    }
  }
  if (!endsInsideCode) {
    final match = RegExp(r'\s+$').firstMatch(core);
    if (match != null) {
      trailing = match.group(0)!;
      core = core.substring(0, match.start);
    }
  }
  return '$leading$opening$core$closing$trailing';
}

void _scanMarkup(String source, int start, int end, List<String> active) {
  var index = start;
  while (index < end) {
    final current = source.codeUnitAt(index);
    if (_isEscaped(source, index)) {
      index += 1;
      continue;
    }

    final activeCode = active.isEmpty ? null : active.last;
    if (activeCode == '```') {
      if (_startsWith(source, index, '```', end)) {
        active.removeLast();
        index += 3;
      } else {
        index += 1;
      }
      continue;
    }
    if (activeCode == '`') {
      if (current == 0x60) active.removeLast();
      index += 1;
      continue;
    }

    if (_startsWith(source, index, '```', end)) {
      if (_hasClosingMarker(source, index + 3, '```')) active.add('```');
      index += 3;
      continue;
    }
    if (current == 0x60) {
      if (_hasClosingMarker(source, index + 1, '`')) active.add('`');
      index += 1;
      continue;
    }

    final marker = switch (current) {
      0x2A => '*',
      0x5F => '_',
      0x7E => '~',
      _ => null,
    };
    if (marker == null || _isInsideWord(source, index)) {
      index += 1;
      continue;
    }
    if (active.isNotEmpty && active.last == marker) {
      active.removeLast();
    } else if (_hasClosingMarker(source, index + 1, marker)) {
      active.add(marker);
    }
    index += 1;
  }
}

bool _hasClosingMarker(String source, int start, String marker) {
  for (var index = start; index <= source.length - marker.length; index++) {
    if (_isEscaped(source, index) || !_startsWith(source, index, marker, source.length)) continue;
    if (marker.length == 1 && marker != '`' && _isInsideWord(source, index)) continue;
    return true;
  }
  return false;
}

bool _startsWith(String source, int index, String marker, int end) {
  return index + marker.length <= end && source.startsWith(marker, index);
}

bool _isEscaped(String source, int index) {
  var slashes = 0;
  for (var i = index - 1; i >= 0 && source.codeUnitAt(i) == 0x5C; i--) {
    slashes += 1;
  }
  return slashes.isOdd;
}

bool _isInsideWord(String source, int index) {
  if (index == 0 || index + 1 >= source.length) return false;
  return _isWordCodeUnit(source.codeUnitAt(index - 1)) && _isWordCodeUnit(source.codeUnitAt(index + 1));
}

bool _isWordCodeUnit(int codeUnit) {
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7A);
}

String _openingMarkup(List<String> active) {
  return active.map((marker) => marker == '```' ? '```\n' : marker).join();
}

String _closingMarkup(List<String> active) {
  return active.reversed.map((marker) => marker == '```' ? '\n```' : marker).join();
}
