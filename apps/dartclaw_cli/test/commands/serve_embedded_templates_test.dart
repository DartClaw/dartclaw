import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

late String _templatesDirPath;
late String _staticDirPath;
late String _skillsDirPath;
late String _workflowsDirPath;

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
  return _templatesDirPath;
}

String _staticDir() {
  return _staticDirPath;
}

String _skillsDir() {
  return _skillsDirPath;
}

String _workflowsDir() {
  return _workflowsDirPath;
}

Future<String> _resolvePackageDir(String package, String packageRelativeAnchor) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:$package/$packageRelativeAnchor'));
  if (uri == null || !uri.isScheme('file')) {
    throw StateError('Could not resolve $package $packageRelativeAnchor via package URI');
  }
  return p.dirname(uri.toFilePath());
}

AssetResolver _assetResolverFor(Directory tempDir) {
  final prefixDir = Directory(p.join(tempDir.path, 'prefix'))..createSync(recursive: true);
  final assetRoot = Directory(p.join(prefixDir.path, 'share', 'dartclaw'))..createSync(recursive: true);
  _copyDirectory(Directory(_templatesDir()), Directory(p.join(assetRoot.path, 'templates')));
  _copyDirectory(Directory(_staticDir()), Directory(p.join(assetRoot.path, 'static')));
  Link(p.join(assetRoot.path, 'skills')).createSync(p.absolute(_skillsDir()));
  Link(p.join(assetRoot.path, 'workflows')).createSync(p.absolute(_workflowsDir()));
  return AssetResolver(resolvedExecutable: p.join(prefixDir.path, 'bin', 'dartclaw'));
}

void _copyDirectory(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final entity in source.listSync(recursive: true)) {
    final relative = p.relative(entity.path, from: source.path);
    final targetPath = p.join(target.path, relative);
    if (entity is Directory) {
      Directory(targetPath).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(targetPath)).createSync(recursive: true);
      entity.copySync(targetPath);
    }
  }
}

void main() {
  group('ServeCommand filesystem templates', () {
    setUpAll(() async {
      _templatesDirPath = await _resolvePackageDir('dartclaw_server', 'src/templates/audit_table.dart');
      _staticDirPath = await _resolvePackageDir('dartclaw_server', 'src/static/app.js');
      _skillsDirPath = await _resolvePackageDir('dartclaw_workflow', 'skills/dartclaw-native-skills.txt');
      _workflowsDirPath = await _resolvePackageDir('dartclaw_workflow', 'src/workflow/definitions/code-review.yaml');
    });

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
