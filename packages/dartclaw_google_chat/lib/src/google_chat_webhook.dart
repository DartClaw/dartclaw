import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import 'chat_card_builder.dart';
import 'google_chat_channel.dart';
import 'google_chat_config.dart';
import 'google_chat_rest_client.dart';
import 'google_chat_utils.dart';
import 'slash_command_executor.dart';
import 'slash_command_parser.dart';
import 'webhook_http_support.dart';
import 'workspace_events_manager.dart';

/// Dispatches an inbound Google Chat message and returns the reply text.
typedef GoogleChatMessageDispatcher = Future<String> Function(ChannelMessage message);

/// Handles signed Google Chat webhook deliveries and surfaces them to the runtime.
class GoogleChatWebhookHandler {
  static final _log = Logger('GoogleChatWebhookHandler');
  static const _typingMessage = '_DartClaw is typing..._';
  static const _welcomeMessage = 'Hello! I am DartClaw. Send me a message to get started.';
  static const _errorMessage = 'Sorry, I was unable to process your message. Please try again later.';

  final GoogleChatChannel channel;
  final GoogleJwtVerifier jwtVerifier;
  final GoogleChatConfig config;
  final ChannelManager? channelManager;
  final GoogleChatMessageDispatcher? dispatchMessage;
  final DmAccessController? dmAccess;
  final MentionGating? mentionGating;
  final EventBus? eventBus;
  final List<String> trustedProxies;
  final Duration responseTimeout;
  final ChannelReviewHandler? _reviewHandler;
  final ChatCardBuilder _cardBuilder;
  final SlashCommandParser? _slashCommandParser;
  final SlashCommandExecutor? _slashCommandHandler;
  final MessageDeduplicator? _deduplicator;
  final WorkspaceEventsManager? _subscriptionManager;

  new({
    required this.channel,
    required this.jwtVerifier,
    required this.config,
    this.channelManager,
    this.dispatchMessage,
    this.dmAccess,
    this.mentionGating,
    this.eventBus,
    this.trustedProxies = const [],
    this.responseTimeout = const Duration(seconds: 25),
    ChannelReviewHandler? reviewHandler,
    ChatCardBuilder? cardBuilder,
    SlashCommandParser? slashCommandParser,
    SlashCommandExecutor? slashCommandHandler,
    MessageDeduplicator? deduplicator,
    WorkspaceEventsManager? subscriptionManager,
  }) : _reviewHandler = reviewHandler,
       _cardBuilder = cardBuilder ?? const ChatCardBuilder(),
       _slashCommandParser = slashCommandParser,
       _slashCommandHandler = slashCommandHandler,
       _deduplicator = deduplicator,
       _subscriptionManager = subscriptionManager;

  Future<Response> handle(Request request) async {
    final authHeader = request.headers['authorization'];
    if (!await jwtVerifier.verify(authHeader)) {
      _log.warning('Google Chat webhook rejected: invalid or missing JWT');
      fireFailedAuthEvent(
        eventBus,
        request,
        source: 'webhook',
        reason: 'invalid_google_chat_jwt',
        trustedProxies: trustedProxies,
      );
      return Response(401);
    }

    final body = await readBounded(request, maxWebhookPayloadBytes);
    if (body == null) {
      _log.warning('Google Chat webhook payload exceeds size limit');
      return Response(413);
    }

    final rawPayload = _decodePayload(body);
    if (rawPayload == null) {
      return _jsonResponse(const {});
    }

    // Normalize Workspace Add-on format to legacy Chat API format.
    final payload = rawPayload['type'] == null ? (_normalizeAddOnPayload(rawPayload) ?? rawPayload) : rawPayload;

    return switch (payload['type']) {
      'MESSAGE' => _handleMessage(payload),
      'ADDED_TO_SPACE' => _handleAddedToSpace(payload),
      'REMOVED_FROM_SPACE' => _handleRemovedFromSpace(payload),
      'CARD_CLICKED' => _handleCardClicked(payload),
      'APP_COMMAND' => _handleAppCommand(payload),
      _ => () {
        _log.fine('Ignoring Google Chat event type "${payload['type']}"');
        return _jsonResponse(const {});
      }(),
    };
  }

  Future<Response> _handleMessage(Map<String, dynamic> payload) async {
    final message = asMap(payload['message']);
    final space = asMap(payload['space']);
    final user = asMap(payload['user']);
    final sender = asMap(message?['sender']);
    if (message == null || space == null || user == null) {
      return _jsonResponse(const {});
    }
    if (isBotMessage(sender, botUser: config.botUser)) {
      return _jsonResponse(const {});
    }

    final senderJid = (user['name'] as String?) ?? (sender?['name'] as String?);
    final spaceName = space['name'] as String?;
    final spaceType = resolveSpaceType(space);
    final thread = asMap(message['thread']);
    if (senderJid == null || senderJid.isEmpty || spaceName == null || spaceName.isEmpty) {
      return _jsonResponse(const {});
    }

    final slashCommandParser = _slashCommandParser;
    final slashCommandHandler = _slashCommandHandler;
    final slashCommand = slashCommandParser == null || slashCommandHandler == null
        ? null
        : slashCommandParser.parseFromMessage(payload);

    final text = resolveMessageText(message);
    if (slashCommand == null && (text == null || text.isEmpty)) {
      return _jsonResponse(const {});
    }

    final channelMessage = ChannelMessage(
      id: (message['name'] as String?) ?? (message['messageId'] as String?),
      channelType: ChannelType.googlechat,
      senderJid: senderJid,
      groupJid: resolveGroupJid(spaceType: spaceType, spaceName: spaceName),
      text: text ?? '',
      mentionedJids: _extractMentionedJids(message),
      metadata: {
        'spaceName': spaceName,
        'spaceType': spaceType,
        if (space['displayName'] case final String spaceDisplayName) 'spaceDisplayName': spaceDisplayName,
        if (user['displayName'] case final String displayName) 'senderDisplayName': displayName,
        if (sender?['avatarUrl'] case final String avatarUrl when avatarUrl.isNotEmpty) 'senderAvatarUrl': avatarUrl,
        if (message['name'] case final String messageName) 'messageName': messageName,
        if (message['createTime'] case final String createTime) 'messageCreateTime': createTime,
        if (thread?['name'] case final String threadName when threadName.isNotEmpty) 'threadName': threadName,
      },
    );

    final refusal = await _refuseByInboundGate(
      channelMessage,
      spaceName: spaceName,
      senderDisplayName: user['displayName'] as String?,
      isSlashCommand: slashCommand != null,
    );
    if (refusal != null) {
      return refusal;
    }

    if (slashCommand != null && slashCommandHandler != null) {
      final response = await slashCommandHandler.handle(
        slashCommand,
        spaceName: spaceName,
        senderJid: senderJid,
        senderDisplayName: user['displayName'] as String?,
        spaceType: spaceType,
        sourceMessageId: _resolveMessageId(message),
      );
      return _jsonResponse(response);
    }

    final manager = channelManager;
    if (manager != null) {
      // Dedup check — skip if this message already arrived via Pub/Sub.
      final dedup = _deduplicator;
      final messageName = channelMessage.metadata['messageName'] as String?;
      if (dedup != null && messageName != null && messageName.isNotEmpty) {
        if (!dedup.tryProcess(messageName)) {
          _log.fine('Duplicate message $messageName (already seen via Pub/Sub) — skipping webhook processing');
          return _jsonResponse(const {});
        }
      }

      await _sendTypingIndicator(spaceName, channelMessage);
      manager.handleInboundMessage(channelMessage);
      return _jsonResponse(const {});
    }

    final dispatcher = dispatchMessage;
    if (dispatcher == null) {
      return _jsonResponse(const {});
    }

    final responseFuture = dispatcher(channelMessage);
    String? responseText;
    var timedOut = false;
    try {
      responseText = await responseFuture.timeout(responseTimeout);
    } on TimeoutException {
      timedOut = true;
    } catch (error, stackTrace) {
      _log.warning('Google Chat dispatch failed', error, stackTrace);
      await _sendError(spaceName);
      return _jsonResponse(const {});
    }

    if (!timedOut) {
      final formatted = _formatWithMetadata(channelMessage, responseText ?? '');
      if (formatted.isEmpty) {
        return _jsonResponse(const {});
      }
      if (formatted.length > 1) {
        unawaited(_sendChunks(spaceName, formatted.skip(1)));
      }
      return _jsonResponse({'text': formatted.first.text});
    }

    await _sendTypingIndicator(spaceName, channelMessage);
    unawaited(_deliverDeferredResponse(spaceName, responseFuture, channelMessage));
    return _jsonResponse(const {});
  }

  /// Applies the shared inbound gate, returning the response to answer a refused
  /// event with, or `null` when the event is admitted.
  ///
  /// [isSlashCommand] exempts [ChannelInboundDecision.mentionRequired] alone: a
  /// registered slash command names this app explicitly, so mention gating has
  /// no ambient chatter to filter. Every access decision still applies.
  Future<Response?> _refuseByInboundGate(
    ChannelMessage message, {
    required String spaceName,
    required String? senderDisplayName,
    required bool isSlashCommand,
  }) async {
    final decision = ChannelInboundGate.evaluate(
      message,
      dmAccess: dmAccess,
      mentionGating: mentionGating,
      groupAccess: config.groupAccess,
      groupAllowlist: config.groupIds,
    );
    final senderJid = message.senderJid;
    switch (decision) {
      case ChannelInboundDecision.admitted:
        return null;
      case ChannelInboundDecision.dmPairingRequired:
        final pairing = dmAccess?.createPairing(senderJid, displayName: senderDisplayName);
        if (pairing != null) {
          await channel.restClient.send(
            spaceName: spaceName,
            text: 'To start chatting, confirm this pairing code in the DartClaw settings: **${pairing.code}**',
          );
        }
        _log.fine('Dropping DM from unauthorized sender $senderJid');
        return _jsonResponse(const {});
      case ChannelInboundDecision.dmDenied:
        _log.fine('Dropping DM from unauthorized sender $senderJid');
        return _jsonResponse(const {});
      case ChannelInboundDecision.groupAccessDisabled:
        _log.fine('Dropping group message from $spaceName (group access disabled)');
        return _jsonResponse(const {});
      case ChannelInboundDecision.groupNotAllowlisted:
        _log.fine('Dropping group message from unlisted space $spaceName');
        return _jsonResponse(const {});
      case ChannelInboundDecision.mentionRequired:
        if (isSlashCommand) {
          return null;
        }
        _log.fine('Dropping group message without bot mention from $spaceName');
        return _jsonResponse(const {});
    }
  }

  Future<Response> _handleAddedToSpace(Map<String, dynamic> payload) async {
    final space = asMap(payload['space']);
    final spaceName = space?['name'] as String?;
    if (spaceName != null && spaceName.isNotEmpty) {
      await channel.restClient.send(spaceName: spaceName, text: _welcomeMessage);
      _log.info('Google Chat bot added to $spaceName');

      // Auto-subscribe to space events when enabled
      final subscriptionManager = _subscriptionManager;
      if (subscriptionManager != null && config.spaceEvents.enabled) {
        try {
          await subscriptionManager.subscribe(spaceName);
          _log.info('Subscribed to space events for $spaceName');
        } catch (e, st) {
          _log.warning('Failed to subscribe to space events for $spaceName', e, st);
        }
      }
    }
    return _jsonResponse(const {});
  }

  Future<Response> _handleRemovedFromSpace(Map<String, dynamic> payload) async {
    final space = asMap(payload['space']);
    final spaceName = space?['name'] as String?;
    if (spaceName != null && spaceName.isNotEmpty) {
      _log.info('Google Chat bot removed from $spaceName');
      final subscriptionManager = _subscriptionManager;
      if (subscriptionManager != null) {
        try {
          await subscriptionManager.unsubscribe(spaceName);
          _log.info('Unsubscribed from space events for $spaceName');
        } catch (e, st) {
          _log.warning('Failed to unsubscribe from space events for $spaceName', e, st);
        }
      }
    }
    return _jsonResponse(const {});
  }

  Future<Response> _handleCardClicked(Map<String, dynamic> payload) async {
    final common = asMap(payload['common']);
    final invokedFunction = common?['invokedFunction'] as String?;
    final space = asMap(payload['space']);
    final spaceName = space?['name'] as String?;
    if (invokedFunction == null || invokedFunction.isEmpty || spaceName == null || spaceName.isEmpty) {
      _log.warning('CARD_CLICKED event missing invokedFunction or space');
      return _jsonResponse(const {});
    }

    final action = switch (invokedFunction) {
      'task_accept' => 'accept',
      'task_reject' => 'reject',
      _ => null,
    };
    if (action == null) {
      _log.fine('Ignoring unknown CARD_CLICKED function "$invokedFunction"');
      return _jsonResponse(const {});
    }

    final reviewHandler = _reviewHandler;
    if (reviewHandler == null) {
      _log.warning('CARD_CLICKED received but no review handler configured');
      return _jsonResponse({'text': 'Review actions are not available.'});
    }

    final taskId = _extractFlatParameters(common?['parameters'])['taskId'];
    if (taskId == null || taskId.isEmpty) {
      _log.warning('CARD_CLICKED $invokedFunction missing taskId parameter');
      return _jsonResponse({'text': 'Invalid button action: missing task ID.'});
    }

    final result = await reviewHandler(taskId, action);
    return switch (result) {
      ChannelReviewSuccess(:final taskTitle, :final action) => () {
        final completedAction = action == 'accept' ? 'accepted' : 'rejected';
        return _jsonResponse(
          _cardBuilder.confirmationCard(
            title: 'Task $completedAction',
            message: "Task '$taskTitle' has been $completedAction.",
          ),
        );
      }(),
      ChannelReviewMergeConflict(:final taskTitle) => _jsonResponse(
        _cardBuilder.errorNotification(
          title: 'Merge Conflict',
          errorSummary: "Task '$taskTitle' has merge conflicts. Review in the web UI.",
          taskId: taskId,
        ),
      ),
      ChannelReviewError(:final message) => _jsonResponse({'text': message}),
    };
  }

  Future<Response> _handleAppCommand(Map<String, dynamic> payload) async {
    final space = asMap(payload['space']);
    final user = asMap(payload['user']);
    final message = asMap(payload['message']);
    final spaceName = space?['name'] as String?;
    final senderJid = user?['name'] as String?;
    final spaceType = resolveSpaceType(space);
    if (spaceName == null || spaceName.isEmpty || senderJid == null || senderJid.isEmpty) {
      _log.warning('APP_COMMAND event missing space or user');
      return _jsonResponse(const {});
    }

    final slashCommandParser = _slashCommandParser;
    final slashCommandHandler = _slashCommandHandler;
    if (slashCommandParser == null || slashCommandHandler == null) {
      _log.warning('APP_COMMAND received but slash command handling is not configured');
      return _jsonResponse({'text': 'Slash commands are not available.'});
    }

    final slashCommand = slashCommandParser.parseFromAppCommand(payload);
    if (slashCommand == null) {
      _log.warning('APP_COMMAND event could not be parsed');
      return _jsonResponse(const {});
    }

    final refusal = await _refuseByInboundGate(
      ChannelMessage(
        id: _resolveMessageId(message),
        channelType: ChannelType.googlechat,
        senderJid: senderJid,
        groupJid: resolveGroupJid(spaceType: spaceType, spaceName: spaceName),
        text: '/${slashCommand.name}',
        metadata: {'spaceName': spaceName, 'spaceType': spaceType},
      ),
      spaceName: spaceName,
      senderDisplayName: user?['displayName'] as String?,
      isSlashCommand: true,
    );
    if (refusal != null) {
      return refusal;
    }

    final response = await slashCommandHandler.handle(
      slashCommand,
      spaceName: spaceName,
      senderJid: senderJid,
      senderDisplayName: user?['displayName'] as String?,
      spaceType: spaceType,
      sourceMessageId: _resolveMessageId(message),
    );
    return _jsonResponse(response);
  }

  Future<void> _sendTypingIndicator(String spaceName, ChannelMessage channelMessage) async {
    switch (config.typingIndicatorMode) {
      case TypingIndicatorMode.message:
        final placeholder = await channel.restClient.send(spaceName: spaceName, text: _typingMessage);
        final placeholderName = placeholder.messageName;
        if (placeholderName != null) {
          channel.setPlaceholder(spaceName: spaceName, turnId: channelMessage.id, messageName: placeholderName);
        }
      case TypingIndicatorMode.emoji:
        final reactionTarget = channelMessage.metadata['messageName'] as String? ?? channelMessage.id;
        final reactionName = await channel.restClient.addReaction(reactionTarget, typingIndicatorEmoji);
        if (reactionName != null) {
          channel.setReaction(spaceName: spaceName, turnId: channelMessage.id, reactionName: reactionName);
        }
      case TypingIndicatorMode.disabled:
        break;
    }
  }

  Future<void> _deliverDeferredResponse(String spaceName, Future<String> responseFuture, ChannelMessage message) async {
    try {
      final responseText = await responseFuture;
      await _sendChunks(spaceName, _formatWithMetadata(message, responseText));
    } catch (error, stackTrace) {
      _log.warning('Google Chat async delivery failed', error, stackTrace);
      await _sendError(spaceName);
    }
  }

  /// Formats response text into [ChannelResponse] chunks with inbound message
  /// metadata restored — matching the same pattern used by [MessageQueue].
  List<ChannelResponse> _formatWithMetadata(ChannelMessage message, String responseText) {
    return channel.formatResponse(responseText).map((chunk) {
      return ChannelResponse(
        text: chunk.text,
        mediaAttachments: chunk.mediaAttachments,
        metadata: {
          ...chunk.metadata,
          sourceMessageIdMetadataKey: message.id,
          if (message.metadata['messageName'] case final String messageName) 'messageName': messageName,
          if (message.metadata['messageCreateTime'] case final String createTime) 'messageCreateTime': createTime,
          if (message.metadata['senderDisplayName'] case final String senderDisplayName)
            'senderDisplayName': senderDisplayName,
          if (message.metadata['spaceType'] case final String spaceType) 'spaceType': spaceType,
        },
        replyToMessageId: message.metadata['messageName'] as String?,
        structuredPayload: chunk.structuredPayload,
      );
    }).toList();
  }

  Future<void> _sendChunks(String spaceName, Iterable<ChannelResponse> chunks) async {
    for (final chunk in chunks) {
      await channel.sendMessage(spaceName, chunk);
    }
  }

  Future<void> _sendError(String spaceName) async {
    try {
      await channel.sendMessage(spaceName, const ChannelResponse(text: _errorMessage));
    } catch (error, stackTrace) {
      _log.warning('Failed to send Google Chat error message', error, stackTrace);
    }
  }

  Response _jsonResponse(Map<String, dynamic> body) {
    return Response.ok(jsonEncode(body), headers: const {'content-type': 'application/json'});
  }

  /// Converts a Workspace Add-on event into the legacy Chat API shape.
  ///
  /// Add-on events carry `commonEventObject`, `authorizationEventObject`, and
  /// `chat` at the top level. The event type is inferred from which payload
  /// field (`messagePayload`, `addedToSpacePayload`, etc.) is present inside
  /// `chat`.
  Map<String, dynamic>? _normalizeAddOnPayload(Map<String, dynamic> raw) {
    final common = asMap(raw['commonEventObject']);
    if (common?['hostApp'] != 'CHAT') return null;

    final chat = asMap(raw['chat']);
    if (chat == null) return null;

    final user = asMap(chat['user']);
    final eventTime = chat['eventTime'] as String?;

    // Detect event type by which payload key is present.
    if (chat.containsKey('messagePayload')) {
      final mp = asMap(chat['messagePayload']);
      return <String, dynamic>{
        'type': 'MESSAGE',
        'space': mp?['space'] ?? asMap(chat['space']),
        'message': mp?['message'],
        'user': user,
        'eventTime': ?eventTime,
        'common': ?common,
      };
    }
    if (chat.containsKey('addedToSpacePayload')) {
      final ap = asMap(chat['addedToSpacePayload']);
      return <String, dynamic>{
        'type': 'ADDED_TO_SPACE',
        'space': ap?['space'] ?? asMap(chat['space']),
        'user': user,
        'eventTime': ?eventTime,
      };
    }
    if (chat.containsKey('removedFromSpacePayload')) {
      final rp = asMap(chat['removedFromSpacePayload']);
      return <String, dynamic>{
        'type': 'REMOVED_FROM_SPACE',
        'space': rp?['space'] ?? asMap(chat['space']),
        'user': user,
        'eventTime': ?eventTime,
      };
    }
    if (chat.containsKey('buttonClickedPayload')) {
      final bp = asMap(chat['buttonClickedPayload']);
      return <String, dynamic>{
        'type': 'CARD_CLICKED',
        'space': bp?['space'] ?? asMap(chat['space']),
        'message': bp?['message'],
        'user': user,
        'common': ?common,
        'eventTime': ?eventTime,
      };
    }
    if (chat.containsKey('appCommandPayload')) {
      final appCommandPayload = asMap(chat['appCommandPayload']);
      return <String, dynamic>{
        'type': 'APP_COMMAND',
        'space': appCommandPayload?['space'] ?? asMap(chat['space']),
        'message': appCommandPayload?['message'],
        'user': user,
        'appCommandMetadata': ?appCommandPayload?['appCommandMetadata'],
        'common': ?common,
        'eventTime': ?eventTime,
      };
    }

    _log.fine('Add-on payload has no recognized chat event payload key: ${chat.keys.toList()}');
    return null;
  }

  Map<String, dynamic>? _decodePayload(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      _log.warning('Google Chat webhook payload was not a JSON object');
    } catch (error, stackTrace) {
      _log.warning('Invalid Google Chat webhook payload', error, stackTrace);
    }
    return null;
  }

  String? _resolveMessageId(Map<String, dynamic>? message) {
    if (message == null) {
      return null;
    }

    final name = message['name'] as String?;
    if (name != null && name.isNotEmpty) {
      return name;
    }

    final messageId = message['messageId'] as String?;
    if (messageId != null && messageId.isNotEmpty) {
      return messageId;
    }

    return null;
  }

  List<String> _extractMentionedJids(Map<String, dynamic> message) {
    final annotations = message['annotations'];
    if (annotations is! List) {
      return const [];
    }

    final mentioned = <String>[];
    for (final annotation in annotations) {
      final annotationMap = asMap(annotation);
      if (annotationMap == null || annotationMap['type'] != 'USER_MENTION') {
        continue;
      }
      final userMention = asMap(annotationMap['userMention']);
      final user = asMap(userMention?['user']);
      final userName = user?['name'];
      if (userName is String && userName.isNotEmpty) {
        mentioned.add(userName);
      }
    }
    return mentioned;
  }

  Map<String, String> _extractFlatParameters(Object? rawParameters) {
    if (rawParameters is Map) {
      final parameters = <String, String>{};
      for (final entry in rawParameters.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String) {
          continue;
        }
        final trimmedKey = key.trim();
        if (trimmedKey.isEmpty || value.isEmpty) {
          continue;
        }
        parameters[trimmedKey] = value;
      }
      return parameters;
    }
    if (rawParameters is! List) {
      return const {};
    }

    final parameters = <String, String>{};
    for (final entry in rawParameters) {
      final map = asMap(entry);
      final key = map?['key'];
      final value = map?['value'];
      if (key is! String || value is! String) {
        continue;
      }
      final trimmedKey = key.trim();
      if (trimmedKey.isEmpty || value.isEmpty) {
        continue;
      }
      parameters[trimmedKey] = value;
    }
    return parameters;
  }
}
