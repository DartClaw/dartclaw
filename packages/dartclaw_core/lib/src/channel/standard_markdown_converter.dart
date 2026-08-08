final _bulletListPattern = RegExp(r'^(\s*)\* ', multiLine: true);
final _headerPattern = RegExp(r'^#{1,6}\s+(.+)$', multiLine: true);
final _horizontalRulePattern = RegExp(r'^\s*([-*_]\s*){3,}$', multiLine: true);
final _tableSeparatorPattern = RegExp(r'^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$');
final _tableRowPattern = RegExp(r'^\s*\|(.+)\|\s*$');
final _imagePattern = RegExp(r'!\[([^\]]*)\]\(([^)]+)\)');
final _linkPattern = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');
final _referenceImagePattern = RegExp(r'!\[([^\]]*)\]\[([^\]]*)\]');
final _referenceLinkPattern = RegExp(r'\[([^\]]+)\]\[([^\]]*)\]');
final _referenceDefinitionPattern = RegExp(
  r'^\s{0,3}\[([^\]]+)\]:[ \t]*(?:<([^>]+)>|(\S+))(?:[ \t]+.*)?$',
  multiLine: true,
  caseSensitive: false,
);
final _boldItalicStarPattern = RegExp(r'\*{3}(.+?)\*{3}');
final _boldItalicUnderPattern = RegExp(r'___(.+?)___');
final _boldStarPattern = RegExp(r'\*{2}(.+?)\*{2}');
final _boldUnderPattern = RegExp(r'__(.+?)__');
final _italicPattern = RegExp(r'(?<!\w)\*(\S(?:.*?\S)?)\*(?!\w)');
final _strikethroughPattern = RegExp(r'~~(.+?)~~');
final _fencedCodePattern = RegExp(r'```[^\n]*\n([\s\S]*?)```');
final _inlineCodePattern = RegExp(r'`[^`\n]+`');
final _escapedMarkerPattern = RegExp(r'\\([*_~`\[\]#!])');

/// Converts standard Markdown to native chat markup.
///
/// Converts headings and emphasis to native markers, normalizes bullet lists
/// and tables, removes horizontal rules, renders images as readable text, and
/// resolves reference definitions. Code regions and escaped markers remain
/// intact.
///
/// [renderLink] supplies the platform representation for inline and resolved
/// reference links. Its output is inserted before emphasis and strikethrough
/// conversion, so native link delimiters must not use Markdown markers.
String convertStandardMarkdownToNativeChatMarkup(
  String markdown, {
  required String Function(String label, String url) renderLink,
}) {
  if (markdown.isEmpty) return markdown;

  final protectedRegions = <String>[];
  var text = _protectCodeRegions(markdown, protectedRegions);
  text = _protectEscapedMarkers(text, protectedRegions);
  final references = <String, String>{};
  text = text.replaceAllMapped(_referenceDefinitionPattern, (match) {
    references[match.group(1)!.toLowerCase()] = match.group(2) ?? match.group(3)!;
    return '';
  });
  text = _normalizeTables(text);

  const boldOpen = '\x02';
  const boldClose = '\x03';

  text = text.replaceAllMapped(_bulletListPattern, (match) => '${match.group(1)}- ');
  text = text.replaceAllMapped(
    _headerPattern,
    (match) => '$boldOpen${_headingContent(match.group(1)!.trim())}$boldClose',
  );
  text = text.replaceAll(_horizontalRulePattern, '');
  text = text.replaceAllMapped(_imagePattern, (match) {
    final alt = match.group(1)!;
    final url = match.group(2)!;
    return alt.isEmpty ? url : '$alt ($url)';
  });
  text = text.replaceAllMapped(_referenceImagePattern, (match) {
    final alt = match.group(1)!;
    final key = (match.group(2)!.isEmpty ? alt : match.group(2)!).toLowerCase();
    final url = references[key];
    if (url == null) return match.group(0)!;
    return alt.isEmpty ? url : '$alt ($url)';
  });
  text = text.replaceAllMapped(_referenceLinkPattern, (match) {
    final label = match.group(1)!;
    final key = (match.group(2)!.isEmpty ? label : match.group(2)!).toLowerCase();
    final url = references[key];
    return url == null ? match.group(0)! : renderLink(label, url);
  });
  text = text.replaceAllMapped(_linkPattern, (match) => renderLink(match.group(1)!, match.group(2)!));
  text = text.replaceAllMapped(_boldItalicStarPattern, (match) => '${boldOpen}_${match.group(1)}_$boldClose');
  text = text.replaceAllMapped(_boldItalicUnderPattern, (match) => '${boldOpen}_${match.group(1)}_$boldClose');
  text = text.replaceAllMapped(_boldStarPattern, (match) => '$boldOpen${match.group(1)}$boldClose');
  text = text.replaceAllMapped(_boldUnderPattern, (match) => '$boldOpen${match.group(1)}$boldClose');
  text = text.replaceAllMapped(_italicPattern, (match) => '_${match.group(1)}_');
  text = text.replaceAll(boldOpen, '*').replaceAll(boldClose, '*');
  text = text.replaceAllMapped(_strikethroughPattern, (match) => '~${match.group(1)}~');

  return _restoreProtectedRegions(text, protectedRegions);
}

String _headingContent(String content) {
  return content
      .replaceAllMapped(_boldItalicStarPattern, (match) => '_${match.group(1)}_')
      .replaceAllMapped(_boldItalicUnderPattern, (match) => '_${match.group(1)}_')
      .replaceAllMapped(_boldStarPattern, (match) => match.group(1)!)
      .replaceAllMapped(_boldUnderPattern, (match) => match.group(1)!);
}

String _normalizeTables(String text) {
  final lines = <String>[];
  for (final line in text.split('\n')) {
    if (_tableSeparatorPattern.hasMatch(line.trim())) continue;
    final row = _tableRowPattern.firstMatch(line);
    lines.add(row == null ? line : row.group(1)!.trim());
  }
  return lines.join('\n');
}

String _protectEscapedMarkers(String text, List<String> store) {
  return text.replaceAllMapped(_escapedMarkerPattern, (match) {
    store.add(match.group(0)!);
    return '\x00P${store.length - 1}\x00';
  });
}

String _protectCodeRegions(String text, List<String> store) {
  text = text.replaceAllMapped(_fencedCodePattern, (match) {
    store.add('```\n${match.group(1)}```');
    return '\x00P${store.length - 1}\x00';
  });
  return text.replaceAllMapped(_inlineCodePattern, (match) {
    store.add(match.group(0)!);
    return '\x00P${store.length - 1}\x00';
  });
}

String _restoreProtectedRegions(String text, List<String> store) {
  for (var i = store.length - 1; i >= 0; i--) {
    text = text.replaceFirst('\x00P$i\x00', store[i]);
  }
  return text;
}
