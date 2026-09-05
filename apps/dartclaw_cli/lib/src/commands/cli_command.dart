import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExitFn, WriteLine;
import 'package:meta/meta.dart';

abstract class CliCommand extends Command<void> {
  final DartclawConfig? _config;
  @protected
  final WriteLine writeLine;
  @protected
  final ExitFn exitFn;
  @protected
  final WriteLine stderrLine;

  new({DartclawConfig? config, WriteLine? writeLine, ExitFn? exitFn, WriteLine? stderrLine})
    : _config = config,
      writeLine = writeLine ?? stdout.writeln,
      exitFn = exitFn ?? exit,
      stderrLine = stderrLine ?? stderr.writeln;

  /// The injected [DartclawConfig], when one was provided to the constructor.
  ///
  /// Commands with a standalone (server-less) path read this to honour an
  /// injected config before falling back to loading one from disk.
  @protected
  DartclawConfig? get injectedConfig => _config;

  /// Returns the first positional arg, or throws [UsageException] with
  /// [missingMessage] when absent.
  @protected
  String requirePositionalArg(String missingMessage) {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException(missingMessage, usage);
    }
    return args.first;
  }
}
