import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show SubscriptionCredentialStore;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Measures the single-flight refresh across a real rotation window.
///
/// The sibling authority suite counts invocations of an injected seam, which
/// proves DartClaw called out once but not that the token *lineage* advanced
/// once: a second call carrying a spent refresh token would increment the same
/// counter and still be a protocol violation. Here the refresh is driven
/// against a local endpoint that enforces one-time use, so a duplicate call is
/// rejected and counted rather than merely tallied, and the assertion reads the
/// rotated lineage out of the persisted store rather than out of the fixture.
///
/// No Docker and no vendor CLI: the invoker below stands in for the vendor's
/// own auth manager, which is the only thing that ever writes `auth.json`.
void main() {
  late Directory root;
  late SubscriptionCredentialStore store;
  late _OneTimeUseTokenEndpoint endpoint;
  late DateTime clock;

  /// Builds a structurally valid JWT whose payload carries [exp] in seconds.
  String jwt(DateTime exp) {
    String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${segment({'alg': 'RS256', 'typ': 'JWT'})}'
        '.${segment({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': 'chatgpt-account'})}'
        '.cm90YXRpb24td2luZG93';
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('codex_rotation_window_');
    final home = Directory(p.join(root.path, 'home'))..createSync(recursive: true);
    store = SubscriptionCredentialStore.open(
      credentialsDir: p.join(root.path, 'data', 'credentials'),
      environment: {'HOME': home.path},
    );
    clock = DateTime.utc(2026, 8, 15, 12);
    endpoint = await _OneTimeUseTokenEndpoint.start(now: () => clock, mintAccessToken: jwt);
  });

  tearDown(() async {
    await endpoint.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Seeds the store at the endpoint's opening lineage, with the access token
  /// already inside the near-expiry window so the gate must rotate.
  void seedStoreAtOpeningLineage({Duration lastRefreshAge = Duration.zero}) {
    File(store.codexAuthPath).writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token': jwt(clock.add(const Duration(minutes: 1))),
          'refresh_token': _OneTimeUseTokenEndpoint.openingRefreshToken,
          'account_id': 'acct-rotation',
        },
        'last_refresh': clock.subtract(lastRefreshAge).toIso8601String(),
      }),
    );
  }

  /// What the vendor CLI does on DartClaw's behalf: presents the stored refresh
  /// token to the token endpoint and persists whatever came back.
  ///
  /// DartClaw itself never reads the refresh token, so it has to be read here —
  /// on the vendor's side of the seam — for the rotation to be real.
  CodexVendorRefresh vendorRefreshAgainstEndpoint() => (codexHome) async {
    final authPath = p.join(codexHome, 'auth.json');
    final record = jsonDecode(File(authPath).readAsStringSync()) as Map<String, Object?>;
    final tokens = record['tokens']! as Map<String, Object?>;
    final rotated = await endpoint.exchange(tokens['refresh_token']! as String);
    File(authPath).writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token': rotated.accessToken,
          'refresh_token': rotated.refreshToken,
          'account_id': tokens['account_id'],
        },
        'last_refresh': clock.toIso8601String(),
      }),
    );
  };

  CodexRefreshAuthority authority() =>
      CodexRefreshAuthority(store: store, vendorRefresh: vendorRefreshAgainstEndpoint(), now: () => clock);

  CodexSubscriptionCredential credentialOf(CodexRefreshOutcome outcome) => switch (outcome) {
    CodexCredentialPresented(:final credential) => credential,
    CodexCredentialRotatedAway(:final credential) => credential,
    _ => fail('expected a usable credential, got $outcome'),
  };

  ({String accessToken, String refreshToken}) persistedLineage() {
    final record = jsonDecode(File(store.codexAuthPath).readAsStringSync()) as Map<String, Object?>;
    final tokens = record['tokens']! as Map<String, Object?>;
    return (accessToken: tokens['access_token']! as String, refreshToken: tokens['refresh_token']! as String);
  }

  test('two simultaneous demands across a rotation window make exactly one token call', () async {
    seedStoreAtOpeningLineage();
    final gate = authority();

    // Both demands issued before either is awaited: a second caller that only
    // discovered the refresh afterwards would prove nothing about the window.
    final first = gate.present();
    final second = gate.present();
    final outcomes = await Future.wait([first, second]);

    expect(endpoint.callCount, 1, reason: 'the rotation window saw more than one token-endpoint call');
    expect(endpoint.violations, isEmpty, reason: 'one-time-use was violated: ${endpoint.violations}');
    expect(endpoint.presentedRefreshTokens, [_OneTimeUseTokenEndpoint.openingRefreshToken]);

    // Both demanders hold the rotated token — not merely equal tokens, but the
    // one the endpoint actually minted for this window.
    final held = outcomes.map((outcome) => credentialOf(outcome).accessToken).toSet();
    expect(held, {endpoint.lastMintedAccessToken});

    // And the lineage advanced exactly once in the store the vendor persists to.
    expect(persistedLineage().accessToken, endpoint.lastMintedAccessToken);
    expect(persistedLineage().refreshToken, endpoint.lastMintedRefreshToken);
    expect(persistedLineage().refreshToken, isNot(_OneTimeUseTokenEndpoint.openingRefreshToken));
  });

  test('the rotated lineage stays usable: a later window rotates again on the new refresh token', () async {
    seedStoreAtOpeningLineage();
    final gate = authority();

    await Future.wait([gate.present(), gate.present()]);
    final firstWindow = persistedLineage();

    // The clock moves the freshly minted token into the window rather than the
    // fixture rewriting the store: re-seeding from a saved copy would resurrect
    // a spent refresh token and hide exactly the violation under test.
    //
    // 56 leaves exactly `nearExpiryWindow` (4 min) of the 60-minute token, so
    // the rotation below is what pins the gate's `<=`: any strictly-inside
    // value leaves a `<` slip invisible, handing out a token at the exact edge
    // un-refreshed. Load-bearing literal — don't round it.
    clock = clock.add(const Duration(minutes: 56));
    final outcome = await gate.present();

    expect(endpoint.callCount, 2, reason: 'the settled memo did not release, so the second window never rotated');
    expect(endpoint.violations, isEmpty, reason: 'one-time-use was violated: ${endpoint.violations}');
    expect(endpoint.presentedRefreshTokens, [
      _OneTimeUseTokenEndpoint.openingRefreshToken,
      firstWindow.refreshToken,
    ], reason: 'the second window did not present the refresh token the first one minted');
    expect(credentialOf(outcome).accessToken, endpoint.lastMintedAccessToken);
    expect(persistedLineage().accessToken, endpoint.lastMintedAccessToken);
    expect(persistedLineage().refreshToken, isNot(firstWindow.refreshToken));
  });

  test('a replayed refresh token is rejected, so the endpoint can fail this suite', () async {
    seedStoreAtOpeningLineage();
    final gate = authority();

    await gate.present();
    final spent = _OneTimeUseTokenEndpoint.openingRefreshToken;

    // The detector's own proof: without it, "zero violations" above would hold
    // for an endpoint that never checked anything.
    await expectLater(endpoint.exchange(spent), throwsA(isA<_OneTimeUseViolation>()));
    expect(endpoint.violations, [spent]);
  });

  test('the rotated store reads back as exactly the four values that omit the refresh token', () async {
    seedStoreAtOpeningLineage();

    final credential = credentialOf(await authority().present());
    final persisted = persistedLineage();
    final read = store.readCodexAuth()!;

    // Positive control: the file on disk really does hold a refresh token, so
    // the enumeration below asserts an omission rather than describing a store
    // that had nothing to omit.
    expect(
      File(store.codexAuthPath).readAsStringSync(),
      contains(persisted.refreshToken),
      reason: 'the vendor persisted no refresh token, so the read surface below proves nothing',
    );

    // The whole read surface, enumerated. DartClaw's mediation and spawn lanes
    // draw from exactly these values, so a refresh token reaching any of them —
    // an access-token field populated from the wrong JSON key, say — fails here
    // where four independent absence checks would each pass.
    expect(
      {
        'accessToken': read.accessToken,
        'accountId': read.accountId,
        'expiresAt': read.expiresAt.toIso8601String(),
        'lastRefresh': read.lastRefresh?.toIso8601String(),
      },
      {
        'accessToken': persisted.accessToken,
        'accountId': 'acct-rotation',
        'expiresAt': clock.add(const Duration(minutes: 60)).toIso8601String(),
        'lastRefresh': clock.toIso8601String(),
      },
    );
    // And the credential handed to a mediated request carries the same token,
    // not a second read that could have picked up something else.
    expect(credential.accessToken, read.accessToken);
  });
}

/// Raised when the endpoint is presented a refresh token it already consumed.
final class _OneTimeUseViolation implements Exception {
  const new(this.refreshToken);

  final String refreshToken;

  @override
  String toString() => 'one-time-use violation: $refreshToken was already consumed';
}

/// A local token endpoint that rotates refresh tokens exactly once each.
///
/// Bound to loopback port 0: `dart test` runs suites as isolates in one OS
/// process, so a fixed port would collide across suites.
final class _OneTimeUseTokenEndpoint {
  new _(this._server, this._now, this._mintAccessToken);

  static const openingRefreshToken = 'refresh-token-0';

  final HttpServer _server;
  final DateTime Function() _now;
  final String Function(DateTime exp) _mintAccessToken;

  final _consumed = <String>{};
  final presentedRefreshTokens = <String>[];

  /// Refresh tokens presented after they were already consumed, or that never
  /// belonged to this lineage at all.
  final violations = <String>[];

  var _generation = 0;
  String _currentRefreshToken = openingRefreshToken;
  String lastMintedAccessToken = '';
  String lastMintedRefreshToken = '';

  int get callCount => presentedRefreshTokens.length;

  Uri get uri => Uri.parse('http://${InternetAddress.loopbackIPv4.address}:${_server.port}/token');

  static Future<_OneTimeUseTokenEndpoint> start({
    required DateTime Function() now,
    required String Function(DateTime exp) mintAccessToken,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = _OneTimeUseTokenEndpoint._(server, now, mintAccessToken);
    server.listen(endpoint._serve, onError: (Object _) {});
    return endpoint;
  }

  /// Presents [refreshToken] and answers the rotated lineage.
  ///
  /// Throws [_OneTimeUseViolation] when the token was already spent, which is
  /// what makes a duplicated refresh a protocol failure rather than a count.
  Future<({String accessToken, String refreshToken})> exchange(String refreshToken) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'grant_type': 'refresh_token', 'refresh_token': refreshToken}));
      final response = await request.close();
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, Object?>;
      if (response.statusCode != 200) throw _OneTimeUseViolation(refreshToken);
      return (accessToken: body['access_token']! as String, refreshToken: body['refresh_token']! as String);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, Object?>;
    final presented = body['refresh_token'] as String? ?? '';
    presentedRefreshTokens.add(presented);

    if (_consumed.contains(presented) || presented != _currentRefreshToken) {
      violations.add(presented);
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'invalid_grant'}));
      await request.response.close();
      return;
    }

    _consumed.add(presented);
    _generation++;
    lastMintedAccessToken = _mintAccessToken(_now().add(const Duration(minutes: 60)));
    lastMintedRefreshToken = 'refresh-token-$_generation';
    _currentRefreshToken = lastMintedRefreshToken;

    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'access_token': lastMintedAccessToken, 'refresh_token': lastMintedRefreshToken, 'expires_in': 3600}),
    );
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}
