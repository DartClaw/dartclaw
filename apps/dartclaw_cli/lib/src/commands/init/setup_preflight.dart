import 'dart:io';

/// Pre-write validation for the init/setup command.
///
/// All checks run before any instance files are written. A non-empty [errors]
/// list means setup cannot proceed.
class SetupPreflight {
  final List<String> errors;
  final List<String> warnings;

  const SetupPreflight({required this.errors, required this.warnings});

  bool get passed => errors.isEmpty;

  /// Runs preflight checks for [providers] on [port] with [instanceDir].
  ///
  /// [runProcess] is injectable for tests.
  static Future<SetupPreflight> run({
    required List<String> providers,
    required int port,
    required String instanceDir,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
  }) async {
    final runner = runProcess ?? Process.run;
    final errors = <String>[];
    final warnings = <String>[];

    for (final provider in providers.toSet()) {
      final executable = provider == 'codex' ? 'codex' : 'claude';
      try {
        final result = await runner(executable, ['--version']);
        if (result.exitCode != 0) {
          errors.add("Provider binary '$executable' found but returned non-zero on --version");
        }
      } on ProcessException {
        errors.add(
          "Provider binary '$executable' not found in PATH. "
          'Install it: ${_installHint(provider)}',
        );
      }
    }

    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await socket.close();
    } on SocketException {
      errors.add(
        'Port $port is already in use. '
        'Choose a different port with --port or stop the existing process.',
      );
    }

    try {
      final target = Directory(instanceDir);
      final entityType = FileSystemEntity.typeSync(instanceDir);
      if (entityType != FileSystemEntityType.notFound && entityType != FileSystemEntityType.directory) {
        errors.add('Instance path exists but is not a directory: $instanceDir');
      } else {
        final probeDir = target.existsSync() ? target : _nearestExistingParent(target);
        if (probeDir == null) {
          errors.add('Cannot resolve a writable parent directory for $instanceDir');
        } else {
          final probeName = '.dartclaw_preflight_${DateTime.now().microsecondsSinceEpoch}';
          final testFile = File('${probeDir.path}/$probeName');
          testFile.writeAsStringSync('');
          testFile.deleteSync();
        }
      }
    } catch (e) {
      errors.add('Cannot write to instance directory $instanceDir: $e');
    }

    return SetupPreflight(errors: errors, warnings: warnings);
  }

  static Directory? _nearestExistingParent(Directory dir) {
    var current = dir.absolute;
    while (!current.existsSync()) {
      final parent = current.parent;
      if (parent.path == current.path) {
        return null;
      }
      current = parent;
    }
    return current;
  }

  static String _installHint(String provider) {
    return switch (provider) {
      'codex' => 'See https://github.com/openai/codex',
      _ => 'curl -fsSL https://claude.ai/install.sh | bash',
    };
  }
}
