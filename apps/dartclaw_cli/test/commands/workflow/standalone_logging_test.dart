import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_cli/src/commands/workflow/standalone_lifecycle_support.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show LogService;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final format in ['human', 'json']) {
    test('standalone $format question warning reaches real stderr and file with redaction', () async {
      final directory = Directory.systemTemp.createTempSync('standalone_codex_logging');
      addTearDown(() => directory.deleteSync(recursive: true));
      final logFile = '${directory.path}/dartclaw.log';
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:dartclaw_cli/src/commands/config_loader.dart'),
      );
      if (library == null) throw StateError('Could not resolve dartclaw_cli package root');
      final packageRoot = File.fromUri(library).parent.parent.parent.parent.path;
      final fixture = p.join(
        packageRoot,
        'test',
        'commands',
        'workflow',
        'fixtures',
        'standalone_codex_logging_probe.dart',
      );
      final packageConfig = p.join(Directory(packageRoot).parent.parent.path, '.dart_tool', 'package_config.json');
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=$packageConfig',
        fixture,
        logFile,
        format,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      for (final content in [result.stderr as String, File(logFile).readAsStringSync()]) {
        expect('Unsupported Codex user input'.allMatches(content), hasLength(1));
        expect(content, contains('Blue'));
        expect(content, isNot(contains('sk_test_ABCSECRET')));
        expect(content, isNot(contains('CUSTOM_SENTINEL')));
        expect(content.split('\n').where((line) => line.trim().isNotEmpty), hasLength(1));
      }
    });
  }

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
