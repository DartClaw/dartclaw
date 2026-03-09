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
    tempDir = Directory.systemTemp.createTempSync('allowlist_api_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();

    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
channels:
  whatsapp:
    enabled: true
    dm_allowlist: []
  signal:
    enabled: true
    dm_allowlist: []
''');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Router createRouter({
    DmAccessController? waController,
    DmAccessController? sigController,
  }) {
    final cfg = const DartclawConfig.defaults();
    final rc = RuntimeConfig(
      heartbeatEnabled: cfg.heartbeatEnabled,
      gitSyncEnabled: cfg.gitSyncEnabled,
      gitSyncPushEnabled: cfg.gitSyncPushEnabled,
    );
    final writer = ConfigWriter(configPath: configPath);

    // Create minimal fake channels with the provided controllers
    final WhatsAppChannel? waChannel;
    if (waController != null) {
      waChannel = WhatsAppChannel(
        gowa: _FakeGowaManager(),
        config: const WhatsAppConfig(enabled: true),
        dmAccess: waController,
        mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
        workspaceDir: tempDir.path,
      );
    } else {
      waChannel = null;
    }

    final SignalChannel? sigChannel;
    if (sigController != null) {
      sigChannel = SignalChannel(
        sidecar: _FakeSignalCliManager(),
        config: const SignalConfig(enabled: true),
        dmAccess: sigController,
        mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ''),
      );
    } else {
      sigChannel = null;
    }

    return configApiRoutes(
      config: cfg,
      writer: writer,
      validator: const ConfigValidator(),
      runtimeConfig: rc,
      dataDir: dataDir,
      whatsAppChannel: waChannel,
      signalChannel: sigChannel,
    );
  }

  Future<Response> request(Router router, String method, String path, [Map<String, dynamic>? body]) {
    final req = Request(
      method,
      Uri.parse('http://localhost$path'),
      body: body != null ? jsonEncode(body) : null,
      headers: body != null ? {'content-type': 'application/json'} : {},
    );
    return router.call(req);
  }

  Future<Map<String, dynamic>> parseBody(Response response) async {
    return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  }

  group('Allowlist CRUD', () {
    late DmAccessController waCtrl;
    late DmAccessController sigCtrl;
    late Router router;

    setUp(() {
      waCtrl = DmAccessController(mode: DmAccessMode.allowlist);
      sigCtrl = DmAccessController(mode: DmAccessMode.allowlist);
      router = createRouter(waController: waCtrl, sigController: sigCtrl);
    });

    test('GET returns empty allowlist initially', () async {
      final resp = await request(router, 'GET', '/api/config/channels/whatsapp/dm-allowlist');
      expect(resp.statusCode, 200);
      final body = await parseBody(resp);
      expect(body['allowlist'], isEmpty);
    });

    test('POST adds entry, returns updated list', () async {
      final resp = await request(router, 'POST', '/api/config/channels/whatsapp/dm-allowlist', {
        'entry': '1234567890@s.whatsapp.net',
      });
      expect(resp.statusCode, 200);
      final body = await parseBody(resp);
      expect(body['added'], isTrue);
      expect(body['allowlist'], contains('1234567890@s.whatsapp.net'));

      // Verify in controller
      expect(waCtrl.isAllowed('1234567890@s.whatsapp.net'), isTrue);
    });

    test('POST with invalid format returns 400', () async {
      final resp = await request(router, 'POST', '/api/config/channels/whatsapp/dm-allowlist', {
        'entry': 'no-at-sign',
      });
      expect(resp.statusCode, 400);
    });

    test('POST duplicate returns 409', () async {
      waCtrl.addToAllowlist('dup@s.whatsapp.net');
      final resp = await request(router, 'POST', '/api/config/channels/whatsapp/dm-allowlist', {
        'entry': 'dup@s.whatsapp.net',
      });
      expect(resp.statusCode, 409);
    });

    test('DELETE removes entry, returns updated list', () async {
      waCtrl.addToAllowlist('remove@s.whatsapp.net');
      final resp = await request(router, 'DELETE', '/api/config/channels/whatsapp/dm-allowlist', {
        'entry': 'remove@s.whatsapp.net',
      });
      expect(resp.statusCode, 200);
      final body = await parseBody(resp);
      expect(body['removed'], isTrue);
      expect(body['allowlist'], isNot(contains('remove@s.whatsapp.net')));
      expect(waCtrl.isAllowed('remove@s.whatsapp.net'), isFalse);
    });

    test('DELETE non-existent entry returns 404', () async {
      final resp = await request(router, 'DELETE', '/api/config/channels/whatsapp/dm-allowlist', {
        'entry': 'nonexistent@s.whatsapp.net',
      });
      expect(resp.statusCode, 404);
    });

    test('GET/POST/DELETE for unconfigured channel returns 404', () async {
      final noChannelsRouter = createRouter();

      var resp = await request(noChannelsRouter, 'GET', '/api/config/channels/whatsapp/dm-allowlist');
      expect(resp.statusCode, 404);

      resp = await request(noChannelsRouter, 'POST', '/api/config/channels/whatsapp/dm-allowlist', {
        'entry': 'test@s.whatsapp.net',
      });
      expect(resp.statusCode, 404);

      resp = await request(noChannelsRouter, 'DELETE', '/api/config/channels/whatsapp/dm-allowlist', {
        'entry': 'test@s.whatsapp.net',
      });
      expect(resp.statusCode, 404);
    });

    test('Signal: POST with UUID entry succeeds', () async {
      final resp = await request(router, 'POST', '/api/config/channels/signal/dm-allowlist', {
        'entry': '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
      });
      expect(resp.statusCode, 200);
      final body = await parseBody(resp);
      expect(body['added'], isTrue);
      expect(sigCtrl.isAllowed('12bfcd5a-3363-45f4-94b6-3fe247f11ab8'), isTrue);
    });

    test('Signal: POST with phone entry succeeds', () async {
      final resp = await request(router, 'POST', '/api/config/channels/signal/dm-allowlist', {
        'entry': '+1234567890',
      });
      expect(resp.statusCode, 200);
      final body = await parseBody(resp);
      expect(body['added'], isTrue);
      expect(sigCtrl.isAllowed('+1234567890'), isTrue);
    });

    test('WhatsApp: POST with JID entry succeeds', () async {
      final resp = await request(router, 'POST', '/api/config/channels/whatsapp/dm-allowlist', {
        'entry': '1234567890@s.whatsapp.net',
      });
      expect(resp.statusCode, 200);
    });

    test('WhatsApp: POST without @ returns 400', () async {
      final resp = await request(router, 'POST', '/api/config/channels/whatsapp/dm-allowlist', {
        'entry': '1234567890',
      });
      expect(resp.statusCode, 400);
    });
  });
}

// --- Fakes ---

class _FakeGowaManager extends GowaManager {
  _FakeGowaManager() : super(executable: '', host: '', port: 0, webhookUrl: '', osName: '');

  @override
  Future<void> start() async {}

  @override
  Future<void> reset() async {}
}

class _FakeSignalCliManager extends SignalCliManager {
  _FakeSignalCliManager() : super(executable: '', host: '', port: 0, phoneNumber: '');

  @override
  Future<void> start() async {}

  @override
  Future<void> reset() async {}
}
