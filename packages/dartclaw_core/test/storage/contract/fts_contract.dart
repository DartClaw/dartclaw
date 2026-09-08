import 'dart:convert';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'database_backend_contract.dart';

const _documents = <(String, String)>[('doc-a', 'orchid cobalt'), ('doc-b', 'cobalt zephyr'), ('doc-c', 'quartz')];
const _queries = <(String, Set<String>)>[
  ('orchid', {'doc-a'}),
  ('cobalt', {'doc-a', 'doc-b'}),
  ('zephyr', {'doc-b'}),
  ('quartz', {'doc-c'}),
];

void ftsContractGroups(ContractBackend Function() current) {
  group('[contract:fts.membership] exact result sets', () {
    test('uses neutral terms and matches the portable corpus', () async {
      final contract = current();
      final whitelist = _readWhitelist();
      final exercised = <String>{};
      for (final term in _fixtureTerms) {
        final probe = contract.lexemeOf;
        if (probe != null) {
          expect(await probe(term), term, reason: '$term must be neutral on ${contract.engine}');
        } else {
          final id = 'neutral-$term';
          await contract.index.upsert([_document(id, term)], userId: 'neutrality');
          expect((await contract.index.search(term, userId: 'neutrality')).map((hit) => hit.id).toSet(), {id});
        }
      }

      await contract.index.replaceAll([for (final (id, text) in _documents) _document(id, text)], userId: 'member');
      for (final (query, expected) in _queries) {
        final actual = (await contract.index.search(query, userId: 'member')).map((hit) => hit.id).toSet();
        final ignored = whitelist
            .where((entry) {
              final match =
                  entry.query == query &&
                  entry.engine == contract.engine &&
                  (actual.contains(entry.documentId) != expected.contains(entry.documentId));
              if (match) exercised.add(entry.key);
              return match;
            })
            .map((entry) => entry.documentId)
            .toSet();
        expect(actual.difference(ignored), unorderedEquals(expected.difference(ignored)), reason: query);
      }
      _validateWhitelistUsage(whitelist, contract.engine, exercised);
    });

    test('rejects malformed and stale whitelist entries', () {
      expect(
        () => _parseWhitelist([
          {
            'query': 'unused',
            'documentId': 'absent',
            'engine': current().engine,
            'evidence': '',
            'reviewedOn': 'not-a-date',
          },
        ]),
        throwsFormatException,
      );
      final stale = _parseWhitelist([
        {
          'query': 'unused',
          'documentId': 'absent',
          'engine': current().engine,
          'evidence': 'engine output showed a different token',
          'reviewedOn': '2026-09-09',
        },
      ]);
      expect(() => _validateWhitelistUsage(stale, current().engine, const <String>{}), throwsA(isA<StateError>()));
    });
  });

  group('[contract:fts.tenancy] user isolation', () {
    test('isolates reads, overwrites, and deletes for the same id', () async {
      final index = current().index;
      await index.upsert([_document('shared', 'orchid owner')], userId: 'u-alpha');
      await index.upsert([_document('shared', 'quartz other')], userId: 'u-beta');

      expect((await index.search('orchid', userId: 'u-alpha')).map((hit) => hit.id), ['shared']);
      expect(await index.search('orchid', userId: 'u-beta'), isEmpty);
      expect((await index.listRecent(userId: 'u-alpha')).map((hit) => hit.chunk), ['orchid owner']);
      expect((await index.fetch(['shared'], userId: 'u-beta')).single.chunks, ['quartz other']);
      expect(await index.count(userId: 'u-alpha'), 1);
      expect(await index.count(userId: 'u-beta'), 1);

      await index.upsert([_document('shared', 'cobalt replacement')], userId: 'u-alpha');
      expect((await index.fetch(['shared'], userId: 'u-alpha')).single.chunks, ['cobalt replacement']);
      expect((await index.fetch(['shared'], userId: 'u-beta')).single.chunks, ['quartz other']);

      await index.delete(['shared'], userId: 'u-alpha');
      expect(await index.fetch(['shared'], userId: 'u-alpha'), isEmpty);
      expect((await index.fetch(['shared'], userId: 'u-beta')).single.id, 'shared');
    });
  });
}

Set<String> get _fixtureTerms => {
  for (final (_, text) in _documents) ...text.split(' '),
  for (final (query, _) in _queries) query,
};

SearchDocument _document(String id, String text) => SearchDocument(
  id: id,
  chunks: [text],
  metadata: {'source': id, 'role': 'memory', 'provenance': 'contract'},
  timestamp: DateTime.utc(2026, 1, 1),
);

List<_WhitelistEntry> _readWhitelist() {
  final decoded = jsonDecode(contractFixtureFile('fts_divergence_whitelist.json').readAsStringSync());
  if (decoded is! List) throw const FormatException('FTS divergence whitelist must be an array');
  return _parseWhitelist(decoded);
}

List<_WhitelistEntry> _parseWhitelist(List<dynamic> values) {
  return values
      .map((value) {
        if (value is! Map<String, dynamic>) throw const FormatException('Whitelist entries must be objects');
        final query = value['query'];
        final documentId = value['documentId'];
        final engine = value['engine'];
        final evidence = value['evidence'];
        final reviewedOn = value['reviewedOn'];
        if (query is! String ||
            query.isEmpty ||
            documentId is! String ||
            documentId.isEmpty ||
            engine is! String ||
            !const {'sqlite', 'postgres'}.contains(engine) ||
            evidence is! String ||
            evidence.trim().isEmpty ||
            reviewedOn is! String ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(reviewedOn) ||
            DateTime.tryParse(reviewedOn) == null) {
          throw const FormatException('Whitelist entries require query, documentId, engine, evidence, and reviewedOn');
        }
        return _WhitelistEntry(query, documentId, engine, evidence, reviewedOn);
      })
      .toList(growable: false);
}

void _validateWhitelistUsage(List<_WhitelistEntry> entries, String engine, Set<String> exercised) {
  final stale = entries
      .where((entry) => entry.engine == engine && !exercised.contains(entry.key))
      .map((entry) => entry.key);
  if (stale.isNotEmpty) {
    throw StateError('Stale FTS divergence whitelist entries: ${stale.join(', ')}');
  }
}

final class _WhitelistEntry {
  const new(this.query, this.documentId, this.engine, this.evidence, this.reviewedOn);

  final String query;
  final String documentId;
  final String engine;
  final String evidence;
  final String reviewedOn;

  String get key => '$query\u0000$documentId\u0000$engine';
}
