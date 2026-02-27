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
  });

  group('delete', () {
    test('removes existing key', () async {
      await kv.set('key1', 'val');
      await kv.delete('key1');
      expect(await kv.get('key1'), isNull);
    });

    test('no-op when file does not exist', () async {
      // Should not throw
      await kv.delete('missing');
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
}
