import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/container/container_config.dart';
import 'package:dartclaw_core/src/container/container_manager.dart';
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Reusable FakeProcess (same pattern as claude_code_harness_test.dart)
// ---------------------------------------------------------------------------

class _NullIOSink implements IOSink {
  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Completer<void>().future;
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}

class _FakeProcess implements Process {
  final StreamController<List<int>> _stdoutCtrl = StreamController<List<int>>();
  final StreamController<List<int>> _stderrCtrl = StreamController<List<int>>();
  final Completer<int> _exitCodeCompleter = Completer<int>();

  @override
  int get pid => 42;

  @override
  IOSink get stdin => _NullIOSink();

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  void emitStdout(String line) {
    _stdoutCtrl.add(utf8.encode('$line\n'));
  }
}

/// Captures JSONL lines written to stdin.
class _CapturingFakeProcess extends _FakeProcess {
  final List<Map<String, dynamic>> captured = [];

  @override
  IOSink get stdin => _CapturingIOSink(captured);
}

class _CapturingIOSink extends _NullIOSink {
  final List<Map<String, dynamic>> _captured;
  _CapturingIOSink(this._captured);

  @override
  void add(List<int> data) {
    final line = utf8.decode(data).trim();
    if (line.isNotEmpty) {
      try {
        _captured.add(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {}
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ProcessResult _result({int exitCode = 0, String stdout = ''}) => ProcessResult(0, exitCode, stdout, '');

Future<ProcessResult> _defaultProbe(String exe, List<String> args) async => _result(exitCode: 0, stdout: '1.0.0');

Future<void> _noOpDelay(Duration _) async {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MCP config temp file lifecycle', () {
    test('writes MCP config temp file when mcpServerUrl and mcpGatewayToken set', () async {
      late List<String> capturedArgs;
      final fake = _FakeProcess();

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory:
            (
              exe,
              args, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              capturedArgs = args;
              scheduleMicrotask(() {
                fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
              });
              return fake;
            },
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3000/mcp', mcpGatewayToken: 'test-token'),
      );

      await harness.start();

      // Verify --mcp-config arg was passed
      expect(capturedArgs, contains('--mcp-config'));
      final mcpConfigIdx = capturedArgs.indexOf('--mcp-config');
      final mcpConfigPath = capturedArgs[mcpConfigIdx + 1];
      expect(mcpConfigPath, contains('dartclaw-mcp-config-'));

      // Verify temp file exists and has correct JSON content
      final configFile = File(mcpConfigPath);
      expect(configFile.existsSync(), isTrue);

      final json = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      final mcpServers = json['mcpServers'] as Map<String, dynamic>;
      final dartclaw = mcpServers['dartclaw'] as Map<String, dynamic>;
      expect(dartclaw['type'], equals('http'));
      expect(dartclaw['url'], equals('http://127.0.0.1:3000/mcp'));
      final headers = dartclaw['headers'] as Map<String, dynamic>;
      expect(headers['Authorization'], equals('Bearer test-token'));

      // Clean up
      await harness.dispose();
    });

    test('temp file has 0600 permissions', () async {
      final fake = _FakeProcess();
      String? mcpConfigPath;

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory:
            (
              exe,
              args, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              final idx = args.indexOf('--mcp-config');
              if (idx != -1) mcpConfigPath = args[idx + 1];
              scheduleMicrotask(() {
                fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
              });
              return fake;
            },
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3000/mcp', mcpGatewayToken: 'test-token'),
      );

      await harness.start();

      expect(mcpConfigPath, isNotNull);
      final stat = File(mcpConfigPath!).statSync();
      // 0600 = owner read+write only. Dart returns mode as decimal.
      // 33152 = 0100600 (regular file + 0600) on macOS/Linux.
      final modeBits = stat.mode & 0x1FF; // lower 9 bits = rwxrwxrwx
      expect(modeBits, equals(0x180)); // 0600 = 0b110000000 = 0x180

      await harness.dispose();
    }, testOn: 'mac-os || linux');

    test('temp file cleaned up on stop()', () async {
      final fake = _FakeProcess();
      String? mcpConfigPath;

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory:
            (
              exe,
              args, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              final idx = args.indexOf('--mcp-config');
              if (idx != -1) mcpConfigPath = args[idx + 1];
              scheduleMicrotask(() {
                fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
              });
              return fake;
            },
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3000/mcp', mcpGatewayToken: 'test-token'),
      );

      await harness.start();
      expect(File(mcpConfigPath!).existsSync(), isTrue);

      await harness.stop();
      expect(File(mcpConfigPath!).existsSync(), isFalse);

      // Final cleanup (dispose after stop is safe)
      await harness.dispose();
    });

    test('temp file cleaned up on dispose()', () async {
      final fake = _FakeProcess();
      String? mcpConfigPath;

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory:
            (
              exe,
              args, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              final idx = args.indexOf('--mcp-config');
              if (idx != -1) mcpConfigPath = args[idx + 1];
              scheduleMicrotask(() {
                fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
              });
              return fake;
            },
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3000/mcp', mcpGatewayToken: 'test-token'),
      );

      await harness.start();
      expect(File(mcpConfigPath!).existsSync(), isTrue);

      await harness.dispose();
      expect(File(mcpConfigPath!).existsSync(), isFalse);
    });

    test('restricted container copies MCP config into /tmp when /project is unavailable', () async {
      final fake = _FakeProcess();
      final dockerCalls = <List<String>>[];
      List<String>? capturedExecArgs;

      final containerManager = ContainerManager(
        config: const ContainerConfig(enabled: true),
        containerName: 'dartclaw-test1234-restricted',
        profileId: 'restricted',
        workspaceMounts: const [],
        proxySocketDir: '/tmp/proxy',
        workingDir: '/tmp',
        runCommand: (exe, args) async {
          dockerCalls.add([exe, ...args]);
          if (args.first == 'inspect') {
            return ProcessResult(0, 0, 'true\n', '');
          }
          return ProcessResult(0, 0, '', '');
        },
        startCommand:
            (
              exe,
              args, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              capturedExecArgs = args;
              scheduleMicrotask(() {
                fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
              });
              return fake;
            },
      );

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3000/mcp', mcpGatewayToken: 'test-token'),
        containerManager: containerManager,
      );

      await harness.start();

      expect(capturedExecArgs, contains('--mcp-config'));
      final mcpConfigIdx = capturedExecArgs!.indexOf('--mcp-config');
      final containerConfigPath = capturedExecArgs![mcpConfigIdx + 1];
      expect(containerConfigPath, startsWith('/tmp/'));
      expect(containerConfigPath, isNot(contains('/project/')));

      final copyCall = dockerCalls.firstWhere((call) => call.length > 1 && call[1] == 'cp');
      expect(copyCall[3], equals('dartclaw-test1234-restricted:$containerConfigPath'));
      expect(File(copyCall[2]).existsSync(), isTrue);

      await harness.stop();
      final cleanupCall = dockerCalls.firstWhere((call) => call.length > 1 && call[1] == 'exec');
      expect(cleanupCall, ['docker', 'exec', 'dartclaw-test1234-restricted', 'rm', '-f', containerConfigPath]);
      expect(File(copyCall[2]).existsSync(), isFalse);
      await harness.dispose();
    });

    test('no temp file when mcpServerUrl is null', () async {
      late List<String> capturedArgs;
      final fake = _FakeProcess();

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory:
            (
              exe,
              args, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              capturedArgs = args;
              scheduleMicrotask(() {
                fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
              });
              return fake;
            },
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        harnessConfig: const HarnessConfig(),
      );

      await harness.start();

      expect(capturedArgs, isNot(contains('--mcp-config')));

      await harness.dispose();
    });

    test('skips sdkMcpServers when mcpServerUrl is set', () async {
      final fake = _CapturingFakeProcess();

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory:
            (
              exe,
              args, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              scheduleMicrotask(() {
                fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
              });
              return fake;
            },
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        onMemorySave: (args) async => {'status': 'ok'},
        onMemorySearch: (args) async => {'results': []},
        onMemoryRead: (args) async => {'content': ''},
        harnessConfig: const HarnessConfig(mcpServerUrl: 'http://127.0.0.1:3000/mcp', mcpGatewayToken: 'test-token'),
      );

      await harness.start();

      // Find the initialize control_request
      final initMsg = fake.captured.firstWhere(
        (msg) => msg['type'] == 'control_request',
        orElse: () => <String, dynamic>{},
      );
      final request = initMsg['request'] as Map<String, dynamic>?;
      expect(request, isNotNull);
      expect(request!.containsKey('sdkMcpServers'), isFalse);

      await harness.dispose();
    });

    test('includes sdkMcpServers when mcpServerUrl is null', () async {
      final fake = _CapturingFakeProcess();

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory:
            (
              exe,
              args, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              scheduleMicrotask(() {
                fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
              });
              return fake;
            },
        commandProbe: _defaultProbe,
        delayFactory: _noOpDelay,
        environment: {'ANTHROPIC_API_KEY': 'sk-test'},
        onMemorySave: (args) async => {'status': 'ok'},
        onMemorySearch: (args) async => {'results': []},
        onMemoryRead: (args) async => {'content': ''},
        harnessConfig: const HarnessConfig(),
      );

      await harness.start();

      final initMsg = fake.captured.firstWhere(
        (msg) => msg['type'] == 'control_request',
        orElse: () => <String, dynamic>{},
      );
      final request = initMsg['request'] as Map<String, dynamic>?;
      expect(request, isNotNull);
      expect(request!.containsKey('sdkMcpServers'), isTrue);

      await harness.dispose();
    });
  });
}
