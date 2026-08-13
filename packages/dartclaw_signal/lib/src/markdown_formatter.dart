import 'dart:math' as math;

import 'package:dartclaw_core/dartclaw_core.dart' show ChannelResponse, TextChunkSlice, chunkTextSlices;
import 'package:markdown/markdown.dart' as markdown;

const signalTextStylesMetadataKey = 'textStyles';

enum _SignalStyle {
  bold('BOLD'),
  italic('ITALIC'),
  strikethrough('STRIKETHROUGH'),
  monospace('MONOSPACE');

  new(this.wireName);

  final String wireName;
}

final class _StyleRange {
  const new({required this.style, required this.start, required this.length});

  final _SignalStyle style;
  final int start;
  final int length;

  int get end => start + length;
}

final class _FormattedMarkdown {
  const new(this.text, this.styles);

  final String text;
  final List<_StyleRange> styles;
}

List<ChannelResponse> formatSignalMarkdown(String source, {required int maxSize}) {
  final formatted = _MarkdownTextBuilder().format(source);
  final slices = chunkTextSlices(formatted.text, maxSize: maxSize, preserveBoundaryWhitespace: true);
  final total = slices.length;

  return [for (var i = 0; i < total; i++) _responseForSlice(formatted, slices[i], index: i, total: total)];
}

ChannelResponse _responseForSlice(
  _FormattedMarkdown formatted,
  TextChunkSlice slice, {
  required int index,
  required int total,
}) {
  final prefix = total > 1 ? '(${index + 1}/$total) ' : '';
  final styles = <String>[];

  for (final range in formatted.styles) {
    final start = math.max(range.start, slice.start);
    final end = math.min(range.end, slice.end);
    if (start >= end) continue;
    styles.add('${prefix.length + start - slice.start}:${end - start}:${range.style.wireName}');
  }

  return ChannelResponse(
    text: '$prefix${slice.text}',
    metadata: {if (styles.isNotEmpty) signalTextStylesMetadataKey: styles},
  );
}

final class _MarkdownTextBuilder {
  final StringBuffer _buffer = StringBuffer();
  final List<_StyleRange> _styles = [];
  var _quoteDepth = 0;
  var _atLineStart = true;
  var _trailingNewlines = 0;

  int get _length => _buffer.length;

  _FormattedMarkdown format(String source) {
    final document = markdown.Document(extensionSet: markdown.ExtensionSet.gitHubFlavored, encodeHtml: false);
    final nodes = document.parse(source);
    for (final node in nodes) {
      _renderBlock(node);
    }

    final text = _buffer.toString().trimRight();
    final styles = _styles.where((range) => range.start < text.length).toList()
      ..sort((a, b) {
        final startOrder = a.start.compareTo(b.start);
        if (startOrder != 0) return startOrder;
        return a.style.index.compareTo(b.style.index);
      });
    return _FormattedMarkdown(text, styles);
  }

  void _renderBlock(markdown.Node node, {int listDepth = 0}) {
    if (node is markdown.Text) {
      _write(node.text);
      return;
    }
    if (node is! markdown.Element) return;

    switch (node.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        _withStyle(_SignalStyle.bold, () => _renderInlineChildren(node));
        _ensureNewlines(2);
      case 'p':
        _renderInlineChildren(node);
        _ensureNewlines(2);
      case 'ul':
        _renderList(node, ordered: false, depth: listDepth);
      case 'ol':
        _renderList(node, ordered: true, depth: listDepth);
      case 'blockquote':
        _quoteDepth += 1;
        _renderBlockChildren(node, listDepth: listDepth);
        _quoteDepth -= 1;
        _ensureNewlines(2);
      case 'pre':
        final code = node.textContent.trimRight();
        _withStyle(_SignalStyle.monospace, () => _write(code));
        _ensureNewlines(2);
      case 'table':
        _renderTable(node);
      case 'hr':
        _ensureNewlines(2);
      case 'input':
        _renderInline(node);
      default:
        _renderBlockChildren(node, listDepth: listDepth);
    }
  }

  void _renderList(markdown.Element list, {required bool ordered, required int depth}) {
    final items = list.children?.whereType<markdown.Element>().where((child) => child.tag == 'li').toList() ?? const [];
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    for (var i = 0; i < items.length; i++) {
      _write('${'  ' * depth}${ordered ? '${start + i}.' : '•'} ');
      _renderListItem(items[i], depth: depth);
      _ensureNewlines(1);
    }
    _ensureNewlines(2);
  }

  void _renderListItem(markdown.Element item, {required int depth}) {
    for (final child in item.children ?? const <markdown.Node>[]) {
      if (child is markdown.Element && child.tag == 'p') {
        _renderInlineChildren(child);
      } else if (child is markdown.Element && (child.tag == 'ul' || child.tag == 'ol')) {
        _ensureNewlines(1);
        _renderList(child, ordered: child.tag == 'ol', depth: depth + 1);
      } else {
        _renderBlock(child, listDepth: depth + 1);
      }
    }
  }

  void _renderTable(markdown.Element table) {
    final rows = <markdown.Element>[];
    _collectElements(table, 'tr', rows);
    for (final row in rows) {
      final cells =
          row.children?.whereType<markdown.Element>().where((cell) => cell.tag == 'th' || cell.tag == 'td').toList() ??
          const [];
      for (var i = 0; i < cells.length; i++) {
        if (i > 0) _write(' | ');
        final cell = cells[i];
        if (cell.tag == 'th') {
          _withStyle(_SignalStyle.bold, () => _renderInlineChildren(cell));
        } else {
          _renderInlineChildren(cell);
        }
      }
      _ensureNewlines(1);
    }
    _ensureNewlines(2);
  }

  void _collectElements(markdown.Element element, String tag, List<markdown.Element> result) {
    for (final child in element.children ?? const <markdown.Node>[]) {
      if (child is! markdown.Element) continue;
      if (child.tag == tag) result.add(child);
      _collectElements(child, tag, result);
    }
  }

  void _renderBlockChildren(markdown.Element element, {required int listDepth}) {
    for (final child in element.children ?? const <markdown.Node>[]) {
      _renderBlock(child, listDepth: listDepth);
    }
  }

  void _renderInlineChildren(markdown.Element element) {
    for (final child in element.children ?? const <markdown.Node>[]) {
      _renderInline(child);
    }
  }

  void _renderInline(markdown.Node node) {
    if (node is markdown.Text) {
      _write(node.text);
      return;
    }
    if (node is! markdown.Element) return;

    switch (node.tag) {
      case 'strong':
        _withStyle(_SignalStyle.bold, () => _renderInlineChildren(node));
      case 'em':
        _withStyle(_SignalStyle.italic, () => _renderInlineChildren(node));
      case 'del':
        _withStyle(_SignalStyle.strikethrough, () => _renderInlineChildren(node));
      case 'code':
        _withStyle(_SignalStyle.monospace, () => _renderInlineChildren(node));
      case 'a':
        final label = node.textContent;
        _renderInlineChildren(node);
        final url = node.attributes['href'];
        if (url != null && url.isNotEmpty && url != label) _write(' ($url)');
      case 'img':
        final alt = node.attributes['alt'] ?? '';
        final source = node.attributes['src'] ?? '';
        _write(alt.isEmpty ? source : '$alt ($source)');
      case 'br':
        _ensureNewlines(1);
      case 'input':
        _write(node.attributes.containsKey('checked') ? '[x] ' : '[ ] ');
      default:
        _renderInlineChildren(node);
    }
  }

  void _withStyle(_SignalStyle style, void Function() render) {
    _ensureQuotePrefix();
    final start = _length;
    render();
    final length = _length - start;
    if (length > 0) {
      _styles.add(_StyleRange(style: style, start: start, length: length));
    }
  }

  void _write(String text) {
    var segmentStart = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) != 10) continue;
      if (i > segmentStart) {
        _ensureQuotePrefix();
        _appendRaw(text.substring(segmentStart, i));
      }
      _appendRaw('\n');
      segmentStart = i + 1;
    }
    if (segmentStart < text.length) {
      _ensureQuotePrefix();
      _appendRaw(text.substring(segmentStart));
    }
  }

  void _ensureQuotePrefix() {
    if (_quoteDepth > 0 && _atLineStart) {
      _appendRaw('│ ' * _quoteDepth);
    }
  }

  void _appendRaw(String text) {
    if (text.isEmpty) return;
    _buffer.write(text);
    var trailing = 0;
    for (var i = text.length - 1; i >= 0 && text.codeUnitAt(i) == 10; i--) {
      trailing += 1;
    }
    _trailingNewlines = trailing == text.length ? _trailingNewlines + trailing : trailing;
    _atLineStart = text.endsWith('\n');
  }

  void _ensureNewlines(int count) {
    if (_trailingNewlines < count) _appendRaw('\n' * (count - _trailingNewlines));
  }
}
