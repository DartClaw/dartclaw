import 'dart:io';

import 'package:dartclaw_server/src/behavior/heartbeat_scheduler.dart';
import 'package:dartclaw_server/src/workspace/workspace_git_sync.dart';
import 'package:test/test.dart';

Future<WorkspaceGitSync> _recordingGitSync(String workspaceDir, List<List<String>> calls) async {
  final sync = WorkspaceGitSync(
    workspaceDir: workspaceDir,
    commandRunner: (executable, arguments, {workingDirectory}) async {
      calls.add(arguments);
      if (arguments.first == 'remote') {
        return ProcessResult(0, 1, '', 'No remote');
      }
      return ProcessResult(0, 0, '', '');
    },
  );
  await sync.isGitAvailable();
  return sync;
}

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

    test('skips dispatch but still syncs when HEARTBEAT.md is missing', () async {
      final dispatched = <(String, String)>[];
      final gitCalls = <List<String>>[];
      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: tmpDir.path,
        dispatch: (key, msg) async => dispatched.add((key, msg)),
        gitSync: await _recordingGitSync(tmpDir.path, gitCalls),
      );

      await scheduler.runOnce();
      expect(dispatched, isEmpty);
      expect(gitCalls.map((call) => call.first), contains('status'));
    });

    test('skips dispatch but still syncs when HEARTBEAT.md is empty', () async {
      File('${tmpDir.path}/HEARTBEAT.md').writeAsStringSync('   ');
      final dispatched = <(String, String)>[];
      final gitCalls = <List<String>>[];

      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: tmpDir.path,
        dispatch: (key, msg) async => dispatched.add((key, msg)),
        gitSync: await _recordingGitSync(tmpDir.path, gitCalls),
      );

      await scheduler.runOnce();
      expect(dispatched, isEmpty);
      expect(gitCalls.map((call) => call.first), contains('status'));
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
        interval: const Duration(milliseconds: 100),
        workspaceDir: tmpDir.path,
        dispatch: (key, msg) async => dispatched.add(key),
      );

      scheduler.start();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      scheduler.stop();
      final countAtStop = dispatched.length;
      expect(countAtStop, greaterThanOrEqualTo(1));

      await Future<void>.delayed(const Duration(milliseconds: 300));
      // No new dispatches after stop
      expect(dispatched.length, countAtStop);
    });
  });
}
