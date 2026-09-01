import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../signal_test_support.dart';
import '../test_utils.dart';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late FakeSignalCliManager fakeSidecar;
  late SignalChannel signalChannel;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_signal_route_test_');
    sessions = SessionService(baseDir: tempDir.path);
    fakeSidecar = FakeSignalCliManager(fakeHealthy: true, fakeLinkUri: 'sgnl://linkdevice?uuid=test-uuid');
    signalChannel = SignalChannel(
      sidecar: fakeSidecar,
      config: const SignalConfig(enabled: true, phoneNumber: '+15551234567'),
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: '+15551234567'),
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
      fakeSidecar.fakeRegistrationState = SignalRegistrationState.registered;
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
      expect(body, contains('class="well pairing-section pairing-qr-section"'));
      expect(body, contains('class="pairing-qr-frame"'));
      expect(body, isNot(contains('style="')));
      expect(body, isNot(contains('wa-')));
      expect(fakeSidecar.linkUriRequests, 1);
    });

    test('indeterminate registration does not start linking', () async {
      fakeSidecar.fakeRegistrationState = SignalRegistrationState.unknown;

      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      final body = await res.readAsString();

      expect(res.statusCode, 200);
      expect(body, contains('Registration Status Unavailable'));
      expect(body, isNot(contains('Connect Signal')));
      expect(fakeSidecar.linkUriRequests, 0);
    });

    test('sidecar not reachable shows setup instructions', () async {
      fakeSidecar.fakeRunning = false;
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('signal-cli Not Reachable'));
      expect(body, contains('class="well-deep pairing-config-block"'));
      expect(body, isNot(contains('style="')));
      expect(body, isNot(contains('wa-')));
      expect(fakeSidecar.healthCheckRequests, 0);
    });

    test('sidecar restart backoff shows reconnecting state without probing', () async {
      fakeSidecar
        ..fakeRunning = false
        ..fakeWasPaired = true
        ..fakeRestartCount = 2;

      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      final body = await res.readAsString();

      expect(res.statusCode, 200);
      expect(body, contains('Reconnecting'));
      expect(body, contains('Attempt'));
      expect(body, contains('2 of 5'));
      expect(fakeSidecar.healthCheckRequests, 0);
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

    test('unknown step and phone params are inert', () async {
      for (final query in const ['?step=verify', '?step=captcha&phone=%2B15551234567']) {
        final res = await handler(Request('GET', Uri.parse('http://localhost/pairing$query')));
        expect(res.statusCode, 200, reason: query);
        expect(_stateCards(await res.readAsString()), unorderedEquals(<String>{'Connect Signal'}), reason: query);
      }
    });

    test('error query param shows error banner', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing?error=Something+went+wrong')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      expect(body, contains('Something went wrong'));
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
  group('deleted registration routes', () {
    for (final path in const ['/pairing/register', '/pairing/register-voice', '/pairing/verify']) {
      test('POST $path is unrouted', () async {
        final res = await handler(
          Request('POST', Uri.parse('http://localhost$path'), body: 'phone=%2B15551234567&token=123456'),
        );
        expect(res.statusCode, 404);
      });
    }
  });

  // -------------------------------------------------------------------------
  group('rendered state cards', () {
    Future<Set<String>> renderedCards() async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      expect(res.statusCode, 200);
      return _stateCards(await res.readAsString());
    }

    test('registered sidecar renders only the connected card', () async {
      fakeSidecar.fakeRegistrationState = SignalRegistrationState.registered;
      expect(await renderedCards(), unorderedEquals(<String>{'Signal Connected'}));
    });

    test('unregistered sidecar renders only the link-device card', () async {
      expect(await renderedCards(), unorderedEquals(<String>{'Connect Signal'}));
    });

    test('indeterminate registration renders only the status-unavailable card', () async {
      fakeSidecar.fakeRegistrationState = SignalRegistrationState.unknown;
      expect(await renderedCards(), unorderedEquals(<String>{'Registration Status Unavailable'}));
    });

    test('restart backoff renders only the connection-lost card', () async {
      fakeSidecar
        ..fakeRunning = false
        ..fakeWasPaired = true
        ..fakeRestartCount = 2;
      expect(await renderedCards(), unorderedEquals(<String>{'Connection Lost'}));
    });

    test('unreachable sidecar renders only the setup card', () async {
      fakeSidecar.fakeRunning = false;
      expect(await renderedCards(), unorderedEquals(<String>{'signal-cli Not Reachable'}));
    });
  });

  // -------------------------------------------------------------------------
  group('rendered form targets', () {
    Future<Set<String>> renderedFormTargets() async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/pairing')));
      expect(res.statusCode, 200);
      final body = await res.readAsString();
      // Binds the empty-set cases below to a page that actually rendered a card.
      expect(_stateCards(body), hasLength(1));
      return _formTargets(body);
    }

    test('connected state posts only to disconnect', () async {
      fakeSidecar.fakeRegistrationState = SignalRegistrationState.registered;
      expect(await renderedFormTargets(), unorderedEquals(<String>{'/signal/pairing/disconnect'}));
    });

    test('link-device state renders no form', () async {
      expect(await renderedFormTargets(), isEmpty);
    });

    test('status-unavailable state renders no form', () async {
      fakeSidecar.fakeRegistrationState = SignalRegistrationState.unknown;
      expect(await renderedFormTargets(), isEmpty);
    });

    test('reconnecting state renders no form', () async {
      fakeSidecar
        ..fakeRunning = false
        ..fakeWasPaired = true
        ..fakeRestartCount = 2;
      expect(await renderedFormTargets(), isEmpty);
    });

    test('setup state renders no form', () async {
      fakeSidecar.fakeRunning = false;
      expect(await renderedFormTargets(), isEmpty);
    });
  });
}

/// Collects every target a `<form>` in [html] submits to, whether declared as a
/// plain `action` or as an HTMX `hx-post`.
Set<String> _formTargets(String html) {
  final targets = <String>{};
  for (final tag in RegExp(r'<form\b[^>]*>').allMatches(html)) {
    for (final attr in RegExp(r'(?:action|hx-post)="([^"]*)"').allMatches(tag.group(0)!)) {
      targets.add(attr.group(1)!);
    }
  }
  return targets;
}

/// Collects the heading of every pairing state card rendered in [html]. Each
/// card announces itself with exactly one `pairing-connected-header` or
/// `pairing-section-title`, so the set names the states that rendered.
Set<String> _stateCards(String html) {
  final card = RegExp(r'<div class="pairing-(?:connected-header|section-title)">(.*?)</div>', dotAll: true);
  final markup = RegExp(r'<[^>]*>');
  return {
    for (final m in card.allMatches(html)) m.group(1)!.replaceAll(markup, ' ').replaceAll(RegExp(r'\s+'), ' ').trim(),
  }..removeWhere((c) => c.isEmpty);
}
