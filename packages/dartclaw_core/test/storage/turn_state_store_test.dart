import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('TurnStateStore', () {
    late Directory tempDir;
    late File stateFile;
    late TurnStateStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('turn-state-store-');
      stateFile = File(p.join(tempDir.path, 'turn_state.json'));
      store = openTurnStateStore(stateFile.path);
    });

    tearDown(() async {
      await store.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('set and getAll round-trip', () async {
      final later = DateTime.parse('2026-03-15T09:45:00Z');
      final earlier = DateTime.parse('2026-03-15T09:30:00Z');
      await store.set('session-z', 'turn-old', earlier);
      await store.set('session-a', 'turn-a', earlier);
      await store.set('session-z', 'turn-new', later);
      await store.delete('session-a');
      await store.set('session-b', 'turn-b', earlier);

      final states = await store.getAll();
      expect(states.keys, ['session-b', 'session-z']);
      expect(states['session-z'], (turnId: 'turn-new', startedAt: later));
    });

    test('getAll reads the file on every call and sees another instance', () async {
      final other = openTurnStateStore(stateFile.path);
      addTearDown(other.dispose);
      await other.set('session-2', 'turn-2', DateTime.parse('2026-03-15T09:30:00Z'));
      expect((await store.getAll())['session-2']?.turnId, 'turn-2');
    });

    test('set is durable before its returned future is awaited', () {
      store.set('session-1', 'turn-1', DateTime.parse('2026-03-15T09:30:00Z'));
      final disk = jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
      expect((disk['session-1'] as Map<String, dynamic>)['turnId'], 'turn-1');
    });

    test('open removes abandoned target temp files only', () async {
      await store.dispose();
      File('${stateFile.path}.deadbeef.tmp').writeAsStringSync('partial');
      final unrelated = File(p.join(tempDir.path, 'other.tmp'))..writeAsStringSync('keep');
      store = openTurnStateStore(stateFile.path);
      expect(File('${stateFile.path}.deadbeef.tmp').existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
    });

    test('open quarantines invalid JSON, warns once, and continues empty', () async {
      await store.dispose();
      stateFile.writeAsStringSync(r'{"session":');
      final warnings = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen((record) {
        if (record.level >= Level.WARNING && record.loggerName == 'TurnStateStore') warnings.add(record);
      });
      addTearDown(subscription.cancel);
      store = openTurnStateStore(stateFile.path);

      final quarantined = tempDir
          .listSync()
          .whereType<File>()
          .where((file) => p.basename(file.path).startsWith('turn_state.json.corrupt-'))
          .toList();
      expect(quarantined, hasLength(1));
      expect(warnings, hasLength(1));
      expect(warnings.single.message, contains(quarantined.single.path));
      expect(await store.getAll(), isEmpty);
      await store.set('session-1', 'turn-1', DateTime.parse('2026-03-15T09:30:00Z'));
      expect((await store.getAll())['session-1']?.turnId, 'turn-1');
    });

    test('post-open unreadable state returns failed futures from operations', () async {
      stateFile.deleteSync();
      Directory(stateFile.path).createSync();
      await expectLater(store.getAll(), throwsA(isA<FileSystemException>()));
      await expectLater(
        store.set('session-1', 'turn-1', DateTime.parse('2026-03-15T09:30:00Z')),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(store.delete('session-1'), throwsA(isA<FileSystemException>()));
    });

    test('dispose is a no-op and the store remains usable', () async {
      await store.dispose();
      await store.set('session-1', 'turn-1', DateTime.parse('2026-03-15T09:30:00Z'));
      expect((await store.getAll())['session-1']?.turnId, 'turn-1');
    });
  });
}
