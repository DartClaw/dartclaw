import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show MemorySearchResult;
import 'package:path/path.dart' as p;

/// Reads synthesized wiki pages as a high-priority memory search source.
class WikiSearchSource {
  /// Workspace root that contains the `wiki/` directory.
  final String workspaceDir;

  /// Creates a source rooted at `<workspaceDir>/wiki`.
  WikiSearchSource({required this.workspaceDir});

  /// Searches wiki markdown pages and returns synthesized results before raw memory.
  Future<List<MemorySearchResult>> search(String query, {int limit = 10}) async {
    final wikiDir = Directory(p.join(workspaceDir, 'wiki'));
    if (!wikiDir.existsSync()) return const [];

    final terms = _queryTerms(query);
    if (terms.isEmpty) return const [];

    final results = <MemorySearchResult>[];
    await for (final entity in wikiDir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final raw = await entity.readAsString();
      final body = _stripFrontmatter(raw);
      final haystack = body.toLowerCase();
      final matches = terms.where(haystack.contains).length;
      if (matches == 0) continue;

      final source = p.relative(entity.path, from: workspaceDir);
      final provenance = _frontmatterValue(raw, 'provenance');
      final isTrusted = provenance == 'human-authored' || provenance == 'hybrid';
      final isSourceBacked = provenance == 'llm-authored' && _hasSourceFrontmatter(raw);
      results.add(
        MemorySearchResult(
          text: _snippet(body, terms),
          source: source,
          category: isTrusted ? 'synthesized knowledge' : 'untrusted synthesized knowledge',
          score: (isTrusted || isSourceBacked ? -1000.0 : 1000.0) - matches,
        ),
      );
    }

    results.sort((a, b) => a.score.compareTo(b.score));
    return results.take(limit).toList();
  }

  /// Lists wiki markdown pages without requiring a search term.
  Future<List<MemorySearchResult>> list({int limit = 10}) async {
    final wikiDir = Directory(p.join(workspaceDir, 'wiki'));
    if (!wikiDir.existsSync()) return const [];

    final results = <MemorySearchResult>[];
    await for (final entity in wikiDir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final raw = await entity.readAsString();
      final body = _stripFrontmatter(raw);
      final source = p.relative(entity.path, from: workspaceDir);
      results.add(
        MemorySearchResult(text: _snippet(body, const []), source: source, category: 'synthesized knowledge', score: 0),
      );
    }

    results.sort((a, b) => a.source.compareTo(b.source));
    return results.take(limit).toList();
  }

  static List<String> _queryTerms(String query) => query
      .replaceAll('"', ' ')
      .split(RegExp(r'\s+'))
      .map((term) => term.trim().toLowerCase())
      .where((term) => term.isNotEmpty)
      .toList();

  static String _stripFrontmatter(String text) {
    if (!text.startsWith('---\n')) return text;
    final end = text.indexOf('\n---', 4);
    if (end == -1) return text;
    return text.substring(end + 4).trimLeft();
  }

  static String? _frontmatterValue(String text, String key) {
    if (!text.startsWith('---\n')) return null;
    final end = text.indexOf('\n---', 4);
    if (end == -1) return null;
    final pattern = RegExp('^${RegExp.escape(key)}:\\s*(.+)\$', multiLine: true);
    return pattern.firstMatch(text.substring(4, end))?.group(1)?.replaceAll('"', '').trim();
  }

  static bool _hasSourceFrontmatter(String text) {
    if (!text.startsWith('---\n')) return false;
    final end = text.indexOf('\n---', 4);
    if (end == -1) return false;
    final frontmatter = text.substring(4, end);
    final sourcesIndex = frontmatter.indexOf(RegExp(r'^sources:\s*$', multiLine: true));
    if (sourcesIndex == -1) return false;
    return frontmatter
        .substring(sourcesIndex)
        .split('\n')
        .skip(1)
        .takeWhile((line) => line.startsWith(RegExp(r'\s')))
        .any((line) => line.trim().startsWith('- ') && line.trim().length > 2);
  }

  static String _snippet(String text, List<String> terms) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 240) return compact;
    final lower = compact.toLowerCase();
    final first = terms.map(lower.indexOf).where((index) => index >= 0).fold<int?>(null, (best, index) {
      if (best == null || index < best) return index;
      return best;
    });
    final start = first == null ? 0 : (first - 80).clamp(0, compact.length);
    final end = (start + 240).clamp(0, compact.length);
    return compact.substring(start, end);
  }
}
