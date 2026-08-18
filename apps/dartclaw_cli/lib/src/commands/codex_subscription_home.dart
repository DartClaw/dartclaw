import 'package:dartclaw_config/dartclaw_config.dart'
    show CredentialMode, CredentialRegistry, CredentialUnavailableReason, ProviderIdentity, credentialRemediationFor;
import 'package:dartclaw_core/dartclaw_core.dart' show CredentialHealthState;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        CodexCredentialPresented,
        CodexCredentialRotatedAway,
        CodexReauthRequired,
        CodexRefreshAuthority,
        CodexRefreshFailed;

/// Announces a host-boundary Codex credential condition to the deployment's
/// credential-health writer.
///
/// Structurally identical to `CredentialHealthMonitor.report`, so a composition
/// root holding the monitor passes it straight through. Optional: a lane with
/// no monitor keeps the throw below as its only signal.
typedef CodexCredentialHealthSink = void Function({
  required String providerId,
  required CredentialHealthState state,
  required String detail,
  String? remediation,
});

/// What an operator-facing alert says about a spawn this function refused; the
/// remediation that travels with it carries the fix.
const _refusedDetail = 'The host Codex spawn was refused because the selected credential cannot be presented.';

/// Prepares the DartClaw-dedicated `CODEX_HOME` for a host Codex spawn and
/// returns its path, or `null` when [registry] resolves an API key instead.
///
/// The freshness gate runs inside the authority's per-store critical section,
/// so the vendor CLI is handed a store that is not mid-rotation and holds a
/// token whose remaining life is outside the near-expiry window — leaving the
/// vendor no cause to rotate at spawn time. A rotation later in a long turn is
/// routine and is recovered on the next gate pass, not prevented here.
///
/// Throws when a credential was selected but cannot be presented — nothing
/// stored, no API key, or an unreadable `providers.<id>.auth`. None of those
/// resolve to a mode, and answering `null` for them would spawn against the
/// operator's own `~/.codex` login, which this deployment must never read.
/// [CredentialUnavailableReason.noneConfigured] is the one exception: nothing
/// was selected, so the vendor CLI's own login stays admissible.
///
/// [credentialsDir] is the dedicated store the refusal searched, and
/// [onCredentialHealth] the sink a refusal is announced through — the host
/// boundary reaches no gateway, so this is where its FR6 signal originates.
Future<String?> prepareCodexSubscriptionHome({
  required CredentialRegistry registry,
  required CodexRefreshAuthority authority,
  String providerId = ProviderIdentity.codex,
  String? family,
  String? credentialsDir,
  CodexCredentialHealthSink? onCredentialHealth,
}) async {
  Never refuse({required CredentialHealthState state, required String detail, String? remediation}) {
    onCredentialHealth?.call(providerId: providerId, state: state, detail: detail, remediation: remediation);
    throw StateError(remediation == null ? detail : '$detail $remediation');
  }

  final resolution = registry.resolve(providerId, family: family);
  final reason = resolution.reason;
  if (reason != null && reason != CredentialUnavailableReason.noneConfigured) {
    refuse(
      state: CredentialHealthState.reauthRequired,
      detail: _refusedDetail,
      remediation: credentialRemediationFor(
        reason,
        providerId: providerId,
        family: family,
        credentialsDir: credentialsDir,
      ),
    );
  }
  if (resolution.mode != CredentialMode.subscription) return null;
  return authority.prepareHostSpawn(
    (outcome) => switch (outcome) {
      CodexCredentialPresented() || CodexCredentialRotatedAway() => authority.codexHome,
      CodexReauthRequired(:final detail, :final remediation) => refuse(
        state: CredentialHealthState.reauthRequired,
        detail: detail,
        remediation: remediation,
      ),
      CodexRefreshFailed(:final detail) => refuse(state: CredentialHealthState.refreshFailure, detail: detail),
    },
  );
}
