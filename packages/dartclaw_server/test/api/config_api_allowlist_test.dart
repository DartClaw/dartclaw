import 'dart:io';

import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:path/path.dart' as p;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import '../signal_test_support.dart';
import '../whatsapp_test_support.dart';
import 'api_test_helpers.dart';

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

  Router createRouter({DmAccessController? waController, DmAccessController? sigController}) {
    final cfg = const DartclawConfig.defaults();
    final rc = RuntimeConfig(
      heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
      gitSyncEnabled: cfg.workspace.gitSyncEnabled,
      gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
    );
    final writer = ConfigWriter(configPath: configPath);

    // Create minimal fake channels with the provided controllers
    final WhatsAppChannel? waChannel;
    if (waController != null) {
      waChannel = WhatsAppChannel(
        gowa: FakeGowaManager(),
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
        sidecar: FakeSignalCliManager(),
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

  ApiRouteTestClient api(Router router) {
    return ApiRouteTestClient(router.call);
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
      final body = await api(router).expectJsonObject('GET', '/api/config/channels/whatsapp/dm-allowlist');

      expect(body['allowlist'], isEmpty);
    });

    test('POST adds entry, returns updated list', () async {
      final body = await api(router).expectJsonObject(
        'POST',
        '/api/config/channels/whatsapp/dm-allowlist',
        json: {'entry': '1234567890@s.whatsapp.net'},
      );

      expect(body['added'], isTrue);
      expect(body['allowlist'], contains('1234567890@s.whatsapp.net'));

      // Verify in controller
      expect(waCtrl.isAllowed('1234567890@s.whatsapp.net'), isTrue);
    });

    test('POST with invalid format returns 400', () async {
      await api(router).expectResponse(
        'POST',
        '/api/config/channels/whatsapp/dm-allowlist',
        json: {'entry': 'no-at-sign'},
        status: 400,
      );
    });

    test('POST duplicate returns 409', () async {
      waCtrl.addToAllowlist('dup@s.whatsapp.net');
      await api(router).expectResponse(
        'POST',
        '/api/config/channels/whatsapp/dm-allowlist',
        json: {'entry': 'dup@s.whatsapp.net'},
        status: 409,
      );
    });

    test('DELETE removes entry, returns updated list', () async {
      waCtrl.addToAllowlist('remove@s.whatsapp.net');
      final body = await api(router).expectJsonObject(
        'DELETE',
        '/api/config/channels/whatsapp/dm-allowlist',
        json: {'entry': 'remove@s.whatsapp.net'},
      );

      expect(body['removed'], isTrue);
      expect(body['allowlist'], isNot(contains('remove@s.whatsapp.net')));
      expect(waCtrl.isAllowed('remove@s.whatsapp.net'), isFalse);
    });

    test('DELETE non-existent entry returns 404', () async {
      await api(router).expectResponse(
        'DELETE',
        '/api/config/channels/whatsapp/dm-allowlist',
        json: {'entry': 'nonexistent@s.whatsapp.net'},
        status: 404,
      );
    });

    test('GET/POST/DELETE for unconfigured channel returns 404', () async {
      final noChannelsRouter = createRouter();

      await api(noChannelsRouter).expectResponse('GET', '/api/config/channels/whatsapp/dm-allowlist', status: 404);

      await api(noChannelsRouter).expectResponse(
        'POST',
        '/api/config/channels/whatsapp/dm-allowlist',
        json: {'entry': 'test@s.whatsapp.net'},
        status: 404,
      );

      await api(noChannelsRouter).expectResponse(
        'DELETE',
        '/api/config/channels/whatsapp/dm-allowlist',
        json: {'entry': 'test@s.whatsapp.net'},
        status: 404,
      );
    });

    test('Signal: POST with UUID entry succeeds', () async {
      final body = await api(router).expectJsonObject(
        'POST',
        '/api/config/channels/signal/dm-allowlist',
        json: {'entry': '12bfcd5a-3363-45f4-94b6-3fe247f11ab8'},
      );

      expect(body['added'], isTrue);
      expect(sigCtrl.isAllowed('12bfcd5a-3363-45f4-94b6-3fe247f11ab8'), isTrue);
    });

    test('Signal: POST with phone entry succeeds', () async {
      final body = await api(
        router,
      ).expectJsonObject('POST', '/api/config/channels/signal/dm-allowlist', json: {'entry': '+1234567890'});

      expect(body['added'], isTrue);
      expect(sigCtrl.isAllowed('+1234567890'), isTrue);
    });

    test('WhatsApp: POST with JID entry succeeds', () async {
      await api(router).expectResponse(
        'POST',
        '/api/config/channels/whatsapp/dm-allowlist',
        json: {'entry': '1234567890@s.whatsapp.net'},
        status: 200,
      );
    });

    test('WhatsApp: POST without @ returns 400', () async {
      await api(router).expectResponse(
        'POST',
        '/api/config/channels/whatsapp/dm-allowlist',
        json: {'entry': '1234567890'},
        status: 400,
      );
    });
  });
}
