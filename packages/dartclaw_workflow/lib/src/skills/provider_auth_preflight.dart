import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart'
    show CredentialRegistry, CredentialUnavailableReason, ProviderIdentity, credentialRemediationFor;
import 'package:dartclaw_security/dartclaw_security.dart' show EnvPolicy, SafeProcess;

/// Outcome of evaluating one referenced provider's authentication state.
///
/// Carries an actionable [remediationMessage] (rather than throwing) so a
/// downstream advisory-tolerance change can downgrade a failure per criticality
/// instead of always aborting the run.
final class ProviderAuthResult {
  final String provider;
  final bool authenticated;

  /// Provider-named remediation guidance when [authenticated] is `false`; `null`
  /// when the provider is authenticated.
  final String? remediationMessage;

  const new authenticated(this.provider) : authenticated = true, remediationMessage = null;

  const new unauthenticated(this.provider, String message) : authenticated = false, remediationMessage = message;
}

/// Pre-step auth probe for a referenced workflow provider.
abstract interface class ProviderAuthPreflight {
  /// Evaluates whether [provider] is authenticated for a workflow run.
  Future<ProviderAuthResult> evaluate({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  });
}

typedef AuthProbeRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

/// Builds the probe's spawn environment for a provider.
///
/// Asynchronous for the same reason as `SkillProbeEnvironmentBuilder`: the
/// lanes share one builder, and presenting a subscription credential can
/// require preparing a dedicated provider home first.
typedef AuthProbeEnvironmentBuilder = Future<Map<String, String>> Function(String provider);

/// CLI-backed [ProviderAuthPreflight].
///
/// A configured provider API key short-circuits as authenticated before any
/// process spawn; otherwise the provider CLI is probed via an injectable runner
/// (claude = `claude auth status` JSON `loggedIn`; codex = `codex login status`
/// exit-code/text). The runner seam mirrors `CliSkillIntrospector` so unit tests
/// never spawn a real provider CLI.
final class CliProviderAuthPreflight implements ProviderAuthPreflight {
  final AuthProbeRunner _runner;
  final CredentialRegistry Function() _credentials;
  final AuthProbeEnvironmentBuilder? _environmentForProvider;
  final Map<String, String> _environment;
  final String? _credentialsDir;

  /// [credentials] answers a registry per [evaluate], not one snapshot: a lane
  /// whose executor rebuilds its registry per spawn would otherwise be gated by
  /// a boot-time view and refuse a step the executor itself would run — sending
  /// the operator back to a `dartclaw auth …` they already ran successfully.
  ///
  /// [credentialsDir] is the dedicated subscription store those registries read;
  /// it names the searched directory in every remediation this preflight emits.
  new({
    required CredentialRegistry Function() credentials,
    AuthProbeRunner? runner,
    AuthProbeEnvironmentBuilder? environmentForProvider,
    Map<String, String> environment = const <String, String>{},
    String? credentialsDir,
  }) : _credentials = credentials,
       _runner = runner ?? _defaultRunner,
       _environmentForProvider = environmentForProvider,
       _environment = Map.unmodifiable(environment),
       _credentialsDir = credentialsDir;

  @override
  Future<ProviderAuthResult> evaluate({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  }) async {
    final family = ProviderIdentity.resolveFamily(provider, options: providerOptions, executable: executable);
    // A presentable credential of either mode wins before any spawn: a
    // subscription token in DartClaw's own store, like an API key, leaves the
    // vendor CLI's own login irrelevant, so probing it first would false-fail.
    // The resolution is the same one the spawn-env builder uses, so the
    // short-circuit can never disagree with what is actually presented.
    final resolution = _credentials().resolve(provider, family: family);
    if (resolution.isPresent) {
      return ProviderAuthResult.authenticated(provider);
    }
    final reason = resolution.reason!;
    // A forced auth selection is not up for rescue by the vendor CLI's login:
    // the operator named the credential to present, and it is absent.
    if (reason != CredentialUnavailableReason.noneConfigured) {
      return ProviderAuthResult.unauthenticated(provider, _remediation(provider, family, reason));
    }
    final resolvedExecutable = executable?.trim().isNotEmpty == true ? executable!.trim() : _defaultExecutable(family);
    final environment = await _environmentForProvider?.call(provider) ?? _environment;
    return switch (family) {
      ProviderIdentity.claude => _probeClaude(provider, family, resolvedExecutable, environment),
      ProviderIdentity.codex => _probeCodex(provider, family, resolvedExecutable, environment),
      // No auth probe is configured for other provider families; do not block —
      // skill introspection still surfaces genuinely broken provider setups.
      _ => Future.value(ProviderAuthResult.authenticated(provider)),
    };
  }

  Future<ProviderAuthResult> _probeClaude(
    String provider,
    String family,
    String executable,
    Map<String, String> environment,
  ) async {
    final result = await _run(executable, const ['auth', 'status'], environment);
    if (result.exitCode == 0) {
      try {
        final status = jsonDecode((result.stdout ?? '').toString());
        if (status is Map && status['loggedIn'] == true) {
          return ProviderAuthResult.authenticated(provider);
        }
      } on FormatException {
        // Non-JSON output means the probe could not confirm an OAuth session.
      }
    }
    return ProviderAuthResult.unauthenticated(
      provider,
      _remediation(provider, family, CredentialUnavailableReason.noneConfigured),
    );
  }

  Future<ProviderAuthResult> _probeCodex(
    String provider,
    String family,
    String executable,
    Map<String, String> environment,
  ) async {
    final result = await _run(executable, const ['login', 'status'], environment);
    // `codex login status` is exit-code/text, not JSON: a logged-in session
    // exits 0 and prints "Logged in"; a logged-out one exits non-zero and prints
    // "Not logged in" (which the CLI emits on stderr, not stdout). Inspect both
    // streams so an exit-0-but-not-logged-in edge still fails closed.
    final output = '${result.stdout ?? ''}\n${result.stderr ?? ''}'.toLowerCase();
    final loggedOut =
        output.contains('not logged in') || output.contains('not authenticated') || output.contains('unauthenticated');
    final loggedIn = output.contains('logged in');
    if (result.exitCode == 0 && loggedIn && !loggedOut) {
      return ProviderAuthResult.authenticated(provider);
    }
    return ProviderAuthResult.unauthenticated(
      provider,
      _remediation(provider, family, CredentialUnavailableReason.noneConfigured),
    );
  }

  Future<ProcessResult> _run(String executable, List<String> arguments, Map<String, String> environment) async {
    try {
      return await _runner(executable, arguments, environment: environment.isEmpty ? null : environment);
    } on Exception {
      return ProcessResult(0, 1, '', '');
    }
  }

  String _remediation(String provider, String family, CredentialUnavailableReason reason) =>
      'Workflow provider "$provider" is not authenticated. '
      '${credentialRemediationFor(reason, providerId: provider, family: family, credentialsDir: _credentialsDir)} '
      'Then re-run.';

  static String _defaultExecutable(String family) => switch (family) {
    ProviderIdentity.claude => 'claude',
    ProviderIdentity.codex => 'codex',
    _ => family,
  };

  static Future<ProcessResult> _defaultRunner(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    return SafeProcess.run(
      executable,
      arguments,
      env: EnvPolicy.passthrough(environment: environment ?? const <String, String>{}),
    );
  }
}
