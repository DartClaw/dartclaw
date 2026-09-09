import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/native_embedding_platform_gate.dart';

void main() {
  test('observer accepts natural success and every natural expected failure', () async {
    final observer = NativeProbeObserver(
      runner: (executable, arguments, {required workingDirectory, required deadline, environment}) async {
        final failure = arguments.contains('--expect-failure');
        return ObservedCommand(
          exitCode: failure ? 1 : 0,
          stdoutText: jsonEncode({
            'result': failure ? 'expected-failure' : 'pass',
            if (failure) 'error': 'Native embedding initialization failed',
            if (!failure)
              'metrics': {
                'coldFirstEmbedMs': 10,
                'warmQueryMs': 2,
                'documentBatchMs': 3,
                'disposeMs': 1,
                'vectorDimension': 8,
                'documentCardinality': 2,
              },
          }),
          stderrText: '',
          elapsed: const Duration(milliseconds: 12),
          processExitObserved: true,
          forcedTermination: false,
        );
      },
    );
    final records = await observer.observe(_cases());
    expect(records.map((record) => record['operation']), [
      'success',
      'missingLibrary',
      'absentModel',
      'corruptModel',
      'nativeLoadFailure',
    ]);
    expect(records.every((record) => record['result'] == 'pass'), isTrue);
    expect(records.skip(1).every((record) => record['exitCode'] == 1), isTrue);
    expect(records.skip(1).every((record) => record['processExitObserved'] == true), isTrue);
  });

  test('malformed output, retained process and forced cleanup can never pass', () async {
    for (final result in [
      const ObservedCommand(
        exitCode: 0,
        stdoutText: 'not json',
        stderrText: '/Users/person/private/model.gguf',
        elapsed: Duration(milliseconds: 5),
        processExitObserved: true,
        forcedTermination: false,
      ),
      const ObservedCommand(
        exitCode: 0,
        stdoutText: '{"result":"pass"}',
        stderrText: '',
        elapsed: Duration(milliseconds: 5),
        processExitObserved: false,
        forcedTermination: false,
      ),
      const ObservedCommand(
        exitCode: 0,
        stdoutText: '{"result":"pass"}',
        stderrText: '',
        elapsed: Duration(seconds: 1),
        processExitObserved: true,
        forcedTermination: false,
        outputStreamsClosed: false,
      ),
      const ObservedCommand(
        exitCode: -1,
        stdoutText: '{"result":"pass"}',
        stderrText: '',
        elapsed: Duration(seconds: 90),
        processExitObserved: true,
        forcedTermination: true,
      ),
    ]) {
      final records = await NativeProbeObserver(
        runner: (executable, arguments, {required workingDirectory, required deadline, environment}) async => result,
      ).observe([_cases().first]);
      expect(records.single['result'], 'fail');
      expect('${records.single['sanitizedError']}', isNot(contains('/Users/person')));
    }
  });

  test('actual outer observer kills a stuck fake child and records forced termination', () async {
    final root = Directory.systemTemp.createTempSync('dartclaw-native-fake-child');
    addTearDown(() => root.deleteSync(recursive: true));
    final script = File(p.join(root.path, 'child.dart'))
      ..writeAsStringSync('Future<void> main() async => await Future<void>.delayed(const Duration(days: 1));\n');
    final result = await runObservedCommand(
      Platform.resolvedExecutable,
      [script.path],
      workingDirectory: root.path,
      deadline: const Duration(milliseconds: 100),
    );
    expect(result.forcedTermination, isTrue);
    expect(result.processExitObserved, isTrue);
  });

  test('outer observer escalates when a child ignores initial termination', () async {
    final root = Directory.systemTemp.createTempSync('dartclaw-native-resistant-child');
    addTearDown(() => root.deleteSync(recursive: true));
    final script = File(p.join(root.path, 'child.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'Future<void> main() async {\n'
        '  ProcessSignal.sigterm.watch().listen((_) {});\n'
        "  stdout.writeln('ready');\n"
        '  await Future<void>.delayed(const Duration(days: 1));\n'
        '}\n',
      );
    final result = await runObservedCommand(
      Platform.resolvedExecutable,
      [script.path],
      workingDirectory: root.path,
      deadline: const Duration(seconds: 1),
    );
    expect(result.stdoutText.trim(), 'ready');
    expect(result.forcedTermination, isTrue);
    expect(result.processExitObserved, isTrue);
    expect(result.outputStreamsClosed, isTrue);
    expect(result.exitCode, isNot(0));
    expect(result.elapsed, lessThan(const Duration(seconds: 13)));
  }, skip: Platform.isWindows ? 'Windows does not support ignoring SIGTERM' : false);

  test('inherited output pipes cannot retain an exited probe', () async {
    final root = Directory.systemTemp.createTempSync('dartclaw-native-retained-output');
    final pidFile = File(p.join(root.path, 'child.pid'));
    addTearDown(() {
      if (pidFile.existsSync()) Process.killPid(int.parse(pidFile.readAsStringSync()), ProcessSignal.sigkill);
      root.deleteSync(recursive: true);
    });
    final child = File(p.join(root.path, 'child.dart'))
      ..writeAsStringSync('Future<void> main() async => await Future<void>.delayed(const Duration(seconds: 30));\n');
    final script = File(p.join(root.path, 'parent.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'Future<void> main(List<String> args) async {\n'
        '  final child = await Process.start(Platform.resolvedExecutable, [args[0]], mode: ProcessStartMode.inheritStdio);\n'
        '  File(args[1]).writeAsStringSync(child.pid.toString());\n'
        '  exit(0);\n'
        '}\n',
      );
    final result = await runObservedCommand(
      Platform.resolvedExecutable,
      [script.path, child.path, pidFile.path],
      workingDirectory: root.path,
      deadline: const Duration(seconds: 3),
    );
    expect(result.exitCode, 0);
    expect(result.processExitObserved, isTrue);
    expect(result.outputStreamsClosed, isFalse);
    expect(result.elapsed, lessThan(const Duration(seconds: 5)));
  }, skip: Platform.isWindows ? 'POSIX inherited pipe fixture' : false);

  test('evidence schema requires both archives, all failure operations and process fields', () {
    final evidence = <String, Object?>{
      'schemaVersion': '1',
      'target': 'linux-x64',
      'sourceCommit': 'abc',
      'platform': {'os': 'linux', 'architecture': 'x64'},
      'dartVersion': '3.13.0',
      'hardware': {'processorCount': 2},
      'nativeRelease': {'release': 'v0.3.0'},
      'model': {'basename': 'model.gguf'},
      'releaseArchives': [{}, {}],
      'metrics': {'coldFirstEmbedMs': 1},
      'linuxOpenMp': {'library': 'libgomp.so.1', 'resolved': false},
      'failureCases': [
        for (final operation in ['missingLibrary', 'absentModel', 'corruptModel', 'nativeLoadFailure'])
          {
            'operation': operation,
            'elapsedMs': 1,
            'sanitizedError': 'safe',
            'exitCode': 1,
            'processExitObserved': true,
            'forcedTermination': false,
            'result': 'pass',
          },
      ],
      'result': 'pass',
    };
    expect(validateNativeEmbeddingEvidence(evidence), isFalse);
    (evidence['linuxOpenMp'] as Map<String, Object?>)['resolved'] = true;
    expect(validateNativeEmbeddingEvidence(evidence), isTrue);
    evidence['target'] = 'windows-x64';
    (evidence['platform'] as Map<String, Object?>)['os'] = 'windows';
    evidence.remove('linuxOpenMp');
    expect(validateNativeEmbeddingEvidence(evidence), isTrue);
    (evidence['failureCases'] as List).removeLast();
    expect(validateNativeEmbeddingEvidence(evidence), isFalse);
  });

  test('probe proves document batch order with per-document production calls and never calls exit', () {
    final source = File(p.join(_repoRoot(), 'apps', 'dartclaw_cli', 'tool', 'native_embedding_probe.dart'))
        .readAsStringSync();
    expect(RegExp(r'embedDocuments\(documentInputs\)').allMatches(source), hasLength(1));
    expect(RegExp(r'embedDocuments\(\[documentInputs\.(?:first|last)\]\)').allMatches(source), hasLength(2));
    expect(RegExp(r'_requireSameVector\(documents\[[01]\]').allMatches(source), hasLength(2));
    expect(source, isNot(contains('exit(')));
  });
}

List<ProbeCase> _cases() => [
  for (final operation in ['success', 'missingLibrary', 'absentModel', 'corruptModel', 'nativeLoadFailure'])
    ProbeCase(
      operation: operation,
      executable: 'probe',
      workingDirectory: '.',
      arguments: operation == 'success' ? const [] : ['--expect-failure', operation],
      failure: operation != 'success',
    ),
];

String _repoRoot() {
  var current = Directory.current.absolute.path;
  while (!Directory(p.join(current, 'apps', 'dartclaw_cli')).existsSync()) {
    final parent = p.dirname(current);
    if (parent == current) throw StateError('Repository root not found');
    current = parent;
  }
  return current;
}
