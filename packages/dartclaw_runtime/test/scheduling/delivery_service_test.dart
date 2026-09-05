import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/api/sse_broadcast.dart';
import 'package:dartclaw_runtime/src/scheduling/delivery.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DeliveryService', () {
    late Directory tempDir;
    late String workspaceDir;
    late SessionService sessions;
    late MessageService messages;
    late MemoryFileService memoryFile;
    late SseBroadcast sseBroadcast;
    late List<String> continuityResets;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('delivery-service-test-');
      workspaceDir = p.join(tempDir.path, 'workspace');
      Directory(workspaceDir).createSync(recursive: true);
      sessions = SessionService(baseDir: tempDir.path);
      messages = MessageService(baseDir: tempDir.path);
      memoryFile = MemoryFileService(baseDir: workspaceDir);
      sseBroadcast = SseBroadcast();
      continuityResets = [];
    });

    tearDown(() async {
      await memoryFile.dispose();
      await messages.dispose();
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

    test('announce applies channel formatting and delivers every chunk', () async {
      const signalPeer = 'signal/+46700000000';
      await _createChannelSession(
        sessions,
        SessionKey.dmPerChannelContact(channelType: ChannelType.signal.name, peerId: signalPeer),
      );
      final signal = FakeChannel(
        type: ChannelType.signal,
        ownedJids: {signalPeer},
        responseFormatter: (text) => [
          ChannelResponse(text: 'formatted:$text:1'),
          ChannelResponse(text: 'formatted:$text:2'),
        ],
      );
      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: [signal]);

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-formatted', result: '**scheduled**');

      expect(signal.sentMessages.map((entry) => entry.$2.text), [
        'formatted:**scheduled**:1',
        'formatted:**scheduled**:2',
      ]);
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

    test('announce stops a failed multipart target and continues with later targets', () async {
      const failingPeer = 'dm/contact/partial@s.whatsapp.net';
      const deliveredPeer = 'signal/+46700000002';
      await _createChannelSession(
        sessions,
        SessionKey.dmPerChannelContact(channelType: ChannelType.whatsapp.name, peerId: failingPeer),
      );
      await _createChannelSession(sessions, SessionKey.dmPerContact(peerId: deliveredPeer));
      final failingChannel = _SecondChunkFailureChannel(ownedJids: {failingPeer});
      final signal = FakeChannel(type: ChannelType.signal, ownedJids: {deliveredPeer});
      final service = _makeService(sessions: sessions, sseBroadcast: sseBroadcast, channels: [failingChannel, signal]);

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-partial', result: 'multipart');

      expect(failingChannel.sentMessages.map((entry) => entry.$2.text), ['multipart:1']);
      expect(signal.sentMessages.single.$2.text, 'multipart');
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

    test('announce records the delivered result in every DM session it reached', () async {
      const whatsappPeer = 'dm/contact/one@s.whatsapp.net';
      const signalPeer = 'signal/+46700000000';
      final whatsappSession = await _createChannelSession(
        sessions,
        SessionKey.dmPerChannelContact(channelType: ChannelType.whatsapp.name, peerId: whatsappPeer),
      );
      final signalSession = await _createChannelSession(sessions, SessionKey.dmPerContact(peerId: signalPeer));

      final service = _makeService(
        sessions: sessions,
        sseBroadcast: sseBroadcast,
        channels: [
          FakeChannel(type: ChannelType.whatsapp, ownedJids: {whatsappPeer}),
          FakeChannel(type: ChannelType.signal, ownedJids: {signalPeer}),
        ],
        messages: messages,
        memoryFile: memoryFile,
        resetSessionContinuity: (sessionId) async => continuityResets.add(sessionId),
      );

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-record', result: 'the announced text');

      for (final session in [whatsappSession, signalSession]) {
        final recorded = await messages.getMessages(session.id);
        expect(recorded, hasLength(1), reason: 'session ${session.id} should hold exactly one announce record');
        expect(recorded.single.role, 'assistant');
        expect(recorded.single.content, 'the announced text');
        expect(jsonDecode(recorded.single.metadata!), {'jobId': 'job-record', 'origin': 'announce'});
      }
      expect(continuityResets, unorderedEquals([whatsappSession.id, signalSession.id]));
    });

    test('announce records nothing for a target whose send failed', () async {
      const failingPeer = 'dm/contact/fail@s.whatsapp.net';
      const deliveredPeer = 'signal/+46700000001';
      final failingSession = await _createChannelSession(
        sessions,
        SessionKey.dmPerChannelContact(channelType: ChannelType.whatsapp.name, peerId: failingPeer),
      );
      final deliveredSession = await _createChannelSession(sessions, SessionKey.dmPerContact(peerId: deliveredPeer));

      final service = _makeService(
        sessions: sessions,
        sseBroadcast: sseBroadcast,
        channels: [
          FakeChannel(type: ChannelType.whatsapp, ownedJids: {failingPeer})..throwOnSend = true,
          FakeChannel(type: ChannelType.signal, ownedJids: {deliveredPeer}),
        ],
        messages: messages,
        memoryFile: memoryFile,
        resetSessionContinuity: (sessionId) async => continuityResets.add(sessionId),
      );

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-failed-send', result: 'best effort');

      expect(await messages.getMessages(failingSession.id), isEmpty);
      expect(await messages.getMessages(deliveredSession.id), hasLength(1));
      expect(continuityResets, [deliveredSession.id]);
    });

    test('an SSE-only announce records no message and no daily-log entry', () async {
      final service = _makeService(
        sessions: sessions,
        sseBroadcast: sseBroadcast,
        channels: const [],
        messages: messages,
        memoryFile: memoryFile,
        resetSessionContinuity: (sessionId) async => continuityResets.add(sessionId),
      );

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-sse-only', result: 'nobody reachable');

      expect(continuityResets, isEmpty);
      expect(await _readDailyLog(workspaceDir), isNull);
    });

    test('a busy session continuity reset leaves the record and the delivery standing', () async {
      const peerId = 'signal/+46700000003';
      final session = await _createChannelSession(sessions, SessionKey.dmPerContact(peerId: peerId));
      final signal = FakeChannel(type: ChannelType.signal, ownedJids: {peerId});
      final service = _makeService(
        sessions: sessions,
        sseBroadcast: sseBroadcast,
        channels: [signal],
        messages: messages,
        memoryFile: memoryFile,
        resetSessionContinuity: (sessionId) async => throw BusyTurnException('turn in progress', isSameSession: true),
      );

      await service.deliver(mode: DeliveryMode.announce, jobId: 'job-busy', result: 'delivered anyway');

      expect(signal.sentMessages, hasLength(1));
      expect(await messages.getMessages(session.id), hasLength(1));
      expect(await _readDailyLog(workspaceDir), contains('Announce: job-busy'));
    });

    test('announce appends one redacted daily-log record per fire', () async {
      const whatsappPeer = 'dm/contact/one@s.whatsapp.net';
      const signalPeer = 'signal/+46700000004';
      await _createChannelSession(
        sessions,
        SessionKey.dmPerChannelContact(channelType: ChannelType.whatsapp.name, peerId: whatsappPeer),
      );
      await _createChannelSession(sessions, SessionKey.dmPerContact(peerId: signalPeer));

      final service = _makeService(
        sessions: sessions,
        sseBroadcast: sseBroadcast,
        channels: [
          FakeChannel(type: ChannelType.whatsapp, ownedJids: {whatsappPeer}),
          FakeChannel(type: ChannelType.signal, ownedJids: {signalPeer}),
        ],
        messages: messages,
        memoryFile: memoryFile,
        redactor: MessageRedactor(extraPatterns: ['TOPSECRETVALUE']),
      );

      await service.deliver(
        mode: DeliveryMode.announce,
        jobId: 'job-log',
        result: 'summary with TOPSECRETVALUE inside',
      );

      final log = await _readDailyLog(workspaceDir);
      expect(log, isNotNull);
      expect(RegExp(r'^## \d{2}:\d{2} — "Announce: job-log"$', multiLine: true).allMatches(log!), hasLength(1));
      expect(log, contains('**User**: "(scheduled)"'));
      expect(log, contains('**Tools**: []'));
      expect(log, contains('TOPSECR***'));
      expect(log, isNot(contains('TOPSECRETVALUE')));
    });

    test('webhook and none deliveries record nothing', () async {
      const peerId = 'signal/+46700000005';
      final session = await _createChannelSession(sessions, SessionKey.dmPerContact(peerId: peerId));
      final signal = FakeChannel(type: ChannelType.signal, ownedJids: {peerId});
      final service = _makeService(
        sessions: sessions,
        sseBroadcast: sseBroadcast,
        channels: [signal],
        messages: messages,
        memoryFile: memoryFile,
        resetSessionContinuity: (sessionId) async => continuityResets.add(sessionId),
      );

      await service.deliver(mode: DeliveryMode.none, jobId: 'job-none', result: 'ignore me');
      await service.deliver(
        mode: DeliveryMode.webhook,
        jobId: 'job-webhook',
        result: 'posted elsewhere',
        webhookUrl: 'http://127.0.0.1:1/hook',
      );

      expect(await messages.getMessages(session.id), isEmpty);
      expect(continuityResets, isEmpty);
      expect(await _readDailyLog(workspaceDir), isNull);
    });
  });
}

class _SecondChunkFailureChannel extends FakeChannel {
  new({required super.ownedJids})
    : super(
        type: ChannelType.whatsapp,
        responseFormatter: (text) => [
          ChannelResponse(text: '$text:1'),
          ChannelResponse(text: '$text:2'),
          ChannelResponse(text: '$text:3'),
        ],
      );

  var _sendCount = 0;

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    _sendCount += 1;
    if (_sendCount == 2) throw StateError('second chunk failed');
    await super.sendMessage(recipientJid, response);
  }
}

DeliveryService _makeService({
  required SessionService sessions,
  required SseBroadcast sseBroadcast,
  required List<Channel> channels,
  MessageService? messages,
  MemoryFileService? memoryFile,
  MessageRedactor? redactor,
  Future<void> Function(String sessionId)? resetSessionContinuity,
}) {
  final manager = ChannelManager(
    queue: MessageQueue(
      dispatcher: (sessionKey, message, {required channelType, senderJid, senderDisplayName, groupJid}) async => 'ok',
    ),
    config: const ChannelConfig.defaults(),
  );
  for (final channel in channels) {
    manager.registerChannel(channel);
  }
  addTearDown(manager.dispose);
  return DeliveryService(
    channelManager: manager,
    sseBroadcast: sseBroadcast,
    sessions: sessions,
    messages: messages,
    memoryFile: memoryFile,
    redactor: redactor,
    resetSessionContinuity: resetSessionContinuity,
  );
}

Future<Session> _createChannelSession(SessionService sessions, String channelKey) {
  return sessions.getOrCreateByKey(channelKey, type: SessionType.channel);
}

Future<String?> _readDailyLog(String workspaceDir) async {
  final now = DateTime.now();
  final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final file = File(p.join(workspaceDir, 'memory', '$date.md'));
  return file.existsSync() ? file.readAsString() : null;
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
