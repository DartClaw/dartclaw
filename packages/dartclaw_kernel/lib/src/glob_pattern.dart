/// Compiles a POSIX-shaped glob [pattern] to an anchored regular expression.
///
/// The one glob dialect in the workspace. Two consumers depend on it — the file
/// guard's rule patterns and the workflow output resolver's declared artifact
/// patterns — and a second compiler is how they drift: a pattern an operator
/// verifies against one surface has to behave the same on the other.
///
/// The dialect:
///
/// - `*` matches any run of characters within one path segment.
/// - `**` matches any run of characters, segment separators included.
/// - `**/` matches zero or more whole leading segments, so it is anchored to a
///   segment boundary: `**/.ssh/*` matches `a/.ssh/k` but not `a/my.ssh/k`.
/// - `?` matches one character within a segment.
/// - `{a,b}` matches either alternative, with each alternative taken literally.
/// - Everything else is literal.
///
/// The result is anchored at both ends; a caller wanting a suffix or basename
/// match applies the result to those strings itself.
String globToRegex(String pattern) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final char = pattern[i];
    if (char == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        if (i + 2 < pattern.length && pattern[i + 2] == '/') {
          buffer.write('(?:.*/)?');
          i += 2;
        } else {
          buffer.write('.*');
          i++;
        }
      } else {
        buffer.write('[^/]*');
      }
      continue;
    }
    if (char == '?') {
      buffer.write('[^/]');
      continue;
    }
    if (char == '{') {
      final closeIndex = pattern.indexOf('}', i + 1);
      if (closeIndex != -1) {
        final body = pattern.substring(i + 1, closeIndex);
        if (body.contains(',')) {
          buffer.write('(?:${body.split(',').map(RegExp.escape).join('|')})');
          i = closeIndex;
          continue;
        }
      }
    }
    if (r'.+^$(){}|[]\'.contains(char)) buffer.write(r'\');
    buffer.write(char);
  }
  buffer.write(r'$');
  return buffer.toString();
}
