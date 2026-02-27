import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'setup_command.dart' show RunProcess;

/// Injects secrets into generated config files, starts the service,
/// and verifies health.
class SecretsCommand extends Command<void> {
  final RunProcess _run;

  @override
  String get name => 'secrets';

  @override
  String get description => 'Inject secrets and start the service';

  SecretsCommand({RunProcess? run}) : _run = run ?? Process.run {
    argParser
      ..addOption('api-key', help: 'Anthropic API key (or set ANTHROPIC_API_KEY env)')
      ..addOption('data-dir', help: 'Data directory (default: ~/.dartclaw)')
      ..addOption('host', defaultsTo: 'localhost', help: 'Host for health check')
      ..addOption('port', defaultsTo: '3000', help: 'Port for health check');
  }

  @override
  Future<void> run() async {
    final apiKey = argResults!['api-key'] as String? ?? Platform.environment['ANTHROPIC_API_KEY'] ?? '';
    final dataDir = argResults!['data-dir'] as String? ?? '${Platform.environment['HOME']}/.dartclaw';
    final host = argResults!['host'] as String;
    final port = argResults!['port'] as String;

    if (apiKey.isEmpty) {
      stderr.writeln('Error: No API key provided.');
      stderr.writeln('  Use --api-key=<key> or set ANTHROPIC_API_KEY environment variable.');
      exitCode = 1;
      return;
    }

    stdout.writeln('Injecting secrets...');

    // Replace placeholders in all files in the output directory
    final dir = Directory(dataDir);
    if (!dir.existsSync()) {
      stderr.writeln('Error: Data directory not found: $dataDir');
      stderr.writeln('  Run: dartclaw deploy config first');
      exitCode = 1;
      return;
    }

    var replaced = 0;
    for (final file in _findConfigFiles(dataDir)) {
      final content = file.readAsStringSync();
      if (content.contains('__ANTHROPIC_API_KEY__')) {
        final updated = content.replaceAll('__ANTHROPIC_API_KEY__', apiKey);
        file.writeAsStringSync(updated);
        // Set restrictive permissions
        await _run('chmod', ['600', file.path]);
        stdout.writeln('  [OK] ${file.path}');
        replaced++;
      }
    }

    if (replaced == 0) {
      stdout.writeln('  No files with placeholders found.');
    }

    // Start service
    stdout.writeln();
    stdout.writeln('Starting service...');
    if (Platform.isMacOS) {
      final plistPath = p.join(dataDir, 'com.dartclaw.agent.plist');
      if (File(plistPath).existsSync()) {
        final result = await _run('launchctl', ['load', plistPath]);
        if (result.exitCode == 0) {
          stdout.writeln('  [OK] LaunchDaemon loaded');
        } else {
          stderr.writeln('  [FAIL] launchctl load: ${result.stderr}');
        }
      }
    } else if (Platform.isLinux) {
      final unitPath = p.join(dataDir, 'dartclaw.service');
      if (File(unitPath).existsSync()) {
        await _run('systemctl', ['--user', 'daemon-reload']);
        final result = await _run('systemctl', ['--user', 'start', 'dartclaw']);
        if (result.exitCode == 0) {
          stdout.writeln('  [OK] systemd service started');
        } else {
          stderr.writeln('  [FAIL] systemctl start: ${result.stderr}');
        }
      }
    }

    // Health check
    stdout.writeln();
    stdout.writeln('Verifying health...');
    final healthy = await _healthCheck(host, int.parse(port));
    if (healthy) {
      stdout.writeln('  [OK] Service is healthy');
      stdout.writeln();
      stdout.writeln('DartClaw is running at http://$host:$port');
    } else {
      stderr.writeln('  [FAIL] Health check failed after 5 retries');
      stderr.writeln('  Check logs: $dataDir/logs/dartclaw.log');
    }
  }

  List<File> _findConfigFiles(String dir) {
    const extensions = {'.plist', '.service', '.yaml', '.conf'};
    return Directory(
      dir,
    ).listSync(recursive: true).whereType<File>().where((f) => extensions.any((ext) => f.path.endsWith(ext))).toList();
  }

  Future<bool> _healthCheck(String host, int port) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 2);

    for (var i = 0; i < 5; i++) {
      try {
        final request = await client.getUrl(Uri.parse('http://$host:$port/health'));
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode == 200) {
          client.close();
          return true;
        }
      } catch (_) {
        // Retry
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    client.close();
    return false;
  }
}
