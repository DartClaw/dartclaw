import 'package:dartclaw_core/dartclaw_core.dart'
    show ChannelNotification, ChannelResponse, ThreadedNotifications, ThreadedPost, threadIdMetadataKey;
import 'package:logging/logging.dart';

import 'slack_markdown.dart';
import 'slack_web_api_client.dart';

/// Slack's limit for the text of one `section` block.
const _maxSectionTextLength = 3000;

final _partialEntity = RegExp(r'&[a-z]{0,3}$');

/// Slack's [ThreadedNotifications]: a thread is a conversation and the `ts` of
/// its first message, and notifications render as Block Kit sections.
///
/// The identity is `'<conversationId>:<thread_ts>'`; Slack channel ids and
/// timestamps contain no `:`, so [_compose] and [_split] are exact inverses.
class SlackThreadedNotifications implements ThreadedNotifications {
  static final _log = Logger('SlackThreadedNotifications');

  final SlackWebApiClient _api;
  final void Function(String conversation, String threadTs) _noteParticipation;

  /// Creates the capability over [api]; every post it makes is reported to
  /// [noteParticipation], so a reply in that thread needs no mention.
  const new({
    required SlackWebApiClient api,
    required void Function(String conversation, String threadTs) noteParticipation,
  }) : _api = api,
       _noteParticipation = noteParticipation;

  @override
  String? extractThread(Map<String, dynamic> metadata) {
    final conversation = metadata['spaceName'];
    final threadTs = metadata[threadIdMetadataKey];
    if (conversation is! String || conversation.isEmpty || threadTs is! String || threadTs.isEmpty) return null;
    return _compose(conversation, threadTs);
  }

  @override
  ChannelResponse render(ChannelNotification notification) {
    final status = notification.status.replaceAll('_', ' ');
    final body = notification.body?.trim();
    final error = notification.error?.trim();
    final facts = [
      for (final entry in notification.facts.entries)
        '*${escapeSlackText(entry.key)}*: ${escapeSlackText(entry.value)}',
    ];
    final sections = [
      '*${escapeSlackText(notification.title)}* – ${escapeSlackText(status)}',
      if (body != null && body.isNotEmpty) escapeSlackText(body),
      if (error != null && error.isNotEmpty) '*Error*: ${escapeSlackText(error)}',
      if (facts.isNotEmpty) facts.join('\n'),
    ];
    return ChannelResponse(
      text: escapeSlackText(notification.text),
      structuredPayload: {
        'blocks': [
          for (final text in sections)
            {
              'type': 'section',
              'text': {'type': 'mrkdwn', 'text': _clip(text)},
            },
        ],
      },
    );
  }

  @override
  Future<ThreadedPost?> sendToNewThread(
    String recipientId,
    ChannelResponse response, {
    required String threadKey,
  }) async {
    final ts = await _post(recipientId, response, threadTs: null);
    return ts == null ? null : ThreadedPost(threadId: _compose(recipientId, ts), messageId: ts);
  }

  @override
  Future<ThreadedPost?> sendToThread(String recipientId, ChannelResponse response, {required String threadId}) async {
    final threadTs = _split(threadId)?.threadTs;
    if (threadTs == null) {
      _log.warning('Not a Slack thread identity: $threadId');
      return null;
    }
    final ts = await _post(recipientId, response, threadTs: threadTs);
    return ts == null ? null : ThreadedPost(threadId: threadId, messageId: ts);
  }

  Future<String?> _post(String recipientId, ChannelResponse response, {required String? threadTs}) async {
    final rawBlocks = response.structuredPayload?['blocks'];
    final blocks = rawBlocks is List
        ? [
            for (final block in rawBlocks)
              if (block is Map) Map<String, dynamic>.from(block),
          ]
        : null;
    try {
      final ts = await _api.postMessage(channel: recipientId, text: response.text, threadTs: threadTs, blocks: blocks);
      if (ts == null) {
        _log.warning('Slack reported no timestamp for a notification posted to $recipientId');
        return null;
      }
      _noteParticipation(recipientId, threadTs ?? ts);
      return ts;
    } on SlackApiException catch (error) {
      _log.warning('Could not post a Slack notification to $recipientId: $error');
      return null;
    }
  }

  static String _compose(String conversation, String threadTs) => '$conversation:$threadTs';

  static ({String conversation, String threadTs})? _split(String threadId) {
    final separator = threadId.indexOf(':');
    if (separator <= 0 || separator == threadId.length - 1) return null;
    return (conversation: threadId.substring(0, separator), threadTs: threadId.substring(separator + 1));
  }

  /// Truncates to Slack's section limit without leaving half an entity behind.
  static String _clip(String text) {
    if (text.length <= _maxSectionTextLength) return text;
    return '${text.substring(0, _maxSectionTextLength - 3).replaceFirst(_partialEntity, '')}...';
  }
}
