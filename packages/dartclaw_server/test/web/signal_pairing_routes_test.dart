import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

// ---------------------------------------------------------------------------
// Fake SignalCliManager — configurable sidecar behavior for route tests
// ---------------------------------------------------------------------------
class _FakeSignalCliManager extends SignalCliManager {
  bool fakeHealthy;
  bool fakeRegistered;
  String? fakeLinkUri;
  bool smsRequested = false;
  bool voiceRequested = false;
  String? lastVerifyCode;
  bool verifyThrows = false;
  bool smsThrows = false;
  bool voiceThrows = false;

  _FakeSignalCliManager({
    this.fakeHealthy = true,
    this.fakeRegistered = false,
    this.fakeLinkUri,
  }) : super(executable: 'signal-cli', phoneNumber: '+15551234567');

  @override
  bool get isRunning => fakeHealthy;

  @override
  Future<bool> healthCheck() async => fakeHealthy;

  @override
  Future<bool> isAccountRegistered() async => fakeRegistered;

  @override
  Future<String?> getLinkDeviceUri({String deviceName = 'DartClaw'}) async =>
      fakeLinkUri;

  @override
  Future<void> requestSmsVerification({String? phone, String? captcha}) async {
    if (smsThrows) throw Exception('SMS send failed');
    smsRequested = true;
  }

  @override
  Future<void> requestVoiceVerification({String? phone, String? captcha}) async {
    if (voiceThrows) throw Exception('Voice call failed');
    voiceRequested = true;
  }

  @override
  Future<void> verifySmsCode(String code, {String? phone}) async {
    lastVerifyCode = code;
    if (verifyThrows) throw Exception('Invalid code');
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> reset() async {}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late _FakeSignalCliManager fakeSidecar;
  late SignalChannel signalChannel;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_signal_route_test_');
    sessions = SessionService(baseDir: tempDir.path);
    fakeSidecar = _FakeSignalCliManager(
      fakeHealthy: true,
      fakeRegistered: false,
      fakeLinkUri: 'sgnl://linkdevice?uuid=test-uuid',
    );
    signalChannel = SignalChannel(
      sidecar: fakeSidecar,
      config: const SignalConfig(
        enabled: true,
        phoneNumber: '+15551234567',
      ),
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: SignalMentionGating(
        requireMention: false,
        mentionPatterns: [],
        ownNumber: '+15551234567',
      ),
    );
    final router = signalPairingRoutes(
      signalChannel: signalChannel,
      sessions: sessions,
    );
    handler = const Pipeline().addHandler(router.call);
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('GET /pairing', () {
    test('sidecar healthy + registered shows "Signal Connected"', () async {
      fakeSidecar.fakeRegistered = true;
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/pairing')),
      );
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('Signal Connected'));
    });

    test('sidecar healthy + not registered shows link device QR', () async {
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/pairing')),
      );
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('sgnl://linkdevice'));
      expect(body, contains('Connect Signal'));
    });

    test('sidecar not reachable shows setup instructions', () async {
      fakeSidecar.fakeHealthy = false;
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/pairing')),
      );
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('signal-cli Not Reachable'));
    });

    // TD-035: step=verify UI is hidden — route still works but GET /pairing
    // ignores the step param and shows the default link-device state.
    test('step=verify param is ignored (SMS UI hidden, TD-035)', () async {
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/pairing?step=verify')),
      );
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('Connect Signal'));
    });

    test('error query param shows error banner', () async {
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/pairing?error=Something+went+wrong')),
      );
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('Something went wrong'));
    });
  });

  // -------------------------------------------------------------------------
  group('POST /pairing/register', () {
    test('success redirects to verify step', () async {
      final res = await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register'),
            body: 'phone=%2B15551234567'),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], '/signal/pairing?step=verify');
      expect(fakeSidecar.smsRequested, isTrue);
    });

    test('missing phone redirects with error', () async {
      final res = await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register')),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('Phone+number+is+required'));
    });

    test('failure redirects with error', () async {
      fakeSidecar.smsThrows = true;
      final res = await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register'),
            body: 'phone=%2B15551234567'),
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
        Request('POST', Uri.parse('http://localhost/pairing/register-voice'),
            body: 'phone=%2B15551234567'),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], '/signal/pairing?step=verify');
      expect(fakeSidecar.voiceRequested, isTrue);
    });

    test('failure redirects with error', () async {
      fakeSidecar.voiceThrows = true;
      final res = await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register-voice'),
            body: 'phone=%2B15551234567'),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('/signal/pairing?error='));
      expect(res.headers['location'], contains('voice'));
    });

    test('sets voiceRequested flag on fake manager', () async {
      expect(fakeSidecar.voiceRequested, isFalse);
      await handler(
        Request('POST', Uri.parse('http://localhost/pairing/register-voice'),
            body: 'phone=%2B15551234567'),
      );
      expect(fakeSidecar.voiceRequested, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('POST /pairing/disconnect', () {
    test('redirects to pairing page', () async {
      final res = await handler(
        Request('POST', Uri.parse('http://localhost/pairing/disconnect')),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], '/signal/pairing');
    });
  });

  // -------------------------------------------------------------------------
  group('POST /pairing/verify', () {
    test('valid code redirects to pairing page', () async {
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/pairing/verify'),
          body: 'token=123456',
        ),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], '/signal/pairing');
      expect(fakeSidecar.lastVerifyCode, '123456');
    });

    test('empty code redirects with error', () async {
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/pairing/verify'),
          body: 'token=',
        ),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('Code+is+required'));
    });

    test('missing token param redirects with error', () async {
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/pairing/verify'),
          body: '',
        ),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('Code+is+required'));
    });

    test('verification failure redirects with error', () async {
      fakeSidecar.verifyThrows = true;
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/pairing/verify'),
          body: 'token=999999',
        ),
      );
      expect(res.statusCode, 302);
      expect(res.headers['location'], contains('Verification+failed'));
    });
  });
}
