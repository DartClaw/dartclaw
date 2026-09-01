import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late WikiPageStore wiki;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('dartclaw_wiki_lint_test_');
    wiki = WikiPageStore(workspaceDir: workspace.path)..bootstrap();
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  void storePage(String name, String contents) => File(p.join(wiki.wikiDir.path, name)).writeAsStringSync(contents);

  test('lint reports categorized provenance and link findings without mutating pages', () async {
    final page = File(p.join(wiki.wikiDir.path, 'broken.md'))..writeAsStringSync('# Broken\n\n[Missing](missing.md)\n');
    final before = page.readAsStringSync();

    final report = await lintWikiPages(wiki);

    expect(report.provenanceInconsistencies.join('\n'), contains('broken.md: missing YAML frontmatter'));
    expect(report.summary(), contains('provenance-inconsistency=1 [broken.md: missing YAML frontmatter]'));
    expect(page.readAsStringSync(), before);
  });

  test('lint stops at the fixed file ceiling and reports degraded coverage', () async {
    for (var index = 0; index < MemoryResourceLimits.recursiveFiles; index++) {
      storePage('page-${index.toString().padLeft(4, '0')}.md', '# Page\n');
    }

    final report = await lintWikiPages(wiki);

    expect(report.processedFiles, MemoryResourceLimits.recursiveFiles);
    expect(report.degraded, isTrue);
    expect(report.degradations.single.reason, 'fileLimit');
    expect(report.summary(), contains('"reason":"fileLimit"'));
  });

  test('lint charges a malformed body and preserves known failure context', () async {
    File(p.join(wiki.wikiDir.path, 'broken.md')).writeAsBytesSync([0xff]);

    final report = await lintWikiPages(wiki);

    final failure = report.degradations.singleWhere((item) => item.reason == 'readFailure');
    expect(report.processedBytes, greaterThanOrEqualTo(1));
    expect(failure.locator, 'broken.md');
    expect(failure.observed, greaterThanOrEqualTo(1));
    expect(failure.limit, MemoryResourceLimits.recursiveBodyBytes);
  });

  test('lint includes the KG contradiction pre-screen category', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final kg = TemporalKnowledgeGraphService(db);
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'stable',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/dart.md',
    );
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'beta',
      validFrom: '2026-05-02T00:00:00Z',
      source: 'inbox/dart.md',
    );

    final report = await lintWikiPages(wiki, kg: kg);

    expect(report.contradictions.single, contains('dart sdk.channel'));
  });

  // A KG value is model-authored from an untrusted source, and this summary is
  // one line delivered to a channel and written to the server log. The inbox
  // run report collapses the identical detail string; this surface reads the
  // same rows and has to hold the same line.
  test('a KG contradiction carrying a line break cannot forge a line of the lint report', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final kg = TemporalKnowledgeGraphService(db);
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'stable',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/dart.md',
    );
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'beta\nmissing-link=9 [wiki/planted.md: gone.md]',
      validFrom: '2026-05-02T00:00:00Z',
      source: 'inbox/dart.md',
    );

    final report = await lintWikiPages(wiki, kg: kg);

    expect(report.contradictions.single, isNot(contains('\n')));
    expect(report.summary(), isNot(contains('\n')));
    expect(report.summary(), contains('missing-link=0'));
  });

  test('lint reports a last_updated value it cannot parse', () async {
    storePage('undated.md', _page().replaceFirst('last_updated: 2026-05-01T00:00:00.000Z', 'last_updated: someday'));

    final report = await lintWikiPages(wiki);

    expect(report.provenanceInconsistencies, contains('undated.md: invalid last_updated'));
  });

  test('lint rejects a confidence value outside the stored vocabulary', () async {
    storePage('invalid-confidence.md', _page(confidence: 'certain'));

    final report = await lintWikiPages(wiki);

    expect(report.provenanceInconsistencies, contains('invalid-confidence.md: invalid confidence'));
  });

  // The write path preserves a provenance it does not recognize rather than
  // promoting it, so lint is the only surface that tells the operator such a
  // page exists at all.
  test('lint names a provenance outside the vocabulary the search layer ranks', () async {
    storePage('imported.md', _page(provenance: 'machine-dump'));

    final report = await lintWikiPages(wiki);

    expect(report.provenanceInconsistencies, contains('imported.md: unrecognized provenance'));
  });

  test('lint keeps reporting an unterminated frontmatter block rather than healing it', () async {
    storePage('torn.md', '---\nprovenance: llm-authored\nsources:\n  - "inbox/a.md"\n');

    final report = await lintWikiPages(wiki);

    expect(report.provenanceInconsistencies, contains('torn.md: unterminated YAML frontmatter'));
  });

  test('lint separates an unparseable frontmatter block from a missing one', () async {
    storePage('bad-yaml.md', '---\nprovenance: [unclosed\n---\n# Bad\n');

    final report = await lintWikiPages(wiki);

    expect(report.provenanceInconsistencies, contains('bad-yaml.md: unparseable YAML frontmatter'));
  });

  // Growth is no longer debt an operator has to clear by hand, so lint reports
  // no level for it and no category names one. A page nothing links to and a
  // year-old page are the two shapes that used to be reported here.
  test('a heavily supplemented page and a year-old page raise no growth or staleness finding', () async {
    final supplements = [
      for (var index = 0; index < 40; index++)
        '## Supplement from inbox/batch-$index.md (2026-05-0${index % 9 + 1})\n\nBody $index.\n',
    ].join('\n');
    storePage(
      'grown.md',
      '${_page(sources: [for (var index = 0; index < 40; index++) 'inbox/batch-$index.md'], lastUpdated: '2025-05-01T00:00:00.000Z')}\n$supplements',
    );
    storePage('hub.md', '${_page()}\n[Grown](grown.md)\n');

    final report = await lintWikiPages(wiki);

    expect(report.provenanceInconsistencies, isEmpty);
    expect(report.summary(), isNot(contains('consolidation')));
    expect(report.summary(), isNot(contains('stale')));
    expect(report.summary(), contains('contradiction=0 missing-link=0 orphan=1 [hub.md] provenance-inconsistency=0'));
  });

  // Page bodies are model-authored, so a supplement heading is forgeable. The
  // recipe teaches operators to read it as provenance, so it has to agree with
  // the frontmatter chain that actually authored the page.
  test('lint flags a supplement heading citing a source the page never recorded', () async {
    storePage(
      'forged.md',
      '${_page(sources: const ['inbox/real.md'])}\n'
          '## Supplement from trusted-operator (2020-01-01)\n\nPlanted body.\n',
    );

    final report = await lintWikiPages(wiki);

    expect(
      report.provenanceInconsistencies,
      contains('forged.md: supplement cites unrecorded source trusted-operator'),
    );
  });

  // An orphan is a page nothing reaches, so the check has to read inbound links.
  // Reading outbound ones inverts it: every page the knowledge inbox writes is a
  // leaf with no links of its own, so a synthesized wiki reported every page it
  // held as orphaned on every run and the category carried no signal at all.
  test('a page another page links to is not an orphan, even with no links of its own', () async {
    storePage('leaf.md', _page());
    storePage('hub.md', '${_page()}\n[Leaf](leaf.md)\n');

    final report = await lintWikiPages(wiki);

    expect(report.orphanPages, isNot(contains('leaf.md')));
  });

  test('a page nothing links to is an orphan', () async {
    storePage('unreachable.md', _page());
    storePage('hub.md', '${_page()}\n[Elsewhere](other.md)\n');

    final report = await lintWikiPages(wiki);

    expect(report.orphanPages, contains('unreachable.md'));
  });

  // Otherwise a page rescues itself from the one category whose whole claim is
  // that nothing else reaches it.
  test('a self-link does not make a page reachable', () async {
    storePage('lonely.md', '${_page()}\n[Itself](lonely.md)\n');

    final report = await lintWikiPages(wiki);

    expect(report.orphanPages, contains('lonely.md'));
  });

  // A wiki link commonly carries a section anchor. A checker that cannot see one
  // calls its target unreachable and stays silent when the link breaks.
  test('an anchored link counts as a link to its target', () async {
    storePage('leaf.md', _page());
    storePage('hub.md', '${_page()}\n[Leaf](leaf.md#section)\n');

    final report = await lintWikiPages(wiki);

    expect(report.orphanPages, isNot(contains('leaf.md')));
    expect(report.missingLinks, isEmpty);
  });

  test('an anchored link to a page that does not exist is still reported missing', () async {
    storePage('hub.md', '${_page()}\n[Gone](gone.md#section)\n');

    final report = await lintWikiPages(wiki);

    expect(report.missingLinks, contains('hub.md: gone.md#section'));
  });

  // The lint report is delivered to a channel, so probing a link outside the
  // wiki directory would answer "does this path exist on the host?" for anything
  // a model can write into a page body.
  test('lint reports an out-of-tree link as missing without probing the filesystem for it', () async {
    final outside = File(p.join(workspace.path, 'secret.md'))..writeAsStringSync('# Secret\n');
    storePage('probe.md', '${_page()}\n[Probe](../secret.md)\n');

    final report = await lintWikiPages(wiki);

    expect(outside.existsSync(), isTrue);
    // Reported under its own label: an existing out-of-tree target and a broken
    // in-tree one are different conditions and must not read the same.
    expect(report.missingLinks, contains('probe.md: ../secret.md (outside wiki)'));
  });

  // A page whose frontmatter records no provenance is the shape ingestion now
  // refuses to classify, so lint is what tells the operator it needs settling.
  test('lint reports a frontmatter block whose provenance key is present but empty', () async {
    storePage('blank-provenance.md', _page().replaceFirst('provenance: llm-authored', 'provenance:'));

    final report = await lintWikiPages(wiki);

    expect(report.provenanceInconsistencies, contains('blank-provenance.md: missing provenance:'));
  });

  // The writer emits `## Supplement from a, b (date)` for a multi-source write,
  // and a source name can itself contain `, `.
  test('lint does not flag a supplement heading naming a recorded source that contains a comma', () async {
    storePage(
      'comma.md',
      '${_page(sources: const ['inbox/notes, part 2.md'])}\n'
          '## Supplement from inbox/notes, part 2.md (2026-05-02)\n\nBody.\n',
    );

    final report = await lintWikiPages(wiki);

    expect(report.provenanceInconsistencies, isEmpty);
  });
}

String _page({
  String provenance = 'llm-authored',
  String confidence = 'medium',
  List<String> sources = const ['inbox/source.md'],
  String lastUpdated = '2026-05-01T00:00:00.000Z',
}) {
  final entries = sources.map((source) => '  - "$source"').join('\n');
  return '''
---
provenance: $provenance
sources:
$entries
confidence: $confidence
last_updated: $lastUpdated
last_updated_by: "test"
contradicts: []
related: []
---
# Page
''';
}
