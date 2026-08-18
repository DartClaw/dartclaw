import 'package:dartclaw_config/dartclaw_config.dart' show CredentialMode, CredentialResolution, ProviderIdentity;
import 'package:logging/logging.dart';

import '../../task/codex_refresh_authority.dart';
import 'gateway_models.dart';
import 'provider_adapter.dart';

/// The Codex adapter's credential, gated on freshness before every injection.
///
/// The two views split by question, not by freshness: [resolve] answers whether
/// a credential is configured at all, so a stored-but-expired one still reports
/// present and admission does not refuse a container the gate could still
/// recover. [present] is where the token is actually made usable, so a request
/// never carries one the expiry window has already caught up with.
final class CodexCredentialSource extends ProviderCredentialSource {
  new({
    required CredentialResolution Function() resolve,
    this.providerId = ProviderIdentity.codex,
    this.authority,
    this.onRefreshOutcome,
  }) : super(resolve);

  static final _log = Logger('CodexCredentialSource');

  /// The provider whose authority this source presents for, named on a terminal
  /// failure so the teardown and the health report identify the right entry.
  final String providerId;

  /// Rotates the dedicated store, or `null` where this deployment presents an
  /// API key and has nothing to rotate.
  final CodexRefreshAuthority? authority;

  /// Where each gate pass is reported, fire-and-forget.
  final void Function(CodexRefreshOutcome outcome)? onRefreshOutcome;

  @override
  Future<CredentialResolution> present() async {
    final configured = resolve();
    final gate = authority;
    if (configured.mode != CredentialMode.subscription || gate == null) return configured;

    final CodexRefreshOutcome outcome;
    try {
      outcome = await gate.present();
    } on Object catch (error, stackTrace) {
      // The gate reports its own failures as outcomes, so anything thrown is
      // unexpected — and must still not strand a request on an unbounded await.
      _log.warning('Codex credential gate failed unexpectedly', error, stackTrace);
      throw const GatewayDenied(status: 503, reason: 'the stored Codex subscription credential could not be prepared');
    }
    onRefreshOutcome?.call(outcome);

    switch (outcome) {
      case CodexCredentialPresented(:final credential) || CodexCredentialRotatedAway(:final credential):
        return CodexSubscriptionResolution(credential);
      // Terminal and transient are answered differently on purpose: a spent
      // refresh lineage cannot be repaired by any later request, so the
      // authority ends rather than re-failing every turn on a dead credential,
      // while a refresh that merely failed is a wait the operator rides out.
      case CodexReauthRequired(:final detail, :final remediation):
        throw GatewayCredentialUnusable(providerId: providerId, remediation: '$detail. $remediation');
      case CodexRefreshFailed(:final detail):
        throw GatewayDenied(status: 503, reason: detail);
    }
  }
}
