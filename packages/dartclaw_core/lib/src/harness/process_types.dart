import 'dart:io';

typedef ProcessFactory =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment,
    });

typedef CommandProbe = Future<ProcessResult> Function(String executable, List<String> arguments);

typedef DelayFactory = Future<void> Function(Duration duration);

typedef HealthProbe = Future<bool> Function();
