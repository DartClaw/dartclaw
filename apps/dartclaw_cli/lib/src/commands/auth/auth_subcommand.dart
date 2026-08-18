import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

import '../config_loader.dart';
import '../serve_command.dart' show ExitFn;

typedef AuthWriteLine = void Function(String line);

/// Shared composition root for the `dartclaw auth` subcommands.
///
/// Each subcommand opens [SubscriptionCredentialStore] exactly once per
/// invocation, before it handles any credential material.
abstract class AuthSubcommand extends Command<void> {
  final AuthWriteLine stdoutLine;
  final AuthWriteLine stderrLine;
  final ExitFn exitFn;
  final Map<String, String> environment;

  new({AuthWriteLine? stdoutLine, AuthWriteLine? stderrLine, ExitFn? exitFn, Map<String, String>? environment})
    : stdoutLine = stdoutLine ?? stdout.writeln,
      stderrLine = stderrLine ?? stderr.writeln,
      exitFn = exitFn ?? exit,
      environment = environment ?? Platform.environment {
    argParser.addOption(
      'data-dir',
      help: 'Data directory path, selecting the credential store to write to (must match the running serve instance)',
    );
  }

  /// The config this invocation writes against.
  ///
  /// `--data-dir` is honored for the same reason `serve` honors it: the store is
  /// derived from `server.data_dir`, so a `serve --data-dir` that overrides the
  /// YAML value reads a store no `--config`-only invocation here can address.
  DartclawConfig loadConfig() =>
      loadCliConfig(configPath: globalResults?['config'] as String?, cliOverrides: {'data_dir': ?_dataDirOverride});

  String? get _dataDirOverride {
    if (argResults?.wasParsed('data-dir') != true) return null;
    final value = (argResults!['data-dir'] as String).trim();
    return value.isEmpty ? null : value;
  }

  /// This invocation, as an operator can paste it back, so a command that tells
  /// them to re-run it names the same instance rather than the default one.
  String get selfInvocation {
    final configPath = globalResults?['config'] as String?;
    final scope = configPath == null || configPath.isEmpty ? '' : ' --config "$configPath"';
    final dataDir = _dataDirOverride;
    final store = dataDir == null ? '' : ' --data-dir "$dataDir"';
    return 'dartclaw$scope auth $name$store';
  }

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

  /// The cause without a stack trace, and without ever stringifying an
  /// unrecognized error.
  ///
  /// A `FileSystemException`'s `osError` carries the actual reason, so dropping
  /// it would leave the refusal naming no cause at all. Anything else is named
  /// by type only: these messages are built on paths that hold the operator's
  /// credential, and `ArgumentError.value.toString()` embeds the value it
  /// rejected.
  static String reasonFor(Object error) => switch (error) {
    FileSystemException(:final message, :final osError?) => '$message (${osError.message})',
    FileSystemException(:final message) => message,
    StateError(:final message) => '$message (StateError)',
    _ => 'unexpected ${error.runtimeType}',
  };
}
