import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver, LogService;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:shelf/shelf.dart' show Handler, Request;
import 'package:test/test.dart';

import '../helpers/log_service_capture.dart';

late String _templatesDir;
late List<LogRecord> _testLogRecords;
late StreamSubscription<LogRecord> _testLogSubscription;

Future<String> _resolveServerAssetDir(String child) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/dartclaw_server.dart'));
  if (uri == null) throw StateError('Could not resolve package:dartclaw_server.');
  return p.join(File.fromUri(uri).parent.path, 'src', child);
}

class _ExitIntercept implements Exception {
  final int code;
  _ExitIntercept(this.code);
}

class _WorkerHarness extends FakeAgentHarness {
  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async => {'ok': true};
}

HarnessFactory _harnessFactory() {
  final factory = HarnessFactory();
  factory.register('claude', (_) => _WorkerHarness());
  return factory;
}

DartclawConfig _config(
  String dataDir, {
  required String templatesDir,
  required String staticDir,
  bool devMode = false,
}) {
  return DartclawConfig(
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'test-key')}),
    server: ServerConfig(
      dataDir: dataDir,
      templatesDir: templatesDir,
      staticDir: staticDir,
      devMode: devMode,
      claudeExecutable: Platform.resolvedExecutable,
    ),
  );
}

Future<({Handler handler, List<LogRecord> logs})> _startUntilBindFailure(
  DartclawConfig config, {
  List<String> arguments = const ['serve'],
  bool runWorkflowSkillsBootstrap = false,
}) async {
  late Handler handler;
  final command = ServeCommand(
    config: config,
    searchDbFactory: (_) => sqlite3.openInMemory(),
    harnessFactory: _harnessFactory(),
    serverFactory: (builder) => builder.build(),
    serveFn: (candidate, address, port) async {
      handler = candidate;
      throw const SocketException('Address already in use');
    },
    stderrLine: (_) {},
    exitFn: (code) => throw _ExitIntercept(code),
    assetResolver: const AssetResolver(),
    runWorkflowSkillsBootstrap: runWorkflowSkillsBootstrap,
  );
  final runner = DartclawRunner()..addCommand(command);
  final logs = await captureLogServiceRecords(
    () async {
      await expectLater(runner.run(arguments), throwsA(isA<_ExitIntercept>().having((error) => error.code, 'code', 1)));
    },
    expectedSevereSubstrings: const ['Cannot bind to localhost:3333'],
    failOnUnexpectedSevere: true,
  );
  return (handler: handler, logs: logs);
}

void _copyDirectory(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final entity in source.listSync(recursive: true)) {
    final destination = p.join(target.path, p.relative(entity.path, from: source.path));
    if (entity is Directory) {
      Directory(destination).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(destination)).createSync(recursive: true);
      entity.copySync(destination);
    }
  }
}

void main() {
  setUpAll(() async {
    _templatesDir = await _resolveServerAssetDir('templates');
  });

  setUp(() {
    LogService.suppressOutputForTests = true;
    _testLogRecords = [];
    _testLogSubscription = Logger.root.onRecord.listen(_testLogRecords.add);
  });

  tearDown(() async {
    await _testLogSubscription.cancel();
    LogService.suppressOutputForTests = false;
  });

  test('embedded fallback serves static assets and materializes workflows and skills', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_embedded_assets_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final dataDir = p.join(tempDir.path, 'data');

    final started = await _startUntilBindFailure(
      _config(
        dataDir,
        templatesDir: p.join(tempDir.path, 'missing-templates'),
        staticDir: p.join(tempDir.path, 'missing-static'),
      ),
      runWorkflowSkillsBootstrap: true,
    );

    final response = await started.handler(Request('GET', Uri.parse('http://localhost/static/tokens.css')));
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], startsWith('text/css'));
    expect(started.logs.any((record) => record.message == 'Assets: embedded'), isTrue);
    for (final name in ['code-review.yaml', 'plan-and-implement.yaml', 'spec-and-implement.yaml']) {
      expect(File(p.join(dataDir, 'workflows', 'built-in', name)).existsSync(), isTrue, reason: name);
    }
    expect(File(p.join(dataDir, '.agents', 'skills', 'dartclaw-validate-workflow', 'SKILL.md')).existsSync(), isTrue);
  });

  test('explicit directories win over embedded assets', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_explicit_assets_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final templates = Directory(p.join(tempDir.path, 'templates'));
    final staticAssets = Directory(p.join(tempDir.path, 'static'))..createSync(recursive: true);
    _copyDirectory(Directory(_templatesDir), templates);
    File(p.join(staticAssets.path, 'custom.css')).writeAsStringSync('body { color: purple; }');

    final started = await _startUntilBindFailure(
      _config(tempDir.path, templatesDir: templates.path, staticDir: staticAssets.path),
      arguments: ['serve', '--templates-dir', templates.path, '--static-dir', staticAssets.path],
    );

    final response = await started.handler(Request('GET', Uri.parse('http://localhost/static/custom.css')));
    expect(response.statusCode, 200);
    expect(started.logs.any((record) => record.message.startsWith('Assets: explicitConfig')), isTrue);
  });

  test('dev source tree serves live filesystem assets', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_dev_assets_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final root = Directory(p.join(tempDir.path, 'checkout'))..createSync(recursive: true);
    final templates = Directory(p.join(root.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates'));
    final staticAssets = Directory(p.join(root.path, 'packages', 'dartclaw_server', 'lib', 'src', 'static'))
      ..createSync(recursive: true);
    _copyDirectory(Directory(_templatesDir), templates);
    File(p.join(staticAssets.path, 'live.css')).writeAsStringSync('/* local edit */');

    final started = await _startUntilBindFailure(
      _config(tempDir.path, templatesDir: templates.path, staticDir: staticAssets.path, devMode: true),
    );

    final response = await started.handler(Request('GET', Uri.parse('http://localhost/static/live.css')));
    expect(await response.readAsString(), '/* local edit */');
    expect(started.logs.any((record) => record.message.startsWith('Assets: devSourceTree')), isTrue);
  });

  test('partial explicit directories fail instead of using embedded assets', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_partial_assets_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final stderrLines = <String>[];
    final staticAssets = Directory(p.join(tempDir.path, 'static'))..createSync();
    final command = ServeCommand(
      config: _config(
        tempDir.path,
        templatesDir: p.join(tempDir.path, 'missing-templates'),
        staticDir: staticAssets.path,
      ),
      stderrLine: stderrLines.add,
      exitFn: (code) => throw _ExitIntercept(code),
      runWorkflowSkillsBootstrap: false,
    );

    await expectLater(
      (DartclawRunner()..addCommand(command)).run(['serve', '--static-dir', staticAssets.path]),
      throwsA(isA<_ExitIntercept>().having((error) => error.code, 'code', 1)),
    );
    expect(stderrLines.join('\n'), contains('Explicit asset directories are incomplete'));
  });
}
