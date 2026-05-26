/// Truncates [s] to [maxLength] **characters** (UTF-16 code units), appending
/// [suffix] if truncated.
///
/// The total output length is at most [maxLength]. If [s] is already within
/// [maxLength] it is returned unchanged. If [maxLength] is shorter than
/// [suffix], the suffix is clamped to zero characters.
///
/// For truncation by UTF-8 **byte** count (e.g. classifier payload limits),
/// use `truncateUtf8Bytes` from `package:dartclaw_security`.
String truncate(String s, int maxLength, {String suffix = '…'}) {
  if (s.length <= maxLength) return s;
  final cut = maxLength - suffix.length;
  return '${s.substring(0, cut < 0 ? 0 : cut)}$suffix';
}
