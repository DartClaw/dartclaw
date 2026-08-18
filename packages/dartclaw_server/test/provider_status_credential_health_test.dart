import 'package:dartclaw_core/dartclaw_core.dart' show CredentialHealthState;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

import 'helpers/probe_helpers.dart';

/// Keys `/api/providers` served before credential health existed. Consumers
/// (and S06's cards) still read every one of them.
const _preExistingKeys = {
  'id',
  'executable',
  'version',
  'binaryFound',
  'credentialStatus',
  'credentialEnvVar',
  'poolSize',
  'effectiveWorkers',
  'activeWorkers',
  'queuedWorkers',
  'cachedWorkers',
  'quarantinedWorkers',
  'isDefault',
  'health',
  'errorMessage',
};

/// The credential block, present as a whole once health has been recorded and
/// absent as a whole before that, so a pre-credential-health consumer sees the
/// payload it always saw.
const _credentialKeys = {
  'credentialMode',
  'credentialHealth',
  'credentialReauthRequired',
  'credentialExpiresAt',
  'credentialExpiryDerived',
  'credentialLastChecked',
  'credentialRemediation',
};

ProviderStatusService _service() => ProviderStatusService(
  providers: const ProvidersConfig(
    entries: {
      'claude': ProviderEntry(executable: 'claude', poolSize: 1),
      'codex': ProviderEntry(executable: 'codex', poolSize: 1),
    },
  ),
  registry: CredentialRegistry(
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
  ),
  defaultProvider: 'claude',
);

Future<void> _probeBinaries(ProviderStatusService service) => service.probe(
  commandProbe: probeResults({'claude': probeOk('Claude CLI 1.0.0'), 'codex': probeOk('Codex CLI 1.0.0')}),
  authProbe: (executable, {providerId}) async => false,
);

Map<String, dynamic> _json(ProviderStatusService service, String providerId) =>
    service.all.firstWhere((status) => status.id == providerId).toJson();

void main() {
  group('ProviderStatus credential health', () {
    test('reports the recorded credential block and leaves an unrecorded provider null', () async {
      final service = _service();
      await _probeBinaries(service);
      final issuedAt = DateTime.utc(2026, 1, 1);
      final checkedAt = DateTime.utc(2026, 8, 15, 10);

      service.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.nearingExpiry,
        checkedAt: checkedAt,
        mode: CredentialMode.subscription,
        expiry: CredentialExpiry(issuedAt: issuedAt, expiresAt: DateTime.utc(2027, 1, 1), derived: true),
        remediation: 'claude setup-token',
      );

      final claude = _json(service, 'claude');
      expect(claude.keys, containsAll(_credentialKeys));
      expect(claude['credentialMode'], 'subscription');
      expect(claude['credentialHealth'], 'nearing-expiry');
      expect(claude['credentialReauthRequired'], isFalse);
      expect(claude['credentialExpiresAt'], DateTime.utc(2027, 1, 1).toIso8601String());
      expect(claude['credentialExpiryDerived'], isTrue);
      expect(claude['credentialLastChecked'], checkedAt.toIso8601String());
      expect(claude['credentialRemediation'], 'claude setup-token');

      // Nothing recorded for codex: the block is absent rather than fabricated,
      // so the cards render "unknown" instead of a false healthy and existing
      // consumers see the JSON they saw before credential health existed.
      final codex = _json(service, 'codex');
      expect(codex.keys, containsAll(_preExistingKeys));
      for (final key in _credentialKeys) {
        expect(codex.containsKey(key), isFalse, reason: '$key must be absent until health is recorded');
        expect(codex[key], isNull, reason: '$key must read as null until health is recorded');
      }
    });

    test('reauth-required is reported as such, and an API-key mode serializes as api_key', () async {
      final service = _service();
      await _probeBinaries(service);

      service.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.reauthRequired,
        checkedAt: DateTime.utc(2026, 8, 15),
        remediation: 'claude setup-token',
      );
      service.recordCredentialHealth(
        providerId: 'codex',
        state: CredentialHealthState.healthy,
        checkedAt: DateTime.utc(2026, 8, 15),
        mode: CredentialMode.apiKey,
      );

      // A refusal path knows the state but not the mode, so mode stays null
      // inside an otherwise-populated block.
      expect(_json(service, 'claude')['credentialReauthRequired'], isTrue);
      expect(_json(service, 'claude').containsKey('credentialMode'), isTrue);
      expect(_json(service, 'claude')['credentialMode'], isNull);
      expect(_json(service, 'codex')['credentialMode'], 'api_key');
      expect(_json(service, 'codex')['credentialReauthRequired'], isFalse);
    });

    // `health` deliberately shifts with credential health, and every other
    // pre-existing key deliberately does not. The original of this test pinned
    // `health` as unshiftable too, for backward compatibility; that made one
    // entry report `"health": "healthy"` beside `"credentialHealth":
    // "reauth-required"`, and left the *primary* badge on `/settings` — the
    // surface an operator with no alert target is left with — green while a
    // secondary badge inside the same card said re-authenticate. Documented as
    // an API change in the changelog and in docs/guide/web-ui-and-api.md.
    test('health follows a recorded credential degradation, and no other pre-existing key does', () async {
      final service = _service();
      await _probeBinaries(service);
      final before = {for (final status in service.all) status.id: Map<String, dynamic>.of(status.toJson())};
      expect(before['claude']!['health'], 'healthy');
      expect(service.summary, {'configured': 2, 'healthy': 1, 'degraded': 1});

      service.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.reauthRequired,
        checkedAt: DateTime.utc(2026, 8, 15),
        remediation: 'claude setup-token',
      );

      final claude = _json(service, 'claude');
      expect(claude['health'], 'degraded');
      // Presence is unchanged by a health verdict: this fixture configures an
      // `anthropic` API key and forces no `auth`, so the key still resolves and
      // saying "missing" would misreport what the deployment holds.
      //
      // Scoped deliberately to that: it is *not* a claim that `present` is
      // right wherever a credential is refused. The tracked case where it is
      // wrong — a forced `auth: subscription` with nothing stored, where the
      // fall-through to an API-key lookup reports present while admission
      // refuses — is a different fixture this suite does not build, and closing
      // it is an assertion to add rather than this one to delete.
      expect(claude['credentialStatus'], 'present');
      for (final status in service.all) {
        for (final key in _preExistingKeys.where((key) => key != 'health')) {
          expect(status.toJson()[key], before[status.id]![key], reason: '$key must not shift for existing consumers');
        }
      }
      // The summary counts the same field, so it re-counts with it rather than
      // reporting a healthy provider the entries no longer agree is healthy.
      expect(service.summary, {'configured': 2, 'healthy': 0, 'degraded': 2});
    });

    test('a nearing-expiry credential degrades too, and a healthy one does not', () async {
      // `isDegraded` is the one deployment-wide "needs operator attention"
      // predicate — the same one behind the stderr warning and the alert — so
      // the badge cannot disagree with the line the operator already got.
      final service = _service();
      await _probeBinaries(service);

      service.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.nearingExpiry,
        checkedAt: DateTime.utc(2026, 8, 15),
        mode: CredentialMode.subscription,
        expiry: CredentialExpiry(
          issuedAt: DateTime.utc(2026, 1, 1),
          expiresAt: DateTime.utc(2026, 9, 1),
          derived: true,
        ),
      );
      expect(_json(service, 'claude')['health'], 'degraded');

      service.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.healthy,
        checkedAt: DateTime.utc(2026, 8, 15),
        mode: CredentialMode.apiKey,
      );
      expect(_json(service, 'claude')['health'], 'healthy');
    });

    test('an uncheckable credential lifetime is not a degradation', () async {
      // `unknown` means DartClaw cannot see the lifetime of a login that works —
      // the Claude interactive-login case. Degrading there would page an
      // operator about a provider that runs fine.
      final service = _service();
      await _probeBinaries(service);

      service.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.unknown,
        checkedAt: DateTime.utc(2026, 8, 15),
        remediation: 'claude setup-token',
      );

      expect(_json(service, 'claude')['health'], 'healthy');
      expect(service.summary, {'configured': 2, 'healthy': 1, 'degraded': 1});
    });

    // The token side of this contract is proven end-to-end, through a real
    // resolution, in test/alerts/credential_health_monitor_test.dart.
    test('the configured API key never reaches the serialized status', () async {
      final service = _service();
      await _probeBinaries(service);

      service.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.nearingExpiry,
        checkedAt: DateTime.utc(2026, 8, 15),
        mode: CredentialMode.subscription,
        expiry: CredentialExpiry(
          issuedAt: DateTime.utc(2026, 1, 1),
          expiresAt: DateTime.utc(2027, 1, 1),
          derived: true,
        ),
        remediation: 'claude setup-token',
      );

      expect(_json(service, 'claude').toString(), isNot(contains('anthropic-key')));
    });
  });
}
