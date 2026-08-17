@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_server/src/knowledge/knowledge_hub_service.dart';
import 'package:dartclaw_server/src/knowledge/knowledge_inbox_service.dart';
import 'package:dartclaw_server/src/knowledge/wiki_lint.dart';
import 'package:dartclaw_server/src/knowledge/wiki_page_store.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Knowledge-hub integration over one seeded corpus.
///
/// The per-layer unit tests use one-line fixtures, which cannot show what a wiki
/// that has been *lived in* does to the hub: pages carrying frontmatter and
/// provenance, a page grown by repeated ingestion into supplement sections, a
/// hand-authored note with no frontmatter, and a page imported from another tool.
/// Those shapes are what the search, hub, and lint layers disagree about, so this
/// walks one corpus through all three rather than mocking between them.
///
/// The wiki is seeded through `WikiPageStore.writePage` where the pipeline would
/// author it, and through raw literals where a human or a foreign tool would —
/// a fixture the writer built can never exercise the reader's tolerance for
/// shapes the writer cannot emit.
void main() {
  late Directory workspace;
  late Database searchDb;
  late Database taskDb;
  late MemoryService memory;
  late TemporalKnowledgeGraphService kg;
  late WikiPageStore wiki;

  /// A body long enough that a hub snippet cannot show the whole page, so the
  /// snippet has to choose what the reader sees.
  ///
  /// The marker is repeated at both ends because the snippet windows anchor on
  /// the first and last match: a marker only at the start is unreachable from
  /// the tail window, and the assertions would then pass or fail on where the
  /// filler happens to fall rather than on which section the reader can see.
  String section(String marker) =>
      'Kestrel $marker begins. '
      '${List.filled(24, 'operational detail about the Kestrel service').join(' ')} '
      'Kestrel $marker ends.';

  setUp(() async {
    workspace = Directory.systemTemp.createTempSync('knowledge_hub_corpus_');
    searchDb = sqlite3.openInMemory();
    taskDb = sqlite3.openInMemory();
    memory = MemoryService(searchDb);
    kg = TemporalKnowledgeGraphService(taskDb);
    wiki = WikiPageStore(workspaceDir: workspace.path)..bootstrap();

    // A page the pipeline authored, linking onward to the runbook.
    await wiki.writePage(
      slug: 'kestrel-overview',
      title: 'Kestrel Overview',
      body: '${section('overview')}\n\nSee the [runbook](kestrel-runbook.md).',
      sources: const ['inbox/kestrel-brief.md'],
      lastUpdatedBy: 'cron:knowledge-inbox',
      now: DateTime.utc(2026, 8, 1),
    );

    // A page grown by four ingestions: the shape the inbox actually produces
    // over time, and the one a single-window snippet reports wrongly.
    await wiki.writePage(
      slug: 'kestrel-runbook',
      title: 'Kestrel Runbook',
      body: section('runbook first synthesis'),
      sources: const ['inbox/kestrel-batch-1.md'],
      lastUpdatedBy: 'cron:knowledge-inbox',
      now: DateTime.utc(2026, 8, 2),
    );
    for (var batch = 2; batch <= 4; batch++) {
      await wiki.writePage(
        slug: 'kestrel-runbook',
        title: 'Kestrel Runbook',
        body: section('runbook supplement $batch'),
        sources: ['inbox/kestrel-batch-$batch.md'],
        lastUpdatedBy: 'cron:knowledge-inbox',
        now: DateTime.utc(2026, 8, 2 + batch),
      );
    }

    // A hand-authored note: no frontmatter at all, which is what a personal
    // wiki is full of and what the store must never silently reclassify.
    File('${wiki.wikiDir.path}/kestrel-notes.md').writeAsStringSync('# Kestrel Notes\n\n${section('field notes')}\n');

    // A page imported from another tool: frontmatter this pipeline does not own.
    File('${wiki.wikiDir.path}/kestrel-imported.md').writeAsStringSync(
      '---\ntags:\n  - kestrel\naliases: ["kestrel legacy"]\nprovenance: obsidian-sync\n---\n'
      '# Imported\n\n${section('imported legacy record')}\n',
    );

    // The KG carries a contradiction the operator has to settle.
    kg.addFact(
      entity: 'Kestrel',
      predicate: 'tier',
      value: 'gold',
      validFrom: '2026-08-01T00:00:00Z',
      source: 'wiki/kestrel-overview.md',
    );
    kg.addFact(
      entity: 'Kestrel',
      predicate: 'tier',
      value: 'silver',
      validFrom: '2026-08-05T00:00:00Z',
      source: 'inbox/kestrel-batch-3.md',
    );

    searchDb.execute('INSERT INTO memory_chunks (text, source, category, created_at, locator) VALUES (?, ?, ?, ?, ?)', [
      'Kestrel escalation policy recorded from the on-call handover.',
      'MEMORY.md',
      'operations',
      DateTime.utc(2026, 8, 6).toIso8601String(),
      'MEMORY.md',
    ]);

    _write(workspace, 'inbox/kestrel-brief.md', 'Kestrel brief awaiting ingestion.');
    _write(workspace, 'processed/kestrel-batch-1.md', 'Kestrel batch one, already ingested.');
  });

  tearDown(() {
    searchDb.close();
    taskDb.close();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  KnowledgeHubService hub() => KnowledgeHubService(
    wiki: WikiSearchSource(workspaceDir: workspace.path),
    kg: kg,
    memory: memory,
    searchBackend: ComposedSearchBackend(
      personal: Fts5SearchBackend(memoryService: memory),
      wiki: WikiSearchSource(workspaceDir: workspace.path),
    ),
    inbox: KnowledgeInboxReadService(workspaceDir: workspace.path),
  );

  group('hub search over the seeded corpus', () {
    test('one query reaches every layer the corpus was seeded in', () async {
      final result = await hub().search(const KnowledgeHubQuery(query: 'Kestrel', perPage: 50));

      expect(result.layerCounts[KnowledgeHubLayer.wiki], greaterThan(0));
      expect(result.layerCounts[KnowledgeHubLayer.kg], greaterThan(0));
      expect(result.layerCounts[KnowledgeHubLayer.memory], greaterThan(0));
      expect(result.layerCounts[KnowledgeHubLayer.inbox], greaterThan(0));
      expect(result.failedLayers, isEmpty, reason: 'no layer may fail on a well-formed corpus');
      expect(result.degradedLayers, isEmpty);
    });

    // A page grown by supplements is the inbox's steady state. Anchored only at
    // the first match, the hub shows the oldest section for every query and the
    // knowledge added since is unreachable from search.
    test('a grown page surfaces its newest supplement, not only its oldest section', () async {
      final result = await hub().search(
        const KnowledgeHubQuery(query: 'Kestrel', layer: KnowledgeHubLayer.wiki, perPage: 50),
      );

      final runbook = result.items.firstWhere((item) => item.sourceLabel.endsWith('kestrel-runbook.md'));
      expect(runbook.snippet, contains('runbook first synthesis begins'), reason: 'the oldest section stays visible');
      expect(runbook.snippet, contains('runbook supplement 4 ends'), reason: 'the newest supplement must be reachable');
    });

    test('layer scoping returns only that layer', () async {
      final kgOnly = await hub().search(
        const KnowledgeHubQuery(query: 'Kestrel', layer: KnowledgeHubLayer.kg, perPage: 50),
      );

      expect(kgOnly.items, isNotEmpty);
      expect(kgOnly.items.every((item) => item.layer == KnowledgeHubLayer.kg), isTrue);
      expect(kgOnly.items.map((item) => item.snippet), contains(contains('tier')));
    });

    // The hub renders these as links, so a wrong route is a dead end in the UI
    // that no layer-level test can see.
    test('every item carries a resolvable route for its layer', () async {
      final result = await hub().search(const KnowledgeHubQuery(query: 'Kestrel', perPage: 50));

      for (final item in result.items) {
        final expectedPrefix = switch (item.layer) {
          KnowledgeHubLayer.wiki => '/knowledge/wiki/',
          KnowledgeHubLayer.kg => '/knowledge/timeline#fact-',
          KnowledgeHubLayer.memory => '/memory?source=',
          KnowledgeHubLayer.inbox => '/knowledge?layer=inbox&source=',
          KnowledgeHubLayer.all => fail('items are never tagged with the aggregate layer'),
        };
        expect(item.sourceHref, startsWith(expectedPrefix), reason: '${item.layer.wireName}: ${item.sourceHref}');
      }
    });

    // The writer and the reader have to agree about a page neither authored.
    // Promoting it on write moves it into the tier the reader ranks as trusted,
    // which is the one consequence no single-layer test can observe.
    test('an ingestion onto an imported page neither promotes nor trusts it', () async {
      await wiki.writePage(
        slug: 'kestrel-imported',
        title: 'Imported',
        body: section('supplement onto imported'),
        sources: const ['inbox/kestrel-batch-5.md'],
        lastUpdatedBy: 'cron:knowledge-inbox',
        now: DateTime.utc(2026, 8, 7),
      );

      final stored = File('${wiki.wikiDir.path}/kestrel-imported.md').readAsStringSync();
      expect(stored, contains('provenance: obsidian-sync'), reason: 'the writer preserves what it cannot classify');
      expect(stored, isNot(contains('hybrid')));

      final ranked = await WikiSearchSource(workspaceDir: workspace.path).searchScan('Kestrel');
      final imported = ranked.results.firstWhere((item) => item.source.endsWith('kestrel-imported.md'));
      expect(imported.category, 'untrusted synthesized knowledge', reason: 'the reader trusts no value it cannot rank');
      expect(imported.score, greaterThan(0), reason: 'an unclassifiable page never outranks the corpus');
    });

    test('an empty query lists the wiki without dropping the hand-authored page', () async {
      final result = await hub().search(const KnowledgeHubQuery(perPage: 50));

      final wikiLabels = result.items
          .where((item) => item.layer == KnowledgeHubLayer.wiki)
          .map((item) => item.sourceLabel)
          .toList();
      expect(wikiLabels, contains(endsWith('kestrel-notes.md')));
      expect(wikiLabels, contains(endsWith('kestrel-imported.md')));
    });
  });

  group('wiki lint over the same corpus', () {
    test('orphans are the pages nothing links to, not the pages that link to nothing', () async {
      final report = await lintWikiPages(wiki, kg: kg, now: DateTime.utc(2026, 8, 10));

      expect(
        report.orphanPages,
        isNot(contains('kestrel-runbook.md')),
        reason: 'the overview links to the runbook, so it is reachable',
      );
      expect(report.orphanPages, contains('kestrel-notes.md'));
    });

    test('a page grown past the threshold is reported as consolidation debt', () async {
      final report = await lintWikiPages(
        wiki,
        kg: kg,
        now: DateTime.utc(2026, 8, 10),
        consolidationAfterSupplements: 3,
      );

      expect(report.consolidationDebt, contains(startsWith('kestrel-runbook.md: 3')));
    });

    test('the KG contradiction the corpus carries is surfaced', () async {
      final report = await lintWikiPages(wiki, kg: kg, now: DateTime.utc(2026, 8, 10));

      expect(report.contradictions.single, contains('kestrel.tier'));
      expect(report.contradictions.single, contains('gold'));
      expect(report.contradictions.single, contains('silver'));
    });

    test('pages this pipeline did not author are named rather than rewritten', () async {
      final before = File('${wiki.wikiDir.path}/kestrel-imported.md').readAsStringSync();

      final report = await lintWikiPages(wiki, kg: kg, now: DateTime.utc(2026, 8, 10));

      expect(report.provenanceInconsistencies, contains('kestrel-imported.md: unrecognized provenance'));
      expect(report.provenanceInconsistencies, contains('kestrel-notes.md: missing YAML frontmatter'));
      expect(
        File('${wiki.wikiDir.path}/kestrel-imported.md').readAsStringSync(),
        before,
        reason: 'lint reports, never rewrites',
      );
    });
  });
}

void _write(Directory root, String relativePath, String body) {
  final file = File('${root.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(body);
}
