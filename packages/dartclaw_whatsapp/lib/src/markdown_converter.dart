import 'package:dartclaw_core/dartclaw_core.dart' show convertStandardMarkdownToNativeChatMarkup;

String markdownToWhatsApp(String markdown) {
  return convertStandardMarkdownToNativeChatMarkup(markdown, renderLink: _renderWhatsAppLink);
}

String _renderWhatsAppLink(String label, String url) => '$label ($url)';
