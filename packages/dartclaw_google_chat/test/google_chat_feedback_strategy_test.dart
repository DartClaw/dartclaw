import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _FakeChannel extends Channel {
  final List<(String recipientJid, ChannelResponse response)> sentMessages = [];

  @override
  String get name => 'fake-google-chat';

  @override
  ChannelType get type => ChannelType.googlechat;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  List<ChannelResponse> formatResponse(String text) => [ChannelResponse(text: text)];

  @override
  bool ownsJid(String jid) => jid.startsWith('spaces/');

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    sentMessages.add((recipientJid, response));
  }
}

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  final List<(String messageName, String text)> editedMessages = [];
  final List<(String spaceName, String text)> sentMessages = [];

  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  @override
  Future<bool> editMessage(String messageName, String newText) async {
    editedMessages.add((messageName, newText));
    return true;
  }

  @override
  Future<String?> sendMessage(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
  }) async {
    sentMessages.add((spaceName, text));
    return 'spaces/AAA/messages/generated-placeholder';
  }
}

void main() {
  group('GoogleChatFeedbackStrategy', () {
    test('onToolUse edits the placeholder with tool progress', () async {
      final restClient = _FakeGoogleChatRestClient();
      final strategy = GoogleChatFeedbackStrategy(restClient: restClient);
      final context = FeedbackContext(
        channel: _FakeChannel(),
        recipientJid: 'spaces/AAA',
        inboundMessageId: 'spaces/AAA/messages/original',
      );
      context.placeholderMessageId = 'spaces/AAA/messages/placeholder';

      await strategy.onToolUse(
        context: context,
        snapshot: TurnProgressSnapshot(
          elapsed: const Duration(seconds: 10),
          toolCallCount: 1,
          lastToolName: 'bash',
          accumulatedTokens: 128,
          textLength: 0,
        ),
        toolName: 'bash',
      );

      expect(restClient.editedMessages, hasLength(1));
      expect(restClient.editedMessages.single.$1, 'spaces/AAA/messages/placeholder');
      expect(restClient.editedMessages.single.$2.toLowerCase(), contains('bash'));
    });

    test('throttles placeholder edits inside the one-second window', () {
      fakeAsync((async) {
        final restClient = _FakeGoogleChatRestClient();
        var now = DateTime.utc(2026, 3, 26, 12);
        final strategy = GoogleChatFeedbackStrategy(restClient: restClient, now: () => now);
        final context = FeedbackContext(
          channel: _FakeChannel(),
          recipientJid: 'spaces/AAA',
          inboundMessageId: 'spaces/AAA/messages/original',
        );
        context.placeholderMessageId = 'spaces/AAA/messages/placeholder';

        unawaited(
          strategy.onToolUse(
            context: context,
            snapshot: TurnProgressSnapshot(
              elapsed: const Duration(seconds: 5),
              toolCallCount: 1,
              lastToolName: 'bash',
              accumulatedTokens: 64,
              textLength: 0,
            ),
            toolName: 'bash',
          ),
        );
        async.flushMicrotasks();
        expect(restClient.editedMessages, hasLength(1));

        now = now.add(const Duration(milliseconds: 500));
        unawaited(
          strategy.onStatusTick(
            context: context,
            snapshot: TurnProgressSnapshot(
              elapsed: const Duration(seconds: 20),
              toolCallCount: 1,
              lastToolName: 'bash',
              accumulatedTokens: 96,
              textLength: 0,
            ),
          ),
        );
        async.flushMicrotasks();

        expect(restClient.editedMessages, hasLength(1));
      });
    });

    test('status ticks vary across elapsed-time buckets', () async {
      final restClient = _FakeGoogleChatRestClient();
      var now = DateTime.utc(2026, 3, 26, 12);
      final strategy = GoogleChatFeedbackStrategy(
        restClient: restClient,
        now: () {
          final current = now;
          now = now.add(const Duration(seconds: 2));
          return current;
        },
      );
      final context = FeedbackContext(
        channel: _FakeChannel(),
        recipientJid: 'spaces/AAA',
        inboundMessageId: 'spaces/AAA/messages/original',
      );
      context.placeholderMessageId = 'spaces/AAA/messages/placeholder';

      await strategy.onStatusTick(
        context: context,
        snapshot: TurnProgressSnapshot(
          elapsed: const Duration(seconds: 45),
          toolCallCount: 1,
          lastToolName: 'search',
          accumulatedTokens: 64,
          textLength: 0,
        ),
      );
      await strategy.onStatusTick(
        context: context,
        snapshot: TurnProgressSnapshot(
          elapsed: const Duration(seconds: 90),
          toolCallCount: 2,
          lastToolName: 'bash',
          accumulatedTokens: 128,
          textLength: 0,
        ),
      );
      await strategy.onStatusTick(
        context: context,
        snapshot: TurnProgressSnapshot(
          elapsed: const Duration(seconds: 150),
          toolCallCount: 3,
          lastToolName: 'write_file',
          accumulatedTokens: 256,
          textLength: 0,
        ),
      );

      expect(restClient.editedMessages, hasLength(3));
      expect(restClient.editedMessages.map((entry) => entry.$2).toSet(), hasLength(3));
    });

    test('onTurnCompleted returns true when a placeholder exists', () async {
      final restClient = _FakeGoogleChatRestClient();
      final strategy = GoogleChatFeedbackStrategy(restClient: restClient);
      final context = FeedbackContext(
        channel: _FakeChannel(),
        recipientJid: 'spaces/AAA',
        inboundMessageId: 'spaces/AAA/messages/original',
      );
      context.placeholderMessageId = 'spaces/AAA/messages/placeholder';

      final result = await strategy.onTurnCompleted(context: context, responseText: 'Final answer');

      expect(result, isTrue);
      expect(restClient.editedMessages, hasLength(1));
      expect(restClient.editedMessages.single.$2, contains('Final answer'));
    });

    test('onTurnCompleted returns false when no placeholder exists', () async {
      final restClient = _FakeGoogleChatRestClient();
      final strategy = GoogleChatFeedbackStrategy(restClient: restClient);
      final context = FeedbackContext(
        channel: _FakeChannel(),
        recipientJid: 'spaces/AAA',
        inboundMessageId: 'spaces/AAA/messages/original',
      );

      final result = await strategy.onTurnCompleted(context: context, responseText: 'Final answer');

      expect(result, isFalse);
      expect(restClient.editedMessages, isEmpty);
    });
  });
}
