/// Split text into chunks respecting a max size, using smart break points.
///
/// Break priority: paragraph (`\n\n`) > line (`\n`) > sentence (`. `) > word (` `).
/// Multi-part chunks get `(n/total)` prefix.
List<String> chunkText(String text, {int maxSize = 4000}) {
  if (text.length <= maxSize) return [text];

  final chunks = <String>[];
  var remaining = text;

  while (remaining.isNotEmpty) {
    if (remaining.length <= maxSize) {
      chunks.add(remaining);
      break;
    }

    final breakIndex = _findBreakPoint(remaining, maxSize);
    chunks.add(remaining.substring(0, breakIndex).trimRight());
    remaining = remaining.substring(breakIndex).trimLeft();
  }

  if (chunks.length == 1) return chunks;

  final total = chunks.length;
  return [for (var i = 0; i < total; i++) '(${i + 1}/$total) ${chunks[i]}'];
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
