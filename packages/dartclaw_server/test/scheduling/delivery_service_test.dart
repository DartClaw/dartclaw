import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/api/sse_broadcast.dart';
import 'package:dartclaw_server/src/scheduling/delivery.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('DeliveryService', () {
    late Directory tempDir;
    late SessionService sessions;
    late SseBroadcast sseBroadcast;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('delivery-service-test-');
      sessions = SessionService(baseDir: tempDir.path);
      sseBroadcast = SseBroadcast();
    });

    tearDown(() async {
      await sseBroadcast.dispose();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('announce broadcasts to SSE clients', () async {
      final controller = sseBroadcast.subscribe();
      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: const []);

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-1', result: 'scheduled summary');

      final frame = await _nextSseFrame(controller);
      expect(frame, isNotNull);
      expect(frame, startsWith('event: announce\n'));

      final dataLine = frame!.split('\n').firstWhere((line) => line.startsWith('data: '));
      final payload = jsonDecode(dataLine.substring(6)) as Map<String, dynamic>;
      expect(payload['jobId'], 'job-1');
      expect(payload['result'], 'scheduled summary');
      expect(DateTime.parse(payload['timestamp'] as String), isA<DateTime>());
    });

    test('announce sends to DM contacts on active channels', () async {
      const whatsappPeer = 'dm/contact/one@s.whatsapp.net';
      const signalPeer = 'signal/+46700000000';

      await _createChannelSession(
        sessions,
        SessionKey.dmPerChannelContact(channelType: ChannelType.whatsapp.name, peerId: whatsappPeer),
      );
      await _createChannelSession(sessions, SessionKey.dmPerContact(peerId: signalPeer));

      final whatsapp = FakeChannel(type: ChannelType.whatsapp, ownedJids: {whatsappPeer});
      final signal = FakeChannel(type: ChannelType.signal, ownedJids: {signalPeer});
      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: [whatsapp, signal]);

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-2', result: 'hello channels');

      expect(whatsapp.sentMessages, hasLength(1));
      expect(whatsapp.sentMessages.single.$1, whatsappPeer);
      expect(whatsapp.sentMessages.single.$2.text, 'hello channels');

      expect(signal.sentMessages, hasLength(1));
      expect(signal.sentMessages.single.$1, signalPeer);
      expect(signal.sentMessages.single.$2.text, 'hello channels');
    });

    test('announce skips dmShared sessions with no peerId', () async {
      await _createChannelSession(sessions, SessionKey.dmShared());

      final whatsapp = FakeChannel(type: ChannelType.whatsapp, ownedJids: {'dm/contact/one@s.whatsapp.net'});
      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: [whatsapp]);

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-3', result: 'hello');

      expect(whatsapp.sentMessages, isEmpty);
    });

    test('announce handles channel sendMessage failure gracefully', () async {
      const failingPeer = 'dm/contact/fail@s.whatsapp.net';
      const deliveredPeer = 'signal/+46700000001';

      await _createChannelSession(
        sessions,
        SessionKey.dmPerChannelContact(channelType: ChannelType.whatsapp.name, peerId: failingPeer),
      );
      await _createChannelSession(sessions, SessionKey.dmPerContact(peerId: deliveredPeer));

      final failingChannel = FakeChannel(type: ChannelType.whatsapp, ownedJids: {failingPeer})..throwOnSend = true;
      final signal = FakeChannel(type: ChannelType.signal, ownedJids: {deliveredPeer});
      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: [failingChannel, signal]);

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-4', result: 'best effort');

      expect(failingChannel.sentMessages, isEmpty);
      expect(signal.sentMessages, hasLength(1));
      expect(signal.sentMessages.single.$1, deliveredPeer);
      expect(signal.sentMessages.single.$2.text, 'best effort');
    });

    test('announce works with no channels registered', () async {
      await _createChannelSession(
        sessions,
        SessionKey.dmPerChannelContact(channelType: ChannelType.whatsapp.name, peerId: 'dm/contact/one@s.whatsapp.net'),
      );

      final controller = sseBroadcast.subscribe();
      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: const []);

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-5', result: 'sse only');

      final frame = await _nextSseFrame(controller);
      expect(frame, isNotNull);
      expect(frame, contains('event: announce'));
    });

    test('announce works with no active DM sessions', () async {
      await _createChannelSession(
        sessions,
        SessionKey.groupShared(channelType: ChannelType.whatsapp.name, groupId: 'groups/room-1'),
      );

      final whatsapp = FakeChannel(type: ChannelType.whatsapp, ownedJids: {'groups/room-1'});
      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: [whatsapp]);

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-6', result: 'group only');

      expect(whatsapp.sentMessages, isEmpty);
    });

    test('webhook delivery unchanged', () async {
      final receivedPayload = Completer<Map<String, dynamic>>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      unawaited(
        server.listen((request) async {
          final body = await utf8.decoder.bind(request).join();
          receivedPayload.complete(jsonDecode(body) as Map<String, dynamic>);
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
        }).asFuture<void>(),
      );

      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: const []);
      await service.deliver(
        mode: DeliveryMode.webhook,
        jobId: 'job-7',
        result: 'webhook body',
        webhookUrl: 'http://${server.address.host}:${server.port}/hook',
      );

      final payload = await receivedPayload.future.timeout(const Duration(seconds: 1));
      expect(payload['job_id'], 'job-7');
      expect(payload['result'], 'webhook body');
      expect(DateTime.parse(payload['timestamp'] as String), isA<DateTime>());
    });

    test('none delivery unchanged', () async {
      const peerId = 'dm/contact/none@s.whatsapp.net';
      await _createChannelSession(
        sessions,
        SessionKey.dmPerChannelContact(channelType: ChannelType.whatsapp.name, peerId: peerId),
      );

      final controller = sseBroadcast.subscribe();
      final whatsapp = FakeChannel(type: ChannelType.whatsapp, ownedJids: {peerId});
      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: [whatsapp]);

      await service.deliver(mode: DeliveryMode.none, jobId: 'job-8', result: 'ignore me');

      expect(whatsapp.sentMessages, isEmpty);
      expect(await _nextSseFrame(controller), isNull);
    });
  });
}

DeliveryService _makeService({
  required SessionService sessions,
  required SseBroadcast sseBroadcast,
  required List<Channel> channels,
}) {
  final manager = ChannelManager(
    queue: MessageQueue(dispatcher: (sessionKey, message, {senderJid}) async => 'ok'),
    config: const ChannelConfig.defaults(),
  );
  for (final channel in channels) {
    manager.registerChannel(channel);
  }
  addTearDown(manager.dispose);
  return DeliveryService(channelManager: manager, sseBroadcast: sseBroadcast, sessions: sessions);
}

Future<void> _createChannelSession(SessionService sessions, String channelKey) async {
  await sessions.getOrCreateByKey(channelKey, type: SessionType.channel);
}

Future<String?> _nextSseFrame(StreamController<List<int>> controller) async {
  final queue = StreamQueue(controller.stream);
  try {
    final hasNext = await queue.hasNext.timeout(const Duration(milliseconds: 150), onTimeout: () => false);
    if (!hasNext) {
      return null;
    }
    return utf8.decode(await queue.next);
  } finally {
    await queue.cancel(immediate: true);
  }
}
