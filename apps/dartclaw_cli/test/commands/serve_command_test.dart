import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

String _templatesDir() {
  const fromWorkspace = 'packages/dartclaw_server/lib/src/templates';
  if (Directory(fromWorkspace).existsSync()) return fromWorkspace;
  final fromApp = p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'templates');
  if (Directory(fromApp).existsSync()) return fromApp;
  return fromWorkspace;
}

class _ExitIntercept implements Exception {
  final int code;
  _ExitIntercept(this.code);
}

class _FakeWorkerService implements AgentHarness {
  bool started = false;
  bool stopped = false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => const Stream<BridgeEvent>.empty();

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {
    stopped = true;
  }

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
  }) async => {'ok': true};
}

void main() {
  late DartclawRunner runner;
  late ServeCommand serveCommand;

  setUp(() {
    serveCommand = ServeCommand();
    runner = DartclawRunner()..addCommand(serveCommand);
  });

  group('ServeCommand', () {
    test('name is serve', () {
      expect(serveCommand.name, 'serve');
    });

    test('description is set', () {
      expect(serveCommand.description, isNotEmpty);
    });

    test('default port is 3000', () {
      final portOption = serveCommand.argParser.options['port']!;
      expect(portOption.defaultsTo, '3000');
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

    test('has data-dir, static-dir, worker-timeout options', () {
      final options = serveCommand.argParser.options;
      expect(options.containsKey('data-dir'), isTrue);
      expect(options.containsKey('static-dir'), isTrue);
      expect(options.containsKey('worker-timeout'), isTrue);
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
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_test_');

      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final config = DartclawConfig(
        host: '0.0.0.0',
        dataDir: tempDir.path,
        staticDir: Directory.current.path,
        templatesDir: _templatesDir(),
      );

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory:
            (cwd, {claudeExecutable, turnTimeout, onMemorySave, onMemorySearch, onMemoryRead, harnessConfig}) => worker,
        serverFactory:
            ({
              required sessions,
              required messages,
              required worker,
              required staticDir,
              required behavior,
              memoryFile,
              sessionsForTurns,
              guardChain,
              kv,
              healthService,
              tokenService,
              sessionStore,
              lockManager,
              resetService,
              contextMonitor,
              resultTrimmer,
              channelManager,
              whatsAppChannel,
              signalChannel,
              webhookSecret,
              redactor,
              gatewayToken,
              selfImprovement,
              usageTracker,
              authEnabled = true,
              heartbeatEnabled = false,
              heartbeatIntervalMinutes = 30,
              scheduledJobs = const [],
              workspacePath,
              gitSyncEnabled = false,
            }) => DartclawServer(
              sessions: sessions,
              messages: messages,
              worker: worker,
              staticDir: staticDir,
              behavior: behavior,
              memoryFile: memoryFile,
              guardChain: guardChain,
              kv: kv,
              healthService: healthService,
              tokenService: tokenService,
              sessionStore: sessionStore,
              lockManager: lockManager,
              resetService: resetService,
              contextMonitor: contextMonitor,
              resultTrimmer: resultTrimmer,
              redactor: redactor,
              gatewayToken: gatewayToken,
              authEnabled: authEnabled,
            ),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stdoutLine: (_) {},
        stderrLine: stderrLines.add,
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(stderrLines.join('\n'), contains('WARNING: Binding to 0.0.0.0 exposes the server to the network.'));
      expect(worker.started, isTrue);
      expect(worker.stopped, isTrue);
    });

    test('port-in-use path prints clear bind error', () async {
      final stderrLines = <String>[];
      final worker = _FakeWorkerService();
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_test_');

      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final config = DartclawConfig(
        dataDir: tempDir.path,
        staticDir: Directory.current.path,
        templatesDir: _templatesDir(),
      );

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory:
            (cwd, {claudeExecutable, turnTimeout, onMemorySave, onMemorySearch, onMemoryRead, harnessConfig}) => worker,
        serverFactory:
            ({
              required sessions,
              required messages,
              required worker,
              required staticDir,
              required behavior,
              memoryFile,
              sessionsForTurns,
              guardChain,
              kv,
              healthService,
              tokenService,
              sessionStore,
              lockManager,
              resetService,
              contextMonitor,
              resultTrimmer,
              channelManager,
              whatsAppChannel,
              signalChannel,
              webhookSecret,
              redactor,
              gatewayToken,
              selfImprovement,
              usageTracker,
              authEnabled = true,
              heartbeatEnabled = false,
              heartbeatIntervalMinutes = 30,
              scheduledJobs = const [],
              workspacePath,
              gitSyncEnabled = false,
            }) => DartclawServer(
              sessions: sessions,
              messages: messages,
              worker: worker,
              staticDir: staticDir,
              behavior: behavior,
              memoryFile: memoryFile,
              guardChain: guardChain,
              kv: kv,
              healthService: healthService,
              tokenService: tokenService,
              sessionStore: sessionStore,
              lockManager: lockManager,
              resetService: resetService,
              contextMonitor: contextMonitor,
              resultTrimmer: resultTrimmer,
              redactor: redactor,
              gatewayToken: gatewayToken,
              authEnabled: authEnabled,
            ),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stdoutLine: (_) {},
        stderrLine: stderrLines.add,
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(stderrLines.join('\n'), contains('Error: Cannot bind to localhost:3000'));
    });

    test('search database open failure prints clear startup error', () async {
      final stderrLines = <String>[];
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_test_');

      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final config = DartclawConfig(dataDir: tempDir.path, templatesDir: _templatesDir());

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => throw FileSystemException('open failed'),
        stdoutLine: (_) {},
        stderrLine: stderrLines.add,
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(stderrLines.join('\n'), contains('Error: Cannot open search database'));
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

      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_test_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final config = DartclawConfig(
        contentGuardEnabled: true,
        dataDir: tempDir.path,
        staticDir: Directory.current.path,
        templatesDir: _templatesDir(),
      );
      final worker = _FakeWorkerService();

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory:
            (cwd, {claudeExecutable, turnTimeout, onMemorySave, onMemorySearch, onMemoryRead, harnessConfig}) => worker,
        serverFactory:
            ({
              required sessions,
              required messages,
              required worker,
              required staticDir,
              required behavior,
              memoryFile,
              sessionsForTurns,
              guardChain,
              kv,
              healthService,
              tokenService,
              sessionStore,
              lockManager,
              resetService,
              contextMonitor,
              resultTrimmer,
              channelManager,
              whatsAppChannel,
              signalChannel,
              webhookSecret,
              redactor,
              gatewayToken,
              selfImprovement,
              usageTracker,
              authEnabled = true,
              heartbeatEnabled = false,
              heartbeatIntervalMinutes = 30,
              scheduledJobs = const [],
              workspacePath,
              gitSyncEnabled = false,
            }) => DartclawServer(
              sessions: sessions,
              messages: messages,
              worker: worker,
              staticDir: staticDir,
              behavior: behavior,
              memoryFile: memoryFile,
              guardChain: guardChain,
              kv: kv,
              healthService: healthService,
              tokenService: tokenService,
              sessionStore: sessionStore,
              lockManager: lockManager,
              resetService: resetService,
              contextMonitor: contextMonitor,
              resultTrimmer: resultTrimmer,
              redactor: redactor,
              gatewayToken: gatewayToken,
              authEnabled: authEnabled,
            ),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stdoutLine: (_) {},
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>()));
      // Default classifier is claude_binary which doesn't need ANTHROPIC_API_KEY.
      // No API key warning should appear.
      expect(warnings.join('\n'), isNot(contains('ANTHROPIC_API_KEY not set')));
    });
  });
}
