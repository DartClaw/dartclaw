import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
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
    int? maxTurns,
  }) async => {'ok': true};
}

const _missingBinary = 'dartclaw-definitely-missing-binary-12345';

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
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

    test('has data-dir, source-dir, static-dir, templates-dir, worker-timeout options', () {
      final options = serveCommand.argParser.options;
      expect(options.containsKey('data-dir'), isTrue);
      expect(options.containsKey('source-dir'), isTrue);
      expect(options.containsKey('static-dir'), isTrue);
      expect(options.containsKey('templates-dir'), isTrue);
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
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          host: '0.0.0.0',
          dataDir: tempDir.path,
          staticDir: Directory.current.path,
          templatesDir: _templatesDir(),
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
          'static_dir': Directory.current.path,
          'templates_dir': _templatesDir(),
          'claude_executable': Platform.resolvedExecutable,
        },
        env: {'HOME': '/home/user'},
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

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(stderrLines.join('\n'), contains('WARNING: Invalid type for google_chat.group_access'));
      expect(stderrLines.join('\n'), contains('WARNING: Invalid type for whatsapp.gowa_port'));
      expect(stderrLines.join('\n'), contains('WARNING: Invalid type for signal.port'));
      expect(worker.started, isTrue);
      expect(worker.stopped, isTrue);
    });

    test('legacy startup validation fails fast when default provider credentials are missing', () async {
      final worker = _FakeWorkerService();
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_serve_test_');

      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: Directory.current.path,
          templatesDir: _templatesDir(),
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(worker),
        serverFactory: (builder) => builder.build(),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
      expect(worker.started, isFalse);
      expect(worker.stopped, isFalse);
    });

    test('secondary-provider validation warnings do not block startup', () async {
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
          staticDir: Directory.current.path,
          templatesDir: _templatesDir(),
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(worker),
        serverFactory: (builder) => builder.build(),
        serveFn: (handler, address, port) async => throw SocketException('Address already in use'),
        stderrLine: (_) {},
        exitFn: (code) => throw _ExitIntercept(code),
      );
      final localRunner = DartclawRunner()..addCommand(command);

      await expectLater(localRunner.run(['serve']), throwsA(isA<_ExitIntercept>().having((e) => e.code, 'code', 1)));
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
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: Directory.current.path,
          templatesDir: _templatesDir(),
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
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: Directory.current.path,
          templatesDir: _templatesDir(),
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

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(worker),
        serverFactory: (builder) => builder.build(),
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

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path, templatesDir: _templatesDir()),
      );

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

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path, templatesDir: _templatesDir()),
      );

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
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        server: ServerConfig(
          dataDir: tempDir.path,
          staticDir: Directory.current.path,
          templatesDir: _templatesDir(),
          claudeExecutable: Platform.resolvedExecutable,
        ),
        security: SecurityConfig(contentGuardEnabled: true),
      );
      final worker = _FakeWorkerService();

      final command = ServeCommand(
        config: config,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        harnessFactory: _harnessFactoryFor(worker),
        serverFactory: (builder) => builder.build(),
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

    // The clean shutdown path (SIGINT/SIGTERM → shutdown() → _exitFn(0)) is
    // verified by manual testing with `bash docs/testing/plain/run.sh` + Ctrl+C.
    // In-process signal-based testing is not feasible: Process.killPid sends
    // signals to the OS process which terminates the test runner itself.
    // The _exitFn(0) call is placed at the end of run() (after the finally
    // block) and is exercised by any successful run that completes normally.
  });
}
