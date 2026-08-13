import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

const collectionId = '9a56ad9e-573c-45a4-901f-4fc073a20f84';
const entryId = 'e907c4e7-0c55-43c0-95cd-ebf41c4f6721';
final created = DateTime.utc(2026, 8, 10, 12);
final updated = DateTime.utc(2026, 8, 11, 13, 30);

MemorySourceRef source({String? event = 'session-1:4', String? caller = 'user', String? session = 'session-1'}) =>
    MemorySourceRef(
      originKind: MemoryOriginKind.turn,
      sourceLocator: 'sessions/session-1/messages/4',
      sourceEvent: event,
      caller: caller,
      sessionRef: session,
    );

CanonicalMemoryEntry entry({
  String id = entryId,
  int revision = 3,
  String topic = 'preferences',
  DateTime? createdAt,
  DateTime? updatedAt,
}) => CanonicalMemoryEntry(
  id: id,
  revision: revision,
  topic: topic,
  summary: 'Prefers concise answers',
  content: 'Use concise answers.\n\n- Keep key evidence\n- Avoid filler',
  created: createdAt ?? created,
  updated: updatedAt ?? updated,
  provenance: source(),
);

void main() {
  group('canonical values', () {
    test('preserve separate identities, revisions, provenance, and locators', () {
      final metadata = MemoryCollectionMetadata(collectionId: collectionId, revision: 7);
      final value = entry();

      expect(metadata.collectionId, collectionId);
      expect(metadata.revision, 7);
      expect(value.revision, 3);
      expect(value.locator, entryId);
      expect(value.provenance.sourceEvent, 'session-1:4');
      expect(value.provenance.caller, 'user');
      expect(value.provenance.sessionRef, 'session-1');
    });

    test('rejects invalid IDs, revisions, topics, provenance, and timestamps', () {
      expect(() => MemoryCollectionMetadata(collectionId: 'not-an-id', revision: 1), throwsArgumentError);
      expect(() => MemoryCollectionMetadata(collectionId: collectionId, revision: 0), throwsArgumentError);
      for (final topic in ['', 'Preferences', 'two words', 'a' * 65]) {
        expect(() => entry(topic: topic), throwsArgumentError, reason: topic);
      }
      expect(() => MemorySourceRef(originKind: MemoryOriginKind.turn, sourceLocator: ' '), throwsArgumentError);
      for (final kind in [
        MemoryOriginKind.turn,
        MemoryOriginKind.journal,
        MemoryOriginKind.inbox,
        MemoryOriginKind.curation,
      ]) {
        expect(
          () => MemorySourceRef(originKind: kind, sourceLocator: 'source'),
          throwsArgumentError,
          reason: kind.name,
        );
      }
      expect(() => MemorySourceRef(sourceLocator: 'manual', sourceEvent: 'unexpected'), throwsArgumentError);
      expect(
        () =>
            MemorySourceRef(originKind: MemoryOriginKind.migration, sourceLocator: 'legacy', sourceEvent: 'unexpected'),
        throwsArgumentError,
      );
      expect(MemorySourceRef(sourceLocator: 'manual').sourceEvent, isNull);
      expect(MemorySourceRef(originKind: MemoryOriginKind.migration, sourceLocator: 'legacy').sourceEvent, isNull);
      expect(() => entry(createdAt: DateTime(2026), updatedAt: updated), throwsArgumentError);
      expect(() => entry(createdAt: updated, updatedAt: created), throwsArgumentError);
      expect(
        () => MemoryCollectionMetadata(formatVersion: 2, collectionId: collectionId, revision: 1),
        throwsArgumentError,
      );
      expect(() => MemoryOriginKind.parse('unknown'), throwsFormatException);
      expect(
        () => MemoryIndexEntry(
          id: entryId,
          revision: 1,
          topic: 'preferences',
          summary: 'summary',
          updated: updated,
          priority: -1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects blank provenance components at construction', () {
      final invalidFields = <String, MemorySourceRef Function()>{
        'sourceEvent': () => MemorySourceRef(
          originKind: MemoryOriginKind.turn,
          sourceLocator: 'sessions/session-1/messages/4',
          sourceEvent: ' ',
        ),
        'caller': () => MemorySourceRef(sourceLocator: 'manual', caller: ' '),
        'sessionRef': () => MemorySourceRef(sourceLocator: 'manual', sessionRef: ' '),
      };

      for (final invalidField in invalidFields.entries) {
        expect(
          invalidField.value,
          throwsA(isA<ArgumentError>().having((error) => error.name, 'name', invalidField.key)),
          reason: invalidField.key,
        );
      }
    });

    test('exact-replay equality requires every optional provenance component', () {
      expect(source().isExactReplayOf(source()), isTrue);
      expect(source(), source());
      final incomplete = MemorySourceRef(sourceLocator: 'manual');
      expect(incomplete, same(incomplete), reason: 'identity preserves reflexivity');
      expect(incomplete, isNot(MemorySourceRef(sourceLocator: 'manual')));
      expect(source(caller: null), isNot(source(caller: null)));
      expect(source(session: null), isNot(source(session: null)));
      expect(source().isExactReplayOf(source(event: 'session-1:5')), isFalse);
    });
  });
}
