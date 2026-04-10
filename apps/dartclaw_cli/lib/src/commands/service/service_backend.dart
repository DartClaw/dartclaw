import 'dart:io';

/// Result of a service operation.
class ServiceResult {
  final bool success;
  final String message;

  const ServiceResult({required this.success, required this.message});
}

/// Abstraction over platform-specific user-scoped service management.
abstract class ServiceBackend {
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    String? sourceDir,
  });

  Future<ServiceResult> uninstall({required String instanceDir});

  Future<ServiceStatus> status({required String instanceDir});

  Future<ServiceResult> start({required String instanceDir});

  Future<ServiceResult> stop({required String instanceDir});
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

class MacOSLaunchAgentBackend implements ServiceBackend {
  final Future<ProcessResult> Function(String, List<String>) _run;
  final String _home;

  MacOSLaunchAgentBackend({Future<ProcessResult> Function(String, List<String>)? run, String? home})
    : _run = run ?? Process.run,
      _home = home ?? Platform.environment['HOME'] ?? '.';

  String get _agentDir => '$_home/Library/LaunchAgents';

  String _labelFor(String instanceDir) => 'com.dartclaw.agent.${_instanceSuffix(instanceDir)}';

  String _plistPathFor(String instanceDir) => '$_agentDir/${_labelFor(instanceDir)}.plist';

  @override
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    String? sourceDir,
  }) async {
    Directory(_agentDir).createSync(recursive: true);
    Directory('$instanceDir/logs').createSync(recursive: true);

    final plistPath = _plistPathFor(instanceDir);
    File(plistPath).writeAsStringSync(
      _plistContent(
        label: _labelFor(instanceDir),
        binPath: binPath,
        configPath: configPath,
        instanceDir: instanceDir,
        sourceDir: sourceDir,
      ),
    );

    final uid = await _uid();
    final result = await _run('launchctl', ['bootstrap', 'gui/$uid', plistPath]);
    if (result.exitCode == 0) {
      return const ServiceResult(success: true, message: 'LaunchAgent installed and loaded.');
    }

    final stderrText = _quotedStderr(result);
    if (stderrText.contains('36') || stderrText.contains('already')) {
      return const ServiceResult(success: true, message: 'LaunchAgent already installed.');
    }
    return ServiceResult(success: false, message: 'launchctl bootstrap failed: $stderrText');
  }

  @override
  Future<ServiceResult> uninstall({required String instanceDir}) async {
    final plistPath = _plistPathFor(instanceDir);
    if (!File(plistPath).existsSync()) {
      return const ServiceResult(success: true, message: 'LaunchAgent not installed.');
    }

    final label = _labelFor(instanceDir);
    final uid = await _uid();
    final result = await _run('launchctl', ['bootout', 'gui/$uid/$label']);
    final stderrText = result.stderr.toString().trim();
    if (result.exitCode != 0 && stderrText.isNotEmpty && !stderrText.contains('No such process')) {
      return ServiceResult(success: false, message: 'launchctl bootout failed: $stderrText');
    }

    File(plistPath).deleteSync();
    return const ServiceResult(success: true, message: 'LaunchAgent removed.');
  }

  @override
  Future<ServiceStatus> status({required String instanceDir}) async {
    final plistPath = _plistPathFor(instanceDir);
    if (!File(plistPath).existsSync()) {
      return ServiceStatus.notInstalled;
    }

    final label = _labelFor(instanceDir);
    final result = await _run('launchctl', ['print', 'gui/${await _uid()}/$label']);
    if (result.exitCode != 0) {
      return ServiceStatus.stopped;
    }

    final out = result.stdout.toString();
    if (out.contains('state = running')) {
      return ServiceStatus.running;
    }
    if (out.contains('state = waiting')) {
      return ServiceStatus.stopped;
    }
    return ServiceStatus.stopped;
  }

  @override
  Future<ServiceResult> start({required String instanceDir}) async {
    final plistPath = _plistPathFor(instanceDir);
    if (!File(plistPath).existsSync()) {
      return const ServiceResult(success: false, message: 'LaunchAgent not installed. Run: dartclaw service install');
    }

    final label = _labelFor(instanceDir);
    final result = await _run('launchctl', ['kickstart', 'gui/${await _uid()}/$label']);
    if (result.exitCode == 0) {
      return const ServiceResult(success: true, message: 'LaunchAgent started.');
    }
    return ServiceResult(success: false, message: 'launchctl kickstart failed: ${_quotedStderr(result)}');
  }

  @override
  Future<ServiceResult> stop({required String instanceDir}) async {
    final label = _labelFor(instanceDir);
    final result = await _run('launchctl', ['kill', 'TERM', 'gui/${await _uid()}/$label']);
    if (result.exitCode == 0) {
      return const ServiceResult(success: true, message: 'LaunchAgent stopped.');
    }
    return ServiceResult(success: false, message: 'launchctl kill failed: ${_quotedStderr(result)}');
  }

  Future<String> _uid() async {
    final result = await _run('id', ['-u']);
    return result.stdout.toString().trim();
  }

  String _plistContent({
    required String label,
    required String binPath,
    required String configPath,
    required String instanceDir,
    String? sourceDir,
  }) {
    final arguments = <String>[
      binPath,
      'serve',
      '--config',
      configPath,
      if (sourceDir != null) ...['--source-dir', sourceDir],
    ];
    final programArguments = arguments.map((arg) => '    <string>$arg</string>').join('\n');

    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
$programArguments
  </array>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$instanceDir/logs/dartclaw.log</string>
  <key>StandardErrorPath</key>
  <string>$instanceDir/logs/dartclaw.err.log</string>
</dict>
</plist>
''';
  }
}

class LinuxSystemdUserBackend implements ServiceBackend {
  final Future<ProcessResult> Function(String, List<String>) _run;
  final String _home;

  LinuxSystemdUserBackend({Future<ProcessResult> Function(String, List<String>)? run, String? home})
    : _run = run ?? Process.run,
      _home = home ?? Platform.environment['HOME'] ?? '.';

  String get _unitDir => '$_home/.config/systemd/user';

  String _serviceNameFor(String instanceDir) => 'dartclaw-${_instanceSuffix(instanceDir)}';

  String _unitPathFor(String instanceDir) => '$_unitDir/${_serviceNameFor(instanceDir)}.service';

  @override
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    String? sourceDir,
  }) async {
    final serviceName = _serviceNameFor(instanceDir);
    final unitPath = _unitPathFor(instanceDir);
    Directory(_unitDir).createSync(recursive: true);
    Directory('$instanceDir/logs').createSync(recursive: true);
    File(unitPath).writeAsStringSync(
      _unitContent(
        serviceName: serviceName,
        binPath: binPath,
        configPath: configPath,
        instanceDir: instanceDir,
        sourceDir: sourceDir,
      ),
    );

    final daemonReload = await _run('systemctl', ['--user', 'daemon-reload']);
    if (daemonReload.exitCode != 0) {
      File(unitPath).deleteSync();
      return ServiceResult(
        success: false,
        message: 'systemctl --user daemon-reload failed: ${_quotedStderr(daemonReload)}',
      );
    }

    final enable = await _run('systemctl', ['--user', 'enable', serviceName]);
    if (enable.exitCode != 0) {
      File(unitPath).deleteSync();
      await _run('systemctl', ['--user', 'daemon-reload']);
      return ServiceResult(success: false, message: 'systemctl --user enable failed: ${_quotedStderr(enable)}');
    }

    return const ServiceResult(success: true, message: 'systemd user unit installed and enabled.');
  }

  @override
  Future<ServiceResult> uninstall({required String instanceDir}) async {
    final unitPath = _unitPathFor(instanceDir);
    final serviceName = _serviceNameFor(instanceDir);
    if (!File(unitPath).existsSync()) {
      return const ServiceResult(success: true, message: 'systemd unit not installed.');
    }

    final disable = await _run('systemctl', ['--user', 'disable', '--now', serviceName]);
    if (disable.exitCode != 0) {
      return ServiceResult(success: false, message: 'systemctl --user disable --now failed: ${_quotedStderr(disable)}');
    }

    File(unitPath).deleteSync();
    final daemonReload = await _run('systemctl', ['--user', 'daemon-reload']);
    if (daemonReload.exitCode != 0) {
      return ServiceResult(
        success: false,
        message: 'systemctl --user daemon-reload failed: ${_quotedStderr(daemonReload)}',
      );
    }
    return const ServiceResult(success: true, message: 'systemd user unit removed.');
  }

  @override
  Future<ServiceStatus> status({required String instanceDir}) async {
    final unitPath = _unitPathFor(instanceDir);
    final serviceName = _serviceNameFor(instanceDir);
    if (!File(unitPath).existsSync()) {
      return ServiceStatus.notInstalled;
    }

    final result = await _run('systemctl', ['--user', 'is-active', serviceName]);
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
  Future<ServiceResult> start({required String instanceDir}) async {
    final unitPath = _unitPathFor(instanceDir);
    final serviceName = _serviceNameFor(instanceDir);
    if (!File(unitPath).existsSync()) {
      return const ServiceResult(success: false, message: 'systemd unit not installed. Run: dartclaw service install');
    }

    final result = await _run('systemctl', ['--user', 'start', serviceName]);
    if (result.exitCode == 0) {
      return const ServiceResult(success: true, message: 'systemd service started.');
    }
    return ServiceResult(success: false, message: 'systemctl start failed: ${_quotedStderr(result)}');
  }

  @override
  Future<ServiceResult> stop({required String instanceDir}) async {
    final serviceName = _serviceNameFor(instanceDir);
    final result = await _run('systemctl', ['--user', 'stop', serviceName]);
    if (result.exitCode == 0) {
      return const ServiceResult(success: true, message: 'systemd service stopped.');
    }
    return ServiceResult(success: false, message: 'systemctl stop failed: ${_quotedStderr(result)}');
  }

  String _unitContent({
    required String serviceName,
    required String binPath,
    required String configPath,
    required String instanceDir,
    String? sourceDir,
  }) {
    final sourceDirArg = sourceDir == null ? '' : ' --source-dir $sourceDir';
    return '''[Unit]
Description=DartClaw Agent Runtime ($serviceName)
After=network.target

[Service]
Type=simple
ExecStart=$binPath serve --config $configPath$sourceDirArg
WorkingDirectory=$instanceDir
Restart=on-failure
RestartSec=5
StandardOutput=append:$instanceDir/logs/dartclaw.log
StandardError=append:$instanceDir/logs/dartclaw.err.log
NoNewPrivileges=true

[Install]
WantedBy=default.target
''';
  }
}

class UnsupportedPlatformBackend implements ServiceBackend {
  static const _hint =
      'Automatic service management is not supported on this platform.\n'
      'Start DartClaw manually: dartclaw serve';

  @override
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    String? sourceDir,
  }) async => const ServiceResult(success: false, message: _hint);

  @override
  Future<ServiceResult> uninstall({required String instanceDir}) async =>
      const ServiceResult(success: false, message: _hint);

  @override
  Future<ServiceStatus> status({required String instanceDir}) async => ServiceStatus.unknown;

  @override
  Future<ServiceResult> start({required String instanceDir}) async =>
      const ServiceResult(success: false, message: _hint);

  @override
  Future<ServiceResult> stop({required String instanceDir}) async =>
      const ServiceResult(success: false, message: _hint);
}

ServiceBackend createPlatformBackend({Future<ProcessResult> Function(String, List<String>)? run, String? home}) {
  if (Platform.isMacOS) {
    return MacOSLaunchAgentBackend(run: run, home: home);
  }
  if (Platform.isLinux) {
    return LinuxSystemdUserBackend(run: run, home: home);
  }
  return UnsupportedPlatformBackend();
}
