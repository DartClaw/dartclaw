import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' as core;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;

import 'wiki_page_store.dart';

/// Reports structural and provenance findings across the pages [store] holds,
/// reading every page through the stored-page format [WikiPageStore] owns.
///
/// Every category here is a structural claim the pass can check for itself: a
/// link that does not resolve, a page nothing reaches, frontmatter that does not
/// parse or does not agree with the page below it, and open knowledge-graph
/// contradictions. A page this pass cannot parse is reported, never rewritten –
/// the write path refuses the same shapes, so a lint finding and an ingestion
/// refusal always name the same pages.
Future<WikiLintReport> lintWikiPages(WikiPageStore store, {TemporalKnowledgeGraphService? kg}) async {
  store.bootstrap();
  final missingLinks = <String>[];
  final orphanPages = <String>[];
  final provenanceInconsistencies = <String>[];
  var processedFiles = 0;
  var processedBytes = 0;
  var degraded = false;
  final degradations = <MemorySearchDegradation>[];
  final contradictions =
      kg
          ?.openContradictions()
          // Built from model-chosen predicate and value strings, and this
          // summary is one line reaching a channel and the server log, so an
          // unstripped line break forges a report line of its own.
          .map(
            (item) => normalizeWhitespace(
              '${item.existing.entity}.${item.existing.predicate}: ${item.existing.value} <> ${item.incomingValue}',
            ),
          )
          .toList() ??
      <String>[];

  final scannedPages = <String>[];
  final linkedPages = <String>{};
  final wikiRoot = p.normalize(store.wikiDir.absolute.path);
  final fileScan = await core.MemoryFileService.listRegularFilesBounded(store.wikiDir);
  var remainingFiles = fileScan.files.length;
  for (final file in fileScan.files) {
    remainingFiles--;
    final name = p.relative(file.path, from: store.wikiDir.path);
    processedFiles++;
    if (!file.path.endsWith('.md')) continue;
    final size = file.statSync().size;
    final remainingBytes = core.MemoryResourceLimits.recursiveBodyBytes - processedBytes;
    if (size > core.MemoryResourceLimits.sourceBytes || size > remainingBytes) {
      degraded = true;
      degradations.add(
        MemorySearchDegradation(
          layer: 'wiki',
          reason: size > core.MemoryResourceLimits.sourceBytes ? 'sourceBytes' : 'bodyBytes',
          locator: name,
          observed: size > core.MemoryResourceLimits.sourceBytes ? size : processedBytes + size,
          limit: size > core.MemoryResourceLimits.sourceBytes
              ? core.MemoryResourceLimits.sourceBytes
              : core.MemoryResourceLimits.recursiveBodyBytes,
          omittedCount: size > remainingBytes ? remainingFiles + 1 : 1,
        ),
      );
      if (size > remainingBytes) break;
      continue;
    }
    processedBytes += size;
    String text;
    try {
      text = core.MemoryFileService.readRegularFile(
        file,
        maxBytes: remainingBytes < core.MemoryResourceLimits.sourceBytes
            ? remainingBytes
            : core.MemoryResourceLimits.sourceBytes,
        role: core.MemoryRole.wiki,
      )!;
    } on Object {
      degraded = true;
      degradations.add(
        MemorySearchDegradation(
          layer: 'wiki',
          reason: 'readFailure',
          locator: name,
          observed: processedBytes,
          limit: core.MemoryResourceLimits.recursiveBodyBytes,
          omittedCount: 1,
        ),
      );
      continue;
    }
    scannedPages.add(name);
    final split = WikiPageStore.splitFrontmatter(text);
    for (final match in _linkPattern.allMatches(text)) {
      // The link as written, so the report names what the page actually says;
      // the path alone is what resolves, so an anchor never reaches the disk.
      final link = match.group(1)!;
      // Body text is model-authored, so a link is only probed inside the wiki
      // directory: an out-of-tree target must not turn this report, which is
      // delivered to a channel, into a filesystem existence oracle.
      final target = p.normalize(p.join(p.dirname(file.absolute.path), match.group(2)!));
      if (!p.isWithin(wikiRoot, target)) {
        missingLinks.add('$name: $link (outside wiki)');
        continue;
      }
      if (!File(target).existsSync()) missingLinks.add('$name: $link');
      // A page cannot make itself reachable, which is the whole claim the
      // orphan category makes about the pages it names.
      final targetName = p.relative(target, from: wikiRoot);
      if (targetName != name) linkedPages.add(targetName);
    }
    provenanceInconsistencies.addAll(_frontmatterFindings(name, split));
  }
  // An orphan is a page nothing reaches. Only pages this bounded scan actually
  // read can be judged, so a page omitted by the file ceiling is never named.
  orphanPages.addAll(scannedPages.where((page) => page != 'README.md' && !linkedPages.contains(page)));
  if (!fileScan.complete || fileScan.omittedCount > 0) {
    degraded = true;
    degradations.add(
      MemorySearchDegradation(
        layer: 'wiki',
        reason: fileScan.complete ? 'fileLimit' : 'traversalLimit',
        locator: fileScan.firstOmitted == null
            ? null
            : p.relative(fileScan.firstOmitted!.path, from: store.wikiDir.path),
        observed: fileScan.complete ? fileScan.files.length + fileScan.omittedCount : null,
        limit: fileScan.complete ? core.MemoryResourceLimits.recursiveFiles : null,
        omittedCount: fileScan.omittedCount,
      ),
    );
  }

  return WikiLintReport(
    contradictions: contradictions,
    missingLinks: missingLinks,
    orphanPages: orphanPages,
    provenanceInconsistencies: provenanceInconsistencies,
    degraded: degraded,
    processedFiles: processedFiles,
    processedBytes: processedBytes,
    degradations: degradations,
  );
}

/// Internal `.md` links: group 1 is the link as written, group 2 the path
/// without any `#fragment` or `?query`.
///
/// A link a wiki author writes commonly carries a section anchor, and a pattern
/// that cannot see one both calls its target unreachable and stays silent when
/// the link breaks.
final _linkPattern = RegExp(r'\]\((([^)#?]+\.md)(?:[#?][^)]*)?)\)');

/// Provenance findings for one page.
List<String> _frontmatterFindings(String name, ({String? frontmatter, String body})? split) {
  if (split == null) return ['$name: missing YAML frontmatter'];
  if (split.frontmatter == null) return ['$name: unterminated YAML frontmatter'];
  final frontmatter = WikiPageStore.parseFrontmatter(split.frontmatter!);
  if (frontmatter == null) return ['$name: unparseable YAML frontmatter'];

  final findings = <String>[
    for (final key in ['provenance', 'sources', 'confidence', 'last_updated', 'last_updated_by'])
      if (!frontmatter.containsKey(key)) '$name: missing $key:',
  ];
  final provenance = frontmatter['provenance']?.toString().trim();
  if (frontmatter.containsKey('provenance') && (provenance == null || provenance.isEmpty)) {
    findings.add('$name: missing provenance:');
  } else if (provenance != null && !WikiPageStore.isKnownProvenance(provenance)) {
    findings.add('$name: unrecognized provenance');
  }
  final confidence = frontmatter['confidence']?.toString();
  if (confidence != null && !WikiPageStore.confidenceLevels.contains(confidence)) {
    findings.add('$name: invalid confidence');
  }
  final lastUpdated = frontmatter['last_updated']?.toString();
  if (lastUpdated != null && DateTime.tryParse(lastUpdated) == null) {
    findings.add('$name: invalid last_updated');
  }
  final sources = WikiPageStore.frontmatterSources(frontmatter['sources']);
  if (sources.isEmpty && frontmatter.containsKey('sources')) findings.add('$name: sources is empty');
  for (final cited in WikiPageStore.citedSupplementSources(split.body)) {
    // A heading names either one recorded source or the `, `-joined list a
    // multi-source write emitted, and a source name can itself contain `, `.
    if (sources.contains(cited) || cited.split(', ').every(sources.contains)) continue;
    findings.add('$name: supplement cites unrecorded source $cited');
  }
  return findings;
}

class WikiLintReport {
  final List<String> contradictions;
  final List<String> missingLinks;
  final List<String> orphanPages;
  final List<String> provenanceInconsistencies;
  final bool degraded;
  final int processedFiles;
  final int processedBytes;
  final List<MemorySearchDegradation> degradations;

  const new({
    required this.contradictions,
    required this.missingLinks,
    required this.orphanPages,
    required this.provenanceInconsistencies,
    this.degraded = false,
    this.processedFiles = 0,
    this.processedBytes = 0,
    this.degradations = const [],
  });

  bool get hasFindings =>
      degraded ||
      contradictions.isNotEmpty ||
      missingLinks.isNotEmpty ||
      orphanPages.isNotEmpty ||
      provenanceInconsistencies.isNotEmpty;

  String summary() {
    final parts = [
      _summaryPart('contradiction', contradictions),
      _summaryPart('missing-link', missingLinks),
      _summaryPart('orphan', orphanPages),
      _summaryPart('provenance-inconsistency', provenanceInconsistencies),
      if (degraded)
        'coverage=degraded files=$processedFiles bytes=$processedBytes '
            'details=${jsonEncode(degradations.map((item) => item.toJson()).toList())}',
    ];
    return parts.join(' ');
  }

  static String _summaryPart(String label, List<String> items) {
    if (items.isEmpty) return '$label=0';
    return '$label=${items.length} [${items.join("; ")}]';
  }
}
