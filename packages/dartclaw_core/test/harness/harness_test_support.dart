import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_core/src/container/container_executor.dart';
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_core/src/harness/process_types.dart';
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess, FakeProcess;
import 'package:test/test.dart';

/// Capture-only [Guard] that records every [GuardContext] it evaluates and
/// returns a configurable verdict (defaulting to [GuardVerdict.pass]).
///
/// Union of the former per-file recording guards: exposes both the full
/// [contexts] history and a [lastContext] convenience accessor.
class RecordingGuard extends Guard {
  RecordingGuard({this.verdict});

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

FakeProcess makeClaudeFakeProcess() => FakeProcess(stdoutController: StreamController<List<int>>());

CapturingFakeProcess makeCapturingClaudeProcess() =>
    CapturingFakeProcess(stdoutController: StreamController<List<int>>());

class KillTrackingFakeProcess extends FakeProcess {
  KillTrackingFakeProcess({bool completeExitOnKill = false, int killExitCode = 0})
    : _completeExitOnKill = completeExitOnKill,
      _killExitCode = killExitCode,
      super(stdoutController: StreamController<List<int>>());

  final bool _completeExitOnKill;
  final int _killExitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    final accepted = super.kill(signal);
    if (_completeExitOnKill) exit(_killExitCode);
    return accepted;
  }
}

class FailingWriteClaudeProcess extends CapturingFakeProcess {
  FailingWriteClaudeProcess() : super(stdoutController: StreamController<List<int>>());

  bool failWrites = false;

  late final IOSink _failingStdin = _SwitchableFailingSink(super.stdin, () => failWrites);

  @override
  IOSink get stdin => _failingStdin;
}

class _SwitchableFailingSink implements IOSink {
  _SwitchableFailingSink(this._delegate, this._shouldFail);

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
  FakeClaudeContainerExecutor({required this.hostRoot, required this.containerRoot});

  @override
  final String profileId = 'workspace';

  @override
  final String workingDir = '/workspace';

  @override
  final bool hasProjectMount = true;

  final String hostRoot;
  final String containerRoot;
  late List<String> lastCommand;

  @override
  Future<void> copyFileToContainer(String hostPath, String containerPath) async {}

  @override
  Future<void> deleteFileInContainer(String containerPath) async {}

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) async {
    lastCommand = List<String>.from(command);
    final fake = makeClaudeFakeProcess();
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
  Future<void> start() async {}

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
  PlatformCapabilities? platformCapabilities,
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
    platformCapabilities: platformCapabilities,
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
    final fake = makeClaudeFakeProcess();
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
