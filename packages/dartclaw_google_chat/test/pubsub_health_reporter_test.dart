import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('PubSubHealthReporter', () {
    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    http.Response pullResponse({List<Map<String, dynamic>> messages = const []}) {
      return http.Response(
        jsonEncode({'receivedMessages': messages}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    http.Response errorResponse(int status) => http.Response('{"error":"transient"}', status);

    /// Yielding delay that prevents tight-loop spinning while staying fast.
    Future<void> yieldingDelay(Duration _) async {
      await Future<void>.delayed(Duration.zero);
    }

    PubSubClient makeClient(
      MockClient httpClient, {
      int pollIntervalSeconds = 1,
      Future<void> Function(Duration)? delay,
    }) {
      return PubSubClient(
        authClient: httpClient,
        projectId: 'my-project',
        subscription: 'my-sub',
        pollIntervalSeconds: pollIntervalSeconds,
        onMessage: (_) async => true,
        delay: delay ?? yieldingDelay,
      );
    }

    // ---------------------------------------------------------------------------
    // disabled (not configured)
    // ---------------------------------------------------------------------------

    group('disabled (not configured)', () {
      test('returns disabled status when not enabled', () {
        final reporter = PubSubHealthReporter(enabled: false);
        final status = reporter.getStatus();
        expect(status['status'], 'disabled');
        expect(status['enabled'], false);
        expect(status.containsKey('consecutive_errors'), isFalse);
        expect(status.containsKey('last_successful_pull'), isFalse);
      });

      test('disabled map is JSON-serializable', () {
        final reporter = PubSubHealthReporter(enabled: false);
        expect(() => jsonEncode(reporter.getStatus()), returnsNormally);
      });
    });

    // ---------------------------------------------------------------------------
    // enabled but client not started
    // ---------------------------------------------------------------------------

    group('enabled but client not started', () {
      test('returns unavailable when client is null', () {
        final reporter = PubSubHealthReporter(enabled: true, subscriptionCount: () => 2);
        final status = reporter.getStatus();
        expect(status['status'], 'unavailable');
        expect(status['enabled'], true);
        expect(status['active_subscriptions'], 2);
      });

      test('returns zero subscription count when callback is also null', () {
        final reporter = PubSubHealthReporter(enabled: true);
        final status = reporter.getStatus();
        expect(status['active_subscriptions'], 0);
      });
    });

    // ---------------------------------------------------------------------------
    // enabled with running client
    // ---------------------------------------------------------------------------

    group('enabled with running client', () {
      late PubSubClient client;
      late MockClient httpClient;

      tearDown(() async {
        await client.stop();
        httpClient.close();
      });

      test('returns healthy status after successful pull', () async {
        final firstPullDone = Completer<void>();
        httpClient = MockClient((_) async {
          if (!firstPullDone.isCompleted) firstPullDone.complete();
          return pullResponse();
        });
        client = makeClient(httpClient);
        client.start();
        await firstPullDone.future;
        // Yield so _pullLoop finishes processing and updates health status.
        await Future<void>.delayed(Duration.zero);

        final reporter = PubSubHealthReporter(client: client, enabled: true);
        final status = reporter.getStatus();
        expect(status['status'], 'healthy');
        expect(status['enabled'], true);
        expect(status.containsKey('last_successful_pull'), isTrue);
        expect(status['consecutive_errors'], 0);
      });

      test('returns degraded after 5 consecutive errors following a success', () async {
        // degraded requires a prior success — unavailable is returned when
        // there has never been a successful pull.
        var callCount = 0;
        final fiveErrorsDone = Completer<void>();
        var errorCount = 0;
        httpClient = MockClient((_) async {
          await Future<void>.delayed(Duration.zero);
          callCount++;
          // First call succeeds, then all subsequent fail.
          if (callCount == 1) return pullResponse();
          errorCount++;
          if (errorCount >= 5 && !fiveErrorsDone.isCompleted) {
            fiveErrorsDone.complete();
          }
          return errorResponse(500);
        });
        client = makeClient(httpClient);
        client.start();
        await fiveErrorsDone.future;
        await Future<void>.delayed(Duration.zero);

        final reporter = PubSubHealthReporter(client: client, enabled: true);
        final status = reporter.getStatus();
        expect(status['status'], 'degraded');
        expect(status['consecutive_errors'], greaterThanOrEqualTo(5));
      });

      test('returns unavailable when never successfully pulled and has errors', () async {
        final firstErrorDone = Completer<void>();
        httpClient = MockClient((_) async {
          await Future<void>.delayed(Duration.zero);
          if (!firstErrorDone.isCompleted) firstErrorDone.complete();
          return errorResponse(500);
        });
        client = makeClient(httpClient);
        client.start();
        await firstErrorDone.future;
        await Future<void>.delayed(Duration.zero);

        final reporter = PubSubHealthReporter(client: client, enabled: true);
        final status = reporter.getStatus();
        // Before 5 errors, never-pulled client with errors is 'unavailable'
        expect(status['status'], 'unavailable');
        expect(status.containsKey('last_successful_pull'), isFalse);
      });

      test('recovers to healthy after transient failures', () async {
        var callCount = 0;
        final recoveredDone = Completer<void>();
        httpClient = MockClient((_) async {
          await Future<void>.delayed(Duration.zero);
          callCount++;
          if (callCount <= 3) return errorResponse(500);
          if (!recoveredDone.isCompleted) recoveredDone.complete();
          return pullResponse();
        });
        client = makeClient(httpClient);
        client.start();
        await recoveredDone.future;
        await Future<void>.delayed(Duration.zero);

        final reporter = PubSubHealthReporter(client: client, enabled: true);
        final status = reporter.getStatus();
        expect(status['status'], 'healthy');
        expect(status['consecutive_errors'], 0);
        expect(status.containsKey('last_successful_pull'), isTrue);
      });

      test('includes active subscription count from callback', () async {
        final firstPullDone = Completer<void>();
        httpClient = MockClient((_) async {
          if (!firstPullDone.isCompleted) firstPullDone.complete();
          return pullResponse();
        });
        client = makeClient(httpClient);
        client.start();
        await firstPullDone.future;
        await Future<void>.delayed(Duration.zero);

        final reporter = PubSubHealthReporter(client: client, subscriptionCount: () => 5, enabled: true);
        final status = reporter.getStatus();
        expect(status['active_subscriptions'], 5);
      });

      test('handles subscription count callback exception gracefully', () async {
        final firstPullDone = Completer<void>();
        httpClient = MockClient((_) async {
          if (!firstPullDone.isCompleted) firstPullDone.complete();
          return pullResponse();
        });
        client = makeClient(httpClient);
        client.start();
        await firstPullDone.future;
        await Future<void>.delayed(Duration.zero);

        final reporter = PubSubHealthReporter(
          client: client,
          subscriptionCount: () => throw StateError('manager disposed'),
          enabled: true,
        );
        final status = reporter.getStatus();
        expect(status['active_subscriptions'], 0);
      });
    });

    // ---------------------------------------------------------------------------
    // toJson serialization
    // ---------------------------------------------------------------------------

    group('toJson serialization', () {
      test('last_successful_pull is ISO 8601 UTC string', () async {
        final firstPullDone = Completer<void>();
        final httpClient = MockClient((_) async {
          if (!firstPullDone.isCompleted) firstPullDone.complete();
          return http.Response(
            jsonEncode({'receivedMessages': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = PubSubClient(
          authClient: httpClient,
          projectId: 'p',
          subscription: 's',
          onMessage: (_) async => true,
          delay: yieldingDelay,
        );
        client.start();
        await firstPullDone.future;
        await Future<void>.delayed(Duration.zero);

        final reporter = PubSubHealthReporter(client: client, enabled: true);
        final status = reporter.getStatus();
        final lastPull = status['last_successful_pull'] as String?;
        expect(lastPull, isNotNull);
        // Should be parseable as ISO 8601 UTC
        expect(() => DateTime.parse(lastPull!), returnsNormally);
        expect(lastPull!.endsWith('Z'), isTrue);

        await client.stop();
        httpClient.close();
      });

      test('all values are JSON-serializable', () {
        final reporter = PubSubHealthReporter(enabled: true, subscriptionCount: () => 3);
        expect(() => jsonEncode(reporter.getStatus()), returnsNormally);
      });

      test('all values are JSON-serializable when disabled', () {
        final reporter = PubSubHealthReporter(enabled: false);
        expect(() => jsonEncode(reporter.getStatus()), returnsNormally);
      });
    });
  });
}
