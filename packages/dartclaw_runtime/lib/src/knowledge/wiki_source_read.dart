import 'dart:io';

import 'package:path/path.dart' as p;

import 'wiki_page_store.dart';

/// Reads the wiki page at [locator] (`wiki/<path>.md`, relative to [workspaceDir]).
///
/// Returns null for every refusal (malformed locator, traversal, missing file, symlink
/// escape, I/O failure), so callers can answer all of them identically and the
/// refusal never reveals what exists in the workspace.
String? readContainedWikiPage(String workspaceDir, String locator) {
  if (!locator.startsWith('wiki/') || !locator.endsWith('.md')) return null;
  final wikiRoot = p.normalize(p.absolute(p.join(workspaceDir, 'wiki')));
  final filePath = p.normalize(p.absolute(p.join(wikiRoot, locator.substring('wiki/'.length))));
  if (!p.isWithin(wikiRoot, filePath)) return null;
  final file = File(filePath);
  if (!file.existsSync()) return null;

  try {
    final canonicalWikiRoot = p.normalize(Directory(wikiRoot).resolveSymbolicLinksSync());
    final canonicalFilePath = p.normalize(file.resolveSymbolicLinksSync());
    if (!p.isWithin(canonicalWikiRoot, canonicalFilePath)) return null;
    // Read the path that was verified, not the one that was requested: the
    // workspace is agent-writable, so re-resolving through `file` would let a
    // symlink swapped in after the check serve content from outside the root.
    return File(canonicalFilePath).readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

/// A wiki page as a reader sees it: the page's own [title], the quiet frontmatter
/// [metadata] worth showing, and the [markdown] below the frontmatter and the
/// title heading, so neither renders a second time as body text.
typedef WikiSourcePage = ({String title, List<({String label, String value})> metadata, String markdown});

const _metadataFields = [('confidence', 'Confidence'), ('provenance', 'Provenance'), ('last_updated', 'Updated')];

/// Presents the wiki page [text] stored at [locator] for display.
///
/// The frontmatter is split by [WikiPageStore.splitFrontmatter] and dropped from
/// the body whether or not it parses. Of its keys only the three in
/// [_metadataFields] are shown, so `sources` and anything else a page carries
/// stays off the page. A fence that never closes cannot be told apart from the
/// body, so that text is shown as written.
WikiSourcePage presentWikiPage(String text, String locator) {
  final split = WikiPageStore.splitFrontmatter(text);
  final frontmatter = split?.frontmatter;
  final fields = frontmatter == null ? null : WikiPageStore.parseFrontmatter(frontmatter);
  final content = split?.body ?? text;
  final titled = WikiPageStore.splitTitle(content.trimLeft());
  final heading = titled.title?.substring(1).trim();
  return (
    title: heading == null || heading.isEmpty ? _humanizedSlug(locator) : heading,
    metadata: [
      for (final (key, label) in _metadataFields)
        if (_scalar(key, fields?[key]) case final value?) (label: label, value: value),
    ],
    markdown: titled.title == null ? content : titled.body,
  );
}

/// The shown form of a frontmatter value, or null for an absent, blank or non-scalar one.
String? _scalar(String key, Object? value) {
  if (value is! String && value is! num) return null;
  final text = '$value'.trim();
  if (text.isEmpty) return null;
  return key == 'last_updated' && text.length >= 10 && DateTime.tryParse(text) != null ? text.substring(0, 10) : text;
}

String _humanizedSlug(String locator) {
  final words = p.basenameWithoutExtension(locator).replaceAll(RegExp(r'[-_]+'), ' ').trim();
  return words.isEmpty ? 'Wiki page' : '${words[0].toUpperCase()}${words.substring(1)}';
}
