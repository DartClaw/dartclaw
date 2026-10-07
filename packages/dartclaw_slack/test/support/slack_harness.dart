import 'dart:async';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show RecordingMessageQueue;
import 'package:logging/logging.dart';

const botUserId = 'UBOT';

/// A connected [SlackChannel] wired to a fake Socket Mode server, a fake Web API
/// and a real [ChannelManager] over a recording queue.
///
/// Everything an envelope does is observable on [queue] (admitted turns) and
/// [api] (posts), and [deliver] returns only once every envelope sent before it
/// has been processed.
class SlackHarness {
  new _({
    required this.server,
    required this.api,
    required this.queue,
    required this.manager,
    required this.channel,
    required this.dmAccess,
    required this.signingSecret,
  });

  final FakeSocketModeServer server;
  final FakeSlackWebApi api;
  final RecordingMessageQueue queue;
  final ChannelManager manager;
  final SlackChannel channel;
  final DmAccessController dmAccess;
  final String signingSecret;
  final List<LogRecord> logs = [];

  static Future<SlackHarness> start({
    SlackConfig? config,
    SessionScopeConfig scopes = const SessionScopeConfig.defaults(),
    List<GroupEntry> groupRows = const [],
    List<GroupEntry> dmRows = const [],
    String Function(String text)? answer,
    ReservedCommandDispatch? reservedCommands,
    String mode = 'socket',
    String signingSecret = 'harness-signing-secret',
    ChannelRunApprovalHandler? runApprovalHandler,
  }) async {
    final slackConfig =
        config ??
        SlackConfig(
          enabled: true,
          dmAccess: DmAccessMode.allowlist,
          dmAllowlist: [
            const GroupEntry(id: 'U1'),
            const GroupEntry(id: 'U2'),
            const GroupEntry(id: 'UZ'),
          ],
          groupAccess: GroupAccessMode.allowlist,
          groupAllowlist: [
            const GroupEntry(id: 'C1'),
            ...groupRows,
          ],
        );
    final server = FakeSocketModeServer();
    await server.start();
    final api = FakeSlackWebApi(botUserId: botUserId, socketUrl: server.url);
    final queue = RecordingMessageQueue(
      forwardToSuper: answer != null,
      debounceWindow: Duration.zero,
      dispatcher: (
        sessionKey,
        message, {
        required ChannelType channelType,
        String? senderJid,
        String? senderDisplayName,
        String? groupJid,
        String? recipientId,
        String? threadId,
        List<ChannelAttachment> attachments = const [],
      }) async => answer?.call(message) ?? 'ok',
    );
    final dmAccess = DmAccessController(mode: slackConfig.dmAccess, allowlist: slackConfig.dmIds.toSet());
    final manager = ChannelManager(
      queue: queue,
      config: const ChannelConfig.defaults(),
      liveScopeConfig: LiveScopeConfig(scopes),
      taskBridge: reservedCommands == null
          ? null
          : ChannelTaskBridge(
              reservedCommandHandler: reservedCommands,
              isReservedCommand: (text) => text.trim().startsWith('/') || text.trim() == 'stop!',
            ),
      groupConfigResolver: GroupConfigResolver.fromChannelEntries(
        {ChannelType.slack: slackConfig.groupAllowlist},
        dms: {ChannelType.slack: slackConfig.dmAllowlist},
      ),
    );
    final channel = SlackChannel(
      config: slackConfig,
      api: api,
      dmAccess: dmAccess,
      mentionGating: MentionGating(
        requireMention: slackConfig.requireMention,
        mentionPatterns: slackConfig.mentionPatterns,
        ownJid: '',
      ),
      channelManager: manager,
      mode: mode,
      signingSecret: signingSecret,
      reconnectDelay: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
      runApprovalHandler: runApprovalHandler,
    );
    manager.registerChannel(channel);
    final harness = SlackHarness._(
      server: server,
      api: api,
      queue: queue,
      manager: manager,
      channel: channel,
      dmAccess: dmAccess,
      signingSecret: signingSecret,
    );
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(harness.logs.add);
    harness._unsubscribe = subscription.cancel;
    channel.dispatch.register(SlackEnvelopeKind.unknown, (envelope) => harness._sentinelsSeen++);
    await channel.connect();
    if (mode == 'socket') await harness.until(() => channel.connectionState == SocketModeState.connected);
    return harness;
  }

  Future<void> Function()? _unsubscribe;

  /// Admitted turns, in arrival order.
  List<RecordedTurn> get turns => [
    for (final enqueued in queue.enqueued) (message: enqueued.message, sessionKey: enqueued.sessionKey),
  ];

  var _sentinelsSent = 0;
  var _sentinelsSeen = 0;

  /// Sends each [events] entry as an Events API envelope, then waits until all are processed.
  ///
  /// Envelopes are processed in order, so a trailing envelope of an unhandled
  /// kind reaching its handler proves every earlier one has been fully handled,
  /// including the ones that start no turn.
  Future<void> deliver(List<Map<String, dynamic>> events) async {
    for (final event in events) {
      server.sendEvent(eventCallback(event));
    }
    _sentinelsSent++;
    server.sendInteractive({'type': 'sentinel'});
    await until(() => _sentinelsSeen == _sentinelsSent);
  }

  /// Posts [body] to the channel's Events API handler, signed as Slack signs it.
  Future<SlackEventsResponse> post(List<int> body, {String contentType = 'application/json'}) => channel.eventsHandler!
      .handle(Uint8List.fromList(body), signedSlackHeaders(signingSecret, body, contentType: contentType));

  /// Waits for [condition], failing after five seconds.
  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('Condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> close() async {
    await channel.disconnect();
    await server.stop();
    queue.dispose();
    await _unsubscribe?.call();
  }
}

typedef RecordedTurn = ({ChannelMessage message, String sessionKey});

Map<String, dynamic> eventCallback(Map<String, dynamic> event) => {
  'type': 'event_callback',
  'event_id': 'Ev${event['ts']}',
  'event': event,
};

/// A `message` event as Slack delivers it, mentioning the bot when [mention] is set.
Map<String, dynamic> message({
  required String channel,
  required String user,
  required String text,
  required String ts,
  String? threadTs,
  bool mention = false,
  String? channelType,
  String? subtype,
  String? botId,
  List<Map<String, dynamic>>? files,
}) => {
  'type': 'message',
  'channel': channel,
  'channel_type': channelType ?? (channel.startsWith('D') ? 'im' : 'channel'),
  'user': user,
  'text': mention ? '<@$botUserId> $text' : text,
  'ts': ts,
  'thread_ts': ?threadTs,
  'subtype': ?subtype,
  'bot_id': ?botId,
  'files': ?files,
  'blocks': [
    {
      'type': 'rich_text',
      'elements': [
        {
          'type': 'rich_text_section',
          'elements': [
            if (mention) {'type': 'user', 'user_id': botUserId},
            {'type': 'text', 'text': mention ? ' $text' : text},
          ],
        },
      ],
    },
  ],
};

/// The `block_actions` payload Slack delivers for a click on a button.
Map<String, dynamic> blockAction({
  required String actionId,
  Object? value,
  required String user,
  String? name,
  String? messageTs,
  String? responseUrl,
}) => {
  'type': 'block_actions',
  'user': {'id': user, 'username': ?name, 'name': ?name, 'team_id': 'T1'},
  'api_app_id': 'A1',
  'container': {'type': 'message', 'message_ts': ?messageTs, 'channel_id': 'C1', 'thread_ts': '1700000000.000000'},
  'channel': {'id': 'C1', 'name': 'general'},
  'message': {'type': 'message', 'ts': ?messageTs},
  'response_url': ?responseUrl,
  'actions': [
    {
      'type': 'button',
      'action_id': actionId,
      'block_id': 'b1',
      'text': {'type': 'plain_text', 'text': actionId},
      'value': ?value,
      'action_ts': '1700000001.000000',
    },
  ],
};
