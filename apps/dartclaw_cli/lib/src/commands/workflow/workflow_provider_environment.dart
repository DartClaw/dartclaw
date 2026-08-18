import 'package:dartclaw_config/dartclaw_config.dart' show CredentialRegistry, ProviderIdentity;
import 'package:dartclaw_core/dartclaw_core.dart' show claudeHardeningEnvVars;
import 'package:dartclaw_security/dartclaw_security.dart' show SafeProcess;
import 'package:dartclaw_server/dartclaw_server.dart' show CodexRefreshAuthority;

import '../codex_subscription_home.dart';
import '../provider_credential_environment.dart';

/// Builds the sanitized spawn environment for a workflow provider CLI.
///
/// Sanitizes [baseEnvironment] (no allowlist, sensitive-name strip, and
/// Claude-only hardening where applicable) and overlays the single credential
/// [registry] resolves for the provider. No allowlist is applied, so `USER` is
/// preserved — the standalone `claude` CLI reads its keychain subscription
/// OAuth only when `USER` is present (`HOME`+`PATH` alone resolve to "not
/// logged in").
/// [providerFamily] is required, and callers must derive it with
/// `ProviderIdentity.resolveFamily` — a name-only family silently misclassifies
/// a provider alias as its own family, which is how an aliased Claude provider
/// spawns with no credential.
///
/// [subscriptionHome] is the prepared dedicated `CODEX_HOME`; only a caller that
/// spawns the vendor CLI itself supplies one — see
/// [buildWorkflowProbeEnvironment].
Map<String, String> buildWorkflowProviderEnvironment({
  required String providerId,
  required String providerFamily,
  required CredentialRegistry registry,
  required Map<String, String> baseEnvironment,
  String? subscriptionHome,
}) {
  final environment = SafeProcess.sanitize(
    baseEnvironment: baseEnvironment,
    extraEnvironment: providerFamily == ProviderIdentity.claude ? claudeHardeningEnvVars : const {},
  );
  // Family-aware key + env-var resolution is shared with the workflow auth
  // preflight (CredentialRegistry) so the preflight's "key present → skip CLI
  // probe" decision can never disagree with which key gets injected here.
  return overlayProviderCredential(
    environment: environment,
    registry: registry,
    providerId: providerId,
    providerFamily: providerFamily,
    subscriptionHome: subscriptionHome,
  );
}

/// Builds the spawn environment for a workflow provider *probe* — the skill
/// introspection turn and the CLI auth preflight — which run the vendor CLI
/// directly.
///
/// The execution lanes are handed their dedicated `CODEX_HOME` per spawn by the
/// harness or the one-shot provider driver; a probe has no driver downstream, so
/// its own environment must carry the store or the vendor CLI authenticates on
/// whatever ambient login it finds — or, with none, fails the turn and reports
/// it as a skill-introspection error.
///
/// Throws the refusal `prepareCodexSubscriptionHome` raises when a selected
/// credential cannot be presented: probing on the credential the operator ruled
/// out is exactly what must not happen.
///
/// [onCredentialHealth] carries that refusal to the deployment's credential-health
/// writer. Only the `serve` lane supplies it, because only that lane has a
/// monitor: the standalone `dartclaw workflow` run and `workflow validate` are
/// their own processes, build no `ProviderStatusService`, and install no
/// root-logger listener — a sink there would have no reader, and the refusal
/// already reaches their operator as the command's own failure.
Future<Map<String, String>> buildWorkflowProbeEnvironment({
  required String providerId,
  required String providerFamily,
  required CredentialRegistry registry,
  required Map<String, String> baseEnvironment,
  required CodexRefreshAuthority codexRefresh,
  String? credentialsDir,
  CodexCredentialHealthSink? onCredentialHealth,
}) async {
  final subscriptionHome = providerFamily == ProviderIdentity.codex
      ? await prepareCodexSubscriptionHome(
          registry: registry,
          authority: codexRefresh,
          providerId: providerId,
          family: providerFamily,
          credentialsDir: credentialsDir,
          onCredentialHealth: onCredentialHealth,
        )
      : null;
  return buildWorkflowProviderEnvironment(
    providerId: providerId,
    providerFamily: providerFamily,
    registry: registry,
    baseEnvironment: baseEnvironment,
    subscriptionHome: subscriptionHome,
  );
}
