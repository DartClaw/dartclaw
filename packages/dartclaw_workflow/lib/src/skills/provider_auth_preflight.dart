import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show CredentialRegistry, ProviderIdentity;
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

  const ProviderAuthResult.authenticated(this.provider) : authenticated = true, remediationMessage = null;

  const ProviderAuthResult.unauthenticated(this.provider, String message)
    : authenticated = false,
      remediationMessage = message;
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

typedef AuthProbeRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments, {Map<String, String>? environment});

typedef AuthProbeEnvironmentBuilder = Map<String, String> Function(String provider);

/// CLI-backed [ProviderAuthPreflight].
///
/// A configured provider API key short-circuits as authenticated before any
/// process spawn; otherwise the provider CLI is probed via an injectable runner
/// (claude = `claude auth status` JSON `loggedIn`; codex = `codex login status`
/// exit-code/text). The runner seam mirrors `CliSkillIntrospector` so unit tests
/// never spawn a real provider CLI.
final class CliProviderAuthPreflight implements ProviderAuthPreflight {
  final AuthProbeRunner _runner;
  final CredentialRegistry _credentials;
  final AuthProbeEnvironmentBuilder? _environmentForProvider;
  final Map<String, String> _environment;

  CliProviderAuthPreflight({
    required CredentialRegistry credentials,
    AuthProbeRunner? runner,
    AuthProbeEnvironmentBuilder? environmentForProvider,
    Map<String, String> environment = const <String, String>{},
  }) : _credentials = credentials,
       _runner = runner ?? _defaultRunner,
       _environmentForProvider = environmentForProvider,
       _environment = Map.unmodifiable(environment);

  @override
  Future<ProviderAuthResult> evaluate({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  }) async {
    final family = ProviderIdentity.resolveFamily(provider, options: providerOptions, executable: executable);
    // API-key presence wins before any spawn: an API-key user may have no
    // logged-in CLI, so probing the CLI first would false-fail. Family-aware
    // resolution is shared with the spawn-env builder (CredentialRegistry) so
    // the short-circuit decision can never disagree with key injection.
    if (_credentials.getApiKeyForFamily(provider, family) != null) {
      return ProviderAuthResult.authenticated(provider);
    }
    final resolvedExecutable = executable?.trim().isNotEmpty == true ? executable!.trim() : _defaultExecutable(family);
    final environment = _environmentForProvider?.call(provider) ?? _environment;
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
    return ProviderAuthResult.unauthenticated(provider, _remediation(provider, family));
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
    return ProviderAuthResult.unauthenticated(provider, _remediation(provider, family));
  }

  Future<ProcessResult> _run(String executable, List<String> arguments, Map<String, String> environment) async {
    try {
      return await _runner(executable, arguments, environment: environment.isEmpty ? null : environment);
    } on Exception {
      return ProcessResult(0, 1, '', '');
    }
  }

  static String _remediation(String provider, String family) {
    final envVars = CredentialRegistry.envVarsForFamily(provider, family);
    final envHint = envVars.isEmpty ? '' : ' or set ${envVars.join(' / ')}';
    final cliHint = switch (family) {
      ProviderIdentity.claude => 'run `claude login` or `claude setup-token`',
      ProviderIdentity.codex => 'run `codex login`',
      _ => 'log in to the "$provider" CLI',
    };
    return 'Workflow provider "$provider" is not authenticated: $cliHint$envHint, then re-run.';
  }

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
