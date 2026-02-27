import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('heartbeat_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('HeartbeatScheduler', () {
    test('dispatches HEARTBEAT.md content when present', () async {
      File('${tmpDir.path}/HEARTBEAT.md').writeAsStringSync('- [ ] Check server health');
      final dispatched = <(String, String)>[];

      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: tmpDir.path,
        dispatch: (key, msg) async => dispatched.add((key, msg)),
      );

      await scheduler.runOnce();
      expect(dispatched, hasLength(1));
      expect(dispatched.first.$1, startsWith('agent:main:heartbeat:'));
      expect(dispatched.first.$2, contains('Check server health'));
    });

    test('skips when HEARTBEAT.md missing', () async {
      final dispatched = <(String, String)>[];
      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: tmpDir.path,
        dispatch: (key, msg) async => dispatched.add((key, msg)),
      );

      await scheduler.runOnce();
      expect(dispatched, isEmpty);
    });

    test('skips when HEARTBEAT.md is empty', () async {
      File('${tmpDir.path}/HEARTBEAT.md').writeAsStringSync('   ');
      final dispatched = <(String, String)>[];

      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: tmpDir.path,
        dispatch: (key, msg) async => dispatched.add((key, msg)),
      );

      await scheduler.runOnce();
      expect(dispatched, isEmpty);
    });

    test('dispatch failure does not crash scheduler', () async {
      File('${tmpDir.path}/HEARTBEAT.md').writeAsStringSync('- [ ] task');
      var callCount = 0;

      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: tmpDir.path,
        dispatch: (key, msg) async {
          callCount++;
          throw Exception('dispatch failed');
        },
      );

      // Should not throw
      await scheduler.runOnce();
      expect(callCount, 1);

      // Should still be able to run again
      await scheduler.runOnce();
      expect(callCount, 2);
    });

    test('session keys are unique per run', () async {
      File('${tmpDir.path}/HEARTBEAT.md').writeAsStringSync('- [ ] task');
      final keys = <String>[];

      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: tmpDir.path,
        dispatch: (key, msg) async => keys.add(key),
      );

      await scheduler.runOnce();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await scheduler.runOnce();

      expect(keys, hasLength(2));
      expect(keys[0], isNot(keys[1]));
    });

    test('stop cancels timer', () async {
      File('${tmpDir.path}/HEARTBEAT.md').writeAsStringSync('- [ ] task');
      final dispatched = <String>[];

      final scheduler = HeartbeatScheduler(
        interval: const Duration(milliseconds: 50),
        workspaceDir: tmpDir.path,
        dispatch: (key, msg) async => dispatched.add(key),
      );

      scheduler.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      scheduler.stop();
      final countAtStop = dispatched.length;

      await Future<void>.delayed(const Duration(milliseconds: 120));
      // No new dispatches after stop
      expect(dispatched.length, countAtStop);
    });
  });
}
