import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExitFn;

/// Sink for one line of a credential command's operator-facing output.
typedef CredentialWriteLine = void Function(String line);

/// Shared composition root for the subcommands that address DartClaw's
/// credential stores (`dartclaw auth`, `dartclaw secrets`).
///
/// Carries the injected IO seams every one of them needs, and `--data-dir` for
/// the reason `serve` carries it: a store is derived from `server.data_dir`, so
/// a `serve --data-dir` that overrides the YAML value reads a store no
/// `--config`-only invocation here could address.
abstract class CredentialSubcommand extends Command<void> {
  /// Sink for confirmations and reports.
  final CredentialWriteLine stdoutLine;

  /// Sink for refusals.
  final CredentialWriteLine stderrLine;

  /// Process exit, injected so a refusal is observable in a test.
  final ExitFn exitFn;

  /// Environment the login-store collision guard resolves against.
  final Map<String, String> environment;

  new({
    CredentialWriteLine? stdoutLine,
    CredentialWriteLine? stderrLine,
    ExitFn? exitFn,
    Map<String, String>? environment,
  }) : stdoutLine = stdoutLine ?? stdout.writeln,
       stderrLine = stderrLine ?? stderr.writeln,
       exitFn = exitFn ?? exit,
       environment = environment ?? Platform.environment {
    argParser.addOption(
      'data-dir',
      help: 'Data directory path, selecting the credential store to write to (must match the running serve instance)',
    );
  }

  /// `--config` as the operator supplied it, or `null`.
  String? get configPathOverride {
    final value = globalResults?['config'] as String?;
    return value == null || value.isEmpty ? null : value;
  }

  /// `--data-dir` as the operator supplied it, or `null`.
  String? get dataDirOverride {
    if (argResults?.wasParsed('data-dir') != true) return null;
    final value = (argResults!['data-dir'] as String).trim();
    return value.isEmpty ? null : value;
  }

  /// This invocation, as an operator can paste it back, so a command that tells
  /// them to re-run it names the same instance rather than the default one.
  String get selfInvocation {
    final scope = configPathOverride == null ? '' : ' --config "$configPathOverride"';
    final store = dataDirOverride == null ? '' : ' --data-dir "$dataDirOverride"';
    final group = parent == null ? '' : '${parent!.name} ';
    return 'dartclaw$scope $group$name$store';
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
