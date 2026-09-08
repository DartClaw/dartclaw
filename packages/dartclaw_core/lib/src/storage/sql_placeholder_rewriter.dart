/// Rewrites positional `?` placeholders while preserving SQL literals,
/// identifiers, and comments.
String rewriteSqlPlaceholders(String sql, String Function(int ordinal) formatPlaceholder) {
  final output = StringBuffer();
  var ordinal = 0;
  var index = 0;
  var state = _SqlState.code;

  while (index < sql.length) {
    final char = sql[index];
    final next = index + 1 < sql.length ? sql[index + 1] : null;

    switch (state) {
      case _SqlState.code:
        if (char == "'") {
          state = _SqlState.singleQuoted;
          output.write(char);
        } else if (char == '"') {
          state = _SqlState.doubleQuoted;
          output.write(char);
        } else if (char == '-' && next == '-') {
          state = _SqlState.lineComment;
          output.write('--');
          index++;
        } else if (char == '/' && next == '*') {
          state = _SqlState.blockComment;
          output.write('/*');
          index++;
        } else if (char == '?') {
          output.write(formatPlaceholder(++ordinal));
        } else {
          output.write(char);
        }
      case _SqlState.singleQuoted:
        output.write(char);
        if (char == "'") {
          if (next == "'") {
            output.write(next);
            index++;
          } else {
            state = _SqlState.code;
          }
        }
      case _SqlState.doubleQuoted:
        output.write(char);
        if (char == '"') {
          if (next == '"') {
            output.write(next);
            index++;
          } else {
            state = _SqlState.code;
          }
        }
      case _SqlState.lineComment:
        output.write(char);
        if (char == '\n' || char == '\r') state = _SqlState.code;
      case _SqlState.blockComment:
        output.write(char);
        if (char == '*' && next == '/') {
          output.write('/');
          index++;
          state = _SqlState.code;
        }
    }
    index++;
  }

  return output.toString();
}

enum _SqlState { code, singleQuoted, doubleQuoted, lineComment, blockComment }
