import 'dart:io';

import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_cli/src/commands/workflow/standalone_lifecycle_support.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show LogService;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  test('a standalone run installs a sink, so harness diagnostics are not discarded', () async {
    // Standalone lanes print only their own progress lines. Without an
    // installed sink every runtime record — provider stderr included — is
    // dropped and the configured level never applies (live, 2026-08-28).
    final dir = Directory.systemTemp.createTempSync('standalone_logging_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final logFile = '${dir.path}/dartclaw.log';

    final config = loadCliConfig(
      configPath: '/tmp/dartclaw.yaml',
      env: const {'HOME': '/home/testuser'},
      fileReader: (path) =>
          '''
logging:
  level: WARNING
  file: $logFile
''',
    );

    LogService.suppressOutputForTests = true;
    addTearDown(() => LogService.suppressOutputForTests = false);

    final logService = installStandaloneLogging(config);
    Logger('ClaudeCodeHarness').warning('[claude stderr] rule is not matched by file permission checks');
    await logService.dispose();

    expect(File(logFile).readAsStringSync(), contains('[claude stderr]'));
  });
}
