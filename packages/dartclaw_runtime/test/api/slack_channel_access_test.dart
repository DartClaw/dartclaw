import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show RecordingMessageQueue;
import 'package:path/path.dart' as p;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'api_test_helpers.dart';

void main() {
  late Directory tempDir;
  late String configPath;
  late FakeSlackWebApi slackApi;
  late RecordingMessageQueue queue;
  late SlackChannel channel;
  late Router router;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('slack_channel_access_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    final dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();
    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
channels:
  slack:
    enabled: true
    dm_access: pairing
    dm_allowlist:
      - U1
''');

    final config = const SlackConfig(
      enabled: true,
      dmAccess: DmAccessMode.pairing,
      dmAllowlist: [GroupEntry(id: 'U1')],
    );
    slackApi = FakeSlackWebApi();
    queue = RecordingMessageQueue(debounceWindow: Duration.zero);
    final manager = ChannelManager(
      queue: queue,
      config: const ChannelConfig.defaults(),
      liveScopeConfig: LiveScopeConfig(const SessionScopeConfig.defaults()),
    );
    channel = SlackChannel(
      config: config,
      api: slackApi,
      dmAccess: DmAccessController(mode: config.dmAccess, allowlist: config.dmIds.toSet()),
      mentionGating: MentionGating(requireMention: true, mentionPatterns: const [], ownJid: ''),
      channelManager: manager,
    );
    manager.registerChannel(channel);
    router = _routerFor(configPath: configPath, dataDir: dataDir, slackChannel: channel);
  });

  tearDown(() {
    queue.dispose();
    tempDir.deleteSync(recursive: true);
  });

  ApiRouteTestClient api() => ApiRouteTestClient(router.call);

  Future<void> sendDm(String user, String ts) async {
    await channel.dispatch.dispatch(
      SlackEnvelope(
        kind: SlackEnvelopeKind.event,
        payload: {
          'event': {'type': 'message', 'channel': 'D$user', 'channel_type': 'im', 'user': user, 'text': 'hi', 'ts': ts},
        },
      ),
    );
    await pumpEventQueue();
  }

  List<Object?> storedDmRows() {
    final doc = loadYaml(File(configPath).readAsStringSync()) as YamlMap;
    return [...((doc['channels'] as YamlMap)['slack']['dm_allowlist'] as YamlList)];
  }

  group('pairing', () {
    test('a confirmed Slack pairing admits the sender it was issued to, and the grant outlives a restart', () async {
      await sendDm('U9', '100.1');
      expect(queue.enqueued, isEmpty, reason: 'an unpaired sender must be held back');
      final code = slackApi.posts.single.text.split('*')[1];

      final pending = await api().expectJsonObject('GET', '/api/channels/slack/dm-pairing');
      expect(pending['total'], 1);
      expect((pending['pending'] as List).single, containsPair('senderId', 'U9'));

      final confirmed = await api().expectJsonObject(
        'POST',
        '/api/channels/slack/dm-pairing/confirm',
        json: {'code': code},
      );
      expect(confirmed, {'confirmed': true, 'senderId': 'U9'});

      await sendDm('U9', '101.1');
      expect(queue.enqueued.map((entry) => entry.message.senderJid), ['U9']);
      expect(slackApi.posts, hasLength(1), reason: 'an admitted sender is not issued another code');
      expect(storedDmRows(), ['U1', 'U9'], reason: 'a restart rebuilds the controller from these rows');
    });

    test('a rejected pairing leaves the sender unadmitted and the allowlist unchanged', () async {
      await sendDm('U9', '100.1');
      final code = slackApi.posts.single.text.split('*')[1];

      await api().expectJsonObject('POST', '/api/channels/slack/dm-pairing/reject', json: {'code': code});

      await sendDm('U9', '101.1');
      expect(queue.enqueued, isEmpty);
      expect(storedDmRows(), ['U1']);
    });

    test('pairing-counts reports the Slack backlog beside the other channels', () async {
      await sendDm('U9', '100.1');

      final counts = await api().expectJsonObject('GET', '/api/channels/pairing-counts');

      expect(counts['slack'], 1);
    });

    test('with no Slack channel running, the pairing routes answer 404', () async {
      final bare = _routerFor(configPath: configPath, dataDir: p.join(tempDir.path, 'data'));

      await ApiRouteTestClient(bare.call).expectResponse('GET', '/api/channels/slack/dm-pairing', status: 404);
    });
  });

  group('allowlist', () {
    test('the DM allowlist is readable, appendable and removable, and the controller follows', () async {
      final read = await api().expectJsonObject('GET', '/api/config/channels/slack/dm-allowlist');
      expect(read['allowlist'], ['U1']);

      await api().expectJsonObject('POST', '/api/config/channels/slack/dm-allowlist', json: {'entry': 'W2'});
      expect(channel.dmAccess.isAllowed('W2'), isTrue);
      expect(storedDmRows(), ['U1', 'W2']);

      await api().expectJsonObject('DELETE', '/api/config/channels/slack/dm-allowlist', json: {'entry': 'W2'});
      expect(channel.dmAccess.isAllowed('W2'), isFalse);
      expect(storedDmRows(), ['U1']);
    });

    test('an entry that is not a Slack user ID is refused', () async {
      await api().expectResponse(
        'POST',
        '/api/config/channels/slack/dm-allowlist',
        json: {'entry': 'users/123'},
        status: 400,
      );
      expect(storedDmRows(), ['U1']);
    });
  });
}

Router _routerFor({required String configPath, required String dataDir, SlackChannel? slackChannel}) {
  const cfg = DartclawConfig.defaults();
  return configApiRoutes(
    config: cfg,
    writer: ConfigWriter(configPath: configPath),
    validator: const ConfigValidator(),
    runtimeConfig: RuntimeConfig(
      heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
      gitSyncEnabled: cfg.workspace.gitSyncEnabled,
      gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
    ),
    dataDir: dataDir,
    slackChannel: slackChannel,
  );
}
