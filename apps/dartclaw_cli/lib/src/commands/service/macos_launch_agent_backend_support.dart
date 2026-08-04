part of 'service_backend.dart';

extension on MacOSLaunchAgentBackend {
  Future<ServiceResult> _refreshExistingDefinition({
    required String plistPath,
    required String plistContent,
    required String label,
    required String uid,
  }) async {
    final suffix = '${pid}_${DateTime.now().microsecondsSinceEpoch}';
    final staged = File('$plistPath.new_$suffix')..writeAsStringSync(plistContent);
    final current = File(plistPath);
    final backup = File('$plistPath.previous_$suffix');

    final bootoutError = await _bootoutLoaded(label: label, uid: uid);
    if (bootoutError != null) {
      final cleanupError = _tryDelete(staged);
      return ServiceResult(
        success: false,
        message:
            'launchctl bootout failed: $bootoutError${cleanupError == null ? '' : '; staged cleanup failed: $cleanupError'}',
      );
    }

    try {
      _renameFile(current.path, backup.path);
      _renameFile(staged.path, plistPath);
    } on FileSystemException catch (error) {
      final restoreError = _tryRestore(source: backup, target: current);
      final cleanupError = _tryDelete(staged);
      if (!current.existsSync()) {
        return ServiceResult(
          success: false,
          message:
              'LaunchAgent definition replacement failed: ${error.message}; previous definition restore failed: '
              '${restoreError ?? 'unknown error'}',
        );
      }
      final rollback = await _run('launchctl', ['bootstrap', 'gui/$uid', plistPath]);
      if (rollback.exitCode == 0) {
        return ServiceResult(
          success: false,
          message:
              'LaunchAgent definition replacement failed: ${error.message}; previous LaunchAgent restored'
              '${cleanupError == null ? '' : '; staged cleanup failed: $cleanupError'}',
        );
      }
      return ServiceResult(
        success: false,
        message:
            'LaunchAgent definition replacement failed: ${error.message}; restoring the previous LaunchAgent also '
            'failed: ${_quotedStderr(rollback)}${cleanupError == null ? '' : '; staged cleanup failed: $cleanupError'}',
      );
    }

    final replacement = await _run('launchctl', ['bootstrap', 'gui/$uid', plistPath]);
    if (replacement.exitCode == 0) {
      final cleanupError = _tryDelete(backup);
      if (cleanupError == null) {
        return const ServiceResult(success: true, message: 'LaunchAgent definition refreshed and loaded.');
      }
      return ServiceResult(
        success: true,
        message: 'LaunchAgent definition refreshed and loaded; previous definition cleanup failed: $cleanupError',
      );
    }

    final rejected = File('$plistPath.rejected_$suffix');
    try {
      _renameFile(current.path, rejected.path);
    } on FileSystemException catch (error) {
      return ServiceResult(
        success: false,
        message:
            'launchctl bootstrap failed: ${_quotedStderr(replacement)}; replacement definition could not be moved: '
            '${error.message}; previous definition remains at ${backup.path}',
      );
    }

    try {
      _renameFile(backup.path, plistPath);
    } on FileSystemException catch (error) {
      final replacementRestoreError = _tryRestore(source: rejected, target: current);
      return ServiceResult(
        success: false,
        message:
            'launchctl bootstrap failed: ${_quotedStderr(replacement)}; previous definition remains at ${backup.path} '
            'because restore failed: ${error.message}'
            '${replacementRestoreError == null ? '' : '; replacement definition restore failed: $replacementRestoreError'}',
      );
    }

    final rollback = await _run('launchctl', ['bootstrap', 'gui/$uid', plistPath]);
    final cleanupError = _tryDelete(rejected);
    final replacementError = _quotedStderr(replacement);
    if (rollback.exitCode == 0) {
      return ServiceResult(
        success: false,
        message:
            'launchctl bootstrap failed: $replacementError; previous LaunchAgent restored'
            '${cleanupError == null ? '' : '; rejected definition cleanup failed: $cleanupError'}',
      );
    }
    return ServiceResult(
      success: false,
      message:
          'launchctl bootstrap failed: $replacementError; restoring the previous LaunchAgent also failed: '
          '${_quotedStderr(rollback)}'
          '${cleanupError == null ? '' : '; rejected definition cleanup failed: $cleanupError'}',
    );
  }

  String? _tryDelete(File file) {
    try {
      if (file.existsSync()) _deleteFile(file.path);
      return null;
    } on FileSystemException catch (error) {
      return error.message;
    }
  }

  String? _tryRestore({required File source, required File target}) {
    try {
      if (source.existsSync() && !target.existsSync()) {
        _renameFile(source.path, target.path);
      }
      return null;
    } on FileSystemException catch (error) {
      return error.message;
    }
  }

  Future<String> _uid() async {
    final result = await _run('id', ['-u']);
    return result.stdout.toString().trim();
  }

  Future<String?> _bootoutLoaded({required String label, required String uid}) async {
    final result = await _run('launchctl', ['bootout', 'gui/$uid/$label']);
    final stderrText = result.stderr.toString().trim();
    if (result.exitCode != 0 && stderrText.isNotEmpty && !stderrText.contains('No such process')) {
      return stderrText;
    }
    return null;
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
    final programArguments = arguments.map((arg) => '    <string>${_xmlEscape(arg)}</string>').join('\n');

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
  <false/>
  <key>StandardOutPath</key>
  <string>${_xmlEscape('$instanceDir/logs/dartclaw.log')}</string>
  <key>StandardErrorPath</key>
  <string>${_xmlEscape('$instanceDir/logs/dartclaw.err.log')}</string>
</dict>
</plist>
''';
  }
}
