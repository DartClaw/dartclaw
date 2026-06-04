import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('WebhookDeliveryStore', () {
    late Database db;
    late WebhookDeliveryStore store;

    setUp(() {
      db = sqlite3.openInMemory();
      store = WebhookDeliveryStore(db);
    });

    tearDown(() {
      db.close();
    });

    group('schema', () {
      test('creates webhook_delivery_ids table', () {
        final tables = db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name");
        final names = tables.map((row) => row['name']).toList();

        expect(names, contains('webhook_delivery_ids'));
      });
    });

    group('registerIfNew', () {
      test('returns true on first registration', () {
        expect(store.registerIfNew('delivery-1'), isTrue);
      });

      test('returns false on duplicate', () {
        store.registerIfNew('delivery-1');
        expect(store.registerIfNew('delivery-1'), isFalse);
      });

      test('different delivery IDs are independent', () {
        expect(store.registerIfNew('delivery-1'), isTrue);
        expect(store.registerIfNew('delivery-2'), isTrue);
      });

      test('duplicate returns false even after intervening inserts', () {
        store.registerIfNew('delivery-1');
        store.registerIfNew('delivery-2');
        store.registerIfNew('delivery-3');

        expect(store.registerIfNew('delivery-1'), isFalse);
      });
    });

    group('pending delivery state', () {
      test('reserves, releases, commits, and dedupes delivery IDs', () {
        expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedNew);
        expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.duplicate);

        store.releasePending('delivery-1');
        expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedNew);

        store.commitProcessed('delivery-1');
        expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.duplicate);
      });

      test('reclaims stale pending reservations', () {
        expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedNew);
        db.execute(
          "UPDATE webhook_delivery_ids SET updated_at = '1970-01-01T00:00:00.000Z' WHERE delivery_id = 'delivery-1'",
        );

        expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedReclaimed);
      });

      test('committing reclaimed pending rows refreshes the dedupe TTL', () {
        expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedNew);
        db.execute('''
          UPDATE webhook_delivery_ids
          SET inserted_at = '1970-01-01T00:00:00.000Z',
              updated_at = '1970-01-01T00:00:00.000Z'
          WHERE delivery_id = 'delivery-1'
          ''');

        expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedReclaimed);
        store.commitProcessed('delivery-1');
        store.registerIfNew('trigger-purge');

        expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.duplicate);
      });

      test('treats existing legacy rows as processed after migration', () {
        final legacyDb = sqlite3.openInMemory();
        addTearDown(legacyDb.close);
        legacyDb.execute('''
          CREATE TABLE webhook_delivery_ids (
            delivery_id TEXT PRIMARY KEY,
            inserted_at TEXT NOT NULL
          )
        ''');
        legacyDb.execute("INSERT INTO webhook_delivery_ids (delivery_id, inserted_at) VALUES ('legacy-id', ?)", [
          DateTime.now().toUtc().toIso8601String(),
        ]);

        final migrated = WebhookDeliveryStore(legacyDb);

        expect(migrated.reservePending('legacy-id'), WebhookDeliveryReservation.duplicate);
      });
    });

    group('TTL purge', () {
      test('stale entries are purged on next registerIfNew call', () {
        // Manually insert a row with an old timestamp to simulate a stale entry.
        db.execute(
          '''
          INSERT INTO webhook_delivery_ids (delivery_id, inserted_at, state, updated_at)
          VALUES ('stale-id', ?, 'processed', ?)
          ''',
          ['1970-01-01T00:00:00.000Z', '1970-01-01T00:00:00.000Z'],
        );

        // A new insert triggers the purge.
        store.registerIfNew('trigger-purge');

        final remaining = db.select("SELECT delivery_id FROM webhook_delivery_ids WHERE delivery_id = 'stale-id'");
        expect(remaining, isEmpty);
      });

      test('recent entries survive the purge', () {
        store.registerIfNew('recent-id');
        // Trigger another insert (which runs the purge).
        store.registerIfNew('another-id');

        // 'recent-id' was inserted moments ago and must still be present.
        expect(store.registerIfNew('recent-id'), isFalse);
      });
    });
  });
}
