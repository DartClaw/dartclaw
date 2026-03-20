// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../auth/auth_utils.dart';
import '../security/google_jwt_verifier.dart';
import 'slash_command_handler.dart';

typedef GoogleChatMessageDispatcher = Future<String> Function(ChannelMessage message);

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
  final SlashCommandHandler? _slashCommandHandler;

  GoogleChatWebhookHandler({
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
    SlashCommandHandler? slashCommandHandler,
  }) : _reviewHandler = reviewHandler,
       _cardBuilder = cardBuilder ?? const ChatCardBuilder(),
       _slashCommandParser = slashCommandParser,
       _slashCommandHandler = slashCommandHandler;

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

    final payload = _decodePayload(body);
    if (payload == null) {
      return _jsonResponse(const {});
    }

    return switch (payload['type']) {
      'MESSAGE' => _handleMessage(payload),
      'ADDED_TO_SPACE' => _handleAddedToSpace(payload),
      'CARD_CLICKED' => _handleCardClicked(payload),
      'APP_COMMAND' => _handleAppCommand(payload),
      _ => () {
        _log.fine('Ignoring Google Chat event type "${payload['type']}"');
        return _jsonResponse(const {});
      }(),
    };
  }

  Future<Response> _handleMessage(Map<String, dynamic> payload) async {
    final message = _asMap(payload['message']);
    final space = _asMap(payload['space']);
    final user = _asMap(payload['user']);
    final sender = _asMap(message?['sender']);
    if (message == null || space == null || user == null) {
      return _jsonResponse(const {});
    }
    if (_isBotMessage(sender)) {
      return _jsonResponse(const {});
    }

    final senderJid = (user['name'] as String?) ?? (sender?['name'] as String?);
    final spaceName = space['name'] as String?;
    final spaceType = space['type'] as String?;
    if (senderJid == null || senderJid.isEmpty || spaceName == null || spaceName.isEmpty) {
      return _jsonResponse(const {});
    }

    final slashCommandParser = _slashCommandParser;
    final slashCommandHandler = _slashCommandHandler;
    if (slashCommandParser != null && slashCommandHandler != null) {
      final slashCommand = slashCommandParser.parseFromMessage(payload);
      if (slashCommand != null) {
        final response = await slashCommandHandler.handle(
          slashCommand,
          spaceName: spaceName,
          senderJid: senderJid,
          spaceType: spaceType,
          sourceMessageId: _resolveMessageId(message),
        );
        return _jsonResponse(response);
      }
    }

    final text = _resolveMessageText(message);
    if (text == null || text.isEmpty) {
      return _jsonResponse(const {});
    }

    final channelMessage = ChannelMessage(
      id: (message['name'] as String?) ?? (message['messageId'] as String?),
      channelType: ChannelType.googlechat,
      senderJid: senderJid,
      groupJid: switch (spaceType) {
        'DM' => null,
        'ROOM' || 'SPACE' => spaceName,
        _ => spaceName,
      },
      text: text,
      mentionedJids: _extractMentionedJids(message),
      metadata: {
        'spaceName': spaceName,
        if (spaceType case final String resolvedSpaceType) 'spaceType': resolvedSpaceType,
        if (user['displayName'] case final String displayName) 'senderDisplayName': displayName,
        if (message['name'] case final String messageName) 'messageName': messageName,
      },
    );

    // Access control gate
    final isDm = channelMessage.groupJid == null;
    if (isDm) {
      final access = dmAccess;
      if (access != null && !access.isAllowed(senderJid)) {
        if (access.mode == DmAccessMode.pairing) {
          final displayName = user['displayName'] as String?;
          final pairing = access.createPairing(senderJid, displayName: displayName);
          if (pairing != null) {
            await channel.restClient.sendMessage(
              spaceName,
              'To start chatting, confirm this pairing code in the DartClaw settings: **${pairing.code}**',
            );
          }
        }
        _log.fine('Dropping DM from unauthorized sender $senderJid');
        return _jsonResponse(const {});
      }
    } else {
      // Group access control
      if (config.groupAccess == GroupAccessMode.disabled) {
        _log.fine('Dropping group message from $spaceName (group access disabled)');
        return _jsonResponse(const {});
      }
      if (config.groupAccess == GroupAccessMode.allowlist && !config.groupAllowlist.contains(spaceName)) {
        _log.fine('Dropping group message from unlisted space $spaceName');
        return _jsonResponse(const {});
      }

      // Mention gating for groups
      final gating = mentionGating;
      if (gating != null && !gating.shouldProcess(channelMessage)) {
        _log.fine('Dropping group message without bot mention from $spaceName');
        return _jsonResponse(const {});
      }
    }

    final manager = channelManager;
    if (manager != null) {
      if (config.typingIndicator) {
        final placeholderName = await channel.restClient.sendMessage(spaceName, _typingMessage);
        if (placeholderName != null) {
          channel.setPlaceholder(spaceName: spaceName, turnId: channelMessage.id, messageName: placeholderName);
        }
      }
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
      final formatted = channel.formatResponse(responseText ?? '');
      if (formatted.isEmpty) {
        return _jsonResponse(const {});
      }
      if (formatted.length > 1) {
        unawaited(_sendChunks(spaceName, formatted.skip(1)));
      }
      return _jsonResponse({'text': formatted.first.text});
    }

    if (config.typingIndicator) {
      final placeholderName = await channel.restClient.sendMessage(spaceName, _typingMessage);
      if (placeholderName != null) {
        channel.setPlaceholder(spaceName: spaceName, turnId: channelMessage.id, messageName: placeholderName);
      }
    }
    unawaited(_deliverDeferredResponse(spaceName, responseFuture, channelMessage.id));
    return _jsonResponse(const {});
  }

  Future<Response> _handleAddedToSpace(Map<String, dynamic> payload) async {
    final space = _asMap(payload['space']);
    final spaceName = space?['name'] as String?;
    if (spaceName != null && spaceName.isNotEmpty) {
      await channel.restClient.sendMessage(spaceName, _welcomeMessage);
      _log.info('Google Chat bot added to $spaceName');
    }
    return _jsonResponse(const {});
  }

  Future<Response> _handleCardClicked(Map<String, dynamic> payload) async {
    final common = _asMap(payload['common']);
    final invokedFunction = common?['invokedFunction'] as String?;
    final space = _asMap(payload['space']);
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
    final space = _asMap(payload['space']);
    final user = _asMap(payload['user']);
    final message = _asMap(payload['message']);
    final spaceName = space?['name'] as String?;
    final senderJid = user?['name'] as String?;
    final spaceType = space?['type'] as String?;
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

    final response = await slashCommandHandler.handle(
      slashCommand,
      spaceName: spaceName,
      senderJid: senderJid,
      spaceType: spaceType,
      sourceMessageId: _resolveMessageId(message),
    );
    return _jsonResponse(response);
  }

  Future<void> _deliverDeferredResponse(String spaceName, Future<String> responseFuture, String sourceMessageId) async {
    try {
      final responseText = await responseFuture;
      await _sendChunks(spaceName, channel.formatResponse(responseText), sourceMessageId: sourceMessageId);
    } catch (error, stackTrace) {
      _log.warning('Google Chat async delivery failed', error, stackTrace);
      await _sendError(spaceName);
    }
  }

  Future<void> _sendChunks(String spaceName, Iterable<ChannelResponse> chunks, {String? sourceMessageId}) async {
    for (final chunk in chunks) {
      await channel.sendMessage(
        spaceName,
        sourceMessageId == null
            ? chunk
            : ChannelResponse(
                text: chunk.text,
                mediaAttachments: chunk.mediaAttachments,
                metadata: {...chunk.metadata, sourceMessageIdMetadataKey: sourceMessageId},
              ),
      );
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

  bool _isBotMessage(Map<String, dynamic>? sender) {
    if (sender?['type'] == 'BOT') {
      return true;
    }

    final configuredBotUser = config.botUser;
    return configuredBotUser != null && configuredBotUser.isNotEmpty && sender?['name'] == configuredBotUser;
  }

  String? _resolveMessageText(Map<String, dynamic> message) {
    final argumentText = (message['argumentText'] as String?)?.trim();
    if (argumentText != null && argumentText.isNotEmpty) {
      return argumentText;
    }

    final text = (message['text'] as String?)?.trim();
    if (text != null && text.isNotEmpty) {
      return text;
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
      final annotationMap = _asMap(annotation);
      if (annotationMap == null || annotationMap['type'] != 'USER_MENTION') {
        continue;
      }
      final userMention = _asMap(annotationMap['userMention']);
      final user = _asMap(userMention?['user']);
      final userName = user?['name'];
      if (userName is String && userName.isNotEmpty) {
        mentioned.add(userName);
      }
    }
    return mentioned;
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry('$key', value));
    }
    return null;
  }

  Map<String, String> _extractFlatParameters(Object? rawParameters) {
    if (rawParameters is Map<String, dynamic>) {
      final parameters = <String, String>{};
      for (final entry in rawParameters.entries) {
        final key = entry.key.trim();
        final value = entry.value;
        if (key.isEmpty || value is! String || value.isEmpty) {
          continue;
        }
        parameters[key] = value;
      }
      return parameters;
    }
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
      final map = _asMap(entry);
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
