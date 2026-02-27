import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../deploy_templates/launchdaemon_plist.dart';
import '../deploy_templates/nftables_rules.dart';
import '../deploy_templates/pf_rules.dart';
import '../deploy_templates/systemd_unit.dart';

/// Generates deployment configuration files with secret placeholders.
class ConfigCommand extends Command<void> {
  @override
  String get name => 'config';

  @override
  String get description => 'Generate deployment configuration files';

  ConfigCommand() {
    argParser
      ..addOption('host', defaultsTo: 'localhost', help: 'Host to bind to')
      ..addOption('port', defaultsTo: '3000', help: 'Port to listen on')
      ..addOption('data-dir', help: 'Data directory (default: ~/.dartclaw)')
      ..addOption('user', help: 'OS user to run as (default: current user)')
      ..addOption('bin-path', help: 'Full path to dartclaw binary')
      ..addOption('output-dir', help: 'Output directory for generated files')
      ..addFlag('force', help: 'Overwrite existing files', defaultsTo: false);
  }

  @override
  Future<void> run() async {
    final host = argResults!['host'] as String;
    final port = int.parse(argResults!['port'] as String);
    final dataDir = argResults!['data-dir'] as String? ??
        '${Platform.environment['HOME']}/.dartclaw';
    final user = argResults!['user'] as String? ??
        Platform.environment['USER'] ?? 'dartclaw';
    final binPath = argResults!['bin-path'] as String? ?? 'dartclaw';
    final outputDir = argResults!['output-dir'] as String? ?? dataDir;
    final force = argResults!['force'] as bool;

    final generated = <String>[];

    // Generate service file based on OS
    if (Platform.isMacOS) {
      final plist = generatePlist(
        binPath: binPath, host: host, port: port, dataDir: dataDir, user: user,
      );
      final plistPath = p.join(outputDir, 'com.dartclaw.agent.plist');
      if (_writeFile(plistPath, plist, force)) generated.add(plistPath);
    } else if (Platform.isLinux) {
      final unit = generateUnit(
        binPath: binPath, host: host, port: port, dataDir: dataDir, user: user,
      );
      final unitPath = p.join(outputDir, 'dartclaw.service');
      if (_writeFile(unitPath, unit, force)) generated.add(unitPath);
    }

    // Generate firewall rules
    final firewallDir = p.join(outputDir, 'firewall');
    Directory(firewallDir).createSync(recursive: true);

    final pf = generatePfRules();
    final pfPath = p.join(firewallDir, 'pf.conf');
    if (_writeFile(pfPath, pf, force)) generated.add(pfPath);

    final nft = generateNftablesRules();
    final nftPath = p.join(firewallDir, 'nftables.conf');
    if (_writeFile(nftPath, nft, force)) generated.add(nftPath);

    // Summary
    stdout.writeln();
    stdout.writeln('Generated ${generated.length} file(s):');
    for (final path in generated) {
      stdout.writeln('  $path');
    }
    stdout.writeln();
    stdout.writeln('Next steps:');
    stdout.writeln('  1. Review generated files');
    stdout.writeln('  2. Run: dartclaw deploy secrets');
  }

  bool _writeFile(String path, String content, bool force) {
    final file = File(path);
    if (file.existsSync() && !force) {
      stdout.writeln('  [SKIP] $path (exists, use --force to overwrite)');
      return false;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    stdout.writeln('  [OK] $path');
    return true;
  }
}
