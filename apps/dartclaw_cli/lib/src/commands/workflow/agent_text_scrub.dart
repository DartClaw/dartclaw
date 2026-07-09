/// Scrubs agent-derived text at the CLI printer boundary: ANSI/CSI escape
/// sequences are removed, whitespace (including CR/LF) collapses to single
/// spaces, remaining control characters – including the C1 range
/// (U+0080–U+009F, single-code-point CSI/OSC introducers some terminals
/// honor) – are stripped, and the value is truncated. Agent output is
/// untrusted; without this a reason string can inject terminal escapes,
/// forge log lines, or flood the terminal. Mirrors the engine-side sanitizer
/// but stays CLI-local – the printer boundary must hold even for values
/// persisted before the engine-side scrub existed.
String scrubAgentReportedText(String value, {int maxLength = 300}) {
  final flattened = value
      .replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), '')
      .trim();
  if (flattened.length <= maxLength) return flattened;
  return '${flattened.substring(0, maxLength)}…';
}
