import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:test/test.dart';

Future<Map<String, dynamic>> _capturePost(Future<void> Function(GowaManager manager) invoke) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final captured = Completer<Map<String, dynamic>>();
  final subscription = server.listen((request) {
    unawaited(() async {
      if (request.uri.path == '/devices') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'status': true,
            'code': 200,
            'message': 'ok',
            'results': [
              {'id': 'device-1'},
            ],
          }),
        );
        await request.response.close();
        return;
      }
      final payload = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      captured.complete({'path': request.uri.path, 'deviceId': request.headers.value('X-Device-Id'), ...payload});
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'status': true, 'code': 200, 'message': 'ok', 'results': {}}));
      await request.response.close();
    }());
  });

  try {
    final manager = GowaManager(
      executable: 'whatsapp',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      healthProbe: () async => true,
    );
    await manager.start();
    try {
      await invoke(manager);
      return await captured.future;
    } finally {
      await manager.reset();
    }
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}

void main() {
  group('GowaManager', () {
    for (final scenario in [
      (name: 'starts DM typing', jid: '12125550101@s.whatsapp.net', isTyping: true),
      (name: 'stops group typing', jid: '120363000000000000@g.us', isTyping: false),
    ]) {
      test('${scenario.name} with the GOWA chat-presence contract', () async {
        final payload = await _capturePost(
          (manager) => manager.sendChatPresence(scenario.jid, isTyping: scenario.isTyping),
        );

        expect(payload, {
          'path': '/send/chat-presence',
          'deviceId': 'device-1',
          'phone': scenario.jid,
          'action': scenario.isTyping ? 'start' : 'stop',
        });
      });
    }

    test('chat presence times out when GOWA never completes its response body', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) {
        unawaited(() async {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"status":true,"code":200,"results":');
          await request.response.flush();
        }());
      });
      final manager = GowaManager(
        executable: 'whatsapp',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });

      await expectLater(
        manager.sendChatPresence('12125550101@s.whatsapp.net', isTyping: true),
        throwsA(isA<TimeoutException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('raw response handling provisions after an empty list and preserves HTTP failures', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      final subscription = server.listen((request) {
        unawaited(() async {
          requests.add('${request.method} ${request.uri.path}');
          if (request.method == 'GET' && request.uri.path == '/devices') {
            await request.response.close();
            return;
          }
          if (request.method == 'POST' && request.uri.path == '/devices') {
            await utf8.decoder.bind(request).join();
            request.response.write(
              jsonEncode({
                'results': {'id': 'created-device'},
              }),
            );
            await request.response.close();
            return;
          }
          request.response
            ..statusCode = HttpStatus.serviceUnavailable
            ..write('temporarily unavailable');
          await request.response.close();
        }());
      });
      final manager = GowaManager(
        executable: 'whatsapp',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        healthProbe: () async => true,
      );
      addTearDown(() async {
        await manager.reset();
        await subscription.cancel();
        await server.close(force: true);
      });

      await manager.start();

      expect(requests, ['GET /devices', 'POST /devices']);
      await expectLater(
        manager.status(),
        throwsA(
          isA<HttpException>().having(
            (error) => error.message,
            'message',
            contains('GOWA /app/status returned 503: temporarily unavailable'),
          ),
        ),
      );
    });

    test('start adopts healthy existing service without spawning', () async {
      var spawned = false;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          spawned = true;
          return FakeProcess(completeExitOnKill: true);
        },
        healthProbe: () async => true,
      );

      await mgr.start();

      expect(spawned, isFalse);
      expect(mgr.isRunning, isTrue);

      await mgr.stop();
      expect(mgr.isRunning, isFalse);
    });

    test('start spawns process with correct args (rest subcommand, --db-uri, --webhook)', () async {
      late String capturedExe;
      late List<String> capturedArgs;

      final mgr = GowaManager(
        executable: '/usr/local/bin/whatsapp',
        host: '0.0.0.0',
        port: 5000,
        dbUri: '/data/wa.db',
        webhookUrl: 'http://localhost:3333/webhook/whatsapp?secret=abc',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedExe = exe;
          capturedArgs = args;
          return FakeProcess(completeExitOnKill: true);
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails (no real server)
      }

      expect(capturedExe, '/usr/local/bin/whatsapp');
      expect(capturedArgs, [
        'rest',
        '--host',
        '0.0.0.0',
        '--port',
        '5000',
        '--os',
        'DartClaw',
        '--db-uri',
        '/data/wa.db',
        '--webhook=http://localhost:3333/webhook/whatsapp?secret=abc',
      ]);
    });

    test('start without dbUri omits --db-uri flag', () async {
      late List<String> capturedArgs;

      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = args;
          return FakeProcess(completeExitOnKill: true);
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails
      }

      expect(capturedArgs, contains('rest'));
      expect(capturedArgs, containsAllInOrder(['--host', '127.0.0.1', '--port', '3000']));
      expect(capturedArgs, isNot(contains('--db-uri')));
    });

    test('start without webhookUrl omits --webhook flag', () async {
      late List<String> capturedArgs;

      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = args;
          return FakeProcess(completeExitOnKill: true);
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails
      }

      expect(capturedArgs, isNot(contains(startsWith('--webhook'))));
    });

    test('start throws when already stopped', () async {
      final mgr = GowaManager(executable: 'whatsapp');
      await mgr.stop(); // sets _stopped = true
      expect(() => mgr.start(), throwsStateError);
    });

    test('start rethrows process spawn failure', () async {
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          throw ProcessException('whatsapp', args, 'not found');
        },
      );

      expect(() => mgr.start(), throwsA(isA<ProcessException>()));
    });

    test('stop reaps the GOWA process', () async {
      final proc = FakeProcess(completeExitOnKill: true);
      var healthProbeCalls = 0;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          return proc;
        },
        delay: (d) => Future.value(),
        healthProbe: () async => healthProbeCalls++ > 0,
      );

      await mgr.start();

      expect(proc.killCalled, isFalse);
      await mgr.stop();
      expect(proc.killCalled, isTrue);
      expect(await proc.exitCode, 0);
      expect(mgr.isRunning, isFalse);
    });

    test('stop waits for an in-flight start and reaps the spawned process', () async {
      final spawn = Completer<Process>();
      final proc = FakeProcess(completeExitOnKill: true);
      var healthProbeCalls = 0;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) => spawn.future,
        healthProbe: () async => healthProbeCalls++ > 0,
      );

      final start = mgr.start();
      await pumpEventQueue(times: 1);
      final stop = mgr.stop();
      spawn.complete(proc);

      await expectLater(start, throwsStateError);
      await stop;
      expect(proc.killCalled, isTrue);
      expect(mgr.isRunning, isFalse);
    });

    test('stop on already-stopped manager is a no-op', () async {
      final mgr = GowaManager(executable: 'whatsapp');
      await mgr.stop();
      // Should not throw
      await mgr.stop();
    });

    test('dispose aliases stop', () async {
      final mgr = GowaManager(executable: 'whatsapp');
      await mgr.dispose();
      expect(mgr.isRunning, isFalse);
    });

    test('startup timeout kills process before throwing', () async {
      final proc = FakeProcess(completeExitOnKill: true);
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          return proc;
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      expect(proc.killCalled, isFalse);
      await expectLater(() => mgr.start(), throwsStateError);
      expect(proc.killCalled, isTrue);
    });

    test('startup timeout escalates a POSIX child and releases confirmed ownership', () async {
      final proc = FakeProcess();
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => proc,
        delay: (d) => Future.value(),
        healthProbe: () async => false,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
        terminationGracePeriod: Duration.zero,
      );

      final start = mgr.start();
      for (var i = 0; i < 10 && proc.killSignals.length < 2; i++) {
        await pumpEventQueue(times: 1);
      }
      expect(proc.killSignals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      proc.exit(137);

      await expectLater(start, throwsStateError);
      expect(mgr.isRunning, isFalse);
    });

    test('startup timeout releases a confirmed Windows root', () async {
      final proc = FakeProcess(completeExitOnKill: true);
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => proc,
        delay: (d) => Future.value(),
        healthProbe: () async => false,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        terminationGracePeriod: Duration.zero,
      );

      await expectLater(mgr.start(), throwsStateError);
      expect(proc.killSignals, [ProcessSignal.sigterm]);
      expect(mgr.isRunning, isFalse);

      await mgr.stop();
      expect(proc.killSignals, [ProcessSignal.sigterm]);
      expect(mgr.isRunning, isFalse);
      await mgr.stop();
      expect(proc.killSignals, [ProcessSignal.sigterm]);
    });

    test('reset does not restart the intentionally terminated process', () async {
      var spawnCount = 0;
      var healthProbeCalls = 0;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          spawnCount++;
          return FakeProcess(completeExitOnKill: true);
        },
        delay: (_) async {},
        healthProbe: () async => (++healthProbeCalls).isEven,
      );

      await mgr.start();
      await mgr.reset();
      await pumpEventQueue(times: 20);

      expect(spawnCount, 1);
      expect(mgr.restartCount, 0);
    });

    test('queued reset releases the confirmed Windows root', () async {
      final spawn = Completer<Process>();
      final proc = FakeProcess(completeExitOnKill: true);
      var healthProbeCalls = 0;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) => spawn.future,
        healthProbe: () async => (++healthProbeCalls).isEven,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        terminationGracePeriod: Duration.zero,
      );

      final start = mgr.start();
      await pumpEventQueue(times: 1);
      final reset = mgr.reset();
      spawn.complete(proc);

      await start;
      await reset;
      expect(mgr.isRunning, isFalse);
    });
  });
}
