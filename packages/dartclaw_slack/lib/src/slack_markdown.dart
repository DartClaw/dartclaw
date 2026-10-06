import 'package:dartclaw_core/dartclaw_core.dart' show convertStandardMarkdownToNativeChatMarkup;

/// Converts standard Markdown to Slack mrkdwn.
///
/// Emphasis, strikethrough and `<url|label>` links come from the shared native
/// chat conversion. `&`, `<` and `>` are escaped first, so the only `<` left in
/// the result belongs to a link the conversion built: a literal `<!channel>` or
/// `<@U123>` in the answer cannot ping or link anyone.
String markdownToSlackMrkdwn(String markdown) {
  final escaped = markdown.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  return convertStandardMarkdownToNativeChatMarkup(escaped, renderLink: _renderSlackLink);
}

String _renderSlackLink(String label, String url) => '<$url|$label>';

/// Decodes the three entities Slack escapes in inbound text.
String decodeSlackText(String text) => text.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
