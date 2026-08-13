import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_core/src/container/container_executor.dart';
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_core/src/harness/process_types.dart';
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess, FakeProcess, makeVersionProbeProcess;
import 'package:test/test.dart';

/// Capture-only [Guard] that records every [GuardContext] it evaluates and
/// returns a configurable verdict (defaulting to [GuardVerdict.pass]).
///
/// Union of the former per-file recording guards: exposes both the full
/// [contexts] history and a [lastContext] convenience accessor.
class RecordingGuard extends Guard {
  new({this.verdict});

  final GuardVerdict? verdict;
  final contexts = <GuardContext>[];

  /// The most recently evaluated context, or `null` if none yet.
  GuardContext? get lastContext => contexts.isEmpty ? null : contexts.last;

  @override
  String get name => 'recording-guard';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    contexts.add(context);
    return verdict ?? GuardVerdict.pass();
  }
}

/// `completeExitOnKill` keeps harness teardown from burning the full
/// SIGTERM grace period plus the SIGKILL wait on every test; `closeStreamsOnExit`
/// stays off because these fakes' spawn factories emit on delayed timers that can
/// outlive the kill.
FakeProcess makeClaudeFakeProcess() =>
    FakeProcess(stdoutController: StreamController<List<int>>(), completeExitOnKill: true, closeStreamsOnExit: false);

CapturingFakeProcess makeCapturingClaudeProcess() => CapturingFakeProcess(
  stdoutController: StreamController<List<int>>(),
  completeExitOnKill: true,
  closeStreamsOnExit: false,
);

FakeProcess makeKillTrackingClaudeProcess({bool completeExitOnKill = false, int killExitCode = 0}) => FakeProcess(
  stdoutController: StreamController<List<int>>(),
  completeExitOnKill: completeExitOnKill,
  killExitCode: killExitCode,
  closeStreamsOnExit: false,
);

class FailingWriteClaudeProcess extends CapturingFakeProcess {
  new() : super(stdoutController: StreamController<List<int>>(), completeExitOnKill: true);

  bool failWrites = false;

  late final IOSink _failingStdin = SwitchableFailingSink(super.stdin, () => failWrites);

  @override
  IOSink get stdin => _failingStdin;
}

class SwitchableFailingSink implements IOSink {
  new(this._delegate, this._shouldFail);

  final IOSink _delegate;
  final bool Function() _shouldFail;

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {
    if (_shouldFail()) throw StateError('stdin write failed');
    _delegate.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _delegate.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _delegate.addStream(stream);

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<void> get done => _delegate.done;

  @override
  Future<void> flush() => _delegate.flush();

  @override
  void write(Object? object) {
    if (_shouldFail()) throw StateError('stdin write failed');
    _delegate.write(object);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    if (_shouldFail()) throw StateError('stdin write failed');
    _delegate.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    if (_shouldFail()) throw StateError('stdin write failed');
    _delegate.writeCharCode(charCode);
  }

  @override
  void writeln([Object? object = '']) {
    if (_shouldFail()) throw StateError('stdin write failed');
    _delegate.writeln(object);
  }
}

class FakeClaudeContainerExecutor implements ContainerExecutor {
  new({required this.hostRoot, required this.containerRoot, this.mcpBridgeUrl});

  @override
  final String profileId = 'workspace';

  @override
  final String workingDir = '/workspace';

  @override
  final bool hasProjectMount = true;

  @override
  late final String generatedStateDir = Directory('$hostRoot/.dartclaw-state').absolute.path;

  @override
  final String providerBridgeUrl = 'http://127.0.0.1:8080';

  @override
  final String? mcpBridgeUrl;

  final String hostRoot;
  final String containerRoot;
  late List<String> lastCommand;
  Map<String, String>? lastEnv;

  /// The most recent spawned (non-probe) process, for reading what the harness
  /// wrote to the container's stdin.
  CapturingFakeProcess? spawned;

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) async {
    lastCommand = List<String>.from(command);
    lastEnv = env == null ? null : Map<String, String>.from(env);
    if (command.length == 2 && command[1] == '--version') {
      return makeVersionProbeProcess('claude 1.0.0');
    }
    final fake = spawned = CapturingFakeProcess(
      stdoutController: StreamController<List<int>>(),
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    scheduleMicrotask(() {
      fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
    });
    Future.delayed(const Duration(milliseconds: 20), () {
      fake.emitStdout(
        jsonEncode({
          'type': 'result',
          'result': 'ok',
          'cost_usd': 0.01,
          'duration_ms': 50,
          'duration_api_ms': 20,
          'num_turns': 1,
          'is_error': false,
          'session_id': 'container-session',
        }),
      );
    });
    return fake;
  }

  @override
  Future<void> start() async {
    Directory(generatedStateDir).createSync(recursive: true);
  }

  @override
  String? containerPathForHostPath(String hostPath) {
    final normalizedHostPath = File(hostPath).absolute.path;
    final normalizedHostRoot = Directory(hostRoot).absolute.path;
    if (normalizedHostPath == normalizedHostRoot) {
      return containerRoot;
    }
    if (!normalizedHostPath.startsWith('$normalizedHostRoot${Platform.pathSeparator}')) {
      return null;
    }
    final relative = normalizedHostPath.substring(normalizedHostRoot.length + 1).replaceAll('\\', '/');
    return '$containerRoot/$relative';
  }
}

ProcessResult processResult({int exitCode = 0, String stdout = ''}) => ProcessResult(0, exitCode, stdout, '');

ClaudeCodeHarness buildClaudeHarness({
  ProcessFactory? processFactory,
  CommandProbe? commandProbe,
  DelayFactory? delayFactory,
  Map<String, String>? environment,
  Map<String, dynamic>? providerOptions,
  HarnessConfig harnessConfig = const HarnessConfig(),
  Duration killGracePeriod = Duration.zero,
  Duration initializeTimeout = const Duration(seconds: 10),
  PlatformCapabilities? platformCapabilities,
  GuardChain? guardChain,
  GuardAuditLogger? auditLogger,
  void Function(String toolName, String? reason)? onPermissionDenied,
}) {
  return ClaudeCodeHarness(
    cwd: '/tmp',
    processFactory: processFactory ?? defaultClaudeProcessFactory,
    commandProbe: commandProbe ?? defaultClaudeCommandProbe,
    delayFactory: delayFactory ?? noOpClaudeDelay,
    environment: environment ?? {'ANTHROPIC_API_KEY': 'sk-test-key'},
    providerOptions: providerOptions,
    harnessConfig: harnessConfig,
    killGracePeriod: killGracePeriod,
    initializeTimeout: initializeTimeout,
    platformCapabilities: platformCapabilities,
    guardChain: guardChain,
    auditLogger: auditLogger,
    onPermissionDenied: onPermissionDenied,
  );
}

typedef ProcessSpawn = ({String exe, List<String> args, String? workingDirectory, Map<String, String>? environment});

ProcessFactory capturingInitFactory({void Function(ProcessSpawn spawn)? onSpawn, FakeProcess? process}) {
  return (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
    onSpawn?.call((exe: exe, args: args, workingDirectory: workingDirectory, environment: environment));
    final fake = process ?? makeClaudeFakeProcess();
    scheduleMicrotask(() {
      fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
    });
    return fake;
  };
}

ProcessFactory resultEmittingFactory({Map<String, dynamic>? result, void Function(ProcessSpawn spawn)? onSpawn}) {
  final payload = <String, dynamic>{
    'type': 'result',
    'result': 'ok',
    'cost_usd': 0.001,
    'duration_ms': 10,
    'duration_api_ms': 5,
    'num_turns': 1,
    'is_error': false,
    'session_id': 'test-session',
    ...?result,
  };
  return (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
    onSpawn?.call((exe: exe, args: args, workingDirectory: workingDirectory, environment: environment));
    final fake = makeKillTrackingClaudeProcess(completeExitOnKill: true);
    scheduleMicrotask(() {
      fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
    });
    Future.delayed(const Duration(milliseconds: 20), () {
      fake.emitStdout(jsonEncode(payload));
    });
    return fake;
  };
}

Future<List<String>> startHarnessAndCaptureArgs({Map<String, dynamic>? providerOptions}) async {
  List<String>? capturedArgs;
  final h = buildClaudeHarness(
    providerOptions: providerOptions,
    processFactory: capturingInitFactory(onSpawn: (spawn) => capturedArgs = spawn.args),
  );
  addTearDown(h.dispose);
  await h.start();
  return capturedArgs!;
}

Map<String, dynamic> decodedSettings(List<String> args) {
  final settingsIndex = args.indexOf('--settings');
  expect(settingsIndex, isNonNegative);
  return jsonDecode(args[settingsIndex + 1]) as Map<String, dynamic>;
}

Future<Process> defaultClaudeProcessFactory(
  String exe,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  final fake = makeClaudeFakeProcess();
  scheduleMicrotask(() {
    fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
  });
  return fake;
}

Future<ProcessResult> defaultClaudeCommandProbe(String exe, List<String> args) async {
  return processResult(exitCode: 0, stdout: '1.0.0');
}

Future<void> noOpClaudeDelay(Duration _) async {}
