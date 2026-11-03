import 'package:dartclaw_core/dartclaw_core.dart' show chunkNativeChatMarkup, convertStandardMarkdownToNativeChatMarkup;

/// The longest text one posted Slack message carries here; a longer reply is split.
const _chunkSize = 4000;

/// A reply as Slack shows it: standard Markdown converted to mrkdwn.
///
/// Emphasis, strikethrough and `<url|label>` links come from the shared native
/// chat conversion. `&`, `<` and `>` are escaped first, so the only `<` left in
/// the result belongs to a link the conversion built: a literal `<!channel>` or
/// `<@U123>` in the answer cannot ping or link anyone.
String slackReplyText(String reply) => convertStandardMarkdownToNativeChatMarkup(
  escapeSlackMarkdown(reply.trimLeft()),
  renderLink: (label, url) => '<$url|$label>',
);

/// A reply split into posts of at most [_chunkSize] characters, each of a
/// multi-part reply carrying its `(n/total)` label.
List<String> slackReplyChunks(String reply) => chunkNativeChatMarkup(slackReplyText(reply), maxSize: _chunkSize);

/// Escapes the three characters Slack treats as markup in streamed Markdown, so a
/// literal `<!channel>` or `<@U123>` in the answer cannot ping anyone.
String escapeSlackMarkdown(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Decodes the three entities Slack escapes in inbound text.
String decodeSlackText(String text) => text.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
