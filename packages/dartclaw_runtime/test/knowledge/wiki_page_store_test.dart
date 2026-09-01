import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Every stored-page fixture here is a raw string, never a page this store
/// authored. The parser defects these tests pin all live in shapes `writePage`
/// cannot emit, so a fixture built by calling `writePage` cannot reach them.
void main() {
  late Directory workspace;
  late WikiPageStore wiki;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('dartclaw_wiki_page_store_test_');
    wiki = WikiPageStore(workspaceDir: workspace.path)..bootstrap();
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  File storePage(String slug, String contents) =>
      File(p.join(wiki.wikiDir.path, '$slug.md'))..writeAsStringSync(contents);

  String readPage(String slug) => File(p.join(wiki.wikiDir.path, '$slug.md')).readAsStringSync();

  Future<WikiPageWrite> write(
    String slug, {
    String body = 'Machine supplement body.',
    List<String> sources = const ['inbox/second.md'],
    String lastUpdatedBy = 'cron:knowledge-inbox',
    String confidence = 'medium',
    String provenance = 'llm-authored',
    WikiPageMerge merge = const WikiPageMerge(mode: WikiMergeMode.supplement),
    DateTime? now,
  }) => wiki.writePage(
    slug: slug,
    title: 'Page',
    body: body,
    sources: sources,
    lastUpdatedBy: lastUpdatedBy,
    now: now ?? DateTime.utc(2026, 5, 2),
    confidence: confidence,
    provenance: provenance,
    merge: merge,
  );

  group('a collision keeps what the page already held', () {
    test('a supplement keeps the prior body and unions the prior sources', () async {
      storePage('anti-planner', _page(sources: const ['inbox/first.md'], body: 'Prior synthesis body.'));

      final result = await write('anti-planner', body: 'Supplement synthesis body.');

      expect(result.outcome, WikiPageOutcome.supplemented);
      final page = readPage('anti-planner');
      expect(page, contains('Prior synthesis body.'));
      expect(page, contains('Supplement synthesis body.'));
      expect(page, contains('sources:\n  - "inbox/first.md"\n  - "inbox/second.md"'));
      expect(page, contains('## Supplement from inbox/second.md (2026-05-02)'));
      expect(page, contains(r'last_updated: "2026-05-02T00:00:00.000Z"'));
    });

    // The prior chain has to survive every YAML shape an editor, a formatter, or
    // a foreign tool can leave behind, not only the block style this store emits.
    for (final (label, sources) in const [
      ('flow style', 'sources: ["inbox/first.md", "inbox/other.md"]'),
      ('single-quoted items', "sources:\n  - 'inbox/first.md'\n  - 'inbox/other.md'"),
    ]) {
      test('a $label sources list is read, not replaced', () async {
        storePage('shapes', _rawPage(sources: sources, body: 'Prior synthesis body.'));

        await write('shapes');

        expect(
          readPage('shapes'),
          contains('sources:\n  - "inbox/first.md"\n  - "inbox/other.md"\n  - "inbox/second.md"'),
        );
      });
    }

    test('a single scalar sources value is read as one recorded source', () async {
      storePage('scalar', _rawPage(sources: 'sources: inbox/first.md', body: 'Prior synthesis body.'));

      await write('scalar');

      expect(readPage('scalar'), contains('sources:\n  - "inbox/first.md"\n  - "inbox/second.md"'));
    });

    // A vault recovered from git on Windows arrives with CRLF endings on every
    // page at once, so this fires across the whole wiki rather than on one page.
    test('a CRLF page keeps its frontmatter instead of demoting it into the body', () async {
      storePage(
        'crlf',
        _page(sources: const ['inbox/first.md'], body: 'Prior synthesis body.').replaceAll('\n', '\r\n'),
      );

      await write('crlf');

      final page = readPage('crlf');
      expect(page, contains('sources:\n  - "inbox/first.md"\n  - "inbox/second.md"'));
      expect(page, contains('provenance: llm-authored'));
      expect('---'.allMatches(page), hasLength(2));
      expect(page, contains('Prior synthesis body.'));
    });

    test('frontmatter keys the store does not own survive the merge', () async {
      storePage(
        'curated',
        _rawPage(
          sources: 'sources:\n  - "hand-authored"',
          body: 'Hand-curated knowledge.',
          extra: '''
contradicts:
  - "kg:focus.duration"
related:
  - "attention.md"
  - "flow.md"
tags:
  - focus
aliases: ["deep-work"]''',
        ),
      );

      await write('curated');

      final page = readPage('curated');
      expect(page, contains('contradicts: ["kg:focus.duration"]'));
      expect(page, contains('related: ["attention.md","flow.md"]'));
      expect(page, contains('tags: ["focus"]'));
      expect(page, contains('aliases: ["deep-work"]'));
    });

    test('a merge takes the weaker confidence so a mixed page never claims its strongest part', () async {
      storePage('mixed', _page(confidence: 'high', body: 'Hand-curated knowledge.'));

      await write('mixed', confidence: 'low');

      expect(readPage('mixed'), contains('confidence: low'));
    });

    test('a stronger supplement never raises a page above its weakest part', () async {
      storePage('weak', _page(confidence: 'low', body: 'Hand-curated knowledge.'));

      await write('weak', confidence: 'high');

      expect(readPage('weak'), contains('confidence: low'));
    });

    test('two equally confident writes leave the confidence alone', () async {
      storePage('strong', _page(confidence: 'high', body: 'Hand-curated knowledge.'));

      await write('strong', confidence: 'high');

      expect(readPage('strong'), contains('confidence: high'));
    });

    // Absent means unrated, not weakest: the supplement's confidence is the
    // only assessment the page has, so it is recorded.
    test('a page recording no confidence takes the supplement value', () async {
      storePage(
        'unrated',
        '---\nprovenance: llm-authored\nsources:\n  - "inbox/first.md"\n---\n# Page\n\nPrior synthesis body.\n',
      );

      await write('unrated', confidence: 'high');

      expect(readPage('unrated'), contains('confidence: high'));
    });

    // The weaker-of rule can only rank the vocabulary it knows. A hand-authored
    // value outside it is the operator's note, and replacing it with a machine
    // value is silent destruction of stored content – the same rule provenance
    // already follows, with lint reporting the value as invalid either way.
    test('a hand-authored confidence outside the vocabulary is written back untouched', () async {
      storePage(
        'unsure',
        _rawPage(
          confidence: 'honestly not sure',
          sources: 'sources:\n  - "hand-authored"',
          body: 'Hand-curated knowledge.',
        ),
      );

      await write('unsure', confidence: 'high');

      final page = readPage('unsure');
      expect(page, contains('confidence: "honestly not sure"'));
      expect(page, isNot(contains('confidence: high')));
    });

    test('a supplement names the writer that made the change', () async {
      storePage('authored', _page(body: 'Prior synthesis body.'));

      await write('authored', lastUpdatedBy: 'cron:nightly');

      expect(readPage('authored'), contains('last_updated_by: "cron:nightly"'));
    });

    // The store carries out the settled merge; it never infers one. Guessing is
    // what grew every collided page forever, and a second authority on what a
    // merge means is what this seam exists to remove.
    test('a collision with no settled merge is refused before anything is written', () async {
      final file = storePage('unsettled', _page(body: 'Prior synthesis body.'));
      final before = file.readAsStringSync();

      await expectLater(
        () => wiki.writePage(
          slug: 'unsettled',
          title: 'Page',
          body: 'Machine body.',
          sources: const ['inbox/second.md'],
          lastUpdatedBy: 'cron:knowledge-inbox',
          now: DateTime.utc(2026, 5, 2),
        ),
        throwsArgumentError,
      );
      expect(file.readAsStringSync(), before);
    });
  });

  group('provenance', () {
    // `hybrid` is the value the wiki search source ranks as trusted, so writing
    // it for anything but a page this store can classify launders trust.
    for (final (stored, expected) in const [
      ('human-authored', 'hybrid'),
      ('hybrid', 'hybrid'),
      ('llm-authored', 'llm-authored'),
      ('imported', 'imported'),
      ('machine-dump', 'machine-dump'),
      ('LLM-Authored', 'LLM-Authored'),
    ]) {
      test('a stored $stored page is written back as $expected', () async {
        storePage('provenance', _page(provenance: stored, body: 'Prior synthesis body.'));

        await write('provenance');

        expect(readPage('provenance'), contains('provenance: $expected'));
      });
    }

    test('a page with no frontmatter becomes hybrid and keeps its hand-written body', () async {
      storePage('manual', '# Manual\n\nHand-written knowledge.\n');

      final result = await write('manual');

      expect(result.outcome, WikiPageOutcome.supplemented);
      final page = readPage('manual');
      expect(page, contains('Hand-written knowledge.'));
      expect(page, contains('Machine supplement body.'));
      expect(page, contains('provenance: hybrid'));
      expect(page, contains('sources:\n  - "inbox/second.md"'));
    });
  });

  group('an unchanged merge contributes nothing and changes nothing', () {
    const unchanged = WikiPageMerge(mode: WikiMergeMode.unchanged);

    // The merge declared the page already holds this source's knowledge, so
    // there is no contribution to record. Rewriting the authorship fields for it
    // is the over-claim; refusing to write at all is also what makes a re-dropped
    // source a no-op rather than a second supplement section.
    test('a repeat of a recorded source leaves the stored page byte-identical', () async {
      final file = storePage(
        'stable',
        _page(provenance: 'human-authored', sources: const ['inbox/second.md'], body: 'Shared body text.'),
      );
      final before = file.readAsStringSync();

      final result = await write('stable', body: 'Reworded body text.', merge: unchanged);

      expect(result.outcome, WikiPageOutcome.unchanged);
      expect(file.readAsStringSync(), before);
    });

    // The page gained nothing, but this source's knowledge is demonstrably on it,
    // so the provenance chain has to be able to account for the source.
    test('a source new to the page is recorded without moving any authorship field', () async {
      final file = storePage('accounted', _page(provenance: 'human-authored', body: 'Shared body text.'));

      final result = await write(
        'accounted',
        body: 'Reworded body text.',
        lastUpdatedBy: 'cron:knowledge-inbox',
        merge: unchanged,
      );

      expect(result.outcome, WikiPageOutcome.unchanged);
      final page = file.readAsStringSync();
      expect(page, contains('sources:\n  - "inbox/first.md"\n  - "inbox/second.md"'));
      expect(page, contains('provenance: human-authored'));
      expect(page, contains('last_updated_by: "test"'));
      expect(page, contains(r'last_updated: "2026-05-01T00:00:00.000Z"'));
      expect(page, isNot(contains('## Supplement')));
      expect(page, isNot(contains('Reworded body text.')));
    });
  });

  group('an integrated merge replaces the stored body', () {
    const integrated = WikiPageMerge(mode: WikiMergeMode.integrated);

    // The stored body below the title is what the merge turn was shown and what
    // the floor is measured against: 200 bytes here, so the floor sits at 160.
    final storedBody = 'x' * 200;

    test('the merged body replaces the stored one under a single title heading', () async {
      storePage('merged', _page(sources: const ['inbox/first.md'], body: storedBody));

      final result = await write('merged', body: 'y' * 200, merge: integrated);

      expect(result.outcome, WikiPageOutcome.integrated);
      final page = readPage('merged');
      expect(page, contains('y' * 200));
      expect(page, isNot(contains('x' * 200)));
      expect(page, isNot(contains('## Supplement')));
      expect(RegExp(r'^# ', multiLine: true).allMatches(page), hasLength(1));
      expect(page, contains('sources:\n  - "inbox/first.md"\n  - "inbox/second.md"'));
    });

    // Every host-kept frontmatter rule holds on the branch that rewrites the most.
    test('an integration leaves stored values the store cannot rank exactly as stored', () async {
      storePage(
        'preserved',
        _rawPage(
          provenance: 'obsidian-sync',
          confidence: 'honestly not sure',
          sources: 'sources:\n  - "hand-authored"',
          body: storedBody,
          extra: 'tags:\n  - focus',
        ),
      );

      await write('preserved', body: 'y' * 200, confidence: 'high', merge: integrated);

      final page = readPage('preserved');
      expect(page, contains('provenance: obsidian-sync'));
      expect(page, contains('confidence: "honestly not sure"'));
      expect(page, contains('tags: ["focus"]'));
      expect(page, contains('sources:\n  - "hand-authored"\n  - "inbox/second.md"'));
    });

    // The page is the only copy of every prior batch, so a merge that silently
    // drops most of it reads exactly like a curated page replaced by a summary.
    test('a body under the floor declaring no removal is refused and the page is untouched', () async {
      final file = storePage('shrunk', _page(body: storedBody));
      final before = file.readAsStringSync();

      await expectLater(
        () => write('shrunk', body: 'y' * 159, merge: integrated),
        throwsA(
          isA<WikiPageMergeRefused>()
              .having((e) => e.mergedBytes, 'mergedBytes', 159)
              .having((e) => e.requiredBytes, 'requiredBytes', 160)
              .having((e) => e.toString(), 'message', contains('shrunk.md')),
        ),
      );
      expect(file.readAsStringSync(), before);
    });

    test('the same body written with a declared removal is accepted', () async {
      storePage('declared', _page(body: storedBody));

      final result = await write(
        'declared',
        body: 'y' * 159,
        merge: const WikiPageMerge(mode: WikiMergeMode.integrated, removedContent: ['the superseded vendor table']),
      );

      expect(result.outcome, WikiPageOutcome.integrated);
      expect(readPage('declared'), contains('y' * 159));
    });

    test('a body just above the floor is written without any declaration', () async {
      storePage('sized', _page(body: storedBody));

      final result = await write('sized', body: 'y' * 160, merge: integrated);

      expect(result.outcome, WikiPageOutcome.integrated);
      expect(readPage('sized'), contains('y' * 160));
    });

    // The floor has to measure the text that lands on the page. Measured on the
    // raw reply instead, five bytes of content plus padding clears a floor of
    // 160 and the curated page is gone with no declaration and no refusal.
    test('whitespace padding does not carry a body over the floor', () async {
      final file = storePage('padded', _page(body: storedBody));
      final before = file.readAsStringSync();

      await expectLater(
        () => write('padded', body: 'tiny.${' ' * 500}', merge: integrated),
        throwsA(isA<WikiPageMergeRefused>().having((e) => e.mergedBytes, 'mergedBytes', 5)),
      );
      expect(file.readAsStringSync(), before);
    });

    // The stored title is the page's, and the merge turn does not get to open a
    // second one: the prompt asks for a heading-free body, but asking is not
    // enforcing.
    test('a merged body opening with its own title heading does not add a second one', () async {
      storePage('titled', _page(body: storedBody));

      await write('titled', body: '# Model Title\n\n${'y' * 200}', merge: integrated);

      final page = readPage('titled');
      expect(RegExp(r'^# ', multiLine: true).allMatches(page), hasLength(1));
      expect(page, contains('# Page'));
      expect(page, isNot(contains('# Model Title')));
    });

    test('the floor is a compile-time constant reachable by no parameter', () {
      expect(WikiPageStore.mergeShrinkFloor, 0.8);
    });
  });

  group('a page the store cannot account for is refused, never reinterpreted', () {
    test('a body opening with a thematic break is not parsed as frontmatter', () async {
      final file = storePage('thematic', '---\nA rule, then prose.\n\nMore prose.\n---\nRest of the body.\n');
      final before = file.readAsStringSync();

      await expectLater(() => write('thematic'), throwsA(isA<WikiPageUnreadable>()));
      expect(file.readAsStringSync(), before);
    });

    // An Obsidian or Jekyll page is exactly this shape. Refusing it would deny the
    // slug forever on the deployment this store exists to serve.
    test('foreign frontmatter is merged, its keys preserved, and its page left unclassified', () async {
      storePage('notes', '---\ntags:\n  - focus\naliases: ["deep work"]\n---\nHand-written body.\n');

      final result = await write('notes');

      expect(result.outcome, WikiPageOutcome.supplemented);
      final page = readPage('notes');
      expect(page, contains('Hand-written body.'));
      expect(page, contains('Machine supplement body.'));
      expect(page, contains('tags: ["focus"]'));
      expect(page, contains('aliases: ["deep work"]'));
      // The page records no provenance, so this write records none either.
      expect(page, isNot(contains('provenance:')));
    });

    // Promoting an unclassifiable page is the laundering the trust vocabulary
    // exists to prevent: `hybrid` is what the search source ranks as trusted.
    test('a page whose frontmatter records no provenance is never promoted to hybrid', () async {
      storePage('unlabelled', '---\nsources:\n  - "legacy-import.md"\nconfidence: medium\n---\n# Legacy\n\nBody.\n');

      await write('unlabelled');

      final page = readPage('unlabelled');
      expect(page, isNot(contains('hybrid')));
      expect(page, isNot(contains('provenance:')));
      expect(page, contains('sources:\n  - "legacy-import.md"\n  - "inbox/second.md"'));
    });

    // This is the shape a torn write leaves. Reinterpreting it as body text is
    // what made the damage undetectable, because the lint finding disappeared.
    test('an unterminated frontmatter block is refused and named', () async {
      final file = storePage('torn', '---\nprovenance: llm-authored\nsources:\n  - "inbox/a.md"\n');
      final before = file.readAsStringSync();

      await expectLater(
        () => write('torn'),
        throwsA(
          isA<WikiPageUnreadable>().having((e) => e.toString(), 'message', contains('unterminated YAML frontmatter')),
        ),
      );
      expect(file.readAsStringSync(), before);
    });

    test('an unparseable frontmatter block is refused', () async {
      storePage('bad-yaml', '---\nprovenance: [unclosed\n---\n# Bad\n');

      await expectLater(() => write('bad-yaml'), throwsA(isA<WikiPageUnreadable>()));
    });

    // Refusing is correct – the alternative is overwriting a page nothing can
    // read – but the failure has to name the page, because that is what the
    // operator has to repair, not the inbox source that reported it.
    test('a page that is not valid UTF-8 is refused with the page named', () async {
      File(p.join(wiki.wikiDir.path, 'binary.md')).writeAsBytesSync([0xff, 0xfe]);

      await expectLater(
        () => write('binary'),
        throwsA(isA<WikiPageUnreadable>().having((e) => e.toString(), 'message', contains('binary.md'))),
      );
    });
  });

  // A stored value this store preserves rather than interprets is arbitrary text.
  // Emitted raw, one newline splits the frontmatter and demotes every key below
  // it into the body — the same destruction the parser fix exists to prevent,
  // authored by the store itself.
  group('a preserved value can never split the block it is written into', () {
    test('a stored provenance containing a newline is quoted and survives a second write', () async {
      storePage(
        'injected',
        _rawPage(
          provenance: '"imported\nsources:\n  - forged"',
          sources: 'sources:\n  - "hand-authored"',
          body: 'Prior synthesis body.',
        ),
      );

      await write('injected');
      final afterFirst = readPage('injected');
      await write('injected', body: 'Second supplement body.', sources: const ['inbox/third.md']);

      final page = readPage('injected');
      expect(afterFirst.split('---\n').length, 3, reason: 'exactly one frontmatter block');
      expect(page, contains('sources:\n  - "hand-authored"\n  - "inbox/second.md"\n  - "inbox/third.md"'));
      // The whole stored value stays inside one quoted scalar rather than
      // becoming a second `sources:` key that displaces the real chain.
      expect(RegExp(r'^sources:', multiLine: true).allMatches(page), hasLength(1));
      expect(page, contains(r'provenance: "imported sources: - forged"'));
    });

    test('a stored provenance that is only a comment marker does not become an empty key', () async {
      storePage('commented', _rawPage(provenance: '"#legacy"', sources: 'sources:\n  - "hand"', body: 'Body.'));

      await write('commented');
      await write('commented', body: 'Second body.', sources: const ['inbox/third.md']);

      expect(readPage('commented'), isNot(contains('hybrid')));
      expect(readPage('commented'), contains(r'provenance: "#legacy"'));
    });

    // A value the store cannot interpret must survive a round-trip unchanged: a
    // trailing colon makes the block unparseable, and a keyword or number-shaped
    // value comes back as a different type or vanishes.
    for (final stored in const ['obsidian-sync:', 'null', 'true', '0x1F', '1e5', 'imported: legacy', '#legacy']) {
      test('a stored provenance of "$stored" round-trips through two writes unchanged', () async {
        storePage(
          'roundtrip',
          _rawPage(provenance: jsonEncode(stored), sources: 'sources:\n  - "hand"', body: 'Body.'),
        );

        await write('roundtrip');
        // The second write is what proves it: it has to read back the page the
        // first write authored.
        await write('roundtrip', body: 'Second body.', sources: const ['inbox/third.md']);

        final page = readPage('roundtrip');
        expect(page, contains('provenance: ${jsonEncode(stored)}'));
        expect(page, contains('sources:\n  - "hand"\n  - "inbox/second.md"\n  - "inbox/third.md"'));
      });
    }

    test('a preserved key containing a colon is quoted rather than emitted raw', () async {
      storePage('oddkey', _rawPage(sources: 'sources:\n  - "hand"', body: 'Body.', extra: '"legacy: import": 1'));

      await write('oddkey');
      // Emitted raw this reads back as a nested mapping and the second write
      // refuses the page the first write authored.
      await write('oddkey', body: 'Second body.', sources: const ['inbox/third.md']);

      expect(readPage('oddkey'), contains(r'"legacy: import": 1'));
      expect(readPage('oddkey'), contains('sources:\n  - "hand"\n  - "inbox/second.md"\n  - "inbox/third.md"'));
    });
  });

  group('durability', () {
    // The merge made the stored page the only copy of every prior batch, so a
    // truncating write can destroy exactly what this store exists to keep.
    test('a write leaves no partial page and no temporary file behind', () async {
      storePage('atomic', _page(body: 'Prior synthesis body.'));

      await write('atomic');

      final leftovers = wiki.wikiDir
          .listSync()
          .map((entity) => p.basename(entity.path))
          .where((name) => name.endsWith('.tmp'));
      expect(leftovers, isEmpty);
      expect(readPage('atomic'), contains('Prior synthesis body.'));
    });

    // Staging happens in the wiki directory, so denying new entries there fails
    // the write before the stored page is opened. A truncating in-place write
    // would already have destroyed it by this point.
    test('a write that cannot be staged leaves the stored page intact', () async {
      final file = storePage('locked', _page(body: 'Prior synthesis body.'));
      final before = file.readAsStringSync();
      Process.runSync('chmod', ['555', wiki.wikiDir.path]);
      addTearDown(() => Process.runSync('chmod', ['755', wiki.wikiDir.path]));

      await expectLater(() => write('locked'), throwsA(isA<FileSystemException>()));
      expect(file.readAsStringSync(), before);
    }, skip: Platform.isWindows ? 'POSIX directory permissions' : null);

    test('a write keeps the page operator-editable', () async {
      storePage('editable', _page(body: 'Prior synthesis body.'));
      final file = File(p.join(wiki.wikiDir.path, 'editable.md'));
      final before = file.statSync().mode & 0x1ff;

      await write('editable');

      expect(file.statSync().mode & 0x1ff, before);
    }, skip: Platform.isWindows ? 'POSIX permissions' : null);

    // Preserving a stored page's mode says nothing about the page this store
    // creates: `secureWriteFile` defaults to owner-only, which would hand every
    // new page to the server account alone. Compared against a control file so
    // the assertion holds under whatever umask the host runs.
    test('a created page is no more restricted than an ordinary file in the wiki', () async {
      final control = File(p.join(wiki.wikiDir.path, 'control.txt'))..writeAsStringSync('control');

      await write('fresh', body: 'Fresh synthesis body.');

      final created = File(p.join(wiki.wikiDir.path, 'fresh.md'));
      expect(created.statSync().mode & 0x1ff, control.statSync().mode & 0x1ff);
    }, skip: Platform.isWindows ? 'POSIX permissions' : null);
  });

  group('the exported write contract', () {
    test('a model-controlled slug is reduced to the wiki directory', () async {
      await write('../USER', body: 'Safe body.', sources: const ['inbox/escaped.md']);

      expect(File(p.join(workspace.path, 'wiki', 'user.md')).existsSync(), isTrue);
      expect(File(p.join(workspace.path, 'USER.md')).existsSync(), isFalse);
    });

    test('a confidence value outside the vocabulary is rejected before any write', () async {
      await expectLater(
        () => write('bad-confidence', confidence: 'certain\nlast_updated_by: attacker'),
        throwsArgumentError,
      );
      expect(File(p.join(workspace.path, 'wiki', 'bad-confidence.md')).existsSync(), isFalse);
    });

    test('a blank body is rejected instead of stored as an empty supplement', () async {
      storePage('blank', _page(body: 'Prior synthesis body.'));

      await expectLater(() => write('blank', body: '   \n'), throwsArgumentError);
      expect(readPage('blank'), isNot(contains('## Supplement')));
    });

    test('bootstrap emits provenance frontmatter and the guidance the workspace docs promise', () async {
      final readme = File(p.join(wiki.wikiDir.path, 'README.md')).readAsStringSync();

      expect(readme, startsWith('---\nprovenance: human-authored'));
      expect(readme, contains('sources:\n  - "workspace-bootstrap"'));
      expect(readme, contains('provenance'));
      expect((await lintWikiPages(wiki)).provenanceInconsistencies, isEmpty);
    });
  });
}

String _page({
  String provenance = 'llm-authored',
  String confidence = 'medium',
  List<String> sources = const ['inbox/first.md'],
  String body = 'Prior synthesis body.',
}) => _rawPage(
  provenance: provenance,
  confidence: confidence,
  sources: 'sources:\n${sources.map((source) => '  - "$source"').join('\n')}',
  body: body,
);

String _rawPage({
  String provenance = 'llm-authored',
  String confidence = 'medium',
  required String sources,
  required String body,
  String extra = 'contradicts: []\nrelated: []',
}) =>
    '---\n'
    'provenance: $provenance\n'
    '$sources\n'
    'confidence: $confidence\n'
    'last_updated: 2026-05-01T00:00:00.000Z\n'
    'last_updated_by: "test"\n'
    '$extra\n'
    '---\n'
    '# Page\n'
    '\n'
    '$body\n';
