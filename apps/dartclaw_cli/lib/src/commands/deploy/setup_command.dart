import 'dart:io';

import 'package:args/command_runner.dart';

/// Signature matching [Process.run] for dependency injection in deploy commands.
typedef RunProcess = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Deprecated: prerequisite check now integrated into `dartclaw init`.
///
/// Running `dartclaw deploy setup` redirects users to `dartclaw init` and
/// performs a best-effort Docker/OS check for users who relied on the old flow.
class SetupCommand extends Command<void> {
  final RunProcess _run;

  @override
  String get name => 'setup';

  @override
  String get description =>
      '[Deprecated] Validate deployment prerequisites — use "dartclaw init" instead';

  SetupCommand({RunProcess? run}) : _run = run ?? Process.run;

  @override
  Future<void> run() async {
    stderr.writeln(
      'DEPRECATED: "dartclaw deploy setup" is deprecated. '
      'Run "dartclaw init" to set up your instance — it includes all preflight checks.',
    );

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
      _warn('Data directory does not exist: $dataDir (will be created by dartclaw init)');
    }

    stdout.writeln('');
    if (allPassed) {
      stdout.writeln('All checks passed. Run: dartclaw init to complete setup.');
    } else {
      stdout.writeln('Some checks failed. Fix the issues above, then run: dartclaw init');
    }
  }

  void _pass(String msg) => stdout.writeln('  [PASS] $msg');
  void _fail(String msg) => stdout.writeln('  [FAIL] $msg');
  void _warn(String msg) => stdout.writeln('  [WARN] $msg');
  void _hint(String msg) => stdout.writeln('         $msg');
}
