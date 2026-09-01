import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/alerts/alert_classifier.dart';
import 'package:dartclaw_runtime/src/alerts/alert_formatter.dart';
import 'package:test/test.dart';

const _formatter = AlertFormatter();

CredentialHealthChangedEvent _event(
  CredentialHealthState state, {
  String providerId = 'claude',
  String detail = 'detail',
  String? remediation,
}) => CredentialHealthChangedEvent(
  providerId: providerId,
  state: state,
  detail: detail,
  remediation: remediation,
  timestamp: DateTime.utc(2026, 8, 15),
);

void main() {
  group('classifyAlert for credential health', () {
    const expected = {
      CredentialHealthState.nearingExpiry: (alertType: 'credential_expiry', severity: AlertSeverity.warning),
      CredentialHealthState.refreshFailure: (alertType: 'credential_refresh_failure', severity: AlertSeverity.warning),
      CredentialHealthState.reauthRequired: (alertType: 'credential_reauth_required', severity: AlertSeverity.critical),
      CredentialHealthState.contractBreak: (alertType: 'credential_contract_break', severity: AlertSeverity.critical),
    };

    for (final entry in expected.entries) {
      test('${entry.key.jsonName} yields its own alert type and severity', () {
        final result = classifyAlert(_event(entry.key));
        expect(result, isNotNull);
        expect(result!.alertType, entry.value.alertType);
        expect(result.severity, entry.value.severity);
      });
    }

    test('each degraded state has a distinct alert type', () {
      expect(expected.values.map((value) => value.alertType).toSet(), hasLength(expected.length));
    });

    for (final state in [CredentialHealthState.healthy, CredentialHealthState.unknown]) {
      test('${state.jsonName} is not alertable', () {
        expect(classifyAlert(_event(state)), isNull);
      });
    }
  });

  // The four degraded states share one body and one detail map. These are the
  // ADR-053 contract wording, moved verbatim out of AlertFormatter, so they are
  // pinned literally rather than by `contains`.
  group('classifyAlert content for credential health', () {
    test('the body names the provider and appends the remediation when there is one', () {
      final result = classifyAlert(
        _event(
          CredentialHealthState.nearingExpiry,
          detail: 'Claude setup-token needs renewal within 20 days.',
          remediation: 'claude setup-token',
        ),
      )!;
      expect(
        result.body,
        "Provider 'claude': Claude setup-token needs renewal within 20 days. Remediation: claude setup-token",
      );
      expect(result.details, {'Provider': 'claude', 'State': 'nearing-expiry', 'Remediation': 'claude setup-token'});
    });

    test('a remediation-less state omits the clause and the detail field entirely', () {
      final result = classifyAlert(
        _event(
          CredentialHealthState.contractBreak,
          providerId: 'codex',
          detail: 'Upstream rejected the mediated Bearer form itself (HTTP 403).',
        ),
      )!;
      expect(result.body, "Provider 'codex': Upstream rejected the mediated Bearer form itself (HTTP 403).");
      expect(result.details, {'Provider': 'codex', 'State': 'contract-break'});
    });

    test('a derived expiry is rendered as an estimate, a published one is not', () {
      Map<String, String>? detailsFor({required bool derived}) => classifyAlert(
        CredentialHealthChangedEvent(
          providerId: 'claude',
          state: CredentialHealthState.refreshFailure,
          detail: 'detail',
          expiry: CredentialExpiry(
            issuedAt: DateTime.utc(2026, 1, 1),
            expiresAt: DateTime.utc(2027, 1, 1),
            derived: derived,
          ),
          timestamp: DateTime.utc(2026, 8, 15),
        ),
      )!.details;

      expect(detailsFor(derived: true), {
        'Provider': 'claude',
        'State': 'refresh-failure',
        'Expires': '2027-01-01T00:00:00.000Z (estimated)',
      });
      expect(detailsFor(derived: false)!['Expires'], '2027-01-01T00:00:00.000Z');
    });

    test('reauth-required carries the same shape as the other degraded states', () {
      final result = classifyAlert(
        _event(
          CredentialHealthState.reauthRequired,
          providerId: 'ghost',
          detail: 'No credential can be presented: auth is set to api_key but no API key is configured.',
        ),
      )!;
      expect(
        result.body,
        "Provider 'ghost': No credential can be presented: auth is set to api_key but no API key is configured.",
      );
      expect(result.details, {'Provider': 'ghost', 'State': 'reauth-required'});
    });
  });

  group('AlertFormatter for credential health', () {
    test('nearing expiry names the provider and the remediation, and carries no token', () {
      final event = _event(
        CredentialHealthState.nearingExpiry,
        detail: 'Claude setup-token needs renewal within 20 days.',
        remediation: 'claude setup-token',
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'whatsapp');

      expect(response.text, contains('Credential Nearing Expiry'));
      expect(response.text, contains('claude'));
      expect(response.text, contains('20 days'));
      expect(response.text, contains('claude setup-token'));
      expect(response.text, contains('[WARNING]'));
      expect(response.text, isNot(contains('sk-ant-')));
    });

    test('contract break is titled "Mediation Contract Broken" and never blames the credential', () {
      final event = _event(
        CredentialHealthState.contractBreak,
        providerId: 'codex',
        detail: 'Upstream rejected the mediated Bearer form itself (HTTP 403).',
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'googlechat');

      expect(response.text, contains('Mediation Contract Broken'));
      // Re-authenticating cannot fix a backend auth-scheme change, so the alert
      // must not read as an expiry or send the operator to a login.
      final lowered = response.text.toLowerCase();
      for (final forbidden in [
        'expire',
        'expired',
        're-authenticat',
        'reauthenticat',
        'log in',
        'login',
        'setup-token',
      ]) {
        expect(lowered, isNot(contains(forbidden)), reason: '"$forbidden" must not appear in a contract-break alert');
      }
      expect(response.structuredPayload, isNotNull);
    });

    test('the Google Chat card details carry the provider, state and estimated-expiry flag', () {
      final event = CredentialHealthChangedEvent(
        providerId: 'claude',
        state: CredentialHealthState.nearingExpiry,
        detail: 'Claude setup-token needs renewal within 20 days.',
        remediation: 'claude setup-token',
        expiry: CredentialExpiry(
          issuedAt: DateTime.utc(2026, 1, 1),
          expiresAt: DateTime.utc(2027, 1, 1),
          derived: true,
        ),
        timestamp: DateTime.utc(2026, 8, 15),
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'googlechat');

      final payload = response.structuredPayload.toString();
      expect(payload, contains('claude'));
      expect(payload, contains('nearing-expiry'));
      expect(payload, contains('2027-01-01'));
      expect(payload, contains('estimated'));
    });

    test('a reauth-required alert without a remediation still names the provider', () {
      final event = _event(
        CredentialHealthState.reauthRequired,
        providerId: 'ghost',
        detail: 'No credential can be presented: auth is set to api_key but no API key is configured.',
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'signal');

      expect(response.text, contains('Re-authentication Required'));
      expect(response.text, contains('ghost'));
      expect(response.text, isNot(contains('Remediation:')));
    });
  });
}
