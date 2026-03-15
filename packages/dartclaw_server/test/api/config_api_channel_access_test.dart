import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

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
    task_trigger:
      enabled: true
      prefix: "task:"
      default_type: coding
      auto_start: false
  signal:
    enabled: true
    dm_access: allowlist
    group_access: open
    require_mention: false
    task_trigger:
      enabled: false
      prefix: "do:"
      default_type: analysis
      auto_start: true
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
    task_trigger:
      enabled: true
      prefix: "create:"
      default_type: automation
      auto_start: true
''');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Router createRouter({DartclawConfig? config}) {
    final channelConfigs = <String, Map<String, dynamic>>{
      'whatsapp': {
        'enabled': true,
        'dm_access': 'pairing',
        'group_access': 'disabled',
        'require_mention': true,
        'task_trigger': {'enabled': true, 'prefix': 'task:', 'default_type': 'coding', 'auto_start': false},
      },
      'signal': {
        'enabled': true,
        'dm_access': 'allowlist',
        'group_access': 'open',
        'require_mention': false,
        'task_trigger': {'enabled': false, 'prefix': 'do:', 'default_type': 'analysis', 'auto_start': true},
      },
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
        'task_trigger': {'enabled': true, 'prefix': 'create:', 'default_type': 'automation', 'auto_start': true},
      },
    };
    final cfg = config ?? DartclawConfig(channelConfig: ChannelConfig(channelConfigs: channelConfigs));
    final rc = RuntimeConfig(
      heartbeatEnabled: cfg.heartbeatEnabled,
      gitSyncEnabled: cfg.gitSyncEnabled,
      gitSyncPushEnabled: cfg.gitSyncPushEnabled,
    );

    return configApiRoutes(
      config: cfg,
      writer: ConfigWriter(configPath: configPath),
      validator: const ConfigValidator(),
      runtimeConfig: rc,
      dataDir: dataDir,
    );
  }

  Future<Response> get(Router router, String path) {
    final request = Request('GET', Uri.parse('http://localhost$path'));
    return router.call(request);
  }

  Future<Response> patch(Router router, String path, Map<String, dynamic> body) {
    final request = Request(
      'PATCH',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
    return router.call(request);
  }

  Future<Map<String, dynamic>> parseBody(Response response) async {
    return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  }

  group('Channel access fields in GET /api/config', () {
    test('includes channels.whatsapp.dmAccess and channels.signal.dmAccess', () async {
      final router = createRouter();
      final resp = await get(router, '/api/config');
      expect(resp.statusCode, 200);

      final body = await parseBody(resp);
      final channels = body['channels'] as Map<String, dynamic>;

      expect(channels['whatsapp']['dmAccess'], 'pairing');
      expect(channels['whatsapp']['groupAccess'], 'disabled');
      expect(channels['whatsapp']['requireMention'], true);
      expect(channels['whatsapp']['taskTrigger'], {
        'enabled': true,
        'prefix': 'task:',
        'defaultType': 'coding',
        'autoStart': false,
      });

      expect(channels['signal']['dmAccess'], 'allowlist');
      expect(channels['signal']['groupAccess'], 'open');
      expect(channels['signal']['requireMention'], false);
      expect(channels['signal']['taskTrigger'], {
        'enabled': false,
        'prefix': 'do:',
        'defaultType': 'analysis',
        'autoStart': true,
      });

      expect(channels['googleChat']['enabled'], true);
      expect(channels['googleChat']['serviceAccount'], '/tmp/google-service-account.json');
      expect(channels['googleChat']['audience'], {
        'type': 'app-url',
        'value': 'https://example.com/integrations/googlechat',
      });
      expect(channels['googleChat']['webhookPath'], '/integrations/googlechat');
      expect(channels['googleChat']['botUser'], 'users/123');
      expect(channels['googleChat']['typingIndicator'], false);
      expect(channels['googleChat']['dmAccess'], 'allowlist');
      expect(channels['googleChat']['dmAllowlist'], ['spaces/AAA/users/1']);
      expect(channels['googleChat']['groupAccess'], 'open');
      expect(channels['googleChat']['groupAllowlist'], ['spaces/AAA']);
      expect(channels['googleChat']['requireMention'], false);
      expect(channels['googleChat']['taskTrigger'], {
        'enabled': true,
        'prefix': 'create:',
        'defaultType': 'automation',
        'autoStart': true,
      });
    });

    test('_meta.fields includes channel access field metadata', () async {
      final router = createRouter();
      final resp = await get(router, '/api/config');
      final body = await parseBody(resp);
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
      expect(fields.containsKey('channels.whatsapp.task_trigger.enabled'), isTrue);
      expect(fields.containsKey('channels.whatsapp.task_trigger.prefix'), isTrue);
      expect(fields.containsKey('channels.whatsapp.task_trigger.default_type'), isTrue);
      expect(fields.containsKey('channels.whatsapp.task_trigger.auto_start'), isTrue);
      expect(fields.containsKey('channels.signal.task_trigger.enabled'), isTrue);
      expect(fields.containsKey('channels.signal.task_trigger.prefix'), isTrue);
      expect(fields.containsKey('channels.signal.task_trigger.default_type'), isTrue);
      expect(fields.containsKey('channels.signal.task_trigger.auto_start'), isTrue);
      expect(fields.containsKey('channels.google_chat.task_trigger.enabled'), isTrue);
      expect(fields.containsKey('channels.google_chat.task_trigger.prefix'), isTrue);
      expect(fields.containsKey('channels.google_chat.task_trigger.default_type'), isTrue);
      expect(fields.containsKey('channels.google_chat.task_trigger.auto_start'), isTrue);

      final waDmAccess = fields['channels.whatsapp.dm_access'] as Map<String, dynamic>;
      expect(waDmAccess['mutable'], 'restart');
      expect(waDmAccess['type'], 'enum');
      expect(waDmAccess['allowedValues'], ['open', 'disabled', 'allowlist', 'pairing']);

      final gcServiceAccount = fields['channels.google_chat.service_account'] as Map<String, dynamic>;
      expect(gcServiceAccount['mutable'], 'readonly');
      expect(gcServiceAccount['type'], 'string');

      final waTaskTriggerPrefix = fields['channels.whatsapp.task_trigger.prefix'] as Map<String, dynamic>;
      expect(waTaskTriggerPrefix['mutable'], 'restart');
      expect(waTaskTriggerPrefix['type'], 'string');

      final waTaskTriggerDefaultType = fields['channels.whatsapp.task_trigger.default_type'] as Map<String, dynamic>;
      expect(waTaskTriggerDefaultType['mutable'], 'restart');
      expect(waTaskTriggerDefaultType['type'], 'string');
      expect(waTaskTriggerDefaultType.containsKey('allowedValues'), isFalse);
    });
  });

  group('PATCH /api/config channel access fields', () {
    test('valid dm_access change returns pendingRestart', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {'channels.whatsapp.dm_access': 'allowlist'});
      expect(resp.statusCode, 200);

      final body = await parseBody(resp);
      expect(body['pendingRestart'], contains('channels.whatsapp.dm_access'));
      expect(body['errors'], isEmpty);
    });

    test('invalid dm_access value returns validation error', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {'channels.whatsapp.dm_access': 'invalid'});
      expect(resp.statusCode, 400);

      final body = await parseBody(resp);
      expect(body['errors'], isNotEmpty);
    });

    test('Signal dm_access pairing succeeds', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {'channels.signal.dm_access': 'pairing'});
      expect(resp.statusCode, 200);

      final body = await parseBody(resp);
      expect(body['pendingRestart'], contains('channels.signal.dm_access'));
      expect(body['errors'], isEmpty);
    });

    test('require_mention change returns pendingRestart', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {'channels.whatsapp.require_mention': false});
      expect(resp.statusCode, 200);

      final body = await parseBody(resp);
      expect(body['pendingRestart'], contains('channels.whatsapp.require_mention'));
    });

    test('task trigger changes return pendingRestart', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {
        'channels.whatsapp.task_trigger.enabled': false,
        'channels.whatsapp.task_trigger.prefix': 'do:',
        'channels.whatsapp.task_trigger.default_type': 'analysis',
        'channels.whatsapp.task_trigger.auto_start': true,
      });
      expect(resp.statusCode, 200);

      final body = await parseBody(resp);
      expect(
        body['pendingRestart'],
        containsAll([
          'channels.whatsapp.task_trigger.enabled',
          'channels.whatsapp.task_trigger.prefix',
          'channels.whatsapp.task_trigger.default_type',
          'channels.whatsapp.task_trigger.auto_start',
        ]),
      );
      expect(body['errors'], isEmpty);
    });

    test('unknown task trigger default_type passes validation and round-trips from disk', () async {
      final router = createRouter();
      final patchResp = await patch(router, '/api/config', {
        'channels.whatsapp.task_trigger.default_type': 'future_type',
      });
      expect(patchResp.statusCode, 200);

      final patchBody = await parseBody(patchResp);
      expect(patchBody['pendingRestart'], contains('channels.whatsapp.task_trigger.default_type'));
      expect(patchBody['errors'], isEmpty);

      final getResp = await get(router, '/api/config');
      expect(getResp.statusCode, 200);

      final getBody = await parseBody(getResp);
      final channels = getBody['channels'] as Map<String, dynamic>;
      expect(channels['whatsapp']['taskTrigger']['defaultType'], 'future_type');
    });

    test('task trigger default_type is trimmed on PATCH before persisting', () async {
      final router = createRouter();
      final patchResp = await patch(router, '/api/config', {
        'channels.whatsapp.task_trigger.default_type': ' analysis ',
      });
      expect(patchResp.statusCode, 200);

      final patchBody = await parseBody(patchResp);
      expect(patchBody['pendingRestart'], contains('channels.whatsapp.task_trigger.default_type'));
      expect(patchBody['errors'], isEmpty);

      final configContents = File(configPath).readAsStringSync();
      expect(
        RegExp(r'''^\s*default_type:\s*['"]?analysis['"]?\s*$''', multiLine: true).hasMatch(configContents),
        isTrue,
      );
    });

    test('blank task trigger prefix fails validation', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {'channels.whatsapp.task_trigger.prefix': '   '});
      expect(resp.statusCode, 400);

      final body = await parseBody(resp);
      final errors = (body['errors'] as List).cast<Map<String, dynamic>>();
      expect(errors.single['field'], 'channels.whatsapp.task_trigger.prefix');
    });

    test('google chat credential fields are rejected as unknown (not editable via API)', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {
        'channels.google_chat.service_account': '/tmp/updated-google-service-account.json',
        'channels.google_chat.audience.type': 'project-number',
        'channels.google_chat.audience.value': '123456789',
      });
      expect(resp.statusCode, 400);

      final body = await parseBody(resp);
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
      final resp = await patch(router, '/api/config', {
        'channels.google_chat.dm_allowlist': ['spaces/AAA/users/2'],
        'channels.google_chat.group_allowlist': ['spaces/BBB'],
      });
      expect(resp.statusCode, 200);

      final body = await parseBody(resp);
      expect(
        body['pendingRestart'],
        containsAll(['channels.google_chat.dm_allowlist', 'channels.google_chat.group_allowlist']),
      );
      expect(body['errors'], isEmpty);
    });
  });
}
