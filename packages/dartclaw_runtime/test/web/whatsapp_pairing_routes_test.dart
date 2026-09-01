import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';
import '../whatsapp_test_support.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late FakeGowaManager fakeGowa;
  late WhatsAppChannel channel;
  late Handler handler;

  void buildHandler(FakeGowaManager gowa) {
    fakeGowa = gowa;
    channel = WhatsAppChannel(
      gowa: fakeGowa,
      config: const WhatsAppConfig(enabled: true),
      dmAccess: DmAccessController(mode: DmAccessMode.pairing),
      mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
    );
    final router = whatsappPairingRoutes(whatsAppChannel: channel, sessions: sessions, pageRegistry: PageRegistry());
    handler = const Pipeline().addHandler(router.call);
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wa_route_test_');
    sessions = SessionService(baseDir: tempDir.path);
    buildHandler(FakeGowaManager(running: false));
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('GET /pairing — sidecar unreachable', () {
    test('renders the clean "Not Connected" setup card', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('Not Connected'));
      expect(body, contains('GOWA sidecar is not running or not ready'));
      expect(body, contains('class="well-deep"'));
      expect(body, isNot(contains('style="')));
      expect(body, isNot(contains('wa-')));
      expect(fakeGowa.statusRequests, 0);
    });

    test('does not leak the raw exception into the UI', () async {
      buildHandler(FakeGowaManager(running: true, statusThrows: true));
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      final body = await res.readAsString();
      expect(fakeGowa.statusRequests, 1);
      expect(body, isNot(contains('Failed to check GOWA status')));
      expect(body, isNot(contains('SocketException')));
      expect(body, isNot(contains('errno')));
    });
  });

  group('POST /pairing/code', () {
    test('refuses an oversized body instead of buffering it', () async {
      buildHandler(FakeGowaManager(running: true));
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/pairing/code'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'phone=%2B46700000000&pad=${'x' * 9000}',
        ),
      );

      expect(res.statusCode, 413);
      expect(res.headers['location'], isNull);
    });
  });
}
