import 'dart:io';

import 'package:args/command_runner.dart';

/// Signature matching [Process.run] for dependency injection in deploy commands.
typedef RunProcess = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Validates deployment prerequisites.
class SetupCommand extends Command<void> {
  final RunProcess _run;

  @override
  String get name => 'setup';

  @override
  String get description => 'Validate deployment prerequisites';

  SetupCommand({RunProcess? run}) : _run = run ?? Process.run;

  @override
  Future<void> run() async {
    stdout.writeln('DartClaw Deployment Setup Check');
    stdout.writeln('=' * 40);

    var allPassed = true;

    // OS check
    if (Platform.isMacOS) {
      _pass('OS: macOS');
    } else if (Platform.isLinux) {
      _pass('OS: Linux');
    } else {
      _fail('OS: ${Platform.operatingSystem} (macOS or Linux required)');
      allPassed = false;
    }

    // Docker check
    try {
      final result = await _run('docker', ['version']);
      if (result.exitCode == 0) {
        _pass('Docker installed and running');
      } else {
        _fail('Docker not running');
        _hint('Start Docker Desktop or install: https://docs.docker.com/get-docker/');
        allPassed = false;
      }
    } catch (e) {
      _fail('Docker not found');
      _hint('Install Docker: https://docs.docker.com/get-docker/');
      allPassed = false;
    }

    // dartclaw binary check
    try {
      final result = await _run('dartclaw', ['--help']);
      if (result.exitCode == 0) {
        _pass('dartclaw binary in PATH');
      } else {
        _warn('dartclaw binary returned non-zero');
      }
    } catch (e) {
      _warn('dartclaw binary not in PATH (will use full path)');
    }

    // Data directory
    final dataDir = Platform.environment['DARTCLAW_DATA_DIR'] ?? '${Platform.environment['HOME']}/.dartclaw';
    final dir = Directory(dataDir);
    if (dir.existsSync()) {
      _pass('Data directory exists: $dataDir');
    } else {
      _warn('Data directory does not exist: $dataDir (will be created)');
    }

    stdout.writeln();
    if (allPassed) {
      stdout.writeln('All checks passed. Run: dartclaw deploy config');
    } else {
      stdout.writeln('Some checks failed. Fix the issues above and re-run.');
    }
  }

  void _pass(String msg) => stdout.writeln('  [PASS] $msg');
  void _fail(String msg) => stdout.writeln('  [FAIL] $msg');
  void _warn(String msg) => stdout.writeln('  [WARN] $msg');
  void _hint(String msg) => stdout.writeln('         $msg');
}
