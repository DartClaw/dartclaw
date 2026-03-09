import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/channel/channel_config.dart';
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
  signal:
    enabled: true
    dm_access: allowlist
    group_access: open
    require_mention: false
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
      },
      'signal': {
        'enabled': true,
        'dm_access': 'allowlist',
        'group_access': 'open',
        'require_mention': false,
      },
    };
    final cfg = config ??
        DartclawConfig.defaults().copyWith(
          channelConfig: ChannelConfig(channelConfigs: channelConfigs),
        );
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

      expect(channels['signal']['dmAccess'], 'allowlist');
      expect(channels['signal']['groupAccess'], 'open');
      expect(channels['signal']['requireMention'], false);
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

      final waDmAccess = fields['channels.whatsapp.dm_access'] as Map<String, dynamic>;
      expect(waDmAccess['mutable'], 'restart');
      expect(waDmAccess['type'], 'enum');
      expect(waDmAccess['allowedValues'], ['open', 'disabled', 'allowlist', 'pairing']);
    });
  });

  group('PATCH /api/config channel access fields', () {
    test('valid dm_access change returns pendingRestart', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {
        'channels.whatsapp.dm_access': 'allowlist',
      });
      expect(resp.statusCode, 200);

      final body = await parseBody(resp);
      expect(body['pendingRestart'], contains('channels.whatsapp.dm_access'));
      expect(body['errors'], isEmpty);
    });

    test('invalid dm_access value returns validation error', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {
        'channels.whatsapp.dm_access': 'invalid',
      });
      expect(resp.statusCode, 400);

      final body = await parseBody(resp);
      expect(body['errors'], isNotEmpty);
    });

    test('Signal dm_access pairing succeeds', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {
        'channels.signal.dm_access': 'pairing',
      });
      expect(resp.statusCode, 200);

      final body = await parseBody(resp);
      expect(body['pendingRestart'], contains('channels.signal.dm_access'));
      expect(body['errors'], isEmpty);
    });

    test('require_mention change returns pendingRestart', () async {
      final router = createRouter();
      final resp = await patch(router, '/api/config', {
        'channels.whatsapp.require_mention': false,
      });
      expect(resp.statusCode, 200);

      final body = await parseBody(resp);
      expect(body['pendingRestart'], contains('channels.whatsapp.require_mention'));
    });
  });
}

/// Extension to add copyWith to DartclawConfig for testing.
extension _DartclawConfigCopyWith on DartclawConfig {
  DartclawConfig copyWith({ChannelConfig? channelConfig}) {
    return DartclawConfig(
      port: port,
      host: host,
      name: name,
      dataDir: dataDir,
      workerTimeout: workerTimeout,
      memoryMaxBytes: memoryMaxBytes,
      channelConfig: channelConfig ?? this.channelConfig,
    );
  }
}
