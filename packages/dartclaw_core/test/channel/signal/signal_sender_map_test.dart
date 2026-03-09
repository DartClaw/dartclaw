import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String filePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('signal_sender_map_test_');
    filePath = '${tempDir.path}/signal-sender-map.json';
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('SignalSenderMap', () {
    test('resolve with both phone and UUID stores mapping and returns phone', () {
      final map = SignalSenderMap(filePath: filePath);
      final result = map.resolve(
        sourceNumber: '+1234567890',
        sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
      );
      expect(result, '+1234567890');
      expect(map.length, 1);
    });

    test('resolve with UUID only returns UUID when no mapping exists', () {
      final map = SignalSenderMap(filePath: filePath);
      final result = map.resolve(sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8');
      expect(result, '12bfcd5a-3363-45f4-94b6-3fe247f11ab8');
      expect(map.length, 0);
    });

    test('resolve with UUID only returns cached phone when mapping exists', () {
      final map = SignalSenderMap(filePath: filePath);
      // First: store mapping
      map.resolve(
        sourceNumber: '+1234567890',
        sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
      );
      // Second: UUID only
      final result = map.resolve(sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8');
      expect(result, '+1234567890');
    });

    test('resolve with phone only returns phone', () {
      final map = SignalSenderMap(filePath: filePath);
      final result = map.resolve(sourceNumber: '+1234567890');
      expect(result, '+1234567890');
      expect(map.length, 0);
    });

    test('resolve with neither returns empty string', () {
      final map = SignalSenderMap(filePath: filePath);
      expect(map.resolve(), '');
      expect(map.resolve(sourceNumber: null, sourceUuid: null), '');
      expect(map.resolve(sourceNumber: '', sourceUuid: ''), '');
    });

    test('phone change updates mapping (same UUID, new phone)', () {
      final map = SignalSenderMap(filePath: filePath);
      map.resolve(
        sourceNumber: '+1234567890',
        sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
      );
      map.resolve(
        sourceNumber: '+9876543210',
        sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
      );
      expect(map.length, 1);
      // UUID resolves to new phone
      final result = map.resolve(sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8');
      expect(result, '+9876543210');
    });

    test('invalid E.164 phone not stored', () {
      final map = SignalSenderMap(filePath: filePath);
      final result = map.resolve(
        sourceNumber: 'not-a-phone',
        sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
      );
      // Invalid phone — return UUID since phone is invalid
      expect(result, '12bfcd5a-3363-45f4-94b6-3fe247f11ab8');
      expect(map.length, 0);
    });

    test('invalid UUID not stored', () {
      final map = SignalSenderMap(filePath: filePath);
      final result = map.resolve(
        sourceNumber: '+1234567890',
        sourceUuid: 'not-a-uuid',
      );
      // Valid phone returned, but mapping not stored due to invalid UUID
      expect(result, '+1234567890');
      expect(map.length, 0);
    });

    test('load from valid JSON file', () async {
      final json = jsonEncode({
        'version': 1,
        'mappings': {
          '12bfcd5a-3363-45f4-94b6-3fe247f11ab8': '+1234567890',
          'aaaabbbb-cccc-dddd-eeee-ffffffffffff': '+44771234567',
        },
      });
      File(filePath).writeAsStringSync(json);

      final map = SignalSenderMap(filePath: filePath);
      await map.load();
      expect(map.length, 2);
      expect(
        map.resolve(sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8'),
        '+1234567890',
      );
      expect(
        map.resolve(sourceUuid: 'aaaabbbb-cccc-dddd-eeee-ffffffffffff'),
        '+44771234567',
      );
    });

    test('load from corrupt JSON file logs warning and starts empty', () async {
      File(filePath).writeAsStringSync('not valid json {{{');
      final map = SignalSenderMap(filePath: filePath);
      await map.load();
      expect(map.length, 0);
    });

    test('load from missing file logs warning and starts empty', () async {
      final map = SignalSenderMap(filePath: '${tempDir.path}/nonexistent.json');
      await map.load();
      expect(map.length, 0);
    });

    test('persist writes mappings to JSON file', () async {
      final map = SignalSenderMap(filePath: filePath);
      map.resolve(
        sourceNumber: '+1234567890',
        sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
      );
      // Wait for fire-and-forget persist to complete
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final content = File(filePath).readAsStringSync();
      final json = jsonDecode(content) as Map<String, dynamic>;
      expect(json['version'], 1);
      final mappings = json['mappings'] as Map<String, dynamic>;
      expect(mappings['12bfcd5a-3363-45f4-94b6-3fe247f11ab8'], '+1234567890');
    });

    test('length reflects stored mappings', () {
      final map = SignalSenderMap(filePath: filePath);
      expect(map.length, 0);
      map.resolve(
        sourceNumber: '+1234567890',
        sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
      );
      expect(map.length, 1);
      map.resolve(
        sourceNumber: '+44771234567',
        sourceUuid: 'aaaabbbb-cccc-dddd-eeee-ffffffffffff',
      );
      expect(map.length, 2);
    });

    test('UUID case insensitivity', () {
      final map = SignalSenderMap(filePath: filePath);
      map.resolve(
        sourceNumber: '+1234567890',
        sourceUuid: '12BFCD5A-3363-45F4-94B6-3FE247F11AB8',
      );
      // Lookup with lowercase
      expect(
        map.resolve(sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8'),
        '+1234567890',
      );
    });
  });
}
