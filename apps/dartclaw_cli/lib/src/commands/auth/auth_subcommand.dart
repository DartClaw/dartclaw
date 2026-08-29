import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

import '../config_loader.dart';
import '../credential_subcommand.dart';

/// Sink for one line of an `auth` subcommand's output.
typedef AuthWriteLine = CredentialWriteLine;

/// Shared composition root for the `dartclaw auth` subcommands.
///
/// Each subcommand opens [SubscriptionCredentialStore] exactly once per
/// invocation, before it handles any credential material.
abstract class AuthSubcommand extends CredentialSubcommand {
  new({super.stdoutLine, super.stderrLine, super.exitFn, super.environment});

  /// The config this invocation writes against.
  ///
  /// `--data-dir` is honored for the same reason `serve` honors it: the store is
  /// derived from `server.data_dir`, so a `serve --data-dir` that overrides the
  /// YAML value reads a store no `--config`-only invocation here can address.
  DartclawConfig loadConfig() =>
      loadCliConfig(configPath: configPathOverride, cliOverrides: {'data_dir': ?dataDirOverride});

  /// Refuses any positional argument.
  ///
  /// `args` accepts and discards them, so an operator who typed a credential
  /// here — plausible when one subcommand of this group does take one — would
  /// otherwise get no signal that it is now in their shell history and was
  /// visible in the process list.
  void refuseArguments() {
    if (argResults!.rest.isEmpty) return;
    stderrLine(
      '`dartclaw auth $name` takes no arguments. A value passed on the command line is recorded in your shell '
      'history and visible in the process list — if it was a credential, treat it as exposed and issue a new one.',
    );
    exitFn(1);
  }

  /// Opens the dedicated stores, refusing rather than throwing.
  ///
  /// Callers must open before they take a credential from the operator: opening
  /// runs the login-store collision guard and creates the owner-only
  /// directories, so an unusable store refuses while the operator still holds
  /// the credential.
  SubscriptionCredentialStore openStore(String credentialsDir) {
    try {
      return SubscriptionCredentialStore.open(credentialsDir: credentialsDir, environment: environment);
    } on LoginStoreCollisionError catch (error) {
      stderrLine('$error');
      exitFn(1);
    } catch (error) {
      // Deliberately unrestricted: opening also chmods, which reports failure as
      // a StateError rather than a FileSystemException, and *every* way of
      // failing to open must refuse with a message while the operator still
      // holds the credential.
      stderrLine('Cannot open the dedicated credential store at "$credentialsDir": ${reasonFor(error)}.');
      exitFn(1);
    }
  }

  /// The cause without a stack trace, as [CredentialSubcommand.reasonFor]
  /// renders it.
  static String reasonFor(Object error) => CredentialSubcommand.reasonFor(error);
}
