import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../signal_test_support.dart';
import '../test_utils.dart';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late FakeSignalCliManager fakeSidecar;
  late SignalChannel signalChannel;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_signal_route_test_');
    sessions = SessionService(baseDir: tempDir.path);
    fakeSidecar = FakeSignalCliManager(
      fakeHealthy: true,
      fakeRegistered: false,
      fakeLinkUri: 'sgnl://linkdevice?uuid=test-uuid',
    );
    signalChannel = SignalChannel(
      sidecar: fakeSidecar,
      config: const SignalConfig(enabled: true, phoneNumber: '+15551234567'),
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: '+15551234567'),
    );
    final router = signalPairingRoutes(signalChannel: signalChannel, sessions: sessions, pageRegistry: PageRegistry());
    handler = const Pipeline().addHandler(router.call);
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('GET /pairing', () {
    test('sidecar healthy + registered shows "Signal Connected"', () async {
      fakeSidecar.fakeRegistered = true;
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('Signal Connected'));
    });

    test('sidecar healthy + not registered shows link device QR', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('sgnl://linkdevice'));
      expect(body, contains('Connect Signal'));
    });

    test('sidecar not reachable shows setup instructions', () async {
      fakeSidecar.fakeHealthy = false;
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('signal-cli Not Reachable'));
    });

    test('status probe failure shows clean setup card without leaking the exception', () async {
      fakeSidecar.healthCheckThrows = true;
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('signal-cli Not Reachable'));
      expect(body, isNot(contains('Failed to check signal-cli status')));
      expect(body, isNot(contains('SocketException')));
      expect(body, isNot(contains('errno')));
    });

    // TD-035: step=verify UI is hidden — route still works but GET /pairing
    // ignores the step param and shows the default link-device state.
    test('step=verify param is ignored (SMS UI hidden, TD-035)', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing?step=verify')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('Connect Signal'));
    });

    test('error query param shows error banner', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing?error=Something+went+wrong')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('Something went wrong'));
    });
  });

  // -------------------------------------------------------------------------
  group('POST /pairing/register', () {
    test('success redirects to verify step', () async {
      final res = await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register'), body: 'phone=%2B15551234567'),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], '/signal/pairing?step=verify');
      expect(fakeSidecar.smsRequested, isTrue);
    });

    test('missing phone redirects with error', () async {
      final res = await handler(Request('POST', Uri.parse('http://localhost/pairing/register')));
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('Phone+number+is+required'));
    });

    test('failure redirects with error', () async {
      fakeSidecar.smsThrows = true;
      final res = await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register'), body: 'phone=%2B15551234567'),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('/signal/pairing?error='));
      expect(res.headers['location'], contains('Failed'));
    });
  });

  // -------------------------------------------------------------------------
  group('POST /pairing/register-voice', () {
    test('success redirects to verify step', () async {
      final res = await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register-voice'), body: 'phone=%2B15551234567'),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], '/signal/pairing?step=verify');
      expect(fakeSidecar.voiceRequested, isTrue);
    });

    test('failure redirects with error', () async {
      fakeSidecar.voiceThrows = true;
      final res = await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register-voice'), body: 'phone=%2B15551234567'),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('/signal/pairing?error='));
      expect(res.headers['location'], contains('voice'));
    });

    test('sets voiceRequested flag on fake manager', () async {
      expect(fakeSidecar.voiceRequested, isFalse);
      await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register-voice'), body: 'phone=%2B15551234567'),
      );
      expect(fakeSidecar.voiceRequested, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('POST /pairing/disconnect', () {
    test('redirects to pairing page', () async {
      final res = await handler(Request('POST', Uri.parse('http://localhost/pairing/disconnect')));
      expect(res.statusCode, 302);
      expect(res.headers['location'], '/signal/pairing');
    });
  });

  // -------------------------------------------------------------------------
  group('POST /pairing/verify', () {
    test('valid code redirects to pairing page', () async {
      final res = await handler(Request('POST', Uri.parse('http://localhost/pairing/verify'), body: 'token=123456'));
      expect(res.statusCode, 302);
      expect(res.headers['location'], '/signal/pairing');
      expect(fakeSidecar.lastVerifyCode, '123456');
    });

    test('empty code redirects with error', () async {
      final res = await handler(Request('POST', Uri.parse('http://localhost/pairing/verify'), body: 'token='));
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('Code+is+required'));
    });

    test('missing token param redirects with error', () async {
      final res = await handler(Request('POST', Uri.parse('http://localhost/pairing/verify'), body: ''));
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('Code+is+required'));
    });

    test('verification failure redirects with error', () async {
      fakeSidecar.verifyThrows = true;
      final res = await handler(Request('POST', Uri.parse('http://localhost/pairing/verify'), body: 'token=999999'));
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('Verification+failed'));
    });
  });
}
