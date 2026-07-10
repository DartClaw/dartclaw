import 'dart:io';

import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../helpers/log_service_capture.dart';

class _ExitIntercept implements Exception {
  final int code;
  _ExitIntercept(this.code);
}

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
}

void main() {
  group('ServeCommand embedded templates', () {
    test('boots successfully without filesystem assets', () async {
      final stderrLines = <String>[];
      final worker = FakeAgentHarness();
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_filesystem_test_');

      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: p.join(tempDir.path, 'missing-static'),
          templatesDir: p.join(tempDir.path, 'missing-templates'),
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(worker),
        serverFactory: (builder) => builder.build(),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stderrLine: stderrLines.add,
        exitFn: (code) => throw _ExitIntercept(code),
        assetResolver: const AssetResolver(),
        runWorkflowSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await captureLogServiceRecords(
        () async {
          await expectLater(
            localRunner.run(['serve']),
            throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)),
          );
        },
        expectedSevereSubstrings: const ['Cannot bind to localhost:3333'],
        failOnUnexpectedSevere: true,
      );
      expect(stderrLines.join('\n'), isNot(contains('Template validation failed')));
    });
  });
}
