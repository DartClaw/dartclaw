import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;

import '../config_loader.dart';
import 'service_backend.dart';

class _ServiceTarget {
  final String configPath;
  final String instanceDir;
  final int port;
  final String? sourceDir;

  const new({required this.configPath, required this.instanceDir, required this.port, required this.sourceDir});
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
  } catch (_) {} // `which`/`where` not available — fall back to plain 'dartclaw'.
  return 'dartclaw';
}

String? _detectSourceDir() {
  final cwd = Directory.current.path;
  final templates = Directory('$cwd/packages/dartclaw_runtime/lib/src/templates');
  final staticDir = Directory('$cwd/packages/dartclaw_runtime/lib/src/static');
  if (templates.existsSync() && staticDir.existsSync()) {
    return cwd;
  }
  return null;
}

/// Adds `--system` and, for `install`, the `--service-user` run-as override.
void _addScopeOptions(Command<void> command, {bool includeServiceUser = false}) {
  command.argParser.addFlag(
    'system',
    negatable: false,
    help: 'Act on the system-scoped, boot-started service instead of the user-scoped one (requires root)',
  );
  if (includeServiceUser) {
    command.argParser.addOption(
      'service-user',
      help: 'OS user a --system service runs as (default: SUDO_USER)',
      valueHelp: 'name',
    );
  }
}

ServiceScope _scopeOf(Command<void> command) =>
    (command.argResults!['system'] as bool) ? ServiceScope.system : ServiceScope.user;

String _scopeArg(ServiceScope scope) => scope == ServiceScope.system ? ' --system' : '';

/// System scope is only reachable through `sudo`, where most distributions
/// replace `HOME` with root's — so a defaulted or unresolvable instance would
/// name root's instance, not the operator's. Windows is exempt: it has no
/// system scope to reach, and [UnsupportedPlatformBackend] owns that message.
String? _systemScopeInstanceRefusal(
  Command<void> command,
  ServiceScope scope,
  Map<String, String> environment,
  _ServiceTarget target, {
  required bool requireConfig,
}) {
  if (scope == ServiceScope.user || Platform.isWindows) return null;
  final explicit = [
    _optionalArg(command, 'instance-dir'),
    _optionalArg(command, 'config'),
    environment['DARTCLAW_CONFIG'],
  ];
  if (!explicit.any((value) => value != null && value.isNotEmpty)) {
    return 'System scope needs an explicit instance: pass --instance-dir <path> or --config <path>. '
        "Under sudo the default resolves against root's home, not the service user's.";
  }
  if (requireConfig && !File(target.configPath).existsSync()) {
    return 'No DartClaw config at ${target.configPath}. Run `dartclaw init --instance-dir <path>` first, '
        'or point --config at an existing config.';
  }
  return null;
}

/// Reports a system-scope instance refusal; `true` means the command is done.
bool _refusedSystemScopeInstance(
  Command<void> command,
  ServiceScope scope,
  Map<String, String>? env,
  _ServiceTarget target, {
  bool requireConfig = false,
}) {
  final refusal = _systemScopeInstanceRefusal(
    command,
    scope,
    env ?? Platform.environment,
    target,
    requireConfig: requireConfig,
  );
  if (refusal == null) return false;
  stderr.writeln('Error: $refusal');
  exitCode = 1;
  return true;
}

/// The account a system-scoped service runs as; `null` when it cannot be
/// determined, which the backend refuses rather than falling back to root.
String? _resolveServiceUser(Command<void> command, Map<String, String> environment) {
  final explicit = _optionalArg(command, 'service-user');
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final sudoUser = environment['SUDO_USER'];
  return sudoUser == null || sudoUser.isEmpty ? null : sudoUser;
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
  String get description => 'Manage DartClaw as a background service (user-scoped, or --system for a boot daemon)';

  new({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
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
  String get description =>
      'Install DartClaw as a service: user-scoped (LaunchAgent/systemd --user) or --system (LaunchDaemon/systemd)';

  final ServiceBackend? _backendOverride;
  final Map<String, String>? _env;
  final String? Function()? _detectSourceDir;

  new({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    argParser.addOption('bin-path', help: 'Path to the dartclaw binary (default: searches PATH)', valueHelp: 'path');
    _addTargetOptions(this, includeSourceDir: true);
    _addScopeOptions(this, includeServiceUser: true);
  }

  @override
  Future<void> run() async {
    final scope = _scopeOf(this);
    if (scope == ServiceScope.user && (_optionalArg(this, 'service-user') ?? '').isNotEmpty) {
      throw UsageException('--service-user applies to --system installs only.', usage);
    }
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    if (_refusedSystemScopeInstance(this, scope, _env, target, requireConfig: true)) return;
    final backend = _backendOverride ?? createPlatformBackend();
    final binPath = argResults!['bin-path'] as String? ?? await _resolveBinPath();
    final serviceUser = scope == ServiceScope.system ? _resolveServiceUser(this, _env ?? Platform.environment) : null;

    final result = await backend.install(
      binPath: binPath,
      configPath: target.configPath,
      port: target.port,
      instanceDir: target.instanceDir,
      scope: scope,
      sourceDir: target.sourceDir,
      serviceUser: serviceUser,
    );

    if (result.success) {
      stdout.writeln(result.message);
      if (scope == ServiceScope.system) {
        stdout.writeln('Give the run-as user the instance directory: sudo chown -R $serviceUser ${target.instanceDir}');
      }
      stdout.writeln('');
      stdout.writeln(
        'Start now: ${scope == ServiceScope.system ? 'sudo ' : ''}dartclaw service start '
        '--instance-dir ${target.instanceDir}${_scopeArg(scope)}',
      );
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
  String get description => 'Remove the installed service unit';

  final ServiceBackend? _backendOverride;
  final Map<String, String>? _env;
  final String? Function()? _detectSourceDir;

  new({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    _addTargetOptions(this);
    _addScopeOptions(this);
  }

  @override
  Future<void> run() async {
    final scope = _scopeOf(this);
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    if (_refusedSystemScopeInstance(this, scope, _env, target)) return;
    final backend = _backendOverride ?? createPlatformBackend();
    final result = await backend.uninstall(instanceDir: target.instanceDir, scope: scope);

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

  new({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    _addTargetOptions(this);
    _addScopeOptions(this);
  }

  @override
  Future<void> run() async {
    final scope = _scopeOf(this);
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    if (_refusedSystemScopeInstance(this, scope, _env, target)) return;
    final backend = _backendOverride ?? createPlatformBackend();
    final status = await backend.status(instanceDir: target.instanceDir, scope: scope);
    stdout.writeln('DartClaw service (${target.instanceDir}): ${status.label}');
    if (status == ServiceStatus.notInstalled) {
      stdout.writeln('');
      stdout.writeln('Install: dartclaw service install --instance-dir ${target.instanceDir}${_scopeArg(scope)}');
    }
    if (status == ServiceStatus.unknown && scope == ServiceScope.system) {
      stdout.writeln('');
      stdout.writeln(
        'System-scoped status requires root. If you are not root, re-run: '
        'sudo dartclaw service status --system',
      );
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

  new({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    _addTargetOptions(this);
    _addScopeOptions(this);
  }

  @override
  Future<void> run() async {
    final scope = _scopeOf(this);
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    if (_refusedSystemScopeInstance(this, scope, _env, target)) return;
    final backend = _backendOverride ?? createPlatformBackend();
    final result = await backend.start(instanceDir: target.instanceDir, scope: scope);

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

  new({ServiceBackend? backend, Map<String, String>? env, String? Function()? detectSourceDir})
    : _backendOverride = backend,
      _env = env,
      _detectSourceDir = detectSourceDir {
    _addTargetOptions(this);
    _addScopeOptions(this);
  }

  @override
  Future<void> run() async {
    final scope = _scopeOf(this);
    final target = await _resolveTarget(this, env: _env, detectSourceDir: _detectSourceDir);
    if (_refusedSystemScopeInstance(this, scope, _env, target)) return;
    final backend = _backendOverride ?? createPlatformBackend();
    final result = await backend.stop(instanceDir: target.instanceDir, scope: scope);

    if (result.success) {
      stdout.writeln(result.message);
    } else {
      stderr.writeln('Error: ${result.message}');
      exitCode = 1;
    }
  }
}
