@Tags(['integration'])
@Timeout(Duration(minutes: 2))
library;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show SubscriptionCredentialStore;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'setup_token_wire_verdict.dart';

/// Pre-ship wire check: does Anthropic accept a stored static `setup-token`
/// presented as a raw Bearer under the OAuth beta?
///
/// The spike behind ADR-053 proved the *interactive* OAuth token on this wire.
/// The static `setup-token` the dedicated store holds was never driven through
/// it, and only the real endpoint can answer. Container-mode Claude ships
/// subscription-default only on acceptance; a rejection means the container arm
/// falls back to `x-api-key` mediation with a remediation naming the raw-Bearer
/// rejection, while host mode — where the CLI authenticates itself — is
/// unaffected either way.
///
/// Run it against a real stored token:
/// ```
/// dart test --run-skipped -t integration \
///   packages/dartclaw_runtime/test/integration/anthropic_setup_token_bearer_wire_check_test.dart
/// ```
/// The store is resolved from `DARTCLAW_CREDENTIALS_DIR`, else `$DARTCLAW_HOME`,
/// else `~/.dartclaw` — matching how the runtime finds its instance root. A
/// skip means the gate did not run — no stored token, or one at or past its
/// renewal deadline — never that the token was accepted; the three outcomes it
/// can report live in `setup_token_wire_verdict.dart`.
void main() {
  test('Anthropic accepts a stored setup-token as a raw Bearer', () async {
    final token = _storedSetupToken();
    if (token == null) {
      // Skipped, never passed: an absent token proves nothing about the wire,
      // and a green result here would be read as acceptance.
      markTestSkipped(
        'No Claude setup-token in ${_credentialsDir() ?? "the dedicated store"} – '
        'run "claude setup-token" and store it before the pre-ship gate.',
      );
      return;
    }
    if (_pastRenewalDeadline(token.expiry)) {
      // Skipped for the same reason an absent token is: an expired credential
      // answers 401 about its own age, and recording that as REJECTED would
      // ship the x-api-key fallback over a token that only needed renewing.
      markTestSkipped(
        'The stored Claude setup-token is at or past its renewal deadline '
        '(${token.expiry!.expiresAt.toIso8601String()}) – run "claude setup-token", store it with '
        '"dartclaw auth claude", and re-run the gate. An expired token cannot answer its question.',
      );
      return;
    }

    final adapter = AnthropicMessagesAdapter(
      credential: ProviderCredentialSource(() => CredentialResolution.subscription(token)),
    );
    addTearDown(adapter.dispose);

    await checkSetupTokenOnTheWire(adapter);
  });
}

String? _credentialsDir() {
  final override = Platform.environment['DARTCLAW_CREDENTIALS_DIR']?.trim();
  if (override != null && override.isNotEmpty) return override;
  final instanceRoot = Platform.environment['DARTCLAW_HOME']?.trim();
  if (instanceRoot != null && instanceRoot.isNotEmpty) return p.join(instanceRoot, 'credentials');
  final home = Platform.environment['HOME']?.trim();
  return home == null || home.isEmpty ? null : p.join(home, '.dartclaw', 'credentials');
}

/// Whether the stored credential is too close to its deadline to answer the
/// gate's question.
///
/// The last day before it counts as past: the Claude expiry is derived from a
/// documented lifetime rather than read off the token, so a refusal that near
/// the deadline is far likelier to be a genuinely spent token than a refused
/// raw Bearer.
bool _pastRenewalDeadline(CredentialExpiry? expiry) =>
    expiry != null && expiry.expiresAt.isBefore(DateTime.now().add(const Duration(days: 1)));

CredentialEntry? _storedSetupToken() {
  final dir = _credentialsDir();
  if (dir == null || !Directory(dir).existsSync()) return null;
  return SubscriptionCredentialStore.open(credentialsDir: dir).read('claude');
}
