import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show MemoryFileService, MemoryResourceLimits, MemoryRole, MemorySearchDegradation, MemorySearchResult;
import 'package:path/path.dart' as p;

import 'search_file_io.dart';

/// Wiki frontmatter `provenance` values this source ranks and labels as trusted.
///
/// A writer must never move a page into this set on the strength of not
/// recognizing its stored value: that is how a page nothing can classify ends up
/// ranked above the corpus.
const trustedWikiProvenance = {'human-authored', 'hybrid'};

/// Every `provenance` value the wiki pipeline authors and this source
/// interprets. Anything else is stored data the pipeline must leave alone.
const knownWikiProvenance = {...trustedWikiProvenance, 'llm-authored'};

/// Reads synthesized wiki pages as a high-priority memory search source.
class WikiSearchSource {
  /// Workspace root that contains the `wiki/` directory.
  final String workspaceDir;

  /// Creates a source rooted at `<workspaceDir>/wiki`.
  new({required this.workspaceDir});

  /// Searches wiki markdown pages and returns synthesized results before raw memory.
  Future<List<MemorySearchResult>> search(String query, {int limit = 10}) async {
    final results = await searchAll(query);
    return results.take(limit.clamp(1, MemoryResourceLimits.searchResults)).toList(growable: false);
  }

  /// Searches every wiki page admitted by the current traversal.
  Future<List<MemorySearchResult>> searchAll(String query) async {
    return (await searchScan(query)).results;
  }

  /// Searches the bounded wiki scan and reports incomplete coverage.
  Future<WikiSearchScan> searchScan(String query) async {
    final wikiDir = Directory(p.join(workspaceDir, 'wiki'));
    if (!wikiDir.existsSync()) return const WikiSearchScan(results: []);

    final terms = _queryTerms(query);
    if (terms.isEmpty) return const WikiSearchScan(results: []);

    final results = <MemorySearchResult>[];
    var files = 0;
    var bytes = 0;
    var degraded = false;
    final degradations = <MemorySearchDegradation>[];
    final fileScan = await MemoryFileService.listRegularFilesBounded(wikiDir);
    var remainingFiles = fileScan.files.length;
    for (final entity in fileScan.files) {
      remainingFiles--;
      final locator = p.relative(entity.path, from: workspaceDir);
      files++;
      if (!entity.path.endsWith('.md')) continue;
      final size = entity.statSync().size;
      final remainingBytes = MemoryResourceLimits.recursiveBodyBytes - bytes;
      if (size > MemoryResourceLimits.sourceBytes || size > remainingBytes) {
        degraded = true;
        degradations.add(
          MemorySearchDegradation(
            layer: 'wiki',
            reason: size > MemoryResourceLimits.sourceBytes ? 'sourceBytes' : 'bodyBytes',
            locator: locator,
            observed: size > MemoryResourceLimits.sourceBytes ? size : bytes + size,
            limit: size > MemoryResourceLimits.sourceBytes
                ? MemoryResourceLimits.sourceBytes
                : MemoryResourceLimits.recursiveBodyBytes,
            omittedCount: size > remainingBytes ? remainingFiles + 1 : 1,
          ),
        );
        if (size > remainingBytes) break;
        continue;
      }
      bytes += size;
      String raw;
      try {
        raw = MemoryFileService.readRegularFile(
          File(entity.path),
          maxBytes: remainingBytes < MemoryResourceLimits.sourceBytes
              ? remainingBytes
              : MemoryResourceLimits.sourceBytes,
          role: MemoryRole.wiki,
        )!;
      } on Object {
        degraded = true;
        degradations.add(
          MemorySearchDegradation(
            layer: 'wiki',
            reason: 'readFailure',
            locator: locator,
            observed: bytes,
            limit: MemoryResourceLimits.recursiveBodyBytes,
            omittedCount: 1,
          ),
        );
        continue;
      }
      final body = _stripFrontmatter(raw);
      final haystack = body.toLowerCase();
      final matches = terms.where(haystack.contains).length;
      if (matches == 0) continue;

      final source = locator;
      final provenance = _frontmatterValue(raw, 'provenance');
      final isTrusted = trustedWikiProvenance.contains(provenance);
      final isSourceBacked = provenance == 'llm-authored' && _hasSourceFrontmatter(raw);
      results.add(
        MemorySearchResult(
          text: _snippet(body, terms),
          source: source,
          category: isTrusted ? 'synthesized knowledge' : 'untrusted synthesized knowledge',
          score: (isTrusted || isSourceBacked ? -1000.0 : 1000.0) - matches,
          role: 'wiki',
          provenance: provenance ?? 'wiki',
          locator: source,
        ),
      );
    }
    _recordFileExhaustion(degradations, fileScan, workspaceDir);

    results.sort((a, b) {
      final byScore = a.score.compareTo(b.score);
      return byScore != 0 ? byScore : a.locator.compareTo(b.locator);
    });
    return WikiSearchScan(
      results: results,
      degraded: degraded || degradations.isNotEmpty,
      degradations: degradations,
      processedFiles: files,
      processedBytes: bytes,
    );
  }

  /// Lists wiki markdown pages without requiring a search term.
  Future<List<MemorySearchResult>> list({int limit = 10}) async {
    final scan = await listScan();
    return scan.results.take(limit.clamp(1, MemoryResourceLimits.searchResults)).toList();
  }

  /// Lists pages admitted by the bounded wiki scan and reports incomplete coverage.
  Future<WikiSearchScan> listScan() async {
    final wikiDir = Directory(p.join(workspaceDir, 'wiki'));
    if (!wikiDir.existsSync()) return const WikiSearchScan(results: []);

    final results = <MemorySearchResult>[];
    var files = 0;
    var bytes = 0;
    var degraded = false;
    final degradations = <MemorySearchDegradation>[];
    final fileScan = await MemoryFileService.listRegularFilesBounded(wikiDir);
    var remainingFiles = fileScan.files.length;
    for (final entity in fileScan.files) {
      remainingFiles--;
      final locator = p.relative(entity.path, from: workspaceDir);
      files++;
      if (!entity.path.endsWith('.md')) continue;
      final file = entity;
      final size = file.statSync().size;
      final remainingBytes = MemoryResourceLimits.recursiveBodyBytes - bytes;
      if (size > MemoryResourceLimits.sourceBytes || size > remainingBytes) {
        degraded = true;
        degradations.add(
          MemorySearchDegradation(
            layer: 'wiki',
            reason: size > MemoryResourceLimits.sourceBytes ? 'sourceBytes' : 'bodyBytes',
            locator: locator,
            observed: size > MemoryResourceLimits.sourceBytes ? size : bytes + size,
            limit: size > MemoryResourceLimits.sourceBytes
                ? MemoryResourceLimits.sourceBytes
                : MemoryResourceLimits.recursiveBodyBytes,
            omittedCount: size > remainingBytes ? remainingFiles + 1 : 1,
          ),
        );
        if (size > remainingBytes) break;
        continue;
      }
      bytes += size;
      String? raw;
      try {
        raw = MemoryFileService.readRegularFile(
          file,
          maxBytes: remainingBytes < MemoryResourceLimits.sourceBytes
              ? remainingBytes
              : MemoryResourceLimits.sourceBytes,
          role: MemoryRole.wiki,
        );
      } on Object {
        degraded = true;
        degradations.add(
          MemorySearchDegradation(
            layer: 'wiki',
            reason: 'readFailure',
            locator: locator,
            observed: bytes,
            limit: MemoryResourceLimits.recursiveBodyBytes,
            omittedCount: 1,
          ),
        );
        continue;
      }
      if (raw == null) continue;
      final body = _stripFrontmatter(raw);
      final source = locator;
      results.add(
        MemorySearchResult(
          text: _snippet(body, const []),
          source: source,
          category: 'synthesized knowledge',
          score: 0,
          role: 'wiki',
          provenance: _frontmatterValue(raw, 'provenance') ?? 'wiki',
          locator: source,
        ),
      );
    }
    _recordFileExhaustion(degradations, fileScan, workspaceDir);

    results.sort((a, b) => a.source.compareTo(b.source));
    return WikiSearchScan(
      results: results,
      degraded: degraded || degradations.isNotEmpty,
      degradations: degradations,
      processedFiles: files,
      processedBytes: bytes,
    );
  }

  /// Resolves one wiki locator without following symlinks or leaving `wiki/`.
  Future<MemorySearchResult?> resolve(String locator) async {
    final normalized = locator.replaceAll('\\', '/');
    if (!normalized.startsWith('wiki/') || normalized.contains('/../') || normalized.endsWith('/..')) return null;
    final root = Directory(p.absolute(p.join(workspaceDir, 'wiki')));
    if (!root.existsSync()) return null;
    final file = File(p.normalize(p.join(p.absolute(workspaceDir), normalized)));
    if (!isRegularFileWithinRoot(root, file)) return null;
    final raw = MemoryFileService.readRegularFile(file, role: MemoryRole.wiki);
    if (raw == null) return null;
    return MemorySearchResult(
      text: _stripFrontmatter(raw),
      source: normalized,
      category: 'synthesized knowledge',
      score: 0,
      role: 'wiki',
      provenance: _frontmatterValue(raw, 'provenance') ?? 'wiki',
      locator: normalized,
    );
  }

  static List<String> _queryTerms(String query) => query
      .replaceAll('"', ' ')
      .split(RegExp(r'\s+'))
      .map((term) => term.trim().toLowerCase())
      .where((term) => term.isNotEmpty)
      .toList();

  static void _recordFileExhaustion(
    List<MemorySearchDegradation> degradations,
    ({List<File> files, File? firstOmitted, int omittedCount, bool complete}) scan,
    String workspaceDir,
  ) {
    if (scan.complete && scan.omittedCount == 0) return;
    degradations.add(
      MemorySearchDegradation(
        layer: 'wiki',
        reason: scan.complete ? 'fileLimit' : 'traversalLimit',
        locator: scan.firstOmitted == null ? null : p.relative(scan.firstOmitted!.path, from: workspaceDir),
        observed: scan.complete ? scan.files.length + scan.omittedCount : null,
        limit: scan.complete ? MemoryResourceLimits.recursiveFiles : null,
        omittedCount: scan.omittedCount,
      ),
    );
  }

  /// The frontmatter block of a stored wiki page, or `null` when it has none.
  ///
  /// Accepts CRLF because the writer does: a page recovered from a Windows
  /// checkout must rank as the page it is, not as one with no frontmatter.
  static String? _frontmatter(String text) {
    if (!text.startsWith('---\n') && !text.startsWith('---\r\n')) return null;
    final rest = text.substring(text.indexOf('\n') + 1);
    final end = RegExp(r'^---[ \t]*\r?$', multiLine: true).firstMatch(rest);
    return end == null ? null : rest.substring(0, end.start);
  }

  static String _stripFrontmatter(String text) {
    if (!text.startsWith('---\n') && !text.startsWith('---\r\n')) return text;
    final rest = text.substring(text.indexOf('\n') + 1);
    final end = RegExp(r'^---[ \t]*\r?$', multiLine: true).firstMatch(rest);
    return end == null ? text : rest.substring(end.end).trimLeft();
  }

  static String? _frontmatterValue(String text, String key) {
    final frontmatter = _frontmatter(text);
    if (frontmatter == null) return null;
    final pattern = RegExp('^${RegExp.escape(key)}:\\s*(.+?)\\r?\$', multiLine: true);
    return pattern.firstMatch(frontmatter)?.group(1)?.replaceAll('"', '').trim();
  }

  /// Whether the page records at least one source.
  ///
  /// Accepts the block, flow, and single-scalar shapes the writer accepts, so a
  /// hand-edited or foreign-tool-written page is not demoted for its YAML style.
  static bool _hasSourceFrontmatter(String text) {
    final frontmatter = _frontmatter(text);
    if (frontmatter == null) return false;
    final match = RegExp(r'^sources:[ \t]*(.*?)\r?$', multiLine: true).firstMatch(frontmatter);
    if (match == null) return false;
    final raw = match.group(1)!.trim();
    // A trailing comment is not a source, and neither is an empty or explicitly
    // null list: ranking such a page source-backed is the same laundering the
    // writer refuses to do.
    final commented = raw.indexOf(RegExp(r'(^|\s)#'));
    final inline = (commented == -1 ? raw : raw.substring(0, commented)).trim();
    if (inline.startsWith('[')) return inline.replaceAll(RegExp('[\\[\\]"\',\\s]'), '').isNotEmpty;
    if (inline.isNotEmpty && inline != 'null' && inline != '~') return true;
    return frontmatter
        .substring(match.end)
        .split('\n')
        .skip(1)
        .takeWhile((line) => line.startsWith(RegExp(r'\s')))
        .any((line) => line.trim().startsWith('- ') && line.trim().length > 2);
  }

  /// A wiki page grows by appending supplement sections, so the first and the
  /// last match can sit many sections apart. Anchored only on the first match,
  /// the snippet would show the oldest section for every query and hide
  /// everything appended since; when the last match falls outside the window at
  /// the first, the budget is split between a window at each so the newest
  /// matching content is visible from the search result itself.
  static String _snippet(String text, List<String> terms) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = compact.runes.toList(growable: false);
    if (runes.length <= 240) return compact;
    final lower = compact.toLowerCase();
    final first = terms.map(lower.indexOf).where((index) => index >= 0).fold<int?>(null, (best, index) {
      if (best == null || index < best) return index;
      return best;
    });
    final firstRune = first == null ? 0 : compact.substring(0, first).runes.length;
    final start = (firstRune - 80).clamp(0, runes.length);
    final last = terms.map(lower.lastIndexOf).fold(-1, (best, index) => index > best ? index : best);
    final lastRune = last < 0 ? 0 : compact.substring(0, last).runes.length;
    if (lastRune < start + 240) {
      return String.fromCharCodes(runes.sublist(start, (start + 240).clamp(0, runes.length)));
    }
    final headStart = (firstRune - 40).clamp(0, runes.length);
    final tailStart = (lastRune - 40).clamp(0, runes.length);
    final head = runes.sublist(headStart, (headStart + 118).clamp(0, runes.length));
    final tail = runes.sublist(tailStart, (tailStart + 118).clamp(0, runes.length));
    return '${String.fromCharCodes(head)} … ${String.fromCharCodes(tail)}';
  }
}

/// Accepted wiki candidates plus bounded-scan coverage.
final class WikiSearchScan {
  /// Creates one bounded wiki scan result.
  const new({
    required this.results,
    this.degraded = false,
    this.degradations = const [],
    this.processedFiles = 0,
    this.processedBytes = 0,
  });

  /// Candidates admitted and matched before output top-K.
  final List<MemorySearchResult> results;

  /// Whether a file or byte ceiling or file failure reduced coverage.
  final bool degraded;

  /// Structured limit and failure evidence for omitted wiki sources.
  final List<MemorySearchDegradation> degradations;

  /// Regular files admitted by this request, including unsupported extensions.
  final int processedFiles;

  /// Admitted body bytes read by this request.
  final int processedBytes;
}
