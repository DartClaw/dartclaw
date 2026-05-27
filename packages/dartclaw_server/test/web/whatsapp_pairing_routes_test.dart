import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// Fake GOWA sidecar whose [status] throws as if the sidecar is unreachable
/// (connection refused), reproducing the "sidecar not running" pairing state.
class _UnreachableGowaManager extends GowaManager {
  _UnreachableGowaManager() : super(executable: '', host: '', port: 0, webhookUrl: '', osName: '');

  @override
  bool get isRunning => false;

  @override
  Future<GowaStatus> status() async => throw const SocketException(
    'Connection refused (OS Error: Connection refused, errno = 61), address = 127.0.0.1, port = 58402',
  );

  @override
  Future<void> start() async {}

  @override
  Future<void> reset() async {}
}

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late WhatsAppChannel channel;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wa_route_test_');
    sessions = SessionService(baseDir: tempDir.path);
    channel = WhatsAppChannel(
      gowa: _UnreachableGowaManager(),
      config: const WhatsAppConfig(enabled: true),
      dmAccess: DmAccessController(mode: DmAccessMode.pairing),
      mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
      workspaceDir: tempDir.path,
    );
    final router = whatsappPairingRoutes(whatsAppChannel: channel, sessions: sessions, pageRegistry: PageRegistry());
    handler = const Pipeline().addHandler(router.call);
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
    });

    test('does not leak the raw exception into the UI', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      final body = await res.readAsString();
      expect(body, isNot(contains('Failed to check GOWA status')));
      expect(body, isNot(contains('SocketException')));
      expect(body, isNot(contains('errno')));
    });
  });
}
