import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:test/test.dart';

void main() {
  group('SignalCliManager', () {
    test('baseUrl constructed from host and port', () {
      final mgr = SignalCliManager(executable: 'signal-cli', host: '0.0.0.0', port: 9090, phoneNumber: '+1');
      expect(mgr.baseUrl, 'http://0.0.0.0:9090');
    });

    test('default baseUrl uses port 8080', () {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      expect(mgr.baseUrl, 'http://127.0.0.1:8080');
    });

    test('isRunning is false initially', () {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      expect(mgr.isRunning, isFalse);
    });

    test('start spawns process with correct args', () async {
      late String capturedExe;
      late List<String> capturedArgs;

      final mgr = SignalCliManager(
        executable: '/usr/local/bin/signal-cli',
        host: '0.0.0.0',
        port: 9090,
        phoneNumber: '+1234567890',
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

      expect(capturedExe, '/usr/local/bin/signal-cli');
      expect(capturedArgs, ['daemon', '--http', '0.0.0.0:9090', '--receive-mode', 'on-connection']);
    });

    test('start throws when already stopped', () async {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      await mgr.stop();
      expect(() => mgr.start(), throwsStateError);
    });

    test('start rethrows process spawn failure', () async {
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          throw ProcessException('signal-cli', args, 'not found');
        },
      );

      expect(() => mgr.start(), throwsA(isA<ProcessException>()));
    });

    test('stop reaps the signal-cli process', () async {
      final proc = FakeProcess(completeExitOnKill: true);
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          return proc;
        },
        delay: (d) => Future.value(),
        healthProbe: () async => true,
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
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) => spawn.future,
        healthProbe: () async => true,
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
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      await mgr.stop();
      // Should not throw
      await mgr.stop();
    });

    test('dispose aliases stop', () async {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      await mgr.dispose();
      expect(mgr.isRunning, isFalse);
    });

    test('startup timeout kills process before throwing', () async {
      final proc = FakeProcess(completeExitOnKill: true);
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
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
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
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
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
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
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          spawnCount++;
          return FakeProcess(completeExitOnKill: true);
        },
        delay: (_) async {},
        healthProbe: () async => true,
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
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) => spawn.future,
        healthProbe: () async => true,
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

    test('requestVoiceVerification sends register RPC with voice flag', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestHandled = Completer<void>();
      late String requestPath;
      late Map<String, dynamic> payload;

      final sub = server.listen((request) {
        unawaited(() async {
          requestPath = request.uri.path;
          payload = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': payload['id'], 'result': null}));
          await request.response.close();
          requestHandled.complete();
        }());
      });

      try {
        final mgr = SignalCliManager(
          executable: 'signal-cli',
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          phoneNumber: '+1',
        );

        await mgr.requestVoiceVerification(captcha: 'captcha-token');
        await requestHandled.future;

        expect(requestPath, '/api/v1/rpc');
        expect(payload['method'], 'register');
        expect(payload['params'], {'account': '+1', 'voice': true, 'captcha': 'captcha-token'});
      } finally {
        await sub.cancel();
        await server.close(force: true);
      }
    });

    test('verifySmsCode activates registration and reconnects the receive stream', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var sseConnections = 0;
      final sub = server.listen((request) {
        unawaited(() async {
          if (request.uri.path == '/api/v1/events') {
            sseConnections++;
            request.response.headers.contentType = ContentType('text', 'event-stream');
            request.response.write(': connected\n\n');
            await request.response.flush();
            return;
          }

          final payload = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': payload['id'], 'result': null}));
          await request.response.close();
        }());
      });

      final mgr = SignalCliManager(
        executable: 'signal-cli',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        phoneNumber: '+12125550100',
        delay: (_) async {},
      );
      addTearDown(() async {
        await mgr.stop();
        await sub.cancel();
        await server.close(force: true);
      });

      await mgr.verifySmsCode('123-456');
      await pumpEventQueue(times: 10);

      expect(mgr.wasPaired, isTrue);
      expect(mgr.registeredPhone, '+12125550100');
      expect(sseConnections, 1);
    });

    test('finishLink refreshes receiving and selects the linked account for sending', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstSse = Completer<HttpResponse>();
      final secondSse = Completer<HttpResponse>();
      final thirdSse = Completer<void>();
      final rpcMethods = <String>[];
      String? sendAccount;
      var sseConnections = 0;
      final sub = server.listen((request) {
        unawaited(() async {
          if (request.uri.path == '/api/v1/events') {
            sseConnections++;
            request.response.headers.contentType = ContentType('text', 'event-stream');
            switch (sseConnections) {
              case 1:
                request.response.write(': connected\n\n');
                await request.response.flush();
                firstSse.complete(request.response);
                return;
              case 2:
                secondSse.complete(request.response);
                return;
              case 3:
                request.response.write(
                  'data: ${jsonEncode({
                    'params': {
                      'envelope': {'sourceNumber': '+12125550101'},
                    },
                  })}\n\n',
                );
                await request.response.close();
                thirdSse.complete();
                return;
              default:
                request.response.write(': connected\n\n');
                await request.response.flush();
                return;
            }
          }

          final payload = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
          final method = payload['method'] as String;
          rpcMethods.add(method);
          if (method == 'send') {
            sendAccount = (payload['params'] as Map<String, dynamic>)['account'] as String?;
          }
          final result = switch (method) {
            'startLink' => {'deviceLinkUri': 'sgnl://linkdevice?uuid=test'},
            'finishLink' => {'number': '+12125550100'},
            _ => null,
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': payload['id'], 'result': result}));
          await request.response.close();
        }());
      });

      final mgr = SignalCliManager(
        executable: 'signal-cli',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        phoneNumber: '+19999999999',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async =>
            FakeProcess(completeExitOnKill: true),
        delay: (_) async {},
        healthProbe: () async => true,
      );
      addTearDown(() async {
        await mgr.stop();
        await sub.cancel();
        await server.close(force: true);
      });

      await mgr.start();
      final firstResponse = await firstSse.future.timeout(const Duration(seconds: 2));
      final event = mgr.events.first;
      await firstResponse.close();
      final delayedResponse = await secondSse.future.timeout(const Duration(seconds: 2));

      expect(await mgr.getLinkDeviceUri(), 'sgnl://linkdevice?uuid=test');
      for (var i = 0; i < 20 && !mgr.wasPaired; i++) {
        await pumpEventQueue(times: 1);
      }
      expect(mgr.wasPaired, isTrue);

      delayedResponse.write(': connected\n\n');
      await delayedResponse.flush();
      await thirdSse.future.timeout(const Duration(seconds: 2));
      await mgr.sendMessage('+12125550102', 'reply');

      expect(sseConnections, greaterThanOrEqualTo(3));
      expect(rpcMethods, ['startLink', 'finishLink', 'send']);
      expect(sendAccount, '+12125550100');
      expect(await event.timeout(const Duration(seconds: 2)), {
        'envelope': {'sourceNumber': '+12125550101'},
      });
    });

    test('events stream is broadcast', () {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      // Should allow multiple listeners without error
      mgr.events.listen((_) {});
      mgr.events.listen((_) {});
    });
  });
}
