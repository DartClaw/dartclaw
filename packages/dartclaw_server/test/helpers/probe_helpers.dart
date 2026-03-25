import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show CommandProbe;

/// Creates a [CommandProbe] that dispatches to per-executable probes.
///
/// Throws a [ProcessException] for any executable not present in [probes].
CommandProbe probeResults(Map<String, CommandProbe> probes) {
  return (executable, arguments) {
    final probe = probes[executable];
    if (probe == null) {
      throw ProcessException(executable, arguments, 'No probe configured for test');
    }
    return probe(executable, arguments);
  };
}

/// Creates a [CommandProbe] that returns a successful result with the given
/// [stdout] and optional [stderr].
CommandProbe probeOk(String stdout, {String stderr = ''}) {
  return (executable, arguments) async => ProcessResult(1, 0, stdout, stderr);
}

/// Creates a [CommandProbe] that returns a result with the given [exitCode].
CommandProbe probeExitCode(int exitCode, {String stdout = '', String stderr = ''}) {
  return (executable, arguments) async => ProcessResult(1, exitCode, stdout, stderr);
}

/// Creates a [CommandProbe] that throws a [ProcessException], simulating
/// a missing binary.
CommandProbe probeMissing(String executableName) {
  return (executable, arguments) async =>
      throw ProcessException(executableName, arguments, 'missing binary');
}
