import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' as core;
import 'package:dartclaw_core/dartclaw_core.dart' show knownWikiProvenance;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Collapses every whitespace run in [value] to a single space and trims the
/// result, so two texts compare on content rather than formatting.
String normalizeWhitespace(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

/// How a [WikiPageStore.writePage] call related to the page already stored.
enum WikiPageOutcome {
  /// No page was stored for the slug, so the body was authored fresh.
  created,

  /// The settled merge replaced the stored body with the merged one.
  integrated,

  /// The settled merge contributed no body, so the stored body was left alone.
  unchanged,

  /// The settled merge called the material unrelated, so the body was appended
  /// as a new supplement section below the stored one.
  supplemented,
}

/// What a settled merge does to the page already stored for a slug.
enum WikiMergeMode {
  /// Replace the stored body with the merged one.
  integrated,

  /// Leave the stored body alone.
  unchanged,

  /// Append the body as a new supplement section.
  supplement,
}

/// The merge decision [WikiPageStore.writePage] performs on a slug that already
/// holds a page.
///
/// The store never decides this for itself: whether a follow-up source belongs
/// in the stored page's body is a judgement, and the store's job is to carry out
/// the settled one and refuse the ones it can check.
class WikiPageMerge {
  /// What to do with the stored body.
  final WikiMergeMode mode;

  /// What the merge declares it dropped from the stored page. A non-empty list
  /// waives the [WikiPageStore.mergeShrinkFloor] guard; the store reads only
  /// whether it is empty, never its text.
  final List<String> removedContent;

  /// Creates a [WikiPageMerge] decision.
  const new({required this.mode, this.removedContent = const []});
}

/// Outcome of a [WikiPageStore.writePage] call.
class WikiPageWrite {
  /// The stored page file.
  final File file;

  /// What the write did to the page already stored for the slug.
  final WikiPageOutcome outcome;

  /// Creates a [WikiPageWrite] value.
  const new({required this.file, required this.outcome});
}

/// Thrown when a stored page cannot be read or its frontmatter cannot be
/// parsed, so writing over it would destroy content the store cannot account
/// for. Carries the page path because the operator has to repair the page, not
/// the inbox source whose ingestion reported the failure.
class WikiPageUnreadable implements Exception {
  /// Workspace-relative path of the page that could not be read. Relative
  /// because this message reaches the run report, and from there a channel and
  /// the server log, where an absolute host path does not belong.
  final String path;

  /// Why the page could not be read, in operator-facing terms.
  final String reason;

  /// Creates a [WikiPageUnreadable] failure.
  const new({required this.path, required this.reason});

  @override
  String toString() => 'wiki page $path cannot be read ($reason); repair or remove it before ingesting this slug';
}

/// Thrown when an integrated merge would leave the stored page materially
/// shorter without declaring what it removed.
///
/// The stored page is the only copy of every prior batch, so a merge that
/// silently drops most of it is indistinguishable from a model replacing a
/// curated page with a short summary. Carries the observed and required sizes
/// because that is what tells an operator whether the merge was honest.
class WikiPageMergeRefused implements Exception {
  /// Workspace-relative path of the page the merge would have shortened.
  final String path;

  /// UTF-8 byte count of the stored body the merge was shown.
  final int storedBytes;

  /// UTF-8 byte count of the merged body the turn returned.
  final int mergedBytes;

  /// Least [mergedBytes] this merge could have kept without declaring a removal.
  final int requiredBytes;

  /// Creates a [WikiPageMergeRefused] failure.
  const new({required this.path, required this.storedBytes, required this.mergedBytes, required this.requiredBytes});

  @override
  String toString() =>
      'wiki page $path refused a merge shrinking it from $storedBytes to $mergedBytes bytes '
      '($requiredBytes required) while declaring no removed content';
}

class _StoredWikiPage {
  final List<String> sources;
  final String content;

  /// Whether the page opened a frontmatter block at all. A page without one is
  /// hand-authored; a page with one that omits `provenance` is a page this store
  /// must not classify.
  final bool hasFrontmatter;
  final String? provenance;
  final String? confidence;
  final String? lastUpdated;
  final String? lastUpdatedBy;
  final Map<String, Object?> preserved;

  const new({
    required this.sources,
    required this.content,
    this.hasFrontmatter = false,
    this.provenance,
    this.confidence,
    this.lastUpdated,
    this.lastUpdatedBy,
    this.preserved = const {},
  });
}

/// Stores synthesized wiki pages with provenance frontmatter.
///
/// Also owns the stored page format – frontmatter splitting, the provenance and
/// confidence vocabularies, and supplement-section recognition – so that every
/// reader of a stored page shares one parse of it.
class WikiPageStore {
  /// Confidence values, weakest first: a merge takes the weaker of the two.
  static const confidenceLevels = ['low', 'medium', 'high'];

  /// Least share of the stored body an integrated merge may keep while declaring
  /// no removed content.
  ///
  /// Fixed here rather than configured: this is the one thing the host can check
  /// about a merge it cannot read, and a floor an operator can lower is a floor
  /// a bad merge can be configured past. The headroom exists so an honest merge
  /// may de-duplicate overlap between the stored page and the new synthesis; a
  /// floor at parity would refuse that, and one at half would admit a curated
  /// page replaced by a summary.
  static const mergeShrinkFloor = 0.8;

  /// Frontmatter keys [writePage] owns; every other stored key is preserved.
  static const _writerOwnedKeys = {'provenance', 'sources', 'confidence', 'last_updated', 'last_updated_by'};

  static final _supplementLine = RegExp(r'^## Supplement(?: from (.+?))? \(\d{4}-\d{2}-\d{2}\)[ \t]*\r?$');

  final String workspaceDir;

  new({required this.workspaceDir});

  Directory get wikiDir => Directory(p.join(workspaceDir, 'wiki'));

  void bootstrap() {
    wikiDir.createSync(recursive: true);
    final readme = File(p.join(wikiDir.path, 'README.md'));
    if (!readme.existsSync()) {
      final frontmatter = _frontmatter(
        provenance: 'human-authored',
        sources: const ['workspace-bootstrap'],
        confidence: 'high',
        lastUpdated: '1970-01-01T00:00:00.000Z',
        lastUpdatedBy: 'workspace-bootstrap',
      );
      readme.writeAsStringSync(
        '$frontmatter# Wiki\n\n'
        'Synthesized, source-backed knowledge pages.\n\n'
        'Frontmatter `provenance` drives search trust: `human-authored` and `hybrid` rank as trusted, '
        '`llm-authored` ranks as trusted while `sources` is populated, and any other value ranks untrusted. '
        'Ingestion records `hybrid` only when it supplements a page whose stored provenance it recognises; '
        'a value it does not recognise is written back untouched, and a page that records none keeps none.\n',
      );
    }
  }

  /// The file storing [slug], with the slug reduced to `[a-z0-9-]`.
  ///
  /// Throws [ArgumentError] for a slug that escapes the wiki directory.
  File pageFile(String slug) {
    final file = File(p.join(wikiDir.path, '${pageSlug(slug)}.md'));
    if (!p.isWithin(p.normalize(wikiDir.absolute.path), p.normalize(file.absolute.path))) {
      throw ArgumentError('wiki page slug escapes wiki directory');
    }
    return file;
  }

  /// Writes the page for [slug], never dropping what an earlier write left there.
  ///
  /// A slug that already holds a page requires a settled [merge]; without one
  /// this call throws, because the store has no way to decide what a follow-up
  /// source means for the stored body and guessing is what grew pages forever.
  /// [WikiMergeMode.integrated] replaces the stored body with [body] under the
  /// stored title heading, [WikiMergeMode.unchanged] leaves the body alone, and
  /// [WikiMergeMode.supplement] appends [body] under a dated supplement heading.
  ///
  /// Every other rule holds whichever mode is settled: the stored `sources` are
  /// unioned with [sources], every frontmatter key this store does not own is
  /// carried through unchanged, `confidence` becomes the weaker of the stored
  /// and incoming values (a page mixing a curated section with a machine merge
  /// is only as strong as its weakest part) unless the stored value is outside
  /// the confidence vocabulary, in which case it is written back untouched like
  /// an unrecognised provenance, and `last_updated_by` names this writer because
  /// this writer did make the change. A stored `human-authored` or `hybrid` page
  /// becomes `hybrid`; a stored value this store does not recognise is written
  /// back untouched, and a page whose frontmatter records no provenance keeps
  /// none – neither is promoted into the search-trusted tier.
  ///
  /// A [WikiMergeMode.unchanged] merge moves no authorship field, and writes
  /// nothing at all when [sources] adds nothing to the page.
  ///
  /// Throws [ArgumentError] for a slug that escapes the wiki directory, an
  /// unsupported [confidence], a blank [body], or a collision with no settled
  /// [merge]. Throws [WikiPageUnreadable] when a page is stored for [slug] but
  /// cannot be read or parsed, and [WikiPageMergeRefused] when an integration
  /// breaches [mergeShrinkFloor] while declaring no removed content.
  Future<WikiPageWrite> writePage({
    required String slug,
    required String title,
    required String body,
    required List<String> sources,
    required String lastUpdatedBy,
    required DateTime now,
    String provenance = 'llm-authored',
    String confidence = 'medium',
    WikiPageMerge? merge,
  }) async {
    bootstrap();
    if (body.trim().isEmpty) throw ArgumentError('wiki page body must not be blank');
    final file = pageFile(slug);
    final safeConfidence = confidenceOrThrow(confidence);
    final existing = _readPage(file);
    if (existing == null) {
      final frontmatter = _frontmatter(
        provenance: provenance,
        sources: sources,
        confidence: safeConfidence,
        lastUpdated: now.toUtc().toIso8601String(),
        lastUpdatedBy: lastUpdatedBy,
      );
      await core.secureWriteFile(file, '$frontmatter# $title\n\n$body\n', restrictPermissions: false);
      return WikiPageWrite(file: file, outcome: WikiPageOutcome.created);
    }
    if (merge == null) {
      throw ArgumentError('wiki page $slug is already stored; writePage needs the settled merge decision');
    }
    final unioned = _unionSources(existing.sources, sources);
    if (merge.mode == WikiMergeMode.unchanged) {
      // Nothing was contributed, so no authorship field moves. A genuinely new
      // source is still recorded: its knowledge is demonstrably on the page, and
      // the provenance chain has to account for it. A repeat of a source the
      // page already records changes nothing and writes nothing at all.
      if (unioned.length == existing.sources.length) {
        return WikiPageWrite(file: file, outcome: WikiPageOutcome.unchanged);
      }
      final unchanged = _frontmatter(
        provenance: existing.provenance,
        sources: unioned,
        confidence: existing.confidence,
        lastUpdated: existing.lastUpdated,
        lastUpdatedBy: existing.lastUpdatedBy,
        preserved: existing.preserved,
      );
      await core.secureWriteFile(file, '$unchanged${existing.content}', restrictPermissions: false);
      return WikiPageWrite(file: file, outcome: WikiPageOutcome.unchanged);
    }
    final String content;
    if (merge.mode == WikiMergeMode.integrated) {
      final stored = _splitTitle(existing.content);
      // The title heading stays this store's to emit, exactly as on a created
      // page, so an integration can neither drop the page's title nor open a
      // second one below it – a merged body that opens with its own `# ` line
      // loses it here rather than becoming the page's second title.
      final merged = _splitTitle(body.trim()).body.trim();
      // Measured on exactly the text that lands on the page, against exactly the
      // text the merge turn was shown: comparing the raw reply instead would let
      // a short body clear the floor on trailing whitespace alone.
      _refuseShrink(file, stored: stored.body.trim(), merged: merged, declaredRemoval: merge.removedContent.isNotEmpty);
      content = '${stored.title ?? '# $title'}\n\n$merged\n';
    } else {
      content = '${existing.content.trimRight()}\n\n${_supplementHeading(sources, now)}\n\n$body\n';
    }
    final frontmatter = _frontmatter(
      provenance: _mergedProvenance(existing, provenance),
      sources: unioned,
      confidence: _weakerConfidence(existing.confidence, safeConfidence),
      lastUpdated: now.toUtc().toIso8601String(),
      lastUpdatedBy: lastUpdatedBy,
      preserved: existing.preserved,
    );
    await core.secureWriteFile(file, '$frontmatter$content', restrictPermissions: false);
    return WikiPageWrite(
      file: file,
      outcome: merge.mode == WikiMergeMode.integrated ? WikiPageOutcome.integrated : WikiPageOutcome.supplemented,
    );
  }

  /// The body a merge turn is shown for [slug] – the stored page below its `# `
  /// title heading – or `null` when no page is stored there.
  ///
  /// Throws [WikiPageUnreadable] when a page is stored but cannot be read, so a
  /// collision on a page nothing can account for is refused before a turn is
  /// spent on it.
  String? storedBody(String slug) {
    final stored = _readPage(pageFile(slug));
    return stored == null ? null : _splitTitle(stored.content).body;
  }

  /// Splits stored page [text] per [core.splitFrontmatter].
  static ({String? frontmatter, String body})? splitFrontmatter(String text) => core.splitFrontmatter(text);

  /// Parses a frontmatter block into its key/value map, or `null` when it is not
  /// YAML or does not parse as a mapping.
  static Map<String, Object?>? parseFrontmatter(String frontmatter) {
    final Object? parsed;
    try {
      parsed = loadYaml(frontmatter.replaceAll('\r\n', '\n'));
    } on YamlException {
      return null;
    }
    if (parsed is! Map) return null;
    return {for (final entry in parsed.entries) '${entry.key}': entry.value};
  }

  /// Reads a frontmatter `sources` value, accepting the block, flow, and single
  /// scalar shapes a hand-edited or foreign-tool-written page can carry.
  static List<String> frontmatterSources(Object? value) {
    if (value is String) return value.trim().isEmpty ? const [] : [value.trim()];
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item != null && '$item'.trim().isNotEmpty) '$item'.trim(),
    ];
  }

  /// The source list each supplement heading in [content] names, one entry per
  /// heading, exactly as written.
  ///
  /// A heading is the operator's cue that the section below it came from the
  /// named source, and model-authored body text can forge one, so a caller must
  /// treat these as claims to check rather than as recorded provenance. A source
  /// name can itself contain `, `, so an entry is never split here.
  static List<String> citedSupplementSources(String content) => [
    for (final line in const LineSplitter().convert(content)) ?_supplementLine.firstMatch(line)?.group(1),
  ];

  /// Whether [provenance] is a value this store authors and the search layer
  /// ranks, as opposed to one it must preserve without interpreting.
  static bool isKnownProvenance(String? provenance) => knownWikiProvenance.contains(provenance);

  /// Reads the page stored at [file] as its frontmatter plus the body below it,
  /// or `null` when no page is stored.
  ///
  /// A page with no frontmatter (hand-authored) reports no sources and no
  /// provenance and keeps its whole text as content, so a machine write can
  /// neither silently replace it nor claim sole authorship of it. A page that
  /// opens a frontmatter block this store cannot parse is refused rather than
  /// reinterpreted as body text, because reinterpreting it is what destroys it.
  static _StoredWikiPage? _readPage(File file) {
    if (!file.existsSync()) return null;
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException catch (error) {
      throw WikiPageUnreadable(path: 'wiki/${p.basename(file.path)}', reason: error.osError?.message ?? error.message);
    }
    final split = splitFrontmatter(text);
    if (split == null) return _StoredWikiPage(sources: const [], content: text);
    if (split.frontmatter == null) {
      throw WikiPageUnreadable(path: 'wiki/${p.basename(file.path)}', reason: 'unterminated YAML frontmatter');
    }
    final parsed = parseFrontmatter(split.frontmatter!);
    if (parsed == null) {
      throw WikiPageUnreadable(path: 'wiki/${p.basename(file.path)}', reason: 'unparseable YAML frontmatter');
    }
    return _StoredWikiPage(
      sources: frontmatterSources(parsed['sources']),
      content: split.body,
      hasFrontmatter: true,
      provenance: _storedScalar(parsed['provenance']),
      confidence: _storedScalar(parsed['confidence']),
      lastUpdated: _storedScalar(parsed['last_updated']),
      lastUpdatedBy: _storedScalar(parsed['last_updated_by']),
      preserved: parsed,
    );
  }

  /// A stored frontmatter scalar, or `null` when the key is absent, null, or
  /// blank – all of which mean the page records no value, not an empty one.
  static String? _storedScalar(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// The provenance to record, or `null` to record none at all.
  ///
  /// Only a page that carried no frontmatter is classified from scratch: it is
  /// hand-authored by construction, and the machine supplement makes it
  /// `hybrid`. A page that has frontmatter but records no provenance is one this
  /// store cannot classify, so it records none either – writing a value would
  /// move a page nothing can account for into the search-trusted tier, and the
  /// lint pass reports the missing key so an operator can settle it.
  static String? _mergedProvenance(_StoredWikiPage existing, String incoming) {
    final stored = existing.provenance;
    if (stored == null) return existing.hasFrontmatter ? null : 'hybrid';
    if (stored == incoming) return stored;
    // Two authorships this store understands mix into `hybrid`. A value it does
    // not understand keeps exactly what it came with: relabelling it would move
    // a page the store cannot classify into the search-trusted tier.
    return isKnownProvenance(stored) ? 'hybrid' : stored;
  }

  /// The weaker of [stored] and [incoming], with a stored value outside
  /// [confidenceLevels] written back untouched – the same rule as provenance:
  /// replacing a value this store cannot rank is how a hand-authored note gets
  /// silently destroyed, and lint already reports it as invalid.
  static String _weakerConfidence(String? stored, String incoming) {
    if (stored == null) return incoming;
    final storedRank = confidenceLevels.indexOf(stored);
    if (storedRank < 0) return stored;
    return storedRank >= confidenceLevels.indexOf(incoming) ? incoming : stored;
  }

  static List<String> _unionSources(List<String> stored, List<String> incoming) => [
    ...stored,
    ...incoming.where((source) => !stored.contains(source)),
  ];

  /// Splits stored page [content] into its leading `# ` title line and the body
  /// below it, with a `null` title for a page that opens with none.
  static ({String? title, String body}) _splitTitle(String content) {
    if (!content.startsWith('# ')) return (title: null, body: content);
    final lineEnd = content.indexOf('\n');
    if (lineEnd < 0) return (title: content.trimRight(), body: '');
    return (title: content.substring(0, lineEnd).trimRight(), body: content.substring(lineEnd + 1).trimLeft());
  }

  /// Refuses an integration that leaves the page materially shorter than the
  /// [stored] body it was shown while declaring no removal.
  static void _refuseShrink(
    File file, {
    required String stored,
    required String merged,
    required bool declaredRemoval,
  }) {
    if (declaredRemoval) return;
    final storedBytes = utf8.encode(stored).length;
    final requiredBytes = (storedBytes * mergeShrinkFloor).ceil();
    final mergedBytes = utf8.encode(merged).length;
    if (mergedBytes >= requiredBytes) return;
    throw WikiPageMergeRefused(
      path: 'wiki/${p.basename(file.path)}',
      storedBytes: storedBytes,
      mergedBytes: mergedBytes,
      requiredBytes: requiredBytes,
    );
  }

  static String _supplementHeading(List<String> sources, DateTime now) {
    final day = now.toUtc().toIso8601String().split('T').first;
    return sources.isEmpty ? '## Supplement ($day)' : '## Supplement from ${sources.join(", ")} ($day)';
  }

  /// Emits the frontmatter block. A `null` [provenance], [confidence],
  /// [lastUpdated], or [lastUpdatedBy] omits that key rather than inventing a
  /// value, which is how a page this store cannot classify stays unclassified.
  static String _frontmatter({
    required String? provenance,
    required List<String> sources,
    required String? confidence,
    required String? lastUpdated,
    required String? lastUpdatedBy,
    Map<String, Object?> preserved = const {},
  }) {
    final extras = <String, Object?>{'contradicts': const [], 'related': const [], ...preserved}
      ..removeWhere((key, value) => _writerOwnedKeys.contains(key));
    return [
      '---',
      if (provenance != null) 'provenance: ${_yamlScalar(provenance)}',
      'sources:',
      ...sources.map((source) => '  - ${_yamlString(source)}'),
      if (confidence != null) 'confidence: ${_yamlScalar(confidence)}',
      if (lastUpdated != null) 'last_updated: ${_yamlScalar(lastUpdated)}',
      if (lastUpdatedBy != null) 'last_updated_by: ${_yamlString(lastUpdatedBy)}',
      for (final entry in extras.entries) '${_yamlScalar(entry.key)}: ${_yamlLiteral(entry.value)}',
      '---',
      '',
    ].join('\n');
  }

  static String _yamlString(String value) => jsonEncode(value);

  /// YAML core-schema words that resolve to something other than a string, so a
  /// stored value spelled this way must be quoted or it changes type on re-read.
  static const _yamlKeywords = {'null', 'Null', 'NULL', '~', 'true', 'True', 'TRUE', 'false', 'False', 'FALSE'};

  /// Emits [value] as a plain scalar only when that is unambiguous, and as a
  /// quoted string otherwise.
  ///
  /// A stored value this store preserves rather than interprets can hold
  /// anything. Emitted raw, a newline splits the block, a trailing `:` makes it
  /// unparseable, and a value that looks like a number, a bool, or null comes
  /// back as a different type. The plain form is therefore restricted to a
  /// letter-led bare word, which no core-schema rule reinterprets.
  static String _yamlScalar(String value) =>
      RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$').hasMatch(value) && !_yamlKeywords.contains(value)
      ? value
      : _yamlString(value);

  /// Re-emits a preserved frontmatter value. JSON is a YAML subset, so encoding
  /// round-trips lists, maps, and scalars without a second serializer.
  static String _yamlLiteral(Object? value) => jsonEncode(_plainYaml(value));

  static Object? _plainYaml(Object? value) {
    if (value is Map) return {for (final entry in value.entries) '${entry.key}': _plainYaml(entry.value)};
    if (value is List) return [for (final item in value) _plainYaml(item)];
    if (value is String || value is num || value is bool || value == null) return value;
    return '$value';
  }

  /// Reduces [input] to the `[a-z0-9-]` slug its page is stored under.
  static String pageSlug(String input) {
    final slug = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'untitled' : slug;
  }

  /// Returns the canonical form of [input].
  ///
  /// Throws [ArgumentError] when it is not one of `high`, `medium`, or `low`, so
  /// a model-controlled value can be rejected before any durable write.
  static String confidenceOrThrow(String input) {
    final value = input.trim().toLowerCase();
    if (!confidenceLevels.contains(value)) {
      throw ArgumentError('confidence must be high, medium, or low');
    }
    return value;
  }
}
