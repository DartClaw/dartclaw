import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show SubscriptionCredentialStore;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A refresh token value that must never reach a diagnostic.
const _refreshTokenSentinel = 'rt-sentinel-must-never-be-read';

/// Builds a JWT carrying [exp] as a numeric seconds claim, the shape the vendor
/// persists the ChatGPT access token in.
String _jwt(DateTime exp) {
  String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'RS256', 'typ': 'JWT'})}'
      '.${segment({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': 'chatgpt-account'})}'
      '.ZmFrZS1zaWduYXR1cmU';
}

void main() {
  late Directory root;
  late SubscriptionCredentialStore store;
  late DateTime now;

  setUp(() {
    root = Directory.systemTemp.createTempSync('codex_credential_source_');
    final home = p.join(root.path, 'home');
    Directory(home).createSync(recursive: true);
    store = SubscriptionCredentialStore.open(
      credentialsDir: p.join(root.path, 'data', 'credentials'),
      environment: {'HOME': home},
    );
    now = DateTime.utc(2026, 8, 16, 12);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Writes the dedicated store the way the vendor CLI does.
  void writeStore({required int inMinutes, Duration lastRefreshAge = Duration.zero}) {
    File(store.codexAuthPath).writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token': _jwt(now.add(Duration(minutes: inMinutes))),
          'refresh_token': _refreshTokenSentinel,
          'account_id': 'acct-1',
        },
        'last_refresh': now.subtract(lastRefreshAge).toIso8601String(),
      }),
    );
  }

  CodexCredentialSource sourceWith(CodexVendorRefresh vendorRefresh, {String providerId = 'codex'}) =>
      CodexCredentialSource(
        providerId: providerId,
        resolve: () => CredentialResolution.subscription(CredentialEntry.subscription(token: 'configured')),
        authority: CodexRefreshAuthority(store: store, vendorRefresh: vendorRefresh, now: () => now),
      );

  test('a spent refresh lineage ends the authority instead of refusing one request', () async {
    // FR5's post-admission branch: nothing a later request does can renew a
    // credential whose refresh token is gone, so a per-request refusal would
    // leave a live authority re-failing every turn behind a dead store.
    writeStore(inMinutes: 1, lastRefreshAge: const Duration(days: 9));
    final source = sourceWith((_) async => throw StateError('invalid_grant'));

    await expectLater(
      source.present(),
      throwsA(
        isA<GatewayCredentialUnusable>()
            .having((failure) => failure.providerId, 'providerId', 'codex')
            .having((failure) => failure.remediation, 'remediation', contains('dartclaw auth codex'))
            .having((failure) => failure.remediation, 'remediation', isNot(contains(_refreshTokenSentinel))),
      ),
    );
  });

  test('the terminal failure names the alias whose authority is being torn down', () async {
    writeStore(inMinutes: 1, lastRefreshAge: const Duration(days: 9));
    final source = sourceWith((_) async => throw StateError('invalid_grant'), providerId: 'my_codex');

    await expectLater(
      source.present(),
      throwsA(isA<GatewayCredentialUnusable>().having((failure) => failure.providerId, 'providerId', 'my_codex')),
    );
  });

  test('a refresh that merely failed refuses the request and leaves the authority live', () async {
    // The operator waits this one out: turning a reachable-again store into a
    // teardown would spend a working credential on a transient outage.
    writeStore(inMinutes: -5, lastRefreshAge: const Duration(hours: 2));
    final source = sourceWith((_) async => throw const SocketException('vendor refresh timed out'));

    await expectLater(
      source.present(),
      throwsA(
        isA<GatewayDenied>()
            .having((denied) => denied.status, 'status', 503)
            .having((denied) => denied.reason, 'reason', isNot(contains(_refreshTokenSentinel))),
      ),
    );
  });

  test('a usable store presents its credential with the account it belongs to', () async {
    writeStore(inMinutes: 30);
    final source = sourceWith((_) async => fail('a fresh store must not be refreshed'));

    final resolution = await source.present();

    expect(resolution.isPresent, isTrue);
    expect((resolution as CodexSubscriptionResolution).accountId, 'acct-1');
  });
}
