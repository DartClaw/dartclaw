import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('CanvasService', () {
    late CanvasService service;

    setUp(() {
      service = CanvasService();
    });

    tearDown(() async {
      await service.dispose();
    });

    test('push updates state and broadcasts canvas_update', () async {
      final stream = service.subscribe('agent:main:web:');
      service.push('agent:main:web:', '<h1>hello</h1>');

      final frame = utf8.decode(await stream.stream.first);
      expect(frame, startsWith('event: canvas_update\n'));
      expect(frame, contains('"html":"<h1>hello</h1>"'));

      final state = service.getState('agent:main:web:');
      expect(state, isNotNull);
      expect(state!.currentHtml, '<h1>hello</h1>');
      expect(state.visible, isFalse);
    });

    test('clear removes current html and broadcasts canvas_clear', () async {
      final stream = service.subscribe('session-a');
      final iterator = StreamIterator(stream.stream.map(utf8.decode));
      addTearDown(iterator.cancel);
      service.push('session-a', '<p>content</p>');
      expect(await iterator.moveNext(), isTrue);

      service.clear('session-a');
      expect(await iterator.moveNext(), isTrue);
      final frame = iterator.current;
      expect(frame, startsWith('event: canvas_clear\n'));

      final state = service.getState('session-a');
      expect(state, isNotNull);
      expect(state!.currentHtml, isNull);
    });

    test('setVisible updates state and broadcasts canvas_visible', () async {
      final stream = service.subscribe('session-a');
      service.setVisible('session-a', true);

      final frame = utf8.decode(await stream.stream.first);
      expect(frame, startsWith('event: canvas_visible\n'));
      expect(frame, contains('"visible":true'));
      expect(service.getState('session-a')!.visible, isTrue);
    });

    test('getState supports late joiners after push', () {
      service.push('session-late', '<div>current</div>');
      final state = service.getState('session-late');
      expect(state, isNotNull);
      expect(state!.currentHtml, '<div>current</div>');
    });

    test('push broadcasts to all subscribers in the same session', () async {
      final one = service.subscribe('shared');
      final two = service.subscribe('shared');
      service.push('shared', '<span>x</span>');

      final oneFrame = utf8.decode(await one.stream.first);
      final twoFrame = utf8.decode(await two.stream.first);
      expect(oneFrame, contains('"html":"<span>x</span>"'));
      expect(twoFrame, contains('"html":"<span>x</span>"'));
    });

    test('createShareToken generates 32-char base64url token and validates', () {
      final token = service.createShareToken(
        'session-token',
        permission: CanvasPermission.interact,
        ttl: const Duration(hours: 1),
      );
      expect(token.token.length, 32);
      expect(RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(token.token), isTrue);
      expect(token.permission, CanvasPermission.interact);
      expect(service.validateShareToken(token.token), isNotNull);
      expect(service.getState('session-token')!.activeTokens, hasLength(1));
    });

    test('validateShareToken returns null for expired token and revokes it', () async {
      final token = service.createShareToken('session-expire', ttl: const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(service.validateShareToken(token.token), isNull);
      expect(service.tokenCount, 0);
    });

    test('revokeShareToken removes token from index and state', () {
      final token = service.createShareToken('session-revoke');
      expect(service.validateShareToken(token.token), isNotNull);

      service.revokeShareToken(token.token);

      expect(service.validateShareToken(token.token), isNull);
      expect(service.getState('session-revoke')!.activeTokens, isEmpty);
    });

    test('broadcast cleans stale closed controllers', () async {
      final live = service.subscribe('session-stale');
      final stale = service.subscribe('session-stale');
      unawaited(stale.close());
      final events = <List<int>>[];
      final liveSub = live.stream.listen(events.add);
      addTearDown(liveSub.cancel);

      service.push('session-stale', '<p>ok</p>');

      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      final frame = utf8.decode(events.single);
      expect(frame, contains('canvas_update'));
      expect(service.viewerCountForSession('session-stale'), 1);
    });

    test('dispose closes active controllers', () async {
      final c1 = service.subscribe('dispose-a');
      final c2 = service.subscribe('dispose-b');
      await service.dispose();
      expect(c1.isClosed, isTrue);
      expect(c2.isClosed, isTrue);
    });

    test('subscribe enforces configured max connections', () {
      final limited = CanvasService(maxConnections: 1);
      addTearDown(limited.dispose);

      limited.subscribe('limited-session');

      expect(() => limited.subscribe('limited-session'), throwsA(isA<StateError>()));
    });
  });
}
