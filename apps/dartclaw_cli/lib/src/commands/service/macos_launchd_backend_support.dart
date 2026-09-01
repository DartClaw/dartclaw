part of 'service_backend.dart';

extension on MacOSLaunchdBackend {
  /// Wordings launchd uses for "that label was not loaded", which every
  /// install tolerates because it boots out before writing.
  static const _notLoaded = ['No such process', 'not find service'];

  Future<String?> _bootoutLoaded({required String domain, required String label}) async {
    final result = await _run('launchctl', ['bootout', '$domain/$label']);
    final stderrText = result.stderr.toString().trim();
    if (result.exitCode == 0 || stderrText.isEmpty) return null;
    return _notLoaded.any(stderrText.contains) ? null : stderrText;
  }

  String _plistContent({
    required ServiceScope scope,
    required String label,
    required String binPath,
    required String configPath,
    required String instanceDir,
    String? sourceDir,
    String? serviceUser,
  }) {
    final arguments = <String>[
      binPath,
      'serve',
      '--config',
      configPath,
      if (sourceDir != null) ...['--source-dir', sourceDir],
    ];
    final programArguments = arguments.map((arg) => '    <string>${_xmlEscape(arg)}</string>').join('\n');
    final system = scope == ServiceScope.system;
    final runAtLoad = system ? '<true/>' : '<false/>';
    final runAsUser = system ? '  <key>UserName</key>\n  <string>${_xmlEscape(serviceUser!)}</string>\n' : '';

    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_xmlEscape(label)}</string>
  <key>ProgramArguments</key>
  <array>
$programArguments
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${_xmlEscape(_path)}</string>
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  $runAtLoad
  <key>StandardOutPath</key>
  <string>${_xmlEscape('$instanceDir/logs/dartclaw.log')}</string>
  <key>StandardErrorPath</key>
  <string>${_xmlEscape('$instanceDir/logs/dartclaw.err.log')}</string>
$runAsUser</dict>
</plist>
''';
  }
}
