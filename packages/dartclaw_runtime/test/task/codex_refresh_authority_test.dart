import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show SubscriptionCredentialStore;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Builds a JWT whose payload carries [exp] as a numeric seconds claim, the
/// shape the vendor persists the ChatGPT access token in.
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
    root = Directory.systemTemp.createTempSync('codex_refresh_authority_');
    final home = p.join(root.path, 'home');
    Directory(home).createSync(recursive: true);
    store = SubscriptionCredentialStore.open(
      credentialsDir: p.join(root.path, 'data', 'credentials'),
      environment: {'HOME': home},
    );
    now = DateTime.utc(2026, 8, 15, 12);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Writes the dedicated store as the vendor CLI would, with an access token
  /// expiring [inMinutes] from the fixed clock.
  void writeStore({required int inMinutes, String accountId = 'acct-1', Duration lastRefreshAge = Duration.zero}) {
    File(store.codexAuthPath).writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token': _jwt(now.add(Duration(minutes: inMinutes))),
          'refresh_token': 'rt-sentinel-must-never-be-read',
          'account_id': accountId,
        },
        'last_refresh': now.subtract(lastRefreshAge).toIso8601String(),
      }),
    );
  }

  CodexRefreshAuthority authorityWith(CodexVendorRefresh vendorRefresh) =>
      CodexRefreshAuthority(store: store, vendorRefresh: vendorRefresh, now: () => now);

  /// A refresh that rotates the store the way the vendor's own mechanism does.
  ///
  /// Each call writes a distinct token, so "both callers received the same
  /// token" asserts one refresh rather than a property of the fixture.
  CodexVendorRefresh rotatingRefresh({required List<String> calls, int inMinutes = 12}) => (codexHome) async {
    calls.add(codexHome);
    await Future<void>.delayed(Duration.zero);
    writeStore(inMinutes: inMinutes + calls.length, accountId: 'acct-1');
  };

  CodexSubscriptionCredential credentialOf(CodexRefreshOutcome outcome) => switch (outcome) {
    CodexCredentialPresented(:final credential) => credential,
    CodexCredentialRotatedAway(:final credential) => credential,
    _ => fail('expected a usable credential, got $outcome'),
  };

  group('single-flight refresh', () {
    test('two callers demanding a refresh in one event-loop turn make one token call', () async {
      final calls = <String>[];
      writeStore(inMinutes: 1);
      final authority = authorityWith(rotatingRefresh(calls: calls));

      // Both started before either is awaited: a second caller that only
      // discovered the refresh after the first completed would prove nothing.
      final first = authority.present();
      final second = authority.present();
      final outcomes = await Future.wait([first, second]);

      expect(calls, hasLength(1), reason: 'the in-flight refresh was observable before the first await');
      expect(calls.single, store.codexHome);
      final tokens = outcomes.map((outcome) => credentialOf(outcome).accessToken).toSet();
      expect(tokens, hasLength(1), reason: 'both callers received the same rotated token');
    });

    test('the second caller joins the first future itself, not a second pass that happens to agree', () async {
      writeStore(inMinutes: 1);
      final authority = authorityWith(rotatingRefresh(calls: <String>[]));

      final first = authority.present();
      final second = authority.present();

      // Counting token calls cannot see this: the per-store lock plus the
      // in-critical-section re-read collapse two passes onto one call anyway,
      // so every count-based assertion still holds with the memo deleted. Only
      // the published future proves a caller in this same event-loop turn was
      // handed the refresh already under way.
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);
    });

    test('a caller arriving after the refresh settles triggers a new one', () async {
      final calls = <String>[];
      writeStore(inMinutes: 1);
      final authority = authorityWith(rotatingRefresh(calls: calls));

      await authority.present();
      // Back inside the window, so the next caller must demand its own refresh
      // rather than joining a memo that was never cleared.
      writeStore(inMinutes: 1);
      await authority.present();

      expect(calls, hasLength(2));
    });
  });

  group('freshness gate', () {
    test('a token expiring inside the window is refreshed and the post-refresh value is returned', () async {
      final calls = <String>[];
      writeStore(inMinutes: 2);
      final beforeToken = store.readCodexAuth()!.accessToken;
      final authority = authorityWith(rotatingRefresh(calls: calls));

      final credential = credentialOf(await authority.present());

      expect(calls, hasLength(1));
      expect(credential.accessToken, isNot(beforeToken));
      expect(credential.accessToken, store.readCodexAuth()!.accessToken);
      expect(credential.accountId, 'acct-1');
      expect(credential.expiresAt.isAfter(now), isTrue, reason: 'never returns a token already past expiry');
    });

    test('a token comfortably outside the window is returned with no refresh', () async {
      final calls = <String>[];
      writeStore(inMinutes: 30);
      final authority = authorityWith(rotatingRefresh(calls: calls));

      final outcome = await authority.present();

      expect(calls, isEmpty);
      expect(outcome, isA<CodexCredentialPresented>());
      expect(credentialOf(outcome).accessToken, store.readCodexAuth()!.accessToken);
    });

    test('a refresh that leaves the token at expiry never presents it', () async {
      writeStore(inMinutes: 0);
      final authority = authorityWith((_) async {});

      final outcome = await authority.present();

      expect(outcome, isA<CodexRefreshFailed>());
    });

    test('a still-valid token the vendor declined to rotate is presented, not failed', () async {
      // The vendor's conditional refresh is a no-op whenever it judges the
      // token fresh enough — routine at the edge of its own window, and a
      // transient blip looks identical from here. The window says when to *ask*
      // for a rotation; failing the turn over the answer would deny a
      // credential the backend still accepts.
      writeStore(inMinutes: 3);
      final beforeToken = store.readCodexAuth()!.accessToken;
      final authority = authorityWith((_) async {});

      final outcome = await authority.present();

      expect(outcome, isA<CodexCredentialPresented>());
      expect(credentialOf(outcome).accessToken, beforeToken);
    });

    test('the demand window stays strictly inside the vendor window the drive can act in', () {
      // Mirroring the vendor's own 5 minutes exactly puts every demand on its
      // edge, where a decline is as likely as a rotation.
      expect(CodexRefreshAuthority.nearExpiryWindow, lessThan(const Duration(minutes: 5)));
      expect(CodexRefreshAuthority.nearExpiryWindow, greaterThan(Duration.zero));
    });
  });

  group('refresh outcomes', () {
    test('a token superseded mid-flight returns the current one and reports neither reauth nor failure', () async {
      writeStore(inMinutes: 1);
      final authority = authorityWith((_) async {
        // The lineage this refresh held was already consumed by another writer,
        // which is what a one-time-use rotation race looks like from here.
        writeStore(inMinutes: 20, accountId: 'acct-rotated');
        throw StateError('refresh token already used');
      });

      final outcome = await authority.present();

      expect(outcome, isA<CodexCredentialRotatedAway>());
      expect(credentialOf(outcome).accountId, 'acct-rotated');
      expect(outcome, isNot(isA<CodexReauthRequired>()));
      expect(outcome, isNot(isA<CodexRefreshFailed>()));
    });

    test('a refresh token past its staleness limit is terminal and names re-login', () async {
      // The access token still has a minute of life, which rescues nothing: no
      // later pass can renew a lineage that is gone, so the operator hears now
      // rather than one short turn from now.
      writeStore(inMinutes: 1, lastRefreshAge: const Duration(days: 9));
      final authority = authorityWith((_) async => throw StateError('invalid_grant'));

      final outcome = await authority.present();

      expect(outcome, isA<CodexReauthRequired>());
      final reauth = outcome as CodexReauthRequired;
      expect(reauth.remediation, contains('codex login'));
      expect('${reauth.detail} ${reauth.remediation}', isNot(contains('rt-sentinel')));
    });

    test('a store left holding no readable credential is terminal, not retryable', () async {
      writeStore(inMinutes: 1, lastRefreshAge: const Duration(hours: 2));
      final authority = authorityWith((_) async => File(store.codexAuthPath).deleteSync());

      final outcome = await authority.present();

      // Nothing remains to refresh from, so reporting this as transient would
      // hand a retryable signal that can never resolve.
      expect(outcome, isA<CodexReauthRequired>());
    });

    test('a drive that threw after tearing the store is retryable, not a re-login', () async {
      writeStore(inMinutes: 1, lastRefreshAge: const Duration(hours: 2));
      final authority = authorityWith((_) async {
        // A vendor process killed on a timeout can leave the store mid-write.
        // The refresh token it held was never presented to any endpoint, so
        // sending the operator to an interactive login — and failing closed
        // until they run it — spends a working credential on a stalled process.
        File(store.codexAuthPath).writeAsStringSync('{"tokens":{');
        throw const SocketException('vendor refresh timed out');
      });

      final outcome = await authority.present();

      expect(outcome, isA<CodexRefreshFailed>());
      expect(outcome, isNot(isA<CodexReauthRequired>()));
    });

    test('a transient refresh failure carries no reauth semantics', () async {
      // At expiry, so the pass has no still-usable token to fall back on and
      // the outcome is the drive's own.
      writeStore(inMinutes: 0, lastRefreshAge: const Duration(hours: 2));
      final authority = authorityWith((_) async => throw const SocketException('endpoint unreachable'));

      final outcome = await authority.present();

      expect(outcome, isA<CodexRefreshFailed>());
      expect(outcome, isNot(isA<CodexReauthRequired>()));
      expect((outcome as CodexRefreshFailed).detail, isNot(contains('rt-sentinel')));
    });

    test('the three outcomes are distinguishable without parsing any message', () async {
      writeStore(inMinutes: 1);
      final rotated = await authorityWith((_) async {
        writeStore(inMinutes: 20);
        throw StateError('superseded');
      }).present();
      writeStore(inMinutes: 1, lastRefreshAge: const Duration(days: 9));
      final stale = await authorityWith((_) async => throw StateError('invalid_grant')).present();
      writeStore(inMinutes: 0, lastRefreshAge: const Duration(hours: 2));
      final transient = await authorityWith((_) async => throw StateError('offline')).present();

      expect({rotated.runtimeType, stale.runtimeType, transient.runtimeType}, hasLength(3));
    });
  });

  group('host spawn and container inject on one store', () {
    test('either contention order produces one refresh and a host token outside the window', () async {
      for (final hostFirst in [true, false]) {
        final calls = <String>[];
        writeStore(inMinutes: 1);
        final authority = authorityWith(rotatingRefresh(calls: calls));
        CodexSubscriptionCredential? hostCredential;

        Future<Object?> startHost() => authority.prepareHostSpawn((outcome) {
          hostCredential = credentialOf(outcome);
          return authority.codexHome;
        });
        // The lock is taken at call time, so the futures must be *created* in
        // the permuted order — reordering only the `Future.wait` arguments
        // would run the identical scenario twice.
        final pending = hostFirst
            ? <Future<Object?>>[startHost(), authority.present()]
            : <Future<Object?>>[authority.present(), startHost()];
        final outcomes = await Future.wait(pending);

        expect(calls, hasLength(1), reason: 'one refresh serves both lanes (hostFirst: $hostFirst)');
        expect(outcomes, contains(authority.codexHome));
        expect(
          hostCredential!.expiresAt.difference(now),
          greaterThan(CodexRefreshAuthority.nearExpiryWindow),
          reason: 'the vendor is handed a token it has no cause to rotate at spawn time',
        );
      }
    });

    test('a host spawn queued behind another never waits on a refresh queued behind itself', () async {
      // Three participants on one store. The inject publishes its in-flight
      // refresh while queued *behind* the second host preparation, so a holder
      // that joined that memo would await a future queued behind its own lock
      // hold and neither would ever settle.
      writeStore(inMinutes: 30);
      final calls = <String>[];
      final authority = authorityWith(rotatingRefresh(calls: calls));
      final firstHolds = Completer<void>();
      final releaseFirst = Completer<void>();

      final first = authority.prepareHostSpawn((_) async {
        firstHolds.complete();
        await releaseFirst.future;
        return 'first';
      });
      await firstHolds.future;
      // The token falls into the window while the first preparation still holds
      // the store, so both later callers arrive needing a refresh.
      writeStore(inMinutes: 1);
      final second = authority.prepareHostSpawn((_) async => 'second');
      final inject = authority.present();
      releaseFirst.complete();

      await Future.wait([first, second, inject]).timeout(const Duration(seconds: 2));

      expect(calls, hasLength(1));
    });

    test('host-spawn preparation and a refresh are mutually exclusive on one store', () async {
      writeStore(inMinutes: 1);
      final order = <String>[];
      final authority = authorityWith((codexHome) async {
        order.add('refresh-start');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        writeStore(inMinutes: 20);
        order.add('refresh-end');
      });

      final inject = authority.present();
      final host = authority.prepareHostSpawn((_) async {
        order.add('prepare');
        return 0;
      });
      await Future.wait([inject, host]);

      expect(order, ['refresh-start', 'refresh-end', 'prepare']);
    });
  });
}
