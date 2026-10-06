import 'package:dartclaw_core/dartclaw_core.dart'
    show ChannelNotification, ChannelNotificationKind, ChannelResponse, ThreadedNotifications, ThreadedPost;
import 'package:logging/logging.dart';

import 'chat_card_builder.dart';
import 'google_chat_rest_client.dart' show GoogleChatRestClient;
import 'google_chat_utils.dart';

/// Google Chat's [ThreadedNotifications]: threads are named by the server
/// (`spaces/X/threads/Y`), and notifications render as Cards v2.
class GoogleChatThreadedNotifications implements ThreadedNotifications {
  static final _log = Logger('GoogleChatThreadedNotifications');

  final GoogleChatRestClient _restClient;
  final ChatCardBuilder _cards;

  /// Creates the capability over [restClient] and [cards].
  const new(this._restClient, {ChatCardBuilder cards = const ChatCardBuilder()}) : _cards = cards;

  @override
  String? extractThread(Map<String, dynamic> metadata) {
    final threadName = metadata['threadName'];
    return threadName is String && threadName.isNotEmpty ? threadName : null;
  }

  @override
  ChannelResponse render(ChannelNotification notification) {
    try {
      final card = switch (notification.kind) {
        ChannelNotificationKind.task => _cards.taskNotification(
          taskId: notification.id,
          title: notification.title,
          status: notification.status,
          description: notification.body,
          errorSummary: notification.error,
          requestedBy: notification.requestedBy,
          createdAt: notification.createdAt,
          updatedAt: notification.updatedAt,
          includeReviewButtons: notification.reviewActions,
        ),
        ChannelNotificationKind.run => _cards.runNotification(
          runId: notification.id,
          title: notification.title,
          status: notification.status,
          facts: notification.facts,
          body: notification.body,
          errorSummary: notification.error,
        ),
      };
      return ChannelResponse(text: notification.text, structuredPayload: card);
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to build Google Chat card for ${notification.kind.name} ${notification.id}',
        error,
        stackTrace,
      );
      return ChannelResponse(text: notification.text);
    }
  }

  @override
  Future<ThreadedPost?> sendToNewThread(String recipientId, ChannelResponse response, {required String threadKey}) =>
      _send(recipientId, response, threadKey: threadKey);

  @override
  Future<ThreadedPost?> sendToThread(String recipientId, ChannelResponse response, {required String threadId}) =>
      _send(recipientId, response, threadName: threadId);

  /// Sends the card, then the plain text when the card is refused.
  Future<ThreadedPost?> _send(
    String recipientId,
    ChannelResponse response, {
    String? threadKey,
    String? threadName,
  }) async {
    final card = response.structuredPayload;
    if (card != null) {
      final sent = await _restClient.send(
        spaceName: recipientId,
        card: card,
        threadKey: threadKey,
        threadName: threadName,
      );
      if (sent.messageName != null) {
        return _post(sent);
      }
      _log.warning('Google Chat threaded card send failed for $recipientId, falling back to plain text');
    }

    final text = outboundFallbackText(response);
    if (text.isEmpty) {
      return null;
    }
    return _post(
      await _restClient.send(spaceName: recipientId, text: text, threadKey: threadKey, threadName: threadName),
    );
  }

  ThreadedPost? _post(({String? messageName, String? threadName, bool usedQuotedMessageMetadata}) sent) {
    final messageName = sent.messageName;
    final threadName = sent.threadName;
    if (messageName == null || threadName == null) {
      return null;
    }
    return ThreadedPost(threadId: threadName, messageId: messageName);
  }
}
