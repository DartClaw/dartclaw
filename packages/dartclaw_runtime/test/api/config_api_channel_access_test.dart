import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/auth/request_auth_context.dart';
import 'package:path/path.dart' as p;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('channel_access_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();

    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
channels:
  whatsapp:
    enabled: true
    dm_access: pairing
    group_access: disabled
    require_mention: true
  signal:
    enabled: true
    dm_access: allowlist
    group_access: open
    require_mention: false
  google_chat:
    enabled: true
    service_account: /tmp/google-service-account.json
    audience:
      type: app-url
      value: https://example.com/integrations/googlechat
    webhook_path: /integrations/googlechat
    bot_user: users/123
    typing_indicator: false
    dm_access: allowlist
    dm_allowlist:
      - spaces/AAA/users/1
    group_access: open
    group_allowlist:
      - spaces/AAA
    require_mention: false
''');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Router createRouter({DartclawConfig? config}) {
    final channelConfigs = <String, Map<String, dynamic>>{
      'whatsapp': {'enabled': true, 'dm_access': 'pairing', 'group_access': 'disabled', 'require_mention': true},
      'signal': {'enabled': true, 'dm_access': 'allowlist', 'group_access': 'open', 'require_mention': false},
      'google_chat': {
        'enabled': true,
        'service_account': '/tmp/google-service-account.json',
        'audience': {'type': 'app-url', 'value': 'https://example.com/integrations/googlechat'},
        'webhook_path': '/integrations/googlechat',
        'bot_user': 'users/123',
        'typing_indicator': false,
        'dm_access': 'allowlist',
        'dm_allowlist': ['spaces/AAA/users/1'],
        'group_access': 'open',
        'group_allowlist': ['spaces/AAA'],
        'require_mention': false,
      },
    };
    final cfg = config ?? DartclawConfig(channels: ChannelConfig(channelConfigs: channelConfigs));
    final rc = RuntimeConfig(
      heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
      gitSyncEnabled: cfg.workspace.gitSyncEnabled,
      gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
    );

    return configApiRoutes(
      config: cfg,
      writer: ConfigWriter(configPath: configPath),
      validator: const ConfigValidator(),
      runtimeConfig: rc,
      dataDir: dataDir,
    );
  }

  ApiRouteTestClient api(Router router) {
    return ApiRouteTestClient(router.call);
  }

  ApiRouteTestClient adminApi(Router router) {
    return ApiRouteTestClient((request) => router.call(withAdminAuthContext(request)));
  }

  group('Channel access fields in GET /api/config', () {
    test('includes channels.whatsapp.dmAccess and channels.signal.dmAccess', () async {
      final router = createRouter();
      final body = await api(router).expectJsonObject('GET', '/api/config');

      final channels = body['channels'] as Map<String, dynamic>;

      expect(channels['whatsapp']['dmAccess'], 'pairing');
      expect(channels['whatsapp']['groupAccess'], 'disabled');
      expect(channels['whatsapp']['requireMention'], true);

      expect(channels['signal']['dmAccess'], 'allowlist');
      expect(channels['signal']['groupAccess'], 'open');
      expect(channels['signal']['requireMention'], false);

      expect(channels['googleChat']['enabled'], true);
      expect(channels['googleChat']['serviceAccount'], '/tmp/google-service-account.json');
      expect(channels['googleChat']['audience'], {
        'type': 'app-url',
        'value': 'https://example.com/integrations/googlechat',
      });
      expect(channels['googleChat']['webhookPath'], '/integrations/googlechat');
      expect(channels['googleChat']['botUser'], 'users/123');
      expect(channels['googleChat']['typingIndicator'], 'disabled');
      expect(channels['googleChat']['dmAccess'], 'allowlist');
      expect(channels['googleChat']['dmAllowlist'], ['spaces/AAA/users/1']);
      expect(channels['googleChat']['groupAccess'], 'open');
      expect(channels['googleChat']['groupAllowlist'], ['spaces/AAA']);
      expect(channels['googleChat']['requireMention'], false);
    });

    test('_meta.fields includes channel access field metadata', () async {
      final router = createRouter();
      final body = await api(router).expectJsonObject('GET', '/api/config');
      final fields = body['_meta']['fields'] as Map<String, dynamic>;

      expect(fields.containsKey('channels.whatsapp.dm_access'), isTrue);
      expect(fields.containsKey('channels.signal.dm_access'), isTrue);
      expect(fields.containsKey('channels.whatsapp.group_access'), isTrue);
      expect(fields.containsKey('channels.signal.require_mention'), isTrue);
      expect(fields.containsKey('channels.google_chat.dm_access'), isTrue);
      expect(fields.containsKey('channels.google_chat.service_account'), isTrue);
      expect(fields.containsKey('channels.google_chat.audience.type'), isTrue);
      expect(fields.containsKey('channels.google_chat.audience.value'), isTrue);
      expect(fields.containsKey('channels.google_chat.dm_allowlist'), isTrue);
      expect(fields.containsKey('channels.google_chat.webhook_path'), isTrue);
      expect(fields.containsKey('channels.google_chat.bot_user'), isTrue);
      expect(fields.containsKey('channels.google_chat.group_allowlist'), isTrue);
      final channelFieldKeys = fields.keys.where((key) => key.startsWith('channels.'));
      expect(
        channelFieldKeys,
        unorderedEquals(const {
          'channels.debounce_window_ms',
          'channels.max_queue_depth',
          'channels.retry_policy.max_attempts',
          'channels.retry_policy.base_delay_ms',
          'channels.retry_policy.jitter_factor',
          'channels.whatsapp.dm_access',
          'channels.whatsapp.group_access',
          'channels.whatsapp.require_mention',
          'channels.whatsapp.enabled',
          'channels.whatsapp.dm_allowlist',
          'channels.whatsapp.group_allowlist',
          'channels.whatsapp.mention_patterns',
          'channels.whatsapp.response_prefix',
          'channels.whatsapp.max_chunk_size',
          'channels.whatsapp.gowa_executable',
          'channels.whatsapp.gowa_host',
          'channels.whatsapp.gowa_port',
          'channels.whatsapp.gowa_db_uri',
          'channels.signal.dm_access',
          'channels.signal.group_access',
          'channels.signal.require_mention',
          'channels.signal.enabled',
          'channels.signal.phone_number',
          'channels.signal.executable',
          'channels.signal.host',
          'channels.signal.port',
          'channels.signal.dm_allowlist',
          'channels.signal.group_allowlist',
          'channels.signal.mention_patterns',
          'channels.signal.max_chunk_size',
          'channels.signal.response_prefix',
          'channels.google_chat.enabled',
          'channels.google_chat.service_account',
          'channels.google_chat.oauth_credentials',
          'channels.google_chat.audience.type',
          'channels.google_chat.audience.value',
          'channels.google_chat.webhook_path',
          'channels.google_chat.bot_user',
          'channels.google_chat.typing_indicator',
          'channels.google_chat.dm_access',
          'channels.google_chat.dm_allowlist',
          'channels.google_chat.group_access',
          'channels.google_chat.group_allowlist',
          'channels.google_chat.require_mention',
          'channels.google_chat.quote_reply',
          'channels.google_chat.reactions_auth',
          'channels.google_chat.pubsub.project_id',
          'channels.google_chat.pubsub.subscription',
          'channels.google_chat.pubsub.poll_interval_seconds',
          'channels.google_chat.pubsub.max_messages_per_pull',
          'channels.google_chat.space_events.enabled',
          'channels.google_chat.space_events.pubsub_topic',
          'channels.google_chat.space_events.event_types',
          'channels.google_chat.space_events.include_resource',
          'channels.google_chat.feedback.enabled',
          'channels.google_chat.feedback.min_feedback_delay',
          'channels.google_chat.feedback.status_interval',
          'channels.google_chat.feedback.status_style',
          'channels.google_chat.max_chunk_size',
          'channels.google_chat.mention_patterns',
          'channels.google_chat.response_prefix',
        }),
      );

      final waDmAccess = fields['channels.whatsapp.dm_access'] as Map<String, dynamic>;
      expect(waDmAccess['mutable'], 'restart');
      expect(waDmAccess['type'], 'enum');
      expect(waDmAccess['allowedValues'], ['open', 'disabled', 'allowlist', 'pairing']);

      final gcServiceAccount = fields['channels.google_chat.service_account'] as Map<String, dynamic>;
      expect(gcServiceAccount['mutable'], 'readonly');
      expect(gcServiceAccount['type'], 'string');
    });
  });

  group('PATCH /api/config channel access fields', () {
    test('valid dm_access change returns pendingRestart', () async {
      final router = createRouter();
      final body = await adminApi(router)
          .expectJsonObject('PATCH', '/api/config', json: {'channels.whatsapp.dm_access': 'allowlist'});

      expect(body['pendingRestart'], contains('channels.whatsapp.dm_access'));
      expect(body['errors'], isEmpty);
    });

    test('invalid dm_access value returns validation error', () async {
      final router = createRouter();
      final body = await adminApi(router)
          .expectJsonObject('PATCH', '/api/config', json: {'channels.whatsapp.dm_access': 'invalid'}, status: 400);

      expect(body['errors'], isNotEmpty);
    });

    test('Signal dm_access pairing succeeds', () async {
      final router = createRouter();
      final body = await adminApi(router)
          .expectJsonObject('PATCH', '/api/config', json: {'channels.signal.dm_access': 'pairing'});

      expect(body['pendingRestart'], contains('channels.signal.dm_access'));
      expect(body['errors'], isEmpty);
    });

    test('require_mention change returns pendingRestart', () async {
      final router = createRouter();
      final body = await adminApi(router)
          .expectJsonObject('PATCH', '/api/config', json: {'channels.whatsapp.require_mention': false});

      expect(body['pendingRestart'], contains('channels.whatsapp.require_mention'));
    });

    test('retired task trigger fields are rejected as unknown without writes', () async {
      final router = createRouter();
      final before = File(configPath).readAsStringSync();
      for (final channel in const ['whatsapp', 'signal', 'google_chat']) {
        for (final field in const ['enabled', 'prefix', 'default_type', 'auto_start']) {
          final path = 'channels.$channel.task_trigger.$field';
          final body = await adminApi(router).expectJsonObject(
            'PATCH',
            '/api/config',
            json: {path: field == 'prefix' || field == 'default_type' ? 'value' : true},
            status: 400,
          );
          final errors = (body['errors'] as List).cast<Map<String, dynamic>>();
          expect(errors.single['message'], "Unknown config field: '$path'");
        }
      }
      expect(File(configPath).readAsStringSync(), before);
    });

    test('google chat credential fields are rejected as unknown (not editable via API)', () async {
      final router = createRouter();
      final body = await adminApi(router).expectJsonObject(
        'PATCH',
        '/api/config',
        json: {
          'channels.google_chat.service_account': '/tmp/updated-google-service-account.json',
          'channels.google_chat.audience.type': 'project-number',
          'channels.google_chat.audience.value': '123456789',
        },
        status: 400,
      );

      final errors = (body['errors'] as List).cast<Map<String, dynamic>>();
      expect(errors, hasLength(3));
      final fields = errors.map((e) => e['field']).toSet();
      expect(
        fields,
        containsAll([
          'channels.google_chat.service_account',
          'channels.google_chat.audience.type',
          'channels.google_chat.audience.value',
        ]),
      );
    });

    test('google chat allowlist changes return pendingRestart', () async {
      final router = createRouter();
      final body = await adminApi(router).expectJsonObject(
        'PATCH',
        '/api/config',
        json: {
          'channels.google_chat.dm_allowlist': ['spaces/AAA/users/2'],
          'channels.google_chat.group_allowlist': ['spaces/BBB'],
        },
      );

      expect(
        body['pendingRestart'],
        containsAll(['channels.google_chat.dm_allowlist', 'channels.google_chat.group_allowlist']),
      );
      expect(body['errors'], isEmpty);
    });
  });
}
