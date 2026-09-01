import 'dart:io';

part 'unsupported_service_backend.dart';
part 'macos_launchd_backend_support.dart';

/// Result of a service operation.
class ServiceResult {
  final bool success;
  final String message;

  const new({required this.success, required this.message});
}

/// Installation scope of a managed DartClaw service.
///
/// [user] installs into the invoking user's own login session (LaunchAgent,
/// `systemd --user`). [system] installs a boot-started daemon owned by root
/// that still runs the process as a named human operator.
enum ServiceScope { user, system }

/// Abstraction over platform-specific service management.
abstract class ServiceBackend {
  /// Writes and loads the service definition for [scope].
  ///
  /// [serviceUser] names the account a [ServiceScope.system] service runs as
  /// and is required for that scope; it is ignored for [ServiceScope.user].
  /// System scope fails without root privileges before touching the filesystem.
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    required ServiceScope scope,
    String? sourceDir,
    String? serviceUser,
  });

  Future<ServiceResult> uninstall({required String instanceDir, required ServiceScope scope});

  Future<ServiceStatus> status({required String instanceDir, required ServiceScope scope});

  Future<ServiceResult> start({required String instanceDir, required ServiceScope scope});

  Future<ServiceResult> stop({required String instanceDir, required ServiceScope scope});
}

/// Current service state.
enum ServiceStatus {
  running,
  stopped,
  notInstalled,
  unknown;

  String get label => switch (this) {
    ServiceStatus.running => 'running',
    ServiceStatus.stopped => 'stopped',
    ServiceStatus.notInstalled => 'not installed',
    ServiceStatus.unknown => 'unknown',
  };
}

/// Signature matching [Process.run], injected so tests can fake `launchctl`,
/// `systemctl` and `id` without touching the host.
typedef RunProcess = Future<ProcessResult> Function(String, List<String>);

String _instanceSuffix(String instanceDir) {
  var hash = 0x811c9dc5;
  for (final codeUnit in instanceDir.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String _quotedStderr(ProcessResult result) {
  final stderrText = result.stderr.toString().trim();
  return stderrText.isEmpty ? 'unknown error' : stderrText;
}

Future<String> _effectiveUid(RunProcess run) async => (await run('id', ['-u'])).stdout.toString().trim();

/// Whether the caller may act on [scope]; system scope needs effective uid 0.
Future<bool> _mayManage(ServiceScope scope, RunProcess run) async =>
    scope == ServiceScope.user || await _effectiveUid(run) == '0';

/// Refuses a [ServiceScope.system] operation that is not running as root.
///
/// Returns `null` when the operation may proceed. Callers must consult it
/// before creating directories or writing unit files.
Future<ServiceResult?> _refuseUnprivilegedSystemScope(ServiceScope scope, String operation, RunProcess run) async {
  if (await _mayManage(scope, run)) return null;
  return ServiceResult(
    success: false,
    message:
        'System-scoped service management requires root privileges (effective uid 0). '
        'Re-run with sudo: sudo dartclaw service $operation --system',
  );
}

const _missingServiceUser = ServiceResult(
  success: false,
  message:
      'Cannot determine which user the system service should run as. '
      'Re-run with sudo so SUDO_USER is set, or pass --service-user <name>.',
);

/// Refuses a system-scope install whose run-as user is absent or names no
/// account. Falling through to root is the security regression this guards.
Future<ServiceResult?> _refuseUnusableServiceUser(ServiceScope scope, String? serviceUser, RunProcess run) async {
  if (scope == ServiceScope.user) return null;
  if (serviceUser == null || serviceUser.isEmpty) return _missingServiceUser;
  if ((await run('id', ['-u', serviceUser])).exitCode == 0) return null;
  return ServiceResult(
    success: false,
    message: 'No account named "$serviceUser" on this host. Pass --service-user <name> naming an existing user.',
  );
}

class MacOSLaunchdBackend implements ServiceBackend {
  final RunProcess _run;
  final String _home;
  final String _systemRoot;
  final String _path;

  new({RunProcess? run, String? home, String? systemRoot, Map<String, String>? environment})
    : _run = run ?? Process.run,
      _home = home ?? Platform.environment['HOME'] ?? '.',
      _systemRoot = systemRoot ?? '',
      _path = _servicePath(environment ?? Platform.environment);

  String _definitionDir(ServiceScope scope) => switch (scope) {
    ServiceScope.user => '$_home/Library/LaunchAgents',
    ServiceScope.system => '$_systemRoot/Library/LaunchDaemons',
  };

  String _kind(ServiceScope scope) => scope == ServiceScope.system ? 'LaunchDaemon' : 'LaunchAgent';

  String _labelFor(String instanceDir) => 'com.dartclaw.agent.${_instanceSuffix(instanceDir)}';

  String _plistPathFor(ServiceScope scope, String instanceDir) =>
      '${_definitionDir(scope)}/${_labelFor(instanceDir)}.plist';

  Future<String> _domain(ServiceScope scope) async =>
      scope == ServiceScope.system ? 'system' : 'gui/${await _effectiveUid(_run)}';

  @override
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    required ServiceScope scope,
    String? sourceDir,
    String? serviceUser,
  }) async {
    final refusal = await _refuseUnprivilegedSystemScope(scope, 'install', _run);
    if (refusal != null) return refusal;
    final unusableUser = await _refuseUnusableServiceUser(scope, serviceUser, _run);
    if (unusableUser != null) return unusableUser;

    final definition = File(_plistPathFor(scope, instanceDir));
    final previous = definition.existsSync() ? definition.readAsStringSync() : null;
    final label = _labelFor(instanceDir);
    final domain = await _domain(scope);
    final content = _plistContent(
      scope: scope,
      label: label,
      binPath: binPath,
      configPath: configPath,
      instanceDir: instanceDir,
      sourceDir: sourceDir,
      serviceUser: serviceUser,
    );

    Directory(_definitionDir(scope)).createSync(recursive: true);
    Directory('$instanceDir/logs').createSync(recursive: true);

    if (previous != null) {
      final bootoutError = await _bootoutLoaded(domain: domain, label: label);
      if (bootoutError != null) {
        return ServiceResult(success: false, message: 'launchctl bootout failed: $bootoutError');
      }
    }

    definition.writeAsStringSync(content);
    final bootstrap = await _run('launchctl', ['bootstrap', domain, definition.path]);
    if (bootstrap.exitCode == 0) {
      return ServiceResult(
        success: true,
        message: previous == null
            ? '${_kind(scope)} installed and loaded.'
            : '${_kind(scope)} definition refreshed and loaded.',
      );
    }

    final failure = _quotedStderr(bootstrap);
    if (previous == null) {
      return ServiceResult(success: false, message: 'launchctl bootstrap failed: $failure');
    }

    definition.writeAsStringSync(previous);
    final restore = await _run('launchctl', ['bootstrap', domain, definition.path]);
    return ServiceResult(
      success: false,
      message: restore.exitCode == 0
          ? 'launchctl bootstrap failed: $failure; previous ${_kind(scope)} restored'
          : 'launchctl bootstrap failed: $failure; restoring the previous ${_kind(scope)} also failed: '
                '${_quotedStderr(restore)}',
    );
  }

  @override
  Future<ServiceResult> uninstall({required String instanceDir, required ServiceScope scope}) async {
    final refusal = await _refuseUnprivilegedSystemScope(scope, 'uninstall', _run);
    if (refusal != null) return refusal;

    final definition = File(_plistPathFor(scope, instanceDir));
    if (!definition.existsSync()) {
      return ServiceResult(success: true, message: '${_kind(scope)} not installed.');
    }

    final error = await _bootoutLoaded(domain: await _domain(scope), label: _labelFor(instanceDir));
    if (error != null) {
      return ServiceResult(success: false, message: 'launchctl bootout failed: $error');
    }

    definition.deleteSync();
    return ServiceResult(success: true, message: '${_kind(scope)} removed.');
  }

  @override
  Future<ServiceStatus> status({required String instanceDir, required ServiceScope scope}) async {
    if (!await _mayManage(scope, _run)) {
      return ServiceStatus.unknown;
    }
    if (!File(_plistPathFor(scope, instanceDir)).existsSync()) {
      return ServiceStatus.notInstalled;
    }

    final result = await _run('launchctl', ['print', '${await _domain(scope)}/${_labelFor(instanceDir)}']);
    if (result.exitCode != 0) {
      return ServiceStatus.stopped;
    }
    return result.stdout.toString().contains('state = running') ? ServiceStatus.running : ServiceStatus.stopped;
  }

  @override
  Future<ServiceResult> start({required String instanceDir, required ServiceScope scope}) async {
    final refusal = await _refuseUnprivilegedSystemScope(scope, 'start', _run);
    if (refusal != null) return refusal;

    if (!File(_plistPathFor(scope, instanceDir)).existsSync()) {
      return ServiceResult(
        success: false,
        message: '${_kind(scope)} not installed. Run: ${_installHint(scope, instanceDir)}',
      );
    }

    final result = await _run('launchctl', ['kickstart', '${await _domain(scope)}/${_labelFor(instanceDir)}']);
    if (result.exitCode == 0) {
      return ServiceResult(success: true, message: '${_kind(scope)} started.');
    }
    return ServiceResult(success: false, message: 'launchctl kickstart failed: ${_quotedStderr(result)}');
  }

  @override
  Future<ServiceResult> stop({required String instanceDir, required ServiceScope scope}) async {
    final refusal = await _refuseUnprivilegedSystemScope(scope, 'stop', _run);
    if (refusal != null) return refusal;

    final result = await _run('launchctl', ['kill', 'TERM', '${await _domain(scope)}/${_labelFor(instanceDir)}']);
    if (result.exitCode == 0) {
      return ServiceResult(success: true, message: '${_kind(scope)} stopped.');
    }
    return ServiceResult(success: false, message: 'launchctl kill failed: ${_quotedStderr(result)}');
  }
}

String _installHint(ServiceScope scope, String instanceDir) => scope == ServiceScope.system
    ? 'sudo dartclaw service install --system --instance-dir $instanceDir'
    : 'dartclaw service install';

String _servicePath(Map<String, String> environment) {
  final entries = (environment['PATH'] ?? '')
      .split(':')
      .where((entry) => entry.startsWith('/'))
      .toList(growable: false);
  return entries.isEmpty ? '/usr/bin:/bin:/usr/sbin:/sbin' : entries.join(':');
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

class LinuxSystemdBackend implements ServiceBackend {
  final RunProcess _run;
  final String _home;
  final String _systemRoot;

  new({RunProcess? run, String? home, String? systemRoot})
    : _run = run ?? Process.run,
      _home = home ?? Platform.environment['HOME'] ?? '.',
      _systemRoot = systemRoot ?? '';

  String _unitDir(ServiceScope scope) => switch (scope) {
    ServiceScope.user => '$_home/.config/systemd/user',
    ServiceScope.system => '$_systemRoot/etc/systemd/system',
  };

  /// `--user ` for user scope, empty for system scope — both as a `systemctl`
  /// argument prefix and as the prefix quoted back in failure messages.
  String _scopeFlag(ServiceScope scope) => scope == ServiceScope.user ? '--user ' : '';

  List<String> _systemctlArgs(ServiceScope scope, List<String> args) =>
      scope == ServiceScope.user ? ['--user', ...args] : args;

  String _serviceNameFor(String instanceDir) => 'dartclaw-${_instanceSuffix(instanceDir)}';

  String _unitPathFor(ServiceScope scope, String instanceDir) =>
      '${_unitDir(scope)}/${_serviceNameFor(instanceDir)}.service';

  @override
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    required ServiceScope scope,
    String? sourceDir,
    String? serviceUser,
  }) async {
    final refusal = await _refuseUnprivilegedSystemScope(scope, 'install', _run);
    if (refusal != null) return refusal;
    final unusableUser = await _refuseUnusableServiceUser(scope, serviceUser, _run);
    if (unusableUser != null) return unusableUser;

    final serviceName = _serviceNameFor(instanceDir);
    final unit = File(_unitPathFor(scope, instanceDir));
    final scopeFlag = _scopeFlag(scope);
    Directory(_unitDir(scope)).createSync(recursive: true);
    Directory('$instanceDir/logs').createSync(recursive: true);
    unit.writeAsStringSync(
      _unitContent(
        scope: scope,
        serviceName: serviceName,
        binPath: binPath,
        configPath: configPath,
        instanceDir: instanceDir,
        sourceDir: sourceDir,
        serviceUser: serviceUser,
      ),
    );

    final daemonReload = await _run('systemctl', _systemctlArgs(scope, ['daemon-reload']));
    if (daemonReload.exitCode != 0) {
      unit.deleteSync();
      return ServiceResult(
        success: false,
        message: 'systemctl ${scopeFlag}daemon-reload failed: ${_quotedStderr(daemonReload)}',
      );
    }

    final enable = await _run('systemctl', _systemctlArgs(scope, ['enable', serviceName]));
    if (enable.exitCode != 0) {
      unit.deleteSync();
      await _run('systemctl', _systemctlArgs(scope, ['daemon-reload']));
      return ServiceResult(success: false, message: 'systemctl ${scopeFlag}enable failed: ${_quotedStderr(enable)}');
    }

    return ServiceResult(
      success: true,
      message: scope == ServiceScope.system
          ? 'systemd system unit installed and enabled.'
          : 'systemd user unit installed and enabled.',
    );
  }

  @override
  Future<ServiceResult> uninstall({required String instanceDir, required ServiceScope scope}) async {
    final refusal = await _refuseUnprivilegedSystemScope(scope, 'uninstall', _run);
    if (refusal != null) return refusal;

    final unit = File(_unitPathFor(scope, instanceDir));
    final serviceName = _serviceNameFor(instanceDir);
    final scopeFlag = _scopeFlag(scope);
    if (!unit.existsSync()) {
      return const ServiceResult(success: true, message: 'systemd unit not installed.');
    }

    final disable = await _run('systemctl', _systemctlArgs(scope, ['disable', '--now', serviceName]));
    if (disable.exitCode != 0) {
      return ServiceResult(
        success: false,
        message: 'systemctl ${scopeFlag}disable --now failed: ${_quotedStderr(disable)}',
      );
    }

    unit.deleteSync();
    final daemonReload = await _run('systemctl', _systemctlArgs(scope, ['daemon-reload']));
    if (daemonReload.exitCode != 0) {
      return ServiceResult(
        success: false,
        message: 'systemctl ${scopeFlag}daemon-reload failed: ${_quotedStderr(daemonReload)}',
      );
    }
    return ServiceResult(
      success: true,
      message: scope == ServiceScope.system ? 'systemd system unit removed.' : 'systemd user unit removed.',
    );
  }

  @override
  Future<ServiceStatus> status({required String instanceDir, required ServiceScope scope}) async {
    if (!await _mayManage(scope, _run)) {
      return ServiceStatus.unknown;
    }
    if (!File(_unitPathFor(scope, instanceDir)).existsSync()) {
      return ServiceStatus.notInstalled;
    }

    final result = await _run('systemctl', _systemctlArgs(scope, ['is-active', _serviceNameFor(instanceDir)]));
    final out = result.stdout.toString().trim();
    if (out == 'active') {
      return ServiceStatus.running;
    }
    if (result.exitCode == 3 || out == 'inactive' || out == 'dead') {
      return ServiceStatus.stopped;
    }
    return ServiceStatus.unknown;
  }

  @override
  Future<ServiceResult> start({required String instanceDir, required ServiceScope scope}) async {
    final refusal = await _refuseUnprivilegedSystemScope(scope, 'start', _run);
    if (refusal != null) return refusal;

    final serviceName = _serviceNameFor(instanceDir);
    if (!File(_unitPathFor(scope, instanceDir)).existsSync()) {
      return ServiceResult(
        success: false,
        message: 'systemd unit not installed. Run: ${_installHint(scope, instanceDir)}',
      );
    }

    final result = await _run('systemctl', _systemctlArgs(scope, ['start', serviceName]));
    if (result.exitCode == 0) {
      return const ServiceResult(success: true, message: 'systemd service started.');
    }
    return ServiceResult(success: false, message: 'systemctl start failed: ${_quotedStderr(result)}');
  }

  @override
  Future<ServiceResult> stop({required String instanceDir, required ServiceScope scope}) async {
    final refusal = await _refuseUnprivilegedSystemScope(scope, 'stop', _run);
    if (refusal != null) return refusal;

    final result = await _run('systemctl', _systemctlArgs(scope, ['stop', _serviceNameFor(instanceDir)]));
    if (result.exitCode == 0) {
      return const ServiceResult(success: true, message: 'systemd service stopped.');
    }
    return ServiceResult(success: false, message: 'systemctl stop failed: ${_quotedStderr(result)}');
  }

  String _unitContent({
    required ServiceScope scope,
    required String serviceName,
    required String binPath,
    required String configPath,
    required String instanceDir,
    String? sourceDir,
    String? serviceUser,
  }) {
    final sourceDirArg = sourceDir == null ? '' : ' --source-dir $sourceDir';
    final runAs = scope == ServiceScope.system ? 'User=$serviceUser\n' : '';
    final execStart = 'ExecStart=$binPath serve --config $configPath$sourceDirArg';
    final hardening = scope == ServiceScope.system
        ? 'ProtectSystem=strict\nProtectHome=read-only\nReadWritePaths=$instanceDir\nPrivateTmp=true\n'
        : '';
    final target = scope == ServiceScope.system ? 'multi-user.target' : 'default.target';
    // System scope matches macOS `KeepAlive` and the retired root template:
    // a boot daemon comes back from a clean exit too.
    final restart = scope == ServiceScope.system ? 'always' : 'on-failure';
    return '''[Unit]
Description=DartClaw Agent Runtime ($serviceName)
After=network.target

[Service]
Type=simple
$runAs$execStart
WorkingDirectory=$instanceDir
Restart=$restart
RestartSec=5
StandardOutput=append:$instanceDir/logs/dartclaw.log
StandardError=append:$instanceDir/logs/dartclaw.err.log
NoNewPrivileges=true
$hardening
[Install]
WantedBy=$target
''';
  }
}

ServiceBackend createPlatformBackend({RunProcess? run, String? home}) {
  if (Platform.isMacOS) {
    return MacOSLaunchdBackend(run: run, home: home);
  }
  if (Platform.isLinux) {
    return LinuxSystemdBackend(run: run, home: home);
  }
  return UnsupportedPlatformBackend();
}
