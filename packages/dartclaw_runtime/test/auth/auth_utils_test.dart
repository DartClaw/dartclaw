import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, FailedAuthEvent;
import 'package:dartclaw_runtime/src/auth/auth_rate_limiter.dart';
import 'package:dartclaw_runtime/src/auth/auth_utils.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'auth_test_support.dart';

void main() {
  group('readBounded', () {
    test('returns body under the limit', () async {
      final request = Request('POST', Uri.parse('http://localhost/test'), body: 'hello');
      expect(await readBounded(request, 10), 'hello');
    });

    test('returns body at the limit', () async {
      final request = Request(
        'POST',
        Uri.parse('http://localhost/test'),
        body: 'hello',
        headers: {'content-length': '5'},
      );
      expect(await readBounded(request, 5), 'hello');
    });

    test('returns null when content-length exceeds limit', () async {
      final request = Request(
        'POST',
        Uri.parse('http://localhost/test'),
        body: 'hello!',
        headers: {'content-length': '6'},
      );
      expect(await readBounded(request, 5), isNull);
    });

    test('returns empty body when request is empty', () async {
      final request = Request('POST', Uri.parse('http://localhost/test'), body: '');
      expect(await readBounded(request, 1), '');
    });

    test('returns null when streamed body exceeds exact boundary', () async {
      final request = Request('POST', Uri.parse('http://localhost/test'), body: 'hello!');
      expect(await readBounded(request, 5), isNull);
    });
  });

  group('requestRemoteKey', () {
    test('uses socket address when no trusted proxies configured', () {
      final request = authRequest(
        socketAddress: '192.168.1.50',
        headers: {'x-forwarded-for': '1.2.3.4'},
        path: '/test',
      );

      expect(requestRemoteKey(request), '192.168.1.50');
    });

    test('uses forwarded-for when connecting IP is trusted proxy', () {
      final request = authRequest(
        socketAddress: '192.168.1.100',
        headers: {'x-forwarded-for': '10.0.0.1, 10.0.0.2'},
        path: '/test',
      );

      expect(requestRemoteKey(request, trustedProxies: const ['192.168.1.100']), '10.0.0.1');
    });

    test('ignores forwarded-for when connecting IP is not in trusted list', () {
      final request = authRequest(
        socketAddress: '192.168.1.50',
        headers: {'x-forwarded-for': '1.2.3.4'},
        path: '/test',
      );

      expect(requestRemoteKey(request, trustedProxies: const ['192.168.1.100']), '192.168.1.50');
    });
  });

  group('recordFailedAuth', () {
    late EventBus eventBus;
    late List<FailedAuthEvent> events;
    late StreamSubscription<FailedAuthEvent> subscription;

    setUp(() {
      eventBus = EventBus();
      events = [];
      subscription = eventBus.on<FailedAuthEvent>().listen(events.add);
    });

    tearDown(() async {
      await subscription.cancel();
      await eventBus.dispose();
    });

    Response? fail(AuthRateLimiter? limiter) => recordFailedAuth(
      authRequest(socketAddress: '192.168.1.50', path: '/test'),
      source: 'unit',
      reason: 'bad_credential',
      rateLimiter: limiter,
      eventBus: eventBus,
    );

    test('answers null while under the budget and records each failure against the remote address', () async {
      final limiter = AuthRateLimiter(maxAttempts: 2);

      expect([fail(limiter), fail(limiter)], [null, null]);
      await pumpEventQueue();

      expect(events.map((e) => (e.source, e.reason, e.path, e.remoteKey, e.limited)), [
        ('unit', 'bad_credential', '/test', '192.168.1.50', false),
        ('unit', 'bad_credential', '/test', '192.168.1.50', false),
      ]);
      expect(limiter.shouldLimit('192.168.1.50'), isTrue);
    });

    test('answers 429 with the shared JSON body once the budget is spent, and stops counting', () async {
      final limiter = AuthRateLimiter(maxAttempts: 1);
      fail(limiter);

      final limited = fail(limiter)!;
      await pumpEventQueue();

      expect(limited.statusCode, 429);
      expect(limited.headers['content-type'], 'application/json');
      expect(jsonDecode(await limited.readAsString()), {
        'error': 'Too Many Requests',
        'message': 'Too many failed authentication attempts',
      });
      expect(events.map((e) => e.limited), [false, true]);
      limiter.reset('192.168.1.50');
      expect(limiter.shouldLimit('192.168.1.50'), isFalse, reason: 'the refused attempt was not recorded');
    });

    test('without a limiter the failure is reported and never limited', () async {
      expect([fail(null), fail(null), fail(null)], [null, null, null]);
      await pumpEventQueue();

      expect(events, hasLength(3));
    });
  });
}
