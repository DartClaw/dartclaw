import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show SubscriptionCredentialStore;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'container_integration_support.dart';

/// Proves the credential-free sweep the container suites rely on can fail.
///
/// The suites it serves need Docker and are skipped by default, so a sweep that
/// silently stopped detecting anything would go unnoticed for a whole release.
/// This suite is deliberately Docker-free and untagged: it runs on every push,
/// plants each subscription credential shape on a surface those suites really
/// read, and asserts the sweep rejects it by name.
void main() {
  late Directory dataDir;

  setUp(() => dataDir = Directory.systemTemp.createTempSync('subscription_sentinel_'));

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  group('the credential-free sweep', () {
    test('fails naming the surface for every planted subscription credential', () {
      for (final sentinel in subscriptionSentinels) {
        final leaked = Directory(p.join(dataDir.path, 'generated-state'))..createSync(recursive: true);
        File(p.join(leaked.path, 'auth.json')).writeAsStringSync('{"stored":"$sentinel"}');

        // A surface map built exactly as the container suites build theirs, so
        // this proves the real call site fails rather than a paraphrase of it.
        final surfaces = {
          for (final entry in readAllFiles(leaked).entries) 'generated-state/${entry.key}': entry.value,
        };

        expect(
          () => expectSentinelsAbsent(surfaces, subscriptionSentinels),
          throwsA(
            isA<TestFailure>().having(
              (failure) => failure.message ?? '',
              'message',
              contains('generated-state/auth.json'),
            ),
          ),
          reason: 'a real leak of $sentinel passed the sweep',
        );

        leaked.deleteSync(recursive: true);
      }
    });

    test('passes only because nothing was planted, not because it reads nothing', () {
      final clean = Directory(p.join(dataDir.path, 'workspace'))..createSync(recursive: true);
      File(p.join(clean.path, 'notes.txt')).writeAsStringSync('no credential here');

      final surfaces = {for (final entry in readAllFiles(clean).entries) 'workspace/${entry.key}': entry.value};

      expect(surfaces, isNotEmpty, reason: 'the control surface read no files, so a pass would prove nothing');
      expectSentinelsAbsent(surfaces, subscriptionSentinels);
    });

    test('reads the whole sweep, not just the first surface', () {
      final surfaces = {'clean': 'nothing here', 'later': 'stored $sentinelClaudeSetupToken'};

      expect(
        () => expectSentinelsAbsent(surfaces, subscriptionSentinels),
        throwsA(isA<TestFailure>().having((failure) => failure.message ?? '', 'message', contains('later'))),
      );
    });
  });

  group('the dedicated-store fixtures', () {
    late SubscriptionCredentialStore store;

    setUp(() => store = openSentinelCredentialStore(dataDir));

    test('the Codex sentinel JWT reads back as a usable, non-derived expiry', () {
      writeSentinelCodexCredential(store);

      final auth = store.readCodexAuth();
      final entry = store.read('codex');

      // The constraint this pins: an unparseable `exp` reads as *no credential*,
      // which would silently convert every conformance fixture below it into an
      // admission fixture that never runs a turn.
      expect(auth, isNotNull, reason: 'the sentinel JWT did not parse, so the fixture holds no credential at all');
      expect(auth!.accessToken, sentinelCodexAccessToken);
      expect(auth.accountId, sentinelCodexAccountId);
      expect(auth.expiresAt.isAfter(DateTime.now().toUtc()), isTrue);
      expect(entry!.expiry!.derived, isFalse, reason: 'a JWT exp is exact, never estimated');
      expect(entry.expiry!.expiresAt, auth.expiresAt);
    });

    test('the Claude sentinel setup-token reads back with a derived expiry', () {
      final issuedAt = DateTime.utc(2026, 8, 1);
      writeSentinelClaudeCredential(store, issuedAt: issuedAt);

      final entry = store.read('claude');

      expect(entry!.secret, sentinelClaudeSetupToken);
      expect(entry.expiry!.issuedAt, issuedAt);
      expect(entry.expiry!.derived, isTrue, reason: 'a setup-token carries no expiry claim of its own');
    });

    test('the stores land where the shipped layout puts them', () {
      writeSentinelClaudeCredential(store);
      writeSentinelCodexCredential(store);

      // The container suites assert these paths are *not* mounted, so a fixture
      // writing somewhere else would make that assertion vacuous too.
      expect(store.claudeTokenPath, p.join(dataDir.path, 'credentials', 'claude', 'setup-token.json'));
      expect(store.codexAuthPath, p.join(dataDir.path, 'credentials', 'codex', 'auth.json'));
      expect(File(store.claudeTokenPath).existsSync(), isTrue);
      expect(File(store.codexAuthPath).existsSync(), isTrue);
      // The raw file bytes carry the sentinels; redaction anywhere above this
      // would mask a leak the container could still read.
      expect(File(store.codexAuthPath).readAsStringSync(), contains(sentinelCodexRefreshToken));
    });
  });
}
