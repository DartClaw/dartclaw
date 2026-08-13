import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver, LogService;
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:shelf/shelf.dart' show Handler, Request;
import 'package:test/test.dart';

import '../helpers/log_service_capture.dart';

late String _templatesDir;
late String _staticDir;
late List<LogRecord> _testLogRecords;
late StreamSubscription<LogRecord> _testLogSubscription;
late List<String> _expectedSevereLogSubstrings;

Future<String> _resolveDartclawServerAssetDir(String child) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/dartclaw_server.dart'));
  if (uri == null) {
    throw StateError('Could not resolve package:dartclaw_server.');
  }
  final libDir = File.fromUri(uri).parent;
  return p.join(libDir.path, 'src', child);
}

Future<List<LogRecord>> _captureExpectedServeLogs(
  Future<void> Function() body, {
  Iterable<String> expectedSevereSubstrings = const [],
}) async {
  final expectedSevere = expectedSevereSubstrings.toList();
  _expectedSevereLogSubstrings.addAll(expectedSevere);
  return captureLogServiceRecords(body, expectedSevereSubstrings: expectedSevere, failOnUnexpectedSevere: true);
}

AssetResolver _assetResolverFor(Directory tempDir) {
  return const AssetResolver();
}

class _ExitIntercept implements Exception {
  final int code;
  _ExitIntercept(this.code);
}

class _FakeWorkerService extends FakeAgentHarness {
  bool get started => startCalled;
  bool get stopped => stopCalled || disposeCalled;

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
    String? agentId,
  }) async => {'ok': true};
}

const _missingBinary = 'dartclaw-definitely-missing-binary-12345';

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
}

Directory _tempDirectory([String prefix = 'dartclaw_serve_test_']) {
  final directory = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

Future<void> _expectExit(DartclawRunner runner, {int? code, List<String> args = const ['serve']}) {
  final matcher = code == null
      ? isA<_ExitIntercept>()
      : isA<_ExitIntercept>().having((error) => error.code, 'code', code);
  return expectLater(runner.run(args), throwsA(matcher));
}

ServeCommand _bindingFailureCommand({
  required DartclawConfig config,
  required Directory tempDir,
  required AgentHarness worker,
  void Function(String)? stderrLine,
}) => ServeCommand(
  config: config,
  searchDbFactory: (_) => sqlite3.openInMemory(),
  harnessFactory: _harnessFactoryFor(worker),
  serverFactory: (builder) => builder.build(),
  serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
  stderrLine: stderrLine ?? (_) {},
  exitFn: (code) => throw _ExitIntercept(code),
  assetResolver: _assetResolverFor(tempDir),
  runWorkflowSkillsBootstrap: false,
);

void main() {
  late DartclawRunner runner;
  late ServeCommand serveCommand;

  setUpAll(() async {
    // Absolute: `ServerConfig` defaults these to repo-root-relative paths, and a
    // concurrently-running suite that sets `Directory.current` changes this
    // process's cwd out from under us.
    _templatesDir = await _resolveDartclawServerAssetDir('templates');
    _staticDir = await _resolveDartclawServerAssetDir('static');
  });

  setUp(() {
    LogService.suppressOutputForTests = true;
    _testLogRecords = <LogRecord>[];
    _testLogSubscription = Logger.root.onRecord.listen(_testLogRecords.add);
    _expectedSevereLogSubstrings = <String>[];
    serveCommand = ServeCommand();
    runner = DartclawRunner()..addCommand(serveCommand);
  });

  tearDown(() async {
    await _testLogSubscription.cancel();
    LogService.suppressOutputForTests = false;
    final unexpectedSevere = _testLogRecords
        .where(
          (record) =>
              record.level >= Level.SEVERE &&
              !_expectedSevereLogSubstrings.any((expected) => record.message.contains(expected)),
        )
        .toList();
    if (unexpectedSevere.isNotEmpty) {
      fail('Unexpected SEVERE logs: ${unexpectedSevere.map((record) => record.message).join(' | ')}');
    }
  });

  group('ServeCommand', () {
    test('default port is 3333', () {
      final portOption = serveCommand.argParser.options['port']!;
      expect(portOption.defaultsTo, '3333');
    });

    test('default host is localhost', () {
      final hostOption = serveCommand.argParser.options['host']!;
      expect(hostOption.defaultsTo, 'localhost');
    });

    test('port has -p abbreviation', () {
      final portOption = serveCommand.argParser.options['port']!;
      expect(portOption.abbr, 'p');
    });

    test('host has -H abbreviation', () {
      final hostOption = serveCommand.argParser.options['host']!;
      expect(hostOption.abbr, 'H');
    });

    test('has data-dir, source-dir, static-dir, templates-dir, worker-timeout options', () {
      final options = serveCommand.argParser.options;
      expect(options.containsKey('data-dir'), isTrue);
      expect(options.containsKey('source-dir'), isTrue);
      expect(options.containsKey('static-dir'), isTrue);
      expect(options.containsKey('templates-dir'), isTrue);
      expect(options.containsKey('worker-timeout'), isTrue);
      expect(options.containsKey('offline'), isFalse);
    });

    group('port validation', () {
      test('port 0 throws UsageException', () {
        expect(
          () => runner.run(['serve', '--port', '0']),
          throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Invalid port'))),
        );
      });

      test('port 70000 throws UsageException', () {
        expect(
          () => runner.run(['serve', '--port', '70000']),
          throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Invalid port'))),
        );
      });

      test('non-numeric port throws UsageException', () {
        expect(
          () => runner.run(['serve', '--port', 'abc']),
          throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Invalid port'))),
        );
      });

      test('negative port throws UsageException', () {
        expect(
          () => runner.run(['serve', '--port', '-1']),
          throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Invalid port'))),
        );
      });
    });

    test('host 0.0.0.0 prints network exposure warning', () async {
      final stderrLines = <String>[];
      final worker = _FakeWorkerService();
      final tempDir = _tempDirectory();

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          host: '0.0.0.0',
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );

      final command = _bindingFailureCommand(
        config: config,
        tempDir: tempDir,
        worker: worker,
        stderrLine: stderrLines.add,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Cannot bind to 0.0.0.0:3333'],
      );
      expect(stderrLines.join('\n'), contains('WARNING: Binding to 0.0.0.0 exposes the server to the network.'));
    });

    test('Windows isolation capability reaches security wiring and aborts before server bind', () async {
      final tempDir = _tempDirectory('dartclaw_serve_isolation_test_');
      var serveCalled = false;

      final config = DartclawConfig(
        container: const ContainerConfig(enabled: true),
        server: ServerConfig(
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );
      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(_FakeWorkerService()),
        serveFn: (handler, address, port) async {
          serveCalled = true;
          throw StateError('server bind must not be reached');
        },
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
        assetResolver: _assetResolverFor(tempDir),
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        runWorkflowSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      final logs = await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Unsupported capability "container isolation"'],
      );

      expect(serveCalled, isFalse);
      expect(logs.map((record) => record.error).whereType<UnsupportedCapabilityError>(), hasLength(1));
    });

    test('Windows platform policy skips SIGTERM registration', () async {
      final tempDir = _tempDirectory('dartclaw_serve_signals_test_');
      var sigtermWatchCalls = 0;

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );
      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(_FakeWorkerService()),
        serveFn: (handler, address, port) => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
        assetResolver: _assetResolverFor(tempDir),
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        sigintWatch: () => Stream.value(ProcessSignal.sigint),
        sigtermWatch: () {
          sigtermWatchCalls++;
          return const Stream.empty();
        },
        runWorkflowSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await _expectExit(localRunner, code: 0);

      expect(sigtermWatchCalls, 0);
    });

    test('channel startup can be skipped while channels remain configured', () async {
      ensureDartclawWhatsappRegistered();
      final worker = _FakeWorkerService();
      late String pairingBody;
      final tempDir = _tempDirectory('dartclaw_serve_channels_skipped_test_');

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        gateway: const GatewayConfig(authMode: 'none'),
        server: ServerConfig(
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
        channels: const ChannelConfig(
          channelConfigs: {
            'whatsapp': {'enabled': true, 'gowa_executable': _missingBinary},
          },
        ),
      );
      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(worker),
        serveFn: (handler, address, port) async {
          pairingBody = await (await handler(
            Request('GET', Uri.parse('http://localhost/whatsapp/pairing')),
          )).readAsString();
          return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        },
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
        assetResolver: _assetResolverFor(tempDir),
        sigintWatch: () => Stream.value(ProcessSignal.sigint),
        sigtermWatch: () => const Stream.empty(),
        runWorkflowSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 0, args: const ['serve', '--no-connect-channels']),
      );

      expect(pairingBody, contains('Not Connected'));
      expect(worker.started, isTrue);
      expect(worker.stopped, isTrue);
    });

    test('channels connect by default', () async {
      ensureDartclawWhatsappRegistered();
      final worker = _FakeWorkerService();
      final tempDir = _tempDirectory('dartclaw_serve_channels_default_test_');

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
        channels: const ChannelConfig(
          channelConfigs: {
            'whatsapp': {'enabled': true, 'gowa_executable': _missingBinary},
          },
        ),
      );
      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(worker),
        serveFn: (handler, address, port) => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
        assetResolver: _assetResolverFor(tempDir),
        sigintWatch: () => Stream.value(ProcessSignal.sigint),
        sigtermWatch: () => const Stream.empty(),
        runWorkflowSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      final logs = await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 0),
        expectedSevereSubstrings: const ['Failed to spawn GOWA process', 'Failed to connect channel whatsapp'],
      );

      expect(logs.map((record) => record.message), contains('Failed to spawn GOWA process'));
      expect(logs.map((record) => record.message), contains('Failed to connect channel whatsapp'));
      expect(worker.started, isTrue);
      expect(worker.stopped, isTrue);
    });

    test('channel config warnings are printed before server startup', () async {
      final stderrLines = <String>[];
      final worker = _FakeWorkerService();
      final tempDir = _tempDirectory();

      ensureDartclawGoogleChatRegistered();
      ensureDartclawWhatsappRegistered();
      ensureDartclawSignalRegistered();

      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path == 'dartclaw.yaml') {
            return '''
credentials:
  anthropic:
    api_key: anthropic-key
channels:
  google_chat:
    group_access: 123
  whatsapp:
    gowa_port: nope
  signal:
    port: nope
''';
          }
          return null;
        },
        cliOverrides: {
          'data_dir': tempDir.path,
          'static_dir': _staticDir,
          'templates_dir': _templatesDir,
          'claude_executable': Platform.resolvedExecutable,
        },
        env: {'HOME': '/home/user'},
      );

      final command = _bindingFailureCommand(
        config: config,
        tempDir: tempDir,
        worker: worker,
        stderrLine: stderrLines.add,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Cannot bind to localhost:3333'],
      );
      expect(stderrLines.join('\n'), contains('WARNING: Invalid type for google_chat.group_access'));
      expect(stderrLines.join('\n'), contains('WARNING: Invalid type for whatsapp.gowa_port'));
      expect(stderrLines.join('\n'), contains('WARNING: Invalid type for signal.port'));
      expect(worker.started, isTrue);
      expect(worker.stopped, isTrue);
    });

    test('legacy startup validation fails fast when default provider credentials are missing', () async {
      final worker = _FakeWorkerService();
      final tempDir = _tempDirectory();

      final config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        server: ServerConfig(
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );

      final command = _bindingFailureCommand(config: config, tempDir: tempDir, worker: worker);
      final localRunner = DartclawRunner()..addCommand(command);

      await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Failed to start harness'],
      );
      expect(worker.started, isFalse);
      expect(worker.stopped, isFalse);
    });

    test('uses embedded templates and static assets without filesystem assets', () async {
      final worker = _FakeWorkerService();
      final tempDir = _tempDirectory('dartclaw_serve_asset_root_test_');

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: p.join(tempDir.path, 'missing-static'),
          templatesDir: p.join(tempDir.path, 'missing-templates'),
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );

      late Handler capturedHandler;
      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(worker),
        serverFactory: (builder) => builder.build(),
        serveFn: (handler, address, port) async {
          capturedHandler = handler;
          throw SocketException('Address already in use');
        },
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
        assetResolver: const AssetResolver(),
        runWorkflowSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Cannot bind to localhost:3333'],
      );

      final response = await capturedHandler(Request('GET', Uri.parse('http://localhost/static/sse.js')));
      expect(response.statusCode, 200);
      expect(response.headers['cache-control'], 'no-cache');
    });

    test('secondary-provider validation warnings do not block startup', () async {
      final worker = _FakeWorkerService();
      final tempDir = _tempDirectory();

      final config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        providers: ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
            'codex': const ProviderEntry(executable: _missingBinary, poolSize: 0),
          },
        ),
        server: ServerConfig(
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );

      final command = _bindingFailureCommand(config: config, tempDir: tempDir, worker: worker);
      final localRunner = DartclawRunner()..addCommand(command);

      final logs = await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Cannot bind to localhost:3333'],
      );
      expect(worker.started, isTrue);
      expect(
        logs.any(
          (record) =>
              record.loggerName == 'HarnessWiring' &&
              record.level == Level.WARNING &&
              record.message.contains("Provider 'codex': binary not found at '$_missingBinary'"),
        ),
        isTrue,
      );
    });

    test('port-in-use path prints clear bind error', () async {
      final stderrLines = <String>[];
      final worker = _FakeWorkerService();
      final tempDir = _tempDirectory();

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );

      final command = _bindingFailureCommand(
        config: config,
        tempDir: tempDir,
        worker: worker,
        stderrLine: stderrLines.add,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      final logs = await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Cannot bind to localhost:3333'],
      );
      expect(logs.any((r) => r.level == Level.SEVERE && r.message.contains('Cannot bind to localhost:3333')), isTrue);
      expect(
        logs.any((r) => r.level == Level.SEVERE && r.message.contains('is another process already using this port?')),
        isTrue,
      );
    });

    test('startup migrates legacy turn KV keys to state db without touching session cost keys', () async {
      final worker = _FakeWorkerService();
      final tempDir = _tempDirectory();

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );
      final kvFile = File(config.kvPath);
      kvFile.writeAsStringSync(
        jsonEncode({
          'turn:session-a': {'value': '{"turnId":"old-a"}', 'updatedAt': '2026-03-01T00:00:00Z'},
          'turn:session-b': {'value': '{"turnId":"old-b"}', 'updatedAt': '2026-03-02T00:00:00Z'},
          'session_cost:session-a': {'value': '123', 'updatedAt': '2026-03-03T00:00:00Z'},
        }),
      );

      final command = _bindingFailureCommand(config: config, tempDir: tempDir, worker: worker);
      final localRunner = DartclawRunner()..addCommand(command);

      await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Cannot bind to localhost:3333'],
      );

      expect(File(p.join(tempDir.path, 'state.db')).existsSync(), isTrue);

      final kvContents = jsonDecode(kvFile.readAsStringSync()) as Map<String, dynamic>;
      expect(kvContents.keys.where((key) => key.startsWith('turn:')), isEmpty);
      expect(kvContents.containsKey('session_cost:session-a'), isTrue);
    });

    test('search database open failure boots degraded and reports search unavailable', () async {
      final tempDir = _tempDirectory();

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path, templatesDir: _templatesDir, staticDir: _staticDir),
      );

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => throw FileSystemException('open failed'),
        serveFn: (handler, address, port) async => throw SocketException('stop after degraded boot'),
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
        assetResolver: _assetResolverFor(tempDir),
        runWorkflowSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      final logs = await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Cannot open search database', 'Cannot bind to localhost:3333'],
      );
      expect(
        logs.any(
          (record) =>
              record.level == Level.SEVERE &&
              record.message.contains('Cannot open search database') &&
              record.message.contains('booting with search unavailable'),
        ),
        isTrue,
      );
    });

    test('task database open failure prints clear startup error', () async {
      final tempDir = _tempDirectory();

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path, templatesDir: _templatesDir, staticDir: _staticDir),
      );

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => throw FileSystemException('open failed'),
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
        assetResolver: _assetResolverFor(tempDir),
        runWorkflowSkillsBootstrap: false,
      );
      final localRunner = DartclawRunner()..addCommand(command);

      final logs = await _captureExpectedServeLogs(
        () => _expectExit(localRunner, code: 1),
        expectedSevereSubstrings: const ['Cannot open task database'],
      );
      expect(logs.any((r) => r.level == Level.SEVERE && r.message.contains('Cannot open task database')), isTrue);
    });

    test('content guard with default claude_binary classifier needs no ANTHROPIC_API_KEY', () async {
      final apiKey = Platform.environment['ANTHROPIC_API_KEY'] ?? '';
      if (apiKey.isNotEmpty) {
        markTestSkipped('Cannot test absent-key path when ANTHROPIC_API_KEY is set');
        return;
      }

      final warnings = <String>[];
      final sub = Logger.root.onRecord.listen((r) {
        if (r.level >= Level.WARNING) warnings.add(r.message);
      });
      addTearDown(sub.cancel);

      final tempDir = _tempDirectory();

      final config = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          templatesDir: _templatesDir,
          staticDir: _staticDir,
          claudeExecutable: Platform.resolvedExecutable,
        ),
        security: SecurityConfig(contentGuardEnabled: true),
      );
      final worker = _FakeWorkerService();

      final command = _bindingFailureCommand(config: config, tempDir: tempDir, worker: worker);
      final localRunner = DartclawRunner()..addCommand(command);

      await _captureExpectedServeLogs(
        () => _expectExit(localRunner),
        expectedSevereSubstrings: const ['Cannot bind to localhost:3333'],
      );
      // Default classifier is claude_binary which doesn't need ANTHROPIC_API_KEY.
      // No API key warning should appear.
      expect(warnings.join('\n'), isNot(contains('ANTHROPIC_API_KEY not set')));
    });

    // The clean shutdown path (SIGINT/SIGTERM → shutdown() → _exitFn(0)) is
    // verified by manual testing with `bash dev/testing/profiles/plain/run.sh` + Ctrl+C.
    // In-process signal-based testing is not feasible: Process.killPid sends
    // signals to the OS process which terminates the test runner itself.
    // The _exitFn(0) call is placed at the end of run() (after the finally
    // block) and is exercised by any successful run that completes normally.
  });
}
