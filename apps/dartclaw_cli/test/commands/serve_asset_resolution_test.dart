import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_cli/src/asset_downloader.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver, dartclawVersion;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:shelf/shelf.dart' show Handler, Request, Response;
import 'package:test/test.dart';

late String _templatesDir;

Future<String> _resolveDartclawServerAssetDir(String child) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/dartclaw_server.dart'));
  if (uri == null) {
    throw StateError('Could not resolve package:dartclaw_server.');
  }
  final libDir = File.fromUri(uri).parent;
  return p.join(libDir.path, 'src', child);
}

class _AssetExitIntercept implements Exception {
  final int code;
  _AssetExitIntercept(this.code);
}

class _AssetWorkerHarness extends FakeAgentHarness {
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

class _AssetReturningDownloader extends AssetDownloader {
  final String root;

  _AssetReturningDownloader(this.root) : super(homeDir: '/tmp', releaseBaseUri: Uri.parse('http://127.0.0.1/'));

  @override
  Future<String> download() async => root;
}

/// Fails loudly if a test ever falls through to the download path. Tests that
/// expect an explicit/dev source tree or a seeded cache to win must never reach
/// here; without this, a fall-through silently fetches real release assets over
/// the network on CI and serves the wrong static dir (manifesting as a 404).
class _FailingDownloader extends AssetDownloader {
  _FailingDownloader() : super(homeDir: '/tmp', releaseBaseUri: Uri.parse('http://127.0.0.1/'));

  @override
  Future<String> download() async =>
      throw StateError('unexpected asset download — resolution should have returned an on-disk root');
}

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
}

Directory _seedCacheRoot(Directory tempDir, {required bool copyTemplates}) {
  final cacheRoot = Directory(p.join(tempDir.path, 'home', '.dartclaw', 'assets', 'v$dartclawVersion'))
    ..createSync(recursive: true);
  final templates = Directory(p.join(cacheRoot.path, 'templates'))..createSync(recursive: true);
  if (copyTemplates) {
    _copyDirectory(Directory(_templatesDir), templates);
  }
  Directory(p.join(cacheRoot.path, 'static')).createSync(recursive: true);
  Directory(p.join(cacheRoot.path, 'skills')).createSync(recursive: true);
  Directory(p.join(cacheRoot.path, 'workflows')).createSync(recursive: true);
  File(p.join(cacheRoot.path, 'VERSION')).writeAsStringSync('$dartclawVersion\n');
  return cacheRoot;
}

Directory _seedSourceCheckout(Directory tempDir, {bool createWorkflowDefinitions = true, bool createSkills = true}) {
  final sourceRoot = Directory(p.join(tempDir.path, 'source-checkout'))..createSync(recursive: true);
  final templates = Directory(p.join(sourceRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates'))
    ..createSync(recursive: true);
  _copyDirectory(Directory(_templatesDir), templates);
  final staticDir = Directory(p.join(sourceRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'static'))
    ..createSync(recursive: true);
  File(p.join(staticDir.path, 'source-only.css')).writeAsStringSync('body { color: green; }');
  if (createWorkflowDefinitions) {
    final workflowDefinitions = Directory(
      p.join(sourceRoot.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
    )..createSync(recursive: true);
    File(p.join(workflowDefinitions.path, 'source-only-workflow.yaml')).writeAsStringSync('''
name: source-only-workflow
description: Source-only workflow fixture.
steps:
  - id: noop
    name: Noop
    type: bash
    command: "true"
''');
  }
  if (createSkills) {
    Directory(p.join(sourceRoot.path, 'packages', 'dartclaw_workflow', 'skills')).createSync(recursive: true);
  }
  return sourceRoot;
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
  setUpAll(() async {
    _templatesDir = await _resolveDartclawServerAssetDir('templates');
  });

  setUp(() => capturedHandler = null);

  test('explicit asset dirs beat a same-version cache for templates and static assets', () async {
    final logs = <LogRecord>[];
    Logger.root.level = Level.ALL;
    final logSub = Logger.root.onRecord.listen(logs.add);
    addTearDown(() {
      logSub.cancel();
      Logger.root.level = Level.INFO;
    });

    final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_asset_precedence_test_');
    final sourceStatic = Directory(p.join(tempDir.path, 'source-static'))..createSync(recursive: true);
    File(p.join(sourceStatic.path, 'source-only.css')).writeAsStringSync('body { color: red; }');
    _seedCacheRoot(tempDir, copyTemplates: false);
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final command = ServeCommand(
      config: DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: sourceStatic.path,
          templatesDir: _templatesDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      ),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      harnessFactory: _harnessFactoryFor(_AssetWorkerHarness()),
      serverFactory: (builder) => builder.build(),
      serveFn: (handler, address, port) async {
        capturedHandler = handler;
        throw SocketException('Address already in use');
      },
      stderrLine: (_) {},
      exitFn: (code) => throw _AssetExitIntercept(code),
      assetResolver: AssetResolver(
        resolvedExecutable: p.join(tempDir.path, 'bin', 'dartclaw'),
        homeDir: p.join(tempDir.path, 'home'),
      ),
      runAndthenSkillsBootstrap: false,
    );
    final localRunner = DartclawRunner()..addCommand(command);

    await expectLater(
      localRunner.run(['serve', '--static-dir', sourceStatic.path]),
      throwsA(isA<_AssetExitIntercept>().having((e) => e.code, 'code', 1)),
    );

    final response = await _hit('/static/source-only.css');
    expect(response.statusCode, 200);
    expect(logs.any((r) => r.message == 'Assets: explicitConfig at $_templatesDir'), isTrue);
  });

  test('config source_dir beats a same-version cache without CLI asset flags', () async {
    final logs = <LogRecord>[];
    Logger.root.level = Level.ALL;
    final logSub = Logger.root.onRecord.listen(logs.add);
    addTearDown(() {
      logSub.cancel();
      Logger.root.level = Level.INFO;
    });
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_config_source_precedence_test_');
    final sourceRoot = _seedSourceCheckout(tempDir);
    final sourceTemplates = p.join(sourceRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates');
    _seedCacheRoot(tempDir, copyTemplates: true);
    final configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))
      ..writeAsStringSync('''
data_dir: ${p.join(tempDir.path, 'data')}
source_dir: ${sourceRoot.path}
credentials:
  anthropic:
    api_key: test-key
gateway:
  auth_mode: none
guards:
  enabled: false
scheduling:
  heartbeat:
    enabled: false
  jobs: []
workspace:
  git_sync:
    enabled: false
''');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final command = ServeCommand(
      searchDbFactory: (_) => sqlite3.openInMemory(),
      harnessFactory: _harnessFactoryFor(_AssetWorkerHarness()),
      serverFactory: (builder) => builder.build(),
      serveFn: (handler, address, port) async {
        capturedHandler = handler;
        throw SocketException('Address already in use');
      },
      stderrLine: (_) {},
      exitFn: (code) => throw _AssetExitIntercept(code),
      assetResolver: AssetResolver(
        resolvedExecutable: p.join(tempDir.path, 'bin', 'dartclaw'),
        homeDir: p.join(tempDir.path, 'home'),
      ),
      assetDownloader: _FailingDownloader(),
      runAndthenSkillsBootstrap: false,
    );
    final localRunner = DartclawRunner()..addCommand(command);

    // `claude_executable` is read only from CLI overrides (config_parser), not
    // YAML, so the provider binary must be pinned via the flag — otherwise
    // ProviderValidator probes the default `claude`, which is absent on CI and
    // aborts harness startup before serveFn. `--claude-executable` is not an
    // asset-dir flag, so it does not affect the config-source_dir precedence
    // path under test.
    await expectLater(
      localRunner.run(['--config', configFile.path, 'serve', '--claude-executable', Platform.resolvedExecutable]),
      throwsA(isA<_AssetExitIntercept>().having((e) => e.code, 'code', 1)),
    );

    // The config-set source tree must win over the same-version cache: provenance
    // names the source checkout, and its static (not the cache's empty static) serves.
    expect(
      logs.map((r) => r.message).where((m) => m.startsWith('Assets:')),
      contains('Assets: explicitConfig at $sourceTemplates'),
      reason: 'config source_dir should resolve as explicitConfig from the source checkout, not the cache',
    );
    final response = await _hit('/static/source-only.css');
    expect(response.statusCode, 200);
  });

  test('partial explicit asset dir does not fall through to cache', () async {
    final stderrLines = <String>[];
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_partial_asset_dir_test_');
    final sourceStatic = Directory(p.join(tempDir.path, 'source-static'))..createSync(recursive: true);
    _seedCacheRoot(tempDir, copyTemplates: true);
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final command = ServeCommand(
      config: DartclawConfig(
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: sourceStatic.path,
          templatesDir: p.join(tempDir.path, 'missing-templates'),
          claudeExecutable: Platform.resolvedExecutable,
        ),
      ),
      stderrLine: stderrLines.add,
      exitFn: (code) => throw _AssetExitIntercept(code),
      assetResolver: AssetResolver(
        resolvedExecutable: p.join(tempDir.path, 'bin', 'dartclaw'),
        homeDir: p.join(tempDir.path, 'home'),
      ),
      runAndthenSkillsBootstrap: false,
    );
    final localRunner = DartclawRunner()..addCommand(command);

    await expectLater(
      localRunner.run(['serve', '--static-dir', sourceStatic.path]),
      throwsA(isA<_AssetExitIntercept>().having((e) => e.code, 'code', 1)),
    );

    final stderr = stderrLines.join('\n');
    expect(stderr, contains('Explicit asset directories are incomplete'));
    expect(stderr, contains('templates:'));
  });

  test('downloaded assets are wrapped once and shared with static and workflow materialization', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_downloaded_assets_test_');
    final downloadedRoot = Directory(p.join(tempDir.path, 'downloaded'))..createSync(recursive: true);
    _copyDirectory(Directory(_templatesDir), Directory(p.join(downloadedRoot.path, 'templates')));
    final downloadedStatic = Directory(p.join(downloadedRoot.path, 'static'))..createSync(recursive: true);
    File(p.join(downloadedStatic.path, 'downloaded-only.css')).writeAsStringSync('body { color: blue; }');
    Directory(p.join(downloadedRoot.path, 'skills')).createSync(recursive: true);
    final downloadedWorkflows = Directory(p.join(downloadedRoot.path, 'workflows'))..createSync(recursive: true);
    File(p.join(downloadedWorkflows.path, 'downloaded-only-workflow.yaml')).writeAsStringSync('''
name: downloaded-only-workflow
description: Downloaded-only workflow fixture.
steps:
  - id: noop
    name: Noop
    type: bash
    command: "true"
''');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final command = ServeCommand(
      config: DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: p.join(tempDir.path, 'missing-static'),
          templatesDir: p.join(tempDir.path, 'missing-templates'),
          claudeExecutable: Platform.resolvedExecutable,
        ),
      ),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      harnessFactory: _harnessFactoryFor(_AssetWorkerHarness()),
      serverFactory: (builder) => builder.build(),
      serveFn: (handler, address, port) async {
        capturedHandler = handler;
        throw SocketException('Address already in use');
      },
      stderrLine: (_) {},
      exitFn: (code) => throw _AssetExitIntercept(code),
      assetResolver: AssetResolver(
        resolvedExecutable: p.join(tempDir.path, 'bin', 'dartclaw'),
        homeDir: p.join(tempDir.path, 'home'),
      ),
      assetDownloader: _AssetReturningDownloader(downloadedRoot.path),
      runAndthenSkillsBootstrap: false,
    );
    final localRunner = DartclawRunner()..addCommand(command);

    await expectLater(localRunner.run(['serve']), throwsA(isA<_AssetExitIntercept>().having((e) => e.code, 'code', 1)));

    final response = await _hit('/static/downloaded-only.css');
    expect(response.statusCode, 200);
    expect(File(p.join(tempDir.path, 'workflows', 'built-in', 'downloaded-only-workflow.yaml')).existsSync(), isTrue);
  });

  test('source-dir asset session materializes built-in workflows from the same checkout', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_source_session_test_');
    final sourceRoot = _seedSourceCheckout(tempDir);
    _seedCacheRoot(tempDir, copyTemplates: true);
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final command = ServeCommand(
      config: DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: p.join(tempDir.path, 'data'),
          staticDir: p.join(sourceRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'static'),
          templatesDir: p.join(sourceRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates'),
          claudeExecutable: Platform.resolvedExecutable,
        ),
      ),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      harnessFactory: _harnessFactoryFor(_AssetWorkerHarness()),
      serverFactory: (builder) => builder.build(),
      serveFn: (handler, address, port) async {
        capturedHandler = handler;
        throw SocketException('Address already in use');
      },
      stderrLine: (_) {},
      exitFn: (code) => throw _AssetExitIntercept(code),
      assetResolver: AssetResolver(
        resolvedExecutable: p.join(tempDir.path, 'elsewhere', 'bin', 'dartclaw'),
        homeDir: p.join(tempDir.path, 'home'),
      ),
      runAndthenSkillsBootstrap: false,
    );
    final localRunner = DartclawRunner()..addCommand(command);

    await expectLater(
      localRunner.run(['serve', '--source-dir', sourceRoot.path]),
      throwsA(isA<_AssetExitIntercept>().having((e) => e.code, 'code', 1)),
    );

    final response = await _hit('/static/source-only.css');
    expect(response.statusCode, 200);
    expect(
      File(p.join(tempDir.path, 'data', 'workflows', 'built-in', 'source-only-workflow.yaml')).existsSync(),
      isTrue,
    );
  });

  test(
    'source-dir asset session does not fall back to ambient workflows when resolved workflows are missing',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_missing_source_workflows_test_');
      final sourceRoot = _seedSourceCheckout(tempDir, createWorkflowDefinitions: false);
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final dataDir = p.join(tempDir.path, 'data');
      final command = ServeCommand(
        config: DartclawConfig(
          credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
          server: ServerConfig(
            dataDir: dataDir,
            staticDir: p.join(sourceRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'static'),
            templatesDir: p.join(sourceRoot.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates'),
            claudeExecutable: Platform.resolvedExecutable,
          ),
        ),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(_AssetWorkerHarness()),
        serverFactory: (builder) => builder.build(),
        serveFn: (handler, address, port) async {
          capturedHandler = handler;
          throw SocketException('Address already in use');
        },
        stderrLine: (_) {},
        exitFn: (code) => throw _AssetExitIntercept(code),
        assetResolver: AssetResolver(
          resolvedExecutable: p.join(tempDir.path, 'elsewhere', 'bin', 'dartclaw'),
          homeDir: p.join(tempDir.path, 'home'),
        ),
        runAndthenSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(
        localRunner.run(['serve', '--source-dir', sourceRoot.path]),
        throwsA(isA<_AssetExitIntercept>().having((e) => e.code, 'code', 1)),
      );

      expect(File(p.join(dataDir, 'workflows', 'built-in', 'code-review.yaml')).existsSync(), isFalse);
    },
  );

  test('noncanonical explicit asset dirs do not fall back to ambient workflows', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_noncanonical_assets_test_');
    final templates = Directory(p.join(tempDir.path, 'custom-templates'))..createSync(recursive: true);
    _copyDirectory(Directory(_templatesDir), templates);
    final staticDir = Directory(p.join(tempDir.path, 'custom-static'))..createSync(recursive: true);
    File(p.join(staticDir.path, 'custom-only.css')).writeAsStringSync('body { color: purple; }');
    final dataDir = p.join(tempDir.path, 'data');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final command = ServeCommand(
      config: DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: dataDir,
          staticDir: staticDir.path,
          templatesDir: templates.path,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      ),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      harnessFactory: _harnessFactoryFor(_AssetWorkerHarness()),
      serverFactory: (builder) => builder.build(),
      serveFn: (handler, address, port) async {
        capturedHandler = handler;
        throw SocketException('Address already in use');
      },
      stderrLine: (_) {},
      exitFn: (code) => throw _AssetExitIntercept(code),
      assetResolver: AssetResolver(
        resolvedExecutable: p.join(tempDir.path, 'elsewhere', 'bin', 'dartclaw'),
        homeDir: p.join(tempDir.path, 'home'),
      ),
      runAndthenSkillsBootstrap: false,
    );
    final localRunner = DartclawRunner()..addCommand(command);

    await expectLater(
      localRunner.run(['serve', '--templates-dir', templates.path, '--static-dir', staticDir.path]),
      throwsA(isA<_AssetExitIntercept>().having((e) => e.code, 'code', 1)),
    );

    final response = await _hit('/static/custom-only.css');
    expect(response.statusCode, 200);
    expect(File(p.join(dataDir, 'workflows', 'built-in', 'code-review.yaml')).existsSync(), isFalse);
  });

  test('missing template error names resolved source and remedy', () async {
    final stderrLines = <String>[];
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_missing_template_cache_test_');
    final cacheRoot = _seedCacheRoot(tempDir, copyTemplates: false);
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final command = ServeCommand(
      config: DartclawConfig(
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: p.join(tempDir.path, 'missing-static'),
          templatesDir: p.join(tempDir.path, 'missing-templates'),
          claudeExecutable: Platform.resolvedExecutable,
        ),
      ),
      stderrLine: stderrLines.add,
      exitFn: (code) => throw _AssetExitIntercept(code),
      assetResolver: AssetResolver(
        resolvedExecutable: p.join(tempDir.path, 'bin', 'dartclaw'),
        homeDir: p.join(tempDir.path, 'home'),
      ),
      runAndthenSkillsBootstrap: false,
    );
    final localRunner = DartclawRunner()..addCommand(command);

    await expectLater(localRunner.run(['serve']), throwsA(isA<_AssetExitIntercept>().having((e) => e.code, 'code', 1)));

    final stderr = stderrLines.join('\n');
    expect(stderr, contains('Template validation failed:'));
    expect(stderr, contains('Resolved assets: downloadedCache at ${cacheRoot.path}'));
    expect(stderr, contains('--source-dir <repo>'));
    expect(stderr, contains('~/.dartclaw/assets/v$dartclawVersion'));
  });
}

/// Reset before every test so a command that exits before `serveFn` cannot
/// leave a stale handler from a prior test (which would make the next test
/// assert against the wrong static root).
Handler? capturedHandler;

/// Asserts the serve command actually reached `serveFn` (so the handler belongs
/// to *this* test), then dispatches the request — turning a silent stale-handler
/// 404 into an explicit "no handler captured" failure.
Future<Response> _hit(String path) async {
  expect(
    capturedHandler,
    isNotNull,
    reason: 'serve command exited before serveFn — no handler was captured for this test',
  );
  return capturedHandler!(Request('GET', Uri.parse('http://localhost$path')));
}
