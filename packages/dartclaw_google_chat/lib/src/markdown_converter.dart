// Precompiled RegExp patterns for markdown-to-Google-Chat conversion.
final _bulletListPattern = RegExp(r'^\* ', multiLine: true);
final _headerPattern = RegExp(r'^#{1,6}\s+(.+)$', multiLine: true);
final _horizontalRulePattern = RegExp(r'^\s*([-*_]\s*){3,}$', multiLine: true);
final _imagePattern = RegExp(r'!\[([^\]]*)\]\(([^)]+)\)');
final _linkPattern = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');
final _boldItalicStarPattern = RegExp(r'\*{3}(.+?)\*{3}');
final _boldItalicUnderPattern = RegExp(r'___(.+?)___');
final _boldStarPattern = RegExp(r'\*{2}(.+?)\*{2}');
final _boldUnderPattern = RegExp(r'__(.+?)__');
final _italicPattern = RegExp(r'(?<!\w)\*(\S(?:.*?\S)?)\*(?!\w)');
final _strikethroughPattern = RegExp(r'~~(.+?)~~');
final _fencedCodePattern = RegExp(r'```[^\n]*\n[\s\S]*?```');
final _inlineCodePattern = RegExp(r'`[^`\n]+`');
final _escapedMarkerPattern = RegExp(r'\\([*_~`\[\]#!])');

/// Converts standard Markdown to Google Chat's text markup.
///
/// Google Chat uses non-standard formatting: `*bold*` (not `**bold**`),
/// `_italic_`, `~strike~` (not `~~strike~~`), `<url|text>` links. Standard
/// markdown from LLM output does not render correctly without conversion.
///
/// Code blocks and inline code are protected from conversion.
String markdownToGoogleChat(String markdown) {
  if (markdown.isEmpty) return markdown;

  var text = markdown;

  // 1. Protect code regions and escaped markers from conversion.
  final protectedRegions = <String>[];
  text = _protectCodeRegions(text, protectedRegions);
  text = _protectEscapedMarkers(text, protectedRegions);

  // Bold placeholders — prevent the italic pass from re-matching bold
  // markers produced by header or bold conversion.
  const boldOpen = '\x02';
  const boldClose = '\x03';

  // 2. Normalize `* item` bullet lists to `- item` (before bold/italic
  //    conversion to avoid ambiguity with italic markers).
  text = text.replaceAll(_bulletListPattern, '- ');

  // 3. Headers -> bold (all levels). Uses bold placeholders.
  text = text.replaceAllMapped(_headerPattern, (m) => '$boldOpen${m.group(1)!.trim()}$boldClose');

  // 4. Horizontal rules -> empty line.
  text = text.replaceAll(_horizontalRulePattern, '');

  // 5. Images -> plain text (before link conversion).
  text = text.replaceAllMapped(_imagePattern, (m) {
    final alt = m.group(1)!;
    final url = m.group(2)!;
    return alt.isNotEmpty ? '$alt ($url)' : url;
  });

  // 6. Links -> Google Chat syntax.
  text = text.replaceAllMapped(_linkPattern, (m) => '<${m.group(2)}|${m.group(1)}>');

  // 7-10. Bold and italic conversion.
  //
  // Standard markdown: ***bold italic***, **bold**, *italic*
  // Google Chat:       *_bold italic_*,   *bold*,   _italic_

  // 7. Bold + italic (***text*** / ___text___) -> *_text_*
  text = text.replaceAllMapped(_boldItalicStarPattern, (m) => '${boldOpen}_${m.group(1)}_$boldClose');
  text = text.replaceAllMapped(_boldItalicUnderPattern, (m) => '${boldOpen}_${m.group(1)}_$boldClose');

  // 8. Bold (**text** / __text__) -> placeholder
  text = text.replaceAllMapped(_boldStarPattern, (m) => '$boldOpen${m.group(1)}$boldClose');
  text = text.replaceAllMapped(_boldUnderPattern, (m) => '$boldOpen${m.group(1)}$boldClose');

  // 9. Italic (*text*) -> _text_
  //    Requires non-word boundary to avoid matching math like 2*3.
  text = text.replaceAllMapped(_italicPattern, (m) => '_${m.group(1)}_');

  // 10. Resolve bold placeholders -> *text*
  text = text.replaceAll(boldOpen, '*').replaceAll(boldClose, '*');

  // 11. Strikethrough (~~text~~) -> ~text~
  text = text.replaceAllMapped(_strikethroughPattern, (m) => '~${m.group(1)}~');

  // 12. Restore protected code regions.
  text = _restoreCodeRegions(text, protectedRegions);

  return text;
}

/// Replaces backslash-escaped markdown markers with placeholders.
String _protectEscapedMarkers(String text, List<String> store) {
  return text.replaceAllMapped(_escapedMarkerPattern, (m) {
    store.add(m.group(0)!);
    return '\x00P${store.length - 1}\x00';
  });
}

/// Replaces fenced code blocks and inline code with placeholders.
String _protectCodeRegions(String text, List<String> store) {
  // Fenced code blocks (``` ... ```) — must handle multiline.
  text = text.replaceAllMapped(_fencedCodePattern, (m) {
    store.add(m.group(0)!);
    return '\x00P${store.length - 1}\x00';
  });

  // Inline code (`text`).
  text = text.replaceAllMapped(_inlineCodePattern, (m) {
    store.add(m.group(0)!);
    return '\x00P${store.length - 1}\x00';
  });

  return text;
}

/// Restores placeholders with original code content.
String _restoreCodeRegions(String text, List<String> store) {
  for (var i = store.length - 1; i >= 0; i--) {
    text = text.replaceFirst('\x00P$i\x00', store[i]);
  }
  return text;
}
