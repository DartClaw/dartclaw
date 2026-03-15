import 'dart:io';

/// Factory for starting a subprocess used by a harness or sidecar manager.
typedef ProcessFactory =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment,
    });

/// One-shot command callback used for availability probes and diagnostics.
typedef CommandProbe = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Injectable async delay used to make retry and backoff logic testable.
typedef DelayFactory = Future<void> Function(Duration duration);

/// Lightweight health-check callback used by subprocess managers.
typedef HealthProbe = Future<bool> Function();
