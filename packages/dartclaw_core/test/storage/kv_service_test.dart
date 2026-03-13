import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late KvService kv;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_test_kv_');
    kv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
  });

  tearDown(() async {
    await kv.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('get', () {
    test('returns null when file does not exist', () async {
      expect(await kv.get('missing'), isNull);
    });

    test('returns null for non-existent key', () async {
      await kv.set('other', 'val');
      expect(await kv.get('missing'), isNull);
    });

    test('returns cached value without re-reading file', () async {
      await kv.set('key1', 'value1');
      expect(await kv.get('key1'), equals('value1'));

      final file = File(p.join(tempDir.path, 'kv.json'));
      file.writeAsStringSync('{"key1":{"value":"tampered","updatedAt":"2026-03-10T10:00:00Z"}}');

      expect(await kv.get('key1'), equals('value1'));
    });
  });

  group('set', () {
    test('stores and retrieves value', () async {
      await kv.set('key1', 'value1');
      expect(await kv.get('key1'), equals('value1'));
    });

    test('overwrites existing value', () async {
      await kv.set('key1', 'old');
      await kv.set('key1', 'new');
      expect(await kv.get('key1'), equals('new'));
    });

    test('creates file and directory if missing', () async {
      final nested = KvService(filePath: p.join(tempDir.path, 'sub', 'dir', 'kv.json'));
      await nested.set('k', 'v');
      expect(await nested.get('k'), equals('v'));
      await nested.dispose();
    });

    test('persists to disk before the future completes', () async {
      await kv.set('durable', 'value');

      final file = File(p.join(tempDir.path, 'kv.json'));
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains('"durable"'));
    });
  });

  group('delete', () {
    test('removes existing key', () async {
      await kv.set('key1', 'val');
      await kv.delete('key1');
      expect(await kv.get('key1'), isNull);
      expect(File(p.join(tempDir.path, 'kv.json')).readAsStringSync(), isNot(contains('"key1"')));
    });

    test('no-op when file does not exist', () async {
      // Should not throw
      await kv.delete('missing');
    });
  });

  group('getByPrefix', () {
    test('returns matching entries', () async {
      await kv.set('turn:abc', 'data1');
      await kv.set('turn:def', 'data2');
      await kv.set('session_cost:xyz', 'cost');

      final result = await kv.getByPrefix('turn:');
      expect(result.length, equals(2));
      expect(result['turn:abc'], equals('data1'));
      expect(result['turn:def'], equals('data2'));
    });

    test('returns cached prefix values without re-reading file', () async {
      await kv.set('turn:abc', 'data1');
      expect(await kv.getByPrefix('turn:'), {'turn:abc': 'data1'});

      final file = File(p.join(tempDir.path, 'kv.json'));
      file.writeAsStringSync('{"turn:abc":{"value":"tampered","updatedAt":"2026-03-10T10:00:00Z"}}');

      expect(await kv.getByPrefix('turn:'), {'turn:abc': 'data1'});
    });

    test('returns empty map when no matches', () async {
      await kv.set('session_cost:xyz', 'cost');
      final result = await kv.getByPrefix('turn:');
      expect(result, isEmpty);
    });

    test('returns empty map when file does not exist', () async {
      final result = await kv.getByPrefix('turn:');
      expect(result, isEmpty);
    });
  });

  group('serialized writes', () {
    test('multiple concurrent writes do not corrupt data', () async {
      // Fire multiple writes concurrently
      await Future.wait([kv.set('a', '1'), kv.set('b', '2'), kv.set('c', '3')]);
      expect(await kv.get('a'), equals('1'));
      expect(await kv.get('b'), equals('2'));
      expect(await kv.get('c'), equals('3'));
    });
  });

  group('cache invalidation', () {
    test('invalidates cache after write failure', () async {
      final targetDir = Directory(p.join(tempDir.path, 'kv-target'))..createSync();
      final failing = KvService(filePath: targetDir.path);
      addTearDown(failing.dispose);

      await expectLater(failing.set('key', 'stale'), throwsA(isA<FileSystemException>()));

      targetDir.deleteSync(recursive: true);
      File(targetDir.path).writeAsStringSync('{"key":{"value":"fresh","updatedAt":"2026-03-10T10:00:00Z"}}');

      expect(await failing.get('key'), equals('fresh'));
    });
  });
}
