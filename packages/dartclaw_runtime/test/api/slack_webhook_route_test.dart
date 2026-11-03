import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/server.dart'
    show ServerChannelDeps, ServerCoreDeps, ServerObservabilityDeps, ServerTurnDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../auth/auth_test_support.dart';
import '../test_utils.dart';
import '../whatsapp_test_support.dart';

const _path = '/integrations/slack';
const _signingSecret = 'plain-signing-secret-7c1e';
const _proxy = '192.168.1.100';

late String _staticDir;

/// One composed server around a Slack channel in a transport mode, with every
/// observable the route writes to: dispatched messages, failed-auth events,
/// audit entries and log records.
class _Rig {
  new _({
    required this.server,
    required this.channel,
    required this.queue,
    required this.events,
    required this.audit,
    required this.logs,
    required this.dispose,
  });

  final DartclawServer server;
  final SlackChannel channel;
  final RecordingMessageQueue queue;
  final List<FailedAuthEvent> events;
  final GuardAuditLogger audit;
  final List<LogRecord> logs;
  final Future<void> Function() dispose;

  static Future<_Rig> build({required String mode, bool authEnabled = true}) async {
    final tempDir = Directory.systemTemp.createTempSync('slack_webhook_route_');
    final eventBus = EventBus();
    final events = <FailedAuthEvent>[];
    final eventsSub = eventBus.on<FailedAuthEvent>().listen(events.add);
    final logs = <LogRecord>[];
    Logger.root.level = Level.ALL;
    final logSub = Logger.root.onRecord.listen(logs.add);

    final queue = RecordingMessageQueue(debounceWindow: Duration.zero);
    final channel = SlackChannel(
      config: const SlackConfig(enabled: true, dmAccess: DmAccessMode.open),
      api: FakeSlackWebApi(),
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: MentionGating(requireMention: true, mentionPatterns: const [], ownJid: ''),
      channelManager: ChannelManager(queue: queue, config: const ChannelConfig.defaults()),
      mode: mode,
      signingSecret: mode == 'events' ? _signingSecret : null,
    );
    channel.channelManager.registerChannel(channel);
    if (mode == 'events') await channel.connect();

    final sessions = SessionService(baseDir: p.join(tempDir.path, 'sessions'));
    final messages = MessageService(baseDir: p.join(tempDir.path, 'messages'));
    final worker = FakeAgentHarness();
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      auth: const AuthConfig(trustedProxies: [_proxy]),
    );
    final audit = GuardAuditLogger(dataDir: tempDir.path);
    final health = HealthService(
      worker: worker,
      searchDbPath: p.join(tempDir.path, 'search.db'),
      sessionsDir: p.join(tempDir.path, 'sessions'),
      tasksDir: p.join(tempDir.path, 'tasks'),
    )..slackReporter = channel.healthReporter;
    final server = composeServer(
      core: ServerCoreDeps(
        sessions: sessions,
        messages: messages,
        worker: worker,
        dataDir: tempDir.path,
        staticDir: _staticDir,
        authEnabled: authEnabled,
        gatewayToken: authEnabled ? 'gateway-token' : null,
        tokenService: authEnabled ? TokenService(token: 'gateway-token') : null,
        config: config,
        auditLogger: audit,
        healthService: health,
      ),
      turn: ServerTurnDeps(
        turns: composeServerTurns(
          sessions: sessions,
          messages: messages,
          worker: worker,
          behavior: BehaviorFileService(workspaceDir: p.join(tempDir.path, 'workspace')),
          config: config,
        ),
      ),
      channels: ServerChannelDeps(slackChannel: channel),
      observability: ServerObservabilityDeps(eventBus: eventBus),
    );
    return _Rig._(
      server: server,
      channel: channel,
      queue: queue,
      events: events,
      audit: audit,
      logs: logs,
      dispose: () async {
        await server.shutdown();
        await channel.disconnect();
        queue.dispose();
        await eventsSub.cancel();
        await logSub.cancel();
        await eventBus.dispose();
        tempDir.deleteSync(recursive: true);
      },
    );
  }

  Future<Response> post(
    Object body, {
    Map<String, String> headers = const {},
    String peer = '10.0.0.7',
    String path = _path,
  }) async => server.handler(
    Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: body,
      headers: {'host': 'localhost', ...headers},
      context: {'shelf.io.connection_info': FakeConnectionInfo(peer)},
    ),
  );

  Future<Response> postSigned(
    String body, {
    String secret = _signingSecret,
    int? timestamp,
    String contentType = 'application/json',
    String peer = '10.0.0.7',
    Map<String, String> headers = const {},
  }) {
    final bytes = utf8.encode(body);
    return post(
      bytes,
      headers: {
        ...signedSlackHeaders(secret, bytes, timestamp: timestamp, contentType: contentType),
        ...headers,
      },
      peer: peer,
    );
  }

  Future<List<Map<String, dynamic>>> auditEntries() async {
    await audit.flush();
    final file = File(audit.auditFilePath);
    if (!file.existsSync()) return const [];
    return file.readAsLinesSync().map(jsonDecode).cast<Map<String, dynamic>>().toList();
  }

  Future<String> health() async {
    final response = await server.handler(Request('GET', Uri.parse('http://localhost/health')));
    expect(response.statusCode, 200);
    return response.readAsString();
  }
}

String _dmEvent({String id = 'Ev1'}) => jsonEncode({
  'type': 'event_callback',
  'event_id': id,
  'event': {
    'type': 'message',
    'channel': 'D1',
    'channel_type': 'im',
    'user': 'U1',
    'text': 'hello from slack',
    'ts': '1700000000.000100',
  },
});

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  setUpAll(() async {
    initTemplates(await resolveTemplatesDir());
    _staticDir = await resolveStaticDir();
  });
  tearDownAll(resetTemplates);

  late _Rig rig;

  Future<void> start({String mode = 'events', bool authEnabled = true}) async {
    rig = await _Rig.build(mode: mode, authEnabled: authEnabled);
    addTearDown(rig.dispose);
  }

  group('events mode', () {
    setUp(start);

    test('a signed event answers 200 with an empty body, reaches the dispatch, and is not audited', () async {
      final response = await rig.postSigned(_dmEvent());
      await pumpEventQueue(times: 50);

      expect(response.statusCode, 200);
      expect(await response.readAsString(), isEmpty);
      expect(rig.queue.enqueued.map((e) => e.message.text), ['hello from slack']);
      expect(rig.events, isEmpty);
      expect(await rig.auditEntries(), isEmpty);
    });

    test(
      'an unsigned request gets the signature 401, not the gateway login, and gateway auth stays on elsewhere',
      () async {
        final response = await rig.post(utf8.encode(_dmEvent()));

        expect(response.statusCode, 401);
        expect(await response.readAsString(), 'Unauthorized');
        expect(response.headers, isNot(contains('location')));
        expect(rig.events.single.reason, 'missing_slack_signature');
        expect(rig.queue.enqueued, isEmpty);

        final elsewhere = await rig.post(utf8.encode('{}'), path: '/api/tasks');
        expect(elsewhere.statusCode, 401);
        expect(rig.events.map((e) => e.reason), ['missing_slack_signature', 'missing_credentials']);
      },
    );

    test('the exemption is the exact path, never a prefix', () async {
      final response = await rig.post(utf8.encode('{}'), path: '$_path/extra');

      expect(response.statusCode, 401);
      expect(rig.events.map((e) => e.reason), isNot(contains('missing_slack_signature')));
      expect(await rig.auditEntries(), isEmpty);
    });

    group('a refused request', () {
      final cases = <(String, Future<Response> Function(_Rig))>[
        ('missing_slack_signature', (r) => r.post(utf8.encode(_dmEvent()), peer: _proxy, headers: _forwarded)),
        (
          'stale_slack_timestamp',
          (r) => r.postSigned(_dmEvent(), timestamp: _now() - 301, peer: _proxy, headers: _forwarded),
        ),
        (
          'invalid_slack_signature',
          (r) => r.postSigned(_dmEvent(), secret: 'another-secret', peer: _proxy, headers: _forwarded),
        ),
      ];
      for (final (reason, send) in cases) {
        test('$reason answers 401 and leaves one failed-auth event and one audit entry', () async {
          final response = await send(rig);

          expect(response.statusCode, 401);
          expect(rig.queue.enqueued, isEmpty);
          expect(rig.events, hasLength(1));
          expect(rig.events.single.source, 'webhook');
          expect(rig.events.single.path, _path);
          expect(rig.events.single.reason, reason);
          expect(rig.events.single.remoteKey, '203.0.113.9', reason: 'the forwarded client of a trusted proxy');
          final entries = await rig.auditEntries();
          expect(entries, hasLength(1));
          expect(entries.single, containsPair('guard', 'slack_signature'));
          expect(entries.single, containsPair('hook', 'webhook'));
          expect(entries.single, containsPair('verdict', 'block'));
          expect(entries.single, containsPair('channel', 'slack'));
          expect(entries.single, containsPair('reason', reason));
          expect(entries.single, containsPair('peerId', '203.0.113.9'));
        });
      }
    });

    test('a body with non-ASCII text, reordered keys and trailing whitespace verifies over its exact bytes', () async {
      final response = await rig.postSigned('{"type":"url_verification",\n"challenge":"vérifié ✓"}  \n');

      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'vérifié ✓');
      expect(rig.events, isEmpty);
    });

    group('a body over 1 MiB', () {
      const oversized = 1024 * 1024 + 1;

      test('declared by Content-Length is refused 413 before anything is verified, reported or audited', () async {
        final response = await rig.post(List<int>.filled(oversized, 0x61), headers: {'content-length': '$oversized'});

        expect(response.statusCode, 413);
        expect(rig.channel.eventsHandler!.lastVerifiedAt, isNull);
        expect(rig.channel.eventsHandler!.lastRejection, isNull);
        expect(rig.events, isEmpty);
        expect(await rig.auditEntries(), isEmpty);
        expect(rig.queue.enqueued, isEmpty);
      });

      test('streamed in chunks without a length is refused 413 the same way', () async {
        final chunks = Stream.fromIterable([for (var i = 0; i < 17; i++) List<int>.filled(64 * 1024, 0x61)]);
        final response = await rig.post(chunks);

        expect(response.statusCode, 413);
        expect(rig.channel.eventsHandler!.lastRejection, isNull);
        expect(rig.events, isEmpty);
        expect(await rig.auditEntries(), isEmpty);
      });
    });

    test('another webhook\'s failed verification writes no audit entry', () async {
      final whatsApp = WhatsAppChannel(
        gowa: FakeGowaManager(),
        config: WhatsAppConfig(enabled: true),
        dmAccess: DmAccessController(mode: DmAccessMode.open),
        mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
        channelManager: FakeChannelManager(),
      );
      final router = webhookRoutes(whatsApp: whatsApp, webhookSecret: 'abc', auditLogger: rig.audit);

      final response = await router.call(
        Request('POST', Uri.parse('http://localhost/webhook/whatsapp?secret=wrong'), body: '{}'),
      );

      expect(response.statusCode, 403);
      expect(await rig.auditEntries(), isEmpty);
    });

    test(
      '/health carries Slack\'s state, and neither it, the audit trail nor the logs hold the signing secret',
      () async {
        final events = rig.channel.eventsHandler!;
        await rig.postSigned(_dmEvent(), secret: 'another-secret');
        await rig.postSigned(_dmEvent(id: 'Ev2'));
        await rig.postSigned(_dmEvent(id: 'Ev3'), secret: 'another-secret');

        final health = await rig.health();
        final slack = (jsonDecode(health) as Map<String, dynamic>)['slack'] as Map<String, dynamic>;
        expect(slack['mode'], 'events');
        expect(slack['last_failure_reason'], 'invalid_slack_signature');
        expect(slack, contains('last_verified_at'));
        expect(events.lastVerifiedAt, isNotNull);

        final audit = jsonEncode(await rig.auditEntries());
        final logged = rig.logs.map((r) => '${r.message} ${r.error ?? ''}').join('\n');
        for (final output in [health, audit, logged]) {
          expect(output, isNot(contains(_signingSecret)));
        }
      },
    );
  });

  group('socket mode', () {
    test('mounts nothing at the path: gateway auth answers an unsigned POST, and without auth it is a 404', () async {
      await start(mode: 'socket');

      final response = await rig.post(utf8.encode(_dmEvent()));

      expect(response.statusCode, 401);
      expect(await response.readAsString(), isNot('Unauthorized'));
      expect(rig.events.map((e) => e.reason), isNot(contains('missing_slack_signature')));
      expect(await rig.auditEntries(), isEmpty);
    });

    test('an instance without auth answers 404, so no route exists at the path', () async {
      await start(mode: 'socket', authEnabled: false);

      final response = await rig.post(utf8.encode(_dmEvent()));

      expect(response.statusCode, 404);
    });

    test('/health reports the socket transport', () async {
      await start(mode: 'socket');

      final slack = (jsonDecode(await rig.health()) as Map<String, dynamic>)['slack'] as Map<String, dynamic>;

      expect(slack['mode'], 'socket');
      expect(slack['connection'], 'disconnected');
    });
  });
}

const _forwarded = {'x-forwarded-for': '203.0.113.9'};
