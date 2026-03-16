import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
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
            (
              cwd, {
              claudeExecutable,
              turnTimeout,
              onMemorySave,
              onMemorySearch,
              onMemoryRead,
              harnessConfig,
              containerManager,
            }) => worker,
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
              lockManager,
              resetService,
              contextMonitor,
              resultTrimmer,
              channelManager,
              whatsAppChannel,
              googleChatWebhookHandler,
              signalChannel,
              webhookSecret,
              redactor,
              gatewayToken,
              selfImprovement,
              usageTracker,
              EventBus? eventBus,
              authEnabled = true,
              pool,
              contentGuardDisplay = const ContentGuardDisplayParams(),
              heartbeatDisplay = const HeartbeatDisplayParams(),
              schedulingDisplay = const SchedulingDisplayParams(),
              workspaceDisplay = const WorkspaceDisplayParams(),
              appDisplay = const AppDisplayParams(),
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
              lockManager: lockManager,
              resetService: resetService,
              contextMonitor: contextMonitor,
              resultTrimmer: resultTrimmer,
              redactor: redactor,
              gatewayToken: gatewayToken,
              eventBus: eventBus,
              authEnabled: authEnabled,
            ),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stderrLine: stderrLines.add,
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(stderrLines.join('\n'), contains('WARNING: Binding to 0.0.0.0 exposes the server to the network.'));
      expect(worker.started, isTrue);
      expect(worker.stopped, isTrue);
    });

    test('channel config warnings are printed before server startup', () async {
      final stderrLines = <String>[];
      final worker = _FakeWorkerService();
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_test_');

      ensureDartclawGoogleChatRegistered();
      ensureDartclawWhatsappRegistered();
      ensureDartclawSignalRegistered();

      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path == 'dartclaw.yaml') {
            return '''
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
          'static_dir': Directory.current.path,
          'templates_dir': _templatesDir(),
        },
        env: {'HOME': '/home/user'},
      );

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory:
            (
              cwd, {
              claudeExecutable,
              turnTimeout,
              onMemorySave,
              onMemorySearch,
              onMemoryRead,
              harnessConfig,
              containerManager,
            }) => worker,
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
              lockManager,
              resetService,
              contextMonitor,
              resultTrimmer,
              channelManager,
              whatsAppChannel,
              googleChatWebhookHandler,
              signalChannel,
              webhookSecret,
              redactor,
              gatewayToken,
              selfImprovement,
              usageTracker,
              EventBus? eventBus,
              authEnabled = true,
              pool,
              contentGuardDisplay = const ContentGuardDisplayParams(),
              heartbeatDisplay = const HeartbeatDisplayParams(),
              schedulingDisplay = const SchedulingDisplayParams(),
              workspaceDisplay = const WorkspaceDisplayParams(),
              appDisplay = const AppDisplayParams(),
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
              lockManager: lockManager,
              resetService: resetService,
              contextMonitor: contextMonitor,
              resultTrimmer: resultTrimmer,
              redactor: redactor,
              gatewayToken: gatewayToken,
              eventBus: eventBus,
              authEnabled: authEnabled,
            ),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stderrLine: stderrLines.add,
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(stderrLines.join('\n'), contains('WARNING: Invalid type for google_chat.group_access'));
      expect(stderrLines.join('\n'), contains('WARNING: Invalid type for whatsapp.gowa_port'));
      expect(stderrLines.join('\n'), contains('WARNING: Invalid type for signal.port'));
      expect(worker.started, isTrue);
      expect(worker.stopped, isTrue);
    });

    test('port-in-use path prints clear bind error', () async {
      final stderrLines = <String>[];
      final logs = <LogRecord>[];
      Logger.root.level = Level.ALL;
      final logSub = Logger.root.onRecord.listen(logs.add);
      addTearDown(() {
        logSub.cancel();
        Logger.root.level = Level.INFO;
      });
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
            (
              cwd, {
              claudeExecutable,
              turnTimeout,
              onMemorySave,
              onMemorySearch,
              onMemoryRead,
              harnessConfig,
              containerManager,
            }) => worker,
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
              lockManager,
              resetService,
              contextMonitor,
              resultTrimmer,
              channelManager,
              whatsAppChannel,
              googleChatWebhookHandler,
              signalChannel,
              webhookSecret,
              redactor,
              gatewayToken,
              selfImprovement,
              usageTracker,
              EventBus? eventBus,
              authEnabled = true,
              pool,
              contentGuardDisplay = const ContentGuardDisplayParams(),
              heartbeatDisplay = const HeartbeatDisplayParams(),
              schedulingDisplay = const SchedulingDisplayParams(),
              workspaceDisplay = const WorkspaceDisplayParams(),
              appDisplay = const AppDisplayParams(),
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
              lockManager: lockManager,
              resetService: resetService,
              contextMonitor: contextMonitor,
              resultTrimmer: resultTrimmer,
              redactor: redactor,
              gatewayToken: gatewayToken,
              eventBus: eventBus,
              authEnabled: authEnabled,
            ),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stderrLine: stderrLines.add,
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(logs.any((r) => r.level == Level.SEVERE && r.message.contains('Cannot bind to localhost:3000')), isTrue);
      expect(
        logs.any((r) => r.level == Level.SEVERE && r.message.contains('is another process already using this port?')),
        isTrue,
      );
    });

    test('startup migrates legacy turn KV keys to state db without touching session cost keys', () async {
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
      final kvFile = File(config.kvPath);
      kvFile.writeAsStringSync(
        jsonEncode({
          'turn:session-a': {'value': '{"turnId":"old-a"}', 'updatedAt': '2026-03-01T00:00:00Z'},
          'turn:session-b': {'value': '{"turnId":"old-b"}', 'updatedAt': '2026-03-02T00:00:00Z'},
          'session_cost:session-a': {'value': '123', 'updatedAt': '2026-03-03T00:00:00Z'},
        }),
      );

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory:
            (
              cwd, {
              claudeExecutable,
              turnTimeout,
              onMemorySave,
              onMemorySearch,
              onMemoryRead,
              harnessConfig,
              containerManager,
            }) => worker,
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
              lockManager,
              resetService,
              contextMonitor,
              resultTrimmer,
              channelManager,
              whatsAppChannel,
              googleChatWebhookHandler,
              signalChannel,
              webhookSecret,
              redactor,
              gatewayToken,
              selfImprovement,
              usageTracker,
              EventBus? eventBus,
              authEnabled = true,
              pool,
              contentGuardDisplay = const ContentGuardDisplayParams(),
              heartbeatDisplay = const HeartbeatDisplayParams(),
              schedulingDisplay = const SchedulingDisplayParams(),
              workspaceDisplay = const WorkspaceDisplayParams(),
              appDisplay = const AppDisplayParams(),
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
              lockManager: lockManager,
              resetService: resetService,
              contextMonitor: contextMonitor,
              resultTrimmer: resultTrimmer,
              redactor: redactor,
              gatewayToken: gatewayToken,
              eventBus: eventBus,
              authEnabled: authEnabled,
            ),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));

      expect(File(p.join(tempDir.path, 'state.db')).existsSync(), isTrue);

      final kvContents = jsonDecode(kvFile.readAsStringSync()) as Map<String, dynamic>;
      expect(kvContents.keys.where((key) => key.startsWith('turn:')), isEmpty);
      expect(kvContents.containsKey('session_cost:session-a'), isTrue);
    });

    test('search database open failure prints clear startup error', () async {
      final logs = <LogRecord>[];
      Logger.root.level = Level.ALL;
      final logSub = Logger.root.onRecord.listen(logs.add);
      addTearDown(() {
        logSub.cancel();
        Logger.root.level = Level.INFO;
      });
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_test_');

      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final config = DartclawConfig(dataDir: tempDir.path, templatesDir: _templatesDir());

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => throw FileSystemException('open failed'),
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(logs.any((r) => r.level == Level.SEVERE && r.message.contains('Cannot open search database')), isTrue);
    });

    test('task database open failure prints clear startup error', () async {
      final logs = <LogRecord>[];
      Logger.root.level = Level.ALL;
      final logSub = Logger.root.onRecord.listen(logs.add);
      addTearDown(() {
        logSub.cancel();
        Logger.root.level = Level.INFO;
      });
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_test_');

      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final config = DartclawConfig(dataDir: tempDir.path, templatesDir: _templatesDir());

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => throw FileSystemException('open failed'),
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
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
            (
              cwd, {
              claudeExecutable,
              turnTimeout,
              onMemorySave,
              onMemorySearch,
              onMemoryRead,
              harnessConfig,
              containerManager,
            }) => worker,
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
              lockManager,
              resetService,
              contextMonitor,
              resultTrimmer,
              channelManager,
              whatsAppChannel,
              googleChatWebhookHandler,
              signalChannel,
              webhookSecret,
              redactor,
              gatewayToken,
              selfImprovement,
              usageTracker,
              EventBus? eventBus,
              authEnabled = true,
              pool,
              contentGuardDisplay = const ContentGuardDisplayParams(),
              heartbeatDisplay = const HeartbeatDisplayParams(),
              schedulingDisplay = const SchedulingDisplayParams(),
              workspaceDisplay = const WorkspaceDisplayParams(),
              appDisplay = const AppDisplayParams(),
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
              lockManager: lockManager,
              resetService: resetService,
              contextMonitor: contextMonitor,
              resultTrimmer: resultTrimmer,
              redactor: redactor,
              gatewayToken: gatewayToken,
              eventBus: eventBus,
              authEnabled: authEnabled,
            ),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
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
