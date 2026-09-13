import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

typedef VectorIndexFixture = ({
  VectorIndex memory,
  VectorIndex conversation,
  RecordingDatabaseBackend database,
  Future<void> Function() close,
});

void runVectorIndexContract(String backendName, Future<VectorIndexFixture> Function() open) {
  group('$backendName VectorIndex contract', () {
    test('round-trips float32 records and isolates owner, corpus, fingerprint, and dimension', () async {
      final fixture = await open();
      try {
        await fixture.memory.upsert([
          _record('z', 0, [1, 0], hash: 'z'),
          _record('a', 1, [1, 0], hash: 'a1'),
          _record('a', 0, [0.5, 0], hash: 'a0'),
          _record('wrong-fingerprint', 0, [1, 0], fingerprint: 'other'),
          _record('wrong-dimension', 0, [1, 0, 0]),
          _record('zero', 0, [0, 0]),
        ], userId: 'owner');
        await fixture.memory.upsert([
          _record('a', 0, [0, 1], hash: 'other-owner'),
        ], userId: 'other');
        await fixture.conversation.upsert([
          _record('a', 0, [0, 1], hash: 'conversation'),
        ], userId: 'owner');

        final listed = await fixture.memory.list(userId: 'owner');
        expect(listed.map((record) => '${record.documentId}:${record.chunkIndex}'), [
          'a:0',
          'a:1',
          'wrong-dimension:0',
          'wrong-fingerprint:0',
          'z:0',
          'zero:0',
        ]);
        expect(listed.first.vector, closeToVector([0.5, 0]));
        expect((await fixture.memory.list(userId: 'other')).single.contentHash, 'other-owner');
        expect((await fixture.conversation.list(userId: 'owner')).single.contentHash, 'conversation');

        final matches = await fixture.memory.search([1, 0], userId: 'owner', modelFingerprint: 'model', limit: 3);
        expect(matches.map((match) => '${match.documentId}:${match.chunkIndex}'), ['a:0', 'a:1', 'z:0']);
        expect(matches.every((match) => match.score.isFinite), isTrue);
        expect(matches.map((match) => match.score), everyElement(closeTo(1, 1e-6)));
        expect(await fixture.memory.search([0, 0], userId: 'owner', modelFingerprint: 'model'), isEmpty);
      } finally {
        await fixture.close();
      }
    });

    test('applies last-wins retirement, deletion, and complete owner replacement', () async {
      final fixture = await open();
      try {
        await fixture.memory.upsert([
          _record('a', 0, [1]),
          _record('b', 0, [2]),
        ], userId: 'owner');
        await fixture.memory.upsert([
          _record('a', 0, [3], hash: 'other'),
        ], userId: 'other');
        await fixture.conversation.upsert([
          _record('kept', 0, [4]),
        ], userId: 'owner');

        await fixture.memory.upsert(
          [
            _record('replacement', 0, [5], hash: 'discarded'),
            _record('replacement', 0, [6], hash: 'retained'),
          ],
          userId: 'owner',
          retire: {VectorIdentity(documentId: 'a', chunkIndex: 0)},
        );
        expect((await fixture.memory.list(userId: 'owner')).map((record) => record.documentId), ['b', 'replacement']);
        expect((await fixture.memory.list(userId: 'owner')).last.contentHash, 'retained');

        await fixture.memory.delete([
          VectorIdentity(documentId: 'replacement', chunkIndex: 0),
          VectorIdentity(documentId: 'missing', chunkIndex: 0),
        ], userId: 'owner');
        expect((await fixture.memory.list(userId: 'owner')).single.documentId, 'b');

        await fixture.memory.replaceAll(const [], userId: 'owner');
        expect(await fixture.memory.list(userId: 'owner'), isEmpty);
        expect((await fixture.memory.list(userId: 'other')).single.contentHash, 'other');
        expect((await fixture.conversation.list(userId: 'owner')).single.documentId, 'kept');
      } finally {
        await fixture.close();
      }
    });

    test('rejects invalid queries', () async {
      final fixture = await open();
      try {
        for (final query in <List<double>>[
          const [],
          const [double.nan],
          const [double.infinity],
          const [double.negativeInfinity],
          const [1e308],
        ]) {
          fixture.database.reset();
          await expectLater(
            fixture.memory.search(query, userId: 'owner', modelFingerprint: 'model'),
            throwsArgumentError,
            reason: '$query',
          );
          _expectNoDatabaseOperations(fixture.database);
        }
        fixture.database.reset();
        await expectLater(fixture.memory.search(const [1], userId: 'owner', modelFingerprint: ''), throwsArgumentError);
        _expectNoDatabaseOperations(fixture.database);
        fixture.database.reset();
        await expectLater(
          fixture.memory.search(const [1], userId: 'owner', modelFingerprint: 'model', limit: 0),
          throwsArgumentError,
        );
        _expectNoDatabaseOperations(fixture.database);
      } finally {
        await fixture.close();
      }
    });

    test('rejects finite values that overflow float32 before mutation work', () async {
      final fixture = await open();
      try {
        fixture.database.reset();
        await expectLater(
          fixture.memory.upsert([
            _record('overflow', 0, const [1e308]),
          ], userId: 'owner'),
          throwsArgumentError,
        );
        _expectNoDatabaseOperations(fixture.database);
      } finally {
        await fixture.close();
      }
    });
  });
}

VectorRecord _record(
  String documentId,
  int chunkIndex,
  List<double> vector, {
  String? hash,
  String fingerprint = 'model',
}) => VectorRecord(
  documentId: documentId,
  chunkIndex: chunkIndex,
  contentHash: hash ?? '$documentId-$chunkIndex',
  modelFingerprint: fingerprint,
  vector: vector,
);

Matcher closeToVector(List<double> expected) => predicate<List<double>>((actual) {
  if (actual.length != expected.length) return false;
  for (var index = 0; index < actual.length; index++) {
    if ((actual[index] - expected[index]).abs() > 1e-6) return false;
  }
  return true;
}, 'a float32 vector close to $expected');

void _expectNoDatabaseOperations(RecordingDatabaseBackend database) {
  expect(
    (
      query: database.queryCount,
      execute: database.executeCount,
      prepare: database.prepareCount,
      transaction: database.transactionCount,
    ),
    (query: 0, execute: 0, prepare: 0, transaction: 0),
  );
}
