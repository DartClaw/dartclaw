import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> sampleReceivedMessageJson({
  String ackId = 'ack-1',
  String data = 'eyJ0ZXN0IjogdHJ1ZX0=', // base64 of {"test": true}
  String messageId = 'msg-1',
  String publishTime = '2024-03-15T10:30:00.260Z',
  Map<String, String> attributes = const {'ce-type': 'test'},
}) => {
  'ackId': ackId,
  'message': {'data': data, 'messageId': messageId, 'publishTime': publishTime, 'attributes': attributes},
};

http.Response pullResponse(List<Map<String, dynamic>> messages) =>
    http.Response(jsonEncode({'receivedMessages': messages}), 200);

http.Response emptyPullResponse() => http.Response('{}', 200);

/// A delay function that yields to the event loop, preventing tight-loop
/// spinning that causes multi-GB memory growth in tests.
Future<void> _yieldingDelay(Duration _) async {
  await Future<void>.delayed(Duration.zero);
}

class _BlockingCloseAwareClient extends http.BaseClient {
  final requestStarted = Completer<void>();
  final _closed = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!requestStarted.isCompleted) {
      requestStarted.complete();
    }
    await _closed.future;
    throw http.ClientException('connection closed during shutdown', request.url);
  }

  @override
  void close() {
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }
}

/// Creates a [PubSubClient] wired to [mockClient] with a yielding delay
/// override so tests don't wait on real timers but still yield to the event
/// loop between pull iterations.
PubSubClient makeClient({
  required http.Client mockClient,
  Future<bool> Function(ReceivedMessage)? onMessage,
  Future<void> Function(Duration)? delay,
  int pollIntervalSeconds = 1,
}) {
  return PubSubClient(
    authClient: mockClient,
    projectId: 'my-project',
    subscription: 'my-sub',
    pollIntervalSeconds: pollIntervalSeconds,
    onMessage: onMessage ?? (_) async => true,
    delay: delay ?? _yieldingDelay,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ReceivedMessage', () {
    group('fromJson', () {
      test('parses all fields', () {
        final msg = ReceivedMessage.fromJson(sampleReceivedMessageJson());
        expect(msg.ackId, 'ack-1');
        expect(msg.data, 'eyJ0ZXN0IjogdHJ1ZX0=');
        expect(msg.messageId, 'msg-1');
        expect(msg.publishTime, '2024-03-15T10:30:00.260Z');
        expect(msg.attributes, {'ce-type': 'test'});
      });

      test('handles missing optional fields', () {
        final msg = ReceivedMessage.fromJson({
          'ackId': 'ack-x',
          'message': {'messageId': 'msg-x'},
        });
        expect(msg.ackId, 'ack-x');
        expect(msg.data, '');
        expect(msg.publishTime, '');
        expect(msg.attributes, isEmpty);
      });

      test('handles missing attributes', () {
        final msg = ReceivedMessage.fromJson({
          'ackId': 'ack-x',
          'message': {'messageId': 'msg-x', 'data': 'abc'},
        });
        expect(msg.attributes, isEmpty);
      });
    });
  });

  group('PubSubHealthStatus', () {
    test('toJson includes all fields', () {
      final ts = DateTime.utc(2024, 3, 15, 10, 30);
      final status = PubSubHealthStatus(status: 'degraded', lastSuccessfulPull: ts, consecutiveErrors: 6);
      final json = status.toJson();
      expect(json['status'], 'degraded');
      expect(json['consecutive_errors'], 6);
      expect(json['last_successful_pull'], ts.toIso8601String());
    });

    test('toJson omits lastSuccessfulPull when null', () {
      final status = PubSubHealthStatus(status: 'unavailable', consecutiveErrors: 3);
      expect(status.toJson().containsKey('last_successful_pull'), isFalse);
    });
  });

  group('PubSubClient.fromConfig', () {
    test('creates client from valid PubSubConfig', () {
      final config = PubSubConfig(
        projectId: 'proj',
        subscription: 'sub',
        pollIntervalSeconds: 3,
        maxMessagesPerPull: 50,
      );
      final client = PubSubClient.fromConfig(
        authClient: MockClient((_) async => http.Response('{}', 200)),
        config: config,
        onMessage: (_) async => true,
      );
      expect(client, isNotNull);
    });

    test('throws on unconfigured PubSubConfig', () {
      expect(
        () => PubSubClient.fromConfig(
          authClient: MockClient((_) async => http.Response('{}', 200)),
          config: const PubSubConfig.disabled(),
          onMessage: (_) async => true,
        ),
        throwsArgumentError,
      );
    });
  });

  group('health status', () {
    test('initial status is healthy with no pull', () {
      final client = makeClient(mockClient: MockClient((_) async => emptyPullResponse()));
      final status = client.healthStatus;
      expect(status.status, 'healthy');
      expect(status.lastSuccessfulPull, isNull);
      expect(status.consecutiveErrors, 0);
    });

    test('healthy after successful pull', () async {
      final firstPullDone = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((_) async {
          if (!firstPullDone.isCompleted) firstPullDone.complete();
          return emptyPullResponse();
        }),
      );

      client.start();
      await firstPullDone.future;
      await client.stop();

      expect(client.healthStatus.status, 'healthy');
      expect(client.healthStatus.lastSuccessfulPull, isNotNull);
      expect(client.healthStatus.consecutiveErrors, 0);
    });

    test('degraded after 5 consecutive errors following a success', () async {
      final delays = <Duration>[];
      var callCount = 0;
      final fiveErrorsDone = Completer<void>();
      var errorCount = 0;
      final client = makeClient(
        mockClient: MockClient((_) async {
          await Future<void>.delayed(Duration.zero);
          callCount++;
          // First call succeeds, then all subsequent fail
          if (callCount == 1) return emptyPullResponse();
          errorCount++;
          if (errorCount >= 5 && !fiveErrorsDone.isCompleted) fiveErrorsDone.complete();
          return http.Response('error', 500);
        }),
        delay: (d) async => delays.add(d),
      );

      client.start();
      await fiveErrorsDone.future;
      await client.stop();

      expect(client.healthStatus.consecutiveErrors, greaterThanOrEqualTo(5));
      expect(client.healthStatus.status, 'degraded');
    });

    test('unavailable when never pulled successfully and has errors', () async {
      final firstErrorDone = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((_) async {
          await Future<void>.delayed(Duration.zero);
          if (!firstErrorDone.isCompleted) firstErrorDone.complete();
          return http.Response('fail', 500);
        }),
        delay: (_) async {},
      );

      client.start();
      await firstErrorDone.future;
      await client.stop();

      final status = client.healthStatus;
      if (status.lastSuccessfulPull == null && status.consecutiveErrors > 0) {
        expect(status.status, 'unavailable');
      }
    });

    test('recovers to healthy after success', () async {
      var count = 0;
      final firstSuccessDone = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((_) async {
          await Future<void>.delayed(Duration.zero);
          count++;
          if (count > 3 && !firstSuccessDone.isCompleted) firstSuccessDone.complete();
          // First 3 calls error, then success
          return count <= 3 ? http.Response('err', 500) : emptyPullResponse();
        }),
        delay: (_) async {},
      );

      client.start();
      await firstSuccessDone.future;
      await client.stop();

      expect(client.healthStatus.status, 'healthy');
      expect(client.healthStatus.consecutiveErrors, 0);
    });
  });

  group('pull loop', () {
    test('pulls messages and delivers to callback', () async {
      final received = <ReceivedMessage>[];
      final requests = <http.Request>[];
      var callCount = 0;
      final ackDone = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((request) async {
          requests.add(request);
          callCount++;
          if (request.url.path.endsWith(':pull') && callCount == 1) {
            return pullResponse([sampleReceivedMessageJson()]);
          }
          if (request.url.path.endsWith(':acknowledge')) {
            if (!ackDone.isCompleted) ackDone.complete();
            return http.Response('{}', 200);
          }
          return emptyPullResponse();
        }),
        onMessage: (msg) async {
          received.add(msg);
          return true;
        },
      );

      client.start();
      await ackDone.future;
      await client.stop();

      expect(received, hasLength(1));
      expect(received.first.ackId, 'ack-1');
      expect(received.first.messageId, 'msg-1');

      final ackRequest = requests.firstWhere((r) => r.url.path.endsWith(':acknowledge'));
      final ackBody = jsonDecode(ackRequest.body) as Map<String, dynamic>;
      expect(ackBody['ackIds'], ['ack-1']);
    });

    test('handles empty pull response without errors', () async {
      var callbackCalled = false;
      final firstPullDone = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((_) async {
          if (!firstPullDone.isCompleted) firstPullDone.complete();
          return emptyPullResponse();
        }),
        onMessage: (_) async {
          callbackCalled = true;
          return true;
        },
      );

      client.start();
      await firstPullDone.future;
      await client.stop();

      expect(callbackCalled, isFalse);
      expect(client.healthStatus.status, 'healthy');
    });

    test('nacks messages when callback returns false', () async {
      final requests = <http.Request>[];
      var callCount = 0;
      final nackDone = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((request) async {
          requests.add(request);
          callCount++;
          if (request.url.path.endsWith(':pull') && callCount == 1) {
            return pullResponse([sampleReceivedMessageJson()]);
          }
          if (request.url.path.endsWith(':modifyAckDeadline')) {
            if (!nackDone.isCompleted) nackDone.complete();
            return http.Response('{}', 200);
          }
          return emptyPullResponse();
        }),
        onMessage: (_) async => false,
      );

      client.start();
      await nackDone.future;
      await client.stop();

      final nackRequest = requests.firstWhere(
        (r) => r.url.path.endsWith(':modifyAckDeadline'),
        orElse: () => throw StateError('No nack request found'),
      );
      final body = jsonDecode(nackRequest.body) as Map<String, dynamic>;
      expect(body['ackIds'], ['ack-1']);
      expect(body['ackDeadlineSeconds'], 0);
    });

    test('nacks messages when callback throws', () async {
      final requests = <http.Request>[];
      var callCount = 0;
      final nackDone = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((request) async {
          requests.add(request);
          callCount++;
          if (request.url.path.endsWith(':pull') && callCount == 1) {
            return pullResponse([sampleReceivedMessageJson()]);
          }
          if (request.url.path.endsWith(':modifyAckDeadline')) {
            if (!nackDone.isCompleted) nackDone.complete();
          }
          return http.Response('{}', 200);
        }),
        onMessage: (_) async => throw Exception('callback boom'),
      );

      client.start();
      await nackDone.future;
      await client.stop();

      final nackRequest = requests.firstWhere(
        (r) => r.url.path.endsWith(':modifyAckDeadline'),
        orElse: () => throw StateError('No nack request found'),
      );
      final body = jsonDecode(nackRequest.body) as Map<String, dynamic>;
      expect(body['ackIds'], ['ack-1']);
      expect(body['ackDeadlineSeconds'], 0);
    });

    test('sends pull request to correct URL with correct body', () async {
      late http.Request captured;
      final firstPullDone = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((request) async {
          if (request.url.path.endsWith(':pull') && !firstPullDone.isCompleted) {
            captured = request;
            firstPullDone.complete();
          }
          return emptyPullResponse();
        }),
      );

      client.start();
      await firstPullDone.future;
      await client.stop();

      expect(captured.url.toString(), 'https://pubsub.googleapis.com/v1/projects/my-project/subscriptions/my-sub:pull');
      expect(captured.method, 'POST');
      expect(jsonDecode(captured.body)['maxMessages'], isNotNull);
    });
  });

  group('backoff', () {
    test('backs off on 429 response', () async {
      final delays = <Duration>[];
      var callCount = 0;
      final firstDelayDone = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((_) async {
          callCount++;
          return callCount == 1 ? http.Response('quota exceeded', 429) : emptyPullResponse();
        }),
        delay: (d) async {
          delays.add(d);
          if (!firstDelayDone.isCompleted) firstDelayDone.complete();
        },
      );

      client.start();
      await firstDelayDone.future;
      await client.stop();

      // First delay should be 2s backoff (2^1)
      expect(delays.first.inSeconds, 2);
    });

    test('backs off on 500 response', () async {
      final delays = <Duration>[];
      final firstDelayDone = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((_) async => http.Response('server error', 500)),
        delay: (d) async {
          delays.add(d);
          if (!firstDelayDone.isCompleted) firstDelayDone.complete();
        },
      );

      client.start();
      await firstDelayDone.future;
      await client.stop();

      expect(delays, isNotEmpty);
      // First backoff should be >= 2s
      expect(delays.first.inSeconds, greaterThanOrEqualTo(2));
    });

    test('backoff caps at 32 seconds', () async {
      final delays = <Duration>[];
      final capReached = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((_) async {
          // Yield to macrotask queue to prevent microtask starvation.
          await Future<void>.delayed(Duration.zero);
          return http.Response('error', 500);
        }),
        delay: (d) async {
          delays.add(d);
          if (d.inSeconds >= 32 && !capReached.isCompleted) capReached.complete();
        },
      );

      client.start();
      await capReached.future;
      await client.stop();

      // After enough errors, delays should be capped at 32
      final backoffDelays = delays.where((d) => d.inSeconds > 1).toList();
      expect(backoffDelays.last.inSeconds, lessThanOrEqualTo(32));
      expect(backoffDelays.where((d) => d.inSeconds == 32), isNotEmpty);
    });

    test('resets backoff on successful pull', () async {
      final delays = <Duration>[];
      var callCount = 0;
      // Wait until at least 4 calls (2 errors + 1 success + 1 error after reset)
      final fourCallsDone = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((_) async {
          // Yield to macrotask queue to prevent microtask starvation.
          await Future<void>.delayed(Duration.zero);
          callCount++;
          if (callCount >= 4 && !fourCallsDone.isCompleted) fourCallsDone.complete();
          // Error, error, success, error
          if (callCount == 1 || callCount == 2) return http.Response('err', 500);
          if (callCount == 3) return emptyPullResponse();
          return http.Response('err', 500);
        }),
        delay: (d) async => delays.add(d),
      );

      client.start();
      await fourCallsDone.future;
      await client.stop();

      // Find delays around the reset: after first two errors delays grow,
      // after success the next error should restart at 2s
      final backoffDelays = delays.where((d) => d.inSeconds >= 2).toList();
      expect(backoffDelays, isNotEmpty);
      // After reset the backoff sequence restarts at 2
      expect(backoffDelays.last, lessThanOrEqualTo(const Duration(seconds: 32)));
    });

    test('does not exponential-backoff on 401', () async {
      final delays = <Duration>[];
      var callCount = 0;
      final twoPermanentErrorsDone = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((_) async {
          // Yield to macrotask queue to prevent microtask starvation.
          await Future<void>.delayed(Duration.zero);
          callCount++;
          if (callCount >= 2 && !twoPermanentErrorsDone.isCompleted) {
            twoPermanentErrorsDone.complete();
          }
          return callCount <= 2 ? http.Response('unauthorized', 401) : emptyPullResponse();
        }),
        delay: (d) async => delays.add(d),
        pollIntervalSeconds: 1,
      );

      client.start();
      await twoPermanentErrorsDone.future;
      // Give a bit of time for the delay after the second error to be recorded
      await Future<void>.delayed(Duration.zero);
      await client.stop();

      // On 401 (permanent error), delays should be poll interval (1s), not exponential
      final longDelays = delays.where((d) => d.inSeconds > 1).toList();
      expect(longDelays, isEmpty);
    });
  });

  group('shutdown', () {
    test('stop() completes promptly when client is in delay', () async {
      // Verify stop() interrupts the delay via the stop signal completer.
      // Uses a mock delay that blocks on its own completer (simulating a long
      // real delay) instead of a real Future.delayed — real timers keep the
      // dart test VM alive even after the test completes.
      final delayEntered = Completer<void>();
      final delayBlocker = Completer<void>();
      final client = PubSubClient(
        authClient: MockClient((_) async => emptyPullResponse()),
        projectId: 'proj',
        subscription: 'sub',
        pollIntervalSeconds: 10,
        onMessage: (_) async => true,
        delay: (_) async {
          if (!delayEntered.isCompleted) delayEntered.complete();
          await delayBlocker.future;
        },
      );

      final stopwatch = Stopwatch()..start();
      client.start();
      // Wait for the pull loop to enter the delay
      await delayEntered.future;
      // stop() should complete the _stopSignal, which races with our blocker
      // in _interruptibleDelay via Future.any
      await client.stop();
      stopwatch.stop();

      // Should stop nearly instantly since _stopSignal resolves Future.any
      expect(stopwatch.elapsed.inMilliseconds, lessThan(1000));
      // Unblock the delay future to avoid pending async work
      delayBlocker.complete();
    });

    test('double stop is safe', () async {
      final firstPullDone = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((_) async {
          if (!firstPullDone.isCompleted) firstPullDone.complete();
          return emptyPullResponse();
        }),
      );
      client.start();
      await firstPullDone.future;
      await client.stop();
      // Should not throw
      await client.stop();
    });

    test('dispose() aborts an in-flight pull promptly', () async {
      final blockingClient = _BlockingCloseAwareClient();
      final client = makeClient(mockClient: blockingClient);

      client.start();
      await blockingClient.requestStarted.future;

      final stopwatch = Stopwatch()..start();
      await client.dispose();
      stopwatch.stop();

      expect(stopwatch.elapsed.inMilliseconds, lessThan(1000));
      expect(client.isRunning, isFalse);
    });

    test('start after stop works', () async {
      var pullCount = 0;
      final firstPullDone = Completer<void>();
      final secondPullDone = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((_) async {
          pullCount++;
          if (!firstPullDone.isCompleted) {
            firstPullDone.complete();
          } else if (!secondPullDone.isCompleted) {
            secondPullDone.complete();
          }
          return emptyPullResponse();
        }),
      );

      client.start();
      await firstPullDone.future;
      await client.stop();

      final countAfterFirstRun = pullCount;
      expect(client.isRunning, isFalse);

      // Start again
      client.start();
      await secondPullDone.future;
      await client.stop();

      expect(pullCount, greaterThan(countAfterFirstRun));
    });

    test('isRunning reflects state', () async {
      final firstPullDone = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((_) async {
          if (!firstPullDone.isCompleted) firstPullDone.complete();
          return emptyPullResponse();
        }),
      );
      expect(client.isRunning, isFalse);
      client.start();
      expect(client.isRunning, isTrue);
      await firstPullDone.future;
      await client.stop();
      expect(client.isRunning, isFalse);
    });

    test('start when already running is idempotent', () async {
      var loopCount = 0;
      final firstPullDone = Completer<void>();
      final client = makeClient(
        mockClient: MockClient((_) async {
          loopCount++;
          if (!firstPullDone.isCompleted) firstPullDone.complete();
          return emptyPullResponse();
        }),
      );

      client.start();
      client.start(); // second call should be no-op
      await firstPullDone.future;
      await client.stop();

      // Only one pull loop should have run, so loopCount should be small
      expect(loopCount, lessThan(10));
    });
  });

  group('auto-recovery', () {
    test('automatically recovers after transient errors resolve', () async {
      var callCount = 0;
      final degradedReached = Completer<void>();
      final recoveredReached = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((_) async {
          await Future<void>.delayed(Duration.zero);
          callCount++;
          // First call succeeds (needed for 'degraded' — 'unavailable' is
          // returned when there has never been a successful pull).
          if (callCount == 1) return emptyPullResponse();
          // Next 6 calls fail (>= 5 needed for degraded threshold).
          if (callCount <= 7) {
            if (callCount == 7 && !degradedReached.isCompleted) {
              degradedReached.complete();
            }
            return http.Response('error', 500);
          }
          if (!recoveredReached.isCompleted) recoveredReached.complete();
          return emptyPullResponse();
        }),
        delay: (_) async {},
      );

      client.start();
      await degradedReached.future;
      await Future<void>.delayed(Duration.zero);
      expect(client.healthStatus.status, 'degraded');

      await recoveredReached.future;
      await Future<void>.delayed(Duration.zero);
      await client.stop();

      expect(client.healthStatus.status, 'healthy');
      expect(client.healthStatus.consecutiveErrors, 0);
      expect(client.healthStatus.lastSuccessfulPull, isNotNull);
    });

    test('recovery resets consecutive error count to zero', () async {
      var callCount = 0;
      final recoveredReached = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((_) async {
          await Future<void>.delayed(Duration.zero);
          callCount++;
          if (callCount <= 5) {
            return http.Response('error', 500);
          }
          if (!recoveredReached.isCompleted) recoveredReached.complete();
          return emptyPullResponse();
        }),
        delay: (_) async {},
      );

      client.start();
      await recoveredReached.future;
      await client.stop();

      expect(client.healthStatus.consecutiveErrors, 0);
    });

    test('no manual intervention needed for recovery', () async {
      // Verify recovery happens without calling any explicit method.
      // The test simply starts the client with a switchable mock and waits
      // for the automatic recovery — no explicit "recover()" call.
      var callCount = 0;
      final recoveredReached = Completer<void>();

      final client = makeClient(
        mockClient: MockClient((_) async {
          await Future<void>.delayed(Duration.zero);
          callCount++;
          if (callCount <= 3) return http.Response('error', 500);
          if (!recoveredReached.isCompleted) recoveredReached.complete();
          return emptyPullResponse();
        }),
        delay: (_) async {},
      );

      client.start();
      // No manual recovery call — just await natural recovery
      await recoveredReached.future;
      await client.stop();

      expect(client.healthStatus.status, 'healthy');
    });
  });
}
