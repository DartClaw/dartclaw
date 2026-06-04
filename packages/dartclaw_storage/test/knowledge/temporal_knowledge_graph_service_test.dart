import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late TemporalKnowledgeGraphService kg;

  setUp(() {
    db = sqlite3.openInMemory();
    kg = TemporalKnowledgeGraphService(db);
  });

  tearDown(() {
    db.close();
  });

  test('S08 KG add query invalidate lifecycle preserves source-linked history', () {
    final id = kg.addFact(
      entity: 'VS Code',
      predicate: 'preferred-editor',
      value: 'true',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/tools.md',
    );

    var facts = kg.query(entity: 'VS Code', predicate: 'preferred-editor', asOf: '2026-05-02T00:00:00Z');
    expect(facts, hasLength(1));
    expect(facts.single.id, id);
    expect(facts.single.entity, 'vs code');
    expect(facts.single.source, 'wiki/tools.md');

    expect(kg.invalidate(id: id, invalidatedAt: '2026-05-03T00:00:00Z', reason: 'user correction'), isTrue);
    facts = kg.query(entity: 'VS Code', predicate: 'preferred-editor', asOf: '2026-05-02T00:00:00Z');
    expect(facts.single.id, id);

    facts = kg.query(entity: 'VS Code', predicate: 'preferred-editor', asOf: '2026-05-04T00:00:00Z');
    expect(facts, isEmpty);

    final timeline = kg.timeline(entity: 'VS Code');
    expect(timeline.single.invalidationReason, 'user correction');
    expect(timeline.single.validTo, '2026-05-03T00:00:00.000Z');
  });

  test('invalidate rejects an instant earlier than valid_from to keep intervals non-inverted', () {
    final id = kg.addFact(
      entity: 'VS Code',
      predicate: 'preferred-editor',
      value: 'true',
      validFrom: '2026-05-10T00:00:00Z',
      source: 'wiki/tools.md',
    );

    expect(
      () => kg.invalidate(id: id, invalidatedAt: '2026-05-05T00:00:00Z', reason: 'premature'),
      throwsArgumentError,
    );

    // The fact's valid_to must remain open (uninverted), proving no partial write happened.
    expect(kg.timeline(entity: 'VS Code').single.validTo, isNull);
  });

  test('invalidate returns false for an unknown fact id', () {
    expect(kg.invalidate(id: 9999, invalidatedAt: '2026-05-05T00:00:00Z', reason: 'noop'), isFalse);
  });

  test('normalizes offset timestamps before string comparison', () {
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'release',
      value: 'stable',
      validFrom: '2026-06-01T12:00:00+02:00',
      source: 'wiki/dart.md',
    );

    final facts = kg.query(entity: 'Dart SDK', predicate: 'release', asOf: '2026-06-01T10:00:00Z');

    expect(facts.single.value, 'stable');
    expect(facts.single.validFrom, '2026-06-01T10:00:00.000Z');
  });

  test('date-only values use UTC midnight without local timezone shifts', () {
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'release-date',
      value: 'stable',
      validFrom: '2026-06-01',
      source: 'wiki/dart.md',
    );

    final facts = kg.query(entity: 'Dart SDK', predicate: 'release-date', asOf: '2026-06-01T00:00:00Z');

    expect(facts.single.validFrom, '2026-06-01T00:00:00.000Z');
  });

  test('S09 as_of only returns facts valid at that time', () {
    kg.addFact(
      entity: 'Google Cloud',
      predicate: 'status',
      value: 'evaluating',
      validFrom: '2026-05-01T00:00:00Z',
      validTo: '2026-05-10T00:00:00Z',
      source: 'inbox/cloud.md',
    );
    kg.addFact(
      entity: 'Google Cloud',
      predicate: 'status',
      value: 'adopted',
      validFrom: '2026-05-11T00:00:00Z',
      source: 'wiki/cloud.md',
    );

    expect(
      kg.query(entity: 'Google Cloud', predicate: 'status', asOf: '2026-05-05T00:00:00Z').single.value,
      'evaluating',
    );
    expect(kg.query(entity: 'Google Cloud', predicate: 'status', asOf: '2026-05-12T00:00:00Z').single.value, 'adopted');
  });

  test('S10 contradiction and no-result paths are explicit', () {
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'release-channel',
      value: 'stable',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/dart.md',
    );

    final contradictions = kg.contradictions(entity: 'Dart SDK', predicate: 'release-channel', value: 'beta');
    expect(contradictions, hasLength(1));
    expect(contradictions.single.existing.value, 'stable');

    expect(kg.query(entity: 'Unknown Entity'), isEmpty);
  });

  test('wiki lint pre-screen can enumerate open contradictions cheaply', () {
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

    final contradictions = kg.openContradictions();

    expect(contradictions, hasLength(1));
    expect(contradictions.single.incomingValue, 'beta');
  });

  test('rejects malformed dates and inverted intervals at write time', () {
    expect(
      () => kg.addFact(
        entity: 'Dart SDK',
        predicate: 'version',
        value: '3.9',
        validFrom: 'not-a-date',
        source: 'wiki/dart.md',
      ),
      throwsArgumentError,
    );
    for (final invalidOffset in [
      '2026-05-01T12:00:00+24:00',
      '2026-05-01T12:00:00+14:99',
      '2026-05-01T12:00:00-00:60',
    ]) {
      expect(
        () => kg.addFact(
          entity: 'Dart SDK',
          predicate: 'version',
          value: '3.9',
          validFrom: invalidOffset,
          source: 'wiki/dart.md',
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => kg.addFact(
        entity: 'Dart SDK',
        predicate: 'version',
        value: '3.9',
        validFrom: '2026-02-30',
        source: 'wiki/dart.md',
      ),
      throwsArgumentError,
    );
    expect(
      () => kg.addFact(
        entity: 'Dart SDK',
        predicate: 'version',
        value: '3.9',
        validFrom: '2026-05-01T12:00:00',
        source: 'wiki/dart.md',
      ),
      throwsArgumentError,
    );
    expect(
      () => kg.addFact(
        entity: 'Dart SDK',
        predicate: 'version',
        value: '3.9',
        validFrom: '2026-05-02T00:00:00Z',
        validTo: '2026-05-01T00:00:00Z',
        source: 'wiki/dart.md',
      ),
      throwsArgumentError,
    );
  });
}
