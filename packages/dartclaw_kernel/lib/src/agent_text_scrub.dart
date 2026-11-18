final _ansiCsi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

/// Flattens agent-reported [value] to one bounded line for a sink that shows it inline (a terminal line, an
/// operator-facing reason, a chat post).
///
/// ANSI CSI sequences are removed, every whitespace run (CR and LF included) becomes one space, the remaining C0,
/// DEL and C1 (U+0080–U+009F) control characters are stripped, and the result is trimmed. A result longer than
/// [maxLength] code units is cut there and ends in `…`. Agent output is untrusted: unscrubbed, it can carry terminal
/// escapes or a line break that forges a host-authored line.
String scrubAgentReportedText(String value, {int maxLength = 300}) {
  final flattened = value
      .replaceAll(_ansiCsi, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), '')
      .trim();
  if (flattened.length <= maxLength) return flattened;
  return '${flattened.substring(0, maxLength)}…';
}

/// Scrubs a multi-line block of agent-reported [value] for a sink that keeps its layout (a pull request body).
///
/// CRLF becomes LF, ANSI CSI sequences are removed, and every C0, DEL and C1 control character except tab and LF is
/// stripped, a lone CR included. Line structure and Markdown are kept; the value is neither trimmed nor bounded.
String scrubAgentReportedBlock(String value) =>
    value.replaceAll('\r\n', '\n').replaceAll(_ansiCsi, '').replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F-\x9F]'), '');
