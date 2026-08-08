import 'package:dartclaw_core/dartclaw_core.dart' show convertStandardMarkdownToNativeChatMarkup;

/// Converts standard Markdown to Google Chat's text markup.
///
/// Google Chat uses `*bold*`, `_italic_`, `~strike~`, and `<url|text>` links.
/// Code blocks, inline code, and escaped Markdown markers remain intact.
String markdownToGoogleChat(String markdown) {
  return convertStandardMarkdownToNativeChatMarkup(markdown, renderLink: _renderGoogleChatLink);
}

/// Converts Markdown to readable plain text for Google Chat card fields.
String markdownToGoogleChatPlainText(String markdown) {
  var text = markdownToGoogleChat(markdown);
  text = text.replaceAllMapped(RegExp(r'<([^|>]+)\|([^>]+)>'), (match) => '${match.group(2)} (${match.group(1)})');
  text = text.replaceAllMapped(RegExp(r'```\n([\s\S]*?)```'), (match) => match.group(1)!.trimRight());
  text = text.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (match) => match.group(1)!);
  for (final marker in ['*', '_', '~']) {
    final pattern = RegExp('${RegExp.escape(marker)}([^${RegExp.escape(marker)}\n]+)${RegExp.escape(marker)}');
    text = text.replaceAllMapped(pattern, (match) => match.group(1)!);
  }
  return text;
}

String _renderGoogleChatLink(String label, String url) => '<$url|$label>';
