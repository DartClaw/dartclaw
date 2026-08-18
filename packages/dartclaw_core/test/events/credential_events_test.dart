import 'package:dartclaw_config/dartclaw_config.dart' show CredentialExpiry;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('CredentialHealthState', () {
    // The taxonomy is the contract shared by the alert wording, /api/providers
    // and the settings cards — a silently added or renamed state would split it.
    test('covers exactly the six states with frozen wire names', () {
      expect(CredentialHealthState.values.map((state) => state.jsonName), [
        'healthy',
        'nearing-expiry',
        'refresh-failure',
        'reauth-required',
        'contract-break',
        'unknown',
      ]);
    });

    test('only the four actionable states count as degraded', () {
      expect(CredentialHealthState.values.where((state) => state.isDegraded), [
        CredentialHealthState.nearingExpiry,
        CredentialHealthState.refreshFailure,
        CredentialHealthState.reauthRequired,
        CredentialHealthState.contractBreak,
      ]);
    });
  });

  group('CredentialHealthChangedEvent', () {
    test('exposes provider, state, detail, remediation and expiry with its derived flag', () {
      final issuedAt = DateTime.utc(2026, 1, 1);
      final event = CredentialHealthChangedEvent(
        providerId: 'claude',
        state: CredentialHealthState.nearingExpiry,
        detail: 'Claude setup-token needs renewal within 20 days.',
        remediation: 'claude setup-token',
        expiry: CredentialExpiry(issuedAt: issuedAt, expiresAt: issuedAt.add(const Duration(days: 365)), derived: true),
        timestamp: DateTime.utc(2026, 12, 12),
      );

      expect(event.providerId, 'claude');
      expect(event.state, CredentialHealthState.nearingExpiry);
      expect(event.detail, contains('20 days'));
      expect(event.remediation, 'claude setup-token');
      expect(event.expiry!.issuedAt, issuedAt);
      expect(event.expiry!.expiresAt, issuedAt.add(const Duration(days: 365)));
      expect(event.expiry!.derived, isTrue);
      expect(event.timestamp, DateTime.utc(2026, 12, 12));
    });

    test('remediation and expiry are optional and default to absent', () {
      final event = CredentialHealthChangedEvent(
        providerId: 'codex',
        state: CredentialHealthState.contractBreak,
        detail: 'Upstream rejected the mediated Bearer form.',
        timestamp: DateTime.utc(2026, 12, 12),
      );

      expect(event.remediation, isNull);
      expect(event.expiry, isNull);
      expect(event.toString(), allOf(contains('codex'), contains('contract-break')));
    });

    test('is a DartclawEvent the sealed switch can match', () {
      final DartclawEvent event = CredentialHealthChangedEvent(
        providerId: 'claude',
        state: CredentialHealthState.healthy,
        detail: 'API key configured.',
        timestamp: DateTime.utc(2026, 12, 12),
      );

      expect(switch (event) {
        CredentialHealthChangedEvent(:final providerId) => providerId,
        _ => 'unmatched',
      }, 'claude');
    });
  });
}
