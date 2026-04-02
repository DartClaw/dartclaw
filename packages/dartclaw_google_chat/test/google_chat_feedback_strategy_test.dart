import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGoogleChatRestClient;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:fake_async/fake_async.dart';
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

void main() {
  group('GoogleChatFeedbackStrategy', () {
    test('onToolUse edits the placeholder with tool progress', () async {
      final restClient = FakeGoogleChatRestClient();
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
        final restClient = FakeGoogleChatRestClient();
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
      final restClient = FakeGoogleChatRestClient();
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
      final restClient = FakeGoogleChatRestClient();
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
      final restClient = FakeGoogleChatRestClient();
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
