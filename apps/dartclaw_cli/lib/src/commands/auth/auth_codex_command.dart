import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

import 'auth_subcommand.dart';

typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  bool includeParentEnvironment,
  ProcessStartMode mode,
});

/// Runs the vendor `codex login` against DartClaw's dedicated `CODEX_HOME`.
///
/// DartClaw writes no Codex credential itself; the vendor CLI owns `auth.json`.
class AuthCodexCommand extends AuthSubcommand {
  final ProcessStarter _startProcess;

  new({super.stdoutLine, super.stderrLine, super.exitFn, super.environment, ProcessStarter? startProcess})
    : _startProcess = startProcess ?? Process.start;

  @override
  String get name => 'codex';

  @override
  String get description => 'Sign Codex in (runs `codex login`) against this DartClaw instance\'s dedicated CODEX_HOME';

  @override
  Future<void> run() async {
    refuseArguments();
    final config = loadConfig();
    final store = openStore(config.credentialsDir);
    final executable = config.providers[ProviderIdentity.codex]?.executable ?? 'codex';
    // Re-authentication is the common case — the health monitor and the refresh
    // authority both send the operator here with a dead credential already in
    // place — so the store as it stands is not evidence about this run.
    final priorWrite = store.read(ProviderIdentity.codex)?.expiry?.issuedAt;
    final process = await _startLogin(executable, store.codexHome);
    if (await process.exitCode != 0) {
      stderrLine('`$executable login` did not complete, so no Codex credential was stored in ${store.codexHome}.');
      exitFn(1);
    }
    final credential = _requireResolvableCredential(store, executable);
    // An untouched store is a success, not a failure: an operator who is already
    // signed in re-runs this command, the vendor CLI returns without rewriting
    // anything, and the deployment is left exactly as it needs to be.
    stdoutLine(
      credential.expiry?.issuedAt == priorWrite
          ? 'Codex was already signed in against ${store.codexHome}, so `$executable login` left the existing '
                'credential in place.'
          : 'Codex is signed in against ${store.codexHome}',
    );
  }

  /// A vendor exit of `0` is not the outcome the operator needs; a credential
  /// this deployment can resolve is. Each way of falling short is reported as
  /// itself — telling an operator the vendor stored nothing when it wrote a
  /// store DartClaw cannot parse sends them to the wrong place.
  CredentialEntry _requireResolvableCredential(SubscriptionCredentialStore store, String executable) {
    final credential = store.read(ProviderIdentity.codex);
    if (credential == null) {
      stderrLine(
        File(store.codexAuthPath).existsSync()
            ? '`$executable login` wrote ${store.codexAuthPath}, but DartClaw cannot read a credential from it.'
            : '`$executable login` reported success but stored no credential in ${store.codexHome}.',
      );
      exitFn(1);
    }
    return credential;
  }

  /// The operator's own interactive session, so it gets their real environment
  /// (`HOME`, `PATH`, browser variables) with only `CODEX_HOME` overridden —
  /// not the sanitized one an agent's subprocess would get.
  Future<Process> _startLogin(String executable, String codexHome) async {
    try {
      return await _startProcess(
        executable,
        const ['login'],
        environment: {...environment, 'CODEX_HOME': codexHome},
        includeParentEnvironment: false,
        mode: ProcessStartMode.inheritStdio,
      );
    } on ProcessException catch (error) {
      // Reported verbatim rather than assumed to be "not installed": a
      // non-executable or unrunnable `codex` needs a different fix.
      stderrLine(
        'Could not run `$executable login`: ${error.message}. Fix the Codex CLI and re-run this command, or run:',
      );
      stderrLine('  CODEX_HOME="$codexHome" $executable login');
      exitFn(1);
    }
  }
}
