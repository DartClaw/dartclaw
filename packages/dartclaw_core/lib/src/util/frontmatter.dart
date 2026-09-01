final _fenceLine = RegExp(r'^---[ \t]*\r?$', multiLine: true);

/// Splits page [text] into its leading `---` frontmatter block and the body
/// below it, or `null` when the text opens no fence at all.
///
/// A `null` `frontmatter` means the fence was opened and never closed – what a
/// torn write leaves, and what readers must refuse rather than reinterpret.
/// CRLF is accepted on both fences, so a Windows-checkout page reads as itself.
({String? frontmatter, String body})? splitFrontmatter(String text) {
  if (!text.startsWith('---\n') && !text.startsWith('---\r\n')) return null;
  final rest = text.substring(text.indexOf('\n') + 1);
  final fence = _fenceLine.firstMatch(rest);
  if (fence == null) return (frontmatter: null, body: rest);
  // A `---\r` fence line closed by CRLF – what a second dos2unix pass leaves –
  // ends the match at the first CR, so the body can still open on either.
  final body = rest.substring(fence.end);
  return (
    frontmatter: rest.substring(0, fence.start),
    body: body.startsWith('\r\n')
        ? body.substring(2)
        : body.startsWith('\n')
        ? body.substring(1)
        : body,
  );
}
