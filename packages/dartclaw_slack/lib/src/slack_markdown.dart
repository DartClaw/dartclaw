import 'package:dartclaw_core/dartclaw_core.dart' show convertStandardMarkdownToNativeChatMarkup;

/// Converts standard Markdown to Slack mrkdwn.
///
/// Emphasis, strikethrough and `<url|label>` links come from the shared native
/// chat conversion. `&`, `<` and `>` are escaped first, so the only `<` left in
/// the result belongs to a link the conversion built: a literal `<!channel>` or
/// `<@U123>` in the answer cannot ping or link anyone.
String markdownToSlackMrkdwn(String markdown) {
  return convertStandardMarkdownToNativeChatMarkup(escapeSlackText(markdown), renderLink: _renderSlackLink);
}

/// Escapes the three characters Slack treats as markup (`&`, `<`, `>`), so a
/// value cannot become a link, a mention or a broadcast.
String escapeSlackText(String text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _renderSlackLink(String label, String url) => '<$url|$label>';

/// Decodes the three entities Slack escapes in inbound text.
String decodeSlackText(String text) => text.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
