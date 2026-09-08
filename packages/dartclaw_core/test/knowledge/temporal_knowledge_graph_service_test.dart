import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late SqliteBackend backend;
  late TemporalKnowledgeGraphService kg;

  setUp(() async {
    db = openTaskDbInMemory();
    backend = SqliteBackend(db);
    await SqliteSchemaGate.prepareTasks(backend, storeName: 'tasks.db');
    kg = TemporalKnowledgeGraphService(backend);
  });

  tearDown(() async {
    await backend.close();
  });

  test('consecutive fact IDs match their stored rows', () async {
    final ids = <int>[];
    for (final value in ['first', 'second']) {
      ids.add(
        await kg.addFact(
          entity: 'Build',
          predicate: 'status',
          value: value,
          validFrom: '2026-05-01T00:00:00Z',
          source: 'wiki/build.md',
        ),
      );
    }
    expect(ids[1], greaterThan(ids[0]));
    final rows = db.select('SELECT id, value FROM kg_facts ORDER BY id');
    expect(rows.map((row) => row['id']), ids);
    expect(rows.map((row) => row['value']), ['first', 'second']);
  });

  test('KG add query invalidate lifecycle preserves source-linked history', () async {
    final id = await kg.addFact(
      entity: 'VS Code',
      predicate: 'preferred-editor',
      value: 'true',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/tools.md',
    );

    var facts = await kg.query(entity: 'VS Code', predicate: 'preferred-editor', asOf: '2026-05-02T00:00:00Z');
    expect(facts, hasLength(1));
    expect(facts.single.id, id);
    expect(facts.single.entity, 'vs code');
    expect(facts.single.source, 'wiki/tools.md');

    expect(await kg.invalidate(id: id, invalidatedAt: '2026-05-03T00:00:00Z', reason: 'user correction'), isTrue);
    facts = await kg.query(entity: 'VS Code', predicate: 'preferred-editor', asOf: '2026-05-02T00:00:00Z');
    expect(facts.single.id, id);

    facts = await kg.query(entity: 'VS Code', predicate: 'preferred-editor', asOf: '2026-05-04T00:00:00Z');
    expect(facts, isEmpty);

    final timeline = await kg.timeline(entity: 'VS Code');
    expect(timeline.single.invalidationReason, 'user correction');
    expect(timeline.single.validTo, '2026-05-03T00:00:00.000Z');
  });

  test('stable fact id reopens preserved current and invalidated facts', () async {
    final id = await kg.addFact(
      entity: 'Falcon',
      predicate: 'status',
      value: 'green',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/falcon.md',
    );

    expect((await kg.factById(id))?.value, 'green');
    expect(await kg.factById(9999), isNull);

    await kg.invalidate(id: id, invalidatedAt: '2026-05-02T00:00:00Z', reason: 'superseded');

    expect((await kg.factById(id))?.invalidationReason, 'superseded');
  });

  test('owner column exists and addFact persists caller principal', () async {
    final id = await kg.addFact(
      entity: 'Owned System',
      predicate: 'status',
      value: 'active',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/system.md',
      owner: 'principal-1',
    );

    expect(await kg.ownerForFact(id), 'principal-1');
    expect((await kg.query(entity: 'Owned System')).single.owner, 'principal-1');
  });

  test('invalidate rejects an instant earlier than valid_from to keep intervals non-inverted', () async {
    final id = await kg.addFact(
      entity: 'VS Code',
      predicate: 'preferred-editor',
      value: 'true',
      validFrom: '2026-05-10T00:00:00Z',
      source: 'wiki/tools.md',
    );

    await expectLater(
      () => kg.invalidate(id: id, invalidatedAt: '2026-05-05T00:00:00Z', reason: 'premature'),
      throwsArgumentError,
    );

    // The fact's valid_to must remain open (uninverted), proving no partial write happened.
    expect((await kg.timeline(entity: 'VS Code')).single.validTo, isNull);
  });

  test('invalidate returns false for an unknown fact id', () async {
    expect(await kg.invalidate(id: 9999, invalidatedAt: '2026-05-05T00:00:00Z', reason: 'noop'), isFalse);
  });

  test('normalizes offset timestamps before string comparison', () async {
    await kg.addFact(
      entity: 'Dart SDK',
      predicate: 'release',
      value: 'stable',
      validFrom: '2026-06-01T12:00:00+02:00',
      source: 'wiki/dart.md',
    );

    final facts = await kg.query(entity: 'Dart SDK', predicate: 'release', asOf: '2026-06-01T10:00:00Z');

    expect(facts.single.value, 'stable');
    expect(facts.single.validFrom, '2026-06-01T10:00:00.000Z');
  });

  test('date-only values use UTC midnight without local timezone shifts', () async {
    await kg.addFact(
      entity: 'Dart SDK',
      predicate: 'release-date',
      value: 'stable',
      validFrom: '2026-06-01',
      source: 'wiki/dart.md',
    );

    final facts = await kg.query(entity: 'Dart SDK', predicate: 'release-date', asOf: '2026-06-01T00:00:00Z');

    expect(facts.single.validFrom, '2026-06-01T00:00:00.000Z');
  });

  test('date-only as_of values use UTC midnight without local timezone shifts', () async {
    await kg.addFact(
      entity: 'Dart SDK',
      predicate: 'release-date',
      value: 'stable',
      validFrom: '2026-06-01',
      source: 'wiki/dart.md',
    );

    expect(kg.parseAsOf('2026-06-01'), DateTime.utc(2026, 6, 1));
    expect((await kg.allFacts(asOf: '2026-06-01')).single.value, 'stable');
  });

  test('as_of only returns facts valid at that time', () async {
    await kg.addFact(
      entity: 'Google Cloud',
      predicate: 'status',
      value: 'evaluating',
      validFrom: '2026-05-01T00:00:00Z',
      validTo: '2026-05-10T00:00:00Z',
      source: 'inbox/cloud.md',
    );
    await kg.addFact(
      entity: 'Google Cloud',
      predicate: 'status',
      value: 'adopted',
      validFrom: '2026-05-11T00:00:00Z',
      source: 'wiki/cloud.md',
    );

    expect(
      (await kg.query(entity: 'Google Cloud', predicate: 'status', asOf: '2026-05-05T00:00:00Z')).single.value,
      'evaluating',
    );
    expect(
      (await kg.query(entity: 'Google Cloud', predicate: 'status', asOf: '2026-05-12T00:00:00Z')).single.value,
      'adopted',
    );
  });

  test('allFacts enumerates facts across entities in validity order', () async {
    await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2026-02-01T00:00:00Z',
      source: 'wiki/status.md',
    );
    await kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'storage',
      value: 'sqlite',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/architecture.md',
    );
    await kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'storage',
      value: 'sqlite-wal',
      validFrom: '2026-03-01T00:00:00Z',
      source: 'wiki/architecture.md',
    );

    final facts = await kg.allFacts();

    expect(facts.map((fact) => fact.entity), ['architecture decisions', 'architecture decisions', 'project status']);
    expect(facts.where((fact) => fact.entity == 'architecture decisions').map((fact) => fact.validFrom), [
      '2026-01-01T00:00:00.000Z',
      '2026-03-01T00:00:00.000Z',
    ]);
  });

  test('allFacts applies search and limit in the database read', () async {
    await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/status.md',
    );
    await kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'sqlite',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/architecture.md',
    );
    await kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'sqlite-wal',
      validFrom: '2026-02-01T00:00:00Z',
      source: 'wiki/architecture.md',
    );

    final facts = await kg.allFacts(search: 'architecture sqlite', limit: 1);

    expect(facts, hasLength(1));
    expect(facts.single.entity, 'architecture decisions');
    expect(facts.single.value, 'sqlite');
  });

  test('allFacts keeps invalidated history visible', () async {
    final id = await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/status.md',
    );
    await kg.invalidate(id: id, invalidatedAt: '2026-02-01T00:00:00Z', reason: 'phase changed');

    expect((await kg.allFacts()).single.invalidatedAt, '2026-02-01T00:00:00.000Z');
    expect(await kg.allFacts(asOf: '2026-02-02T00:00:00Z'), isEmpty);
  });

  test('allFacts as_of matches per-entity query semantics', () async {
    await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2026-01-01T00:00:00Z',
      validTo: '2026-02-01T00:00:00Z',
      source: 'wiki/status.md',
    );
    await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'beta',
      validFrom: '2026-02-01T00:00:00Z',
      source: 'wiki/status.md',
    );
    await kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'sqlite',
      validFrom: '2026-01-15T00:00:00Z',
      source: 'wiki/architecture.md',
    );

    final allAsOf = await kg.allFacts(asOf: '2026-01-20T00:00:00Z');

    expect(allAsOf.map((fact) => '${fact.entity}:${fact.value}'), [
      'architecture decisions:sqlite',
      'project status:alpha',
    ]);
    expect(
      allAsOf.where((fact) => fact.entity == 'project status').map((fact) => fact.id),
      (await kg.query(entity: 'Project Status', asOf: '2026-01-20T00:00:00Z')).map((fact) => fact.id),
    );
    expect(allAsOf.any((fact) => fact.value == 'beta'), isFalse);
  });

  test('allFacts as_of uses temporal comparison for microsecond boundaries', () async {
    final futureId = await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'future',
      validFrom: '2026-01-01T00:00:00.000001Z',
      source: 'wiki/status.md',
    );
    await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'bounded',
      validFrom: '2025-12-31T23:59:59.999999Z',
      validTo: '2026-01-01T00:00:00.000000Z',
      source: 'wiki/status.md',
    );
    await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'valid-to-future',
      validFrom: '2025-12-31T23:59:59.999998Z',
      validTo: '2026-01-01T00:00:00.000001Z',
      source: 'wiki/status.md',
    );
    final invalidatedId = await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'invalidated',
      validFrom: '2025-12-31T23:59:59.999999Z',
      source: 'wiki/status.md',
    );
    await kg.invalidate(id: invalidatedId, invalidatedAt: '2026-01-01T00:00:00.000000Z', reason: 'boundary');
    final invalidatedAfterAsOfId = await kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'invalidated-after-as-of',
      validFrom: '2025-12-31T23:59:59.999997Z',
      source: 'wiki/status.md',
    );
    await kg.invalidate(
      id: invalidatedAfterAsOfId,
      invalidatedAt: '2026-01-01T00:00:00.000001Z',
      reason: 'after boundary',
    );

    final allAsOf = await kg.allFacts(asOf: '2026-01-01T00:00:00.000000Z');
    final queryAsOf = await kg.query(entity: 'Project Status', asOf: '2026-01-01T00:00:00.000000Z');

    expect(
      allAsOf.map((fact) => fact.value),
      unorderedEquals(['bounded', 'valid-to-future', 'invalidated-after-as-of']),
    );
    expect(
      queryAsOf.map((fact) => fact.value),
      unorderedEquals(['bounded', 'valid-to-future', 'invalidated-after-as-of']),
    );
    expect(allAsOf.any((fact) => fact.id == futureId), isFalse);
  });

  test('contradiction and no-result paths are explicit', () async {
    await kg.addFact(
      entity: 'Dart SDK',
      predicate: 'release-channel',
      value: 'stable',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/dart.md',
    );

    final contradictions = await kg.contradictions(entity: 'Dart SDK', predicate: 'release-channel', value: 'beta');
    expect(contradictions, hasLength(1));
    expect(contradictions.single.existing.value, 'stable');

    expect(await kg.query(entity: 'Unknown Entity'), isEmpty);
  });

  test('wiki lint pre-screen can enumerate open contradictions cheaply', () async {
    await kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'stable',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/dart.md',
    );
    await kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'beta',
      validFrom: '2026-05-02T00:00:00Z',
      source: 'inbox/dart.md',
    );

    final contradictions = await kg.openContradictions();

    expect(contradictions, hasLength(1));
    expect(contradictions.single.incomingValue, 'beta');
  });

  test('rejects malformed dates and inverted intervals at write time', () async {
    await expectLater(
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
      await expectLater(
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
    await expectLater(
      () => kg.addFact(
        entity: 'Dart SDK',
        predicate: 'version',
        value: '3.9',
        validFrom: '2026-02-30',
        source: 'wiki/dart.md',
      ),
      throwsArgumentError,
    );
    await expectLater(
      () => kg.addFact(
        entity: 'Dart SDK',
        predicate: 'version',
        value: '3.9',
        validFrom: '2026-05-01T12:00:00',
        source: 'wiki/dart.md',
      ),
      throwsArgumentError,
    );
    await expectLater(
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
