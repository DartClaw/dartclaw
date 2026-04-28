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

String _templatesDir() {
  const fromWorkspace = 'packages/dartclaw_server/lib/src/templates';
  if (Directory(fromWorkspace).existsSync()) return fromWorkspace;
  final fromApp = p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'templates');
  if (Directory(fromApp).existsSync()) return fromApp;
  return fromWorkspace;
}

String _staticDir() {
  const fromWorkspace = 'packages/dartclaw_server/lib/src/static';
  if (Directory(fromWorkspace).existsSync()) return fromWorkspace;
  final fromApp = p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'static');
  if (Directory(fromApp).existsSync()) return fromApp;
  return fromWorkspace;
}

String _skillsDir() {
  const fromWorkspace = 'packages/dartclaw_workflow/skills';
  if (Directory(fromWorkspace).existsSync()) return fromWorkspace;
  final fromApp = p.join('..', '..', 'packages', 'dartclaw_workflow', 'skills');
  if (Directory(fromApp).existsSync()) return fromApp;
  return fromWorkspace;
}

String _workflowsDir() {
  const fromWorkspace = 'packages/dartclaw_workflow/lib/src/workflow/definitions';
  if (Directory(fromWorkspace).existsSync()) return fromWorkspace;
  final fromApp = p.join('..', '..', 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions');
  if (Directory(fromApp).existsSync()) return fromApp;
  return fromWorkspace;
}

AssetResolver _assetResolverFor(Directory tempDir) {
  final prefixDir = Directory(p.join(tempDir.path, 'prefix'))..createSync(recursive: true);
  final assetRoot = Directory(p.join(prefixDir.path, 'share', 'dartclaw'))..createSync(recursive: true);
  Link(p.join(assetRoot.path, 'templates')).createSync(p.absolute(_templatesDir()));
  Link(p.join(assetRoot.path, 'static')).createSync(p.absolute(_staticDir()));
  Link(p.join(assetRoot.path, 'skills')).createSync(p.absolute(_skillsDir()));
  Link(p.join(assetRoot.path, 'workflows')).createSync(p.absolute(_workflowsDir()));
  return AssetResolver(resolvedExecutable: p.join(prefixDir.path, 'bin', 'dartclaw'));
}

void main() {
  group('ServeCommand filesystem templates', () {
    test('boots successfully against filesystem assets without a prebuilt install', () async {
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
        assetResolver: _assetResolverFor(tempDir),
        runAndthenSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(stderrLines.join('\n'), isNot(contains('Template validation failed')));
    });
  });
}
