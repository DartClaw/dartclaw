import 'package:dartclaw_core/dartclaw_core.dart'
    show Channel, ChannelManager, ChannelResponse, ChannelType, DmAccessController, MentionGating, chunkText;
import 'package:logging/logging.dart';

import 'google_chat_config.dart';
import 'google_chat_rest_client.dart' show GoogleChatRestClient, messageNamePattern;

/// Channel adapter that delivers DartClaw responses to Google Chat spaces.
class GoogleChatChannel extends Channel {
  static final _log = Logger('GoogleChatChannel');

  @override
  final String name = 'googlechat';

  @override
  final ChannelType type = ChannelType.googlechat;

  /// Parsed Google Chat runtime configuration.
  final GoogleChatConfig config;

  /// Authenticated REST client used for outbound Google Chat API calls.
  final GoogleChatRestClient restClient;

  /// Optional DM access controller for one-to-one spaces.
  final DmAccessController? dmAccess;

  /// Optional mention-gating helper for group spaces.
  final MentionGating? mentionGating;
  final ChannelManager? _channelManager;
  final Map<String, String> _pendingPlaceholders = {};
  final Map<String, String> _pendingReactions = {};

  /// Creates a Google Chat channel adapter.
  GoogleChatChannel({
    required this.config,
    required this.restClient,
    ChannelManager? channelManager,
    this.dmAccess,
    this.mentionGating,
  }) : _channelManager = channelManager;

  /// Channel manager used to route normalized inbound messages, if attached.
  ChannelManager? get channelManager => _channelManager;

  @override
  Future<void> connect() async {
    _log.info('Starting Google Chat channel');
    await restClient.testConnection();
    _log.info('Google Chat API credentials verified');
    _log.info('Google Chat channel connected');
  }

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    if (response.mediaAttachments.isNotEmpty) {
      _log.warning('Outbound Google Chat media is not supported in 0.8');
    }

    final replyToMessageId = response.replyToMessageId;
    final quotedMessageName =
        config.quoteReply && replyToMessageId != null && messageNamePattern.hasMatch(replyToMessageId)
        ? replyToMessageId
        : null;
    final placeholderKey = replyToMessageId == null ? null : _placeholderKey(recipientJid, replyToMessageId);
    final pendingReaction = placeholderKey == null ? null : _pendingReactions.remove(placeholderKey);
    if (pendingReaction != null) {
      await restClient.removeReaction(pendingReaction);
    }

    final structuredPayload = response.structuredPayload;
    final fallbackText = _fallbackText(response);
    final placeholder = placeholderKey == null ? null : _pendingPlaceholders[placeholderKey];
    if (structuredPayload != null) {
      final name = await restClient.sendCard(recipientJid, structuredPayload, quotedMessageName: quotedMessageName);
      if (name != null) {
        if (placeholderKey != null) {
          _pendingPlaceholders.remove(placeholderKey);
          if (placeholder != null && quotedMessageName != null) {
            final deleted = await restClient.deleteMessage(placeholder);
            if (!deleted) {
              _log.warning('Failed to delete typing placeholder for $recipientJid after quoted card reply');
            }
          }
        }
        return;
      }
      _log.warning('Google Chat card send failed for $recipientJid, falling back to plain text');
    }

    if (fallbackText.isEmpty) {
      return;
    }

    if (quotedMessageName != null && structuredPayload == null) {
      final name = await restClient.sendMessage(recipientJid, fallbackText, quotedMessageName: quotedMessageName);
      if (name != null) {
        if (placeholderKey != null) {
          _pendingPlaceholders.remove(placeholderKey);
          if (placeholder != null) {
            final deleted = await restClient.deleteMessage(placeholder);
            if (!deleted) {
              _log.warning('Failed to delete typing placeholder for $recipientJid after quoted reply');
            }
          }
        }
        return;
      }
      _log.warning('Google Chat quoted reply send failed for $recipientJid, falling back to unquoted text');
    }

    final removedPlaceholder = placeholderKey == null ? null : _pendingPlaceholders.remove(placeholderKey);
    if (removedPlaceholder != null) {
      final updated = await restClient.editMessage(removedPlaceholder, fallbackText);
      if (updated) {
        return;
      }
      _log.warning('Failed to replace typing placeholder for $recipientJid, falling back to new message');
    }

    await restClient.sendMessage(recipientJid, fallbackText, quotedMessageName: quotedMessageName);
  }

  /// Sends a notification [response] to [recipientJid] in a new or existing
  /// thread identified by [threadKey].
  ///
  /// Returns the server-assigned thread name from the API response, or `null`
  /// if the send failed. The thread name can be stored as a [ThreadBinding]
  /// to route subsequent inbound messages from that thread to the task session.
  Future<String?> sendMessageWithThread(
    String recipientJid,
    ChannelResponse response, {
    required String threadKey,
  }) async {
    final structuredPayload = response.structuredPayload;
    final fallbackText = _fallbackText(response);

    if (structuredPayload != null) {
      final result = await restClient.sendCardInThread(recipientJid, structuredPayload, threadKey: threadKey);
      if (result.messageName != null) {
        return result.threadName;
      }
      _log.warning('Google Chat threaded card send failed for $recipientJid, falling back to plain text');
    }

    if (fallbackText.isEmpty) {
      return null;
    }

    final result = await restClient.sendMessageInThread(recipientJid, fallbackText, threadKey: threadKey);
    return result.threadName;
  }

  /// Sends a notification [response] to [recipientJid] in an existing
  /// server-assigned thread named [threadName].
  Future<void> sendMessageToThreadName(
    String recipientJid,
    ChannelResponse response, {
    required String threadName,
  }) async {
    final structuredPayload = response.structuredPayload;
    final fallbackText = _fallbackText(response);

    if (structuredPayload != null) {
      final name = await restClient.sendCardToThread(recipientJid, structuredPayload, threadName: threadName);
      if (name != null) {
        return;
      }
      _log.warning('Google Chat thread-name card send failed for $recipientJid, falling back to plain text');
    }

    if (fallbackText.isEmpty) {
      return;
    }

    await restClient.sendMessageToThread(recipientJid, fallbackText, threadName: threadName);
  }

  /// Associates a pending typing placeholder with an outbound turn id.
  void setPlaceholder({required String spaceName, required String turnId, required String messageName}) {
    _pendingPlaceholders[_placeholderKey(spaceName, turnId)] = messageName;
  }

  /// Associates a pending emoji reaction with an outbound turn id.
  void setReaction({required String spaceName, required String turnId, required String reactionName}) {
    _pendingReactions[_placeholderKey(spaceName, turnId)] = reactionName;
  }

  @override
  bool ownsJid(String jid) => jid.startsWith('spaces/');

  @override
  List<ChannelResponse> formatResponse(String text) {
    final chunks = chunkText(text.trimLeft(), maxSize: 4000);
    return [for (final chunk in chunks) ChannelResponse(text: chunk)];
  }

  @override
  Future<void> disconnect() async {
    _log.info('Disconnecting Google Chat channel');
    await restClient.close();
    _pendingPlaceholders.clear();
    _pendingReactions.clear();
    _log.info('Google Chat channel disconnected');
  }

  String _fallbackText(ChannelResponse response) {
    if (response.text.isNotEmpty) {
      return response.text;
    }

    final structuredPayload = response.structuredPayload;
    if (structuredPayload == null) {
      return '';
    }

    final synthesized = _synthesizeFallbackText(structuredPayload);
    if (synthesized.isNotEmpty) {
      return synthesized;
    }

    return 'DartClaw sent an update.';
  }

  String _synthesizeFallbackText(Map<String, dynamic> structuredPayload) {
    final cards = structuredPayload['cardsV2'];
    if (cards is! List || cards.isEmpty) {
      return '';
    }

    final cardEntry = cards.first;
    if (cardEntry is! Map) {
      return '';
    }

    final card = cardEntry['card'];
    if (card is! Map) {
      return '';
    }

    final parts = <String>[];
    final header = card['header'];
    if (header is Map) {
      final title = _nonEmptyString(header['title']);
      final subtitle = _nonEmptyString(header['subtitle']);
      if (title != null) {
        parts.add(title);
      }
      if (subtitle != null) {
        parts.add(subtitle);
      }
    }

    final sections = card['sections'];
    if (sections is List) {
      for (final section in sections) {
        if (section is! Map) {
          continue;
        }
        final widgets = section['widgets'];
        if (widgets is! List) {
          continue;
        }
        for (final widget in widgets) {
          if (widget is! Map) {
            continue;
          }
          final textParagraph = widget['textParagraph'];
          if (textParagraph is! Map) {
            continue;
          }
          final text = _nonEmptyString(textParagraph['text']);
          if (text == null) {
            continue;
          }
          parts.add(_plainTextFromMarkup(text));
        }
      }
    }

    return parts.where((part) => part.isNotEmpty).join('\n');
  }

  String _plainTextFromMarkup(String value) {
    return value
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', '\'')
        .replaceAll('&amp;', '&')
        .trim();
  }

  String? _nonEmptyString(Object? value) {
    if (value is! String) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _placeholderKey(String spaceName, String turnId) => '$spaceName::$turnId';
}
