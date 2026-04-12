import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show expandHome;
import 'package:path/path.dart' as p;

import '../config_loader.dart';
import 'service_backend.dart';

class _ServiceTarget {
  final String configPath;
  final String instanceDir;
  final int port;
  final String? sourceDir;

  const _ServiceTarget({
    required this.configPath,
    required this.instanceDir,
    required this.port,
    required this.sourceDir,
  });
}

Future<_ServiceTarget> _resolveTarget(
  Command<void> command, {
  Map<String, String>? env,
  String? Function()? detectSourceDir,
}) async {
  final environment = env ?? Platform.environment;
  final explicitConfig = _optionalArg(command, 'config');
  final explicitInstanceDir = _optionalArg(command, 'instance-dir');
  final explicitSourceDir = _optionalArg(command, 'source-dir');
  final explicitEnvConfig = environment['DARTCLAW_CONFIG'];
  var instanceDir = explicitInstanceDir != null && explicitInstanceDir.isNotEmpty
      ? expandHome(explicitInstanceDir, env: environment)
      : defaultInstanceDir(env: environment);
  var configPath = explicitConfig != null && explicitConfig.isNotEmpty
      ? resolveCliConfigPath(configPath: explicitConfig, env: environment)
      : explicitInstanceDir != null && explicitInstanceDir.isNotEmpty
      ? p.join(instanceDir, 'dartclaw.yaml')
      : resolveCliConfigPath(configPath: null, env: environment);
  var port = 3333;

  if (File(configPath).existsSync()) {
    final config = loadCliConfig(configPath: configPath, env: environment);
    instanceDir = explicitInstanceDir ?? config.server.dataDir;
    port = config.server.port;
    if ((explicitConfig == null || explicitConfig.isEmpty) &&
        (explicitEnvConfig == null || explicitEnvConfig.isEmpty)) {
      configPath = p.join(instanceDir, 'dartclaw.yaml');
    }
  }

  return _ServiceTarget(
    configPath: configPath,
    instanceDir: instanceDir,
    port: port,
    sourceDir: explicitSourceDir ?? (detectSourceDir ?? _detectSourceDir)(),
  );
}

String? _optionalArg(Command<void> command, String name) {
  try {
    return command.argResults![name] as String?;
  } on ArgumentError {
    return null;
  }
}

Future<String> _resolveBinPath() async {
  final candidates = Platform.isWindows ? ['where', 'dartclaw'] : ['which', 'dartclaw'];
  try {
    final result = await Process.run(candidates.first, [candidates.last]);
    if (result.exitCode == 0) {
      final resolved = result.stdout.toString().trim();
      if (resolved.isNotEmpty) {
        return resolved.split('\n').first.trim();
      }
    }
  } catch (_) {}
  return 'dartclaw';
}

String? _detectSourceDir() {
  final cwd = Directory.current.path;
  final templates = Directory('$cwd/packages/dartclaw_server/lib/src/templates');
  final staticDir = Directory('$cwd/packages/dartclaw_server/lib/src/static');
  if (templates.existsSync() && staticDir.existsSync()) {
    return cwd;
  }
  return null;
}

void _addTargetOptions(Command<void> command, {bool includeSourceDir = false}) {
  command.argParser
    ..addOption('config', help: 'Path to dartclaw.yaml (default: resolved discovery path)', valueHelp: 'path')
    ..addOption(
      'instance-dir',
      help: 'Instance directory (default: resolved from config or DARTCLAW_HOME)',
      valueHelp: 'path',
    );

  if (includeSourceDir) {
    command.argParser.addOption(
      'source-dir',
      help: 'Source tree root for resolving static/templates when running from source',
      valueHelp: 'path',
    );
  }
}

/// Parent command: `dartclaw service`.
class ServiceCommand extends Command<void> {
  final Map<String, String>? _env;
  final String? Function()? _detectSourceDir;

  @override
  String get name => 'service';

  @override
  String get description => 'Manage DartClaw as a user-scoped background service';

  ServiceCommand({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _env = env,
      _detectSourceDir = detectSourceDir {
    addSubcommand(ServiceInstallCommand(backend: backend, env: _env, detectSourceDir: _detectSourceDir));
    addSubcommand(ServiceUninstallCommand(backend: backend, env: _env, detectSourceDir: _detectSourceDir));
    addSubcommand(ServiceStatusCommand(backend: backend, env: _env, detectSourceDir: _detectSourceDir));
    addSubcommand(ServiceStartCommand(backend: backend, env: _env, detectSourceDir: _detectSourceDir));
    addSubcommand(ServiceStopCommand(backend: backend, env: _env, detectSourceDir: _detectSourceDir));
  }

  @override
  Future<void> run() async {
    printUsage();
  }
}

class ServiceInstallCommand extends Command<void> {
  @override
  String get name => 'install';

  @override
  String get description => 'Install DartClaw as a user-scoped service (LaunchAgent/systemd --user)';

  final ServiceBackend? _backendOverride;
  final Map<String, String>? _env;
  final String? Function()? _detectSourceDir;

  ServiceInstallCommand({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    argParser.addOption('bin-path', help: 'Path to the dartclaw binary (default: searches PATH)', valueHelp: 'path');
    _addTargetOptions(this, includeSourceDir: true);
  }

  @override
  Future<void> run() async {
    final backend = _backendOverride ?? createPlatformBackend();
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    final binPath = argResults!['bin-path'] as String? ?? await _resolveBinPath();

    final result = await backend.install(
      binPath: binPath,
      configPath: target.configPath,
      port: target.port,
      instanceDir: target.instanceDir,
      sourceDir: target.sourceDir,
    );

    if (result.success) {
      stdout.writeln(result.message);
      stdout.writeln('');
      stdout.writeln('Start now: dartclaw service start --instance-dir ${target.instanceDir}');
    } else {
      stderr.writeln('Error: ${result.message}');
      exitCode = 1;
    }
  }
}

class ServiceUninstallCommand extends Command<void> {
  @override
  String get name => 'uninstall';

  @override
  String get description => 'Remove the user-scoped service unit';

  final ServiceBackend? _backendOverride;
  final Map<String, String>? _env;
  final String? Function()? _detectSourceDir;

  ServiceUninstallCommand({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    _addTargetOptions(this);
  }

  @override
  Future<void> run() async {
    final backend = _backendOverride ?? createPlatformBackend();
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    final result = await backend.uninstall(instanceDir: target.instanceDir);

    if (result.success) {
      stdout.writeln(result.message);
    } else {
      stderr.writeln('Error: ${result.message}');
      exitCode = 1;
    }
  }
}

class ServiceStatusCommand extends Command<void> {
  @override
  String get name => 'status';

  @override
  String get description => 'Show the current service status';

  final ServiceBackend? _backendOverride;
  final Map<String, String>? _env;
  final String? Function()? _detectSourceDir;

  ServiceStatusCommand({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    _addTargetOptions(this);
  }

  @override
  Future<void> run() async {
    final backend = _backendOverride ?? createPlatformBackend();
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    final status = await backend.status(instanceDir: target.instanceDir);
    stdout.writeln('DartClaw service (${target.instanceDir}): ${status.label}');
    if (status == ServiceStatus.notInstalled) {
      stdout.writeln('');
      stdout.writeln('Install: dartclaw service install --instance-dir ${target.instanceDir}');
    }
  }
}

class ServiceStartCommand extends Command<void> {
  @override
  String get name => 'start';

  @override
  String get description => 'Start the installed service in the background';

  final ServiceBackend? _backendOverride;
  final Map<String, String>? _env;
  final String? Function()? _detectSourceDir;

  ServiceStartCommand({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    _addTargetOptions(this);
  }

  @override
  Future<void> run() async {
    final backend = _backendOverride ?? createPlatformBackend();
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    final result = await backend.start(instanceDir: target.instanceDir);

    if (result.success) {
      stdout.writeln(result.message);
    } else {
      stderr.writeln('Error: ${result.message}');
      exitCode = 1;
    }
  }
}

class ServiceStopCommand extends Command<void> {
  @override
  String get name => 'stop';

  @override
  String get description => 'Stop the running service';

  final ServiceBackend? _backendOverride;
  final Map<String, String>? _env;
  final String? Function()? _detectSourceDir;

  ServiceStopCommand({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    _addTargetOptions(this);
  }

  @override
  Future<void> run() async {
    final backend = _backendOverride ?? createPlatformBackend();
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    final result = await backend.stop(instanceDir: target.instanceDir);

    if (result.success) {
      stdout.writeln(result.message);
    } else {
      stderr.writeln('Error: ${result.message}');
      exitCode = 1;
    }
  }
}
