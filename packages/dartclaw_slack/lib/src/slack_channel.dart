import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        Channel,
        ChannelInboundDecision,
        ChannelInboundGate,
        ChannelManager,
        ChannelMessage,
        ChannelResponse,
        DmAccessController,
        MentionGating,
        chunkNativeChatMarkup,
        sourceMessageIdMetadataKey,
        threadIdMetadataKey;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show ChannelType;
import 'package:logging/logging.dart';

import 'slack_config.dart';
import 'slack_envelope.dart';
import 'slack_events_handler.dart';
import 'slack_health_reporter.dart';
import 'slack_markdown.dart';
import 'slack_web_api_client.dart';
import 'socket_mode_client.dart';

const _maxChunkSize = 4000;
const _maxTrackedThreads = 2000;
const _maxTrackedSlashCommands = 200;

final _slackIdPattern = RegExp(r'^[UWCGD][A-Z0-9]+$');
final _mentionTokenPattern = RegExp(r'<@([UW][A-Z0-9]+)(?:\|[^>]*)?>');

/// Message subtypes that carry a person's own words. Edits, deletions, joins
/// and the rest are not conversation.
const _conversationalSubtypes = {null, 'file_share', 'thread_broadcast'};

/// Channel adapter for Slack: DMs and channels over Socket Mode or the Events API, one session per thread.
class SlackChannel extends Channel {
  static final _log = Logger('SlackChannel');

  @override
  final String name = 'slack';

  @override
  final ChannelType type = ChannelType.slack;

  /// Parsed Slack configuration.
  final SlackConfig config;

  /// Web API client used for every outbound call.
  final SlackWebApiClient api;

  /// DM access controller deciding which senders may open a conversation.
  final DmAccessController dmAccess;

  /// Mention gating for channel messages; its [MentionGating.ownJid] is set on [connect].
  final MentionGating mentionGating;

  /// Receives every admitted message.
  final ChannelManager channelManager;

  /// The one entry point for every inbound envelope, whichever transport delivered it.
  final SlackEnvelopeDispatch dispatch = SlackEnvelopeDispatch();

  /// Verifies and decodes Slack's HTTP deliveries; non-null only in events mode.
  late final SlackEventsHandler? eventsHandler;

  /// Transport state for `/health`.
  late final SlackHealthReporter healthReporter;

  SocketModeClient? _socket;

  String? _botUserId;
  String? _botId;

  /// Whether the bot has posted in, or been mentioned into, a thread; a missing
  /// entry is unknown and asks Slack once. Insertion-ordered, bounded.
  final Map<String, bool> _participation = {};
  final Map<String, Future<bool>> _participationChecks = {};

  /// `response_url` per slash-command message id, so the handler's reply can
  /// answer the command. Insertion-ordered, bounded.
  final Map<String, Uri> _slashResponseUrls = {};

  /// Creates a Slack channel adapter.
  ///
  /// [mode] is `socket` or `events`; events mode needs a non-empty
  /// [signingSecret] and opens no socket. [socketConnector] and
  /// [reconnectDelay] replace the real WebSocket and backoff sleep, for tests.
  ///
  /// Throws [ArgumentError] for an unknown [mode] or events mode without a signing secret.
  new({
    required this.config,
    required this.api,
    required this.dmAccess,
    required this.mentionGating,
    required this.channelManager,
    String mode = 'socket',
    String? signingSecret,
    SocketModeConnector? socketConnector,
    Future<void> Function(Duration)? reconnectDelay,
  }) {
    switch (mode) {
      case 'socket':
        final socket = _socket = SocketModeClient(
          openUrl: api.openSocketUrl,
          dispatch: dispatch,
          connector: socketConnector,
          delay: reconnectDelay,
        );
        eventsHandler = null;
        healthReporter = SlackHealthReporter(socket: socket);
      case 'events':
        if (signingSecret == null || signingSecret.isEmpty) {
          throw ArgumentError.value(signingSecret, 'signingSecret', 'events mode needs a signing secret');
        }
        final handler = eventsHandler = SlackEventsHandler(signingSecret: signingSecret, dispatch: dispatch);
        healthReporter = SlackHealthReporter(events: handler);
      default:
        throw ArgumentError.value(mode, 'mode', 'must be socket or events');
    }
    dispatch
      ..register(SlackEnvelopeKind.event, _handleEvent)
      ..register(SlackEnvelopeKind.slashCommand, _handleSlashCommand);
  }

  /// Whether the Socket Mode connection is up; always disconnected in events mode.
  SocketModeState get connectionState => _socket?.state ?? SocketModeState.disconnected;

  /// When Socket Mode last connected, or `null` if it never has.
  DateTime? get lastConnectedAt => _socket?.lastConnectedAt;

  @override
  Future<void> connect() async {
    final identity = await api.authTest();
    _botUserId = identity.userId;
    _botId = identity.botId;
    mentionGating.ownJid = identity.userId;
    _socket?.start();
    _log.info('Slack channel connected');
  }

  @override
  Future<void> disconnect() async {
    await _socket?.stop();
    api.close();
    _log.info('Slack channel disconnected');
  }

  @override
  bool ownsJid(String jid) => _slackIdPattern.hasMatch(jid);

  @override
  List<ChannelResponse> formatResponse(String text) {
    final chunks = chunkNativeChatMarkup(markdownToSlackMrkdwn(text.trimLeft()), maxSize: _maxChunkSize);
    return [for (final chunk in chunks) ChannelResponse(text: chunk)];
  }

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    if (response.mediaAttachments.isNotEmpty) {
      _log.warning('Outbound Slack media attachments are not supported');
    }
    if (response.text.isEmpty) return;

    final responseUrl = _slashResponseUrls[response.metadata[sourceMessageIdMetadataKey]];
    try {
      if (responseUrl != null) {
        await api.postEphemeral(responseUrl, response.text);
        return;
      }
      final threadTs = response.metadata[threadIdMetadataKey] as String?;
      await api.postMessage(channel: recipientJid, text: response.text, threadTs: threadTs);
      if (threadTs != null) _noteParticipation(recipientJid, threadTs);
    } on SlackApiException catch (error) {
      // The chunk is dropped; the session transcript still holds the reply, and later chunks are still tried.
      _log.warning('Dropping a Slack reply to $recipientJid: $error');
    }
  }

  Future<void> _handleEvent(SlackEnvelope envelope) async {
    final event = envelope.payload['event'];
    if (event is! Map) {
      _log.fine('Ignoring a Slack event envelope without an event');
      return;
    }
    final eventType = event['type'];
    switch (eventType) {
      case 'message':
        await _handleMessage(Map<String, dynamic>.from(event));
      case 'app_mention':
        // The same message also arrives as a `message` event, which alone carries `files`.
        _log.fine('Ignoring an app_mention event; its message event is the one processed');
      default:
        _log.fine('Ignoring unknown Slack event type "$eventType"');
    }
  }

  Future<void> _handleMessage(Map<String, dynamic> event) async {
    final subtype = event['subtype'];
    if (!_conversationalSubtypes.contains(subtype)) {
      _log.fine('Ignoring Slack message subtype "$subtype"');
      return;
    }
    final user = event['user'];
    final channel = event['channel'];
    final ts = event['ts'];
    if (event['bot_id'] != null || user is! String || channel is! String || ts is! String) return;
    if (user == _botUserId) return;

    final rawText = event['text'];
    final mentioned = _mentionedUserIds(event);
    final botUserId = _botUserId;
    final text = _cleanText(rawText is String ? rawText : '', botUserId);
    if (text.isEmpty) return;

    final isDm = event['channel_type'] == 'im' || channel.startsWith('D');
    final threadTs = event['thread_ts'] is String ? event['thread_ts'] as String : null;
    final isThreadReply = threadTs != null && threadTs != ts;

    ChannelMessage build(String? displayName) => ChannelMessage(
      id: '$channel:$ts',
      channelType: ChannelType.slack,
      senderJid: user,
      groupJid: isDm ? null : channel,
      text: text,
      timestamp: _timestampOf(ts),
      mentionedJids: mentioned,
      metadata: {
        'spaceName': channel,
        threadIdMetadataKey: threadTs ?? ts,
        'senderDisplayName': ?displayName,
        'messageTs': ts,
      },
    );

    final unnamed = build(null);
    var decision = _evaluate(unnamed, mentionGating: mentionGating);
    if (decision == ChannelInboundDecision.mentionRequired &&
        isThreadReply &&
        await _botParticipates(channel, threadTs)) {
      decision = _evaluate(unnamed, mentionGating: null);
    }

    // Only a sender the gate lets through, or asks to pair, is worth a users.info call.
    final named = switch (decision) {
      ChannelInboundDecision.admitted || ChannelInboundDecision.dmPairingRequired => await api.displayName(user),
      _ => null,
    };
    final message = build(named);
    if (!await _admit(decision, message, displayName: named)) return;

    if (!isDm) _noteParticipation(channel, threadTs ?? ts);
    channelManager.handleInboundMessage(message);
  }

  Future<void> _handleSlashCommand(SlackEnvelope envelope) async {
    final payload = envelope.payload;
    final command = payload['command'];
    final user = payload['user_id'];
    final channel = payload['channel_id'];
    final responseUrl = payload['response_url'];
    if (command is! String || user is! String || channel is! String) return;

    final args = payload['text'];
    final message = ChannelMessage(
      channelType: ChannelType.slack,
      senderJid: user,
      groupJid: channel.startsWith('D') ? null : channel,
      text: '$command ${args is String ? args : ''}'.trim(),
      metadata: {'spaceName': channel},
    );

    // A slash command names this app explicitly, so only access gating applies.
    final decision = _evaluate(message, mentionGating: null);
    if (!await _admit(decision, message, displayName: null)) return;

    final url = responseUrl is String ? Uri.tryParse(responseUrl) : null;
    if (url != null) {
      _slashResponseUrls[message.id] = url;
      if (_slashResponseUrls.length > _maxTrackedSlashCommands) {
        _slashResponseUrls.remove(_slashResponseUrls.keys.first);
      }
    }
    channelManager.handleInboundMessage(message);
  }

  ChannelInboundDecision _evaluate(ChannelMessage message, {required MentionGating? mentionGating}) =>
      ChannelInboundGate.evaluate(
        message,
        dmAccess: dmAccess,
        mentionGating: mentionGating,
        groupAccess: config.groupAccess,
        groupAllowlist: config.groupIds,
      );

  /// Whether [decision] admits [message]; a refusal is logged, and a DM that
  /// needs pairing is answered with its code.
  Future<bool> _admit(ChannelInboundDecision decision, ChannelMessage message, {required String? displayName}) async {
    final sender = message.senderJid;
    final conversation = message.metadata['spaceName'] as String;
    switch (decision) {
      case ChannelInboundDecision.admitted:
        return true;
      case ChannelInboundDecision.dmPairingRequired:
        final pairing = dmAccess.createPairing(sender, displayName: displayName);
        if (pairing != null) {
          try {
            await api.postMessage(
              channel: conversation,
              text: 'To start chatting, confirm this pairing code in the DartClaw settings: *${pairing.code}*',
            );
          } on SlackApiException catch (error) {
            _log.warning('Could not send the Slack pairing code to $sender: $error');
          }
        }
        _log.fine('Dropping DM from unauthorized sender $sender');
      case ChannelInboundDecision.dmDenied:
        _log.fine('Dropping DM from unauthorized sender $sender');
      case ChannelInboundDecision.groupAccessDisabled:
        _log.fine('Dropping channel message from $conversation (group access disabled)');
      case ChannelInboundDecision.groupNotAllowlisted:
        _log.fine('Dropping channel message from unlisted channel $conversation');
      case ChannelInboundDecision.mentionRequired:
        _log.fine('Dropping channel message without a bot mention from $conversation');
    }
    return false;
  }

  /// Whether the bot already took part in the thread [threadTs] of [channel].
  ///
  /// Answered from memory when known, else by asking Slack once: the answer, yes
  /// or no, is remembered, and mentions and replies by the bot overwrite a no.
  Future<bool> _botParticipates(String channel, String threadTs) {
    final key = '$channel:$threadTs';
    final known = _participation[key];
    if (known != null) return Future.value(known);
    return _participationChecks[key] ??= _askSlackWhetherBotParticipates(channel, threadTs).whenComplete(() {
      _participationChecks.remove(key);
    });
  }

  Future<bool> _askSlackWhetherBotParticipates(String channel, String threadTs) async {
    var participates = false;
    try {
      final messages = await api.conversationsReplies(channel: channel, threadTs: threadTs);
      participates = messages.any(
        (message) =>
            (message['user'] != null && message['user'] == _botUserId) ||
            (message['bot_id'] != null && message['bot_id'] == _botId),
      );
    } on SlackApiException catch (error) {
      _log.warning('Could not check bot participation in Slack thread $threadTs of $channel: $error');
    }
    _rememberParticipation('$channel:$threadTs', participates);
    return participates;
  }

  void _noteParticipation(String channel, String threadTs) => _rememberParticipation('$channel:$threadTs', true);

  void _rememberParticipation(String key, bool participates) {
    _participation
      ..remove(key)
      ..[key] = participates;
    if (_participation.length > _maxTrackedThreads) _participation.remove(_participation.keys.first);
  }

  List<String> _mentionedUserIds(Map<String, dynamic> event) {
    final ids = <String>{};
    final blocks = event['blocks'];
    if (blocks is List) {
      void collect(Object? node) {
        if (node is Map) {
          if (node['type'] == 'user' && node['user_id'] is String) ids.add(node['user_id'] as String);
          node.values.forEach(collect);
        } else if (node is List) {
          node.forEach(collect);
        }
      }

      collect(blocks);
    } else if (event['text'] case final String text) {
      ids.addAll(_mentionTokenPattern.allMatches(text).map((match) => match.group(1)!));
    }
    return ids.toList();
  }

  /// Drops the bot's own mention token and decodes Slack's entity escapes.
  static String _cleanText(String text, String? botUserId) {
    var cleaned = text;
    if (botUserId != null) {
      cleaned = cleaned.replaceAll(RegExp('<@${RegExp.escape(botUserId)}(?:\\|[^>]*)?>'), '');
    }
    return decodeSlackText(cleaned).trim();
  }

  static DateTime? _timestampOf(String ts) {
    final seconds = double.tryParse(ts);
    return seconds == null ? null : DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  }
}
