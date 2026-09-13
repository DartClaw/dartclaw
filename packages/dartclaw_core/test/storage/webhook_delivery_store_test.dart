import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WebhookDeliveryStore', () {
    late Directory tempDir;
    late Directory markerDir;
    late DateTime now;
    late WebhookDeliveryStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('webhook-delivery-store-');
      markerDir = Directory(p.join(tempDir.path, 'webhook_deliveries'));
      now = DateTime.parse('2026-03-15T09:30:00Z');
      store = openWebhookDeliveryStore(markerDir.path, now: () => now);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('reserves, releases, commits, and dedupes delivery IDs', () {
      expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedNew);
      expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.duplicate);
      store.releasePending('delivery-1');
      expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedNew);
      store.commitProcessed('delivery-1');
      expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.duplicate);

      final body = _readMarker(markerDir, 'delivery-1');
      expect(body.keys, unorderedEquals(['state', 'inserted_at', 'updated_at']));
      expect(body['state'], 'processed');
    });

    test('stale pending is reclaimed and commit refreshes the TTL anchor', () {
      final old = now.subtract(const Duration(days: 8));
      _writeMarker(markerDir, 'delivery-1', state: 'pending', at: old);
      expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedReclaimed);
      store.commitProcessed('delivery-1');
      expect(_readMarker(markerDir, 'delivery-1'), {
        'state': 'processed',
        'inserted_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });

      now = now.add(const Duration(hours: 2));
      expect(store.reservePending('purge-trigger'), WebhookDeliveryReservation.reservedNew);
      expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.duplicate);
    });

    test('purge removes old processed markers and leaves pending and sibling database untouched', () {
      final old = now.subtract(const Duration(days: 8));
      _writeMarker(markerDir, 'processed-old', state: 'processed', at: old);
      _writeMarker(markerDir, 'pending-old', state: 'pending', at: old);
      final legacyDb = File(p.join(tempDir.path, 'webhook_deliveries.db'))..writeAsBytesSync([1, 2, 3]);
      expect(store.reservePending('trigger'), WebhookDeliveryReservation.reservedNew);
      expect(_marker(markerDir, 'processed-old').existsSync(), isFalse);
      expect(_marker(markerDir, 'pending-old').existsSync(), isTrue);
      expect(legacyDb.readAsBytesSync(), [1, 2, 3]);
    });

    test('empty and truncated claimed markers are reclaimable and release deletes them', () {
      _marker(markerDir, 'empty').createSync();
      _marker(markerDir, 'truncated').writeAsStringSync('{');
      expect(store.reservePending('empty'), WebhookDeliveryReservation.reservedReclaimed);
      expect(store.reservePending('truncated'), WebhookDeliveryReservation.reservedReclaimed);
      expect(_readMarker(markerDir, 'empty')['state'], 'pending');
      expect(_readMarker(markerDir, 'truncated')['state'], 'pending');
      store.releasePending('empty');
      expect(_marker(markerDir, 'empty').existsSync(), isFalse);
    });

    test('open sweeps temp files and leaves marker files unchanged', () {
      final marker = _marker(markerDir, 'keep')..writeAsStringSync('{}');
      final temp = File(p.join(markerDir.path, '${p.basename(marker.path)}.abcd.tmp'))..writeAsStringSync('partial');
      openWebhookDeliveryStore(markerDir.path, now: () => now);
      expect(temp.existsSync(), isFalse);
      expect(marker.readAsStringSync(), '{}');
    });

    test('hostile and case-distinct IDs stay inside the marker directory', () {
      const ids = ['../../pwned', 'CON', 'Abc-1', 'abc-1'];
      final longId = 'x' * 400;
      for (final id in [...ids, longId]) {
        expect(store.reservePending(id), WebhookDeliveryReservation.reservedNew);
        store.commitProcessed(id);
      }
      final names = markerDir.listSync().whereType<File>().map((file) => p.basename(file.path)).toList();
      expect(names, hasLength(5));
      expect(names, everyElement(matches(RegExp(r'^[0-9a-f]{64}$'))));
      expect(_marker(markerDir, 'Abc-1').path, isNot(_marker(markerDir, 'abc-1').path));
      expect(File(p.join(tempDir.parent.path, 'pwned')).existsSync(), isFalse);
    });

    test('exclusive claim allows only one new reservation across instances', () {
      final other = openWebhookDeliveryStore(markerDir.path, now: () => now);
      expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedNew);
      expect(other.reservePending('delivery-1'), WebhookDeliveryReservation.duplicate);
    });

    test('purge tolerates a held stale marker according to platform semantics', () {
      final old = now.subtract(const Duration(days: 8));
      _writeMarker(markerDir, 'held', state: 'processed', at: old);
      _writeMarker(markerDir, 'free', state: 'processed', at: old);
      final held = _marker(markerDir, 'held').openSync(mode: FileMode.append);
      addTearDown(held.closeSync);
      expect(store.reservePending('trigger'), WebhookDeliveryReservation.reservedNew);
      expect(_marker(markerDir, 'free').existsSync(), isFalse);
      expect(_marker(markerDir, 'held').existsSync(), Platform.isWindows ? isTrue : isFalse);
    });

    test('atomic rewrites replace existing markers', () {
      expect(store.reservePending('delivery-1'), WebhookDeliveryReservation.reservedNew);
      store.commitProcessed('delivery-1');
      expect(_readMarker(markerDir, 'delivery-1')['state'], 'processed');
    });
  });
}

File _marker(Directory directory, String deliveryId) =>
    File(p.join(directory.path, sha256.convert(utf8.encode(deliveryId)).toString()));

Map<String, dynamic> _readMarker(Directory directory, String deliveryId) =>
    jsonDecode(_marker(directory, deliveryId).readAsStringSync()) as Map<String, dynamic>;

void _writeMarker(Directory directory, String deliveryId, {required String state, required DateTime at}) {
  _marker(directory, deliveryId).writeAsStringSync(
    jsonEncode({'state': state, 'inserted_at': at.toIso8601String(), 'updated_at': at.toIso8601String()}),
  );
}
