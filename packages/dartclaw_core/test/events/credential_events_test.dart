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
}
