import 'dart:io';

import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _ExitIntercept implements Exception {
  final int code;
  _ExitIntercept(this.code);
}

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
}

Map<String, String> _embeddedTemplates() {
  const templateNames = [
    'error_page',
    'login',
    'components',
    'layout',
    'topbar',
    'sidebar',
    'session_info',
    'scheduling',
    'health_dashboard',
    'settings',
    'chat',
    'whatsapp_pairing',
    'signal_pairing',
    'memory_dashboard',
    'restart_banner',
    'channel_detail',
    'tasks',
    'task_detail',
    'task_timeline',
    'projects',
    'canvas_standalone',
    'canvas_embed',
    'canvas_admin_panel',
    'canvas_task_board',
    'canvas_stats_bar',
    'workflow_detail',
    'workflow_step_detail',
    'workflow_list',
  ];

  return {for (final name in templateNames) name: '<div>$name</div>'};
}

void main() {
  group('ServeCommand embedded templates', () {
    test('boots successfully against embedded templates without a real template directory', () async {
      final stderrLines = <String>[];
      final worker = FakeAgentHarness();
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_embedded_test_');
      final previousTemplates = Map<String, String>.from(embeddedTemplates);

      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      embeddedTemplates
        ..clear()
        ..addAll(_embeddedTemplates());

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: Directory.current.path,
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
      );
      final localRunner = DartclawRunner()..addCommand(command);

      try {
        await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
        expect(stderrLines.join('\n'), isNot(contains('Template validation failed')));
      } finally {
        embeddedTemplates
          ..clear()
          ..addAll(previousTemplates);
      }
    });
  });
}
