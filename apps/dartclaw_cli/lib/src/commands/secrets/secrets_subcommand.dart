import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

import '../config_loader.dart';
import '../credential_subcommand.dart';

/// Shared composition root for the `dartclaw secrets` subcommands.
///
/// Every one of them opens [NamedCredentialStore] once per invocation, before
/// it handles any credential material.
abstract class SecretsSubcommand extends CredentialSubcommand {
  new({super.stdoutLine, super.stderrLine, super.exitFn, super.environment});

  /// The config this invocation addresses, **without** stored credentials
  /// merged in.
  ///
  /// `secrets list` and `secrets audit` report on the difference between the
  /// store and the config file, so they need the config file's own view; the
  /// merged one would show a shadowed name only as its stored entry. The write
  /// paths need nothing from the merge either — only `server.data_dir`.
  DartclawConfig loadDeclaredConfig() {
    ensureCliChannelConfigsRegistered();
    return DartclawConfig.load(
      configPath: configPathOverride,
      cliOverrides: {'data_dir': ?dataDirOverride},
      env: environment,
    );
  }

  /// Opens the named store, refusing rather than throwing.
  ///
  /// Callers must open before they take a credential from the operator:
  /// opening runs the login-store collision guard and creates the owner-only
  /// directories, so an unusable store refuses while the operator still holds
  /// the credential.
  NamedCredentialStore openStore(String credentialsDir, {bool provision = true}) {
    try {
      return provision
          ? NamedCredentialStore.open(credentialsDir: credentialsDir, environment: environment)
          : NamedCredentialStore.readOnly(credentialsDir: credentialsDir, environment: environment);
    } on LoginStoreCollisionError catch (error) {
      stderrLine('$error');
      exitFn(1);
    } catch (error) {
      // Deliberately unrestricted: provisioning also chmods, which reports
      // failure as a StateError rather than a FileSystemException, and every way of
      // failing to open must refuse with a message while the operator still
      // holds the credential.
      stderrLine(
        'Cannot open the named credential store at "$credentialsDir": ${CredentialSubcommand.reasonFor(error)}.',
      );
      exitFn(1);
    }
  }

  /// The single `<name>` positional, validated.
  ///
  /// The store is addressed by filename, so a name is checked against the
  /// pattern before any path is built from it.
  String readNameArgument() {
    final rest = argResults!.rest;
    if (rest.length > 1) {
      stderrLine(
        '`$selfInvocation` takes one name and nothing else. A value passed on the command line is recorded in your '
        'shell history and visible in the process list — if it was a credential, treat it as exposed and issue a new '
        'one.',
      );
      exitFn(1);
    }
    if (rest.isEmpty) {
      stderrLine('A credential name is required: `$selfInvocation <name>`.');
      exitFn(1);
    }
    final name = rest.single;
    if (!NamedCredentialStore.isValidName(name)) {
      stderrLine(
        '"$name" is not a usable credential name — it must match ${NamedCredentialStore.namePattern.pattern}.',
      );
      exitFn(1);
    }
    return name;
  }
}
